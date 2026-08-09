module Address = Yeokcham_v2_address
module Cutover = Yeokcham_cutover
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Store = Yeokcham_store
module Golden = Yeokcham_testkit.Golden_fixture

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

let other_repository_id =
  Model.Repository_id.of_bytes (String.make 32 's')
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

let signed_event ?(repository = repository_id) ?(signature_mutation = false) ()
    =
  let unsigned =
    Ledger.make_unsigned ~repository_id:repository ~ref_name
      ~signer_key_id:signer.key_id ~predecessor:None ~target:(Some target)
      ~mandatory_features:0L
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

let envelope ?(nonce_offset = 0) event =
  let nonce =
    Envelope.nonce_of_bytes
      (String.init 12 (fun index -> Char.chr (index + nonce_offset + 32)))
    |> require_ok Envelope.error_to_string
  in
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
    (Ledger.encode event)
  |> require_ok Envelope.error_to_string

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let canonical_record_envelope_and_address_goldens () =
  let event = signed_event () in
  let envelope = envelope event in
  let object_ref =
    Address.derive ~repository_id ~key:address_key ~envelope
    |> Model.Opaque_object_ref.to_bytes
  in
  Alcotest.(check string)
    "canonical ref-ledger plaintext"
    (read_golden "v2-ref-ledger-event-v1.cbor.hex")
    (Ledger.encode event);
  Alcotest.(check string)
    "canonical encrypted ref-ledger envelope"
    (read_golden "v2-ref-ledger-envelope-v1.cbor.hex")
    (Envelope.encode envelope);
  Alcotest.(check string)
    "canonical opaque ledger object address"
    (read_golden "v2-ref-ledger-opaque-address-v1.hex")
    object_ref

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
  let root = Filename.temp_file "yeokcham-v2-ledger-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository =
        Ledger_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key ~public_keys
        |> require_ok Ledger_store.error_to_string
      in
      run root repository)

let create_only_publication_reopens_and_preserves_v2_root () =
  with_v2_repository (fun root repository ->
      let event = signed_event () in
      let envelope = envelope event in
      let object_ref =
        match Ledger_store.publish repository ~envelope with
        | Ok (Ledger_store.Published { object_ref; event_id }) ->
            Alcotest.(check bool)
              "published event identity" true
              (Ledger.Event_id.equal event_id (Ledger.event_id event));
            object_ref
        | Ok (Ledger_store.Already_published _) ->
            Alcotest.fail "first publication reported an existing object"
        | Error error -> Alcotest.fail (Ledger_store.error_to_string error)
      in
      (match Ledger_store.publish repository ~envelope with
      | Ok (Ledger_store.Already_published { object_ref = repeated; _ }) ->
          Alcotest.(check bool)
            "idempotent retry retains opaque address" true
            (Model.Opaque_object_ref.equal object_ref repeated)
      | Ok (Ledger_store.Published _) ->
          Alcotest.fail "retry published a second object"
      | Error error -> Alcotest.fail (Ledger_store.error_to_string error));
      let loaded =
        Ledger_store.load repository ~object_ref
        |> require_ok Ledger_store.error_to_string
        |> Ledger.verified_event
      in
      Alcotest.(check bool)
        "loaded record retains event ID" true
        (Ledger.Event_id.equal (Ledger.event_id event) (Ledger.event_id loaded));
      match Cutover.detect ~root |> require_ok Cutover.error_to_string with
      | Cutover.V2 -> ()
      | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
        | Cutover.Incomplete _ ) as classification ->
          Alcotest.failf "published V2 envelope changed root classification: %s"
            (Cutover.classification_to_string classification))

let stale_ledger_temporary_is_non_authoritative () =
  with_v2_repository (fun root repository ->
      let event = signed_event () in
      let envelope = envelope event in
      let object_ref =
        match Ledger_store.publish repository ~envelope with
        | Ok (Ledger_store.Published { object_ref; _ }) -> object_ref
        | Ok (Ledger_store.Already_published _) ->
            Alcotest.fail "first publication reported an existing object"
        | Error error -> Alcotest.fail (Ledger_store.error_to_string error)
      in
      let final = Ledger_store.object_path repository object_ref in
      let temporary =
        Filename.concat (Filename.dirname final)
          (Printf.sprintf ".%s.ledger-123-0" (Filename.basename final))
      in
      let descriptor =
        Unix.openfile temporary
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
          0o600
      in
      Unix.close descriptor;
      (match Cutover.detect ~root |> require_ok Cutover.error_to_string with
      | Cutover.V2 -> ()
      | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
        | Cutover.Incomplete _ ) as classification ->
          Alcotest.failf
            "regular ledger temporary changed root classification: %s"
            (Cutover.classification_to_string classification));
      let objects =
        Ledger_store.list_object_refs repository
        |> require_ok Ledger_store.error_to_string
      in
      Alcotest.(check (list string))
        "temporary is not an object"
        [ Model.Opaque_object_ref.to_hex object_ref ]
        (List.map Model.Opaque_object_ref.to_hex objects);
      Unix.unlink temporary;
      Unix.mkdir temporary 0o700;
      match Cutover.detect ~root |> require_ok Cutover.error_to_string with
      | Cutover.V2 -> Alcotest.fail "non-regular ledger temporary was accepted"
      | Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
      | Cutover.Incomplete _ ->
          ())

let rejected_or_blocked_publication_writes_no_object () =
  with_v2_repository (fun _ repository ->
      let invalid_envelope =
        envelope (signed_event ~signature_mutation:true ())
      in
      let invalid_ref =
        Address.derive ~repository_id ~key:address_key
          ~envelope:invalid_envelope
      in
      Alcotest.(check bool)
        "bad signature rejects before publication" true
        (Result.is_error
           (Ledger_store.publish repository ~envelope:invalid_envelope));
      Alcotest.(check bool)
        "rejected event has no object path" false
        (Sys.file_exists (Ledger_store.object_path repository invalid_ref));
      let foreign_envelope =
        envelope ~nonce_offset:2
          (signed_event ~repository:other_repository_id ())
      in
      let foreign_ref =
        Address.derive ~repository_id ~key:address_key
          ~envelope:foreign_envelope
      in
      Alcotest.(check bool)
        "foreign repository event rejects before publication" true
        (Result.is_error
           (Ledger_store.publish repository ~envelope:foreign_envelope));
      Alcotest.(check bool)
        "foreign repository event has no object path" false
        (Sys.file_exists (Ledger_store.object_path repository foreign_ref));
      let valid_envelope = envelope ~nonce_offset:1 (signed_event ()) in
      let object_ref =
        Address.derive ~repository_id ~key:address_key ~envelope:valid_envelope
      in
      let final = Ledger_store.object_path repository object_ref in
      let first_shard = Filename.dirname (Filename.dirname final) in
      let descriptor =
        Unix.openfile first_shard
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
          0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "blocked object shard rejects" true
        (Result.is_error
           (Ledger_store.publish repository ~envelope:valid_envelope));
      Alcotest.(check bool)
        "blocked publication has no final object" false (Sys.file_exists final))

let () =
  Alcotest.run "V2 encrypted ref-ledger object storage"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical record, envelope, and address goldens"
            `Quick canonical_record_envelope_and_address_goldens;
          Alcotest.test_case "create-only publish/reopen retains V2 root" `Quick
            create_only_publication_reopens_and_preserves_v2_root;
          Alcotest.test_case "stale ledger temporary is non-authoritative"
            `Quick stale_ledger_temporary_is_non_authoritative;
          Alcotest.test_case "rejected and blocked publish leave no object"
            `Quick rejected_or_blocked_publication_writes_no_object;
        ] );
    ]
