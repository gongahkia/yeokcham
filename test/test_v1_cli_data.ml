module Cli_data = Yeokcham_v1_cli_data

let fixture_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_file path = In_channel.with_open_bin path In_channel.input_all

let canonical_success_fixture_round_trips () =
  let envelope =
    Cli_data.success ~command:"verify"
      ~result:(`Assoc [ ("damages", `List []) ])
      ~warnings:[]
  in
  let expected =
    read_file (fixture_path "v1/cli-envelope-v1.json") |> String.trim
  in
  Alcotest.(check string) "canonical JSON" expected (Cli_data.encode envelope);
  let decoded = Cli_data.decode expected |> Result.get_ok in
  Alcotest.(check string)
    "command survives decoding" "verify" (Cli_data.command decoded);
  Alcotest.(check bool) "success survives decoding" true (Cli_data.ok decoded)

let generic_completed_fixture_round_trips () =
  let envelope =
    Cli_data.success ~command:"save"
      ~result:(Cli_data.command_result_json Cli_data.Completed)
      ~warnings:[]
  in
  let expected =
    read_file (fixture_path "v1/cli-completed-envelope-v1.json") |> String.trim
  in
  Alcotest.(check string)
    "generic completed JSON" expected (Cli_data.encode envelope);
  let decoded = Cli_data.decode expected |> Result.get_ok in
  Alcotest.(check string)
    "completed fixture command" "save" (Cli_data.command decoded)

let decoder_rejects_unknown_duplicate_and_inconsistent_fields () =
  let valid =
    "{\"schema_version\":1,\"command\":\"verify\",\"ok\":true,\"result\":{},\"warnings\":[],\"error\":null}"
  in
  let unknown =
    "{\"schema_version\":1,\"command\":\"verify\",\"ok\":true,\"result\":{},\"warnings\":[],\"error\":null,\"future\":true}"
  in
  let duplicate =
    "{\"schema_version\":1,\"command\":\"verify\",\"command\":\"repair\",\"ok\":true,\"result\":{},\"warnings\":[],\"error\":null}"
  in
  let inconsistent =
    "{\"schema_version\":1,\"command\":\"verify\",\"ok\":false,\"result\":{},\"warnings\":[],\"error\":null}"
  in
  List.iter
    (fun invalid ->
      Alcotest.(check bool)
        "invalid envelope refuses" true
        (Result.is_error (Cli_data.decode invalid)))
    [ unknown; duplicate; inconsistent ];
  Alcotest.(check bool)
    "valid envelope decodes" true
    (Result.is_ok (Cli_data.decode valid))

let () =
  Alcotest.run "V1 CLI data"
    [
      ( "envelope",
        [
          Alcotest.test_case "canonical success fixture" `Quick
            canonical_success_fixture_round_trips;
          Alcotest.test_case "generic completed fixture" `Quick
            generic_completed_fixture_round_trips;
          Alcotest.test_case "strict decoder" `Quick
            decoder_rejects_unknown_duplicate_and_inconsistent_fields;
        ] );
    ]
