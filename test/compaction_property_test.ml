module Compaction = Paengi_compaction
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

let default_seed = 20_260_730

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let () = Printf.printf "compaction property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let checkpoint_id value =
  let raw = Bytes.make 32 '\000' in
  Bytes.set raw 0 (Char.chr (value land 0xff));
  Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string raw)
  |> Option.get |> Scratch.Checkpoint_id.of_stored_object_id

let checkpoint value created_at pinned =
  {
    Compaction.Policy.id = checkpoint_id value;
    created_at = Int64.of_int created_at;
    effective_retention = (if pinned then [ Scratch.User_pinned ] else []);
  }

let policy =
  Compaction.Policy.create ~recent_window_seconds:10L
    ~periodic_interval_seconds:25L ~storage_budget_bytes:None
  |> Result.get_ok

let decision_equal left right =
  match (left, right) with
  | Compaction.Policy.Protected_by left, Compaction.Policy.Protected_by right ->
      String.equal
        (Scratch.retention_reason_to_string left)
        (Scratch.retention_reason_to_string right)
  | Compaction.Policy.Recent_window, Compaction.Policy.Recent_window -> true
  | ( Compaction.Policy.Periodic_bucket left,
      Compaction.Policy.Periodic_bucket right ) ->
      Int64.equal left right
  | Compaction.Policy.Expired, Compaction.Policy.Expired -> true
  | ( Compaction.Policy.Protected_by _,
      ( Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Expired ) )
  | ( ( Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Expired ),
      Compaction.Policy.Protected_by _ )
  | ( Compaction.Policy.Recent_window,
      (Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Expired) )
  | ( (Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Expired),
      Compaction.Policy.Recent_window )
  | Compaction.Policy.Periodic_bucket _, Compaction.Policy.Expired
  | Compaction.Policy.Expired, Compaction.Policy.Periodic_bucket _ ->
      false

let permutation_does_not_change_selection =
  QCheck2.Test.make ~count:100
    ~name:"retention selection is independent of timeline input order"
    QCheck2.Gen.(list_size (int_range 0 24) (pair (int_range 0 150) bool))
    (fun values ->
      let checkpoints =
        List.mapi
          (fun index (created_at, pinned) -> checkpoint index created_at pinned)
          values
      in
      let selected = Compaction.Policy.select policy ~now:100L checkpoints in
      let reversed =
        Compaction.Policy.select policy ~now:100L (List.rev checkpoints)
      in
      List.for_all
        (fun checkpoint ->
          let lookup selections =
            List.find
              (fun selection ->
                Scratch.Checkpoint_id.equal
                  (Compaction.Policy.checkpoint selection).Compaction.Policy.id
                  checkpoint.Compaction.Policy.id)
              selections
          in
          decision_equal
            (Compaction.Policy.decision (lookup selected))
            (Compaction.Policy.decision (lookup reversed)))
        checkpoints)

let pinned_checkpoints_never_expire =
  QCheck2.Test.make ~count:100
    ~name:"user-pinned checkpoints override every expiry policy"
    QCheck2.Gen.(int_range (-1_000_000) 1_000_000)
    (fun created_at ->
      let pinned = checkpoint 1 created_at true in
      match
        Compaction.Policy.select policy ~now:100L [ pinned ]
        |> List.hd |> Compaction.Policy.decision
      with
      | Compaction.Policy.Protected_by reason ->
          String.equal (Scratch.retention_reason_to_string reason) "user pinned"
      | Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Expired ->
          false)

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let compacted_logical_checkpoints_preserve_snapshots =
  QCheck2.Test.make ~count:20
    ~name:"compacted retained logical checkpoints preserve snapshots"
    QCheck2.Gen.(int_range 1 6)
    (fun count ->
      let root = Filename.temp_file "paengi-compaction-property-" "" in
      Unix.unlink root;
      Unix.mkdir root 0o700;
      Fun.protect
        ~finally:(fun () -> remove_tree root)
        (fun () ->
          try
            let file = Filename.concat root "file" in
            Out_channel.with_open_bin file (fun channel ->
                Out_channel.output_string channel "base");
            let store = Store.init ~root |> Result.get_ok in
            let scratch = Scratch.open_repository store in
            let base, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            let initial =
              Scratch.create_initial scratch ~snapshot:base ~created_at:0L
              |> Result.get_ok
            in
            Scratch.pin scratch (Scratch.Checkpoint.id initial) ~changed_at:1L
            |> Result.get_ok;
            let head = ref initial in
            for index = 1 to count do
              Out_channel.with_open_bin file (fun channel ->
                  Out_channel.output_string channel
                    (Printf.sprintf "edit-%d" index));
              let snapshot, _ = Snapshot.scan ~root ~store |> Result.get_ok in
              match
                Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
                  ~observed_at:(Int64.of_int index)
                  ~created_at:(Int64.of_int index)
                |> Result.get_ok
              with
              | Scratch.Created checkpoint -> head := checkpoint
              | Scratch.Unchanged _ -> raise Exit
            done;
            let expected =
              [
                (Scratch.Checkpoint.id !head, Scratch.Checkpoint.snapshot !head);
                ( Scratch.Checkpoint.id initial,
                  Scratch.Checkpoint.snapshot initial );
              ]
            in
            let policy =
              Compaction.Policy.create ~recent_window_seconds:1L
                ~periodic_interval_seconds:0L ~storage_budget_bytes:None
              |> Result.get_ok
            in
            ignore
              (Compaction.activate ~store scratch ~policy
                 ~now:(Int64.of_int (count + 1))
              |> Result.get_ok);
            let actual =
              Scratch.timeline scratch ~limit:8 () |> Result.get_ok
            in
            List.length actual = List.length expected
            && List.for_all2
                 (fun (logical, snapshot) entry ->
                   Scratch.Checkpoint_id.equal logical entry.Scratch.logical_id
                   && Snapshot.Snapshot.equal_id snapshot
                        (Scratch.Checkpoint.snapshot entry.Scratch.checkpoint))
                 expected actual
          with Exit | Failure _ -> false))

let () =
  Alcotest.run "compaction properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "permutation")
            permutation_does_not_change_selection;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "pins") pinned_checkpoints_never_expire;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "compacted-logical-snapshots")
            compacted_logical_checkpoints_preserve_snapshots;
        ] );
    ]
