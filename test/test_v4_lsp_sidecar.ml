module Store = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module Sidecar = Yeokcham_v4_lsp_sidecar
module Config = Yeokcham_v4_semantic_config

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

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let rec tree root relative =
  let path = Filename.concat root relative in
  Sys.readdir path |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun name ->
      let child = Filename.concat relative name in
      let full = Filename.concat root child in
      match (Unix.lstat full).Unix.st_kind with
      | Unix.S_DIR -> tree root child
      | Unix.S_REG ->
          [
            child ^ "\000" ^ In_channel.with_open_bin full In_channel.input_all;
          ]
      | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
          [ child ])

let fake_server () =
  let from_test_binary =
    Sys.executable_name |> Filename.dirname |> Filename.dirname |> fun build ->
    Filename.concat build "test/fake_lsp_server.exe"
  in
  match
    List.find_opt Sys.file_exists
      [ from_test_binary; "_build/default/test/fake_lsp_server.exe" ]
  with
  | Some executable -> executable
  | None -> Alcotest.fail "cannot locate fake LSP server"

let snapshots root store =
  write_file root "main.ml" "let version = 1\n";
  let _, base =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  write_file root "main.ml" "let version = 2\n";
  let _, left =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  write_file root "main.ml" "let version = 3\n";
  let _, right =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  (base, left, right)

let server ?(overlap_sensitivity = Config.Same_symbol) mode arguments =
  {
    Config.name = "fake";
    program = fake_server ();
    arguments = mode :: arguments;
    enabled = true;
    match_scope = Config.Extensions [ ".ml" ];
    overlap_sensitivity;
  }

let inspect store configured (base, left, right) =
  Sidecar.inspect ~store ~server:configured ~base:("base", base)
    ~left:("left", left) ~right:("right", right) ~paths:[ "main.ml" ]

let reports_observations_from_disposable_snapshots () =
  with_directory "yeokcham-v4-lsp-" (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let capture = Filename.temp_file "yeokcham-v4-lsp-capture-" "" in
      Fun.protect
        ~finally:(fun () ->
          try Unix.unlink capture with Unix.Unix_error _ -> ())
        (fun () ->
          let snapshots = snapshots root store in
          match
            inspect store (server "normal" [ "--capture"; capture ]) snapshots
          with
          | Sidecar.Available report ->
              Alcotest.(check string)
                "reported server"
                (Some "fake-lsp" |> Option.get)
                (Option.value report.server.reported_name ~default:"missing");
              Alcotest.(check int)
                "three snapshot roles" 3
                (List.length report.snapshots);
              Alcotest.(check int)
                "symbols bind all snapshots" 3
                (List.length report.symbols);
              Alcotest.(check int)
                "same changed symbol is advisory overlap" 1
                (List.length report.possible_overlaps);
              let received =
                In_channel.with_open_bin capture In_channel.input_all
              in
              Alcotest.(check bool)
                "server received a disposable file URI" true
                (String.starts_with ~prefix:"file://" received);
              Alcotest.(check bool)
                "server never received live root URI" false
                (String.starts_with ~prefix:("file://" ^ root) received)
          | Sidecar.Unavailable { reason; _ } -> Alcotest.fail reason))

let rejected_or_bad_server_output_preserves_repository () =
  with_directory "yeokcham-v4-lsp-state-" (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let snapshots = snapshots root store in
      let before = tree root ".yeokcham" in
      (match inspect store (server "apply-edit" []) snapshots with
      | Sidecar.Available _ -> ()
      | Sidecar.Unavailable { reason; _ } -> Alcotest.fail reason);
      (match inspect store (server "execute-command" []) snapshots with
      | Sidecar.Available _ -> ()
      | Sidecar.Unavailable { reason; _ } -> Alcotest.fail reason);
      let after = tree root ".yeokcham" in
      Alcotest.(check (list string))
        "server requests did not write repository" before after;
      (match inspect store (server "oversized" []) snapshots with
      | Sidecar.Unavailable _ -> ()
      | Sidecar.Available _ -> Alcotest.fail "oversized response became advice");
      (match inspect store (server "malformed" []) snapshots with
      | Sidecar.Unavailable _ -> ()
      | Sidecar.Available _ -> Alcotest.fail "malformed response became advice");
      match inspect store (server "timeout" []) snapshots with
      | Sidecar.Unavailable _ -> ()
      | Sidecar.Available _ -> Alcotest.fail "timed out response became advice")

let broader_sensitivity_does_not_require_matching_symbol_names () =
  with_directory "yeokcham-v4-lsp-granularity-" (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let snapshots = snapshots root store in
      let expected mode sensitivity evidence =
        match
          inspect store
            (server ~overlap_sensitivity:sensitivity mode [])
            snapshots
        with
        | Sidecar.Unavailable { reason; _ } -> Alcotest.fail reason
        | Sidecar.Available report ->
            Alcotest.(check int)
              (mode ^ " reports one possible overlap")
              1
              (List.length report.possible_overlaps);
            Alcotest.(check string)
              (mode ^ " reports its configured evidence")
              evidence
              ( report.possible_overlaps |> List.hd |> fun overlap ->
                Sidecar.overlap_evidence_to_string overlap.evidence )
      in
      expected "nearby" Config.Nearby_ranges "nearby-returned-ranges";
      expected "references" Config.References "shared-definition-or-reference")

let () =
  Alcotest.run "yeokcham v4 LSP sidecar"
    [
      ( "sidecar",
        [
          Alcotest.test_case "disposable snapshots" `Quick
            reports_observations_from_disposable_snapshots;
          Alcotest.test_case "reject and bound" `Quick
            rejected_or_bad_server_output_preserves_repository;
          Alcotest.test_case "broader sensitivity" `Quick
            broader_sensitivity_does_not_require_matching_symbol_names;
        ] );
    ]
