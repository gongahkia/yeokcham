module Adapter = Paengi_typescript_adapter
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
    Filename.concat "fixtures/semantic-adapter" name;
    Filename.concat "test/fixtures/semantic-adapter" name;
  ]
  |> List.find_opt Sys.file_exists
  |> function
  | Some path -> path
  | None -> Alcotest.fail ("missing adapter fixture " ^ name)

let adapter_path () =
  [
    "tools/paengi-typescript-adapter/adapter.mjs";
    "../tools/paengi-typescript-adapter/adapter.mjs";
  ]
  |> List.find_opt Sys.file_exists
  |> function
  | Some path -> path
  | None -> Alcotest.fail "missing TypeScript adapter"

let configuration =
  Adapter.configuration_with ~adapter_path:(adapter_path ())
    Adapter.default_configuration

let options = Adapter.Protocol.default_compiler_options

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

let handshake_reports_pinned_local_compiler () =
  match Adapter.handshake configuration with
  | Adapter.Available handshake ->
      Alcotest.(check string)
        "exact TypeScript version" "5.9.3"
        (Adapter.handshake_typescript_version handshake);
      Alcotest.(check string)
        "minimum Node version" "14.17.0"
        (Adapter.handshake_minimum_node_version handshake);
      Alcotest.(check bool)
        "virtual file capability" true
        (List.mem "virtual-files" (Adapter.handshake_capabilities handshake))
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)

let verified_snapshot_is_the_only_analysis_input () =
  with_directory "paengi-typescript-adapter-" (fun root ->
      let source =
        "\239\187\191// 😀\r\n\
         export function café(value: string): string { return value; }\r\n"
      in
      Unix.mkdir (Filename.concat root "src") 0o700;
      write_file (Filename.concat root "src/main.ts") source;
      write_file
        (Filename.concat root "src/view.tsx")
        "export const View = () => <div title=\"😀\">text</div>;\n";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      match
        Adapter.analyze_snapshot configuration ~store ~snapshot
          ~compiler_options:options
      with
      | Adapter.Unavailable reason ->
          Alcotest.fail (Adapter.unavailable_reason_to_string reason)
      | Adapter.Available analysis -> (
          Alcotest.(check bool)
            "parser is complete" true
            (Adapter.Protocol.analysis_parser_complete analysis);
          Alcotest.(check bool)
            "resolution is complete" true
            (Adapter.Protocol.analysis_resolution_complete analysis);
          let declarations = Adapter.Protocol.analysis_declarations analysis in
          let cafe =
            List.find_opt
              (fun declaration ->
                String.equal
                  (Option.value ~default:""
                     (Adapter.Protocol.declaration_syntactic_name declaration))
                  "café")
              declarations
          in
          match cafe with
          | None ->
              Alcotest.fail "unicode TypeScript declaration was not returned"
          | Some declaration ->
              Alcotest.(check string)
                "snapshot path" "src/main.ts"
                (Adapter.Protocol.declaration_path declaration);
              Alcotest.(check bool)
                "export status" true
                (Adapter.Protocol.declaration_exported declaration);
              let span =
                match Adapter.Protocol.declaration_name_span declaration with
                | Some span -> span
                | None -> Alcotest.fail "missing declaration name span"
              in
              Alcotest.(check int)
                "UTF-16 source position became UTF-8 byte offset"
                (String.index_from source 25 'c')
                (Adapter.Protocol.span_start_byte span)))

let failures_are_semantic_unavailable () =
  let request =
    Adapter.Protocol.make_source_file ~path:"src/a.ts"
      ~language:Adapter.Protocol.Ts ~contents:"export const value = 1;\n"
  in
  let analyze configuration =
    Adapter.analyze_files configuration ~snapshot_id:(String.make 64 '1')
      ~root_files:[ "src/a.ts" ] ~files:[ request ] ~compiler_options:options
  in
  assert_unavailable_contains "adapter is missing"
    (analyze
       (Adapter.configuration_with ~adapter_path:"missing-adapter.mjs"
          Adapter.default_configuration));
  assert_unavailable_contains "timed out"
    (analyze
       (Adapter.configuration_with ~adapter_path:(fixture_path "slow.mjs")
          ~timeout_ms:25 Adapter.default_configuration));
  assert_unavailable_contains "malformed adapter response"
    (analyze
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "malformed.mjs")
          Adapter.default_configuration));
  assert_unavailable_contains "adapter crashed"
    (analyze
       (Adapter.configuration_with ~adapter_path:(fixture_path "crash.mjs")
          Adapter.default_configuration));
  assert_unavailable_contains "adapter output exceeded"
    (analyze
       (Adapter.configuration_with
          ~adapter_path:(fixture_path "large-output.mjs")
          ~max_response_bytes:128 Adapter.default_configuration))

let unavailable_adapter_preserves_textual_operation () =
  let source = "// independent edit\nexport const value = 1;\n" in
  let semantic =
    Adapter.analyze_files
      (Adapter.configuration_with ~adapter_path:"missing-adapter.mjs"
         Adapter.default_configuration)
      ~snapshot_id:(String.make 64 '3') ~root_files:[ "src/a.ts" ]
      ~files:
        [
          Adapter.Protocol.make_source_file ~path:"src/a.ts"
            ~language:Adapter.Protocol.Ts ~contents:source;
        ]
      ~compiler_options:options
  in
  assert_unavailable_contains "adapter is missing" semantic;
  let start_byte = String.index source '1' in
  let patch =
    Patch.make
      ~original_span:Patch.{ start_byte; end_byte = start_byte + 1 }
      ~expected_preimage:"1" ~replacement:"2" ~before_context:"value = "
      ~after_context:";\n"
      ~relaxed_context_bytes:Patch.default_relaxed_context_bytes
    |> require_ok Fun.id
  in
  match Patch.apply ~source patch with
  | Patch.Applied applied ->
      Alcotest.(check string)
        "textual operation remains available"
        "// independent edit\nexport const value = 2;\n" applied.contents
  | Patch.Already_satisfied _ | Patch.Conflict _ ->
      Alcotest.fail "unavailable semantic adapter blocked a textual operation"

let unsafe_paths_do_not_start_analysis () =
  let source =
    Adapter.Protocol.make_source_file ~path:"../escape.ts"
      ~language:Adapter.Protocol.Ts ~contents:"export const x = 1;\n"
  in
  assert_unavailable_contains "adapter error invalid-path"
    (Adapter.analyze_files configuration ~snapshot_id:(String.make 64 '1')
       ~root_files:[ "../escape.ts" ] ~files:[ source ]
       ~compiler_options:options)

let replace_node_preserves_outside_bytes () =
  let source =
    "// prefix 😀\r\n\
     export function greet(name: string): string { return `hello ${name}`; }\r\n\
     // suffix\r\n"
  in
  let file =
    Adapter.Protocol.make_source_file ~path:"src/replace.ts"
      ~language:Adapter.Protocol.Ts ~contents:source
  in
  let snapshot_id = String.make 64 '2' in
  let analysis =
    Adapter.analyze_files configuration ~snapshot_id
      ~root_files:[ "src/replace.ts" ] ~files:[ file ] ~compiler_options:options
  in
  let declaration =
    match analysis with
    | Adapter.Available analysis -> (
        match
          Adapter.Protocol.analysis_declarations analysis
          |> List.find_opt (fun declaration ->
              String.equal
                (Option.value ~default:""
                   (Adapter.Protocol.declaration_syntactic_name declaration))
                "greet")
        with
        | Some declaration -> declaration
        | None -> Alcotest.fail "replace declaration is absent")
    | Adapter.Unavailable reason ->
        Alcotest.fail (Adapter.unavailable_reason_to_string reason)
  in
  let span = Adapter.Protocol.declaration_span declaration in
  let start_byte = Adapter.Protocol.span_start_byte span in
  let end_byte = Adapter.Protocol.span_end_byte span in
  let preimage = String.sub source start_byte (end_byte - start_byte) in
  let target =
    Adapter.make_replace_target ~path:"src/replace.ts" ~declaration_span:span
      ~expected_preimage:preimage
      ~declaration_kind:(Adapter.Protocol.declaration_kind declaration)
      ~declaration_shape_digest:
        (Adapter.Protocol.declaration_shape_digest declaration)
  in
  let replacement =
    "export function greet(name: string): string { return `welcome ${name}`; }"
  in
  let result =
    Adapter.replace_node_files configuration ~snapshot_id
      ~root_files:[ "src/replace.ts" ] ~files:[ file ] ~compiler_options:options
      ~target ~replacement
  in
  (match result with
  | Adapter.Available (Adapter.Replaced _) -> ()
  | Adapter.Available (Adapter.Replace_conflict _) ->
      Alcotest.fail "replace-node returned a conflict for an exact preimage"
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason));
  let output =
    match result with
    | Adapter.Available outcome -> (
        match Adapter.replace_outcome_contents outcome with
        | Some contents -> contents
        | None -> Alcotest.fail "replace-node did not return exact output bytes"
        )
    | Adapter.Unavailable _ -> Alcotest.fail "replace-node became unavailable"
  in
  Alcotest.(check string)
    "exact output bytes"
    (String.sub source 0 start_byte
    ^ replacement
    ^ String.sub source end_byte (String.length source - end_byte))
    output;
  (match result with
  | Adapter.Available outcome ->
      Alcotest.(check string)
        "confidence" "exact"
        (Option.value ~default:"" (Adapter.replace_outcome_confidence outcome));
      Alcotest.(check bool)
        "text fallback was not hidden" false
        (Option.value ~default:true
           (Adapter.replace_outcome_fallback_used outcome))
  | Adapter.Unavailable _ -> Alcotest.fail "replace-node became unavailable");
  let stale =
    Adapter.make_replace_target ~path:"src/replace.ts" ~declaration_span:span
      ~expected_preimage:"stale bytes"
      ~declaration_kind:(Adapter.Protocol.declaration_kind declaration)
      ~declaration_shape_digest:
        (Adapter.Protocol.declaration_shape_digest declaration)
  in
  match
    Adapter.replace_node_files configuration ~snapshot_id
      ~root_files:[ "src/replace.ts" ] ~files:[ file ] ~compiler_options:options
      ~target:stale ~replacement
  with
  | Adapter.Available (Adapter.Replace_conflict _) as result ->
      let outcome =
        match result with
        | Adapter.Available outcome -> outcome
        | Adapter.Unavailable _ -> assert false
      in
      Alcotest.(check string)
        "stale preimage conflict" "preimage-mismatch"
        (Option.value ~default:""
           (Adapter.replace_outcome_conflict_code outcome))
  | Adapter.Available (Adapter.Replaced _) ->
      Alcotest.fail "stale preimage changed bytes"
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)

let () =
  Alcotest.run "TypeScript adapter"
    [
      ( "protocol",
        [
          Alcotest.test_case "pinned handshake" `Quick
            handshake_reports_pinned_local_compiler;
          Alcotest.test_case "adapter failures remain unavailable" `Quick
            failures_are_semantic_unavailable;
          Alcotest.test_case "unavailable adapter preserves textual operation"
            `Quick unavailable_adapter_preserves_textual_operation;
          Alcotest.test_case "unsafe virtual path is rejected" `Quick
            unsafe_paths_do_not_start_analysis;
          Alcotest.test_case "replace-node preserves exact outside bytes" `Quick
            replace_node_preserves_outside_bytes;
        ] );
      ( "snapshot",
        [
          Alcotest.test_case "verified snapshot virtual files" `Quick
            verified_snapshot_is_the_only_analysis_input;
        ] );
    ]
