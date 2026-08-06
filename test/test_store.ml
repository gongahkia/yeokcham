module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Store = Yeokcham_store

let require_envelope = function
  | Ok envelope -> envelope
  | Error error -> Alcotest.fail (Envelope.creation_error_to_string error)

let content_envelope bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

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

let with_repository run =
  let root = Filename.temp_file "yeokcham-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      match Store.init ~root with
      | Ok repository -> run root repository
      | Error error -> Alcotest.fail (Store.error_to_string error))

let typed_ids_are_canonical () =
  let lower = String.make 64 'a' in
  let id =
    match Store.Stored_object_id.of_hex lower with
    | Ok id -> id
    | Error error ->
        Alcotest.fail (Store.Stored_object_id.parse_error_to_string error)
  in
  Alcotest.(check string)
    "lowercase rendering" lower
    (Store.Stored_object_id.to_hex id);
  (match Store.Stored_object_id.of_hex (String.make 63 'a') with
  | Error error ->
      Alcotest.(check string)
        "short ID rejection"
        "stored object ID must contain 64 hexadecimal characters, got 63"
        (Store.Stored_object_id.parse_error_to_string error)
  | Ok _ -> Alcotest.fail "short ID was accepted");
  match Store.Stored_object_id.of_hex (String.make 63 'a' ^ "A") with
  | Error error ->
      Alcotest.(check string)
        "uppercase ID rejection"
        "stored object ID has invalid lowercase hexadecimal character 'A' at 63"
        (Store.Stored_object_id.parse_error_to_string error)
  | Ok _ -> Alcotest.fail "uppercase ID was accepted"

let init_writes_exact_format () =
  with_repository (fun root _ ->
      Alcotest.(check string)
        "repository format" Store.repository_format
        (read_file
           (Filename.concat (Filename.concat root ".yeokcham") "format")))

let round_trip_is_idempotent_and_restart_safe () =
  with_repository (fun root repository ->
      let envelope = content_envelope "exact\000bytes\255" in
      let id =
        match Store.put repository envelope with
        | Ok id -> id
        | Error error -> Alcotest.fail (Store.error_to_string error)
      in
      let duplicate =
        match Store.put repository envelope with
        | Ok id -> id
        | Error error -> Alcotest.fail (Store.error_to_string error)
      in
      Alcotest.(check string)
        "idempotent ID"
        (Store.Stored_object_id.to_hex id)
        (Store.Stored_object_id.to_hex duplicate);
      let path = Store.object_path repository id in
      let hex = Store.Stored_object_id.to_hex id in
      Alcotest.(check string)
        "typed object path"
        (Filename.concat
           (Filename.concat
              (Filename.concat (Filename.concat root ".yeokcham") "objects")
              (String.sub hex 0 2))
           (Filename.concat (String.sub hex 2 2) (String.sub hex 4 60)))
        path;
      let reopened =
        match Store.open_repository ~root with
        | Ok repository -> repository
        | Error error -> Alcotest.fail (Store.error_to_string error)
      in
      match Store.get reopened id with
      | Ok actual ->
          Alcotest.(check string)
            "exact envelope bytes" (Envelope.encode envelope)
            (Envelope.encode actual)
      | Error error -> Alcotest.fail (Store.error_to_string error))

let stale_temporary_is_ignored_on_reopen () =
  with_repository (fun root repository ->
      let envelope = content_envelope "retained" in
      let id =
        match Store.put repository envelope with
        | Ok id -> id
        | Error error -> Alcotest.fail (Store.error_to_string error)
      in
      let final = Store.object_path repository id in
      let stale =
        Filename.concat (Filename.dirname final)
          (Printf.sprintf ".stale.tmp-%d" (Unix.getpid ()))
      in
      write_file stale "incomplete";
      let reopened =
        match Store.open_repository ~root with
        | Ok repository -> repository
        | Error error -> Alcotest.fail (Store.error_to_string error)
      in
      match Store.get reopened id with
      | Ok actual ->
          Alcotest.(check string)
            "published bytes survive stale temporary" (Envelope.encode envelope)
            (Envelope.encode actual)
      | Error error -> Alcotest.fail (Store.error_to_string error))

let corruption_and_divergence_are_explicit () =
  with_repository (fun _ repository ->
      let envelope = content_envelope "unmodified" in
      let id =
        match Store.put repository envelope with
        | Ok id -> id
        | Error error -> Alcotest.fail (Store.error_to_string error)
      in
      write_file (Store.object_path repository id) "corrupt";
      (match Store.get repository id with
      | Error error ->
          Alcotest.(check bool)
            "corruption identity failure" true
            (String.starts_with ~prefix:"object identity mismatch: "
               (Store.error_to_string error))
      | Ok _ -> Alcotest.fail "corrupt object was accepted");
      match Store.put repository envelope with
      | Error error ->
          Alcotest.(check bool)
            "divergent existing object failure" true
            (String.starts_with ~prefix:"existing object "
               (Store.error_to_string error))
      | Ok _ -> Alcotest.fail "divergent object was accepted")

let init_rejects_non_directory_metadata () =
  let root = Filename.temp_file "yeokcham-store-invalid-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      write_file (Filename.concat root ".yeokcham") "not a directory";
      match Store.init ~root with
      | Error error ->
          Alcotest.(check string)
            "file metadata rejection"
            (Printf.sprintf "repository root is not a directory: %s"
               (Filename.concat root ".yeokcham"))
            (Store.error_to_string error)
      | Ok _ -> Alcotest.fail "file .yeokcham was accepted")

let () =
  Alcotest.run "immutable object store"
    [
      ( "unit",
        [
          Alcotest.test_case "typed IDs are canonical" `Quick
            typed_ids_are_canonical;
          Alcotest.test_case "init writes exact repository format" `Quick
            init_writes_exact_format;
          Alcotest.test_case "put is idempotent and survives reopen" `Quick
            round_trip_is_idempotent_and_restart_safe;
          Alcotest.test_case "stale temporary is ignored on reopen" `Quick
            stale_temporary_is_ignored_on_reopen;
          Alcotest.test_case "corruption and divergence are explicit" `Quick
            corruption_and_divergence_are_explicit;
          Alcotest.test_case "init rejects non-directory metadata" `Quick
            init_rejects_non_directory_metadata;
        ] );
    ]
