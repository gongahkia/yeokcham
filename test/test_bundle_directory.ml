module Bundle = Yeokcham_bundle
module Directory = Yeokcham_bundle_directory
module Divergence_store = Yeokcham_divergence_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Store = Yeokcham_store

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_bundle result = require Bundle.error_to_string result
let require_directory result = require Directory.error_to_string result
let require_envelope result = require Envelope.creation_error_to_string result
let require_store result = require Store.error_to_string result

let key =
  Bundle.key_of_bytes (String.init 32 (fun index -> Char.chr (index + 1)))
  |> require_bundle

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

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

let with_repositories run =
  let root = Filename.temp_file "yeokcham-bundle-directory-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  let shared = Filename.concat root "shared" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Unix.mkdir shared 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require_store in
      let destination = Store.init ~root:destination_root |> require_store in
      run source destination shared)

let write_file path bytes =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output bytes)

let read_lines path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
      let rec loop values =
        match input_line input with
        | value -> loop (value :: values)
        | exception End_of_file -> List.rev values
      in
      loop [])

let assert_ref_unchanged repository reference =
  Alcotest.(check bool)
    "application ref is unchanged" true
    (Store.read_ref repository ~name:"scratch-head"
    |> require_store
    |> Option.exists (Store.Mutable_ref.equal reference))

let equal_ids left right =
  List.length left = List.length right
  && List.for_all2 Store.Stored_object_id.equal left right

let export_list_inspect_import_preserves_refs () =
  with_repositories (fun source destination shared ->
      let source_envelopes = [ content "one"; content "two" ] in
      let source_ids =
        List.map (Store.put source) source_envelopes |> List.map require_store
      in
      let retained =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let components =
        Divergence_store.binding_components ~ref_name:"scratch-head"
      in
      let binding = Divergence_store.encode_binding retained in
      Store.Ref_file.compare_and_swap destination ~components ~expected:None
        ~replacement:binding
      |> require_store;
      let complete =
        Directory.export ~directory:shared ~repository:source ~key
          ~object_ids:(List.rev source_ids)
        |> require_directory
      in
      let entries = Directory.list ~directory:shared |> require_directory in
      Alcotest.(check int) "one complete file" 1 (List.length entries);
      let listed =
        List.hd entries |> Directory.complete_of_entry |> require_directory
      in
      Alcotest.(check string)
        "listed complete path"
        (Directory.complete_path complete)
        (Directory.complete_path listed);
      let inspection = Directory.inspect ~key listed |> require_directory in
      Alcotest.(check bool)
        "inspection returns canonical IDs" true
        (equal_ids
           (List.sort Store.Stored_object_id.compare source_ids)
           (Directory.inspection_object_ids inspection));
      let imported =
        Directory.import ~repository:destination ~key listed
        |> require_directory
      in
      Alcotest.(check bool)
        "import returns canonical IDs" true
        (equal_ids
           (List.sort Store.Stored_object_id.compare source_ids)
           imported);
      List.iter2
        (fun envelope object_id ->
          Alcotest.(check string)
            "exact Envelope bytes survive directory import"
            (Envelope.encode envelope)
            (Store.get destination object_id |> require_store |> Envelope.encode))
        source_envelopes source_ids;
      assert_ref_unchanged destination reference;
      Alcotest.(check (option string))
        "divergence binding is unchanged" (Some binding)
        (Store.Ref_file.read destination ~components |> require_store);
      let reopened =
        Store.open_repository ~root:(Store.root destination) |> require_store
      in
      Directory.import ~repository:reopened ~key listed
      |> require_directory |> ignore;
      assert_ref_unchanged reopened reference)

let retained_partials_are_visible_but_not_importable () =
  with_repositories (fun _ _ shared ->
      let partial =
        ".yeokcham-bundle-v1-00000000000000000000000000000000.partial"
      in
      let complete = "yeokcham-bundle-v1-ffffffffffffffffffffffffffffffff.yeok" in
      write_file (Filename.concat shared partial) "partial";
      write_file (Filename.concat shared complete) "complete";
      let expected =
        read_lines (Filename.concat "golden" "shared-directory-v1.names")
      in
      let entries = Directory.list ~directory:shared |> require_directory in
      Alcotest.(check (list string))
        "v1 names sort canonically" expected
        (List.map Directory.entry_name entries);
      Alcotest.(check bool)
        "partial conversion rejects" true
        (Result.is_error (Directory.complete_of_entry (List.hd entries))))

let corruption_and_unsafe_entries_reject_before_import () =
  with_repositories (fun source destination shared ->
      let source_id =
        Store.put source (content "source-only") |> require_store
      in
      let retained =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let complete =
        Directory.export ~directory:shared ~repository:source ~key
          ~object_ids:[ source_id ]
        |> require_directory
      in
      write_file (Directory.complete_path complete) "corrupt";
      Alcotest.(check bool)
        "corrupt complete file rejects" true
        (Result.is_error
           (Directory.import ~repository:destination ~key complete));
      Alcotest.(check bool)
        "corrupt complete file imports nothing" true
        (Result.is_error (Store.get destination source_id));
      assert_ref_unchanged destination reference;
      let unsafe = Filename.concat shared "unrelated" in
      write_file unsafe "unexpected";
      Alcotest.(check bool)
        "unexpected entry rejects" true
        (Result.is_error (Directory.list ~directory:shared));
      Unix.unlink unsafe;
      Unix.unlink (Directory.complete_path complete);
      let symlink =
        Filename.concat shared
          "yeokcham-bundle-v1-11111111111111111111111111111111.yeok"
      in
      Unix.symlink "missing-target" symlink;
      Alcotest.(check bool)
        "symlink entry rejects" true
        (Result.is_error (Directory.list ~directory:shared)))

let () =
  Alcotest.run "shared-directory encrypted bundles"
    [
      ( "directory",
        [
          Alcotest.test_case "export list inspect import retry" `Quick
            export_list_inspect_import_preserves_refs;
          Alcotest.test_case "retained partials stay non-importable" `Quick
            retained_partials_are_visible_but_not_importable;
          Alcotest.test_case "corruption and unsafe entries reject" `Quick
            corruption_and_unsafe_entries_reject_before_import;
        ] );
    ]
