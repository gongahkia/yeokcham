module Cutover = Yeokcham_cutover
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let identity of_bytes character =
  of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let repository_id = identity Model.Repository_id.of_bytes 'r'
let other_repository_id = identity Model.Repository_id.of_bytes 'x'
let operation_id = identity Model.Transaction_id.of_bytes 'o'

let prepared ?(repository = repository_id) ?(operation = operation_id)
    action_count =
  Journal.make_prepared ~repository_id:repository ~operation_id:operation
    ~safety_event_id:(identity Ledger.Event_id.of_bytes 'e')
    ~target_event_id:(identity Ledger.Event_id.of_bytes 't')
    ~safety_snapshot:(identity Model.Opaque_object_ref.of_bytes 's')
    ~target_snapshot:(identity Model.Opaque_object_ref.of_bytes 't')
    ~action_count ~mandatory_features:0L
  |> require_ok Journal.error_to_string

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

let with_v2_repository run =
  let root = Filename.temp_file "yeokcham-v2-restore-journal-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository =
        Journal_store.open_repository ~root ~repository_id
        |> require_ok Journal_store.error_to_string
      in
      run root repository)

let check_v2_root root =
  match Cutover.detect ~root |> require_ok Cutover.error_to_string with
  | Cutover.V2 -> ()
  | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
    | Cutover.Incomplete _ ) as classification ->
      Alcotest.failf "restore journal changed V2 root classification: %s"
        (Cutover.classification_to_string classification)

let append_chain_is_create_only_and_reopens () =
  with_v2_repository (fun root repository ->
      let initial = prepared 2 in
      (match Journal_store.append repository initial with
      | Ok Journal_store.Appended -> ()
      | Ok Journal_store.Already_appended ->
          Alcotest.fail "first restore journal append was already present"
      | Error error -> Alcotest.fail (Journal_store.error_to_string error));
      (match Journal_store.append repository initial with
      | Ok Journal_store.Already_appended -> ()
      | Ok Journal_store.Appended ->
          Alcotest.fail "identical restore journal retry created a new record"
      | Error error -> Alcotest.fail (Journal_store.error_to_string error));
      let started =
        Journal.advance initial (Journal.Applying 0)
        |> require_ok Journal.error_to_string
      in
      ignore
        (Journal_store.append repository started
        |> require_ok Journal_store.error_to_string);
      let first_action =
        Journal.advance started (Journal.Applying 1)
        |> require_ok Journal.error_to_string
      in
      ignore
        (Journal_store.append repository first_action
        |> require_ok Journal_store.error_to_string);
      let second_action =
        Journal.advance first_action (Journal.Applying 2)
        |> require_ok Journal.error_to_string
      in
      ignore
        (Journal_store.append repository second_action
        |> require_ok Journal_store.error_to_string);
      let materialized =
        Journal.advance second_action Journal.Materialized
        |> require_ok Journal.error_to_string
      in
      ignore
        (Journal_store.append repository materialized
        |> require_ok Journal_store.error_to_string);
      let published =
        Journal.advance materialized Journal.Published
        |> require_ok Journal.error_to_string
      in
      ignore
        (Journal_store.append repository published
        |> require_ok Journal_store.error_to_string);
      check_v2_root root;
      let reopened =
        Journal_store.open_repository ~root ~repository_id
        |> require_ok Journal_store.error_to_string
      in
      let records =
        Journal_store.scan reopened |> require_ok Journal_store.error_to_string
      in
      Alcotest.(check int)
        "all immutable generations reopen" 6 (List.length records);
      let latest =
        Journal_store.latest reopened ~operation_id
        |> require_ok Journal_store.error_to_string
      in
      match latest with
      | Some record ->
          Alcotest.(check int64)
            "published generation reopens" 5L
            (Journal.generation record)
      | None -> Alcotest.fail "reopened journal has no latest generation")

let invalid_predecessors_collisions_and_foreign_records_fail_closed () =
  with_v2_repository (fun _ repository ->
      let initial = prepared 1 in
      let started =
        Journal.advance initial (Journal.Applying 0)
        |> require_ok Journal.error_to_string
      in
      Alcotest.(check bool)
        "cannot append a successor without prepared generation" true
        (Result.is_error (Journal_store.append repository started));
      Alcotest.(check bool)
        "missing predecessor creates no file" false
        (Sys.file_exists (Journal_store.record_path repository started));
      let foreign = prepared ~repository:other_repository_id 1 in
      Alcotest.(check bool)
        "foreign repository record rejects" true
        (Result.is_error (Journal_store.append repository foreign));
      let conflicting =
        Journal.make_prepared ~repository_id ~operation_id
          ~safety_event_id:(identity Ledger.Event_id.of_bytes 'e')
          ~target_event_id:(identity Ledger.Event_id.of_bytes 't')
          ~safety_snapshot:(identity Model.Opaque_object_ref.of_bytes 'u')
          ~target_snapshot:(identity Model.Opaque_object_ref.of_bytes 't')
          ~action_count:1 ~mandatory_features:0L
        |> require_ok Journal.error_to_string
      in
      let final = Journal_store.record_path repository initial in
      Out_channel.with_open_bin final (fun channel ->
          Out_channel.output_string channel (Journal.encode conflicting));
      match Journal_store.append repository initial with
      | Error (Journal_store.Journal_collision path) ->
          Alcotest.(check string) "collision path" final path
      | Error error ->
          Alcotest.failf "collision returned wrong error: %s"
            (Journal_store.error_to_string error)
      | Ok _ -> Alcotest.fail "different existing bytes were accepted")
  [@warning "-4"]

let stale_temporary_is_non_authoritative () =
  with_v2_repository (fun root repository ->
      let initial = prepared 1 in
      let final = Journal_store.record_path repository initial in
      let temporary =
        Filename.concat (Filename.dirname final)
          (Printf.sprintf ".%s.tmp-123-0" (Filename.basename final))
      in
      Out_channel.with_open_bin temporary (fun channel ->
          Out_channel.output_string channel "discarded temporary bytes");
      check_v2_root root;
      let records =
        Journal_store.scan repository
        |> require_ok Journal_store.error_to_string
      in
      Alcotest.(check int)
        "temporary is not a journal record" 0 (List.length records);
      Unix.unlink temporary;
      Unix.mkdir temporary 0o700;
      match Cutover.detect ~root |> require_ok Cutover.error_to_string with
      | Cutover.V2 -> Alcotest.fail "non-regular restore temporary was accepted"
      | Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
      | Cutover.Incomplete _ ->
          ())

let () =
  Alcotest.run "V2 durable restore journal storage"
    [
      ( "unit",
        [
          Alcotest.test_case "create-only chain reopens and preserves V2 root"
            `Quick append_chain_is_create_only_and_reopens;
          Alcotest.test_case
            "missing predecessors, collisions, and foreign records fail closed"
            `Quick
            invalid_predecessors_collisions_and_foreign_records_fail_closed;
          Alcotest.test_case "stale temporary is non-authoritative" `Quick
            stale_temporary_is_non_authoritative;
        ] );
    ]
