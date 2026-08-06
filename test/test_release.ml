module Capsule_store = Yeokcham_capsule_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Validation = Yeokcham_validation
module Workspace_store = Yeokcham_workspace_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let stored_id seed =
  Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get

let snapshot_id seed = Snapshot.Snapshot.of_stored_object_id (stored_id seed)
let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let workspace_id seed = Id.Workspace_id.of_bytes (raw_id seed) |> Result.get_ok

let workspace_revision_id seed =
  Id.Workspace_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let workspace_attempt_id seed =
  Id.Workspace_attempt_id.of_bytes (raw_id seed) |> Result.get_ok

let validation_id seed =
  Id.Validation_id.of_bytes (raw_id seed) |> Result.get_ok

let release_id seed = Id.Release_id.of_bytes (raw_id seed) |> Result.get_ok
let digest value = Hash.digest_string value |> Hash.to_raw_string

let empty_stream =
  { Validation.digest = digest ""; retained = ""; truncated = false }

let fake_result =
  ref
    {
      Validation.runner_status = Validation.Passed;
      runner_exit_code = Some 0;
      runner_signal = None;
      runner_execution_error = None;
      runner_duration_ms = 1L;
      runner_stdout = empty_stream;
      runner_stderr = empty_stream;
      runner_environment_fingerprint = None;
    }

module Fake_runner : Validation.Process_runner = struct
  let run _ ~working_directory:_ = !fake_result
end

let command () =
  {
    Validation.executable = "/usr/bin/true";
    arguments = [];
    working_directory = [];
    timeout_ms = 1000L;
    max_stdout_bytes = 128;
    max_stderr_bytes = 128;
    environment_policy = Validation.Empty;
    environment = [];
    retain_output = false;
    format_version = 1L;
    mandatory_features = 0L;
  }

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let with_root run =
  let root = Filename.temp_file "yeokcham-release-test-" "" in
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
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

type fixture = {
  root : string;
  store : Store.repository;
  scratch : Scratch.repository;
  workspace : Id.Workspace_id.t;
  initial : Scratch.Checkpoint_id.t;
  final_snapshot : Snapshot.Snapshot.id;
}

let checkpoint scratch snapshot time =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:time ~created_at:time
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let fixture root =
  write_file (Filename.concat root "tracked") "base";
  let store = Store.init ~root |> require_ok Store.error_to_string in
  let scratch = Scratch.open_repository store in
  let base, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let initial =
    Scratch.create_initial scratch ~snapshot:base ~created_at:0L
    |> require_ok Scratch.error_to_string
    |> Scratch.Checkpoint.id
  in
  write_file (Filename.concat root "tracked") "release";
  let target, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let target_checkpoint = checkpoint scratch target 1L in
  let capsule = capsule_id 10 in
  ignore
    (Capsule_store.Durable.create_from_checkpoints ~store ~scratch ~id:capsule
       ~title:"release" ~description:"fixture" ~dependencies:[] ~evidence:[]
       ~from:initial ~target:target_checkpoint ~created_at:2L ~changed_at:2L ()
    |> require_ok Capsule_store.error_to_string);
  let workspace = workspace_id 20 in
  ignore
    (Workspace_store.Durable.create ~store ~id:workspace ~base ~name:None
       ~description:None ~created_at:3L
    |> require_ok Workspace_store.error_to_string);
  ignore
    (Workspace_store.Durable.enable_current_capsule ~store ~workspace ~capsule
       ~expected_generation:None ~created_at:4L
    |> require_ok Workspace_store.error_to_string);
  let materialised =
    Workspace_store.Durable.materialise ~store ~scratch ~root ~workspace
      ~observed_at:5L ~created_at:5L ~dry_run:false ()
    |> require_ok Workspace_store.error_to_string
  in
  if materialised.Workspace_store.Durable.partial then
    Alcotest.fail "fixture conflicted";
  {
    root;
    store;
    scratch;
    workspace;
    initial;
    final_snapshot =
      Workspace_store.attempt_resulting_snapshot
        materialised.Workspace_store.Durable.attempt;
  }

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require_ok Fun.id

let hex bytes =
  let alphabet = "0123456789abcdef" in
  let output = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set output (index * 2) alphabet.[value lsr 4];
      Bytes.set output ((index * 2) + 1) alphabet.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string output

let release_fixture () =
  let capsule =
    Capsule_store.make_revision_link ~capsule:(capsule_id 30)
      ~revision:(revision_id 31) ~object_id:(stored_id 32)
  in
  let release =
    Release.create_release
      ~parents:[ release_id 33 ]
      ~workspace:(workspace_id 34)
      ~workspace_revision:(workspace_revision_id 35)
      ~workspace_revision_object:(stored_id 36)
      ~attempt:
        (Some
           {
             Release.attempt_id = workspace_attempt_id 37;
             attempt_object_id = stored_id 38;
           })
      ~base:(snapshot_id 39) ~capsules:[ capsule ] ~resolutions:[]
      ~final_snapshot:(snapshot_id 40)
      ~evidence:
        [
          {
            Release.evidence_id = validation_id 41;
            evidence_object_id = stored_id 42;
          };
        ]
      ~message:(Some "release fixture") ~created_at:9L
    |> require_ok Release.error_to_string
  in
  let payload =
    Release.release_payload release |> require_ok Release.error_to_string
  in
  let object_bytes =
    Envelope.create ~object_type:Envelope.Release ~object_format_version:1
      ~mandatory_features:0L ~payload ()
    |> require_ok Envelope.creation_error_to_string
    |> Envelope.encode
  in
  let binding =
    Release.make_binding
      ~release:(Release.release_id release)
      ~object_id:(stored_id 43)
    |> Release.encode_binding
  in
  (object_bytes, binding)

let canonical_goldens_and_inverse_decoders () =
  let object_bytes, binding = release_fixture () in
  Alcotest.(check string)
    "release golden"
    (refreshed_golden "release-v1.yeok.hex" object_bytes)
    object_bytes;
  Alcotest.(check string)
    "release binding golden"
    (refreshed_golden "release-v1.ref.hex" binding)
    binding;
  let envelope =
    Envelope.decode object_bytes |> require_ok Envelope.decode_error_to_string
  in
  let release =
    Release.decode_release_payload (Envelope.payload envelope)
    |> require_ok Release.error_to_string
  in
  let payload =
    Release.release_payload release |> require_ok Release.error_to_string
  in
  Alcotest.(check bool)
    "release inverse decoder" true
    (Encoding.equal payload (Envelope.payload envelope));
  ignore (Release.decode_binding binding |> require_ok Release.error_to_string)

let creation_reopen_reproduction_and_idempotency () =
  with_root (fun root ->
      let fixture = fixture root in
      fake_result :=
        { !fake_result with Validation.runner_status = Validation.Passed };
      let release =
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
          ~commands:[ command () ]
          ~message:(Some "release") ~observed_at:6L ~created_at:6L ()
        |> require_ok Release.error_to_string
      in
      Alcotest.(check bool)
        "final snapshot recorded" true
        (Snapshot.Snapshot.equal_id fixture.final_snapshot
           (Release.release_final_snapshot release));
      let reopened =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let verified =
        Release.Durable.verify reopened (Release.release_id release)
        |> require_ok Release.error_to_string
      in
      Alcotest.(check bool)
        "reopen verifies release" true
        (Id.Release_id.equal
           (Release.release_id release)
           (Release.release_id verified));
      let retry =
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:reopened ~workspace:fixture.workspace ~parents:[]
          ~commands:[ command () ]
          ~message:(Some "release") ~observed_at:7L ~created_at:7L ()
        |> require_ok Release.error_to_string
      in
      Alcotest.(check bool)
        "identical retry is idempotent" true
        (Id.Release_id.equal
           (Release.release_id release)
           (Release.release_id retry));
      let listed =
        Release.Durable.list reopened |> require_ok Release.error_to_string
      in
      Alcotest.(check int) "deterministic list" 1 (List.length listed);
      let anchor =
        Scratch.head_id fixture.scratch |> require_ok Scratch.error_to_string
      in
      let anchor = Option.get anchor in
      write_file
        (Filename.concat fixture.root "tracked")
        "later capsule revision";
      let later_snapshot, _ =
        Snapshot.scan ~root:fixture.root ~store:reopened
        |> require_ok Snapshot.error_to_string
      in
      let later_checkpoint = checkpoint fixture.scratch later_snapshot 8L in
      let current =
        Capsule_store.Durable.read_current reopened (capsule_id 10)
        |> require_ok Capsule_store.error_to_string
      in
      let current_ref = Capsule_store.Durable.resolved_current_ref current in
      ignore
        (Capsule_store.Durable.fold_from_checkpoints ~store:reopened
           ~scratch:fixture.scratch ~capsule:(capsule_id 10)
           ~expected_revision:(Capsule_store.current_revision current_ref)
           ~expected_generation:(Capsule_store.current_generation current_ref)
           ~evidence:[] ~from:anchor ~target:later_checkpoint ~created_at:8L
           ~changed_at:8L ()
        |> require_ok Capsule_store.error_to_string);
      ignore
        (Workspace_store.Durable.disable_capsule ~store:reopened
           ~workspace:fixture.workspace ~capsule:(capsule_id 10)
           ~expected_generation:None ~created_at:9L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Release.Durable.verify reopened (Release.release_id release)
        |> require_ok Release.error_to_string))

let failed_validation_and_interrupted_binding_are_invisible () =
  with_root (fun root ->
      let fixture = fixture root in
      fake_result :=
        {
          !fake_result with
          Validation.runner_status = Validation.Failed;
          runner_exit_code = Some 2;
        };
      (match
         Release.Durable.create
           ~runner:(module Fake_runner)
           ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
           ~commands:[ command () ]
           ~message:None ~observed_at:6L ~created_at:6L ()
       with
      | Error error
        when String.starts_with ~prefix:"required validation did not pass"
               (Release.error_to_string error) ->
          ()
      | Error error -> Alcotest.fail (Release.error_to_string error)
      | Ok _ -> Alcotest.fail "failed validation published a release");
      Alcotest.(check int)
        "failed validation leaves no visible release" 0
        (List.length
           (Release.Durable.list fixture.store
           |> require_ok Release.error_to_string));
      fake_result :=
        {
          !fake_result with
          Validation.runner_status = Validation.Passed;
          runner_exit_code = Some 0;
        };
      (match
         Release.Durable.create
           ~runner:(module Fake_runner)
           ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
           ~commands:[ command () ]
           ~message:None ~observed_at:7L ~created_at:7L
           ~fail_at:Release.Durable.Before_release_binding ()
       with
      | Error error
        when String.starts_with ~prefix:"injected interruption"
               (Release.error_to_string error) ->
          ()
      | Error error -> Alcotest.fail (Release.error_to_string error)
      | Ok _ -> Alcotest.fail "interrupted release bound");
      Alcotest.(check int)
        "interruption leaves no visible release" 0
        (List.length
           (Release.Durable.list fixture.store
           |> require_ok Release.error_to_string)))

let unresolved_conflicts_reject () =
  with_root (fun root ->
      let fixture = fixture root in
      write_file (Filename.concat root "tracked") "conflicting";
      let conflict_snapshot, _ =
        Snapshot.scan ~root ~store:fixture.store
        |> require_ok Snapshot.error_to_string
      in
      let conflict_checkpoint =
        checkpoint fixture.scratch conflict_snapshot 6L
      in
      let conflicting_capsule = capsule_id 11 in
      ignore
        (Capsule_store.Durable.create_from_checkpoints ~store:fixture.store
           ~scratch:fixture.scratch ~id:conflicting_capsule ~title:"conflict"
           ~description:"fixture" ~dependencies:[] ~evidence:[]
           ~from:fixture.initial ~target:conflict_checkpoint ~created_at:7L
           ~changed_at:7L ()
        |> require_ok Capsule_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_current_capsule ~store:fixture.store
           ~workspace:fixture.workspace ~capsule:conflicting_capsule
           ~expected_generation:None ~created_at:8L
        |> require_ok Workspace_store.error_to_string);
      let materialised =
        Workspace_store.Durable.materialise ~store:fixture.store
          ~scratch:fixture.scratch ~root ~workspace:fixture.workspace
          ~observed_at:9L ~created_at:9L ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      Alcotest.(check bool)
        "workspace conflict is explicit" true
        materialised.Workspace_store.Durable.partial;
      match
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
          ~commands:[ command () ]
          ~message:None ~observed_at:10L ~created_at:10L ()
      with
      | Error error
        when String.starts_with
               ~prefix:"workspace attempt has unresolved conflicts"
               (Release.error_to_string error) ->
          ()
      | Error error -> Alcotest.fail (Release.error_to_string error)
      | Ok _ -> Alcotest.fail "conflicted workspace published a release")

let wrong_type_evidence_link_rejects () =
  with_root (fun root ->
      let fixture = fixture root in
      fake_result :=
        { !fake_result with Validation.runner_status = Validation.Passed };
      let valid =
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
          ~commands:[ command () ]
          ~message:(Some "valid") ~observed_at:6L ~created_at:6L ()
        |> require_ok Release.error_to_string
      in
      let evidence = List.hd (Release.release_evidence valid) in
      let invalid =
        Release.create_release ~parents:[] ~workspace:fixture.workspace
          ~workspace_revision:(Release.release_workspace_revision valid)
          ~workspace_revision_object:
            (Release.release_workspace_revision_object valid)
          ~attempt:(Release.release_attempt valid)
          ~base:(Release.release_base valid)
          ~capsules:(Release.release_capsules valid)
          ~resolutions:(Release.release_resolutions valid)
          ~final_snapshot:(Release.release_final_snapshot valid)
          ~evidence:
            [
              {
                Release.evidence_id = evidence.Release.evidence_id;
                evidence_object_id =
                  Snapshot.Snapshot.stored_object_id fixture.final_snapshot;
              };
            ]
          ~message:(Some "wrong evidence object type") ~created_at:7L
        |> require_ok Release.error_to_string
      in
      let invalid_object =
        Release.store_release fixture.store invalid
        |> require_ok Release.error_to_string
      in
      Store.Ref_file.compare_and_swap fixture.store
        ~components:(Release.binding_components (Release.release_id invalid))
        ~expected:None
        ~replacement:
          (Release.make_binding
             ~release:(Release.release_id invalid)
             ~object_id:invalid_object
          |> Release.encode_binding)
      |> require_ok Store.error_to_string;
      match
        Release.Durable.verify fixture.store (Release.release_id invalid)
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "wrong-type evidence link verified")

let missing_and_cross_context_links_reject () =
  with_root (fun root ->
      let fixture = fixture root in
      fake_result :=
        { !fake_result with Validation.runner_status = Validation.Passed };
      let valid =
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
          ~commands:[ command () ]
          ~message:(Some "valid links") ~observed_at:6L ~created_at:6L ()
        |> require_ok Release.error_to_string
      in
      let evidence = List.hd (Release.release_evidence valid) in
      let forge ~workspace ~evidence_object ~message =
        Release.create_release ~parents:[] ~workspace
          ~workspace_revision:(Release.release_workspace_revision valid)
          ~workspace_revision_object:
            (Release.release_workspace_revision_object valid)
          ~attempt:(Release.release_attempt valid)
          ~base:(Release.release_base valid)
          ~capsules:(Release.release_capsules valid)
          ~resolutions:(Release.release_resolutions valid)
          ~final_snapshot:(Release.release_final_snapshot valid)
          ~evidence:
            [
              {
                Release.evidence_id = evidence.Release.evidence_id;
                evidence_object_id = evidence_object;
              };
            ]
          ~message:(Some message) ~created_at:7L
        |> require_ok Release.error_to_string
      in
      let publish release =
        let object_id =
          Release.store_release fixture.store release
          |> require_ok Release.error_to_string
        in
        Store.Ref_file.compare_and_swap fixture.store
          ~components:(Release.binding_components (Release.release_id release))
          ~expected:None
          ~replacement:
            (Release.make_binding
               ~release:(Release.release_id release)
               ~object_id
            |> Release.encode_binding)
        |> require_ok Store.error_to_string
      in
      let missing =
        forge ~workspace:fixture.workspace ~evidence_object:(stored_id 250)
          ~message:"missing evidence object"
      in
      publish missing;
      (match
         Release.Durable.verify fixture.store (Release.release_id missing)
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "missing evidence link verified");
      let cross_context =
        forge ~workspace:(workspace_id 251)
          ~evidence_object:evidence.Release.evidence_object_id
          ~message:"cross-context workspace link"
      in
      publish cross_context;
      match
        Release.Durable.verify fixture.store (Release.release_id cross_context)
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "cross-context workspace link verified")

let conflicting_binding_reuse_rejects () =
  with_root (fun root ->
      let fixture = fixture root in
      fake_result :=
        { !fake_result with Validation.runner_status = Validation.Passed };
      let visible =
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
          ~commands:[ command () ]
          ~message:(Some "binding conflict") ~observed_at:6L ~created_at:6L ()
        |> require_ok Release.error_to_string
      in
      let alternate =
        Release.create_release ~parents:[] ~workspace:fixture.workspace
          ~workspace_revision:(Release.release_workspace_revision visible)
          ~workspace_revision_object:
            (Release.release_workspace_revision_object visible)
          ~attempt:(Release.release_attempt visible)
          ~base:(Release.release_base visible)
          ~capsules:(Release.release_capsules visible)
          ~resolutions:(Release.release_resolutions visible)
          ~final_snapshot:(Release.release_final_snapshot visible)
          ~evidence:[]
          ~message:(Release.release_message visible)
          ~created_at:(Int64.succ (Release.release_created_at visible))
        |> require_ok Release.error_to_string
      in
      Alcotest.(check bool)
        "same composition has same logical release ID" true
        (Id.Release_id.equal
           (Release.release_id visible)
           (Release.release_id alternate));
      let alternate_object =
        Release.store_release fixture.store alternate
        |> require_ok Release.error_to_string
      in
      let rejected =
        Release.publish_binding fixture.store
          (Release.make_binding
             ~release:(Release.release_id alternate)
             ~object_id:alternate_object)
        |> Result.map_error Release.error_to_string
        |> function
        | Error message ->
            String.starts_with
              ~prefix:
                "release ID is already bound to different immutable content"
              message
        | Ok () -> false
      in
      Alcotest.(check bool) "conflicting release binding rejects" true rejected)

let deterministic_listing_and_show () =
  with_root (fun root ->
      let fixture = fixture root in
      fake_result :=
        { !fake_result with Validation.runner_status = Validation.Passed };
      let first =
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:fixture.store ~workspace:fixture.workspace ~parents:[]
          ~commands:[ command () ]
          ~message:(Some "first") ~observed_at:6L ~created_at:6L ()
        |> require_ok Release.error_to_string
      in
      let second =
        Release.Durable.create
          ~runner:(module Fake_runner)
          ~store:fixture.store ~workspace:fixture.workspace
          ~parents:[ Release.release_id first ]
          ~commands:[ command () ]
          ~message:(Some "second") ~observed_at:7L ~created_at:7L ()
        |> require_ok Release.error_to_string
      in
      let listed =
        Release.Durable.list fixture.store |> require_ok Release.error_to_string
      in
      let actual = List.map Release.release_id listed in
      let expected = List.sort Id.Release_id.compare actual in
      Alcotest.(check bool)
        "release listing has canonical ID order" true
        (List.for_all2 Id.Release_id.equal actual expected);
      let shown =
        Release.Durable.read fixture.store (Release.release_id second)
        |> require_ok Release.error_to_string
      in
      Alcotest.(check bool)
        "release show reads bound immutable object" true
        (Id.Release_id.equal
           (Release.release_id second)
           (Release.release_id shown)))

let parent_resolver_closure_and_cycles () =
  let a = release_id 60 in
  let b = release_id 61 in
  let c = release_id 62 in
  let resolver id =
    if Id.Release_id.equal id a then Ok [ b ]
    else if Id.Release_id.equal id b then Ok [ c ]
    else Ok []
  in
  Alcotest.(check bool)
    "exact declared base satisfies requirement" true
    (Release.Requires_release.satisfied resolver ~base:a ~required:a
    |> require_ok Fun.id);
  Alcotest.(check bool)
    "verified ancestry contains ancestor" true
    (Release.Requires_release.satisfied resolver ~base:a ~required:c
    |> require_ok Fun.id);
  Alcotest.(check bool)
    "snapshot-equality cannot satisfy absent release" false
    (Release.Requires_release.satisfied resolver ~base:a
       ~required:(release_id 63)
    |> require_ok Fun.id);
  let cycle id = if Id.Release_id.equal id a then Ok [ b ] else Ok [ a ] in
  match Release.Parent_resolver.verify_acyclic cycle a with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "parent cycle accepted"

let () =
  match Sys.getenv_opt "YEOKCHAM_PRINT_RELEASE_GOLDENS" with
  | Some "1" ->
      let object_bytes, binding = release_fixture () in
      Printf.printf "%s\n%s\n" (hex object_bytes) (hex binding)
  | None | Some _ ->
      Alcotest.run "yeokcham_release"
        [
          ( "release",
            [
              Alcotest.test_case "canonical goldens and inverse decoders" `Quick
                canonical_goldens_and_inverse_decoders;
              Alcotest.test_case "creation reopen reproduction idempotency"
                `Quick creation_reopen_reproduction_and_idempotency;
              Alcotest.test_case "failed validation and interrupted binding"
                `Quick failed_validation_and_interrupted_binding_are_invisible;
              Alcotest.test_case "conflicts reject release publication" `Quick
                unresolved_conflicts_reject;
              Alcotest.test_case "wrong-type evidence link rejects" `Quick
                wrong_type_evidence_link_rejects;
              Alcotest.test_case "missing and cross-context links reject" `Quick
                missing_and_cross_context_links_reject;
              Alcotest.test_case "conflicting binding reuse rejects" `Quick
                conflicting_binding_reuse_rejects;
              Alcotest.test_case "deterministic listing and show" `Quick
                deterministic_listing_and_show;
              Alcotest.test_case "parent resolver closure and cycle seam" `Quick
                parent_resolver_closure_and_cycles;
            ] );
        ]
