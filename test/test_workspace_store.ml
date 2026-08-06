module Capsule_store = Yeokcham_capsule_store
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Id = Yeokcham_id
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Workspace_store = Yeokcham_workspace_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok
let workspace_id seed = Id.Workspace_id.of_bytes (raw_id seed) |> Result.get_ok

let stored_id seed =
  Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get

let snapshot_id seed = Snapshot.Snapshot.of_stored_object_id (stored_id seed)

let checkpoint_id seed =
  Scratch.Checkpoint_id.of_stored_object_id (stored_id seed)

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let workspace_revision_id seed =
  Id.Workspace_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let golden name =
  let paths =
    [ Filename.concat "golden" name; Filename.concat "test/golden" name ]
  in
  match List.find_opt Sys.file_exists paths with
  | Some path -> Golden.read_lower_hex_file path |> require_ok Fun.id
  | None -> Alcotest.fail ("missing golden fixture: " ^ name)

let with_store run =
  let root = Filename.temp_file "yeokcham-workspace-store-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  in
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      run root store)

let checkpoint scratch snapshot time =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:time ~created_at:time
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

type fixture = {
  scratch : Scratch.repository;
  base : Snapshot.Snapshot.id;
  capsule_a : Id.Capsule_id.t;
  capsule_c : Id.Capsule_id.t;
  capsule_d : Id.Capsule_id.t;
}

let make_fixture root store =
  Unix.mkdir (Filename.concat root "dir") 0o700;
  let tracked = Filename.concat root "dir/tracked" in
  let other = Filename.concat root "dir/other" in
  write_file tracked "base";
  write_file other "base-other";
  let scratch = Scratch.open_repository store in
  let base, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let initial =
    Scratch.create_initial scratch ~snapshot:base ~created_at:0L
    |> require_ok Scratch.error_to_string
    |> Scratch.Checkpoint.id
  in
  write_file tracked "a";
  write_file other "a-other";
  let snapshot_a, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let checkpoint_a = checkpoint scratch snapshot_a 1L in
  let capsule_a = capsule_id 10 in
  ignore
    (Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id:capsule_a
       ~title:"a" ~description:"first edit" ~dependencies:[] ~evidence:[]
       ~from:initial ~target:checkpoint_a ~created_at:2L ~changed_at:2L ()
    |> require_ok Capsule_store.error_to_string);
  write_file tracked "base";
  write_file other "base-other";
  let snapshot_revert, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  ignore (checkpoint scratch snapshot_revert 3L);
  write_file tracked "c";
  let snapshot_c, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let checkpoint_c = checkpoint scratch snapshot_c 4L in
  let capsule_c = capsule_id 20 in
  ignore
    (Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id:capsule_c
       ~title:"c" ~description:"competing edit" ~dependencies:[] ~evidence:[]
       ~from:initial ~target:checkpoint_c ~created_at:5L ~changed_at:5L ()
    |> require_ok Capsule_store.error_to_string);
  write_file tracked "base";
  write_file other "d-other";
  let snapshot_d, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let checkpoint_d = checkpoint scratch snapshot_d 6L in
  let capsule_d = capsule_id 30 in
  ignore
    (Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id:capsule_d
       ~title:"d" ~description:"second competing edit" ~dependencies:[]
       ~evidence:[] ~from:initial ~target:checkpoint_d ~created_at:7L
       ~changed_at:7L ()
    |> require_ok Capsule_store.error_to_string);
  { scratch; base; capsule_a; capsule_c; capsule_d }

let selected_revision revision capsule =
  Workspace_store.revision_selected revision
  |> List.find (fun link ->
      Id.Capsule_id.equal capsule (Capsule_store.revision_link_capsule link))
  |> Capsule_store.revision_link_revision

let current_capsule_revision store capsule =
  Capsule_store.Durable.read_current store capsule
  |> require_ok Capsule_store.error_to_string
  |> Capsule_store.Durable.resolved_revision |> Capsule_store.revision_id

let schema_fixture store =
  let workspace =
    Workspace_store.create_workspace ~id:(workspace_id 100) ~created_at:1L
      ~name:(Some "fixture") ~description:(Some "workspace")
    |> require_ok Workspace_store.error_to_string
  in
  let conflict =
    Workspace_store.create_conflict
      ~workspace:(Workspace_store.workspace_id workspace)
      ~workspace_revision:(workspace_revision_id 101)
      ~attempt:None ~base:(snapshot_id 102) ~capsule:(capsule_id 103)
      ~capsule_revision:(revision_id 104) ~operation_index:3
      ~kind:Workspace_store.Competing_edits
      ~paths:[ [ "dir"; "tracked" ] ]
      ~current:
        (Some
           (Scratch.File
              {
                mode = Snapshot.Executable;
                content = Snapshot.Content.of_stored_object_id (stored_id 105);
              }))
      ~candidates:[ "skip-operation" ] ~created_at:2L
    |> require_ok Workspace_store.error_to_string
  in
  let resolution =
    Workspace_store.create_resolution ~conflict
      ~action:Workspace_store.Skip_operation
      ~expected_current:(Workspace_store.conflict_current conflict)
      ~created_at:3L
    |> require_ok Workspace_store.error_to_string
  in
  let resolution_object =
    Workspace_store.store_resolution store resolution
    |> require_ok Workspace_store.error_to_string
  in
  let selected =
    Capsule_store.make_revision_link ~capsule:(capsule_id 106)
      ~revision:(revision_id 107) ~object_id:(stored_id 108)
  in
  let parent : Workspace_store.parent_link =
    {
      Workspace_store.parent_revision = workspace_revision_id 109;
      Workspace_store.parent_object_id = stored_id 110;
    }
  in
  let binding : Workspace_store.resolution_binding =
    {
      Workspace_store.binding_conflict = Workspace_store.conflict_id conflict;
      Workspace_store.binding_resolution =
        Workspace_store.resolution_id resolution;
      Workspace_store.binding_object_id = resolution_object;
    }
  in
  let revision =
    Workspace_store.create_revision
      ~workspace:(Workspace_store.workspace_id workspace)
      ~parent:(Some parent) ~base:(snapshot_id 102) ~selected:[ selected ]
      ~precedence:[]
      ~resolved_order:[ revision_id 107 ]
      ~resolutions:[ binding ]
      ~provenance:
        (Workspace_store.Resolved (Workspace_store.resolution_id resolution))
      ~created_at:4L
    |> require_ok Workspace_store.error_to_string
  in
  let attempt_id =
    Workspace_store.derive_attempt_id
      ~workspace:(Workspace_store.workspace_id workspace)
      ~workspace_revision:(Workspace_store.revision_id revision)
      ~base:(snapshot_id 102) ~ordered:[ selected ]
      ~starting_checkpoint:(checkpoint_id 111)
      ~starting_snapshot:(snapshot_id 112)
  in
  let attempt =
    Workspace_store.create_attempt ~id:attempt_id
      ~workspace:(Workspace_store.workspace_id workspace)
      ~workspace_revision:(Workspace_store.revision_id revision)
      ~base:(snapshot_id 102) ~ordered:[ selected ]
      ~starting_checkpoint:(checkpoint_id 111)
      ~starting_snapshot:(snapshot_id 112)
      ~outcomes:
        [
          Workspace_store.Attempt_applied_exactly
            {
              capsule = capsule_id 106;
              revision = revision_id 107;
              operation_index = 0;
            };
          Workspace_store.Attempt_persistent_conflict
            (Workspace_store.conflict_id conflict);
        ]
      ~resulting_snapshot:(snapshot_id 113)
      ~conflicts:[ Workspace_store.conflict_id conflict ]
      ~created_at:5L
    |> require_ok Workspace_store.error_to_string
  in
  let workspace_object =
    Workspace_store.store_workspace store workspace
    |> require_ok Workspace_store.error_to_string
  in
  let revision_object =
    Workspace_store.store_revision store revision
    |> require_ok Workspace_store.error_to_string
  in
  let conflict_object =
    Workspace_store.store_conflict store conflict
    |> require_ok Workspace_store.error_to_string
  in
  let attempt_object =
    Workspace_store.store_attempt store attempt
    |> require_ok Workspace_store.error_to_string
  in
  let current =
    Workspace_store.make_current_ref ~generation:7L
      ~workspace:(Workspace_store.workspace_id workspace)
      ~workspace_object
      ~revision:(Workspace_store.revision_id revision)
      ~revision_object
      ~latest_attempt:
        (Some (Workspace_store.attempt_id attempt, attempt_object))
    |> require_ok Workspace_store.error_to_string
  in
  ( workspace,
    workspace_object,
    revision,
    revision_object,
    conflict,
    conflict_object,
    resolution,
    resolution_object,
    attempt,
    attempt_object,
    current )

let schemas_have_canonical_goldens_and_inverse_decoders () =
  with_store (fun _ store ->
      let ( workspace,
            workspace_object,
            revision,
            revision_object,
            conflict,
            conflict_object,
            resolution,
            resolution_object,
            attempt,
            attempt_object,
            current ) =
        schema_fixture store
      in
      let bytes object_id =
        Store.get store object_id
        |> require_ok Store.error_to_string
        |> Envelope.encode
      in
      let fixtures =
        [
          ("workspace-v1.yeok.hex", bytes workspace_object);
          ("workspace-revision-v1.yeok.hex", bytes revision_object);
          ("workspace-attempt-v1.yeok.hex", bytes attempt_object);
          ("conflict-v1.yeok.hex", bytes conflict_object);
          ("resolution-v1.yeok.hex", bytes resolution_object);
          ( "workspace-current-v1.ref.hex",
            Workspace_store.encode_current_ref current );
        ]
      in
      List.iter
        (fun (name, bytes) -> Alcotest.(check string) name (golden name) bytes)
        fixtures;
      let loaded_workspace =
        Workspace_store.load_workspace store workspace_object
        |> require_ok Workspace_store.error_to_string
      in
      let loaded_revision =
        Workspace_store.load_revision store revision_object
        |> require_ok Workspace_store.error_to_string
      in
      let loaded_conflict =
        Workspace_store.load_conflict store conflict_object
        |> require_ok Workspace_store.error_to_string
      in
      let loaded_resolution =
        Workspace_store.load_resolution store resolution_object
        |> require_ok Workspace_store.error_to_string
      in
      let loaded_attempt =
        Workspace_store.load_attempt store attempt_object
        |> require_ok Workspace_store.error_to_string
      in
      let decoded_current =
        Workspace_store.decode_current_ref
          (Workspace_store.encode_current_ref current)
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "workspace inverse" true
        (Id.Workspace_id.equal
           (Workspace_store.workspace_id workspace)
           (Workspace_store.workspace_id loaded_workspace));
      Alcotest.(check bool)
        "revision inverse" true
        (Id.Workspace_revision_id.equal
           (Workspace_store.revision_id revision)
           (Workspace_store.revision_id loaded_revision));
      Alcotest.(check bool)
        "conflict inverse" true
        (Id.Conflict_id.equal
           (Workspace_store.conflict_id conflict)
           (Workspace_store.conflict_id loaded_conflict));
      Alcotest.(check bool)
        "resolution inverse" true
        (Id.Resolution_id.equal
           (Workspace_store.resolution_id resolution)
           (Workspace_store.resolution_id loaded_resolution));
      Alcotest.(check bool)
        "attempt inverse" true
        (Id.Workspace_attempt_id.equal
           (Workspace_store.attempt_id attempt)
           (Workspace_store.attempt_id loaded_attempt));
      Alcotest.(check bool)
        "current ref inverse" true
        (Id.Workspace_revision_id.equal
           (Workspace_store.current_revision current)
           (Workspace_store.current_revision decoded_current)))

let work_create_enable_reopen_and_stale_cas () =
  with_store (fun root store ->
      let fixture = make_fixture root store in
      let identity = workspace_id 40 in
      let created =
        Workspace_store.Durable.create ~store ~id:identity ~base:fixture.base
          ~name:(Some "work") ~description:(Some "test") ~created_at:6L
        |> require_ok Workspace_store.error_to_string
      in
      let initial_revision =
        Workspace_store.revision_id (Workspace_store.resolved_revision created)
      in
      let enabled_a =
        Workspace_store.Durable.enable_current_capsule ~store
          ~workspace:identity ~capsule:fixture.capsule_a
          ~expected_generation:(Some 0L) ~created_at:7L
        |> require_ok Workspace_store.error_to_string
      in
      let enabled_a_revision =
        Workspace_store.revision_id
          (Workspace_store.resolved_revision enabled_a)
      in
      Alcotest.(check bool)
        "enable creates an immutable revision" false
        (Id.Workspace_revision_id.equal initial_revision enabled_a_revision);
      let enabled =
        Workspace_store.Durable.enable_current_capsule ~store
          ~workspace:identity ~capsule:fixture.capsule_c
          ~expected_generation:(Some 1L) ~created_at:8L
        |> require_ok Workspace_store.error_to_string
      in
      (match
         Workspace_store.Durable.disable_capsule ~store ~workspace:identity
           ~capsule:fixture.capsule_a ~expected_generation:(Some 1L)
           ~created_at:9L
       with
      | Error error
        when String.starts_with ~prefix:"workspace "
               (Workspace_store.error_to_string error) ->
          ()
      | Error error -> Alcotest.fail (Workspace_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stale workspace CAS was accepted");
      let revision = Workspace_store.resolved_revision enabled in
      let order =
        [
          selected_revision revision fixture.capsule_a;
          selected_revision revision fixture.capsule_c;
        ]
      in
      ignore
        (Workspace_store.Durable.reorder ~store ~workspace:identity ~order
           ~expected_generation:(Some 2L) ~created_at:10L
        |> require_ok Workspace_store.error_to_string);
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened =
        Workspace_store.Durable.read_current reopened_store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check int)
        "selected revisions survive reopen" 2
        (List.length
           (Workspace_store.revision_selected
              (Workspace_store.resolved_revision reopened))))

let conflicts_materialise_and_resolve_immutably () =
  with_store (fun root store ->
      let fixture = make_fixture root store in
      let identity = workspace_id 60 in
      ignore
        (Workspace_store.Durable.create ~store ~id:identity ~base:fixture.base
           ~name:None ~description:None ~created_at:6L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_revision ~store ~workspace:identity
           ~revision:(current_capsule_revision store fixture.capsule_a)
           ~expected_generation:None ~created_at:7L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_revision ~store ~workspace:identity
           ~revision:(current_capsule_revision store fixture.capsule_c)
           ~expected_generation:None ~created_at:8L
        |> require_ok Workspace_store.error_to_string);
      let enabled =
        Workspace_store.Durable.enable_revision ~store ~workspace:identity
          ~revision:(current_capsule_revision store fixture.capsule_d)
          ~expected_generation:None ~created_at:9L
        |> require_ok Workspace_store.error_to_string
      in
      let revision = Workspace_store.resolved_revision enabled in
      ignore
        (Workspace_store.Durable.reorder ~store ~workspace:identity
           ~order:
             [
               selected_revision revision fixture.capsule_a;
               selected_revision revision fixture.capsule_c;
               selected_revision revision fixture.capsule_d;
             ]
           ~expected_generation:None ~created_at:10L
        |> require_ok Workspace_store.error_to_string);
      let materialised =
        Workspace_store.Durable.materialise ~store ~scratch:fixture.scratch
          ~root ~workspace:identity ~observed_at:11L ~created_at:11L
          ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "materialisation reports partial application" true
        materialised.Workspace_store.Durable.partial;
      Alcotest.(check string)
        "partial result keeps first exact edit" "a"
        (In_channel.with_open_bin
           (Filename.concat root "dir/tracked")
           In_channel.input_all);
      let conflicts =
        Workspace_store.Durable.list_conflicts store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check int)
        "persistent conflicts are listable" 2 (List.length conflicts);
      let conflict = List.hd conflicts in
      let before =
        Workspace_store.Durable.read_current store identity
        |> require_ok Workspace_store.error_to_string
      in
      let before_revision =
        Workspace_store.revision_id (Workspace_store.resolved_revision before)
      in
      let resolved =
        Workspace_store.Durable.resolve_skip ~store ~workspace:identity
          ~conflict:(Workspace_store.conflict_id conflict)
          ~expected_generation:None ~created_at:12L
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "resolution creates a new immutable workspace revision" false
        (Id.Workspace_revision_id.equal before_revision
           (Workspace_store.revision_id
              (Workspace_store.resolved_revision resolved)));
      (match
         Workspace_store.Durable.resolve_skip ~store ~workspace:identity
           ~conflict:(Workspace_store.conflict_id conflict)
           ~expected_generation:None ~created_at:13L
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "stale resolution was accepted");
      let rematerialised =
        Workspace_store.Durable.materialise ~store ~scratch:fixture.scratch
          ~root ~workspace:identity ~observed_at:14L ~created_at:14L
          ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "resolving one conflict preserves another" true
        rematerialised.Workspace_store.Durable.partial;
      let remaining =
        Workspace_store.Durable.list_conflicts store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check int)
        "one unrelated conflict remains" 1 (List.length remaining);
      ignore
        (Workspace_store.Durable.resolve_skip ~store ~workspace:identity
           ~conflict:(Workspace_store.conflict_id (List.hd remaining))
           ~expected_generation:None ~created_at:15L
        |> require_ok Workspace_store.error_to_string);
      let complete =
        Workspace_store.Durable.materialise ~store ~scratch:fixture.scratch
          ~root ~workspace:identity ~observed_at:16L ~created_at:16L
          ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "all explicit resolutions rematerialise exactly" false
        complete.Workspace_store.Durable.partial;
      ignore
        (Workspace_store.Durable.show_conflict store
           (Workspace_store.conflict_id conflict)
        |> require_ok Workspace_store.error_to_string))

let external_mutation_aborts_without_ref_publication () =
  with_store (fun root store ->
      let fixture = make_fixture root store in
      let identity = workspace_id 80 in
      ignore
        (Workspace_store.Durable.create ~store ~id:identity ~base:fixture.base
           ~name:None ~description:None ~created_at:6L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_current_capsule ~store
           ~workspace:identity ~capsule:fixture.capsule_a
           ~expected_generation:None ~created_at:7L
        |> require_ok Workspace_store.error_to_string);
      let head_before =
        Scratch.head_id fixture.scratch |> require_ok Scratch.error_to_string
      in
      let current_before =
        Workspace_store.Durable.read_current store identity
        |> require_ok Workspace_store.error_to_string
      in
      let changed =
        Workspace_store.Durable.materialise ~store ~scratch:fixture.scratch
          ~root ~workspace:identity ~observed_at:8L ~created_at:8L
          ~dry_run:false
          ~before_apply:(fun () ->
            write_file (Filename.concat root "dir/tracked") "external")
          ()
      in
      (match changed with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "external mutation was materialised");
      let head_after =
        Scratch.head_id fixture.scratch |> require_ok Scratch.error_to_string
      in
      let current_after =
        Workspace_store.Durable.read_current store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "external mutation leaves scratch head unchanged" true
        (Option.equal Scratch.Checkpoint_id.equal head_before head_after);
      Alcotest.(check int64)
        "external mutation leaves workspace ref unchanged"
        (Workspace_store.current_generation
           (Workspace_store.resolved_current_ref current_before))
        (Workspace_store.current_generation
           (Workspace_store.resolved_current_ref current_after)))

let materialisation_safety_checkpoint_preserves_exact_modes_and_symlinks () =
  with_store (fun root store ->
      let directory = Filename.concat root "dir" in
      Unix.mkdir directory 0o700;
      let tracked = Filename.concat directory "tracked" in
      let link = Filename.concat directory "link" in
      write_file tracked "base";
      Unix.chmod tracked 0o644;
      Unix.symlink "base-target" link;
      let scratch = Scratch.open_repository store in
      let base, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:base ~created_at:0L
        |> require_ok Scratch.error_to_string
        |> Scratch.Checkpoint.id
      in
      write_file tracked "target";
      Unix.chmod tracked 0o755;
      Unix.unlink link;
      Unix.symlink "target-link" link;
      let target, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let target_checkpoint = checkpoint scratch target 1L in
      let capsule = capsule_id 90 in
      ignore
        (Capsule_store.Durable.create_from_checkpoints ~store ~scratch
           ~id:capsule ~title:"exact" ~description:"exact" ~dependencies:[]
           ~evidence:[] ~from:initial ~target:target_checkpoint ~created_at:2L
           ~changed_at:2L ()
        |> require_ok Capsule_store.error_to_string);
      write_file tracked "outside";
      Unix.chmod tracked 0o644;
      Unix.unlink link;
      Unix.symlink "outside-link" link;
      let outside, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let workspace = workspace_id 91 in
      ignore
        (Workspace_store.Durable.create ~store ~id:workspace ~base ~name:None
           ~description:None ~created_at:3L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_revision ~store ~workspace
           ~revision:(current_capsule_revision store capsule)
           ~expected_generation:None ~created_at:4L
        |> require_ok Workspace_store.error_to_string);
      let materialised =
        Workspace_store.Durable.materialise ~store ~scratch ~root ~workspace
          ~observed_at:5L ~created_at:5L ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "attempt starts from the durable safety snapshot" true
        (Snapshot.Snapshot.equal_id outside
           (Workspace_store.attempt_starting_snapshot
              materialised.Workspace_store.Durable.attempt));
      Alcotest.(check string)
        "workspace materialises exact file bytes" "target"
        (In_channel.with_open_bin tracked In_channel.input_all);
      Alcotest.(check int)
        "workspace materialises executable mode" 0o755
        ((Unix.stat tracked).Unix.st_perm land 0o777);
      Alcotest.(check bool)
        "workspace materialises a symlink" true
        ((Unix.lstat link).Unix.st_kind = Unix.S_LNK);
      Alcotest.(check string)
        "workspace materialises exact symlink target" "target-link"
        (Unix.readlink link))

type localised_fixture = {
  local_scratch : Scratch.repository;
  local_base : Snapshot.Snapshot.id;
  local_capsule_a : Id.Capsule_id.t;
  local_capsule_c : Id.Capsule_id.t;
  local_capsule_b : Id.Capsule_id.t;
  local_tracked : string;
  local_other : string;
}

type reachable = {
  root : string;
  store : Store.repository;
  workspace : Id.Workspace_id.t;
  object_id : Store.Stored_object_id.t;
}

let make_localised_fixture root store =
  Unix.mkdir (Filename.concat root "dir") 0o700;
  let tracked = Filename.concat root "dir/tracked" in
  let other = Filename.concat root "dir/other" in
  write_file tracked "base";
  write_file other "base-other";
  let scratch = Scratch.open_repository store in
  let base, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let initial =
    Scratch.create_initial scratch ~snapshot:base ~created_at:0L
    |> require_ok Scratch.error_to_string
    |> Scratch.Checkpoint.id
  in
  let create_current ~id ~title ~time =
    let target, _ =
      Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
    in
    let target = checkpoint scratch target time in
    Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id ~title
      ~description:title ~dependencies:[] ~evidence:[] ~from:initial ~target
      ~created_at:(Int64.succ time) ~changed_at:(Int64.succ time) ()
    |> require_ok Capsule_store.error_to_string
  in
  write_file tracked "a";
  let capsule_a = capsule_id 110 in
  ignore (create_current ~id:capsule_a ~title:"a" ~time:1L);
  write_file tracked "base";
  let reverted_a, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  ignore (checkpoint scratch reverted_a 3L);
  write_file tracked "c";
  let capsule_c = capsule_id 120 in
  ignore (create_current ~id:capsule_c ~title:"c" ~time:4L);
  write_file tracked "base";
  let reverted_c, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  ignore (checkpoint scratch reverted_c 6L);
  write_file other "b-other";
  let capsule_b = capsule_id 130 in
  ignore (create_current ~id:capsule_b ~title:"b" ~time:7L);
  {
    local_scratch = scratch;
    local_base = base;
    local_capsule_a = capsule_a;
    local_capsule_c = capsule_c;
    local_capsule_b = capsule_b;
    local_tracked = tracked;
    local_other = other;
  }

let create_workspace store (fixture : localised_fixture) identity =
  Workspace_store.Durable.create ~store ~id:identity ~base:fixture.local_base
    ~name:None ~description:None ~created_at:20L
  |> require_ok Workspace_store.error_to_string

let selected_order revision =
  Workspace_store.revision_resolved_order revision
  |> List.map Id.Capsule_revision_id.to_hex

let non_overlapping_capsules_compose_and_reopen () =
  with_store (fun root store ->
      let fixture = make_localised_fixture root store in
      let identity = workspace_id 131 in
      ignore (create_workspace store fixture identity);
      ignore
        (Workspace_store.Durable.enable_current_capsule ~store
           ~workspace:identity ~capsule:fixture.local_capsule_a
           ~expected_generation:None ~created_at:21L
        |> require_ok Workspace_store.error_to_string);
      let selected =
        Workspace_store.Durable.enable_current_capsule ~store
          ~workspace:identity ~capsule:fixture.local_capsule_b
          ~expected_generation:None ~created_at:22L
        |> require_ok Workspace_store.error_to_string
      in
      let before_order =
        selected_order (Workspace_store.resolved_revision selected)
      in
      let materialised =
        Workspace_store.Durable.materialise ~store
          ~scratch:fixture.local_scratch ~root ~workspace:identity
          ~observed_at:23L ~created_at:23L ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "non-overlapping application is complete" false
        materialised.Workspace_store.Durable.partial;
      Alcotest.(check string)
        "first capsule exact bytes" "a"
        (In_channel.with_open_bin fixture.local_tracked In_channel.input_all);
      Alcotest.(check string)
        "second capsule exact bytes" "b-other"
        (In_channel.with_open_bin fixture.local_other In_channel.input_all);
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened =
        Workspace_store.Durable.read_current reopened_store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check (list string))
        "selection order survives reopen" before_order
        (selected_order (Workspace_store.resolved_revision reopened));
      Alcotest.(check int)
        "both selections survive reopen" 2
        (List.length
           (Workspace_store.revision_selected
              (Workspace_store.resolved_revision reopened)));
      Alcotest.(check int)
        "complete composition has no conflicts" 0
        (List.length
           (Workspace_store.Durable.list_conflicts reopened_store identity
           |> require_ok Workspace_store.error_to_string)))

let unresolved_conflicts_leave_independent_work_usable () =
  with_store (fun root store ->
      let fixture = make_localised_fixture root store in
      let identity = workspace_id 132 in
      ignore (create_workspace store fixture identity);
      ignore
        (Workspace_store.Durable.enable_current_capsule ~store
           ~workspace:identity ~capsule:fixture.local_capsule_a
           ~expected_generation:None ~created_at:21L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_current_capsule ~store
           ~workspace:identity ~capsule:fixture.local_capsule_c
           ~expected_generation:None ~created_at:22L
        |> require_ok Workspace_store.error_to_string);
      let selected =
        Workspace_store.Durable.enable_current_capsule ~store
          ~workspace:identity ~capsule:fixture.local_capsule_b
          ~expected_generation:None ~created_at:23L
        |> require_ok Workspace_store.error_to_string
      in
      let revision = Workspace_store.resolved_revision selected in
      ignore
        (Workspace_store.Durable.reorder ~store ~workspace:identity
           ~order:
             [
               selected_revision revision fixture.local_capsule_a;
               selected_revision revision fixture.local_capsule_c;
               selected_revision revision fixture.local_capsule_b;
             ]
           ~expected_generation:None ~created_at:24L
        |> require_ok Workspace_store.error_to_string);
      let materialised =
        Workspace_store.Durable.materialise ~store
          ~scratch:fixture.local_scratch ~root ~workspace:identity
          ~observed_at:25L ~created_at:25L ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "one local conflict keeps attempt partial" true
        materialised.Workspace_store.Durable.partial;
      Alcotest.(check string)
        "prior exact operation remains usable" "a"
        (In_channel.with_open_bin fixture.local_tracked In_channel.input_all);
      Alcotest.(check string)
        "independent operation applies around conflict" "b-other"
        (In_channel.with_open_bin fixture.local_other In_channel.input_all);
      let conflicts =
        Workspace_store.Durable.list_conflicts store identity
        |> require_ok Workspace_store.error_to_string
      in
      let conflict =
        match conflicts with
        | [ conflict ] -> conflict
        | _ -> Alcotest.fail "expected one persistent localized conflict"
      in
      let note = Filename.concat root "dir/note" in
      write_file note "still-usable";
      let note_snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      ignore (checkpoint fixture.local_scratch note_snapshot 26L);
      ignore
        (Workspace_store.Durable.explain_order store identity
        |> require_ok Workspace_store.error_to_string);
      let generation =
        Workspace_store.Durable.read_current store identity
        |> require_ok Workspace_store.error_to_string
        |> Workspace_store.resolved_current_ref
        |> Workspace_store.current_generation
      in
      ignore
        (Workspace_store.Durable.disable_capsule ~store ~workspace:identity
           ~capsule:fixture.local_capsule_b ~expected_generation:None
           ~created_at:27L
        |> require_ok Workspace_store.error_to_string);
      (match
         Workspace_store.Durable.resolve_skip ~store ~workspace:identity
           ~conflict:(Workspace_store.conflict_id conflict)
           ~expected_generation:(Some generation) ~created_at:28L
       with
      | Error error
        when String.starts_with ~prefix:"workspace "
               (Workspace_store.error_to_string error) ->
          ()
      | Error error -> Alcotest.fail (Workspace_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stale resolution CAS was accepted");
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened_conflicts =
        Workspace_store.Durable.list_conflicts reopened_store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check int)
        "unresolved conflict survives reopen" 1
        (List.length reopened_conflicts);
      ignore
        (Workspace_store.Durable.show_conflict reopened_store
           (Workspace_store.conflict_id conflict)
        |> require_ok Workspace_store.error_to_string))

let two_ref_recovery_republishes_after_workspace_cas_failure () =
  with_store (fun root store ->
      let ({ scratch; base; capsule_a; _ } : fixture) =
        make_fixture root store
      in
      let identity = workspace_id 133 in
      ignore
        (Workspace_store.Durable.create ~store ~id:identity ~base ~name:None
           ~description:None ~created_at:20L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_current_capsule ~store
           ~workspace:identity ~capsule:capsule_a ~expected_generation:None
           ~created_at:21L
        |> require_ok Workspace_store.error_to_string);
      let current =
        Workspace_store.Durable.read_current store identity
        |> require_ok Workspace_store.error_to_string
      in
      let current_ref = Workspace_store.resolved_current_ref current in
      let ref_components = Workspace_store.current_ref_components identity in
      let ref_bytes =
        Store.Ref_file.read store ~components:ref_components
        |> require_ok Store.error_to_string
      in
      let ref_bytes = Option.get ref_bytes in
      let head_before =
        Scratch.head_id scratch |> require_ok Scratch.error_to_string
      in
      let interrupted =
        Workspace_store.Durable.materialise ~store ~scratch ~root
          ~workspace:identity ~observed_at:22L ~created_at:22L ~dry_run:false
          ~before_apply:(fun () ->
            let next =
              Workspace_store.make_current_ref
                ~generation:
                  (Int64.succ (Workspace_store.current_generation current_ref))
                ~workspace:identity
                ~workspace_object:
                  (Workspace_store.resolved_workspace_object current)
                ~revision:(Workspace_store.current_revision current_ref)
                ~revision_object:
                  (Workspace_store.current_revision_object current_ref)
                ~latest_attempt:None
              |> require_ok Workspace_store.error_to_string
            in
            Store.Ref_file.compare_and_swap store ~components:ref_components
              ~expected:(Some ref_bytes)
              ~replacement:(Workspace_store.encode_current_ref next)
            |> require_ok Store.error_to_string)
          ()
      in
      (match interrupted with
      | Error error
        when String.starts_with ~prefix:"workspace "
               (Workspace_store.error_to_string error) ->
          ()
      | Error error -> Alcotest.fail (Workspace_store.error_to_string error)
      | Ok _ -> Alcotest.fail "workspace CAS failure was accepted");
      let head_after =
        Scratch.head_id scratch |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "scratch head advances before workspace ref" false
        (Option.equal Scratch.Checkpoint_id.equal head_before head_after);
      Alcotest.(check string)
        "exact result remains after interrupted ref update" "a"
        (In_channel.with_open_bin
           (Filename.concat root "dir/tracked")
           In_channel.input_all);
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened_scratch = Scratch.open_repository reopened_store in
      let reopened =
        Workspace_store.Durable.read_current reopened_store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "interrupted workspace ref records no attempt" true
        (Option.is_none
           (Workspace_store.current_latest_attempt
              (Workspace_store.resolved_current_ref reopened)));
      let retried =
        Workspace_store.Durable.materialise ~store:reopened_store
          ~scratch:reopened_scratch ~root ~workspace:identity ~observed_at:23L
          ~created_at:23L ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "retry is complete" false retried.Workspace_store.Durable.partial;
      let recovered =
        Workspace_store.Durable.read_current reopened_store identity
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "retry republishes immutable attempt" true
        (Option.is_some
           (Workspace_store.current_latest_attempt
              (Workspace_store.resolved_current_ref recovered))))

let assert_reopen_rejects root workspace =
  let reopened_store =
    Store.open_repository ~root |> require_ok Store.error_to_string
  in
  match Workspace_store.Durable.read_current reopened_store workspace with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "corrupt reachable workspace state was accepted"

let prepare_complete_workspace root store identity =
  let ({ scratch; base; capsule_a; _ } : fixture) = make_fixture root store in
  ignore
    (Workspace_store.Durable.create ~store ~id:identity ~base ~name:None
       ~description:None ~created_at:20L
    |> require_ok Workspace_store.error_to_string);
  ignore
    (Workspace_store.Durable.enable_current_capsule ~store ~workspace:identity
       ~capsule:capsule_a ~expected_generation:None ~created_at:21L
    |> require_ok Workspace_store.error_to_string);
  ignore
    (Workspace_store.Durable.materialise ~store ~scratch ~root
       ~workspace:identity ~observed_at:22L ~created_at:22L ~dry_run:false ()
    |> require_ok Workspace_store.error_to_string);
  Workspace_store.Durable.read_current store identity
  |> require_ok Workspace_store.error_to_string

let prepare_conflicted_workspace root store identity =
  let ({ scratch; base; capsule_a; capsule_c; _ } : fixture) =
    make_fixture root store
  in
  ignore
    (Workspace_store.Durable.create ~store ~id:identity ~base ~name:None
       ~description:None ~created_at:20L
    |> require_ok Workspace_store.error_to_string);
  ignore
    (Workspace_store.Durable.enable_current_capsule ~store ~workspace:identity
       ~capsule:capsule_a ~expected_generation:None ~created_at:21L
    |> require_ok Workspace_store.error_to_string);
  ignore
    (Workspace_store.Durable.enable_current_capsule ~store ~workspace:identity
       ~capsule:capsule_c ~expected_generation:None ~created_at:22L
    |> require_ok Workspace_store.error_to_string);
  let materialisation =
    Workspace_store.Durable.materialise ~store ~scratch ~root
      ~workspace:identity ~observed_at:23L ~created_at:23L ~dry_run:false ()
    |> require_ok Workspace_store.error_to_string
  in
  ( Workspace_store.Durable.read_current store identity
    |> require_ok Workspace_store.error_to_string,
    materialisation )

let workspace_ref_corruption_rejects_after_reopen () =
  with_store (fun root store ->
      let identity = workspace_id 134 in
      ignore (prepare_complete_workspace root store identity);
      let components = Workspace_store.current_ref_components identity in
      let bytes =
        Store.Ref_file.read store ~components
        |> require_ok Store.error_to_string
        |> Option.get |> Bytes.of_string
      in
      Bytes.set bytes 0 (if Bytes.get bytes 0 = '\000' then '\001' else '\000');
      Store.Ref_file.compare_and_swap store ~components
        ~expected:
          (Store.Ref_file.read store ~components
          |> require_ok Store.error_to_string)
        ~replacement:(Bytes.unsafe_to_string bytes)
      |> require_ok Store.error_to_string;
      assert_reopen_rejects root identity)

let reachable_object_corruption_rejects_after_reopen () =
  let corrupt reachable =
    write_file (Store.object_path reachable.store reachable.object_id) "corrupt";
    assert_reopen_rejects reachable.root reachable.workspace
  in
  let workspace_case () =
    with_store (fun root store ->
        let workspace = workspace_id 135 in
        let resolved = prepare_complete_workspace root store workspace in
        corrupt
          {
            root;
            store;
            workspace;
            object_id = Workspace_store.resolved_workspace_object resolved;
          })
  in
  let revision_case () =
    with_store (fun root store ->
        let workspace = workspace_id 136 in
        let resolved = prepare_complete_workspace root store workspace in
        corrupt
          {
            root;
            store;
            workspace;
            object_id = Workspace_store.resolved_revision_object resolved;
          })
  in
  let attempt_case () =
    with_store (fun root store ->
        let workspace = workspace_id 137 in
        let resolved = prepare_complete_workspace root store workspace in
        let _, object_id =
          Workspace_store.current_latest_attempt
            (Workspace_store.resolved_current_ref resolved)
          |> Option.get
        in
        corrupt { root; store; workspace; object_id })
  in
  let conflict_case () =
    with_store (fun root store ->
        let workspace = workspace_id 138 in
        let _, materialisation =
          prepare_conflicted_workspace root store workspace
        in
        let _, object_id =
          List.hd materialisation.Workspace_store.Durable.conflicts
        in
        corrupt { root; store; workspace; object_id })
  in
  let resolution_case () =
    with_store (fun root store ->
        let workspace = workspace_id 139 in
        let _, _ = prepare_conflicted_workspace root store workspace in
        let conflict =
          Workspace_store.Durable.list_conflicts store workspace
          |> require_ok Workspace_store.error_to_string
          |> List.hd
        in
        let resolved =
          Workspace_store.Durable.resolve_skip ~store ~workspace
            ~conflict:(Workspace_store.conflict_id conflict)
            ~expected_generation:None ~created_at:24L
          |> require_ok Workspace_store.error_to_string
        in
        let binding =
          Workspace_store.revision_resolutions
            (Workspace_store.resolved_revision resolved)
          |> List.hd
        in
        corrupt
          {
            root;
            store;
            workspace;
            object_id = binding.Workspace_store.binding_object_id;
          })
  in
  workspace_case ();
  revision_case ();
  attempt_case ();
  conflict_case ();
  resolution_case ()

let () =
  Alcotest.run "workspace persistence"
    [
      ( "durable",
        [
          Alcotest.test_case "create enable reopen stale CAS" `Quick
            work_create_enable_reopen_and_stale_cas;
          Alcotest.test_case "materialise conflict resolve" `Quick
            conflicts_materialise_and_resolve_immutably;
          Alcotest.test_case "canonical goldens and inverse decoders" `Quick
            schemas_have_canonical_goldens_and_inverse_decoders;
          Alcotest.test_case "external mutation aborts safely" `Quick
            external_mutation_aborts_without_ref_publication;
          Alcotest.test_case "safety checkpoint and exact modes/symlinks" `Quick
            materialisation_safety_checkpoint_preserves_exact_modes_and_symlinks;
          Alcotest.test_case "non-overlapping composition survives reopen"
            `Quick non_overlapping_capsules_compose_and_reopen;
          Alcotest.test_case "unresolved conflicts preserve unrelated work"
            `Quick unresolved_conflicts_leave_independent_work_usable;
          Alcotest.test_case "two-ref recovery republishes attempt" `Quick
            two_ref_recovery_republishes_after_workspace_cas_failure;
          Alcotest.test_case "workspace ref corruption rejects after reopen"
            `Quick workspace_ref_corruption_rejects_after_reopen;
          Alcotest.test_case "reachable object corruption rejects after reopen"
            `Quick reachable_object_corruption_rejects_after_reopen;
        ] );
    ]
