module Envelope = Paengi_envelope
module Encoding = Paengi_encoding
module Golden = Paengi_testkit.Golden_fixture
module Hash = Paengi_hash.Sha256
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Validation = Paengi_validation

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let hex bytes =
  let alphabet = "0123456789abcdef" in
  let output = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set output (index * 2) alphabet.[value lsr 4];
      Bytes.set output ((index * 2) + 1) alphabet.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string output

let digest value = Hash.digest_string value |> Hash.to_raw_string

let stream ?(limit = max_int) value =
  let retained = String.sub value 0 (min limit (String.length value)) in
  { Validation.digest = digest value; retained; truncated = String.length retained < String.length value }

let result ?(status = Validation.Passed) ?(exit_code = Some 0) ?signal
    ?execution_error ?(stdout = stream "") ?(stderr = stream "") () =
  {
    Validation.runner_status = status;
    runner_exit_code = exit_code;
    runner_signal = signal;
    runner_execution_error = execution_error;
    runner_duration_ms = 7L;
    runner_stdout = stdout;
    runner_stderr = stderr;
    runner_environment_fingerprint = Some (digest "environment");
  }

let fake_result = ref (result ())

module Fake_runner : Validation.Process_runner = struct
  let run _ ~working_directory:_ = !fake_result
end

let command ?(timeout_ms = 1000L) ?(max_stdout_bytes = 1024)
    ?(max_stderr_bytes = 1024) ?(retain_output = false) () =
  {
    Validation.executable = "/usr/bin/true";
    arguments = [];
    working_directory = [];
    timeout_ms;
    max_stdout_bytes;
    max_stderr_bytes;
    environment_policy = Validation.Empty;
    environment = [ ("A", "1") ];
    retain_output;
    format_version = 1L;
    mandatory_features = 0L;
  }

let with_store run =
  let root = Filename.temp_file "paengi-validation-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK -> Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let source = Filename.concat root "source" in
      Unix.mkdir source 0o700;
      Out_channel.with_open_bin (Filename.concat source "tracked") (fun channel ->
          Out_channel.output_string channel "snapshot-bytes");
      let snapshot, _ =
        Snapshot.scan ~root:source ~store |> require_ok Snapshot.error_to_string
      in
      run root source store snapshot)

let golden name =
  let paths = [ Filename.concat "golden" name; Filename.concat "test/golden" name ] in
  match List.find_opt Sys.file_exists paths with
  | Some path -> Golden.read_lower_hex_file path |> require_ok Fun.id
  | None -> Alcotest.fail ("missing golden fixture: " ^ name)

let evidence_fixture () =
  let snapshot =
    Store.Stored_object_id.of_raw_bytes (String.make 32 '\001')
    |> Option.get |> Snapshot.Snapshot.of_stored_object_id
  in
  let command = command ~max_stdout_bytes:3 ~max_stderr_bytes:2 () in
  let evidence =
    Validation.create_evidence ~snapshot ~command ~command_index:4
      ~result:
        (result ~stdout:(stream ~limit:3 "abcd") ~stderr:(stream ~limit:2 "xyz") ())
      ~stdout_output:None ~stderr_output:None ~observed_at:9L
    |> require_ok Validation.error_to_string
  in
  let payload = Validation.evidence_payload evidence |> require_ok Validation.error_to_string in
  Envelope.create ~object_type:Envelope.Validation ~object_format_version:1
    ~mandatory_features:0L ~payload ()
  |> require_ok Envelope.creation_error_to_string |> Envelope.encode

let canonical_golden_and_inverse_decoder () =
  let bytes = evidence_fixture () in
  Alcotest.(check string) "validation evidence golden"
    (golden "validation-evidence-v1.peng.hex") bytes;
  let envelope = Envelope.decode bytes |> require_ok Envelope.decode_error_to_string in
  let evidence =
    Validation.decode_evidence_payload (Envelope.payload envelope)
    |> require_ok Validation.error_to_string
  in
  let encoded = Validation.evidence_payload evidence |> require_ok Validation.error_to_string in
  Alcotest.(check bool) "validation inverse decoder" true
    (Encoding.equal encoded (Envelope.payload envelope))

let validation_targets_exact_snapshot_and_survives_reopen () =
  with_store (fun _root _source store snapshot ->
      fake_result := result ~stdout:(stream "ok") ();
      let evidence, object_id =
        Validation.run ~runner:(module Fake_runner) ~store ~snapshot
          ~command:(command ~retain_output:true ()) ~command_index:0 ~observed_at:1L ()
        |> require_ok Validation.error_to_string
      in
      Alcotest.(check bool) "evidence snapshot is exact" true
        (Snapshot.Snapshot.equal_id snapshot (Validation.evidence_snapshot evidence));
      let reopened = Store.open_repository ~root:(Store.root store) |> require_ok Store.error_to_string in
      let loaded =
        Validation.load_evidence reopened object_id |> require_ok Validation.error_to_string
      in
      Alcotest.(check bool) "reopen preserves binding" true
        (Snapshot.Snapshot.equal_id snapshot (Validation.evidence_snapshot loaded));
      Alcotest.(check bool) "retained stdout object" true
        (Option.is_some (Validation.evidence_stdout_output loaded)))

let statuses_and_bounds_are_evidence () =
  with_store (fun _root _source store snapshot ->
      let cases =
        [
          ("passed", result ());
          ("failed", result ~status:Validation.Failed ~exit_code:(Some 7) ());
          ("timeout", result ~status:Validation.Timed_out ~exit_code:None ~signal:Sys.sigterm ());
          ( "execution-error",
            result ~status:Validation.Execution_error ~exit_code:None
              ~execution_error:"execve failed" () );
        ]
      in
      List.iteri
        (fun index (name, next) ->
          fake_result := next;
          let evidence, _ =
            Validation.run ~runner:(module Fake_runner) ~store ~snapshot
              ~command:(command ()) ~command_index:index ~observed_at:(Int64.of_int index) ()
            |> require_ok Validation.error_to_string
          in
          Alcotest.(check string) name name
            (match Validation.evidence_status evidence with
            | Validation.Passed -> "passed"
            | Validation.Failed -> "failed"
            | Validation.Timed_out -> "timeout"
            | Validation.Execution_error -> "execution-error"))
        cases;
      fake_result :=
        result ~stdout:(stream ~limit:3 "abcdef") ~stderr:(stream ~limit:2 "wxyz") ();
      let evidence, _ =
        Validation.run ~runner:(module Fake_runner) ~store ~snapshot
          ~command:(command ~max_stdout_bytes:3 ~max_stderr_bytes:2 ())
          ~command_index:9 ~observed_at:9L ()
        |> require_ok Validation.error_to_string
      in
      Alcotest.(check bool) "stdout truncated" true
        (Validation.evidence_stdout_truncated evidence);
      Alcotest.(check bool) "stderr truncated" true
        (Validation.evidence_stderr_truncated evidence))

let malformed_commands_reject_and_validation_does_not_move_refs () =
  with_store (fun _root _source store snapshot ->
      let invalid = { (command ()) with Validation.working_directory = [ ".." ] } in
      (match Validation.make_command invalid with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "unsafe command accepted");
      let scratch = Scratch.open_repository store in
      ignore
        (Scratch.create_initial scratch ~snapshot ~created_at:0L
        |> require_ok Scratch.error_to_string);
      let before = Store.read_ref store ~name:"scratch-head" |> require_ok Store.error_to_string in
      fake_result := result ();
      ignore
        (Validation.run ~runner:(module Fake_runner) ~store ~snapshot
           ~command:(command ()) ~command_index:0 ~observed_at:0L ()
        |> require_ok Validation.error_to_string);
      let after = Store.read_ref store ~name:"scratch-head" |> require_ok Store.error_to_string in
      Alcotest.(check bool) "validation does not move scratch head" true
        (Option.equal Store.Mutable_ref.equal before after))

let unix_runner_timeout_and_direct_execution () =
  with_store (fun _root _source store snapshot ->
      let passed = { (command ()) with Validation.executable = "/usr/bin/printf"; arguments = [ "ok" ] } in
      let evidence, _ =
        Validation.run ~store ~snapshot ~command:passed ~command_index:0 ~observed_at:0L ()
        |> require_ok Validation.error_to_string
      in
      Alcotest.(check bool) "direct argv command passes" true
        (Validation.evidence_passed evidence);
      let timeout = { (command ~timeout_ms:0L ()) with Validation.executable = "/bin/sleep"; arguments = [ "1" ] } in
      Alcotest.(check int64) "timeout configuration" 0L timeout.Validation.timeout_ms;
      let evidence, _ =
        Validation.run ~store ~snapshot ~command:timeout ~command_index:1 ~observed_at:1L ()
        |> require_ok Validation.error_to_string
      in
      Alcotest.(check string) "timeout is evidence" "timeout"
        (match Validation.evidence_status evidence with
        | Validation.Passed -> "passed"
        | Validation.Failed -> "failed"
        | Validation.Timed_out -> "timeout"
        | Validation.Execution_error -> "execution-error"))

let () =
  match Sys.getenv_opt "PAENGI_PRINT_GOLDEN" with
  | Some "1" -> print_endline (hex (evidence_fixture ()))
  | None | Some _ ->
      Alcotest.run "paengi_validation"
        [
          ( "validation",
            [
              Alcotest.test_case "canonical golden and inverse decoder" `Quick
                canonical_golden_and_inverse_decoder;
              Alcotest.test_case "exact snapshot and reopen" `Quick
                validation_targets_exact_snapshot_and_survives_reopen;
              Alcotest.test_case "statuses and bounded output" `Quick
                statuses_and_bounds_are_evidence;
              Alcotest.test_case "malformed and no refs" `Quick
                malformed_commands_reject_and_validation_does_not_move_refs;
              Alcotest.test_case "unix direct runner and timeout" `Slow
                unix_runner_timeout_and_direct_execution;
            ] );
        ]
