module Spec = Paengi_testkit.Fixture_spec
module Materializer = Paengi_testkit.Fixture_materializer
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
          QCheck_alcotest.to_alcotest ~speed_level:`Quick deterministic_property;
        ] );
      ( "materializer",
        [
          Alcotest.test_case "writes exact fixture once" `Quick
            materialises_without_overwrite;
        ] );
    ]
