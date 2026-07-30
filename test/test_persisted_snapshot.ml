module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Golden = Paengi_testkit.Golden_fixture
module Snapshot_store = Paengi_snapshot
module Store = Paengi_store
open Snapshot_store

let require_envelope = function
  | Ok envelope -> envelope
  | Error error -> Alcotest.fail (Envelope.creation_error_to_string error)

let require_ok error_to_string = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_to_string error)

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

let with_directory prefix run =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let with_store run =
  with_directory "paengi-snapshot-store-" (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      run root store)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let make_directory path = Unix.mkdir path 0o700

let stored_envelope store identity =
  Store.get store identity
  |> require_ok Store.error_to_string
  |> Envelope.encode

let require_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let find_entry name tree =
  match List.assoc_opt name (Snapshot_store.Tree.entries tree) with
  | Some entry -> entry
  | None -> Alcotest.fail (Printf.sprintf "missing tree entry %S" name)

let entry_names tree = List.map fst (Snapshot_store.Tree.entries tree)

let canonical_tree_order_and_reference_types () =
  with_store (fun _ store ->
      let left =
        Snapshot_store.Content.store store "shared"
        |> require_ok Snapshot_store.error_to_string
      in
      let right =
        Snapshot_store.Content.store store "other"
        |> require_ok Snapshot_store.error_to_string
      in
      let tree =
        Snapshot_store.Tree.create
          [
            ("z", Snapshot_store.Tree.File { mode = Regular; content = right });
            ("a", Snapshot_store.Tree.File { mode = Executable; content = left });
          ]
        |> require_ok Snapshot_store.error_to_string
      in
      let identity =
        Snapshot_store.Tree.store store tree
        |> require_ok Snapshot_store.error_to_string
      in
      let loaded =
        Snapshot_store.Tree.load store identity
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check (list string))
        "tree names are canonical" [ "a"; "z" ] (entry_names loaded);
      match find_entry "a" loaded with
      | Snapshot_store.Tree.File { mode = Executable; content } ->
          Alcotest.(check bool)
            "content identity is preserved" true
            (Snapshot_store.Content.equal_id left content)
      | Snapshot_store.Tree.File { mode = Regular | Symlink; _ }
      | Snapshot_store.Tree.Directory _ ->
          Alcotest.fail "stored tree entry changed")

let scanner_preserves_bytes_modes_symlinks_and_ignores () =
  with_directory "paengi-scan-" (fun root ->
      make_directory (Filename.concat root "nested");
      make_directory (Filename.concat root "ignored-directory");
      write_file (Filename.concat root "binary") "\000\255bytes";
      write_file (Filename.concat root "run") "#!/bin/sh\necho paengi\n";
      Unix.chmod (Filename.concat root "run") 0o755;
      write_file
        (Filename.concat (Filename.concat root "nested") "guide")
        "guide\n";
      Unix.symlink "nested/guide" (Filename.concat root "guide-link");
      write_file (Filename.concat root "ignored") "skip";
      write_file
        (Filename.concat (Filename.concat root "ignored-directory") "skip")
        "skip";
      write_file
        (Filename.concat root ".paengiignore")
        "ignored\nignored-directory\n";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let identity, snapshot =
        Snapshot_store.scan ~root ~store
        |> require_ok Snapshot_store.error_to_string
      in
      let duplicate, _ =
        Snapshot_store.scan ~root ~store
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check bool)
        "scan identity is deterministic" true
        (Snapshot_store.Snapshot.equal_id identity duplicate);
      let loaded =
        Snapshot_store.Snapshot.load store identity
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check bool)
        "snapshot root is preserved" true
        (Snapshot_store.Tree.equal_id
           (Snapshot_store.Snapshot.root snapshot)
           (Snapshot_store.Snapshot.root loaded));
      let root_tree =
        Snapshot_store.Tree.load store (Snapshot_store.Snapshot.root loaded)
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check (list string))
        "root entries"
        [ ".paengiignore"; "binary"; "guide-link"; "nested"; "run" ]
        (entry_names root_tree);
      (match find_entry "binary" root_tree with
      | Snapshot_store.Tree.File { mode = Regular; content } ->
          Alcotest.(check string)
            "binary bytes" "\000\255bytes"
            (Snapshot_store.Content.load store content
            |> require_ok Snapshot_store.error_to_string)
      | Snapshot_store.Tree.File { mode = Executable | Symlink; _ }
      | Snapshot_store.Tree.Directory _ ->
          Alcotest.fail "binary entry mode changed");
      (match find_entry "run" root_tree with
      | Snapshot_store.Tree.File { mode = Executable; content } ->
          Alcotest.(check string)
            "executable bytes" "#!/bin/sh\necho paengi\n"
            (Snapshot_store.Content.load store content
            |> require_ok Snapshot_store.error_to_string)
      | Snapshot_store.Tree.File { mode = Regular | Symlink; _ }
      | Snapshot_store.Tree.Directory _ ->
          Alcotest.fail "executable mode changed");
      match find_entry "guide-link" root_tree with
      | Snapshot_store.Tree.File { mode = Symlink; content } ->
          Alcotest.(check string)
            "symlink target bytes" "nested/guide"
            (Snapshot_store.Content.load store content
            |> require_ok Snapshot_store.error_to_string)
      | Snapshot_store.Tree.File { mode = Regular | Executable; _ }
      | Snapshot_store.Tree.Directory _ ->
          Alcotest.fail "symlink mode changed")

let duplicate_content_is_reused () =
  with_directory "paengi-content-reuse-" (fun root ->
      write_file (Filename.concat root "left") "same";
      write_file (Filename.concat root "right") "same";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let identity, _ =
        Snapshot_store.scan ~root ~store
        |> require_ok Snapshot_store.error_to_string
      in
      let snapshot =
        Snapshot_store.Snapshot.load store identity
        |> require_ok Snapshot_store.error_to_string
      in
      let tree =
        Snapshot_store.Tree.load store (Snapshot_store.Snapshot.root snapshot)
        |> require_ok Snapshot_store.error_to_string
      in
      match find_entry "left" tree with
      | Snapshot_store.Tree.File { content = left; _ } -> (
          match find_entry "right" tree with
          | Snapshot_store.Tree.File { content = right; _ } ->
              Alcotest.(check bool)
                "content object reused" true
                (Snapshot_store.Content.equal_id left right)
          | Snapshot_store.Tree.Directory _ ->
              Alcotest.fail "right file disappeared")
      | Snapshot_store.Tree.Directory _ -> Alcotest.fail "left file disappeared")

let malformed_tree_and_ignore_are_rejected () =
  with_store (fun _ store ->
      let content =
        Snapshot_store.Content.store store "valid"
        |> require_ok Snapshot_store.error_to_string
      in
      let entry name =
        Encoding.array
          [
            Encoding.integer 0L;
            Encoding.bytes name;
            Encoding.integer 0L;
            Encoding.bytes
              (Store.Stored_object_id.to_raw_bytes
                 (Snapshot_store.Content.stored_object_id content));
          ]
        |> require_ok Encoding.construction_error_to_string
      in
      let payload =
        Encoding.array
          [
            Encoding.integer 1L;
            Encoding.array [ entry "z"; entry "a" ]
            |> require_ok Encoding.construction_error_to_string;
          ]
        |> require_ok Encoding.construction_error_to_string
      in
      let envelope =
        Envelope.create ~object_type:Envelope.Tree
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
        |> require_envelope
      in
      let stored =
        Store.put store envelope |> require_ok Store.error_to_string
      in
      let typed = Snapshot_store.Tree.of_stored_object_id stored in
      match Snapshot_store.Tree.load store typed with
      | Error error ->
          Alcotest.(check bool)
            "unordered tree rejection" true
            (String.starts_with ~prefix:"tree names are not strictly ordered: "
               (Snapshot_store.error_to_string error))
      | Ok _ -> Alcotest.fail "unordered tree was accepted");
  with_directory "paengi-invalid-ignore-" (fun root ->
      write_file (Filename.concat root ".paengiignore") "../outside\n";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      match Snapshot_store.scan ~root ~store with
      | Error error ->
          Alcotest.(check string)
            "unsafe ignore rejection"
            "invalid .paengiignore path on line 1: \"../outside\""
            (Snapshot_store.error_to_string error)
      | Ok _ -> Alcotest.fail "unsafe ignore path was accepted")

let persisted_object_goldens () =
  with_store (fun _ store ->
      let content =
        Snapshot_store.Content.store store "golden\000bytes"
        |> require_ok Snapshot_store.error_to_string
      in
      let tree =
        Snapshot_store.Tree.create
          [ ("file", Snapshot_store.Tree.File { mode = Executable; content }) ]
        |> require_ok Snapshot_store.error_to_string
      in
      let tree_id =
        Snapshot_store.Tree.store store tree
        |> require_ok Snapshot_store.error_to_string
      in
      let snapshot = Snapshot_store.Snapshot.create ~root:tree_id in
      let snapshot_id =
        Snapshot_store.Snapshot.store store snapshot
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check string)
        "content golden"
        (require_golden "store-v1-content.peng.hex")
        (stored_envelope store
           (Snapshot_store.Content.stored_object_id content));
      Alcotest.(check string)
        "tree golden"
        (require_golden "store-v1-tree.peng.hex")
        (stored_envelope store (Snapshot_store.Tree.stored_object_id tree_id));
      Alcotest.(check string)
        "snapshot golden"
        (require_golden "store-v1-snapshot.peng.hex")
        (stored_envelope store
           (Snapshot_store.Snapshot.stored_object_id snapshot_id)))

let () =
  Alcotest.run "persisted snapshots"
    [
      ( "unit",
        [
          Alcotest.test_case "tree order and references are canonical" `Quick
            canonical_tree_order_and_reference_types;
          Alcotest.test_case "scanner preserves exact filesystem model" `Quick
            scanner_preserves_bytes_modes_symlinks_and_ignores;
          Alcotest.test_case "unchanged content is reused" `Quick
            duplicate_content_is_reused;
          Alcotest.test_case "malformed schema and ignore paths reject" `Quick
            malformed_tree_and_ignore_are_rejected;
          Alcotest.test_case "persisted object golden bytes" `Quick
            persisted_object_goldens;
        ] );
    ]
