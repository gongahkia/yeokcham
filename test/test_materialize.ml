module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Snapshot_store = Paengi_snapshot
module Store = Paengi_store

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

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let deterministic_bytes length =
  let state = ref 0x13198a2e03707344L in
  let bytes = Bytes.create length in
  for index = 0 to length - 1 do
    state := Int64.add (Int64.mul !state 2862933555777941757L) 3037000493L;
    Bytes.set bytes index
      (Char.chr Int64.(to_int (logand (shift_right_logical !state 32) 255L)))
  done;
  Bytes.unsafe_to_string bytes

let scanned_fixture run =
  with_directory "paengi-materialize-source-" (fun source ->
      with_directory "paengi-materialize-store-" (fun store_root ->
          with_directory "paengi-materialize-destination-" (fun destination ->
              Unix.mkdir (Filename.concat source "nested") 0o700;
              write_file (Filename.concat source "binary") "\000\255bytes";
              write_file
                (Filename.concat source "run")
                "#!/bin/sh\necho paengi\n";
              Unix.chmod (Filename.concat source "run") 0o755;
              write_file
                (Filename.concat (Filename.concat source "nested") "guide")
                "guide\n";
              Unix.symlink "nested/guide" (Filename.concat source "guide-link");
              let store =
                Store.init ~root:store_root |> require_ok Store.error_to_string
              in
              let _, snapshot =
                Snapshot_store.scan ~root:source ~store
                |> require_ok Snapshot_store.error_to_string
              in
              run source store snapshot destination)))

let plan_and_write_exact_snapshot () =
  scanned_fixture (fun _ store snapshot destination ->
      let plan =
        Snapshot_store.Materialize.plan store snapshot
        |> require_ok Snapshot_store.Materialize.error_to_string
      in
      Alcotest.(check int) "dry-run action count" 5 (List.length plan);
      Snapshot_store.Materialize.write ~destination store snapshot
      |> require_ok Snapshot_store.Materialize.error_to_string;
      Alcotest.(check string)
        "binary bytes" "\000\255bytes"
        (read_file (Filename.concat destination "binary"));
      Alcotest.(check string)
        "nested bytes" "guide\n"
        (read_file
           (Filename.concat (Filename.concat destination "nested") "guide"));
      Alcotest.(check bool)
        "executable mode" true
        ((Unix.stat (Filename.concat destination "run")).Unix.st_perm land 0o111
        <> 0);
      let link = Filename.concat destination "guide-link" in
      Alcotest.(check bool)
        "symlink kind" true
        ((Unix.lstat link).Unix.st_kind = Unix.S_LNK);
      Alcotest.(check string)
        "symlink target" "nested/guide" (Unix.readlink link))

let nonempty_destination_is_unchanged () =
  scanned_fixture (fun _ store snapshot destination ->
      let existing = Filename.concat destination "existing" in
      write_file existing "preserve";
      match Snapshot_store.Materialize.write ~destination store snapshot with
      | Error error ->
          Alcotest.(check string)
            "nonempty destination rejection"
            (Printf.sprintf "materialisation destination is not empty: %s"
               destination)
            (Snapshot_store.Materialize.error_to_string error);
          Alcotest.(check string)
            "existing file unchanged" "preserve" (read_file existing)
      | Ok () -> Alcotest.fail "nonempty destination was materialised")

let unsafe_tree_name_cannot_materialise () =
  with_directory "paengi-materialize-unsafe-store-" (fun store_root ->
      with_directory "paengi-materialize-unsafe-destination-"
        (fun destination ->
          let store =
            Store.init ~root:store_root |> require_ok Store.error_to_string
          in
          let content =
            Snapshot_store.Content.store store "value"
            |> require_ok Snapshot_store.error_to_string
          in
          let entry =
            Encoding.array
              [
                Encoding.integer 0L;
                Encoding.bytes "..";
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
                Encoding.array [ entry ]
                |> require_ok Encoding.construction_error_to_string;
              ]
            |> require_ok Encoding.construction_error_to_string
          in
          let envelope =
            Envelope.create ~object_type:Envelope.Tree
              ~object_format_version:Envelope.current_object_format_version
              ~mandatory_features:Envelope.supported_mandatory_features ~payload
              ()
            |> require_ok Envelope.creation_error_to_string
          in
          let stored =
            Store.put store envelope |> require_ok Store.error_to_string
          in
          let snapshot =
            Snapshot_store.Snapshot.create
              ~root:(Snapshot_store.Tree.of_stored_object_id stored)
          in
          match
            Snapshot_store.Materialize.write ~destination store snapshot
          with
          | Error error ->
              Alcotest.(check bool)
                "unsafe tree rejection" true
                (String.starts_with ~prefix:"invalid tree entry name: \"..\""
                   (Snapshot_store.Materialize.error_to_string error));
              Alcotest.(check int)
                "destination remains empty" 0
                (Array.length (Sys.readdir destination))
          | Ok () -> Alcotest.fail "unsafe tree name was materialised"))

let manifest_backed_file_materialises_exactly () =
  with_directory "paengi-large-materialize-source-" (fun source ->
      with_directory "paengi-large-materialize-store-" (fun store_root ->
          with_directory "paengi-large-materialize-destination-"
            (fun destination ->
              let contents = deterministic_bytes ((3 * 131_072) + 17) in
              write_file (Filename.concat source "large.bin") contents;
              let store =
                Store.init ~root:store_root |> require_ok Store.error_to_string
              in
              let source_id, snapshot =
                Snapshot_store.scan ~root:source ~store
                |> require_ok Snapshot_store.error_to_string
              in
              Snapshot_store.Materialize.write ~destination store snapshot
              |> require_ok Snapshot_store.Materialize.error_to_string;
              Alcotest.(check string)
                "manifest-backed regular bytes" contents
                (read_file (Filename.concat destination "large.bin"));
              let destination_id, _ =
                Snapshot_store.scan ~root:destination ~store
                |> require_ok Snapshot_store.error_to_string
              in
              Alcotest.(check bool)
                "manifest-backed round-trip identity" true
                (Snapshot_store.Snapshot.equal_id source_id destination_id))))

let () =
  Alcotest.run "snapshot materialisation"
    [
      ( "unit",
        [
          Alcotest.test_case "dry-run and write preserve exact snapshot" `Quick
            plan_and_write_exact_snapshot;
          Alcotest.test_case "nonempty destination is unchanged" `Quick
            nonempty_destination_is_unchanged;
          Alcotest.test_case "unsafe tree paths are rejected" `Quick
            unsafe_tree_name_cannot_materialise;
          Alcotest.test_case "manifest-backed file materialises exactly" `Quick
            manifest_backed_file_materialises_exactly;
        ] );
    ]
