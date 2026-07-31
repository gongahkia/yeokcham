module Adapter = Paengi_typescript_adapter
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
    | Unix.S_SOCK -> Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_directory prefix run =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let write_file path contents =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel contents)

let fixture_path name =
  [
    Filename.concat "fixtures/semantic-adapter" name;
    Filename.concat "test/fixtures/semantic-adapter" name;
  ]
  |> List.find_opt Sys.file_exists
  |> function
  | Some path -> path
  | None -> Alcotest.fail ("missing adapter fixture " ^ name)

let options =
  Adapter.Protocol.
    {
      strict = false;
      jsx = Some `Preserve;
      module_resolution = Some `Bundler;
      base_url = None;
      paths = [];
    }

let assert_unavailable predicate = function
  | Adapter.Unavailable reason when predicate reason -> ()
  | Adapter.Unavailable reason ->
      Alcotest.fail ("unexpected unavailable result: " ^ Adapter.unavailable_reason_to_string reason)
  | Adapter.Available _ -> Alcotest.fail "adapter unexpectedly succeeded"

let handshake_reports_pinned_local_compiler () =
  match Adapter.handshake Adapter.default_configuration with
  | Adapter.Available handshake ->
      Alcotest.(check string) "exact TypeScript version" "5.9.3"
        handshake.typescript_version;
      Alcotest.(check string) "minimum Node version" "14.17.0"
        handshake.minimum_node_version;
      Alcotest.(check bool) "virtual file capability" true
        (List.mem "virtual-files" handshake.capabilities)
  | Adapter.Unavailable reason ->
      Alcotest.fail (Adapter.unavailable_reason_to_string reason)

let verified_snapshot_is_the_only_analysis_input () =
  with_directory "paengi-typescript-adapter-" (fun root ->
      let source = "\239\187\191// 😀\r\nexport function café(value: string): string { return value; }\r\n" in
      Unix.mkdir (Filename.concat root "src") 0o700;
      write_file (Filename.concat root "src/main.ts") source;
      write_file
        (Filename.concat root "src/view.tsx")
        "export const View = () => <div title=\"😀\">text</div>;\n";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let snapshot, _ = Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string in
      match
        Adapter.analyze_snapshot Adapter.default_configuration ~store ~snapshot
          ~compiler_options:options
      with
      | Adapter.Unavailable reason ->
          Alcotest.fail (Adapter.unavailable_reason_to_string reason)
      | Adapter.Available analysis ->
          Alcotest.(check bool) "parser is complete" true
            (Adapter.Protocol.analysis_parser_complete analysis);
          Alcotest.(check bool) "resolution is complete" true
            (Adapter.Protocol.analysis_resolution_complete analysis);
          let declarations = Adapter.Protocol.analysis_declarations analysis in
          let cafe =
            List.find_opt
              (fun declaration ->
                String.equal
                  (Option.value ~default:"" (Adapter.Protocol.declaration_syntactic_name declaration))
                  "café")
              declarations
          in
          match cafe with
          | None -> Alcotest.fail "unicode TypeScript declaration was not returned"
          | Some declaration ->
              Alcotest.(check string) "snapshot path" "src/main.ts"
                (Adapter.Protocol.declaration_path declaration);
              Alcotest.(check bool) "export status" true
                (Adapter.Protocol.declaration_exported declaration);
              let span =
                Option.value ~default:(Alcotest.fail "missing declaration name span")
                  (Adapter.Protocol.declaration_name_span declaration)
              in
              Alcotest.(check int) "UTF-16 source position became UTF-8 byte offset"
                (String.index source 'c')
                (Adapter.Protocol.span_start_byte span))

let failures_are_semantic_unavailable () =
  let request =
    Adapter.Protocol.make_source_file ~path:"src/a.ts" ~language:Adapter.Protocol.Ts
      ~contents:"export const value = 1;\n"
  in
  let analyze configuration =
    Adapter.analyze_files configuration
      ~snapshot_id:(String.make 64 '1') ~root_files:[ "src/a.ts" ]
      ~files:[ request ] ~compiler_options:options
  in
  assert_unavailable
    (function Adapter.Adapter_missing _ -> true | _ -> false)
    (analyze { Adapter.default_configuration with adapter_path = "missing-adapter.mjs" });
  assert_unavailable
    (function Adapter.Adapter_timeout _ -> true | _ -> false)
    (analyze
       {
         Adapter.default_configuration with
         adapter_path = fixture_path "slow.mjs";
         timeout_ms = 25;
       });
  assert_unavailable
    (function Adapter.Malformed_adapter_response _ -> true | _ -> false)
    (analyze { Adapter.default_configuration with adapter_path = fixture_path "malformed.mjs" });
  assert_unavailable
    (function Adapter.Adapter_crashed _ -> true | _ -> false)
    (analyze { Adapter.default_configuration with adapter_path = fixture_path "crash.mjs" });
  assert_unavailable
    (function Adapter.Adapter_output_too_large _ -> true | _ -> false)
    (analyze
       {
         Adapter.default_configuration with
         adapter_path = fixture_path "large-output.mjs";
         max_response_bytes = 128;
       })

let unsafe_paths_do_not_start_analysis () =
  let source =
    Adapter.Protocol.make_source_file ~path:"../escape.ts" ~language:Adapter.Protocol.Ts
      ~contents:"export const x = 1;\n"
  in
  assert_unavailable
    (function Adapter.Adapter_error { code = "invalid-path"; _ } -> true | _ -> false)
    (Adapter.analyze_files Adapter.default_configuration
       ~snapshot_id:(String.make 64 '1') ~root_files:[ "../escape.ts" ]
       ~files:[ source ] ~compiler_options:options)

let () =
  Alcotest.run "TypeScript adapter"
    [
      ( "protocol",
        [
          Alcotest.test_case "pinned handshake" `Quick
            handshake_reports_pinned_local_compiler;
          Alcotest.test_case "adapter failures remain unavailable" `Quick
            failures_are_semantic_unavailable;
          Alcotest.test_case "unsafe virtual path is rejected" `Quick
            unsafe_paths_do_not_start_analysis;
        ] );
      ( "snapshot",
        [
          Alcotest.test_case "verified snapshot virtual files" `Quick
            verified_snapshot_is_the_only_analysis_input;
        ] );
    ]
