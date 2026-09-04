module Hook = Yeokcham_v4_hook
module Golden = Yeokcham_testkit.Golden_fixture

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Hook.error_to_string error)

let save_hook () =
  Hook.make ~event:Hook.Save ~argv:[ "/usr/bin/printf"; "%s"; "saved" ]
  |> require_ok

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> Result.get_ok

let hooks_are_canonical_and_sorted () =
  let save = save_hook () in
  let init =
    Hook.make ~event:Hook.Init ~argv:[ "/usr/bin/true" ] |> require_ok
  in
  let registry =
    Hook.empty |> fun registry ->
    Hook.add registry save |> require_ok |> fun registry ->
    Hook.add registry init |> require_ok
  in
  let bytes = Hook.encode registry in
  let decoded = Hook.decode bytes |> require_ok in
  Alcotest.(check string)
    "hooks re-encode canonically" bytes (Hook.encode decoded);
  let ids = Hook.hooks decoded |> List.map Hook.hook_id in
  Alcotest.(check (list string))
    "hooks sort by stable ID"
    (List.sort String.compare ids)
    ids

let hooks_v1_fixture_is_stable () =
  let registry = Hook.add Hook.empty (save_hook ()) |> require_ok in
  let expected = read_golden "v4/hooks-v1.cbor.hex" in
  Alcotest.(check string)
    "hooks-v1 canonical bytes" expected (Hook.encode registry);
  let decoded = Hook.decode expected |> require_ok in
  Alcotest.(check string)
    "hooks-v1 fixture decodes canonically" expected (Hook.encode decoded)

let invalid_argv_duplicates_and_encodings_refuse () =
  Alcotest.(check bool)
    "relative hook program refuses" true
    (Result.is_error (Hook.make ~event:Hook.Save ~argv:[ "echo"; "unsafe" ]));
  let hook = save_hook () in
  let registry = Hook.add Hook.empty hook |> require_ok in
  Alcotest.(check bool)
    "duplicate hook refuses" true
    (Result.is_error (Hook.add registry hook));
  let bytes = Hook.encode registry in
  let wrong_version = Bytes.of_string bytes in
  Bytes.set wrong_version 1 '\002';
  Alcotest.(check bool)
    "unsupported hook version refuses" true
    (Result.is_error (Hook.decode (Bytes.unsafe_to_string wrong_version)));
  Alcotest.(check bool)
    "unknown hook field shape refuses" true
    (Result.is_error (Hook.decode ("\x83" ^ bytes)))

let () =
  Alcotest.run "V4 hooks"
    [
      ( "pure registry",
        [
          Alcotest.test_case "hooks are canonical and sorted" `Quick
            hooks_are_canonical_and_sorted;
          Alcotest.test_case "hooks-v1 golden fixture remains stable" `Quick
            hooks_v1_fixture_is_stable;
          Alcotest.test_case "invalid inputs refuse" `Quick
            invalid_argv_duplicates_and_encodings_refuse;
        ] );
    ]
