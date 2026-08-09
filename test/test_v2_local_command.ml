module Command = Yeokcham_local_command
module Cutover = Yeokcham_cutover
module Service = Yeokcham_local_service
module Store = Yeokcham_store

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let () = Printf.printf "v2 local command property base seed: %d\n%!" base_seed

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

let with_root run =
  let root = Filename.temp_file "yeokcham-v2-local-command-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let create_legacy_root root =
  let metadata = Filename.concat root ".yeokcham" in
  Unix.mkdir metadata 0o700;
  List.iter
    (fun name -> Unix.mkdir (Filename.concat metadata name) 0o700)
    [ "objects"; "refs"; "locks" ];
  write_file (Filename.concat metadata "format") Store.repository_format

let parser_and_renderer_are_pure () =
  let parse ~name ~arguments =
    Command.parse ~name ~arguments |> require_ok Command.parse_error_to_string
  in
  Alcotest.(check bool)
    "init command parses" true
    (parse ~name:"init" ~arguments:[] = Command.Init);
  Alcotest.(check bool)
    "archive command parses" true
    (parse ~name:"archive" ~arguments:[ "--name"; "v1-archive" ]
    = Command.Archive { archive_name = "v1-archive" });
  Alcotest.(check bool)
    "reset command parses" true
    (parse ~name:"reset"
       ~arguments:[ "--confirm-v2-reset"; "--archive"; "v1-archive" ]
    = Command.Reset { archive_name = "v1-archive" });
  Alcotest.(check bool)
    "missing reset confirmation rejects" true
    (Result.is_error
       (Command.parse ~name:"reset" ~arguments:[ "--archive"; "v1-archive" ]));
  Alcotest.(check string)
    "initialized rendering" "initialized empty V2 repository"
    (Command.render Command.Initialized);
  Alcotest.(check string)
    "archive rendering" "archived=/tmp/archive manifest=/tmp/archive-manifest"
    (Command.render
       (Command.Archived
          {
            Service.archive_path = "/tmp/archive";
            manifest_path = "/tmp/archive-manifest";
            already_archived = false;
          }))

let initialization_is_reusable_and_idempotent () =
  with_root (fun root ->
      let initialized =
        Service.initialize ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "empty root initializes" true
        (initialized = Service.Initialized);
      Service.require_v2 ~root |> require_ok Service.error_to_string;
      let repeated =
        Service.initialize ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "V2 root is idempotent" true
        (repeated = Service.Already_initialized);
      let response =
        Command.execute ~root Command.Init |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "command adapter reuses service outcome" true
        (response = Command.Already_initialized))

let legacy_archive_and_confirmed_reset_are_service_effects () =
  with_root (fun root ->
      create_legacy_root root;
      let initialization =
        Service.initialize ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "legacy root is refused" true
        (initialization = Service.Init_refused Service.Legacy);
      let classification =
        Cutover.detect ~root |> require_ok Cutover.error_to_string
      in
      Alcotest.(check bool)
        "refused initialization retains legacy root" true
        (classification = Cutover.Legacy);
      Alcotest.(check bool)
        "unconfirmed reset rejects" true
        (Result.is_error
           (Service.reset ~root ~archive_name:"legacy-v1" ~confirm:false));
      let archive =
        Service.archive ~root ~archive_name:"legacy-v1"
        |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "first archive is not a retry" false archive.Service.already_archived;
      let reset =
        Service.reset ~root ~archive_name:"legacy-v1" ~confirm:true
        |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "first reset is not a retry" true (reset = Service.Reset);
      Service.require_v2 ~root |> require_ok Service.error_to_string)

let parser_round_trip =
  QCheck2.Test.make ~count:100 ~print:Fun.id
    ~name:"exact archive parser/rendering round trip"
    QCheck2.Gen.(string_size (int_range 0 96))
    (fun archive_name ->
      let parsed =
        Command.parse ~name:"archive" ~arguments:[ "--name"; archive_name ]
      in
      let rendered =
        Command.render
          (Command.Archived
             {
               Service.archive_path = "/archive/" ^ archive_name;
               manifest_path = "/manifest/" ^ archive_name;
               already_archived = false;
             })
      in
      parsed = Ok (Command.Archive { archive_name })
      && String.equal rendered
           ("archived=/archive/" ^ archive_name ^ " manifest=/manifest/"
          ^ archive_name))

let () =
  Alcotest.run "V2 local command adapters"
    [
      ( "unit",
        [
          Alcotest.test_case "parser and renderer are pure" `Quick
            parser_and_renderer_are_pure;
          Alcotest.test_case "initialization is reusable and idempotent" `Quick
            initialization_is_reusable_and_idempotent;
          Alcotest.test_case "legacy archive and reset are service effects"
            `Quick legacy_archive_and_confirmed_reset_are_service_effects;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed |])
            parser_round_trip;
        ] );
    ]
