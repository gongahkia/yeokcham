module Capsule = Yeokcham_v2_capsule
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module V2_model = Yeokcham_v2_model
module Workspace = Yeokcham_v2_workspace
module Record = Yeokcham_v2_workspace_record

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let snapshot content =
  Model.Snapshot.of_entries
    [
      Model.File_path
        (path [ "tracked" ], { Model.mode = Model.Regular; content });
    ]
  |> require_ok Model.construction_error_to_string

let opaque character =
  V2_model.Opaque_object_ref.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let workspace_id character =
  V2_model.Workspace_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let capsule_id character =
  V2_model.Capsule_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let snapshot_link snapshot reference : Capsule.snapshot_link =
  {
    Capsule.snapshot_id = Model.Snapshot.id snapshot;
    snapshot_ref = opaque reference;
  }

let capsule_revision () =
  let source = snapshot "before" in
  let target = snapshot "after" in
  let proposal =
    Capsule.propose ~from:source ~to_:target
    |> require_ok Capsule.proposal_error_to_string
  in
  let selected =
    Capsule.select proposal ~indices:[ 0 ]
    |> require_ok Capsule.selection_error_to_string
  in
  let capsule =
    Capsule.make_capsule ~id:(capsule_id 'c') ~title:"exact change"
      ~description:"bytes only" ~created_at:7L
    |> require_ok Capsule.error_to_string
  in
  let base = snapshot_link source 'a' in
  let expected_result = snapshot_link target 'b' in
  let boundary : Capsule.source_boundary =
    { Capsule.source_snapshot = base; target_snapshot = expected_result }
  in
  let revision =
    Capsule.make_initial_revision ~capsule ~capsule_ref:(opaque 'c')
      ~declared_base:base ~declared_base_snapshot:source ~expected_result
      ~selected ~source_boundary:boundary
    |> require_ok Capsule.error_to_string
  in
  let link =
    Capsule.make_revision_link
      ~capsule_id:(Capsule.capsule_id capsule)
      ~revision_id:(Capsule.revision_id revision)
      ~revision_ref:(opaque 'r')
  in
  (source, target, base, expected_result, link)

type records = {
  workspace : Record.workspace;
  revision : Record.workspace_revision;
  attempt : Record.workspace_attempt;
  conflict : Record.conflict;
  resolution : Record.resolution;
}

let records () =
  let _source, _target, base, expected_result, selected_link =
    capsule_revision ()
  in
  let workspace =
    Record.make_workspace ~id:(workspace_id 'w') ~title:"curation"
      ~description:"explicit order" ~created_at:11L
    |> require_ok Record.error_to_string
  in
  let revision =
    Record.make_workspace_revision ~workspace ~workspace_ref:(opaque 'w')
      ~parent:None ~base ~selected:[ selected_link ] ~precedence:[]
      ~resolved_order:[ selected_link ] ~resolutions:[] ~created_at:12L
    |> require_ok Record.error_to_string
  in
  let revision_link =
    Record.make_workspace_revision_link
      ~workspace_id:(Record.workspace_revision_workspace_id revision)
      ~revision_id:(Record.workspace_revision_id revision)
      ~revision_ref:(opaque 'v')
  in
  let attempt_id =
    Record.derive_attempt_id ~workspace:revision_link ~base
      ~ordered:[ selected_link ]
  in
  let attempt =
    Record.make_workspace_attempt ~id:attempt_id ~workspace:revision_link ~base
      ~ordered:[ selected_link ] ~resulting_snapshot:expected_result
      ~outcomes:
        [
          Record.Attempt_applied_exactly
            { revision = selected_link; operation_index = 0 };
        ]
      ~conflicts:[] ~created_at:13L
    |> require_ok Record.error_to_string
  in
  let source : Workspace.conflict =
    {
      Workspace.revision = selected_link;
      operation_index = 0;
      paths = [ path [ "tracked" ] ];
      cause = Model.Expected_content_mismatch (path [ "tracked" ]);
    }
  in
  let conflict =
    Record.make_conflict ~workspace:revision_link ~attempt:attempt_id ~source
      ~created_at:14L
    |> require_ok Record.error_to_string
  in
  let conflict_link =
    Record.make_conflict_link
      ~id:(Record.conflict_id conflict)
      ~object_ref:(opaque 'f')
  in
  let resolution =
    Record.make_resolution ~conflict:conflict_link ~source:conflict
      ~workspace:revision_link
      ~action:
        (Record.Skip_operation { revision = selected_link; operation_index = 0 })
      ~created_at:15L
    |> require_ok Record.error_to_string
  in
  ignore source;
  { workspace; revision; attempt; conflict; resolution }

let immutable_records_round_trip_and_frame_separate () =
  let values = records () in
  let check_round_trip name encode decode value =
    let encoded = encode value in
    let decoded = decode encoded |> require_ok Record.error_to_string in
    Alcotest.(check string) name encoded (encode decoded)
  in
  check_round_trip "workspace record canonical round trip"
    Record.encode_workspace Record.decode_workspace values.workspace;
  check_round_trip "workspace revision record canonical round trip"
    Record.encode_workspace_revision Record.decode_workspace_revision
    values.revision;
  check_round_trip "workspace attempt record canonical round trip"
    Record.encode_workspace_attempt Record.decode_workspace_attempt
    values.attempt;
  check_round_trip "conflict record canonical round trip" Record.encode_conflict
    Record.decode_conflict values.conflict;
  check_round_trip "resolution record canonical round trip"
    Record.encode_resolution Record.decode_resolution values.resolution;
  let check_frame name golden expected frame =
    let encoded = Object.encode frame in
    let decoded = Object.decode encoded |> require_ok Object.error_to_string in
    Alcotest.(check bool) name true (Object.kind decoded = expected);
    Alcotest.(check string)
      (name ^ " golden bytes") (read_golden golden) encoded
  in
  check_frame "workspace has a distinct typed object kind"
    "v2-object-workspace-frame-v1.cbor.hex" Object.Workspace
    (Object.workspace values.workspace);
  check_frame "workspace revision has a distinct typed object kind"
    "v2-object-workspace-revision-frame-v1.cbor.hex" Object.Workspace_revision
    (Object.workspace_revision values.revision);
  check_frame "workspace attempt has a distinct typed object kind"
    "v2-object-workspace-attempt-frame-v1.cbor.hex" Object.Workspace_attempt
    (Object.workspace_attempt values.attempt);
  check_frame "conflict has a distinct typed object kind"
    "v2-object-conflict-frame-v1.cbor.hex" Object.Conflict
    (Object.conflict values.conflict);
  check_frame "resolution has a distinct typed object kind"
    "v2-object-resolution-frame-v1.cbor.hex" Object.Resolution
    (Object.resolution values.resolution);
  let frame = Object.workspace_revision values.revision in
  let decoded =
    Object.decode (Object.encode frame) |> require_ok Object.error_to_string
  in
  match Object.workspace_revision_record decoded with
  | Some actual ->
      Alcotest.(check string)
        "workspace revision survives typed frame"
        (Record.encode_workspace_revision values.revision)
        (Record.encode_workspace_revision actual)
  | None -> Alcotest.fail "workspace revision decoded as another object kind"

let immutable_identity_and_exact_resolution_are_checked () =
  let values = records () in
  let wrong_id =
    V2_model.Workspace_attempt_id.of_bytes (String.make 32 'z')
    |> require_ok V2_model.identity_error_to_string
  in
  ((match
      Record.make_workspace_attempt ~id:wrong_id
        ~workspace:(Record.workspace_attempt_workspace values.attempt)
        ~base:(Record.workspace_attempt_base values.attempt)
        ~ordered:(Record.workspace_attempt_ordered values.attempt)
        ~resulting_snapshot:
          (Record.workspace_attempt_resulting_snapshot values.attempt)
        ~outcomes:(Record.workspace_attempt_outcomes values.attempt)
        ~conflicts:(Record.workspace_attempt_conflicts values.attempt)
        ~created_at:16L
    with
  | Error (Record.Invalid_identity _) -> ()
  | Error error -> Alcotest.fail (Record.error_to_string error)
  | Ok _ -> Alcotest.fail "workspace attempt accepted a mismatched immutable ID")
  [@warning "-4"]);
  let invalid_action =
    Record.Skip_operation
      {
        revision = Record.conflict_revision values.conflict;
        operation_index = Record.conflict_operation_index values.conflict + 1;
      }
  in
  let conflict_link =
    Record.make_conflict_link
      ~id:(Record.conflict_id values.conflict)
      ~object_ref:(opaque 'f')
  in
  (match
     Record.make_resolution ~conflict:conflict_link ~source:values.conflict
       ~workspace:(Record.workspace_attempt_workspace values.attempt)
       ~action:invalid_action ~created_at:17L
   with
  | Error Record.Invalid_resolution_target -> ()
  | Error error -> Alcotest.fail (Record.error_to_string error)
  | Ok _ -> Alcotest.fail "resolution rewrote a different operation")
  [@warning "-4"]

let () =
  Alcotest.run "V2 workspace immutable records"
    [
      ( "unit",
        [
          Alcotest.test_case "records round trip through separated frames"
            `Quick immutable_records_round_trip_and_frame_separate;
          Alcotest.test_case "immutable IDs and exact resolutions are checked"
            `Quick immutable_identity_and_exact_resolution_are_checked;
        ] );
    ]
