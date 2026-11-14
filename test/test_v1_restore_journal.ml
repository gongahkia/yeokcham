module Golden = Yeokcham_testkit.Golden_fixture
module Journal = Yeokcham_v1_restore_journal
module Model = Yeokcham_v1_model

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let snapshot value = Model.Snapshot_id.of_string value |> Result.get_ok

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

let with_journal_root run =
  let root = Filename.temp_file "v1-restore-journal-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".yeokcham") 0o700;
  Unix.mkdir
    (Filename.concat (Filename.concat root ".yeokcham") "journal")
    0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let prepared () =
  Journal.make_prepared ~operation_id:(String.make 64 'a')
    ~safety:(snapshot "snapshot-safety")
    ~target:(snapshot "snapshot-target")
  |> require_ok Journal.error_to_string

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let prepared_record_has_stable_bytes () =
  let expected =
    Golden.read_lower_hex_file (golden_path "v1/restore-prepared-v1.cbor.hex")
    |> require_ok Fun.id
  in
  let actual =
    Journal.encode (prepared ()) |> require_ok Journal.error_to_string
  in
  Alcotest.(check string) "prepared bytes" expected actual;
  let decoded = Journal.decode expected |> require_ok Journal.error_to_string in
  Alcotest.(check string)
    "fixture re-encodes identically" expected
    (Journal.encode decoded |> require_ok Journal.error_to_string)

let phases_advance_only_in_order () =
  let applying =
    Journal.advance (prepared ()) Journal.Applying
    |> require_ok Journal.error_to_string
  in
  let materialized =
    Journal.advance applying Journal.Materialized
    |> require_ok Journal.error_to_string
  in
  let published =
    Journal.advance materialized Journal.Published
    |> require_ok Journal.error_to_string
  in
  Alcotest.(check int64)
    "published generation" 3L
    (Journal.generation published);
  match Journal.advance (prepared ()) Journal.Materialized with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "journal skipped the applying phase"

let scan_rejects_a_missing_generation () =
  with_journal_root (fun root ->
      let prepared = prepared () in
      Journal.append ~root prepared |> require_ok Journal.error_to_string;
      let applying =
        Journal.advance prepared Journal.Applying
        |> require_ok Journal.error_to_string
      in
      let materialized =
        Journal.advance applying Journal.Materialized
        |> require_ok Journal.error_to_string
      in
      Journal.append ~root materialized |> require_ok Journal.error_to_string;
      match Journal.scan ~root with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "accepted a non-contiguous journal chain")

let published_journals_are_pruned () =
  with_journal_root (fun root ->
      let rec append_through journal = function
        | [] -> journal
        | phase :: rest ->
            let next =
              Journal.advance journal phase
              |> require_ok Journal.error_to_string
            in
            Journal.append ~root next |> require_ok Journal.error_to_string;
            append_through next rest
      in
      let prepared = prepared () in
      Journal.append ~root prepared |> require_ok Journal.error_to_string;
      ignore
        (append_through prepared
           [ Journal.Applying; Journal.Materialized; Journal.Published ]);
      let pruned =
        Journal.prune_published ~root ~operations:[ String.make 64 'a' ]
        |> require_ok Journal.error_to_string
      in
      Alcotest.(check (list string))
        "published operation is reported"
        [ String.make 64 'a' ]
        pruned;
      Alcotest.(check int)
        "journal directory is empty after prune" 0
        (Journal.scan ~root |> require_ok Journal.error_to_string |> List.length))

let[@warning "-4"] physical_plan_roundtrip_and_scope () =
  with_journal_root (fun root ->
      let branch =
        Model.Core.Branch_id.of_raw (String.make 16 'b')
        |> require_ok Model.Core.error_to_string
      in
      let base =
        Journal.with_history_node (prepared ()) 7L
        |> require_ok Journal.error_to_string
      in
      let planned =
        Journal.with_plan base ~digest:(String.make 32 'p')
          ~selected_branch:(Some branch)
        |> require_ok Journal.error_to_string
      in
      let bytes =
        Journal.encode planned |> require_ok Journal.error_to_string
      in
      let decoded =
        Journal.decode bytes |> require_ok Journal.error_to_string
      in
      Alcotest.(check string)
        "V3 canonical round trip" bytes
        (Journal.encode decoded |> require_ok Journal.error_to_string);
      Alcotest.(check (option int64))
        "exact target position" (Some 7L)
        (Journal.history_node decoded);
      (match Journal.plan decoded with
      | Some (digest, Some selected) ->
          Alcotest.(check string) "plan digest" (String.make 32 'p') digest;
          Alcotest.(check bool)
            "typed branch" true
            (Model.Core.Branch_id.equal branch selected)
      | _ -> Alcotest.fail "plan scope missing");
      Journal.append ~root planned |> require_ok Journal.error_to_string;
      let changed =
        Journal.with_history_node planned 8L
        |> require_ok Journal.error_to_string
      in
      let applying =
        Journal.advance changed Journal.Applying
        |> require_ok Journal.error_to_string
      in
      Journal.append ~root applying |> require_ok Journal.error_to_string;
      match Journal.scan ~root with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "journal chain retargeted history node")

let plan_digest_cannot_change_between_generations () =
  with_journal_root (fun root ->
      let prepared =
        Journal.with_history_node (prepared ()) 0L
        |> require_ok Journal.error_to_string
      in
      let first =
        Journal.with_plan prepared ~digest:(String.make 32 'a')
          ~selected_branch:None
        |> require_ok Journal.error_to_string
      in
      Journal.append ~root first |> require_ok Journal.error_to_string;
      let second =
        Journal.with_plan prepared ~digest:(String.make 32 'b')
          ~selected_branch:None
        |> require_ok Journal.error_to_string
      in
      let applying =
        Journal.advance second Journal.Applying
        |> require_ok Journal.error_to_string
      in
      Journal.append ~root applying |> require_ok Journal.error_to_string;
      match Journal.scan ~root with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "journal chain changed physical plan")

let () =
  Alcotest.run "V1 restore journal"
    [
      ( "record",
        [
          Alcotest.test_case "physical plan and typed branch scope" `Quick
            physical_plan_roundtrip_and_scope;
          Alcotest.test_case "plan digest is immutable across generations"
            `Quick plan_digest_cannot_change_between_generations;
          Alcotest.test_case "prepared golden bytes" `Quick
            prepared_record_has_stable_bytes;
          Alcotest.test_case "phases advance in order" `Quick
            phases_advance_only_in_order;
          Alcotest.test_case "missing generation is rejected" `Quick
            scan_rejects_a_missing_generation;
          Alcotest.test_case "published journals can be pruned" `Quick
            published_journals_are_pruned;
        ] );
    ]
