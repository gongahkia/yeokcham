module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service
module Trust = Yeokcham_v4_trust

let require_success name status stderr =
  match status with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> Alcotest.failf "%s exited %d: %s" name code stderr
  | Unix.WSIGNALED signal ->
      Alcotest.failf "%s was terminated by signal %d: %s" name signal stderr
  | Unix.WSTOPPED signal ->
      Alcotest.failf "%s was stopped by signal %d: %s" name signal stderr

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
  let signer_directory = Filename.temp_file (prefix ^ "signer-") "" in
  Unix.unlink signer_directory;
  Unix.mkdir signer_directory 0o700;
  Unix.putenv "YEOKCHAM_V4_TEST_SIGNER_DIRECTORY" signer_directory;
  Fun.protect
    ~finally:(fun () ->
      remove_tree root;
      remove_tree signer_directory)
    (fun () -> run root)

let with_external_directory prefix run =
  let directory = Filename.temp_file prefix "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree directory)
    (fun () -> run directory)

let executable () =
  let from_test_binary =
    Sys.executable_name |> Filename.dirname |> Filename.dirname
    |> fun build_root -> Filename.concat build_root "bin/yeokcham_v4.exe"
  in
  let candidates = [ from_test_binary; "_build/default/bin/yeokcham_v4.exe" ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "cannot locate the yeokcham-v4 executable"

let run arguments =
  let command =
    executable () :: arguments |> List.map Filename.quote |> String.concat " "
  in
  let stdout, stdin, stderr =
    Unix.open_process_full command (Unix.environment ())
  in
  close_out_noerr stdin;
  let output = In_channel.input_all stdout in
  let errors = In_channel.input_all stderr in
  let status = Unix.close_process_full (stdout, stdin, stderr) in
  (output, errors, status)

let contains output needle =
  let needle_length = String.length needle in
  let rec find index =
    if index + needle_length > String.length output then false
    else if String.equal (String.sub output index needle_length) needle then
      true
    else find (index + 1)
  in
  needle_length > 0 && find 0

let expect_output_contains name needle output =
  Alcotest.(check bool) name true (contains output needle)

let saved_checkpoint output =
  let prefix = "saved " in
  let prefix_length = String.length prefix in
  let rec find index =
    if index + prefix_length > String.length output then
      Alcotest.fail "CLI output did not contain a saved checkpoint"
    else if String.equal (String.sub output index prefix_length) prefix then
      let value_start = index + prefix_length in
      match String.index_from_opt output value_start '\n' with
      | Some value_end -> String.sub output value_start (value_end - value_start)
      | None ->
          Alcotest.fail "saved checkpoint output was not newline-terminated"
    else find (index + 1)
  in
  find 0

let first_prefixed_value prefix output =
  let prefixed_line =
    output |> String.split_on_char '\n'
    |> List.find_opt (fun line -> String.starts_with ~prefix line)
  in
  match prefixed_line with
  | None -> Alcotest.fail ("CLI output did not contain " ^ String.trim prefix)
  | Some line ->
      String.sub line (String.length prefix)
        (String.length line - String.length prefix)

let line_after marker output =
  match String.split_on_char '\n' output with
  | [] -> Alcotest.fail "CLI output did not contain the requested marker"
  | lines -> (
      match List.find_index (String.equal marker) lines with
      | Some index when index + 1 < List.length lines ->
          List.nth lines (index + 1)
      | Some _ | None ->
          Alcotest.fail "CLI output did not contain a value after its marker")

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let model_id parser value = parser value |> Result.get_ok

let signing_capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let trust_device signing_capability =
  Trust.signing_public_key signing_capability
  |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let command_journey_reports_saved_work_and_drafts () =
  with_directory "yeokcham-v4-cli-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "first-work";
          ]
      in
      require_success "init" status errors;
      expect_output_contains "init reports a saved checkpoint" "saved " output;
      expect_output_contains "init records the local username" " alice" output;
      let initial_checkpoint = saved_checkpoint output in
      let output, errors, status =
        run
          [
            "user";
            "register";
            "--root";
            root;
            "--device";
            "device-bob";
            "--username";
            "bob";
          ]
      in
      require_success "username registration" status errors;
      expect_output_contains "registered username is inspectable"
        "user device-bob bob" output;
      let output, errors, status = run [ "save"; "--root"; root ] in
      require_success "unchanged save" status errors;
      expect_output_contains "unchanged save is explicit" "save unchanged"
        output;
      write_file root "main.ml" "let version = 2\n";
      let output, errors, status = run [ "save"; "--root"; root ] in
      require_success "changed save" status errors;
      expect_output_contains "changed save is explicit" "save recorded" output;
      let output, errors, status = run [ "status"; "--root"; root ] in
      require_success "status after save" status errors;
      expect_output_contains "saved tree has no uncaptured edits"
        "uncaptured no" output;
      let output, errors, status = run [ "timeline"; "--root"; root ] in
      require_success "timeline" status errors;
      expect_output_contains "timeline includes initial checkpoint"
        ("checkpoint " ^ initial_checkpoint)
        output;
      let destination = Filename.concat root "recovered" in
      Unix.mkdir destination 0o700;
      let output, errors, status =
        run
          [
            "restore";
            "--root";
            root;
            "--checkpoint";
            initial_checkpoint;
            "--destination";
            destination;
          ]
      in
      require_success "restore" status errors;
      expect_output_contains "restore is explicit" "restored " output;
      Alcotest.(check string)
        "CLI restore materializes prior file bytes" "let version = 1\n"
        (In_channel.with_open_bin
           (Filename.concat destination "main.ml")
           In_channel.input_all);
      let output, errors, status =
        run
          [
            "draft";
            "new";
            "--root";
            root;
            "--id";
            "draft-two";
            "--title";
            "second-work";
          ]
      in
      require_success "new draft" status errors;
      expect_output_contains "new active draft is rendered" "draft draft-two"
        output;
      let output, errors, status = run [ "status"; "--root"; root ] in
      require_success "status" status errors;
      expect_output_contains "status renders no shared work" "shared 0" output;
      expect_output_contains "status renders no decisions" "needs-decision 0"
        output;
      expect_output_contains "status renders no deliveries" "delivered 0" output;
      expect_output_contains "command capture mode is explicit"
        "capture command" output;
      expect_output_contains "restore into the tree is uncaptured work"
        "uncaptured yes" output)

let command_journey_shares_resolves_withdraws_and_delivers () =
  with_directory "yeokcham-v4-cli-share-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "first-work";
          ]
      in
      require_success "init" status errors;
      expect_output_contains "init reports a saved checkpoint" "saved " output;
      write_file root "main.ml" "let version = 2\n";
      let output, errors, status =
        run
          [
            "share";
            "--root";
            root;
            "--change";
            "change-a";
            "--revision";
            "revision-a";
          ]
      in
      require_success "share" status errors;
      expect_output_contains "share is visible" "shared 1" output;
      expect_output_contains "shared change id is listed" "change change-a"
        output;
      let _output, errors, status =
        run
          [
            "draft";
            "new";
            "--root";
            root;
            "--id";
            "draft-two";
            "--title";
            "second-work";
          ]
      in
      require_success "second draft" status errors;
      write_file root "main.ml" "let version = 3\n";
      let output, errors, status =
        run
          [
            "share";
            "--root";
            root;
            "--change";
            "change-b";
            "--revision";
            "revision-b";
          ]
      in
      require_success "overlapping share" status errors;
      expect_output_contains "overlap is a decision" "needs-decision 1" output;
      let decision = first_prefixed_value "decision " output in
      let output, errors, status =
        run
          [
            "resolve";
            "--root";
            root;
            "--decision";
            decision;
            "--change";
            "change-resolution";
            "--revision";
            "revision-resolution";
          ]
      in
      require_success "resolve" status errors;
      expect_output_contains "resolution clears the decision" "needs-decision 0"
        output;
      let _output, errors, status =
        run [ "withdraw"; "--root"; root; "--change"; "change-a" ]
      in
      require_success "withdraw" status errors;
      let output, errors, status =
        run
          [
            "deliver";
            "--root";
            root;
            "--id";
            "delivery-one";
            "--draft";
            "draft-three";
            "--title";
            "after-delivery";
          ]
      in
      require_success "deliver" status errors;
      expect_output_contains "delivery is inspectable" "delivered 1" output;
      expect_output_contains "delivery id is listed" "delivery delivery-one"
        output;
      expect_output_contains "delivery starts the next draft"
        "draft draft-three" output)

let command_journey_materializes_and_resolves_from_an_isolated_tree () =
  with_directory "yeokcham-v4-cli-isolated-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let _output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "isolated-work";
          ]
      in
      require_success "init" status errors;
      write_file root "main.ml" "let version = 2\n";
      let _output, errors, status =
        run
          [
            "share";
            "--root";
            root;
            "--change";
            "change-a";
            "--revision";
            "revision-a";
          ]
      in
      require_success "share" status errors;
      let _output, errors, status =
        run
          [
            "draft";
            "new";
            "--root";
            root;
            "--id";
            "draft-two";
            "--title";
            "second-work";
          ]
      in
      require_success "second draft" status errors;
      write_file root "main.ml" "let version = 3\n";
      let output, errors, status =
        run
          [
            "share";
            "--root";
            root;
            "--change";
            "change-b";
            "--revision";
            "revision-b";
          ]
      in
      require_success "overlapping share" status errors;
      let decision = first_prefixed_value "decision " output in
      let output, errors, status =
        run [ "decision"; "show"; "--root"; root; "--decision"; decision ]
      in
      require_success "decision show" status errors;
      expect_output_contains "show names the decision" ("decision " ^ decision)
        output;
      expect_output_contains "show lists a candidate" "candidate revision-"
        output;
      expect_output_contains "show includes candidate edit metadata"
        "edit revision-" output;
      let output, errors, status =
        run [ "decision"; "inspect"; "--root"; root; "--decision"; decision ]
      in
      require_success "decision inspect" status errors;
      expect_output_contains "inspection renders the local display label"
        "username alice" output;
      let output, errors, status =
        run
          [
            "decision";
            "diff";
            "--root";
            root;
            "--decision";
            decision;
            "--candidate";
            "revision-b";
            "--against";
            "revision-a";
          ]
      in
      require_success "decision diff" status errors;
      expect_output_contains "diff reports its compared candidate"
        "candidate revision-b" output;
      expect_output_contains "diff reports exact changed path" "diff main.ml"
        output;
      let output, errors, status =
        run [ "decision"; "propose"; "--root"; root; "--decision"; decision ]
      in
      require_success "proposal pair overview" status errors;
      expect_output_contains "proposal overview does not choose a pair"
        "proposal-pairs 1" output;
      expect_output_contains "proposal overview names both candidates"
        "proposal-pair revision-a revision-b" output;
      let output, errors, status =
        run
          [
            "decision";
            "propose";
            "--root";
            root;
            "--decision";
            decision;
            "--left";
            "revision-b";
            "--right";
            "revision-a";
          ]
      in
      require_success "granular refused proposal" status errors;
      expect_output_contains "proposal exposes exact provenance"
        "left revision revision-a" output;
      expect_output_contains "proposal does not fake confidence"
        "confidence none" output;
      expect_output_contains "proposal exposes a durable conflict"
        "path main.ml outcome conflict-content-mismatch" output;
      let refused_destination = Filename.concat root "refused-proposal" in
      Unix.mkdir refused_destination 0o700;
      let _output, errors, status =
        run
          [
            "decision";
            "materialize-proposal";
            "--root";
            root;
            "--decision";
            decision;
            "--left";
            "revision-a";
            "--right";
            "revision-b";
            "--destination";
            refused_destination;
          ]
      in
      (match status with
      | Unix.WEXITED 2 -> ()
      | Unix.WEXITED code ->
          Alcotest.failf "refused proposal exited %d: %s" code errors
      | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
          Alcotest.failf "refused proposal stopped by signal %d: %s" signal
            errors);
      expect_output_contains "proposal refusal is explicit"
        "proposal is refused" errors;
      Alcotest.(check int)
        "refused proposal leaves its destination empty" 0
        (Array.length (Sys.readdir refused_destination));
      let destination = Filename.concat root "isolated" in
      Unix.mkdir destination 0o700;
      let output, errors, status =
        run
          [
            "decision";
            "materialize";
            "--root";
            root;
            "--decision";
            decision;
            "--destination";
            destination;
          ]
      in
      require_success "materialize" status errors;
      expect_output_contains "first candidate tree" "materialized revision-a"
        output;
      expect_output_contains "second candidate tree" "materialized revision-b"
        output;
      let tree = Filename.concat destination "alice-001" in
      let output, errors, status =
        run
          [
            "resolve";
            "--root";
            root;
            "--decision";
            decision;
            "--change";
            "change-resolution";
            "--revision";
            "revision-resolution";
            "--tree";
            tree;
          ]
      in
      require_success "isolated resolve" status errors;
      expect_output_contains "decision is cleared" "needs-decision 0" output;
      Alcotest.(check string)
        "live tree is unchanged" "let version = 3\n"
        (In_channel.with_open_bin
           (Filename.concat root "main.ml")
           In_channel.input_all))

let command_journey_materializes_an_exact_proposal_without_accepting_it () =
  with_directory "yeokcham-v4-cli-proposal-" (fun root ->
      with_external_directory "yeokcham-v4-cli-proposal-output-"
        (fun output_root ->
          write_file root "main.ml" "let version = 1\n";
          write_file root "left.txt" "base-left\n";
          write_file root "right.txt" "base-right\n";
          let _output, errors, status =
            run
              [
                "init";
                "--root";
                root;
                "--username";
                "alice";
                "--draft";
                "draft-one";
                "--title";
                "proposal-work";
              ]
          in
          require_success "proposal init" status errors;
          write_file root "main.ml" "let version = 2\n";
          write_file root "left.txt" "left-change\n";
          let _output, errors, status =
            run
              [
                "share";
                "--root";
                root;
                "--change";
                "change-a";
                "--revision";
                "revision-a";
              ]
          in
          require_success "first proposal candidate" status errors;
          let _output, errors, status =
            run
              [
                "draft";
                "new";
                "--root";
                root;
                "--id";
                "draft-two";
                "--title";
                "second-work";
              ]
          in
          require_success "second proposal draft" status errors;
          write_file root "left.txt" "base-left\n";
          write_file root "right.txt" "right-change\n";
          let output, errors, status =
            run
              [
                "share";
                "--root";
                root;
                "--change";
                "change-b";
                "--revision";
                "revision-b";
              ]
          in
          require_success "second proposal candidate" status errors;
          let decision = first_prefixed_value "decision " output in
          let output, errors, status =
            run
              [
                "decision";
                "propose";
                "--root";
                root;
                "--decision";
                decision;
                "--left";
                "revision-a";
                "--right";
                "revision-b";
              ]
          in
          require_success "exact proposal inspection" status errors;
          expect_output_contains "exact proposal has mechanical confidence"
            "confidence exact-source" output;
          expect_output_contains "exact proposal names the left source"
            "path left.txt outcome select-left" output;
          expect_output_contains "exact proposal names the right source"
            "path right.txt outcome select-right" output;
          expect_output_contains
            "without an enabled server the exact proposal remains byte-only"
            "semantic status byte-only-no-matching-enabled-server" output;
          let destination = Filename.concat output_root "exact-proposal" in
          Unix.mkdir destination 0o700;
          let output, errors, status =
            run
              [
                "decision";
                "materialize-proposal";
                "--root";
                root;
                "--decision";
                decision;
                "--left";
                "revision-a";
                "--right";
                "revision-b";
                "--destination";
                destination;
              ]
          in
          require_success "exact proposal materialization" status errors;
          expect_output_contains "materialization says it is not acceptance"
            "proposal remains unaccepted" output;
          Alcotest.(check string)
            "exact proposal selected left bytes" "left-change\n"
            (In_channel.with_open_bin
               (Filename.concat destination "left.txt")
               In_channel.input_all);
          Alcotest.(check string)
            "exact proposal selected right bytes" "right-change\n"
            (In_channel.with_open_bin
               (Filename.concat destination "right.txt")
               In_channel.input_all);
          let output, errors, status = run [ "status"; "--root"; root ] in
          require_success "status after proposal materialization" status errors;
          expect_output_contains "proposal left the decision open"
            "needs-decision 1" output;
          Alcotest.(check string)
            "proposal did not rewrite the live worktree" "base-left\n"
            (In_channel.with_open_bin
               (Filename.concat root "left.txt")
               In_channel.input_all)))

let command_journey_restores_in_place_with_a_safety_checkpoint () =
  with_directory "yeokcham-v4-cli-in-place-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "restore-work";
          ]
      in
      require_success "init" status errors;
      let initial = saved_checkpoint output in
      write_file root "main.ml" "let unsaved = 2\n";
      let output, errors, status =
        run [ "restore"; "--root"; root; "--checkpoint"; initial ]
      in
      require_success "in-place restore" status errors;
      let operation = first_prefixed_value "restore-proof " output in
      let safety = first_prefixed_value "safety " output in
      expect_output_contains "safety checkpoint is reported" "safety " output;
      expect_output_contains "durable recovery proof is reported"
        "restore-proof " output;
      expect_output_contains "restore is explicitly in-place"
        ("restored " ^ initial ^ " in-place")
        output;
      let output, errors, status =
        run [ "restore"; "proofs"; "--root"; root ]
      in
      require_success "restore proofs" status errors;
      expect_output_contains "proof list includes restore operation" operation
        output;
      let output, errors, status =
        run [ "compact"; "--root"; root; "--keep"; "0"; "--explain" ]
      in
      require_success "compact after restore" status errors;
      expect_output_contains "compact prunes only the journal"
        ("journal-prune " ^ operation)
        output;
      let output, errors, status = run [ "storage"; "roots"; "--root"; root ] in
      require_success "storage roots" status errors;
      expect_output_contains "storage explains durable restore root"
        ("root " ^ safety ^ " restore-proof")
        output;
      let output, errors, status =
        run [ "storage"; "gc"; "--root"; root; "--dry-run"; "--explain" ]
      in
      require_success "GC dry-run after restore" status errors;
      expect_output_contains "GC retains the durable restore proof closure"
        "restore-proof" output;
      let output, errors, status =
        run [ "restore"; "forget"; "--root"; root; "--operation"; operation ]
      in
      require_success "restore forget" status errors;
      expect_output_contains "forget reports exact operation"
        ("restore-proof forgotten " ^ operation)
        output;
      Alcotest.(check string)
        "active tree contains target bytes" "let version = 1\n"
        (In_channel.with_open_bin
           (Filename.concat root "main.ml")
           In_channel.input_all))

let command_journey_compacts_and_reports_uncaptured_edits () =
  with_directory "yeokcham-v4-cli-compact-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "compact-work";
          ]
      in
      require_success "init" status errors;
      let initial = saved_checkpoint output in
      write_file root "main.ml" "let version = 2\n";
      let output, errors, status = run [ "status"; "--root"; root ] in
      require_success "uncaptured status" status errors;
      expect_output_contains "status warns about the unsaved file"
        "uncaptured yes" output;
      let output, errors, status = run [ "save"; "--root"; root ] in
      require_success "save" status errors;
      let extra = saved_checkpoint output in
      let _output, errors, status =
        run [ "pin"; "--root"; root; "--checkpoint"; extra ]
      in
      require_success "pin" status errors;
      write_file root "main.ml" "let version = 3\n";
      let _output, errors, status = run [ "save"; "--root"; root ] in
      require_success "second save" status errors;
      let output, errors, status =
        run [ "compact"; "--root"; root; "--keep"; "0"; "--explain" ]
      in
      require_success "compact" status errors;
      expect_output_contains "explain names the pin"
        ("keep " ^ extra ^ " ")
        output;
      ignore initial)

let command_journey_collects_only_through_an_explicit_quarantine () =
  with_directory "yeokcham-v4-cli-gc-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let _output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "gc-work";
          ]
      in
      require_success "init" status errors;
      write_file root "main.ml" "let version = 2\n";
      let _output, errors, status = run [ "save"; "--root"; root ] in
      require_success "second checkpoint" status errors;
      write_file root "main.ml" "let version = 3\n";
      let _output, errors, status = run [ "save"; "--root"; root ] in
      require_success "third checkpoint" status errors;
      let _output, errors, status =
        run [ "compact"; "--root"; root; "--keep"; "0" ]
      in
      require_success "compact" status errors;
      let output, errors, status =
        run [ "storage"; "gc"; "--root"; root; "--dry-run"; "--explain" ]
      in
      require_success "GC dry-run" status errors;
      expect_output_contains "GC plan keeps current storage" "retain " output;
      expect_output_contains "GC plan identifies unreachable storage" "collect "
        output;
      let output, errors, status =
        run [ "storage"; "gc"; "--root"; root; "--apply" ]
      in
      require_success "GC quarantine" status errors;
      let transaction = first_prefixed_value "gc-transaction " output in
      expect_output_contains "apply stages rather than purges" "staged-objects "
        output;
      let output, errors, status =
        run [ "storage"; "gc"; "status"; "--root"; root ]
      in
      require_success "GC status" status errors;
      expect_output_contains "status makes the transaction inspectable"
        ("gc-transaction " ^ transaction)
        output;
      let output, errors, status =
        run [ "storage"; "gc"; "restore"; "--root"; root; "--id"; transaction ]
      in
      require_success "GC restore" status errors;
      expect_output_contains "restore reports the transaction"
        ("gc-restored " ^ transaction)
        output;
      let output, errors, status =
        run [ "storage"; "gc"; "--root"; root; "--apply" ]
      in
      require_success "second GC quarantine" status errors;
      let transaction = first_prefixed_value "gc-transaction " output in
      let output, errors, status =
        run [ "storage"; "gc"; "purge"; "--root"; root; "--id"; transaction ]
      in
      require_success "explicit GC purge" status errors;
      expect_output_contains "purge reports recovered space"
        ("gc-purged " ^ transaction ^ " bytes:")
        output)

let command_receives_a_verified_offline_package_without_materializing_it () =
  with_directory "yeokcham-v4-cli-receive-" (fun root ->
      let source = Filename.concat root "source" in
      let destination = Filename.concat root "destination" in
      Unix.mkdir source 0o700;
      Unix.mkdir destination 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file destination "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root:source
           ~username:(model_id Model.Username.of_string "alice")
           ~initial_draft:(model_id Model.Draft_id.of_string "draft-source")
           ~title:"source" ~repository ~device:administrator
           ~signing_capability:administrator_capability ~recovery_device
           ~recovery_capability
        |> require_ok Service.error_to_string);
      write_file source "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root:source
           ~change:(model_id Model.Change_id.of_string "change-source")
           ~revision:(model_id Model.Revision_id.of_string "revision-source")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let package = Filename.concat root "incoming" in
      Service.create_package ~root:source ~destination:package
      |> require_ok Service.error_to_string;
      let member_capability = signing_capability 'b' in
      let member = trust_device member_capability in
      let root_certificate =
        Trust.root_certificate ~repository ~device:administrator
          administrator_capability
        |> require_ok Trust.error_to_string
      in
      let root_membership =
        Trust.verify_membership ~repository [ root_certificate ]
        |> require_ok Trust.error_to_string
      in
      let member_certificate =
        Trust.enroll root_membership
          ~issuer:(Trust.certificate_id root_certificate)
          administrator_capability ~subject:member ~role:Trust.Member
        |> require_ok Trust.error_to_string
      in
      let membership =
        Trust.verify_membership ~repository
          [ root_certificate; member_certificate ]
        |> require_ok Trust.error_to_string
      in
      let root_epoch =
        Trust.root_epoch ~membership
          ~root_certificate:(Trust.certificate_id root_certificate)
          ~recovery_device administrator_capability
        |> require_ok Trust.error_to_string
      in
      let root_authority =
        Trust.verify_authority ~membership [ root_epoch ]
        |> require_ok Trust.error_to_string
      in
      let member_epoch =
        Trust.successor_epoch root_authority
          ~parents:[ Trust.epoch_id root_epoch ]
          ~certificates:(Trust.certificates membership)
          ~revoked:[] ~frontier:[] ~recovery_device
          ~issuer:(Trust.certificate_id root_certificate)
          administrator_capability
        |> require_ok Trust.error_to_string
      in
      let authority =
        Trust.extend_authority root_authority [ member_epoch ]
        |> require_ok Trust.error_to_string
      in
      ignore
        (Service.init_authority_collaboration ~root:destination
           ~username:(model_id Model.Username.of_string "bob")
           ~initial_draft:
             (model_id Model.Draft_id.of_string "draft-destination")
           ~title:"destination" ~device:member ~authority
           ~local_certificate:(Trust.certificate_id member_certificate)
        |> require_ok Service.error_to_string);
      let output, errors, status =
        run [ "receive"; "--root"; destination; "--from"; package ]
      in
      require_success "verified receive" status errors;
      expect_output_contains "receive shows the imported change" "shared 1"
        output;
      Alcotest.(check string)
        "receive does not materialize incoming content into the live tree"
        "let version = 1\n"
        (In_channel.with_open_bin
           (Filename.concat destination "main.ml")
           In_channel.input_all);
      let forwarded = Filename.concat root "forwarded" in
      let output, errors, status =
        run
          [
            "package";
            "create";
            "--root";
            destination;
            "--destination";
            forwarded;
          ]
      in
      require_success "package create" status errors;
      expect_output_contains "package creation reports its destination"
        ("package " ^ forwarded) output)

let command_creates_and_enrols_a_second_device_without_using_its_username_as_identity
    () =
  with_directory "yeokcham-v4-cli-enroll-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let _output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "admin";
          ]
      in
      require_success "signed init" status errors;
      let output, errors, status = run [ "device"; "create" ] in
      require_success "device create" status errors;
      let device = first_prefixed_value "device " output in
      let public_key = first_prefixed_value "public-key " output in
      let output, errors, status =
        run
          [
            "device";
            "enroll";
            "--root";
            root;
            "--device";
            device;
            "--public-key";
            public_key;
            "--username";
            "bob";
          ]
      in
      require_success "device enroll" status errors;
      expect_output_contains "enrollment records only a local display label"
        ("user " ^ device ^ " bob")
        output;
      let output, errors, status = run [ "device"; "show"; "--root"; root ] in
      require_success "device show" status errors;
      expect_output_contains "the original local device remains administrator"
        "role administrator" output)

let command_joins_only_after_comparing_the_root_phrase () =
  with_directory "yeokcham-v4-cli-join-" (fun root ->
      let source = Filename.concat root "source" in
      let destination = Filename.concat root "destination" in
      Unix.mkdir source 0o700;
      Unix.mkdir destination 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file destination "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            source;
            "--username";
            "alice";
            "--draft";
            "draft-source";
            "--title";
            "source";
          ]
      in
      require_success "source init" status errors;
      let phrase =
        line_after "root-verification-phrase (compare during device join)"
          output
      in
      let output, errors, status = run [ "device"; "create" ] in
      require_success "member device create" status errors;
      let device = first_prefixed_value "device " output in
      let public_key = first_prefixed_value "public-key " output in
      let _output, errors, status =
        run
          [
            "device";
            "enroll";
            "--root";
            source;
            "--device";
            device;
            "--public-key";
            public_key;
            "--username";
            "bob";
          ]
      in
      require_success "member enroll" status errors;
      let package = Filename.concat root "authority-closure" in
      let _output, errors, status =
        run [ "package"; "create"; "--root"; source; "--destination"; package ]
      in
      require_success "authority package" status errors;
      let output, errors, status =
        run
          [
            "join";
            "--root";
            destination;
            "--username";
            "bob";
            "--draft";
            "draft-destination";
            "--title";
            "destination";
            "--device";
            device;
            "--from";
            package;
            "--verify-phrase";
            phrase;
          ]
      in
      require_success "phrase-verified join" status errors;
      expect_output_contains
        "join reports its deliberately separate receive step"
        "join verified authority closure" output;
      let output, errors, status =
        run [ "device"; "show"; "--root"; destination ]
      in
      require_success "member identity" status errors;
      expect_output_contains "the joined device is a member" "role member"
        output;
      Alcotest.(check string)
        "join did not materialize incoming source bytes" "let version = 1\n"
        (In_channel.with_open_bin
           (Filename.concat destination "main.ml")
           In_channel.input_all))

let command_refreshes_an_initial_recovery_package_without_changing_authority ()
    =
  with_directory "yeokcham-v4-cli-recovery-refresh-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "recovery";
          ]
      in
      require_success "recovery init" status errors;
      let mnemonic =
        line_after "recovery-mnemonic (record offline; it is shown only now)"
          output
      in
      let initial_package =
        Filename.concat (Filename.concat root ".yeokcham") "recovery-v1.cbor"
      in
      let refreshed_package = Filename.concat root "recovery-copy.cbor" in
      let output, errors, status =
        run
          [
            "recovery";
            "refresh";
            "--root";
            root;
            "--package";
            initial_package;
            "--mnemonic";
            mnemonic;
            "--output";
            refreshed_package;
          ]
      in
      require_success "recovery refresh" status errors;
      expect_output_contains "refresh names the exclusively written package"
        ("recovery-package " ^ refreshed_package)
        output;
      Alcotest.(check bool)
        "refresh writes an additional package" true
        (Sys.file_exists refreshed_package))

let remote_alias_commands_persist_only_local_configuration () =
  with_directory "yeokcham-v4-cli-remote-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let _output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "remote";
          ]
      in
      require_success "remote init" status errors;
      let output, errors, status =
        run
          [
            "remote";
            "add";
            "--root";
            root;
            "team";
            "https://relay.example.test";
          ]
      in
      require_success "remote add" status errors;
      expect_output_contains "remote add names its alias"
        "remote team https://relay.example.test" output;
      let output, errors, status =
        run [ "remote"; "remove"; "--root"; root; "team" ]
      in
      require_success "remote remove" status errors;
      expect_output_contains "remote remove names its alias"
        "remote removed team" output)

let relay_access_issue_refuses_noninteractive_secret_output () =
  with_directory "yeokcham-v4-cli-relay-access-" (fun root ->
      let repository =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      in
      let output, errors, status =
        run
          [
            "relay";
            "access";
            "issue";
            "--storage";
            root;
            "--repository";
            repository;
            "--scope";
            "read,write";
          ]
      in
      (match status with
      | Unix.WEXITED 2 -> ()
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
          Alcotest.fail
            "noninteractive relay access issue unexpectedly succeeded");
      Alcotest.(check string)
        "issuance writes no secret to standard output" "" output;
      expect_output_contains "issuance explains terminal-only secret delivery"
        "require an interactive controlling terminal" errors)

let inspection_commands_are_read_only_and_keep_domains_distinct () =
  with_directory "yeokcham-v4-cli-inspection-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let _output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "inspection";
          ]
      in
      require_success "inspection init" status errors;
      write_file root "main.ml" "let version = 2\n";
      let _output, errors, status = run [ "save"; "--root"; root ] in
      require_success "inspection save" status errors;
      let _output, errors, status =
        run
          [
            "share";
            "--root";
            root;
            "--change";
            "change-one";
            "--revision";
            "revision-one";
          ]
      in
      require_success "inspection share" status errors;
      write_file root "main.ml" "let unsaved = true\n";
      let before =
        Service.inspection_state ~root |> require_ok Service.error_to_string
      in
      let before_model = Model.export before.Service.inspection_project in
      let output, errors, status = run [ "log"; "--root"; root ] in
      require_success "log" status errors;
      expect_output_contains "log shows an explicit shared revision"
        "shared-revision revision-one" output;
      expect_output_contains "log distinguishes the author device"
        "author-device " output;
      let output, errors, status = run [ "graph"; "--root"; root ] in
      require_success "graph" status errors;
      expect_output_contains "work graph has a typed revision node"
        "[revision revision-one]" output;
      let output, errors, status =
        run [ "graph"; "--authority"; "--root"; root ]
      in
      require_success "authority graph" status errors;
      expect_output_contains "authority graph has a separate epoch node"
        "[epoch " output;
      expect_output_contains "authority graph marks its current head"
        "current-head yes" output;
      let after =
        Service.inspection_state ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "inspection leaves the state model unchanged" true
        (before_model = Model.export after.Service.inspection_project);
      Alcotest.(check string)
        "inspection does not scan or rewrite live bytes" "let unsaved = true\n"
        (In_channel.with_open_bin
           (Filename.concat root "main.ml")
           In_channel.input_all))

let watch_is_linux_only () =
  with_directory "yeokcham-v4-cli-watch-" (fun root ->
      let uname =
        try
          let input = Unix.open_process_in "uname -s" in
          Fun.protect
            ~finally:(fun () -> ignore (Unix.close_process_in input))
            (fun () -> String.trim (input_line input))
        with _ -> ""
      in
      if String.equal uname "Linux" then ()
      else
        let _output, errors, status = run [ "watch"; "--root"; root ] in
        match status with
        | Unix.WEXITED 2 ->
            expect_output_contains "non-Linux watch is refused"
              "Linux watcher capture is not supported" errors
        | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            require_success "watch" status errors)

let () =
  Alcotest.run "V4 CLI"
    [
      ( "journey",
        [
          Alcotest.test_case "saved work and drafts" `Quick
            command_journey_reports_saved_work_and_drafts;
          Alcotest.test_case "share resolve withdraw and deliver" `Quick
            command_journey_shares_resolves_withdraws_and_delivers;
          Alcotest.test_case "isolated materialize and resolve" `Quick
            command_journey_materializes_and_resolves_from_an_isolated_tree;
          Alcotest.test_case "exact proposal materializes without acceptance"
            `Quick
            command_journey_materializes_an_exact_proposal_without_accepting_it;
          Alcotest.test_case "in-place restore retains a safety checkpoint"
            `Quick command_journey_restores_in_place_with_a_safety_checkpoint;
          Alcotest.test_case "compact pin and uncaptured status" `Quick
            command_journey_compacts_and_reports_uncaptured_edits;
          Alcotest.test_case "GC requires a reviewable quarantine journey"
            `Quick command_journey_collects_only_through_an_explicit_quarantine;
          Alcotest.test_case
            "receive verifies a package without materializing it" `Quick
            command_receives_a_verified_offline_package_without_materializing_it;
          Alcotest.test_case
            "device enrollment separates public identity from username" `Quick
            command_creates_and_enrols_a_second_device_without_using_its_username_as_identity;
          Alcotest.test_case "join requires a compared root phrase" `Quick
            command_joins_only_after_comparing_the_root_phrase;
          Alcotest.test_case
            "recovery refresh writes an additional encrypted package" `Quick
            command_refreshes_an_initial_recovery_package_without_changing_authority;
          Alcotest.test_case "remote aliases persist as local configuration"
            `Quick remote_alias_commands_persist_only_local_configuration;
          Alcotest.test_case
            "relay access issuance refuses noninteractive secret output" `Quick
            relay_access_issue_refuses_noninteractive_secret_output;
          Alcotest.test_case "log and graph are read-only V4 projections" `Quick
            inspection_commands_are_read_only_and_keep_domains_distinct;
          Alcotest.test_case "watch is Linux-only" `Quick watch_is_linux_only;
        ] );
    ]
