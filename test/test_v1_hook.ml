module Hook = Yeokcham_v1_hook
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
  let actual = Hook.encode registry in
  let expected =
    Golden.refresh_lower_hex_file (golden_path "v1/hooks-v1.cbor.hex") actual
    |> Result.get_ok
  in
  Alcotest.(check string) "hooks-v1 canonical bytes" expected actual;
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
  Alcotest.run "V1 hooks"
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
