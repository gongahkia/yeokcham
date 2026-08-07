module V2 = Yeokcham_v2_model

let default_seed = 20_260_729

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
let () = Printf.printf "v2 model property base seed: %d\n%!" base_seed

let kinds : (string * (module V2.Identity)) list =
  [
    ("repository", (module V2.Repository_id));
    ("organization", (module V2.Organization_id));
    ("account", (module V2.Account_id));
    ("device", (module V2.Device_id));
    ("opaque object reference", (module V2.Opaque_object_ref));
    ("ref event", (module V2.Ref_event_id));
  ]

let require_ok error_to_string = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_to_string error)

let raw character = String.make 32 character

let check_identity (name, (module Identity : V2.Identity)) =
  let value = raw name.[0] in
  let identity =
    require_ok V2.identity_error_to_string (Identity.of_bytes value)
  in
  Alcotest.(check string)
    (name ^ " byte round trip")
    value
    (Identity.to_bytes identity);
  let hex = Identity.to_hex identity in
  Alcotest.(check int) (name ^ " canonical hex length") 64 (String.length hex);
  let decoded = require_ok V2.identity_error_to_string (Identity.of_hex hex) in
  Alcotest.(check bool)
    (name ^ " hex round trip") true
    (Identity.equal identity decoded);
  Alcotest.(check string)
    (name ^ " short hex") (String.sub hex 0 12)
    (Identity.short_hex identity);
  let byte_length_error =
    match Identity.of_bytes (String.make 31 'x') with
    | Error error -> V2.identity_error_to_string error
    | Ok _ -> Alcotest.fail (name ^ " accepted a short byte identity")
  in
  Alcotest.(check string)
    (name ^ " short bytes reject")
    "identity must contain 32 bytes, got 31" byte_length_error;
  let uppercase_error =
    match Identity.of_hex (String.make 64 'A') with
    | Error error -> V2.identity_error_to_string error
    | Ok _ -> Alcotest.fail (name ^ " accepted uppercase hex")
  in
  Alcotest.(check string)
    (name ^ " noncanonical hex rejects")
    "identity hex has invalid lowercase hexadecimal character 'A' at 0"
    uppercase_error

let all_identities_are_distinct_and_canonical () =
  List.iter check_identity kinds

let verified_state_has_closed_references () =
  let repository =
    require_ok V2.identity_error_to_string (V2.Repository_id.of_bytes (raw 'r'))
  in
  let device =
    require_ok V2.identity_error_to_string (V2.Device_id.of_bytes (raw 'd'))
  in
  let object_a =
    require_ok V2.identity_error_to_string
      (V2.Opaque_object_ref.of_bytes (raw 'a'))
  in
  let object_b =
    require_ok V2.identity_error_to_string
      (V2.Opaque_object_ref.of_bytes (raw 'b'))
  in
  let event_a =
    require_ok V2.identity_error_to_string (V2.Ref_event_id.of_bytes (raw 'a'))
  in
  let event_b =
    require_ok V2.identity_error_to_string (V2.Ref_event_id.of_bytes (raw 'b'))
  in
  let ref_a = V2.Encrypted_ref_event.create ~id:event_a ~object_ref:object_a in
  let ref_b = V2.Encrypted_ref_event.create ~id:event_b ~object_ref:object_b in
  let local =
    require_ok V2.state_error_to_string
      (V2.create_local_state ~repository_id:repository ~device_id:device
         ~object_refs:[ object_a; object_b ] ~ref_events:[ ref_a; ref_b ])
  in
  let verified = require_ok V2.state_error_to_string (V2.verify local) in
  Alcotest.(check bool)
    "repository identity survives verification" true
    (V2.Repository_id.equal repository (V2.verified_repository_id verified));
  Alcotest.(check bool)
    "device identity survives verification" true
    (V2.Device_id.equal device (V2.verified_device_id verified));
  Alcotest.(check int)
    "verified objects" 2
    (List.length (V2.verified_object_refs verified));
  Alcotest.(check int)
    "verified ref events" 2
    (List.length (V2.verified_ref_events verified))

let noncanonical_and_dangling_state_rejects () =
  let repository =
    require_ok V2.identity_error_to_string (V2.Repository_id.of_bytes (raw 'r'))
  in
  let device =
    require_ok V2.identity_error_to_string (V2.Device_id.of_bytes (raw 'd'))
  in
  let object_a =
    require_ok V2.identity_error_to_string
      (V2.Opaque_object_ref.of_bytes (raw 'a'))
  in
  let object_b =
    require_ok V2.identity_error_to_string
      (V2.Opaque_object_ref.of_bytes (raw 'b'))
  in
  let event =
    require_ok V2.identity_error_to_string (V2.Ref_event_id.of_bytes (raw 'e'))
  in
  (match
     V2.create_local_state ~repository_id:repository ~device_id:device
       ~object_refs:[ object_b; object_a ] ~ref_events:[]
   with
  | Error error ->
      Alcotest.(check bool)
        "unordered objects are explicit" true
        (String.starts_with
           ~prefix:"opaque object references are not in canonical order"
           (V2.state_error_to_string error))
  | Ok _ -> Alcotest.fail "unordered object references were accepted");
  let dangling = V2.Encrypted_ref_event.create ~id:event ~object_ref:object_b in
  let local =
    require_ok V2.state_error_to_string
      (V2.create_local_state ~repository_id:repository ~device_id:device
         ~object_refs:[ object_a ] ~ref_events:[ dangling ])
  in
  match V2.verify local with
  | Error error ->
      Alcotest.(check bool)
        "dangling event is explicit" true
        (String.starts_with ~prefix:"encrypted ref event"
           (V2.state_error_to_string error))
  | Ok _ -> Alcotest.fail "dangling ref event was accepted"

let exact_raw_generator = QCheck2.Gen.(string_size (return 32))
let short_raw_generator = QCheck2.Gen.(string_size (0 -- 31))

let identity_round_trip_property =
  QCheck2.Test.make ~count:300
    ~name:"every v2 identity preserves exactly 32 arbitrary bytes"
    exact_raw_generator (fun bytes ->
      List.for_all
        (fun (_, (module Identity : V2.Identity)) ->
          match Identity.of_bytes bytes with
          | Error _ -> false
          | Ok identity -> (
              match Identity.of_hex (Identity.to_hex identity) with
              | Error _ -> false
              | Ok decoded ->
                  String.equal bytes (Identity.to_bytes decoded)
                  && Identity.equal identity decoded))
        kinds)

let short_identities_reject_property =
  QCheck2.Test.make ~count:100
    ~name:"every v2 identity rejects generated non-32-byte values"
    short_raw_generator (fun bytes ->
      List.for_all
        (fun (_, (module Identity : V2.Identity)) ->
          match Identity.of_bytes bytes with Error _ -> true | Ok _ -> false)
        kinds)

let () =
  Alcotest.run "v2 typed identities and repository state"
    [
      ( "unit",
        [
          Alcotest.test_case "identities are distinct and canonical" `Quick
            all_identities_are_distinct_and_canonical;
          Alcotest.test_case "verified state has closed references" `Quick
            verified_state_has_closed_references;
          Alcotest.test_case "noncanonical and dangling state rejects" `Quick
            noncanonical_and_dangling_state_rejects;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "identity-round-trip")
            identity_round_trip_property;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "short-identities")
            short_identities_reject_property;
        ] );
    ]
