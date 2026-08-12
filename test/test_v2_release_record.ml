module Capsule = Yeokcham_v2_capsule
module Encoding = Yeokcham_encoding
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Release = Yeokcham_v2_release_record
module V2_model = Yeokcham_v2_model
module Workspace_record = Yeokcham_v2_workspace_record

let default_seed = 20_260_812

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let state_for name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !value |]

let () = Printf.printf "v2 release-record property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
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

let workspace_revision_id character =
  V2_model.Workspace_revision_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let workspace_attempt_id character =
  V2_model.Workspace_attempt_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let capsule_id character =
  V2_model.Capsule_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let capsule_revision_id character =
  V2_model.Capsule_revision_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let snapshot_link content reference : Capsule.snapshot_link =
  let snapshot = snapshot content in
  {
    Capsule.snapshot_id = Model.Snapshot.id snapshot;
    snapshot_ref = opaque reference;
  }

type values = {
  evidence : Release.validation_evidence;
  evidence_link : Release.validation_evidence_link;
  release : Release.release;
}

let values ?(evidence_ref = 'e') ?(created_at = 31L) ?(observed_at = 29L) () =
  let base = snapshot_link "before" 'a' in
  let final_snapshot = snapshot_link "after" 'b' in
  let capsule =
    Capsule.make_revision_link ~capsule_id:(capsule_id 'c')
      ~revision_id:(capsule_revision_id 'd') ~revision_ref:(opaque 'f')
  in
  let workspace =
    Workspace_record.make_workspace_revision_link
      ~workspace_id:(workspace_id 'w')
      ~revision_id:(workspace_revision_id 'r')
      ~revision_ref:(opaque 'v')
  in
  let attempt =
    Release.make_workspace_attempt_link ~id:(workspace_attempt_id 't')
      ~object_ref:(opaque 'u')
  in
  let evidence =
    Release.make_validation_evidence ~snapshot:final_snapshot ~check_name:"unit"
      ~status:Release.Passed ~observed_at
    |> require_ok Release.error_to_string
  in
  let evidence_link =
    Release.make_validation_evidence_link
      ~id:(Release.validation_evidence_id evidence)
      ~object_ref:(opaque evidence_ref)
  in
  let release =
    Release.make_release ~parents:[] ~workspace ~attempt ~base
      ~capsules:[ capsule ] ~resolutions:[] ~final_snapshot
      ~evidence:[ evidence_link ] ~message:(Some "ready") ~created_at
    |> require_ok Release.error_to_string
  in
  { evidence; evidence_link; release }

let records_round_trip_and_frames_are_separate () =
  let values = values () in
  let check_round_trip name encode decode value =
    let encoded = encode value in
    let decoded = decode encoded |> require_ok Release.error_to_string in
    Alcotest.(check string) name encoded (encode decoded)
  in
  check_round_trip "validation evidence canonical round trip"
    Release.encode_validation_evidence Release.decode_validation_evidence
    values.evidence;
  check_round_trip "release canonical round trip" Release.encode_release
    Release.decode_release values.release;
  let check_frame name golden expected frame =
    let encoded = Object.encode frame in
    let decoded = Object.decode encoded |> require_ok Object.error_to_string in
    Alcotest.(check bool) (name ^ " kind") true (Object.kind decoded = expected);
    Alcotest.(check string)
      (name ^ " golden bytes")
      (refreshed_golden golden encoded)
      encoded
  in
  check_frame "validation evidence has a distinct typed object kind"
    "v2-object-validation-evidence-frame-v1.cbor.hex" Object.Validation_evidence
    (Object.validation_evidence values.evidence);
  check_frame "release has a distinct typed object kind"
    "v2-object-release-frame-v1.cbor.hex" Object.Release
    (Object.release values.release)

let logical_identity_excludes_observation_time_and_physical_evidence_link () =
  let original = values () in
  let moved = values ~evidence_ref:'z' ~created_at:99L ~observed_at:98L () in
  Alcotest.(check string)
    "evidence identity excludes observation time"
    (V2_model.Validation_id.to_hex
       (Release.validation_evidence_id original.evidence))
    (V2_model.Validation_id.to_hex
       (Release.validation_evidence_id moved.evidence));
  Alcotest.(check string)
    "release identity excludes evidence physical links and created time"
    (V2_model.Release_id.to_hex (Release.release_id original.release))
    (V2_model.Release_id.to_hex (Release.release_id moved.release));
  Alcotest.(check bool)
    "release persistence preserves those observations" false
    (String.equal
       (Release.encode_release original.release)
       (Release.encode_release moved.release))

let invalid_records_fail_closed () =
  let values = values () in
  ((match
      Release.make_validation_evidence
        ~snapshot:(Release.validation_evidence_snapshot values.evidence)
        ~check_name:"" ~status:Release.Passed ~observed_at:0L
    with
  | Error (Release.Invalid_payload _) -> ()
  | Error error -> Alcotest.fail (Release.error_to_string error)
  | Ok _ -> Alcotest.fail "empty validation check name was accepted")
  [@warning "-4"]);
  ((match
      Release.make_release ~parents:[]
        ~workspace:(Release.release_workspace values.release)
        ~attempt:(Release.release_attempt values.release)
        ~base:(Release.release_base values.release)
        ~capsules:(Release.release_capsules values.release)
        ~resolutions:[]
        ~final_snapshot:(Release.release_final_snapshot values.release)
        ~evidence:[]
        ~message:(Release.release_message values.release)
        ~created_at:0L
    with
  | Error (Release.Invalid_payload _) -> ()
  | Error error -> Alcotest.fail (Release.error_to_string error)
  | Ok _ -> Alcotest.fail "release without validation evidence was accepted")
  [@warning "-4"]);
  ((match
      Release.make_release ~parents:[]
        ~workspace:(Release.release_workspace values.release)
        ~attempt:(Release.release_attempt values.release)
        ~base:(Release.release_base values.release)
        ~capsules:(Release.release_capsules values.release)
        ~resolutions:[]
        ~final_snapshot:(Release.release_final_snapshot values.release)
        ~evidence:[ values.evidence_link; values.evidence_link ]
        ~message:(Release.release_message values.release)
        ~created_at:0L
    with
  | Error (Release.Invalid_payload _) -> ()
  | Error error -> Alcotest.fail (Release.error_to_string error)
  | Ok _ -> Alcotest.fail "duplicate validation evidence was accepted")
  [@warning "-4"]);
  let tampered =
    (match
       Encoding.decode (Release.encode_validation_evidence values.evidence)
     with
    | Ok
        (Encoding.Array
           [ version; _id; snapshot; check_name; status; observed_at; features ])
      ->
        Encoding.array
          [
            version;
            Encoding.bytes (String.make 32 'z');
            snapshot;
            check_name;
            status;
            observed_at;
            features;
          ]
        |> require_ok Encoding.construction_error_to_string
        |> Encoding.encode
    | Ok _ -> Alcotest.fail "validation evidence changed its known schema"
    | Error error -> Alcotest.fail (Encoding.decode_error_to_string error))
    [@warning "-4"]
  in
  ((match Release.decode_validation_evidence tampered with
  | Error (Release.Invalid_identity _) -> ()
  | Error error -> Alcotest.fail (Release.error_to_string error)
  | Ok _ -> Alcotest.fail "tampered validation identity was accepted")
  [@warning "-4"]);
  let unsupported_features =
    (match
       Encoding.decode (Release.encode_validation_evidence values.evidence)
     with
    | Ok
        (Encoding.Array
           [ version; id; snapshot; check_name; status; observed_at; _features ])
      ->
        Encoding.array
          [
            version;
            id;
            snapshot;
            check_name;
            status;
            observed_at;
            Encoding.integer 1L;
          ]
        |> require_ok Encoding.construction_error_to_string
        |> Encoding.encode
    | Ok _ -> Alcotest.fail "validation evidence changed its known schema"
    | Error error -> Alcotest.fail (Encoding.decode_error_to_string error))
    [@warning "-4"]
  in
  (match Release.decode_validation_evidence unsupported_features with
  | Error (Release.Unsupported_mandatory_features 1L) -> ()
  | Error error -> Alcotest.fail (Release.error_to_string error)
  | Ok _ -> Alcotest.fail "unknown validation feature was accepted")
  [@warning "-4"]

let generated_records_round_trip =
  QCheck2.Test.make ~count:64
    ~name:"V2 release records retain generated final snapshot bytes"
    QCheck2.Gen.(string_size (int_range 0 512))
    (fun content ->
      let final_snapshot = snapshot_link content 'b' in
      match
        Release.make_validation_evidence ~snapshot:final_snapshot
          ~check_name:"check" ~status:Release.Passed ~observed_at:1L
      with
      | Error _ -> false
      | Ok evidence ->
          Release.decode_validation_evidence
            (Release.encode_validation_evidence evidence)
          |> Result.is_ok)

let () =
  Alcotest.run "V2 immutable release records"
    [
      ( "unit",
        [
          Alcotest.test_case "records round trip through separated frames"
            `Quick records_round_trip_and_frames_are_separate;
          Alcotest.test_case "logical IDs omit observations and physical links"
            `Quick
            logical_identity_excludes_observation_time_and_physical_evidence_link;
          Alcotest.test_case "invalid evidence and releases fail closed" `Quick
            invalid_records_fail_closed;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "release-records")
            generated_records_round_trip;
        ] );
    ]
