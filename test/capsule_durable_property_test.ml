module Capsule_store = Yeokcham_capsule_store
module Id = Yeokcham_id
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

[@@@warning "-42"]

let default_seed = 20_260_731

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

let () = Printf.printf "durable capsule property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

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

let with_repository check =
  let root = Filename.temp_file "yeokcham-durable-capsule-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      match Store.init ~root with
      | Error _ -> false
      | Ok store -> check root store)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let checkpoint scratch store root timestamp =
  let snapshot, _ = Snapshot.scan ~root ~store |> Result.get_ok in
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:timestamp ~created_at:timestamp
  |> Result.get_ok
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let link resolved =
  {
    Capsule_store.capsule =
      Capsule_store.capsule_id (Capsule_store.Durable.resolved_capsule resolved);
    revision =
      Capsule_store.revision_id
        (Capsule_store.Durable.resolved_revision resolved);
    object_id = Capsule_store.Durable.resolved_revision_object resolved;
  }

let create_fold_show_split_combine_reopen =
  QCheck2.Test.make ~count:40
    ~name:
      "durable capsule create/fold/show/split/combine state machine survives \
       reopen"
    QCheck2.Gen.(int_range 2 6)
    (fun steps ->
      try
        with_repository (fun root store ->
            let tracked = Filename.concat root "tracked" in
            write_file tracked "0";
            let scratch = Scratch.open_repository store in
            let initial_snapshot, _ =
              Snapshot.scan ~root ~store |> Result.get_ok
            in
            let initial =
              Scratch.create_initial scratch ~snapshot:initial_snapshot
                ~created_at:0L
              |> Result.get_ok |> Scratch.Checkpoint.id
            in
            let checkpoints =
              List.init steps (fun index ->
                  let timestamp = Int64.of_int (index + 1) in
                  write_file tracked (string_of_int (index + 1));
                  checkpoint scratch store root timestamp)
            in
            let first = List.hd checkpoints in
            let id = capsule_id 150 in
            let current =
              Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id
                ~title:"property" ~description:"property" ~dependencies:[]
                ~evidence:[] ~from:initial ~target:first ~created_at:1L
                ~changed_at:1L ()
              |> Result.get_ok
            in
            let _current =
              List.fold_left
                (fun current (index, target) ->
                  let current_ref =
                    Capsule_store.Durable.resolved_current_ref current
                  in
                  Capsule_store.Durable.fold_from_checkpoints ~store ~scratch
                    ~capsule:id
                    ~expected_revision:
                      (Capsule_store.current_revision current_ref)
                    ~expected_generation:
                      (Capsule_store.current_generation current_ref)
                    ~evidence:[]
                    ~from:(List.nth checkpoints index)
                    ~target
                    ~created_at:(Int64.of_int (index + 2))
                    ~changed_at:(Int64.of_int (index + 2))
                    ()
                  |> Result.get_ok)
                current
                (List.mapi
                   (fun index target -> (index, target))
                   (List.tl checkpoints))
            in
            let operations =
              Capsule_store.Durable.current_diff store id |> Result.get_ok
            in
            let left, right =
              Capsule_store.Durable.split ~store ~scratch ~source:id
                ~left_id:(capsule_id 151) ~left_title:"left"
                ~left_description:"left" ~right_id:(capsule_id 152)
                ~right_title:"right" ~right_description:"right"
                ~left_operation_indices:[ 0 ] ~created_at:10L ~changed_at:10L
                ~confirmed:true ()
              |> Result.get_ok
            in
            let combined =
              Capsule_store.Durable.combine ~store ~scratch ~id:(capsule_id 153)
                ~title:"combined" ~description:"combined"
                ~sources:[ link left; link right ]
                ~created_at:11L ~changed_at:11L ~confirmed:true ()
              |> Result.get_ok
            in
            match Store.open_repository ~root with
            | Error _ -> false
            | Ok reopened ->
                let history =
                  Capsule_store.Durable.history reopened id |> Result.get_ok
                in
                let combined_diff =
                  Capsule_store.Durable.current_diff reopened (capsule_id 153)
                  |> Result.get_ok
                in
                List.length history = steps
                && List.length operations = steps
                && List.length combined_diff = steps
                && Id.Capsule_id.equal (capsule_id 153)
                     (Capsule_store.capsule_id
                        (Capsule_store.Durable.resolved_capsule combined)))
      with _ -> false)

let current_create_edit_fold_split_combine_reopen =
  QCheck2.Test.make ~count:40
    ~name:
      "current creation/edit/fold/confirmed split/combine state machine \
       survives reopen"
    QCheck2.Gen.(int_range 2 6)
    (fun steps ->
      try
        with_repository (fun root store ->
            let tracked = Filename.concat root "tracked" in
            write_file tracked "0";
            let scratch = Scratch.open_repository store in
            let initial_snapshot, _ =
              Snapshot.scan ~root ~store |> Result.get_ok
            in
            let initial =
              Scratch.create_initial scratch ~snapshot:initial_snapshot
                ~created_at:0L
              |> Result.get_ok |> Scratch.Checkpoint.id
            in
            write_file tracked "1";
            let id = capsule_id 160 in
            let created =
              Capsule_store.Durable.create_from_current ~store ~scratch ~root
                ~id ~title:"current property" ~description:"current property"
                ~dependencies:[] ~evidence:[] ~created_at:1L ~changed_at:1L ()
              |> Result.get_ok
            in
            let initial_current, anchor =
              match created with
              | Capsule_store.Durable.No_current_changes _ -> raise Exit
              | Capsule_store.Durable.Created_from_current
                  { resolved; source; target } ->
                  if not (Scratch.Checkpoint_id.equal initial source) then
                    raise Exit;
                  (resolved, target)
            in
            let reused =
              Capsule_store.Durable.enable_for_editing ~store ~scratch ~root
                ~capsule:id ~observed_at:2L ~created_at:2L ()
              |> Result.get_ok
            in
            if not (Scratch.Checkpoint_id.equal anchor reused) then false
            else
              let _current, _anchor =
                List.fold_left
                  (fun (current, anchor) index ->
                    let timestamp = Int64.of_int (index + 2) in
                    write_file tracked (string_of_int (index + 1));
                    let target = checkpoint scratch store root timestamp in
                    let reference =
                      Capsule_store.Durable.resolved_current_ref current
                    in
                    let next =
                      Capsule_store.Durable.fold_from_checkpoints ~store
                        ~scratch ~capsule:id
                        ~expected_revision:
                          (Capsule_store.current_revision reference)
                        ~expected_generation:
                          (Capsule_store.current_generation reference)
                        ~evidence:[] ~from:anchor ~target ~created_at:timestamp
                        ~changed_at:timestamp ()
                      |> Result.get_ok
                    in
                    (next, target))
                  (initial_current, anchor)
                  (List.init (steps - 1) (fun index -> index + 1))
              in
              let left, right =
                Capsule_store.Durable.split ~store ~scratch ~source:id
                  ~left_id:(capsule_id 161) ~left_title:"left"
                  ~left_description:"left" ~right_id:(capsule_id 162)
                  ~right_title:"right" ~right_description:"right"
                  ~left_operation_indices:[ 0 ] ~created_at:20L ~changed_at:20L
                  ~confirmed:true ()
                |> Result.get_ok
              in
              let combined =
                Capsule_store.Durable.combine ~store ~scratch
                  ~id:(capsule_id 163) ~title:"combined" ~description:"combined"
                  ~sources:[ link left; link right ]
                  ~created_at:21L ~changed_at:21L ~confirmed:true ()
                |> Result.get_ok
              in
              match Store.open_repository ~root with
              | Error _ -> false
              | Ok reopened ->
                  let history =
                    Capsule_store.Durable.history reopened id |> Result.get_ok
                  in
                  let combined_diff =
                    Capsule_store.Durable.current_diff reopened (capsule_id 163)
                    |> Result.get_ok
                  in
                  List.length history = steps
                  && List.length combined_diff = steps
                  && Id.Capsule_id.equal (capsule_id 163)
                       (Capsule_store.capsule_id
                          (Capsule_store.Durable.resolved_capsule combined)))
      with Exit | _ -> false)

let () =
  Alcotest.run "durable capsule properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "create-fold-show-split-combine")
            create_fold_show_split_combine_reopen;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "current-create-edit-fold-split-combine")
            current_create_edit_fold_split_combine_reopen;
        ] );
    ]
