module Id = Paengi_id

let kinds : (string * (module Id.S)) list =
  [
    ("repository", (module Id.Repository_id));
    ("content", (module Id.Content_id));
    ("snapshot", (module Id.Snapshot_id));
    ("checkpoint", (module Id.Checkpoint_id));
    ("capsule", (module Id.Capsule_id));
    ("capsule revision", (module Id.Capsule_revision_id));
    ("release", (module Id.Release_id));
    ("conflict", (module Id.Conflict_id));
    ("operation", (module Id.Operation_id));
    ("device", (module Id.Device_id));
    ("validation", (module Id.Validation_id));
    ("resolution", (module Id.Resolution_id));
  ]

let require_ok error_to_string = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_to_string error)

let check_kind (name, (module Kind : Id.S)) =
  let raw = "\000\001\127\128\254\255paengi" in
  let identity = require_ok Id.parse_error_to_string (Kind.of_bytes raw) in
  Alcotest.(check string)
    (name ^ " byte round trip")
    raw (Kind.to_bytes identity);
  let encoded = Kind.to_hex identity in
  Alcotest.(check string)
    (name ^ " canonical hex") "00017f80feff7061656e6769" encoded;
  let decoded = require_ok Id.parse_error_to_string (Kind.of_hex encoded) in
  Alcotest.(check bool)
    (name ^ " hex round trip") true
    (Kind.equal identity decoded);
  Alcotest.(check string)
    (name ^ " short hex") "00017f80feff" (Kind.short_hex identity);
  let lower = require_ok Id.parse_error_to_string (Kind.of_bytes "a") in
  let upper = require_ok Id.parse_error_to_string (Kind.of_bytes "b") in
  Alcotest.(check bool) (name ^ " equality") true (Kind.equal lower lower);
  Alcotest.(check bool) (name ^ " inequality") false (Kind.equal lower upper);
  Alcotest.(check bool)
    (name ^ " comparison") true
    (Kind.compare lower upper < 0)

let all_kinds () = List.iter check_kind kinds

let parse_error =
  Alcotest.testable
    (fun formatter error ->
      Format.pp_print_string formatter (Id.parse_error_to_string error))
    ( = )

let error = function Ok _ -> None | Error parse_error -> Some parse_error

let invalid_inputs () =
  let module Kind = Id.Content_id in
  Alcotest.(check (option parse_error))
    "empty bytes" (Some Id.Empty)
    (error (Kind.of_bytes ""));
  Alcotest.(check (option parse_error))
    "empty hex" (Some Id.Empty)
    (error (Kind.of_hex ""));
  Alcotest.(check (option parse_error))
    "odd hex" (Some (Id.Odd_hex_length 3))
    (error (Kind.of_hex "abc"));
  Alcotest.(check (option parse_error))
    "invalid hex"
    (Some (Id.Invalid_hex_character (2, 'g')))
    (error (Kind.of_hex "00g0"));
  let uppercase = require_ok Id.parse_error_to_string (Kind.of_hex "A0FF") in
  Alcotest.(check string) "uppercase normalises" "a0ff" (Kind.to_hex uppercase)

let arbitrary_bytes = QCheck2.Gen.(string_size (1 -- 256))

let round_trip_property =
  QCheck2.Test.make ~count:500 ~name:"all ID kinds preserve arbitrary bytes"
    arbitrary_bytes (fun raw ->
      List.for_all
        (fun (_, (module Kind : Id.S)) ->
          match Kind.of_bytes raw with
          | Error _ -> false
          | Ok identity -> (
              match Kind.of_hex (Kind.to_hex identity) with
              | Error _ -> false
              | Ok decoded ->
                  String.equal raw (Kind.to_bytes decoded)
                  && Kind.equal identity decoded
                  && Kind.compare identity decoded = 0
                  && String.starts_with ~prefix:(Kind.short_hex identity)
                       (Kind.to_hex identity)))
        kinds)

let () =
  Alcotest.run "typed IDs"
    [
      ( "identity",
        [
          Alcotest.test_case "every kind" `Quick all_kinds;
          Alcotest.test_case "invalid inputs" `Quick invalid_inputs;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick round_trip_property;
        ] );
    ]
