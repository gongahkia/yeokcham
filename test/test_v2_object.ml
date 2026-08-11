module Encoding = Yeokcham_encoding
module Golden = Yeokcham_testkit.Golden_fixture
module Capsule = Yeokcham_v2_capsule
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Retention = Yeokcham_v2_retention
module V2_model = Yeokcham_v2_model

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "v2 typed-object property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require_ok Fun.id

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let snapshot content =
  Model.Snapshot.of_entries
    [ Model.File_path (path [ "a" ], { Model.mode = Model.Regular; content }) ]
  |> require_ok Model.construction_error_to_string

let ledger_event () =
  Ledger.decode (read_golden "v2-ref-ledger-event-v1.cbor.hex")
  |> require_ok Ledger.error_to_string

let object_ref character =
  V2_model.Opaque_object_ref.of_hex (String.make 64 character)
  |> require_ok V2_model.identity_error_to_string

let ref_name value = Ledger.Ref_name.of_string value |> require_ok Fun.id

let capsule_id character =
  V2_model.Capsule_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let capsule_records () =
  let source = snapshot "before" in
  let target = snapshot "after" in
  let proposal =
    Capsule.propose ~from:source ~to_:target
    |> require_ok Capsule.proposal_error_to_string
  in
  let selection =
    Capsule.select proposal ~indices:[ 0 ]
    |> require_ok Capsule.selection_error_to_string
  in
  let capsule =
    Capsule.make_capsule ~id:(capsule_id 'c') ~title:"exact"
      ~description:"bytes" ~created_at:17L
    |> require_ok Capsule.error_to_string
  in
  let source_link : Capsule.snapshot_link =
    {
      Capsule.snapshot_id = Model.Snapshot.id source;
      snapshot_ref = object_ref 'a';
    }
  in
  let target_link : Capsule.snapshot_link =
    {
      Capsule.snapshot_id = Model.Snapshot.id target;
      snapshot_ref = object_ref 'b';
    }
  in
  let boundary : Capsule.source_boundary =
    { Capsule.source_snapshot = source_link; target_snapshot = target_link }
  in
  let revision =
    Capsule.make_initial_revision ~capsule ~capsule_ref:(object_ref 'c')
      ~declared_base:source_link ~declared_base_snapshot:source
      ~expected_result:target_link ~selected:selection ~source_boundary:boundary
    |> require_ok Capsule.error_to_string
  in
  (capsule, revision)

let evolved_capsule_revision () =
  let capsule, initial = capsule_records () in
  let source = snapshot "before" in
  let later = snapshot "later" in
  let source_link = Capsule.revision_declared_base initial in
  let target_link = Capsule.revision_expected_result initial in
  let later_link : Capsule.snapshot_link =
    {
      Capsule.snapshot_id = Model.Snapshot.id later;
      snapshot_ref = object_ref 'd';
    }
  in
  let complete =
    Capsule.propose ~from:source ~to_:later
    |> require_ok Capsule.proposal_error_to_string
  in
  let parent =
    Capsule.make_revision_link
      ~capsule_id:(Capsule.capsule_id capsule)
      ~revision_id:(Capsule.revision_id initial)
      ~revision_ref:(object_ref 'e')
  in
  Capsule.make_revision ~capsule ~capsule_ref:(object_ref 'c')
    ~parent:(Some parent) ~declared_base:source_link
    ~declared_base_snapshot:source ~expected_result:later_link
    ~operations:(Capsule.proposal_operations complete)
    ~source_boundaries:
      [
        Capsule.revision_source_boundary initial;
        { Capsule.source_snapshot = target_link; target_snapshot = later_link };
      ]
    ~provenance:(Capsule.Folded parent) ~created_at:18L
  |> require_ok Capsule.error_to_string

let retention_frames_are_canonical_and_type_separated () =
  let protection =
    Retention.protection ~snapshot_ref:(object_ref 'a')
      ~action:Retention.Protect ~reason:Retention.User_pin
  in
  let protected_frame = Object.scratch_protection protection in
  let decoded_protection =
    Object.decode (Object.encode protected_frame)
    |> require_ok Object.error_to_string
  in
  Alcotest.(check bool)
    "protection frame preserves its kind" true
    (Object.kind decoded_protection = Object.Scratch_protection);
  (match Object.protection decoded_protection with
  | Some actual ->
      Alcotest.(check string)
        "protection frame round trips canonically"
        (Retention.encode_protection protection)
        (Retention.encode_protection actual)
  | None -> Alcotest.fail "protection frame decoded as another frame kind");
  let generation =
    Retention.make_generation
      ~source_ref:(ref_name "scratch-device")
      ~source_head:(Ledger.event_id (ledger_event ()))
      ~active_ref:(ref_name "scratch-compact-device-head")
      ~active_anchor:(Ledger.event_id (ledger_event ()))
      ~retired_refs:[ ref_name "scratch-device" ]
      ~cleanup_candidates:
        [
          {
            Retention.candidate_object_ref = object_ref 'b';
            candidate_kind = Retention.Ledger_event;
          };
          {
            Retention.candidate_object_ref = object_ref 'c';
            candidate_kind = Retention.Scratch_snapshot;
          };
        ]
    |> require_ok Retention.error_to_string
  in
  let generation_frame = Object.scratch_generation generation in
  let decoded_generation =
    Object.decode (Object.encode generation_frame)
    |> require_ok Object.error_to_string
  in
  Alcotest.(check bool)
    "generation frame preserves its kind" true
    (Object.kind decoded_generation = Object.Scratch_generation);
  match Object.generation decoded_generation with
  | Some actual ->
      Alcotest.(check string)
        "generation frame round trips canonically"
        (Retention.encode_generation generation)
        (Retention.encode_generation actual)
  | None -> Alcotest.fail "generation frame decoded as another frame kind"

let frame ?(kind = 1L) ?(features = 0L) payload =
  Encoding.array
    [
      Encoding.integer 1L;
      Encoding.integer kind;
      Encoding.bytes payload;
      Encoding.integer features;
    ]
  |> require_ok Encoding.construction_error_to_string
  |> Encoding.encode

let exact_frames_are_canonical_and_kind_separated () =
  let event = ledger_event () in
  let ledger_frame = Object.ledger_event event in
  let decoded_ledger =
    Object.decode (Object.encode ledger_frame)
    |> require_ok Object.error_to_string
  in
  Alcotest.(check bool)
    "ledger frame preserves ledger kind" true
    (Object.kind decoded_ledger = Object.Ledger_event);
  Alcotest.(check string)
    "ledger frame canonical golden"
    (read_golden "v2-object-ledger-frame-v1.cbor.hex")
    (Object.encode ledger_frame);
  let scratch = snapshot "x" in
  let scratch_frame = Object.scratch_snapshot scratch in
  let decoded_scratch =
    Object.decode (Object.encode scratch_frame)
    |> require_ok Object.error_to_string
  in
  Alcotest.(check bool)
    "scratch frame preserves scratch kind" true
    (Object.kind decoded_scratch = Object.Scratch_snapshot);
  Alcotest.(check string)
    "scratch frame canonical golden"
    (read_golden "v2-object-scratch-snapshot-frame-v1.cbor.hex")
    (Object.encode scratch_frame);
  match Object.snapshot decoded_scratch with
  | Some decoded ->
      Alcotest.(check bool)
        "exact scratch snapshot survives frame" true
        (Model.Snapshot.equal scratch decoded)
  | None -> Alcotest.fail "scratch frame decoded as a ledger frame"

let capsule_frames_are_canonical_and_kind_separated () =
  let capsule, revision = capsule_records () in
  let evolved_revision = evolved_capsule_revision () in
  let capsule_frame = Object.capsule capsule in
  let revision_frame = Object.capsule_revision revision in
  let evolved_revision_frame = Object.capsule_revision evolved_revision in
  let decoded_capsule =
    Object.decode (Object.encode capsule_frame)
    |> require_ok Object.error_to_string
  in
  let decoded_revision =
    Object.decode (Object.encode revision_frame)
    |> require_ok Object.error_to_string
  in
  Alcotest.(check bool)
    "capsule frame retains its kind" true
    (Object.kind decoded_capsule = Object.Capsule);
  Alcotest.(check bool)
    "capsule revision frame retains its kind" true
    (Object.kind decoded_revision = Object.Capsule_revision);
  Alcotest.(check string)
    "capsule frame canonical golden"
    (refreshed_golden "v2-object-capsule-frame-v1.cbor.hex"
       (Object.encode capsule_frame))
    (Object.encode capsule_frame);
  Alcotest.(check string)
    "capsule revision frame canonical golden"
    (refreshed_golden "v2-object-capsule-revision-frame-v1.cbor.hex"
       (Object.encode revision_frame))
    (Object.encode revision_frame);
  Alcotest.(check string)
    "evolved capsule revision frame canonical golden"
    (refreshed_golden "v2-object-capsule-revision-frame-v2.cbor.hex"
       (Object.encode evolved_revision_frame))
    (Object.encode evolved_revision_frame);
  match
    ( Object.capsule_record decoded_capsule,
      Object.capsule_revision_record decoded_revision )
  with
  | Some decoded_capsule, Some decoded_revision ->
      Alcotest.(check string)
        "capsule payload round trips"
        (Capsule.encode_capsule capsule)
        (Capsule.encode_capsule decoded_capsule);
      Alcotest.(check string)
        "revision payload round trips"
        (Capsule.encode_revision revision)
        (Capsule.encode_revision decoded_revision)
  | None, _ | _, None -> Alcotest.fail "capsule frame decoded as another kind"

let malformed_or_untyped_payloads_reject () =
  let scratch = snapshot "x" |> Model.Snapshot.canonical_bytes in
  let expect predicate encoded =
    match Object.decode encoded with
    | Error error when predicate error -> ()
    | Error error ->
        Alcotest.failf "wrong typed-object error: %s"
          (Object.error_to_string error)
    | Ok _ -> Alcotest.fail "malformed typed object unexpectedly decoded"
  in
  expect
    ((function Object.Unknown_kind 11L -> true | _ -> false) [@warning "-4"])
    (refreshed_golden
       "v2-object-scratch-snapshot-frame-v1.unknown-kind.cbor.hex"
       (frame ~kind:11L scratch));
  expect
    ((function Object.Unsupported_mandatory_features 1L -> true | _ -> false)
      [@warning "-4"])
    (frame ~features:1L scratch);
  expect
    ((function Object.Invalid_payload _ -> true | _ -> false) [@warning "-4"])
    (Ledger.encode (ledger_event ()));
  expect
    ((function Object.Snapshot_error _ -> true | _ -> false) [@warning "-4"])
    (frame "not a canonical snapshot")

let arbitrary_snapshot_round_trip =
  QCheck2.Test.make ~count:160
    ~name:"V2 typed scratch frames preserve generated exact snapshot bytes"
    QCheck2.Gen.(string_size (int_range 0 4096))
    (fun content ->
      let original = snapshot content in
      match
        Object.decode (Object.scratch_snapshot original |> Object.encode)
      with
      | Error _ -> false
      | Ok decoded -> (
          match Object.snapshot decoded with
          | None -> false
          | Some restored -> Model.Snapshot.equal original restored))

let () =
  Alcotest.run "V2 typed encrypted object frames"
    [
      ( "unit",
        [
          Alcotest.test_case "exact frames are canonical and type-separated"
            `Quick exact_frames_are_canonical_and_kind_separated;
          Alcotest.test_case "retention frames are canonical and type-separated"
            `Quick retention_frames_are_canonical_and_type_separated;
          Alcotest.test_case "capsule frames are canonical and type-separated"
            `Quick capsule_frames_are_canonical_and_kind_separated;
          Alcotest.test_case "malformed or untyped payloads reject" `Quick
            malformed_or_untyped_payloads_reject;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "typed-object-snapshot-round-trip")
            arbitrary_snapshot_round_trip;
        ] );
    ]
