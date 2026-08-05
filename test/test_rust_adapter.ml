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
        (List.mem "virtual-files" (Adapter.handshake_capabilities handshake));
      Alcotest.(check bool)
        "module path capability" true
        (List.mem "module-paths-v1" (Adapter.handshake_capabilities handshake))
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

let module_paths_are_root_scoped_and_incomplete_when_unreachable () =
  let files =
    [
      file ~path:"src/alpha.rs" ~contents:"pub fn alpha() {}\nmod nested;\n";
      file ~path:"src/alpha/nested.rs" ~contents:"pub fn nested() {}\n";
      file ~path:"src/alt.rs" ~contents:"pub fn alt() {}\n";
      file ~path:"src/bin.rs" ~contents:"pub struct Bin;\n";
      file ~path:"src/lib.rs"
        ~contents:"pub mod alpha;\nmod beta { pub struct Café; }\n";
    ]
  in
  match
    Adapter.resolve_module_paths_files configuration ~snapshot_id
      ~root_files:[ "src/bin.rs"; "src/lib.rs" ]
      ~files
  with
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)
  | Adapter.Available analysis ->
      Alcotest.(check bool)
        "reachable syntax is complete" true
        (Adapter.Protocol.module_path_analysis_parser_complete analysis);
      Alcotest.(check bool)
        "unreachable input is incomplete" false
        (Adapter.Protocol.module_path_analysis_complete analysis);
      let modules =
        Adapter.Protocol.module_path_analysis_module_facts analysis
      in
      Alcotest.(check int)
        "root and nested module facts" 5 (List.length modules);
      Alcotest.(check bool)
        "external foo.rs is resolved" true
        (List.exists
           (fun fact ->
             String.equal "src/alpha.rs"
               (Option.value ~default:""
                  (Adapter.Protocol.module_fact_source_path fact))
             && Adapter.Protocol.module_fact_module_path fact = [ "alpha" ]
             && String.equal "resolved"
                  (Adapter.Protocol.module_fact_status fact))
           modules);
      Alcotest.(check bool)
        "inline module is resolved" true
        (List.exists
           (fun fact ->
             String.equal "inline" (Adapter.Protocol.module_fact_kind fact)
             && Adapter.Protocol.module_fact_module_path fact = [ "beta" ])
           modules);
      let facts =
        Adapter.Protocol.module_path_analysis_item_path_facts analysis
      in
      Alcotest.(check int) "root-scoped item facts" 7 (List.length facts);
      Alcotest.(check bool)
        "UTF-8 item span stays byte-correct" true
        (List.exists
           (fun fact ->
             String.equal "Café"
               (Option.value ~default:""
                  (Adapter.Protocol.item_path_fact_syntactic_name fact))
             && Adapter.Protocol.item_path_fact_root_file fact = "src/lib.rs"
             && Adapter.Protocol.item_path_fact_module_path fact = [ "beta" ]
             && Adapter.Protocol.item_path_fact_segments fact = Some [ "Café" ]
             && Adapter.Protocol.span_start_byte
                  (Adapter.Protocol.item_path_fact_name_span fact
                  |> Option.value
                       ~default:
                         (Adapter.Protocol.make_span ~start_byte:0 ~end_byte:0)
                  )
                = 37)
           facts);
      let unreachable =
        Adapter.Protocol.module_path_analysis_unreachable_sources analysis
      in
      Alcotest.(check (list string))
        "unreachable source is explicit" [ "src/alt.rs" ]
        (List.map Adapter.Protocol.unreachable_source_path unreachable)

let module_path_failures_are_structured () =
  let resolve files =
    Adapter.resolve_module_paths_files configuration ~snapshot_id
      ~root_files:[ "src/lib.rs" ] ~files
  in
  assert_unavailable_contains "invalid-input"
    (Adapter.resolve_module_paths_files configuration ~snapshot_id
       ~root_files:[]
       ~files:[ file ~path:"src/lib.rs" ~contents:"" ]);
  assert_unavailable_contains "duplicate root"
    (Adapter.resolve_module_paths_files configuration ~snapshot_id
       ~root_files:[ "src/lib.rs"; "src/lib.rs" ]
       ~files:[ file ~path:"src/lib.rs" ~contents:"" ]);
  assert_unavailable_contains "unsafe root"
    (Adapter.resolve_module_paths_files configuration ~snapshot_id
       ~root_files:[ "../lib.rs" ]
       ~files:[ file ~path:"src/lib.rs" ~contents:"" ]);
  assert_unavailable_contains "absent from the source map"
    (Adapter.resolve_module_paths_files configuration ~snapshot_id
       ~root_files:[ "src/missing.rs" ]
       ~files:[ file ~path:"src/lib.rs" ~contents:"" ]);
  let expect_status expected files =
    match resolve files with
    | Adapter.Unavailable reason ->
        Alcotest.fail (Adapter.unavailable_reason_to_string reason)
    | Adapter.Available analysis ->
        Alcotest.(check bool)
          expected true
          (List.exists
             (fun fact ->
               String.equal expected (Adapter.Protocol.module_fact_status fact))
             (Adapter.Protocol.module_path_analysis_module_facts analysis));
        Alcotest.(check bool)
          "module result is incomplete" false
          (Adapter.Protocol.module_path_analysis_complete analysis)
  in
  expect_status "missing-module"
    [ file ~path:"src/lib.rs" ~contents:"mod missing;\n" ];
  expect_status "ambiguous-module"
    [
      file ~path:"src/a.rs" ~contents:"";
      file ~path:"src/a/mod.rs" ~contents:"";
      file ~path:"src/lib.rs" ~contents:"mod a;\n";
    ];
  (match
     resolve
       [
         file ~path:"src/lib.rs" ~contents:"mod a;\n";
         file ~path:"src/a/mod.rs" ~contents:"pub fn from_mod_rs() {}\n";
       ]
   with
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)
  | Adapter.Available analysis ->
      Alcotest.(check bool)
        "foo/mod.rs resolves uniquely" true
        (Adapter.Protocol.module_path_analysis_complete analysis);
      Alcotest.(check bool)
        "foo/mod.rs selected from snapshot map" true
        (List.exists
           (fun fact ->
             String.equal "src/a/mod.rs"
               (Option.value ~default:""
                  (Adapter.Protocol.module_fact_source_path fact)))
           (Adapter.Protocol.module_path_analysis_module_facts analysis)));
  (match
     resolve
       [
         file ~path:"src/child.rs" ~contents:"pub fn child() {}\n";
         file ~path:"src/lib.rs" ~contents:"mod inline { mod child; }\n";
       ]
   with
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)
  | Adapter.Available analysis ->
      Alcotest.(check bool)
        "inline root child uses root directory" true
        (List.exists
           (fun fact ->
             String.equal "src/child.rs"
               (Option.value ~default:""
                  (Adapter.Protocol.module_fact_source_path fact))
             && Adapter.Protocol.module_fact_module_path fact
                = [ "inline"; "child" ])
           (Adapter.Protocol.module_path_analysis_module_facts analysis)));
  expect_status "unsupported-module-attribute"
    [ file ~path:"src/lib.rs" ~contents:"#[path = \"other.rs\"] mod a;\n" ];
  expect_status "conditional-module"
    [ file ~path:"src/lib.rs" ~contents:"#[cfg(feature = \"x\")] mod a;\n" ];
  expect_status "duplicate-module"
    [ file ~path:"src/lib.rs" ~contents:"mod a {}\nmod a {}\n" ];
  expect_status "module-cycle"
    [ file ~path:"src/lib.rs" ~contents:"mod lib;\n" ];
  match
    resolve
      [
        file ~path:"src/lib.rs"
          ~contents:
            "macro_rules! generated { () => {} }\n\
             generated!();\n\
             use generated;\n";
      ]
  with
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)
  | Adapter.Available analysis ->
      Alcotest.(check bool)
        "macro items are path-deferred" true
        (List.exists
           (fun fact ->
             String.equal "macro-item-deferred"
               (Adapter.Protocol.item_path_fact_status fact)
             && String.equal "macro_invocation"
                  (Adapter.Protocol.item_path_fact_kind fact))
           (Adapter.Protocol.module_path_analysis_item_path_facts analysis));
      (match resolve [ file ~path:"src/lib.rs" ~contents:"pub fn {" ] with
      | Adapter.Unavailable reason ->
          Alcotest.fail (Adapter.unavailable_reason_to_string reason)
      | Adapter.Available damaged ->
          Alcotest.(check bool)
            "damaged module root is incomplete" false
            (Adapter.Protocol.module_path_analysis_parser_complete damaged);
          Alcotest.(check bool)
            "damaged module root has structured status" true
            (List.exists
               (fun fact ->
                 String.equal "parser-incomplete"
                   (Adapter.Protocol.module_fact_status fact))
               (Adapter.Protocol.module_path_analysis_module_facts damaged)));
      let nested_modules count =
        String.concat ""
          (List.init count (fun index -> Printf.sprintf "mod d%d {" index))
        ^ String.make count '}'
      in
      expect_status "module-depth-limit"
        [ file ~path:"src/lib.rs" ~contents:(nested_modules 257) ];
      let many_modules count =
        String.concat ""
          (List.init count (fun index -> Printf.sprintf "mod m%d {}\n" index))
      in
      assert_unavailable_contains "module-fact-limit"
        (Adapter.resolve_module_paths_files
           (Adapter.configuration_with ~timeout_ms:20_000 configuration)
           ~snapshot_id ~root_files:[ "src/lib.rs" ]
           ~files:[ file ~path:"src/lib.rs" ~contents:(many_modules 4_097) ])

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

let verified_snapshot_is_the_only_module_path_input () =
  with_directory "paengi-rust-module-paths-" (fun root ->
      Unix.mkdir (Filename.concat root "src") 0o700;
      let lib_path = Filename.concat root "src/lib.rs" in
      let module_path = Filename.concat root "src/stable.rs" in
      write_file lib_path "mod stable;\n";
      write_file module_path "pub fn stored() {}\n";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      write_file lib_path "mod changed_after_scan;\n";
      write_file module_path "pub fn changed_after_scan() {}\n";
      match
        Adapter.resolve_module_paths_snapshot configuration ~store ~snapshot
          ~root_files:[ "src/lib.rs" ]
      with
      | Adapter.Unavailable reason ->
          Alcotest.fail (Adapter.unavailable_reason_to_string reason)
      | Adapter.Available analysis ->
          let names =
            Adapter.Protocol.module_path_analysis_item_path_facts analysis
            |> List.filter_map Adapter.Protocol.item_path_fact_syntactic_name
          in
          Alcotest.(check bool)
            "snapshot module bytes include stored function" true
            (List.mem "stored" names);
          Alcotest.(check bool)
            "live module source is not read" false
            (List.mem "changed_after_scan" names))

let failures_are_semantic_unavailable () =
  let request = file ~path:"src/a.rs" ~contents:"pub const VALUE: u8 = 1;\n" in
  let resolve configuration =
    Adapter.resolve_module_paths_files configuration ~snapshot_id
      ~root_files:[ "src/a.rs" ] ~files:[ request ]
  in
  assert_unavailable_contains "adapter is missing"
    (resolve
       (Adapter.configuration_with ~adapter_path:"missing-rust-adapter"
          Adapter.default_configuration));
  assert_unavailable_contains "timed out"
    (resolve
       (Adapter.configuration_with ~adapter_path:(fixture_path "slow.sh")
          ~timeout_ms:25 Adapter.default_configuration));
  assert_unavailable_contains "malformed adapter response"
    (resolve
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "malformed.sh")
          Adapter.default_configuration));
  assert_unavailable_contains "adapter crashed"
    (resolve
       (Adapter.configuration_with ~adapter_path:(fixture_path "crash.sh")
          Adapter.default_configuration));
  assert_unavailable_contains "adapter output exceeded"
    (resolve
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "large-output.sh")
          ~max_response_bytes:128 Adapter.default_configuration));
  assert_unavailable_contains "adapter output exceeded"
    (resolve
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "large-stderr.sh")
          ~max_stderr_bytes:128 Adapter.default_configuration));
  assert_unavailable_contains "request exceeded"
    (resolve
       (Adapter.configuration_with ~adapter_path:(adapter_path ())
          ~max_request_bytes:32 Adapter.default_configuration))

let unsafe_and_non_utf8_input_are_structured () =
  assert_unavailable_contains "invalid-input"
    (Adapter.resolve_module_paths_files configuration ~snapshot_id
       ~root_files:[ "../escape.rs" ]
       ~files:[ file ~path:"../escape.rs" ~contents:"pub fn escape() {}" ]);
  assert_unavailable_contains "unsupported-encoding"
    (Adapter.resolve_module_paths_files configuration ~snapshot_id
       ~root_files:[ "src/bytes.rs" ]
       ~files:[ file ~path:"src/bytes.rs" ~contents:"\255" ])

let unavailable_adapter_preserves_textual_operation () =
  let source = "// independent edit\npub const VALUE: u8 = 1;\n" in
  let semantic =
    Adapter.resolve_module_paths_files
      (Adapter.configuration_with ~adapter_path:"missing-rust-adapter"
         Adapter.default_configuration)
      ~snapshot_id ~root_files:[ "src/a.rs" ]
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
          Alcotest.test_case "module paths are root-scoped" `Quick
            module_paths_are_root_scoped_and_incomplete_when_unreachable;
          Alcotest.test_case "module path failures are structured" `Quick
            module_path_failures_are_structured;
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
          Alcotest.test_case "verified snapshot module paths" `Quick
            verified_snapshot_is_the_only_module_path_input;
        ] );
    ]
