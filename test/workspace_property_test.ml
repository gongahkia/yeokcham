module Capsule_store = Paengi_capsule_store
module Id = Paengi_id
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Workspace = Paengi_workspace
module Workspace_store = Paengi_workspace_store

let default_seed = 20_260_801

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

let () = Printf.printf "workspace property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let workspace_id seed = Id.Workspace_id.of_bytes (raw_id seed) |> Result.get_ok

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
  let root = Filename.temp_file "paengi-workspace-property-" "" in
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

let checkpoint scratch snapshot timestamp =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:timestamp ~created_at:timestamp
  |> Result.get_ok
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let selected_revision revision capsule =
  Workspace_store.revision_selected revision
  |> List.find (fun link ->
      Id.Capsule_id.equal capsule (Capsule_store.revision_link_capsule link))
  |> Capsule_store.revision_link_revision

let deterministic_tie_break_ignores_selection_permutations =
  QCheck2.Test.make ~count:100
    ~name:
      "workspace order uses revision-ID tie-break independent of selection \
       permutation"
    QCheck2.Gen.(list_size (int_range 0 24) (int_range 0 1_000))
    (fun ranks ->
      let selected =
        ranks
        |> List.mapi (fun index rank ->
            ( rank,
              Workspace.
                {
                  capsule = capsule_id (index + 1);
                  revision = revision_id (index + 1);
                  dependencies = [];
                } ))
        |> List.sort (fun (left, _) (right, _) -> Int.compare left right)
        |> List.map snd
      in
      match Workspace.derive_order ~selected ~explicit_order:None with
      | Error _ -> false
      | Ok order ->
          let actual =
            Workspace.revisions order
            |> List.map (fun selection -> selection.Workspace.revision)
          in
          let expected =
            List.init (List.length ranks) (fun index -> revision_id (index + 1))
          in
          List.for_all2 Id.Capsule_revision_id.equal actual expected)

let durable_workspace_state_machine_survives_reopen =
  QCheck2.Test.make ~count:20
    ~name:
      "workspace \
       create/enable/disable/reorder/materialise/conflict/resolve/rematerialise \
       state machine survives reopen"
    QCheck2.Gen.(int_range 0 255)
    (fun salt ->
      try
        with_repository (fun root store ->
            let directory = Filename.concat root "dir" in
            Unix.mkdir directory 0o700;
            let tracked = Filename.concat directory "tracked" in
            write_file tracked "base";
            let scratch = Scratch.open_repository store in
            let base, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            let initial =
              Scratch.create_initial scratch ~snapshot:base ~created_at:0L
              |> Result.get_ok |> Scratch.Checkpoint.id
            in
            write_file tracked "a";
            let snapshot_a, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            let checkpoint_a = checkpoint scratch snapshot_a 1L in
            let capsule_a = capsule_id (300 + salt) in
            ignore
              (Capsule_store.Durable.create_from_checkpoints ~store ~scratch
                 ~id:capsule_a ~title:"a" ~description:"a" ~dependencies:[]
                 ~evidence:[] ~from:initial ~target:checkpoint_a ~created_at:2L
                 ~changed_at:2L ()
              |> Result.get_ok);
            write_file tracked "base";
            let reverted, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            ignore (checkpoint scratch reverted 3L);
            write_file tracked "c";
            let snapshot_c, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            let checkpoint_c = checkpoint scratch snapshot_c 4L in
            let capsule_c = capsule_id (600 + salt) in
            ignore
              (Capsule_store.Durable.create_from_checkpoints ~store ~scratch
                 ~id:capsule_c ~title:"c" ~description:"c" ~dependencies:[]
                 ~evidence:[] ~from:initial ~target:checkpoint_c ~created_at:5L
                 ~changed_at:5L ()
              |> Result.get_ok);
            let workspace = workspace_id (900 + salt) in
            ignore
              (Workspace_store.Durable.create ~store ~id:workspace ~base
                 ~name:None ~description:None ~created_at:6L
              |> Result.get_ok);
            ignore
              (Workspace_store.Durable.enable_current_capsule ~store ~workspace
                 ~capsule:capsule_a ~expected_generation:None ~created_at:7L
              |> Result.get_ok);
            ignore
              (Workspace_store.Durable.enable_current_capsule ~store ~workspace
                 ~capsule:capsule_c ~expected_generation:None ~created_at:8L
              |> Result.get_ok);
            ignore
              (Workspace_store.Durable.disable_capsule ~store ~workspace
                 ~capsule:capsule_a ~expected_generation:None ~created_at:9L
              |> Result.get_ok);
            let enabled =
              Workspace_store.Durable.enable_current_capsule ~store ~workspace
                ~capsule:capsule_a ~expected_generation:None ~created_at:10L
              |> Result.get_ok
            in
            let revision = Workspace_store.resolved_revision enabled in
            ignore
              (Workspace_store.Durable.reorder ~store ~workspace
                 ~order:
                   [
                     selected_revision revision capsule_a;
                     selected_revision revision capsule_c;
                   ]
                 ~expected_generation:None ~created_at:11L
              |> Result.get_ok);
            let partial =
              Workspace_store.Durable.materialise ~store ~scratch ~root
                ~workspace ~observed_at:12L ~created_at:12L ~dry_run:false ()
              |> Result.get_ok
            in
            if not partial.Workspace_store.Durable.partial then false
            else
              let conflicts =
                Workspace_store.Durable.list_conflicts store workspace
                |> Result.get_ok
              in
              match conflicts with
              | [ conflict ] ->
                  ignore
                    (Workspace_store.Durable.resolve_skip ~store ~workspace
                       ~conflict:(Workspace_store.conflict_id conflict)
                       ~expected_generation:None ~created_at:13L
                    |> Result.get_ok);
                  let complete =
                    Workspace_store.Durable.materialise ~store ~scratch ~root
                      ~workspace ~observed_at:14L ~created_at:14L ~dry_run:false
                      ()
                    |> Result.get_ok
                  in
                  let reopened = Store.open_repository ~root |> Result.get_ok in
                  let current =
                    Workspace_store.Durable.read_current reopened workspace
                    |> Result.get_ok
                  in
                  (not complete.Workspace_store.Durable.partial)
                  && String.equal
                       (In_channel.with_open_bin tracked In_channel.input_all)
                       "a"
                  && Option.is_some
                       (Workspace_store.current_latest_attempt
                          (Workspace_store.resolved_current_ref current))
                  && Workspace_store.Durable.list_conflicts reopened workspace
                     |> Result.get_ok = []
              | _ -> false)
      with _ -> false)

let () =
  Alcotest.run "workspace properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "deterministic-tie-break")
            deterministic_tie_break_ignores_selection_permutations;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "durable-workspace-state-machine")
            durable_workspace_state_machine_survives_reopen;
        ] );
    ]
