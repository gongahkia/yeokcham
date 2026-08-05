module Adapter = Paengi_rust_adapter
module Patch = Paengi_textual_patch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

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

let write_file path contents =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel contents)

let fixture_path name =
  [
    Filename.concat "fixtures/rust-adapter" name;
    Filename.concat "test/fixtures/rust-adapter" name;
  ]
  |> List.find_opt Sys.file_exists
  |> function
  | Some path -> path
  | None -> Alcotest.fail ("missing Rust adapter fixture " ^ name)

let adapter_path () =
  match Sys.getenv_opt "PAENGI_RUST_ADAPTER" with
  | Some path when Sys.file_exists path -> path
  | Some _ | None -> (
      [
        "tools/paengi-rust-adapter/target/release/paengi-rust-adapter";
        "../tools/paengi-rust-adapter/target/release/paengi-rust-adapter";
      ]
      |> List.find_opt Sys.file_exists
      |> function
      | Some path -> path
      | None -> Alcotest.fail "missing built Rust adapter")

let configuration =
  Adapter.configuration_with ~adapter_path:(adapter_path ())
    Adapter.default_configuration

let contains ~needle value =
  let needle_length = String.length needle in
  let value_length = String.length value in
  let rec search index =
    if index + needle_length > value_length then false
    else if String.sub value index needle_length = needle then true
    else search (index + 1)
  in
  search 0

let assert_unavailable_contains expected = function
  | Adapter.Unavailable reason ->
      Alcotest.(check bool)
        "structured unavailable reason" true
        (contains ~needle:expected
           (Adapter.unavailable_reason_to_string reason))
  | Adapter.Available _ -> Alcotest.fail "adapter unexpectedly succeeded"

let file ~path ~contents = Adapter.Protocol.make_source_file ~path ~contents
let snapshot_id = String.make 64 '1'

let handshake_reports_pinned_parser () =
  match Adapter.handshake configuration with
  | Adapter.Available handshake ->
      Alcotest.(check string)
        "adapter version" "0.1.0"
        (Adapter.handshake_adapter_version handshake);
      Alcotest.(check string)
        "Tree-sitter version" "0.26.11"
        (Adapter.handshake_tree_sitter_version handshake);
      Alcotest.(check string)
        "Rust grammar version" "0.24.2"
        (Adapter.handshake_rust_grammar_version handshake);
      Alcotest.(check bool)
        "virtual file capability" true
        (List.mem "virtual-files" (Adapter.handshake_capabilities handshake))
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)

let rust_items_use_utf8_byte_spans () =
  let source =
    "pub fn café() {}\r\n\
     pub struct Unit;\r\n\
     macro_rules! build { () => {} }\r\n"
  in
  match
    Adapter.analyze_files configuration ~snapshot_id
      ~files:[ file ~path:"src/lib.rs" ~contents:source ]
  with
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)
  | Adapter.Available analysis -> (
      Alcotest.(check bool)
        "complete syntax" true
        (Adapter.Protocol.analysis_parser_complete analysis);
      let items = Adapter.Protocol.analysis_items analysis in
      Alcotest.(check int) "top-level item count" 3 (List.length items);
      let cafe =
        List.find_opt
          (fun item ->
            String.equal "café"
              (Option.value ~default:""
                 (Adapter.Protocol.item_syntactic_name item)))
          items
      in
      match cafe with
      | None -> Alcotest.fail "Rust function item was not returned"
      | Some item ->
          Alcotest.(check string)
            "function item kind" "function_item"
            (Adapter.Protocol.item_kind item);
          let name_span =
            match Adapter.Protocol.item_name_span item with
            | Some span -> span
            | None -> Alcotest.fail "function item missing name span"
          in
          Alcotest.(check int)
            "UTF-8 byte span" (String.index source 'c')
            (Adapter.Protocol.span_start_byte name_span);
          Alcotest.(check string)
            "exact name bytes" "café"
            (String.sub source
               (Adapter.Protocol.span_start_byte name_span)
               (Adapter.Protocol.span_end_byte name_span
               - Adapter.Protocol.span_start_byte name_span)))

let parser_damage_is_explicit () =
  match
    Adapter.analyze_files configuration ~snapshot_id
      ~files:[ file ~path:"src/damaged.rs" ~contents:"pub fn {" ]
  with
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)
  | Adapter.Available analysis ->
      Alcotest.(check bool)
        "parser damage remains incomplete" false
        (Adapter.Protocol.analysis_parser_complete analysis);
      Alcotest.(check bool)
        "syntax diagnostic is explicit" true
        (Adapter.Protocol.analysis_parser_diagnostics analysis <> [])

let verified_snapshot_is_the_only_analysis_input () =
  with_directory "paengi-rust-adapter-" (fun root ->
      Unix.mkdir (Filename.concat root "src") 0o700;
      let source_path = Filename.concat root "src/lib.rs" in
      write_file source_path "pub fn stable() {}\n";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      write_file source_path "pub fn changed_after_scan() {}\n";
      match Adapter.analyze_snapshot configuration ~store ~snapshot with
      | Adapter.Unavailable reason ->
          Alcotest.fail (Adapter.unavailable_reason_to_string reason)
      | Adapter.Available analysis ->
          let names =
            Adapter.Protocol.analysis_items analysis
            |> List.filter_map Adapter.Protocol.item_syntactic_name
          in
          Alcotest.(check bool)
            "snapshot bytes include stable function" true
            (List.mem "stable" names);
          Alcotest.(check bool)
            "live source is not read" false
            (List.mem "changed_after_scan" names))

let failures_are_semantic_unavailable () =
  let request = file ~path:"src/a.rs" ~contents:"pub const VALUE: u8 = 1;\n" in
  let analyze configuration =
    Adapter.analyze_files configuration ~snapshot_id ~files:[ request ]
  in
  assert_unavailable_contains "adapter is missing"
    (analyze
       (Adapter.configuration_with ~adapter_path:"missing-rust-adapter"
          Adapter.default_configuration));
  assert_unavailable_contains "timed out"
    (analyze
       (Adapter.configuration_with ~adapter_path:(fixture_path "slow.sh")
          ~timeout_ms:25 Adapter.default_configuration));
  assert_unavailable_contains "malformed adapter response"
    (analyze
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "malformed.sh")
          Adapter.default_configuration));
  assert_unavailable_contains "adapter crashed"
    (analyze
       (Adapter.configuration_with ~adapter_path:(fixture_path "crash.sh")
          Adapter.default_configuration));
  assert_unavailable_contains "adapter output exceeded"
    (analyze
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "large-output.sh")
          ~max_response_bytes:128 Adapter.default_configuration));
  assert_unavailable_contains "adapter output exceeded"
    (analyze
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "large-stderr.sh")
          ~max_stderr_bytes:128 Adapter.default_configuration));
  assert_unavailable_contains "request exceeded"
    (analyze
       (Adapter.configuration_with ~adapter_path:(adapter_path ())
          ~max_request_bytes:32 Adapter.default_configuration))

let unsafe_and_non_utf8_input_are_structured () =
  assert_unavailable_contains "invalid-input"
    (Adapter.analyze_files configuration ~snapshot_id
       ~files:[ file ~path:"../escape.rs" ~contents:"pub fn escape() {}" ]);
  assert_unavailable_contains "unsupported-encoding"
    (Adapter.analyze_files configuration ~snapshot_id
       ~files:[ file ~path:"src/bytes.rs" ~contents:"\255" ])

let unavailable_adapter_preserves_textual_operation () =
  let source = "// independent edit\npub const VALUE: u8 = 1;\n" in
  let semantic =
    Adapter.analyze_files
      (Adapter.configuration_with ~adapter_path:"missing-rust-adapter"
         Adapter.default_configuration)
      ~snapshot_id
      ~files:[ file ~path:"src/a.rs" ~contents:source ]
  in
  assert_unavailable_contains "adapter is missing" semantic;
  let start_byte = String.index source '1' in
  let patch =
    Patch.make
      ~original_span:Patch.{ start_byte; end_byte = start_byte + 1 }
      ~expected_preimage:"1" ~replacement:"2" ~before_context:"= "
      ~after_context:";\n"
      ~relaxed_context_bytes:Patch.default_relaxed_context_bytes
    |> require_ok Fun.id
  in
  match Patch.apply ~source patch with
  | Patch.Applied applied ->
      Alcotest.(check string)
        "textual operation remains available"
        "// independent edit\npub const VALUE: u8 = 2;\n" applied.contents
  | Patch.Already_satisfied _ | Patch.Conflict _ ->
      Alcotest.fail "unavailable semantic adapter blocked a textual operation"

let () =
  Alcotest.run "Rust adapter"
    [
      ( "protocol",
        [
          Alcotest.test_case "pinned handshake" `Quick
            handshake_reports_pinned_parser;
          Alcotest.test_case "UTF-8 Rust item spans" `Quick
            rust_items_use_utf8_byte_spans;
          Alcotest.test_case "parser damage is incomplete" `Quick
            parser_damage_is_explicit;
          Alcotest.test_case "adapter failures remain unavailable" `Quick
            failures_are_semantic_unavailable;
          Alcotest.test_case "unsafe and non-UTF-8 input is structured" `Quick
            unsafe_and_non_utf8_input_are_structured;
          Alcotest.test_case "unavailable adapter preserves textual operation"
            `Quick unavailable_adapter_preserves_textual_operation;
        ] );
      ( "snapshot",
        [
          Alcotest.test_case "verified snapshot virtual files" `Quick
            verified_snapshot_is_the_only_analysis_input;
        ] );
    ]
