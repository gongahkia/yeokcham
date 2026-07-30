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

let large_content_goldens () =
  with_store (fun _ store ->
      let chunk =
        Snapshot_store.Chunk.store store "chunk\000bytes"
        |> require_ok Snapshot_store.error_to_string
      in
      let contents = String.make (Snapshot_store.inline_file_limit + 1) 'x' in
      let manifest =
        Snapshot_store.Content.store store contents
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check string)
        "chunk golden" (require_golden "store-v1-chunk.peng.hex")
        (stored_envelope store (Snapshot_store.Chunk.stored_object_id chunk));
      Alcotest.(check string)
        "file manifest golden"
        (require_golden "store-v1-file-manifest.peng.hex")
        (stored_envelope store (Snapshot_store.Content.stored_object_id manifest)))

let deterministic_bytes length =
  let state = ref 0x243f6a8885a308d3L in
  let bytes = Bytes.create length in
  for index = 0 to length - 1 do
    state := Int64.add (Int64.mul !state 2862933555777941757L) 3037000493L;
    Bytes.set bytes index
      (Char.chr Int64.(to_int (logand (shift_right_logical !state 32) 255L)))
  done;
  Bytes.unsafe_to_string bytes

let manifest_payload ~total_length ~full_content_id references =
  let references =
    List.map
      (fun (identity, length) ->
        Encoding.array
          [
            Encoding.bytes
              (Store.Stored_object_id.to_raw_bytes
                 (Snapshot_store.Chunk.stored_object_id identity));
            Encoding.integer (Int64.of_int length);
          ]
        |> require_ok Encoding.construction_error_to_string)
      references
  in
  Encoding.array
    [
      Encoding.integer 1L;
      Encoding.integer (Int64.of_int total_length);
      Encoding.integer 1L;
      Encoding.integer 64L;
      Encoding.integer 16_384L;
      Encoding.integer 65_536L;
      Encoding.integer 131_072L;
      Encoding.bytes
        (Snapshot_store.Content.identity_to_raw_bytes full_content_id);
      Encoding.array references |> require_ok Encoding.construction_error_to_string;
    ]
  |> require_ok Encoding.construction_error_to_string

let store_manifest store payload =
  Envelope.create ~object_type:Envelope.File_manifest
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> require_envelope |> Store.put store |> require_ok Store.error_to_string

let inline_and_manifest_content_round_trip () =
  with_store (fun _ store ->
      let inline = deterministic_bytes Snapshot_store.inline_file_limit in
      let manifest = deterministic_bytes (3 * 131_072 + 17) in
      let split =
        Paengi_chunking.split Paengi_chunking.default manifest
        |> require_ok Paengi_chunking.error_to_string
      in
      Alcotest.(check int)
        "chunker retains all input bytes" (String.length manifest)
        (List.fold_left (fun total chunk -> total + String.length chunk) 0 split);
      let inline_id =
        Snapshot_store.Content.store store inline
        |> require_ok Snapshot_store.error_to_string
      in
      let manifest_id =
        Snapshot_store.Content.store store manifest
        |> require_ok Snapshot_store.error_to_string
      in
      let inline_object =
        Store.get store (Snapshot_store.Content.stored_object_id inline_id)
        |> require_ok Store.error_to_string
      in
      let manifest_object =
        Store.get store (Snapshot_store.Content.stored_object_id manifest_id)
        |> require_ok Store.error_to_string
      in
      Alcotest.(check bool)
        "boundary-sized file stays Content v1" true
        (Envelope.object_type inline_object = Envelope.Content);
      Alcotest.(check bool)
        "larger file uses File_manifest v1" true
        (Envelope.object_type manifest_object = Envelope.File_manifest);
      Alcotest.(check string)
        "manifest content round-trips" manifest
        (Snapshot_store.Content.load store manifest_id
        |> require_ok Snapshot_store.error_to_string);
      let loaded =
        Snapshot_store.Manifest.load store
          (Snapshot_store.Manifest.of_stored_object_id
             (Snapshot_store.Content.stored_object_id manifest_id))
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check int)
        "manifest total plaintext length" (String.length manifest)
        (Snapshot_store.Manifest.total_length loaded);
      Alcotest.(check bool)
        "manifest has multiple chunks" true
        (List.length (Snapshot_store.Manifest.chunks loaded) > 1);
      let duplicate =
        Snapshot_store.Content.store store manifest
        |> require_ok Snapshot_store.error_to_string
      in
      Alcotest.(check bool)
        "manifest representation is deterministic" true
        (Snapshot_store.Content.equal_id manifest_id duplicate))

let manifest_failures_are_structured () =
  with_store (fun _ store ->
      let contents = deterministic_bytes (3 * 131_072 + 17) in
      let content =
        Snapshot_store.Content.store store contents
        |> require_ok Snapshot_store.error_to_string
      in
      let manifest =
        Snapshot_store.Manifest.load store
          (Snapshot_store.Manifest.of_stored_object_id
             (Snapshot_store.Content.stored_object_id content))
        |> require_ok Snapshot_store.error_to_string
      in
      let references = Snapshot_store.Manifest.chunks manifest in
      let reordered =
        store_manifest store
          (manifest_payload ~total_length:(String.length contents)
             ~full_content_id:(Snapshot_store.Content.identity_of_bytes contents)
             (List.rev references))
      in
      (match
       Snapshot_store.Content.load store
           (Snapshot_store.Content.of_stored_object_id reordered)
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "reordered chunks were accepted");
      let wrong_chunk =
        Snapshot_store.Content.store store "not-a-chunk"
        |> require_ok Snapshot_store.error_to_string
      in
      let wrong_reference =
        Snapshot_store.Chunk.of_stored_object_id
          (Snapshot_store.Content.stored_object_id wrong_chunk)
      in
      let wrong_type =
        let wrong_references =
          (wrong_reference, String.length "not-a-chunk") :: List.tl references
        in
        let wrong_total =
          List.fold_left (fun total (_, length) -> total + length) 0
            wrong_references
        in
        store_manifest store
          (manifest_payload ~total_length:wrong_total
             ~full_content_id:(Snapshot_store.Content.identity_of_bytes contents)
             wrong_references)
      in
      (match
       Snapshot_store.Content.load store
           (Snapshot_store.Content.of_stored_object_id wrong_type)
       with
      | Error error ->
          Alcotest.(check string)
            "wrong chunk type is explicit" "expected object type 13, got object type 1"
            (Snapshot_store.error_to_string error)
      | Ok _ -> Alcotest.fail "non-chunk reference was accepted");
      let missing, _ = List.hd references in
      Unix.unlink
        (Store.object_path store
           (Snapshot_store.Chunk.stored_object_id missing));
      match Snapshot_store.Content.load store content with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "missing chunk was accepted")

let unsupported_fifo_does_not_publish_a_snapshot () =
  with_directory "paengi-unsupported-node-" (fun root ->
      let regular = Filename.concat root "regular" in
      write_file regular "valid";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let snapshot_id, _ =
        Snapshot_store.scan ~root ~store
        |> require_ok Snapshot_store.error_to_string
      in
      let fifo = Filename.concat root "fifo" in
      try
        Unix.mkfifo fifo 0o600;
        (match Snapshot_store.scan ~root ~store with
        | Error error ->
            Alcotest.(check string)
              "unsupported fifo category"
              (Printf.sprintf "unsupported filesystem node (fifo): %s" fifo)
              (Snapshot_store.error_to_string error)
        | Ok _ -> Alcotest.fail "fifo scan published a snapshot");
        ignore
          (Snapshot_store.Snapshot.load store snapshot_id
          |> require_ok Snapshot_store.error_to_string)
      with
      | Unix.Unix_error (Unix.EPERM, _, _) | Unix.Unix_error (Unix.EACCES, _, _) -> ())

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
          Alcotest.test_case "large-content object golden bytes" `Quick
            large_content_goldens;
          Alcotest.test_case "inline and manifest content round-trip" `Quick
            inline_and_manifest_content_round_trip;
          Alcotest.test_case "manifest failures are structured" `Quick
            manifest_failures_are_structured;
          Alcotest.test_case "unsupported fifo does not publish a snapshot"
            `Quick unsupported_fifo_does_not_publish_a_snapshot;
        ] );
    ]
