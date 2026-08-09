module Encoding = Yeokcham_encoding
module Golden = Yeokcham_testkit.Golden_fixture
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
    ((function Object.Unknown_kind 4L -> true | _ -> false) [@warning "-4"])
    (frame ~kind:4L scratch);
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
          Alcotest.test_case "malformed or untyped payloads reject" `Quick
            malformed_or_untyped_payloads_reject;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "typed-object-snapshot-round-trip")
            arbitrary_snapshot_round_trip;
        ] );
    ]
