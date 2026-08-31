module Config = Yeokcham_v4_semantic_config
module Golden = Yeokcham_testkit.Golden_fixture

[@@@warning "-4-40-42"]

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

let with_repository run =
  let root = Filename.temp_file "yeokcham-v4-semantic-config-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".yeokcham") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let server ?(enabled = true) ?(match_scope = Config.Extensions [ ".ml" ])
    ?(overlap_sensitivity = Config.Same_symbol) name =
  {
    Config.name;
    program = "/usr/bin/ocamllsp";
    arguments = [ "--stdio" ];
    enabled;
    match_scope;
    overlap_sensitivity;
  }

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let canonical_fixture_round_trips () =
  let fixture =
    Golden.decode_canonical_lower_hex_file
      ~path:(golden_path "v4/semantic-lsp-v1.hex")
      ~decode:Config.decode
      ~encode:(fun value ->
        Config.encode value |> require_ok Config.error_to_string)
      ~error_to_string:Config.error_to_string
    |> require_ok Fun.id
  in
  Alcotest.(check (list string))
    "fixture server names" [ "ocaml" ]
    (List.map (fun (server : Config.server) -> server.name) fixture)

let config_is_local_canonical_and_private () =
  with_repository (fun root ->
      let ocaml = server "ocaml" in
      Config.add ~root ~server:ocaml |> require_ok Config.error_to_string;
      let path = Config.path ~root in
      Alcotest.(check int)
        "private local config mode" 0o600
        ((Unix.stat path).Unix.st_perm land 0o777);
      let stored = In_channel.with_open_bin path In_channel.input_all in
      let expected =
        Config.encode [ ocaml ] |> require_ok Config.error_to_string
      in
      Alcotest.(check string) "canonical bytes written" expected stored;
      match Config.add ~root ~server:ocaml with
      | Error (Config.Duplicate_server "ocaml") -> ()
      | Error error -> Alcotest.fail (Config.error_to_string error)
      | Ok () -> Alcotest.fail "duplicate semantic server was accepted")

let matching_uses_the_declared_granularity () =
  let extensions =
    server ~match_scope:(Config.Extensions [ ".ml"; ".mli" ]) "ocaml"
  in
  let globs =
    server ~match_scope:(Config.Path_globs [ "src/**/*.ml" ]) "source"
  in
  let all = server ~match_scope:Config.All_files "all" in
  Alcotest.(check bool)
    "extension matches ml" true
    (Config.matches_path extensions "src/main.ml");
  Alcotest.(check bool)
    "extension excludes markdown" false
    (Config.matches_path extensions "README.md");
  Alcotest.(check bool)
    "glob matches nested source" true
    (Config.matches_path globs "src/nested/main.ml");
  Alcotest.(check bool)
    "glob excludes root source" false
    (Config.matches_path globs "main.ml");
  Alcotest.(check bool)
    "all files matches source" true
    (Config.matches_path all "README.md");
  Alcotest.(check bool)
    "unsafe path never matches" false
    (Config.matches_path all "../outside.ml")

let invalid_scope_is_rejected_before_write () =
  with_repository (fun root ->
      let invalid =
        server ~match_scope:(Config.Path_globs [ "../*.ml" ]) "ocaml"
      in
      match Config.add ~root ~server:invalid with
      | Error (Config.Invalid_match_scope _) ->
          Alcotest.(check bool)
            "invalid config was not written" false
            (Sys.file_exists (Config.path ~root))
      | Error error -> Alcotest.fail (Config.error_to_string error)
      | Ok () -> Alcotest.fail "unsafe glob was accepted")

let () =
  Alcotest.run "yeokcham v4 semantic config"
    [
      ( "config",
        [
          Alcotest.test_case "canonical fixture" `Quick
            canonical_fixture_round_trips;
          Alcotest.test_case "local canonical private" `Quick
            config_is_local_canonical_and_private;
          Alcotest.test_case "matching granularity" `Quick
            matching_uses_the_declared_granularity;
          Alcotest.test_case "invalid scope" `Quick
            invalid_scope_is_rejected_before_write;
        ] );
    ]
