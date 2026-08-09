module Model = Yeokcham_model
module Scanner = Yeokcham_v2_scanner
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

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

let with_root run =
  let root = Filename.temp_file "yeokcham-v2-scanner-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let exact_scan_preserves_bytes_modes_directories_and_symlinks () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      write_file
        (Filename.concat root ".yeokchamignore")
        "ignored\nnested/ignored\n";
      write_file (Filename.concat root "ignored") "excluded";
      let nested = Filename.concat root "nested" in
      Unix.mkdir nested 0o700;
      let executable = Filename.concat nested "run" in
      write_file executable "#!/bin/sh\000exact";
      Unix.chmod executable 0o700;
      write_file (Filename.concat nested "ignored") "excluded";
      Unix.symlink "target bytes" (Filename.concat root "link");
      let actual = Scanner.scan ~root |> require_ok Scanner.error_to_string in
      let expected =
        Model.Snapshot.of_entries
          [
            Model.File_path
              ( path [ ".yeokchamignore" ],
                {
                  Model.mode = Model.Regular;
                  content = "ignored\nnested/ignored\n";
                } );
            Model.File_path
              ( path [ "link" ],
                { Model.mode = Model.Symlink; content = "target bytes" } );
            Model.Directory_path (path [ "nested" ]);
            Model.File_path
              ( path [ "nested"; "run" ],
                {
                  Model.mode = Model.Executable;
                  content = "#!/bin/sh\000exact";
                } );
          ]
        |> require_ok Model.construction_error_to_string
      in
      Alcotest.(check bool)
        "exact scanner excludes metadata and ignored paths" true
        (Model.Snapshot.equal expected actual))

let unsafe_ignore_rule_rejects () =
  with_root (fun root ->
      write_file (Filename.concat root ".yeokchamignore") "../outside\n";
      match Scanner.scan ~root with
      | Error (Scanner.Invalid_ignore_path { line = 1; _ }) -> ()
      | Error error ->
          Alcotest.failf "wrong invalid-ignore error: %s"
            (Scanner.error_to_string error)
      | Ok _ -> Alcotest.fail "unsafe ignore rule unexpectedly scanned")
  [@warning "-4"]

let special_nodes_reject () =
  with_root (fun root ->
      let fifo = Filename.concat root "named-pipe" in
      Unix.mkfifo fifo 0o600;
      match Scanner.scan ~root with
      | Error (Scanner.Unsupported_file_type { kind = "fifo"; _ }) -> ()
      | Error error ->
          Alcotest.failf "wrong special-node error: %s"
            (Scanner.error_to_string error)
      | Ok _ -> Alcotest.fail "FIFO unexpectedly scanned")
  [@warning "-4"]

let () =
  Alcotest.run "V2 exact working-tree scanner"
    [
      ( "unit",
        [
          Alcotest.test_case "preserves exact filesystem entries" `Quick
            exact_scan_preserves_bytes_modes_directories_and_symlinks;
          Alcotest.test_case "unsafe ignore rule rejects" `Quick
            unsafe_ignore_rule_rejects;
          Alcotest.test_case "special nodes reject" `Quick special_nodes_reject;
        ] );
    ]
