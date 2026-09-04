module Hook = Yeokcham_v4_hook

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Hook.error_to_string error)

let save_hook () =
  Hook.make ~event:Hook.Save ~argv:[ "/usr/bin/printf"; "%s"; "saved" ]
  |> require_ok

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
          Alcotest.test_case "invalid inputs refuse" `Quick
            invalid_argv_duplicates_and_encodings_refuse;
        ] );
    ]
