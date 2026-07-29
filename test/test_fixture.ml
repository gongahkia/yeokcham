module Spec = Paengi_testkit.Fixture_spec
module Materializer = Paengi_testkit.Fixture_materializer
module Golden = Paengi_testkit.Golden_fixture
open! Spec

let is_executable = function Regular -> false | Executable -> true

let expect_valid fixture =
  match Spec.validate fixture with
  | Ok () -> ()
  | Error message -> Alcotest.fail message

let expect_invalid fixture =
  match Spec.validate fixture with
  | Ok () -> Alcotest.fail "fixture unexpectedly valid"
  | Error _ -> ()

let golden_hex_parser () =
  Alcotest.(check (result string string))
    "lowercase hex decodes" (Ok "\000\255")
    (Golden.decode_lower_hex "00ff");
  Alcotest.(check (result string string))
    "empty hex rejects" (Error "fixture hex is empty")
    (Golden.decode_lower_hex "");
  Alcotest.(check (result string string))
    "odd hex rejects" (Error "fixture hex has odd length: 1")
    (Golden.decode_lower_hex "0");
  Alcotest.(check (result string string))
    "uppercase hex rejects"
    (Error
       "fixture hex has invalid character 'F'; use lowercase hex at offset 0")
    (Golden.decode_lower_hex "F0");
  Alcotest.(check (result string string))
    "non-hex rejects"
    (Error
       "fixture hex has invalid character 'g'; use lowercase hex at offset 0")
    (Golden.decode_lower_hex "g0");
  Alcotest.(check (result string string))
    "low nibble offset is exact"
    (Error
       "fixture hex has invalid character 'F'; use lowercase hex at offset 1")
    (Golden.decode_lower_hex "0F")

let with_temporary_file contents check =
  let path = Filename.temp_file "paengi-golden-" ".hex" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let channel = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () -> output_string channel contents);
      check path)

let golden_file_shape () =
  with_temporary_file "00ff\n" (fun path ->
      Alcotest.(check (result string string))
        "one newline-terminated line reads" (Ok "\000\255")
        (Golden.read_lower_hex_file path));
  List.iter
    (fun contents ->
      with_temporary_file contents (fun path ->
          Alcotest.(check bool)
            "invalid fixture file rejects" true
            (Result.is_error (Golden.read_lower_hex_file path))))
    [ ""; "00ff"; "00ff\n\n"; "00FF\n" ]

let generated_edges () =
  let fixture = Spec.generate ~seed:7 in
  expect_valid fixture;
  let has predicate = List.exists predicate fixture in
  Alcotest.(check bool)
    "empty file" true
    (has (function
      | Spec.File { contents = ""; _ } -> true
      | Spec.File _ | Spec.Symlink _ -> false));
  Alcotest.(check bool)
    "executable" true
    (has (function
      | Spec.File file -> is_executable file.mode
      | Spec.Symlink _ -> false));
  Alcotest.(check bool)
    "symlink" true
    (has (function Spec.File _ -> false | Spec.Symlink _ -> true));
  Alcotest.(check bool)
    "non-UTF-8" true
    (has (function
      | Spec.File { contents; _ } -> String.contains contents '\255'
      | Spec.Symlink _ -> false));
  Alcotest.(check bool)
    "unicode path" true
    (has (fun entry ->
         let path =
           match entry with
           | Spec.File file -> file.file_path
           | Spec.Symlink link -> link.link_path
         in
         List.exists (String.equal "paëngi-한글.txt") path))

let invalid_paths () =
  expect_invalid
    [
      Spec.File
        { file_path = [ ".."; "escape" ]; contents = ""; mode = Regular };
    ];
  expect_invalid
    [
      Spec.File { file_path = [ "same" ]; contents = "a"; mode = Regular };
      Spec.File { file_path = [ "same" ]; contents = "b"; mode = Regular };
    ];
  expect_invalid
    [
      Spec.File { file_path = [ "parent" ]; contents = "a"; mode = Regular };
      Spec.File
        { file_path = [ "parent"; "child" ]; contents = "b"; mode = Regular };
    ];
  expect_invalid
    [
      Spec.File { file_path = [ "z" ]; contents = "a"; mode = Regular };
      Spec.File { file_path = [ "a" ]; contents = "b"; mode = Regular };
    ]

let read_file path = In_channel.with_open_bin path In_channel.input_all

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let materialises_without_overwrite () =
  let destination = Filename.temp_file "paengi-fixture-" "" in
  Unix.unlink destination;
  Fun.protect
    ~finally:(fun () ->
      remove_tree destination;
      remove_tree
        (Printf.sprintf "%s.paengi-fixture-%d" destination (Unix.getpid ())))
    (fun () ->
      let fixture = Spec.generate ~seed:19 in
      (match Materializer.write ~destination fixture with
      | Error message -> Alcotest.fail message
      | Ok () -> ());
      List.iter
        (function
          | Spec.File file ->
              let path =
                List.fold_left Filename.concat destination file.file_path
              in
              Alcotest.(check string)
                "exact contents" file.contents (read_file path);
              let executable = (Unix.stat path).Unix.st_perm land 0o111 <> 0 in
              Alcotest.(check bool) "mode" (is_executable file.mode) executable
          | Spec.Symlink link ->
              let path =
                List.fold_left Filename.concat destination link.link_path
              in
              Alcotest.(check bool)
                "symlink kind" true
                ((Unix.lstat path).Unix.st_kind = Unix.S_LNK);
              Alcotest.(check string)
                "symlink target"
                (String.concat Filename.dir_sep link.target)
                (Unix.readlink path))
        fixture;
      match Materializer.write ~destination fixture with
      | Ok () -> Alcotest.fail "existing destination was overwritten"
      | Error _ -> ())

let deterministic_property =
  QCheck2.Test.make ~count:200 ~name:"equal seeds produce valid equal fixtures"
    QCheck2.Gen.int (fun seed ->
      let left = Spec.generate ~seed in
      let right = Spec.generate ~seed in
      Spec.equal left right && Spec.validate left = Ok ())

let () =
  Alcotest.run "fixture"
    [
      ( "specification",
        [
          Alcotest.test_case "contains edge cases" `Quick generated_edges;
          Alcotest.test_case "rejects unsafe or noncanonical paths" `Quick
            invalid_paths;
          Alcotest.test_case "parses strict golden hex" `Quick golden_hex_parser;
          Alcotest.test_case "enforces golden file shape" `Quick
            golden_file_shape;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick deterministic_property;
        ] );
      ( "materializer",
        [
          Alcotest.test_case "writes exact fixture once" `Quick
            materialises_without_overwrite;
        ] );
    ]
