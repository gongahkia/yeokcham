module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Event = Yeokcham_ref_event
module Event_store = Yeokcham_ref_event_store
module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
module Golden = Yeokcham_testkit.Golden_fixture
module Store = Yeokcham_store

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Event.signer_key_id;
}

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_event result = require Event.error_to_string result
let require_store result = require Store.error_to_string result
let require_envelope result = require Envelope.creation_error_to_string result
let require_event_store result = require Event_store.error_to_string result

let require_exchange_store result =
  require Exchange_store.error_to_string result

let signer seed =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr ((seed + index) land 255)))
    |> require (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let key_id = Event.signer_key_id_of_public_key public_key |> require_event in
  { private_key; public_key; key_id }

let signer_a = signer 1
let signer_b = signer 33

let object_id byte =
  match Store.Stored_object_id.of_raw_bytes (String.make 32 byte) with
  | Some value -> value
  | None -> Alcotest.fail "test object ID is invalid"

let state generation target =
  Event.make_ref_state ~generation ~target |> require_event

let signed_event signer ~previous ~sequence ~observed ~proposed =
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format
      ~ref_name:"scratch-head" ~signer_key_id:signer.key_id
      ~signer_sequence:sequence ~previous ~observed ~proposed
      ~mandatory_features:0L
    |> require_event
  in
  let signature =
    Event.signing_bytes unsigned
    |> require_event
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require_event

let envelope event =
  let payload = Event.event_payload event |> require_event in
  Envelope.create ~object_type:Envelope.Ref_event
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> require_envelope

let sample =
  signed_event signer_a ~previous:None ~sequence:0L ~observed:(state 0L None)
    ~proposed:(state 1L (Some (object_id '\001')))

let require_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name) |> require Fun.id

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require Fun.id

let check_verification name expected result =
  match result with
  | Ok actual ->
      Alcotest.(check string)
        name expected
        (Event.verification_to_string actual)
  | Error error -> Alcotest.fail (Event.error_to_string error)

let check_evaluation name expected result =
  match result with
  | Ok actual ->
      Alcotest.(check string) name expected (Event.evaluation_to_string actual)
  | Error error -> Alcotest.fail (Event.error_to_string error)

let trusted signer =
  [ { Event.key_id = signer.key_id; public_key = signer.public_key } ]

let canonical_event_golden () =
  let actual = Envelope.encode (envelope sample) in
  let expected = refreshed_golden "ref-event-v1.yeok.hex" actual in
  Alcotest.(check string) "event envelope golden" expected actual;
  let decoded_envelope =
    Envelope.decode expected |> require Envelope.decode_error_to_string
  in
  Alcotest.(check bool)
    "event type" true
    (Envelope.object_type decoded_envelope = Envelope.Ref_event);
  let decoded =
    Event.decode_event_payload (Envelope.payload decoded_envelope)
    |> require_event
  in
  let reencoded = Event.event_payload decoded |> require_event in
  Alcotest.(check bool)
    "event payload is canonical" true
    (Encoding.equal reencoded (Envelope.payload decoded_envelope));
  Alcotest.(check string)
    "event ID"
    (Event.Event_id.to_hex
       (Event.unsigned_event_id (Event.event_unsigned sample)))
    (Event.Event_id.to_hex
       (Event.unsigned_event_id (Event.event_unsigned decoded)))

let verification_rejects_bad_inputs () =
  check_verification "trusted event" "verified"
    (Event.verify ~repository_format:Store.repository_format
       ~trusted_keys:(trusted signer_a) sample);
  check_verification "absent key is untrusted" "untrusted"
    (Event.verify ~repository_format:Store.repository_format ~trusted_keys:[]
       sample);
  Alcotest.(check bool)
    "wrong repository rejects" true
    (Result.is_error
       (Event.verify ~repository_format:"other" ~trusted_keys:(trusted signer_a)
          sample));
  let signature = Bytes.of_string (Event.event_signature sample) in
  Bytes.set signature 0 (Char.chr (Char.code (Bytes.get signature 0) lxor 1));
  let invalid =
    Event.make
      ~unsigned:(Event.event_unsigned sample)
      ~algorithm:Event.algorithm
      ~signature:(Bytes.unsafe_to_string signature)
    |> require_event
  in
  Alcotest.(check bool)
    "bad signature rejects" true
    (Result.is_error
       (Event.verify ~repository_format:Store.repository_format
          ~trusted_keys:(trusted signer_a) invalid));
  Alcotest.(check bool)
    "oversized trust map rejects" true
    (Result.is_error
       (Event.verify ~repository_format:Store.repository_format
          ~trusted_keys:
            (List.init 257 (fun _ ->
                 {
                   Event.key_id = signer_a.key_id;
                   public_key = signer_a.public_key;
                 }))
          sample));
  Alcotest.(check bool)
    "test signer algorithm rejects" true
    (Result.is_error
       (Event.make
          ~unsigned:(Event.event_unsigned sample)
          ~algorithm:"yeokcham-test-only-not-cryptographic-v1"
          ~signature:(Event.event_signature sample)));
  Alcotest.(check bool)
    "malformed payload rejects" true
    (Result.is_error (Event.decode_event_payload Encoding.null))

let replay_order_and_divergence_are_explicit () =
  let current = state 0L None in
  check_evaluation "first event" "ready"
    (Event.evaluate_verified ~current ~known:[] sample);
  check_evaluation "replayed event"
    ("replayed:"
    ^ Event.Event_id.to_hex
        (Event.unsigned_event_id (Event.event_unsigned sample)))
    (Event.evaluate_verified ~current ~known:[ sample ] sample);
  let missing_predecessor =
    signed_event signer_a ~previous:None ~sequence:1L ~observed:current
      ~proposed:(state 1L (Some (object_id '\002')))
  in
  check_evaluation "missing predecessor"
    ("missing-predecessor:"
    ^ Event.Event_id.to_hex
        (Event.unsigned_event_id (Event.event_unsigned missing_predecessor)))
    (Event.evaluate_verified ~current ~known:[ sample ] missing_predecessor);
  let ahead =
    signed_event signer_a
      ~previous:(Some (Event.unsigned_event_id (Event.event_unsigned sample)))
      ~sequence:1L ~observed:current
      ~proposed:(state 1L (Some (object_id '\002')))
  in
  check_evaluation "out-of-order signer sequence" "signer-sequence-reused:0"
    (Event.evaluate_verified ~current ~known:[ ahead ] sample);
  let concurrent =
    signed_event signer_b ~previous:None ~sequence:0L ~observed:current
      ~proposed:(state 1L (Some (object_id '\003')))
  in
  check_evaluation "concurrent proposal"
    ("divergent:"
    ^ Event.Event_id.to_hex
        (Event.unsigned_event_id (Event.event_unsigned sample)))
    (Event.evaluate_verified ~current ~known:[ sample ] concurrent);
  check_evaluation "stale observed state" "stale-observed-ref"
    (Event.evaluate_verified
       ~current:(state 1L (Some (object_id '\004')))
       ~known:[] sample)

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

let with_repositories run =
  let root = Filename.temp_file "yeokcham-ref-event-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require_store in
      let destination = Store.init ~root:destination_root |> require_store in
      run source destination)

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let local_transfer_preserves_ref () =
  with_repositories (fun source destination ->
      let event_object =
        Event_store.store_event source sample |> require_event_store
      in
      let local_object =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some local_object)
        |> require_store
      in
      let session =
        Exchange.session_id_of_bytes "ref-event-test01"
        |> require Exchange.error_to_string
      in
      ignore
        (Exchange_store.transfer ~source ~destination ~session_id:session
           ~object_ids:[ event_object ] ()
        |> require_exchange_store);
      let loaded =
        Event_store.load_event destination event_object |> require_event_store
      in
      check_verification "transferred event verifies" "verified"
        (Event.verify ~repository_format:Store.repository_format
           ~trusted_keys:(trusted signer_a) loaded);
      let actual =
        Store.read_ref destination ~name:"scratch-head" |> require_store
      in
      Alcotest.(check bool)
        "transfer left ref unchanged" true
        (Option.exists (Store.Mutable_ref.equal reference) actual))

let () =
  Alcotest.run "verifiable ref events"
    [
      ( "core",
        [
          Alcotest.test_case "canonical event golden" `Quick
            canonical_event_golden;
          Alcotest.test_case "verification rejects bad inputs" `Quick
            verification_rejects_bad_inputs;
          Alcotest.test_case "replay order and divergence stay explicit" `Quick
            replay_order_and_divergence_are_explicit;
        ] );
      ( "local store",
        [
          Alcotest.test_case "local transfer preserves ref" `Quick
            local_transfer_preserves_ref;
        ] );
    ]
