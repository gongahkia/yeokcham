module Divergence = Yeokcham_divergence
module Divergence_store = Yeokcham_divergence_store
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

type stored_entry = { entry : Divergence.entry; event : Event.t }

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_divergence result = require Divergence.error_to_string result

let require_divergence_store result =
  require Divergence_store.error_to_string result

let require_envelope result = require Envelope.creation_error_to_string result
let require_event result = require Event.error_to_string result
let require_event_store result = require Event_store.error_to_string result

let require_exchange_store result =
  require Exchange_store.error_to_string result

let require_store result = require Store.error_to_string result

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
let signer_c = signer 65

let object_id byte =
  match Store.Stored_object_id.of_raw_bytes (String.make 32 byte) with
  | Some value -> value
  | None -> Alcotest.fail "test object ID is invalid"

let state generation target =
  Event.make_ref_state ~generation ~target |> require_event

let signed_event signer ~sequence ~observed ~target =
  let proposed =
    state (Int64.succ (Event.ref_state_generation observed)) (Some target)
  in
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format
      ~ref_name:"scratch-head" ~signer_key_id:signer.key_id
      ~signer_sequence:sequence ~previous:None ~observed ~proposed
      ~mandatory_features:0L
    |> require_event
  in
  let signature =
    Event.signing_bytes unsigned
    |> require_event
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require_event

let trusted signers =
  List.map
    (fun signer ->
      { Event.key_id = signer.key_id; public_key = signer.public_key })
    signers

let verify signer event =
  match
    Event.verify_for_device ~repository_format:Store.repository_format
      ~trusted_keys:(trusted [ signer ]) event
    |> require_event
  with
  | Some verified -> verified
  | None -> Alcotest.fail "test event is unexpectedly untrusted"

let core_entry signer byte =
  let event =
    signed_event signer ~sequence:0L ~observed:(state 0L None)
      ~target:(object_id byte)
  in
  Divergence.entry_of_verified
    ~object_id:(object_id Char.(chr (code byte + 32)))
    (verify signer event)

let core_a = core_entry signer_a '\001'
let core_b = core_entry signer_b '\002'

let sample_set =
  Divergence.make ~repository_format:Store.repository_format [ core_b; core_a ]
  |> require_divergence

let require_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name) |> require Fun.id

let core_is_canonical () =
  let envelope = Divergence.envelope sample_set |> require_divergence in
  Alcotest.(check string)
    "set envelope golden"
    (require_golden "divergent-ref-set-v1.yeok.hex")
    (Envelope.encode envelope);
  Alcotest.(check string)
    "binding golden"
    (require_golden "sync-divergence-v1.ref.hex")
    (Divergence_store.encode_binding (object_id '\099'));
  let decoded_envelope =
    Envelope.decode (Envelope.encode envelope)
    |> require Envelope.decode_error_to_string
  in
  let decoded_set =
    Divergence.decode_payload (Envelope.payload decoded_envelope)
    |> require_divergence
  in
  Alcotest.(check bool)
    "envelope inverse" true
    (Encoding.equal
       (Divergence.payload sample_set |> require_divergence)
       (Divergence.payload decoded_set |> require_divergence));
  let binding_id = object_id '\099' in
  let decoded_binding =
    Divergence_store.decode_binding (Divergence_store.encode_binding binding_id)
    |> require_divergence_store
  in
  Alcotest.(check bool)
    "binding inverse" true
    (Store.Stored_object_id.equal binding_id decoded_binding);
  let payload = Divergence.payload sample_set |> require_divergence in
  let decoded = Divergence.decode_payload payload |> require_divergence in
  let decoded_payload = Divergence.payload decoded |> require_divergence in
  Alcotest.(check bool)
    "payload inverse" true
    (Encoding.equal payload decoded_payload);
  let other =
    Divergence.make ~repository_format:Store.repository_format
      [ core_a; core_b ]
    |> require_divergence
  in
  Alcotest.(check bool)
    "entry order is canonical" true
    (Encoding.equal payload (Divergence.payload other |> require_divergence));
  let union = Divergence.union sample_set sample_set |> require_divergence in
  Alcotest.(check bool)
    "union is idempotent" true
    (Encoding.equal payload (Divergence.payload union |> require_divergence));
  Alcotest.(check bool)
    "duplicate event rejects" true
    (Result.is_error
       (Divergence.make ~repository_format:Store.repository_format
          [ core_a; core_a ]));
  let stale_event =
    signed_event signer_c ~sequence:1L
      ~observed:(state 1L (Some (object_id '\001')))
      ~target:(object_id '\004')
  in
  let stale =
    Divergence.entry_of_verified ~object_id:(object_id '\099')
      (verify signer_c stale_event)
  in
  Alcotest.(check bool)
    "stale observed state rejects" true
    (Result.is_error
       (Divergence.make ~repository_format:Store.repository_format
          [ core_a; stale ]));
  Alcotest.(check bool)
    "malformed payload rejects" true
    (Result.is_error (Divergence.decode_payload Encoding.null))

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

let with_repository run =
  let root = Filename.temp_file "yeokcham-divergence-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> Store.init ~root |> require_store |> run)

let with_repositories run =
  let root = Filename.temp_file "yeokcham-divergence-pair-" "" in
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

let stored_entry repository signer byte =
  let event =
    signed_event signer ~sequence:0L ~observed:(state 0L None)
      ~target:(object_id byte)
  in
  let object_id =
    Event_store.store_event repository event |> require_event_store
  in
  let entry = Divergence.entry_of_verified ~object_id (verify signer event) in
  { entry; event }

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let assert_ref_unchanged repository reference =
  let actual =
    Store.read_ref repository ~name:"scratch-head" |> require_store
  in
  Alcotest.(check bool)
    "application ref is unchanged" true
    (Option.exists (Store.Mutable_ref.equal reference) actual)

let publication_is_durable_and_merge_only () =
  with_repository (fun repository ->
      let retained =
        Store.put repository (content "retained") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref repository ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let a = stored_entry repository signer_a '\001' in
      let b = stored_entry repository signer_b '\002' in
      let c = stored_entry repository signer_c '\003' in
      let keys = trusted [ signer_a; signer_b; signer_c ] in
      let first =
        Divergence_store.publish repository ~trusted_keys:keys
          [ a.entry; b.entry ]
        |> require_divergence_store
      in
      let duplicate =
        Divergence_store.publish repository ~trusted_keys:keys
          [ b.entry; a.entry ]
        |> require_divergence_store
      in
      Alcotest.(check bool)
        "duplicate publication is idempotent" true
        (Store.Stored_object_id.equal first duplicate);
      let _ =
        Divergence_store.publish repository ~trusted_keys:keys
          [ b.entry; c.entry ]
        |> require_divergence_store
      in
      let published =
        Divergence_store.load_published repository ~trusted_keys:keys
          ~ref_name:"scratch-head"
        |> require_divergence_store |> Option.get
      in
      Alcotest.(check int)
        "union retains all candidates" 3
        (List.length (Divergence.entries published));
      let reopened =
        Store.open_repository ~root:(Store.root repository) |> require_store
      in
      let published =
        Divergence_store.load_published reopened ~trusted_keys:keys
          ~ref_name:"scratch-head"
        |> require_divergence_store |> Option.get
      in
      Alcotest.(check int)
        "reopen retains candidates" 3
        (List.length (Divergence.entries published));
      assert_ref_unchanged reopened reference)

let transferred_candidates_remain_publishable () =
  with_repositories (fun source destination ->
      let a = stored_entry source signer_a '\001' in
      let b = stored_entry source signer_b '\002' in
      let keys = trusted [ signer_a; signer_b ] in
      let source_set =
        Divergence.make ~repository_format:Store.repository_format
          [ a.entry; b.entry ]
        |> require_divergence
        |> Divergence_store.store_set source
        |> require_divergence_store
      in
      let retained =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let session =
        Exchange.session_id_of_bytes "diverge-sync-001"
        |> require Exchange.error_to_string
      in
      let object_ids =
        [
          Divergence.entry_object_id a.entry;
          Divergence.entry_object_id b.entry;
          source_set;
        ]
        |> List.sort Store.Stored_object_id.compare
      in
      Exchange_store.transfer ~source ~destination ~session_id:session
        ~object_ids ()
      |> require_exchange_store |> ignore;
      let a_event =
        Event_store.load_event destination (Divergence.entry_object_id a.entry)
        |> require_event_store
      in
      let b_event =
        Event_store.load_event destination (Divergence.entry_object_id b.entry)
        |> require_event_store
      in
      let destination_entries =
        [
          Divergence.entry_of_verified
            ~object_id:(Divergence.entry_object_id a.entry)
            (verify signer_a a_event);
          Divergence.entry_of_verified
            ~object_id:(Divergence.entry_object_id b.entry)
            (verify signer_b b_event);
        ]
      in
      let published =
        Divergence_store.publish destination ~trusted_keys:keys
          destination_entries
        |> require_divergence_store
      in
      Alcotest.(check bool)
        "transferred set retains its exact object ID" true
        (Store.Stored_object_id.equal source_set published);
      assert_ref_unchanged destination reference)

let persistence_rejections_leave_refs_unchanged () =
  with_repository (fun repository ->
      let retained =
        Store.put repository (content "retained") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref repository ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let a = stored_entry repository signer_a '\001' in
      let b = stored_entry repository signer_b '\002' in
      let keys = trusted [ signer_a; signer_b ] in
      Alcotest.(check bool)
        "untrusted entries reject" true
        (Result.is_error
           (Divergence_store.publish repository ~trusted_keys:[]
              [ a.entry; b.entry ]));
      let wrong_object =
        Store.put repository (content "wrong") |> require_store
      in
      let wrong =
        Divergence.entry_of_verified ~object_id:wrong_object
          (verify signer_a a.event)
      in
      Alcotest.(check bool)
        "wrong object type rejects" true
        (Result.is_error
           (Divergence_store.publish repository ~trusted_keys:keys
              [ wrong; b.entry ]));
      let missing =
        Divergence.entry_of_verified ~object_id:(object_id '\099')
          (verify signer_a a.event)
      in
      Alcotest.(check bool)
        "missing event rejects" true
        (Result.is_error
           (Divergence_store.publish repository ~trusted_keys:keys
              [ missing; b.entry ]));
      let set =
        Divergence.make ~repository_format:Store.repository_format
          [ a.entry; b.entry ]
        |> require_divergence
      in
      let payload = Divergence.payload set |> require_divergence in
      let mismatched_payload =
        match payload with
        | Encoding.Array
            [ version; digest; _; generation; target; entries; features ] ->
            let ref_name =
              Encoding.text "other-head"
              |> require (fun error ->
                  Encoding.construction_error_to_string error)
            in
            Encoding.array
              [
                version; digest; ref_name; generation; target; entries; features;
              ]
            |> require (fun error ->
                Encoding.construction_error_to_string error)
        | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
            Alcotest.fail "divergence payload shape"
      in
      let mismatched =
        Envelope.create ~object_type:Envelope.Divergent_ref_set
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features
          ~payload:mismatched_payload ()
        |> require_envelope |> Store.put repository |> require_store
      in
      let components =
        Divergence_store.binding_components ~ref_name:"scratch-head"
      in
      Store.Ref_file.compare_and_swap repository ~components ~expected:None
        ~replacement:(Divergence_store.encode_binding mismatched)
      |> require_store;
      Alcotest.(check bool)
        "stored context mismatch rejects" true
        (Result.is_error
           (Divergence_store.load_published repository ~trusted_keys:keys
              ~ref_name:"scratch-head"));
      assert_ref_unchanged repository reference)

let corrupt_binding_rejects_without_replacement () =
  with_repository (fun repository ->
      let a = stored_entry repository signer_a '\001' in
      let b = stored_entry repository signer_b '\002' in
      let keys = trusted [ signer_a; signer_b ] in
      let components =
        Divergence_store.binding_components ~ref_name:"scratch-head"
      in
      Store.Ref_file.compare_and_swap repository ~components ~expected:None
        ~replacement:"corrupt"
      |> require_store;
      Alcotest.(check bool)
        "corrupt binding rejects" true
        (Result.is_error
           (Divergence_store.publish repository ~trusted_keys:keys
              [ a.entry; b.entry ]));
      let actual =
        Store.Ref_file.read repository ~components |> require_store
      in
      Alcotest.(check (option string))
        "corrupt binding is retained" (Some "corrupt") actual)

let () =
  Alcotest.run "durable divergent ref-head sets"
    [
      ( "core",
        [
          Alcotest.test_case "canonical verified set and inverse decoder" `Quick
            core_is_canonical;
        ] );
      ( "local store",
        [
          Alcotest.test_case "merge-only publication survives reopen" `Quick
            publication_is_durable_and_merge_only;
          Alcotest.test_case "transferred candidates remain publishable" `Quick
            transferred_candidates_remain_publishable;
          Alcotest.test_case "structured rejections preserve application refs"
            `Quick persistence_rejections_leave_refs_unchanged;
          Alcotest.test_case "corrupt binding is never replaced" `Quick
            corrupt_binding_rejects_without_replacement;
        ] );
    ]
