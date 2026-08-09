module Address = Yeokcham_v2_address
module Cutover = Yeokcham_cutover
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Store = Yeokcham_store
module Transaction = Yeokcham_v2_transaction
module Transaction_store = Yeokcham_v2_transaction_store

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Ledger.Signer_key_id.t;
}

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let signer () =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr (index + 1)))
    |> require_ok (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let key_id =
    Ledger.signer_key_id_of_public_key public_key
    |> require_ok Ledger.error_to_string
  in
  { private_key; public_key; key_id }

let signer = signer ()

let repository_id =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let public_keys =
  Ledger.make_public_key_registry [ (signer.key_id, signer.public_key) ]
  |> require_ok Ledger.error_to_string

let ref_name = Ledger.Ref_name.of_string "main" |> require_ok Fun.id

let target =
  Model.Opaque_object_ref.of_bytes (String.make 32 't')
  |> require_ok Model.identity_error_to_string
  |> Ledger.Ref_target.of_opaque_object_ref

let transaction_id character =
  Model.Transaction_id.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let signed_event ?(signature_mutation = false) () =
  let unsigned =
    Ledger.make_unsigned ~repository_id ~ref_name ~signer_key_id:signer.key_id
      ~predecessor:None ~target:(Some target) ~mandatory_features:0L
    |> require_ok Ledger.error_to_string
  in
  let signature =
    Ledger.signing_bytes unsigned
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  let signature =
    if signature_mutation then (
      let bytes = Bytes.of_string signature in
      Bytes.set bytes 0 (Char.chr (Char.code (Bytes.get bytes 0) lxor 1));
      Bytes.unsafe_to_string bytes)
    else signature
  in
  Ledger.make ~unsigned ~algorithm:Ledger.algorithm ~signature
  |> require_ok Ledger.error_to_string

let envelope ?(nonce_offset = 0) ?(signature_mutation = false) () =
  let nonce =
    Envelope.nonce_of_bytes
      (String.init 12 (fun index -> Char.chr (index + nonce_offset + 32)))
    |> require_ok Envelope.error_to_string
  in
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
    (Ledger.encode (signed_event ~signature_mutation ()))
  |> require_ok Envelope.error_to_string

let object_ref envelope =
  Address.derive ~repository_id ~key:address_key ~envelope

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
  let root = Filename.temp_file "yeokcham-v2-transaction-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository =
        Transaction_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key ~public_keys
        |> require_ok Transaction_store.error_to_string
      in
      run root repository)

let reopen root =
  Transaction_store.open_repository ~root ~repository_id ~address_key
    ~encryption_key ~public_keys
  |> require_ok Transaction_store.error_to_string

let completed_transactions result =
  let { Transaction_store.completed_transactions; _ } = result in
  completed_transactions

let discarded_prepares result =
  let { Transaction_store.discarded_prepares; _ } = result in
  discarded_prepares

let ledger_repository root =
  Ledger_store.open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys
  |> require_ok Ledger_store.error_to_string

let expect_v2_root root =
  match Cutover.detect ~root |> require_ok Cutover.error_to_string with
  | Cutover.V2 -> ()
  | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
    | Cutover.Incomplete _ ) as classification ->
      Alcotest.failf "root classification is not V2: %s"
        (Cutover.classification_to_string classification)

let committed_recovery_publishes_only_after_marker_and_is_idempotent () =
  with_v2_repository (fun root repository ->
      let first = envelope ~nonce_offset:1 () in
      let second = envelope ~nonce_offset:2 () in
      let first_ref = object_ref first in
      let second_ref = object_ref second in
      let transaction_id = transaction_id 'c' in
      (match
         Transaction_store.prepare repository ~transaction_id
           ~envelopes:[ second; first ]
       with
      | Ok (Transaction_store.Prepared _) -> ()
      | Ok (Transaction_store.Already_prepared _) ->
          Alcotest.fail "initial prepare was unexpectedly idempotent"
      | Error error -> Alcotest.fail (Transaction_store.error_to_string error));
      let ledger = ledger_repository root in
      Alcotest.(check bool)
        "prepare does not publish the first object" false
        (Sys.file_exists (Ledger_store.object_path ledger first_ref));
      Alcotest.(check bool)
        "prepare does not publish the second object" false
        (Sys.file_exists (Ledger_store.object_path ledger second_ref));
      expect_v2_root root;
      (match Transaction_store.commit repository ~transaction_id with
      | Ok Transaction_store.Committed -> ()
      | Ok Transaction_store.Already_committed ->
          Alcotest.fail "initial commit was unexpectedly idempotent"
      | Error error -> Alcotest.fail (Transaction_store.error_to_string error));
      Alcotest.(check bool)
        "durable commit still has no published first object" false
        (Sys.file_exists (Ledger_store.object_path ledger first_ref));
      Alcotest.(check bool)
        "durable commit still has no published second object" false
        (Sys.file_exists (Ledger_store.object_path ledger second_ref));
      expect_v2_root root;
      let reopened = reopen root in
      let recovered =
        Transaction_store.recover reopened
        |> require_ok Transaction_store.error_to_string
      in
      Alcotest.(check int)
        "one committed transaction completes" 1
        (List.length (completed_transactions recovered));
      Alcotest.(check int)
        "no committed transaction is discarded" 0
        (List.length (discarded_prepares recovered));
      Alcotest.(check bool)
        "first object is durable" true
        (Sys.file_exists (Ledger_store.object_path ledger first_ref));
      Alcotest.(check bool)
        "second object is durable" true
        (Sys.file_exists (Ledger_store.object_path ledger second_ref));
      ignore
        (Ledger_store.load ledger ~object_ref:first_ref
        |> require_ok Ledger_store.error_to_string);
      ignore
        (Ledger_store.load ledger ~object_ref:second_ref
        |> require_ok Ledger_store.error_to_string);
      Alcotest.(check bool)
        "prepare cleanup completed" false
        (Sys.file_exists
           (Transaction_store.prepare_path reopened transaction_id));
      Alcotest.(check bool)
        "commit cleanup completed" false
        (Sys.file_exists
           (Transaction_store.commit_path reopened transaction_id));
      let repeated =
        Transaction_store.recover (reopen root)
        |> require_ok Transaction_store.error_to_string
      in
      Alcotest.(check int)
        "repeated recovery has no completion" 0
        (List.length (completed_transactions repeated));
      Alcotest.(check int)
        "repeated recovery has no discard" 0
        (List.length (discarded_prepares repeated));
      expect_v2_root root)

let uncommitted_prepare_is_discarded_without_object_visibility () =
  with_v2_repository (fun root repository ->
      let candidate = envelope ~nonce_offset:3 () in
      let candidate_ref = object_ref candidate in
      let transaction_id = transaction_id 'p' in
      ignore
        (Transaction_store.prepare repository ~transaction_id
           ~envelopes:[ candidate ]
        |> require_ok Transaction_store.error_to_string);
      let ledger = ledger_repository root in
      let recovered =
        Transaction_store.recover (reopen root)
        |> require_ok Transaction_store.error_to_string
      in
      Alcotest.(check int)
        "one prepare is discarded" 1
        (List.length (discarded_prepares recovered));
      Alcotest.(check int)
        "no transaction completes" 0
        (List.length (completed_transactions recovered));
      Alcotest.(check bool)
        "discarded prepare published no object" false
        (Sys.file_exists (Ledger_store.object_path ledger candidate_ref));
      Alcotest.(check bool)
        "prepare was removed" false
        (Sys.file_exists
           (Transaction_store.prepare_path repository transaction_id));
      expect_v2_root root)

let rec pair_with_distinct_first_shards root offset =
  let first = envelope ~nonce_offset:offset () in
  let second = envelope ~nonce_offset:(offset + 1) () in
  let ledger = ledger_repository root in
  let first_shard envelope =
    Ledger_store.object_path ledger (object_ref envelope)
    |> Filename.dirname |> Filename.dirname
  in
  if String.equal (first_shard first) (first_shard second) then
    pair_with_distinct_first_shards root (offset + 2)
  else (first, second)

let blocked_post_commit_recovery_preserves_journal_for_retry () =
  with_v2_repository (fun root repository ->
      let first, second = pair_with_distinct_first_shards root 8 in
      let first_ref = object_ref first in
      let second_ref = object_ref second in
      let transaction_id = transaction_id 'b' in
      ignore
        (Transaction_store.prepare repository ~transaction_id
           ~envelopes:[ first; second ]
        |> require_ok Transaction_store.error_to_string);
      ignore
        (Transaction_store.commit repository ~transaction_id
        |> require_ok Transaction_store.error_to_string);
      let ledger = ledger_repository root in
      let blocked_ref =
        if Model.Opaque_object_ref.compare first_ref second_ref < 0 then
          second_ref
        else first_ref
      in
      let blocker =
        Ledger_store.object_path ledger blocked_ref
        |> Filename.dirname |> Filename.dirname
      in
      let descriptor =
        Unix.openfile blocker [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "blocked recovery reports a typed error" true
        (Result.is_error (Transaction_store.recover repository));
      Alcotest.(check bool)
        "prepare remains after failed recovery" true
        (Sys.file_exists
           (Transaction_store.prepare_path repository transaction_id));
      Alcotest.(check bool)
        "commit remains after failed recovery" true
        (Sys.file_exists
           (Transaction_store.commit_path repository transaction_id));
      Unix.unlink blocker;
      let recovered =
        Transaction_store.recover (reopen root)
        |> require_ok Transaction_store.error_to_string
      in
      Alcotest.(check int)
        "retry completes the transaction" 1
        (List.length (completed_transactions recovered));
      Alcotest.(check bool)
        "first retry object is durable" true
        (Sys.file_exists (Ledger_store.object_path ledger first_ref));
      Alcotest.(check bool)
        "second retry object is durable" true
        (Sys.file_exists (Ledger_store.object_path ledger second_ref));
      expect_v2_root root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_golden name =
  let path = Filename.concat "golden" name in
  let path =
    if Sys.file_exists path then path else Filename.concat "test" path
  in
  Golden.read_lower_hex_file path |> require_ok Fun.id

let stray_commit_fixture_blocks_recovery_without_cleanup () =
  with_v2_repository (fun _ repository ->
      let transaction_id = transaction_id 't' in
      write_file
        (Transaction_store.commit_path repository transaction_id)
        (read_golden "v2-transaction-commit-v1.cbor.hex");
      match Transaction_store.recover repository with
      | Error (Transaction_store.Stray_commit actual) ->
          Alcotest.(check bool)
            "fixture transaction ID is preserved" true
            (Model.Transaction_id.equal transaction_id actual);
          Alcotest.(check bool)
            "stray commit remains inspectable" true
            (Sys.file_exists
               (Transaction_store.commit_path repository transaction_id))
      | Error error ->
          Alcotest.failf "stray commit returned the wrong error: %s"
            (Transaction_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stray commit unexpectedly recovered")
  [@warning "-4"]

let invalid_candidate_blocks_recovery_without_cleanup () =
  with_v2_repository (fun root repository ->
      let transaction_id = transaction_id 'i' in
      let invalid = envelope ~nonce_offset:16 ~signature_mutation:true () in
      let invalid_ref = object_ref invalid in
      let prepare =
        Transaction.make_prepare ~repository_id ~transaction_id
          ~mandatory_features:0L
          [ Transaction.stage ~object_ref:invalid_ref ~envelope:invalid ]
        |> require_ok Transaction.error_to_string
      in
      let commit = Transaction.make_commit prepare in
      write_file
        (Transaction_store.prepare_path repository transaction_id)
        (Transaction.encode_prepare prepare);
      write_file
        (Transaction_store.commit_path repository transaction_id)
        (Transaction.encode_commit commit);
      expect_v2_root root;
      Alcotest.(check bool)
        "invalid candidate reports a typed recovery error" true
        (Result.is_error (Transaction_store.recover repository));
      Alcotest.(check bool)
        "invalid prepare stays inspectable" true
        (Sys.file_exists
           (Transaction_store.prepare_path repository transaction_id));
      Alcotest.(check bool)
        "invalid commit stays inspectable" true
        (Sys.file_exists
           (Transaction_store.commit_path repository transaction_id));
      let ledger = ledger_repository root in
      Alcotest.(check bool)
        "invalid candidate never reaches objects" false
        (Sys.file_exists (Ledger_store.object_path ledger invalid_ref)))

let () =
  Alcotest.run "V2 durable object transaction storage"
    [
      ( "unit",
        [
          Alcotest.test_case
            "committed recovery publishes only after marker and is idempotent"
            `Quick
            committed_recovery_publishes_only_after_marker_and_is_idempotent;
          Alcotest.test_case
            "uncommitted prepare is discarded without object visibility" `Quick
            uncommitted_prepare_is_discarded_without_object_visibility;
          Alcotest.test_case
            "blocked post-commit recovery preserves journal for retry" `Quick
            blocked_post_commit_recovery_preserves_journal_for_retry;
          Alcotest.test_case
            "stray commit fixture blocks recovery without cleanup" `Quick
            stray_commit_fixture_blocks_recovery_without_cleanup;
          Alcotest.test_case "invalid candidate blocks recovery without cleanup"
            `Quick invalid_candidate_blocks_recovery_without_cleanup;
        ] );
    ]
