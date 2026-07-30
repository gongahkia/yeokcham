module Compaction = Paengi_compaction
module Scratch = Paengi_scratch
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
        ] );
    ]
