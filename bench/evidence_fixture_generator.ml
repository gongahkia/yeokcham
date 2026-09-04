module Fixture = Evidence_fixture

let fail message =
  prerr_endline ("evidence-fixture-generator: " ^ message);
  exit 2

let parse_int option value =
  match int_of_string_opt value with
  | Some result -> result
  | None -> fail (option ^ " must be an integer")

let parse_int64 option value =
  match Int64.of_string_opt value with
  | Some result -> result
  | None -> fail (option ^ " must be an integer")

let require option = function
  | Some value -> value
  | None -> fail (option ^ " is required")

let () =
  let root = ref None in
  let paths = ref None in
  let bytes = ref None in
  let specification =
    [
      ( "--root",
        Arg.String (fun value -> root := Some value),
        "absolute existing empty fixture directory" );
      ( "--paths",
        Arg.String (fun value -> paths := Some (parse_int "--paths" value)),
        "exact directory-plus-file entry count" );
      ( "--bytes",
        Arg.String (fun value -> bytes := Some (parse_int64 "--bytes" value)),
        "total regular-file bytes" );
    ]
  in
  Arg.parse specification
    (fun argument -> fail ("unexpected argument " ^ argument))
    "evidence_fixture_generator --root ABSOLUTE_EMPTY_DIRECTORY --paths COUNT \
     --bytes COUNT";
  let root = require "--root" !root in
  let path_count = require "--paths" !paths in
  let logical_bytes = require "--bytes" !bytes in
  let profile = Fixture.profile ~path_count ~logical_bytes in
  match Fixture.generate ~root profile with
  | Error error -> fail (Fixture.error_to_string error)
  | Ok layout ->
      Printf.printf
        "schema_version=1\n\
         root=%s\n\
         paths=%d\n\
         directories=%d\n\
         files=%d\n\
         logical_bytes=%Ld\n"
        root path_count
        (Fixture.directory_count layout)
        (Fixture.file_count layout)
        (Fixture.logical_bytes layout)
