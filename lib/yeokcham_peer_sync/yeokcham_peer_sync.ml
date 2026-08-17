module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Store = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
module Peer_id = Id.Peer_id
module Contact_id = Id.Peer_contact_id
module Sync_node_id = Id.Peer_sync_node_id
module Sync_conflict_id = Id.Peer_sync_conflict_id

type identity = { identity_id : Peer_id.t; identity_public_key : string }

type endpoint =
  | Local_path of string
  | Ssh of { target : string; root : string }
  | Relay of string

type contact = {
  contact_identity : Contact_id.t;
  contact_name : string;
  contact_peer : identity;
  contact_endpoints : endpoint list;
}

type unsigned_session = {
  session_repository_digest : string;
  session_initiator : Peer_id.t;
  session_responder : Peer_id.t;
  session_nonce : string;
  session_transcript : string;
}

type session_proof = {
  proof_unsigned : unsigned_session;
  proof_algorithm : string;
  proof_signature : string;
}

type sync_node = {
  sync_node_identity : Sync_node_id.t;
  sync_node_author : Peer_id.t;
  sync_node_snapshot : Snapshot.Snapshot.id;
  sync_node_parents : Sync_node_id.t list;
  sync_node_algorithm : string;
  sync_node_signature : string;
}

type sync_conflict = {
  sync_conflict_identity : Sync_conflict_id.t;
  sync_conflict_base : Sync_node_id.t;
  sync_conflict_local : Sync_node_id.t;
  sync_conflict_remote : Sync_node_id.t;
  sync_conflict_paths : string list list;
}

type reconciliation =
  | Fast_forward of sync_node
  | Already_current of sync_node
  | Merged of sync_node
  | Conflict of sync_conflict

type direct_sync =
  | Tracking_advanced of sync_node
  | Tracking_already_current of sync_node
  | Tracking_diverged of { current : Sync_node_id.t; received : sync_node }

type error =
  | Invalid_peer_id of int
  | Invalid_public_key of int
  | Invalid_private_key of string
  | Invalid_signature of int
  | Invalid_nonce of int
  | Invalid_name of string
  | Invalid_endpoint of string
  | Duplicate_endpoint
  | Invalid_repository_format
  | Repository_format_mismatch
  | Identity_mismatch
  | Contact_mismatch
  | Signature_verification_failed
  | Invalid_sync_node of string
  | Invalid_tracking_name of string
  | Tracking_ref_conflict of string
  | No_common_ancestor
  | Exchange_error of Exchange_store.error
  | Snapshot_error of Snapshot.error
  | Entropy_failure of string
  | Unsupported_schema_version of int64
  | Invalid_payload of string
  | Envelope_error of Envelope.creation_error
  | Store_error of Store.error
  | Binding_error of string
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }

let algorithm = "ed25519"
let nonce_bytes = 32
let max_endpoints = 32
let max_name_bytes = 256
let max_endpoint_bytes = 4096
let max_transcript_bytes = 1024 * 1024
let identity_domain = "yeokcham:peer-identity:v1\000"
let contact_domain = "yeokcham:peer-contact:v1\000"
let identity_binding_domain = "yeokcham:peer-identity-binding:v1\000"
let contact_binding_domain = "yeokcham:peer-contact-binding:v1\000"
let session_domain = "yeokcham:peer-session-signature:v1\000"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_peer_id length ->
      Printf.sprintf "peer ID must contain 32 bytes, got %d" length
  | Invalid_public_key length ->
      Printf.sprintf "peer Ed25519 public key must contain 32 bytes, got %d"
        length
  | Invalid_private_key detail -> "invalid peer private key: " ^ detail
  | Invalid_signature length ->
      Printf.sprintf "peer Ed25519 signature must contain 64 bytes, got %d"
        length
  | Invalid_nonce length ->
      Printf.sprintf "peer nonce must contain %d bytes, got %d" nonce_bytes
        length
  | Invalid_name detail -> "invalid peer contact name: " ^ detail
  | Invalid_endpoint detail -> "invalid peer endpoint: " ^ detail
  | Duplicate_endpoint -> "peer contact contains a duplicate endpoint"
  | Invalid_repository_format -> "peer session repository format is empty"
  | Repository_format_mismatch ->
      "peer session repository format does not match"
  | Identity_mismatch -> "peer identity does not match its public key"
  | Contact_mismatch -> "peer session does not match its pinned contact"
  | Signature_verification_failed ->
      "peer session signature verification failed"
  | Invalid_sync_node detail -> "invalid peer sync node: " ^ detail
  | Invalid_tracking_name name -> "invalid peer tracking name: " ^ name
  | Tracking_ref_conflict name ->
      "peer tracking ref changed concurrently: " ^ name
  | No_common_ancestor -> "peer sync heads have no common ancestor"
  | Exchange_error error -> Exchange_store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Entropy_failure detail -> "peer entropy failure: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported peer schema version: %Ld" version
  | Invalid_payload detail -> "invalid peer payload: " ^ detail
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Store_error error -> Store.error_to_string error
  | Binding_error detail -> "peer binding error: " ^ detail
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "peer object has type %d, expected %d"
        (Envelope.object_type_code actual)
        (Envelope.object_type_code expected)

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let repository_digest bytes = Hash.digest_string bytes |> Hash.to_raw_string

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_payload (Printf.sprintf "%s has the wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be bytes"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be text"))

let raw_id name parser value =
  let* raw = bytes name value in
  if String.length raw <> 32 then Error (Invalid_peer_id (String.length raw))
  else
    parser raw
    |> Result.map_error (fun error ->
        Invalid_payload (Id.parse_error_to_string error))

let peer_id identity = identity.identity_id
let public_key identity = identity.identity_public_key

let identity_equal left right =
  Peer_id.equal left.identity_id right.identity_id
  && String.equal left.identity_public_key right.identity_public_key

let derive_peer_id public_key =
  if String.length public_key <> 32 then
    Error (Invalid_public_key (String.length public_key))
  else
    Peer_id.of_bytes (digest identity_domain public_key)
    |> Result.map_error (fun error ->
        Invalid_payload (Id.parse_error_to_string error))

let make_identity ~public_key =
  let* identity_id = derive_peer_id public_key in
  Ok { identity_id; identity_public_key = public_key }

let generate () =
  try
    Mirage_crypto_rng_unix.use_default ();
    let private_key, _ = Mirage_crypto_ec.Ed25519.generate () in
    let public_key =
      Mirage_crypto_ec.Ed25519.pub_of_priv private_key
      |> Mirage_crypto_ec.Ed25519.pub_to_octets
    in
    let* identity = make_identity ~public_key in
    Ok (identity, private_key)
  with _ -> Error (Entropy_failure "OS CSPRNG unavailable")

let identity_payload identity =
  let* algorithm = text algorithm in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes (Peer_id.to_bytes identity.identity_id);
      algorithm;
      Encoding.bytes identity.identity_public_key;
    ]

let decode_identity_payload value =
  let* fields = fields "peer identity" 4 value in
  match fields with
  | [ version; supplied_id; algorithm_value; public_key ] ->
      let* version = integer "peer identity version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* supplied_id =
          raw_id "peer identity ID" Peer_id.of_bytes supplied_id
        in
        let* algorithm_value =
          text_field "peer identity algorithm" algorithm_value
        in
        if not (String.equal algorithm_value algorithm) then
          Error (Invalid_payload "unsupported peer identity algorithm")
        else
          let* public_key = bytes "peer identity public key" public_key in
          let* identity = make_identity ~public_key in
          if not (Peer_id.equal supplied_id identity.identity_id) then
            Error Identity_mismatch
          else
            let* canonical = identity_payload identity in
            if Encoding.equal canonical value then Ok identity
            else Error (Invalid_payload "peer identity is noncanonical")
  | _ -> assert false

let endpoint_key = function
  | Local_path path -> "0\000" ^ path
  | Ssh { target; root } -> "1\000" ^ target ^ "\000" ^ root
  | Relay path -> "2\000" ^ path

let valid_absolute_path path =
  (not (String.is_empty path))
  && String.length path <= max_endpoint_bytes
  && (not (Filename.is_relative path))
  && not (String.contains path '\000')

let collect_results values =
  List.fold_left
    (fun result value ->
      let* reversed = result in
      let* value = value in
      Ok (value :: reversed))
    (Ok []) values
  |> Result.map List.rev

let validate_endpoint = function
  | Local_path path | Relay path ->
      if valid_absolute_path path then Ok ()
      else
        Error (Invalid_endpoint "path must be absolute, bounded, and NUL-free")
  | Ssh { target; root } ->
      if
        String.is_empty target
        || String.length target > max_endpoint_bytes
        || String.contains target '\000'
        || String.contains target '\n'
        || String.contains target '\r'
      then Error (Invalid_endpoint "SSH target is malformed")
      else if valid_absolute_path root then Ok ()
      else
        Error
          (Invalid_endpoint
             "SSH remote root must be absolute, bounded, and NUL-free")

let endpoint_value endpoint =
  let* () = validate_endpoint endpoint in
  match endpoint with
  | Local_path path -> array [ Encoding.integer 0L; Encoding.bytes path ]
  | Ssh { target; root } ->
      array [ Encoding.integer 1L; Encoding.bytes target; Encoding.bytes root ]
  | Relay path -> array [ Encoding.integer 2L; Encoding.bytes path ]

let decode_endpoint value =
  match value with
  | Encoding.Array [ Encoding.Integer 0L; path ] ->
      let* path = bytes "local peer endpoint" path in
      let endpoint = Local_path path in
      let* () = validate_endpoint endpoint in
      Ok endpoint
  | Encoding.Array [ Encoding.Integer 1L; target; root ] ->
      let* target = bytes "SSH peer target" target in
      let* root = bytes "SSH peer root" root in
      let endpoint = Ssh { target; root } in
      let* () = validate_endpoint endpoint in
      Ok endpoint
  | Encoding.Array [ Encoding.Integer 2L; path ] ->
      let* path = bytes "relay peer endpoint" path in
      let endpoint = Relay path in
      let* () = validate_endpoint endpoint in
      Ok endpoint
  | Encoding.Array _ ->
      Error (Invalid_payload "peer endpoint has an unsupported shape")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload "peer endpoint must be an array")

let normalized_endpoints endpoints =
  if endpoints = [] || List.length endpoints > max_endpoints then
    Error (Invalid_endpoint "contact must contain 1 through 32 endpoints")
  else
    let sorted =
      List.sort
        (fun left right ->
          String.compare (endpoint_key left) (endpoint_key right))
        endpoints
    in
    let rec validate previous = function
      | [] -> Ok sorted
      | endpoint :: rest ->
          let* () = validate_endpoint endpoint in
          let key = endpoint_key endpoint in
          if Option.exists (String.equal key) previous then
            Error Duplicate_endpoint
          else validate (Some key) rest
    in
    validate None sorted

let derive_contact_id name identity endpoints =
  let* endpoints = collect_results (List.map endpoint_value endpoints) in
  let* endpoints = array endpoints in
  let* identity_value = identity_payload identity in
  let* preimage =
    array
      [ Encoding.integer 1L; Encoding.bytes name; identity_value; endpoints ]
  in
  Contact_id.of_bytes (digest contact_domain (Encoding.encode preimage))
  |> Result.map_error (fun error ->
      Invalid_payload (Id.parse_error_to_string error))

let make_contact ~name ~identity ~endpoints =
  if
    String.is_empty name
    || String.length name > max_name_bytes
    || String.contains name '\000'
    || String.contains name '\n' || String.contains name '\r'
  then Error (Invalid_name "name must be nonempty, bounded, and line-safe")
  else
    let* endpoints = normalized_endpoints endpoints in
    let* contact_identity = derive_contact_id name identity endpoints in
    Ok
      {
        contact_identity;
        contact_name = name;
        contact_peer = identity;
        contact_endpoints = endpoints;
      }

let contact_id contact = contact.contact_identity
let contact_name contact = contact.contact_name
let contact_identity contact = contact.contact_peer
let contact_endpoints contact = contact.contact_endpoints

let contact_payload contact =
  let* endpoints =
    collect_results (List.map endpoint_value contact.contact_endpoints)
  in
  let* endpoints = array endpoints in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes (Contact_id.to_bytes contact.contact_identity);
      Encoding.bytes contact.contact_name;
      Encoding.bytes (Peer_id.to_bytes contact.contact_peer.identity_id);
      Encoding.bytes contact.contact_peer.identity_public_key;
      endpoints;
    ]

let decode_contact_payload value =
  let* fields = fields "peer contact" 6 value in
  match fields with
  | [ version; supplied_id; name; supplied_peer; public_key; endpoints ] ->
      let* version = integer "peer contact version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* supplied_id =
          raw_id "peer contact ID" Contact_id.of_bytes supplied_id
        in
        let* name = bytes "peer contact name" name in
        let* supplied_peer =
          raw_id "peer contact peer ID" Peer_id.of_bytes supplied_peer
        in
        let* public_key = bytes "peer contact public key" public_key in
        let* identity = make_identity ~public_key in
        if not (Peer_id.equal supplied_peer identity.identity_id) then
          Error Identity_mismatch
        else
          let* endpoints =
            match endpoints with
            | Encoding.Array values ->
                List.fold_left
                  (fun result value ->
                    let* reversed = result in
                    let* endpoint = decode_endpoint value in
                    Ok (endpoint :: reversed))
                  (Ok []) values
                |> Result.map List.rev
            | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
                Error
                  (Invalid_payload "peer contact endpoints must be an array")
          in
          let* contact = make_contact ~name ~identity ~endpoints in
          if not (Contact_id.equal supplied_id contact.contact_identity) then
            Error Contact_mismatch
          else
            let* canonical = contact_payload contact in
            if Encoding.equal canonical value then Ok contact
            else Error (Invalid_payload "peer contact is noncanonical")
  | _ -> assert false

let binding_body logical physical =
  array
    [
      Encoding.integer 1L;
      Encoding.bytes logical;
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
    ]

let binding_bytes domain logical physical =
  let* body = binding_body logical physical in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes logical;
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
      Encoding.bytes (digest domain (Encoding.encode body));
    ]
  |> Result.map Encoding.encode

let decode_binding ~domain ~validate bytes_value =
  let* value =
    Encoding.decode bytes_value
    |> Result.map_error (fun error ->
        Binding_error (Encoding.decode_error_to_string error))
  in
  let* fields = fields "peer binding" 4 value in
  match fields with
  | [ version; logical; physical; checksum ] ->
      let* version = integer "peer binding version" version in
      if not (Int64.equal version 1L) then
        Error (Binding_error "unsupported peer binding version")
      else
        let* logical = bytes "peer binding logical ID" logical in
        let* () = validate logical in
        let* physical = bytes "peer binding physical ID" physical in
        let physical =
          match Store.Stored_object_id.of_raw_bytes physical with
          | Some value -> Ok value
          | None ->
              Error
                (Binding_error "peer binding physical ID must contain 32 bytes")
        in
        let* physical = physical in
        let* checksum = bytes "peer binding checksum" checksum in
        if String.length checksum <> 32 then
          Error (Binding_error "peer binding checksum must contain 32 bytes")
        else
          let* body = binding_body logical physical in
          if not (String.equal checksum (digest domain (Encoding.encode body)))
          then Error (Binding_error "peer binding checksum mismatch")
          else Ok (logical, physical)
  | _ -> assert false

let identity_components id = [ "peer-identities"; Peer_id.to_hex id ]
let contact_components id = [ "peer-contacts"; Contact_id.to_hex id ]

let store_with_binding store ~lock ~components ~logical ~domain ~envelope =
  let* physical =
    Store.put store envelope
    |> Result.map_error (fun error -> Store_error error)
  in
  let* replacement = binding_bytes domain logical physical in
  Store.with_lock store ~name:lock
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let* existing =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match existing with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement
          |> Result.map_error (fun error -> Store_error error)
          |> Result.map (fun () -> physical)
      | Some current ->
          let* current_logical, current_physical =
            decode_binding ~domain ~validate:(fun _ -> Ok ()) current
          in
          if String.equal current_logical logical then Ok current_physical
          else Error (Binding_error "peer binding has a different logical ID"))

let store_identity store identity =
  let* payload = identity_payload identity in
  let* envelope =
    Envelope.create ~object_type:Envelope.Peer_identity
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  store_with_binding store ~lock:"peer-identities"
    ~components:(identity_components identity.identity_id)
    ~logical:(Peer_id.to_bytes identity.identity_id)
    ~domain:identity_binding_domain ~envelope

let store_contact store contact =
  let* _ = store_identity store contact.contact_peer in
  let* payload = contact_payload contact in
  let* envelope =
    Envelope.create ~object_type:Envelope.Peer_contact
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  store_with_binding store ~lock:"peer-contacts"
    ~components:(contact_components contact.contact_identity)
    ~logical:(Contact_id.to_bytes contact.contact_identity)
    ~domain:contact_binding_domain ~envelope

let load_identity store id =
  let* binding =
    Store.Ref_file.read store ~components:(identity_components id)
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Binding_error "peer identity binding is absent")
  | Some binding ->
      let* logical, physical =
        decode_binding ~domain:identity_binding_domain
          ~validate:(fun raw ->
            Peer_id.of_bytes raw
            |> Result.map (fun _ -> ())
            |> Result.map_error (fun _ -> Binding_error "invalid peer ID"))
          binding
      in
      let* logical =
        Peer_id.of_bytes logical
        |> Result.map_error (fun _ -> Binding_error "invalid peer ID")
      in
      if not (Peer_id.equal logical id) then
        Error (Binding_error "peer identity binding disagrees with its path")
      else
        let* envelope =
          Store.get store physical
          |> Result.map_error (fun error -> Store_error error)
        in
        if Envelope.object_type envelope <> Envelope.Peer_identity then
          Error
            (Unexpected_object_type
               {
                 expected = Envelope.Peer_identity;
                 actual = Envelope.object_type envelope;
               })
        else
          let* identity = decode_identity_payload (Envelope.payload envelope) in
          if Peer_id.equal identity.identity_id id then Ok identity
          else Error Identity_mismatch

let load_contact store id =
  let* binding =
    Store.Ref_file.read store ~components:(contact_components id)
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Binding_error "peer contact binding is absent")
  | Some binding ->
      let* logical, physical =
        decode_binding ~domain:contact_binding_domain
          ~validate:(fun raw ->
            Contact_id.of_bytes raw
            |> Result.map (fun _ -> ())
            |> Result.map_error (fun _ ->
                Binding_error "invalid peer contact ID"))
          binding
      in
      let* logical =
        Contact_id.of_bytes logical
        |> Result.map_error (fun _ -> Binding_error "invalid peer contact ID")
      in
      if not (Contact_id.equal logical id) then
        Error (Binding_error "peer contact binding disagrees with its path")
      else
        let* envelope =
          Store.get store physical
          |> Result.map_error (fun error -> Store_error error)
        in
        if Envelope.object_type envelope <> Envelope.Peer_contact then
          Error
            (Unexpected_object_type
               {
                 expected = Envelope.Peer_contact;
                 actual = Envelope.object_type envelope;
               })
        else
          let* contact = decode_contact_payload (Envelope.payload envelope) in
          if Contact_id.equal contact.contact_identity id then Ok contact
          else Error Contact_mismatch

let make_unsigned_session ~repository_format ~initiator ~responder ~nonce
    ~transcript =
  if String.is_empty repository_format then Error Invalid_repository_format
  else if String.length nonce <> nonce_bytes then
    Error (Invalid_nonce (String.length nonce))
  else if String.length transcript > max_transcript_bytes then
    Error (Invalid_payload "peer session transcript exceeds its bound")
  else
    Ok
      {
        session_repository_digest = repository_digest repository_format;
        session_initiator = initiator.identity_id;
        session_responder = responder.identity_id;
        session_nonce = nonce;
        session_transcript = transcript;
      }

let unsigned_session_nonce value = value.session_nonce
let unsigned_session_initiator value = value.session_initiator
let unsigned_session_responder value = value.session_responder

let unsigned_session_payload session =
  array
    [
      Encoding.integer 1L;
      Encoding.bytes session.session_repository_digest;
      Encoding.bytes (Peer_id.to_bytes session.session_initiator);
      Encoding.bytes (Peer_id.to_bytes session.session_responder);
      Encoding.bytes session.session_nonce;
      Encoding.bytes session.session_transcript;
    ]

let session_signing_bytes session =
  unsigned_session_payload session
  |> Result.map Encoding.encode
  |> Result.map (fun payload -> session_domain ^ payload)

let sign_session unsigned_session ~private_key =
  let* signing_bytes = session_signing_bytes unsigned_session in
  try
    let proof_signature =
      Mirage_crypto_ec.Ed25519.sign ~key:private_key signing_bytes
    in
    if String.length proof_signature <> 64 then
      Error
        (Invalid_private_key
           "Ed25519 signer returned an invalid signature length")
    else
      Ok
        {
          proof_unsigned = unsigned_session;
          proof_algorithm = algorithm;
          proof_signature;
        }
  with _ -> Error (Invalid_private_key "Ed25519 signing failed")

let session_proof_payload proof =
  let* unsigned = unsigned_session_payload proof.proof_unsigned in
  let* algorithm = text proof.proof_algorithm in
  if String.length proof.proof_signature <> 64 then
    Error (Invalid_signature (String.length proof.proof_signature))
  else
    array
      [
        Encoding.integer 1L;
        unsigned;
        algorithm;
        Encoding.bytes proof.proof_signature;
      ]

let decode_session_proof_payload value =
  let* proof_fields = fields "peer session proof" 4 value in
  match proof_fields with
  | [ version; unsigned; algorithm_value; signature ] ->
      let* version = integer "peer session proof version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* unsigned_fields = fields "peer session unsigned" 6 unsigned in
        let* session =
          match unsigned_fields with
          | [
           unsigned_version; digest; initiator; responder; nonce; transcript;
          ] ->
              let* unsigned_version =
                integer "peer session unsigned version" unsigned_version
              in
              if not (Int64.equal unsigned_version 1L) then
                Error (Unsupported_schema_version unsigned_version)
              else
                let* session_repository_digest =
                  bytes "peer session repository digest" digest
                in
                let* session_initiator =
                  raw_id "peer session initiator" Peer_id.of_bytes initiator
                in
                let* session_responder =
                  raw_id "peer session responder" Peer_id.of_bytes responder
                in
                let* session_nonce = bytes "peer session nonce" nonce in
                let* session_transcript =
                  bytes "peer session transcript" transcript
                in
                if String.length session_repository_digest <> 32 then
                  Error
                    (Invalid_payload
                       "peer session repository digest must contain 32 bytes")
                else if String.length session_nonce <> nonce_bytes then
                  Error (Invalid_nonce (String.length session_nonce))
                else if String.length session_transcript > max_transcript_bytes
                then
                  Error
                    (Invalid_payload "peer session transcript exceeds its bound")
                else
                  Ok
                    {
                      session_repository_digest;
                      session_initiator;
                      session_responder;
                      session_nonce;
                      session_transcript;
                    }
          | _ -> assert false
        in
        let* proof_algorithm =
          text_field "peer session algorithm" algorithm_value
        in
        let* proof_signature = bytes "peer session signature" signature in
        if not (String.equal proof_algorithm algorithm) then
          Error (Invalid_payload "unsupported peer session algorithm")
        else if String.length proof_signature <> 64 then
          Error (Invalid_signature (String.length proof_signature))
        else
          let proof =
            { proof_unsigned = session; proof_algorithm; proof_signature }
          in
          let* canonical = session_proof_payload proof in
          if Encoding.equal canonical value then Ok proof
          else Error (Invalid_payload "peer session proof is noncanonical")
  | _ -> assert false

let verify_session ~repository_format ~expected_signer ~expected_initiator
    ~expected_responder ~expected_nonce ~expected_transcript proof =
  if String.is_empty repository_format then Error Invalid_repository_format
  else if String.length expected_nonce <> nonce_bytes then
    Error (Invalid_nonce (String.length expected_nonce))
  else if not (String.equal proof.proof_algorithm algorithm) then
    Error (Invalid_payload "unsupported peer session algorithm")
  else if String.length proof.proof_signature <> 64 then
    Error (Invalid_signature (String.length proof.proof_signature))
  else
    let session = proof.proof_unsigned in
    if
      not
        (String.equal session.session_repository_digest
           (repository_digest repository_format))
    then Error Repository_format_mismatch
    else if
      not
        (Peer_id.equal session.session_initiator expected_initiator
        && Peer_id.equal session.session_responder expected_responder
        && String.equal session.session_nonce expected_nonce
        && String.equal session.session_transcript expected_transcript)
    then Error Contact_mismatch
    else if
      not
        (Peer_id.equal expected_signer.contact_peer.identity_id
           expected_initiator)
    then Error Contact_mismatch
    else
      let* signing_bytes = session_signing_bytes session in
      match
        Mirage_crypto_ec.Ed25519.pub_of_octets
          expected_signer.contact_peer.identity_public_key
      with
      | Error _ -> Error Signature_verification_failed
      | Ok public_key -> (
          try
            if
              Mirage_crypto_ec.Ed25519.verify ~key:public_key
                proof.proof_signature ~msg:signing_bytes
            then Ok ()
            else Error Signature_verification_failed
          with _ -> Error Signature_verification_failed)

(* A peer-sync graph is intentionally separate from authoring and release
   graphs.  Its only content claim is an exact snapshot plus causal parents. *)

let sync_node_domain = "yeokcham:peer-sync-node-signature:v1\000"
let sync_node_id_domain = "yeokcham:peer-sync-node-id:v1\000"
let sync_node_binding_domain = "yeokcham:peer-sync-node-binding:v1\000"
let sync_conflict_domain = "yeokcham:peer-sync-conflict:v1\000"
let sync_conflict_binding_domain = "yeokcham:peer-sync-conflict-binding:v1\000"
let tracking_domain = "yeokcham:peer-tracking-ref:v1\000"
let max_sync_parents = 32
let max_sync_graph_nodes = 10_000
let sync_node_id node = node.sync_node_identity
let sync_node_author node = node.sync_node_author
let sync_node_snapshot node = node.sync_node_snapshot
let sync_node_parents node = node.sync_node_parents

let unique_ids name ids =
  if List.length ids > max_sync_parents then
    Error (Invalid_sync_node (name ^ " has too many parents"))
  else
    let sorted =
      List.sort
        (fun left right ->
          String.compare
            (Sync_node_id.to_bytes left)
            (Sync_node_id.to_bytes right))
        ids
    in
    let rec loop = function
      | left :: right :: _
        when String.equal
               (Sync_node_id.to_bytes left)
               (Sync_node_id.to_bytes right) ->
          Error (Invalid_sync_node (name ^ " contains a duplicate parent"))
      | _ :: rest -> loop rest
      | [] -> Ok ()
    in
    loop sorted

let sync_parent_value parents =
  let values =
    List.map
      (fun parent -> Encoding.bytes (Sync_node_id.to_bytes parent))
      parents
  in
  array values

let sync_node_unsigned_value ~author ~snapshot ~parents =
  let* () = unique_ids "peer sync node" parents in
  let* parents = sync_parent_value parents in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes (Peer_id.to_bytes author);
      Encoding.bytes
        (Snapshot.Snapshot.stored_object_id snapshot
        |> Store.Stored_object_id.to_raw_bytes);
      parents;
    ]

let sync_node_signing_bytes ~author ~snapshot ~parents =
  sync_node_unsigned_value ~author ~snapshot ~parents
  |> Result.map Encoding.encode
  |> Result.map (fun bytes -> sync_node_domain ^ bytes)

let sync_node_id_for ~author ~snapshot ~parents ~signature =
  let* signing_bytes = sync_node_signing_bytes ~author ~snapshot ~parents in
  if String.length signature <> 64 then
    Error (Invalid_signature (String.length signature))
  else
    Sync_node_id.of_bytes
      (digest sync_node_id_domain (signing_bytes ^ signature))
    |> Result.map_error (fun error ->
        Invalid_payload (Id.parse_error_to_string error))

let private_key_matches identity private_key =
  try
    let public_key =
      Mirage_crypto_ec.Ed25519.pub_of_priv private_key
      |> Mirage_crypto_ec.Ed25519.pub_to_octets
    in
    String.equal public_key identity.identity_public_key
  with _ -> false

let make_sync_node ~author ~private_key ~snapshot ~parents =
  if not (private_key_matches author private_key) then
    Error (Invalid_private_key "does not match the sync-node author")
  else
    let* signing_bytes =
      sync_node_signing_bytes ~author:author.identity_id ~snapshot ~parents
    in
    try
      let sync_node_signature =
        Mirage_crypto_ec.Ed25519.sign ~key:private_key signing_bytes
      in
      let* sync_node_identity =
        sync_node_id_for ~author:author.identity_id ~snapshot ~parents
          ~signature:sync_node_signature
      in
      Ok
        {
          sync_node_identity;
          sync_node_author = author.identity_id;
          sync_node_snapshot = snapshot;
          sync_node_parents = parents;
          sync_node_algorithm = algorithm;
          sync_node_signature;
        }
    with _ -> Error (Invalid_private_key "Ed25519 signing failed")

let sync_node_payload node =
  let* unsigned =
    sync_node_unsigned_value ~author:node.sync_node_author
      ~snapshot:node.sync_node_snapshot ~parents:node.sync_node_parents
  in
  let* algorithm_value = text node.sync_node_algorithm in
  if not (String.equal node.sync_node_algorithm algorithm) then
    Error (Invalid_sync_node "unsupported signing algorithm")
  else if String.length node.sync_node_signature <> 64 then
    Error (Invalid_signature (String.length node.sync_node_signature))
  else
    array
      [
        Encoding.integer 1L;
        Encoding.bytes (Sync_node_id.to_bytes node.sync_node_identity);
        unsigned;
        algorithm_value;
        Encoding.bytes node.sync_node_signature;
      ]

let sync_node_id_from_value value =
  let* raw = bytes "peer sync node ID" value in
  Sync_node_id.of_bytes raw
  |> Result.map_error (fun _ ->
      Invalid_sync_node "peer sync node ID must contain 32 bytes")

let decode_sync_parents value =
  match value with
  | Encoding.Array values ->
      let* parents =
        collect_results
          (List.map
             (fun value ->
               let* raw = bytes "peer sync parent ID" value in
               Sync_node_id.of_bytes raw
               |> Result.map_error (fun _ ->
                   Invalid_sync_node "peer sync parent ID must contain 32 bytes"))
             values)
      in
      let* () = unique_ids "peer sync node" parents in
      Ok parents
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_sync_node "peer sync parents must be an array")

let decode_sync_node_payload value =
  let* node_fields = fields "peer sync node" 5 value in
  match node_fields with
  | [ version; supplied_id; unsigned; algorithm_value; signature ] ->
      let* version = integer "peer sync node version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* supplied_id = sync_node_id_from_value supplied_id in
        let* unsigned_fields = fields "peer sync node unsigned" 4 unsigned in
        let* sync_node_author, sync_node_snapshot, sync_node_parents =
          match unsigned_fields with
          | [ unsigned_version; author; snapshot; parents ] ->
              let* unsigned_version =
                integer "peer sync node unsigned version" unsigned_version
              in
              if not (Int64.equal unsigned_version 1L) then
                Error (Unsupported_schema_version unsigned_version)
              else
                let* author =
                  raw_id "peer sync node author" Peer_id.of_bytes author
                in
                let* snapshot = bytes "peer sync node snapshot" snapshot in
                let* sync_node_snapshot =
                  match Store.Stored_object_id.of_raw_bytes snapshot with
                  | Some snapshot ->
                      Ok (Snapshot.Snapshot.of_stored_object_id snapshot)
                  | None ->
                      Error
                        (Invalid_sync_node
                           "peer sync snapshot ID must contain 32 bytes")
                in
                let* sync_node_parents = decode_sync_parents parents in
                Ok (author, sync_node_snapshot, sync_node_parents)
          | _ -> assert false
        in
        let* sync_node_algorithm =
          text_field "peer sync node algorithm" algorithm_value
        in
        let* sync_node_signature = bytes "peer sync node signature" signature in
        if not (String.equal sync_node_algorithm algorithm) then
          Error (Invalid_sync_node "unsupported signing algorithm")
        else
          let* expected_id =
            sync_node_id_for ~author:sync_node_author
              ~snapshot:sync_node_snapshot ~parents:sync_node_parents
              ~signature:sync_node_signature
          in
          if not (Sync_node_id.equal supplied_id expected_id) then
            Error
              (Invalid_sync_node
                 "peer sync node ID does not match its signed value")
          else
            let node =
              {
                sync_node_identity = supplied_id;
                sync_node_author;
                sync_node_snapshot;
                sync_node_parents;
                sync_node_algorithm;
                sync_node_signature;
              }
            in
            let* canonical = sync_node_payload node in
            if Encoding.equal canonical value then Ok node
            else Error (Invalid_sync_node "peer sync node is noncanonical")
  | _ -> assert false

let sync_node_components id = [ "peer-sync-nodes"; Sync_node_id.to_hex id ]

let load_sync_node_raw store id =
  let* binding =
    Store.Ref_file.read store ~components:(sync_node_components id)
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Binding_error "peer sync node binding is absent")
  | Some binding ->
      let* logical, physical =
        decode_binding ~domain:sync_node_binding_domain
          ~validate:(fun raw ->
            Sync_node_id.of_bytes raw
            |> Result.map (fun _ -> ())
            |> Result.map_error (fun _ ->
                Binding_error "invalid peer sync node ID"))
          binding
      in
      let* logical =
        Sync_node_id.of_bytes logical
        |> Result.map_error (fun _ -> Binding_error "invalid peer sync node ID")
      in
      if not (Sync_node_id.equal logical id) then
        Error (Binding_error "peer sync node binding disagrees with its path")
      else
        let* envelope =
          Store.get store physical
          |> Result.map_error (fun error -> Store_error error)
        in
        if Envelope.object_type envelope <> Envelope.Peer_sync_node then
          Error
            (Unexpected_object_type
               {
                 expected = Envelope.Peer_sync_node;
                 actual = Envelope.object_type envelope;
               })
        else
          let* node = decode_sync_node_payload (Envelope.payload envelope) in
          if Sync_node_id.equal node.sync_node_identity id then Ok node
          else
            Error
              (Invalid_sync_node "peer sync node binding targets another node")

let verify_sync_node_signature store node =
  let* identity = load_identity store node.sync_node_author in
  let* signing_bytes =
    sync_node_signing_bytes ~author:node.sync_node_author
      ~snapshot:node.sync_node_snapshot ~parents:node.sync_node_parents
  in
  match Mirage_crypto_ec.Ed25519.pub_of_octets identity.identity_public_key with
  | Error _ -> Error Signature_verification_failed
  | Ok public_key -> (
      try
        if
          Mirage_crypto_ec.Ed25519.verify ~key:public_key
            node.sync_node_signature ~msg:signing_bytes
        then Ok ()
        else Error Signature_verification_failed
      with _ -> Error Signature_verification_failed)

let verify_sync_node store node =
  let rec visit visited active node =
    let raw = Sync_node_id.to_bytes node.sync_node_identity in
    if List.exists (String.equal raw) active then
      Error (Invalid_sync_node "peer sync graph contains a cycle")
    else if List.exists (String.equal raw) visited then Ok visited
    else if List.length visited >= max_sync_graph_nodes then
      Error (Invalid_sync_node "peer sync graph exceeds its verification bound")
    else
      let* () = verify_sync_node_signature store node in
      let* _ =
        Snapshot.Snapshot.load store node.sync_node_snapshot
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let visited = raw :: visited in
      List.fold_left
        (fun result parent ->
          let* visited = result in
          let* parent = load_sync_node_raw store parent in
          visit visited (raw :: active) parent)
        (Ok visited) node.sync_node_parents
  in
  visit [] [] node |> Result.map (fun _ -> ())

let load_sync_node store id =
  let* node = load_sync_node_raw store id in
  let* () = verify_sync_node store node in
  Ok node

let store_sync_node store node =
  let* () = unique_ids "peer sync node" node.sync_node_parents in
  let* () = verify_sync_node store node in
  let* payload = sync_node_payload node in
  let* envelope =
    Envelope.create ~object_type:Envelope.Peer_sync_node
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  store_with_binding store ~lock:"peer-sync-nodes"
    ~components:(sync_node_components node.sync_node_identity)
    ~logical:(Sync_node_id.to_bytes node.sync_node_identity)
    ~domain:sync_node_binding_domain ~envelope

let valid_tracking_name name =
  (not (String.is_empty name))
  && String.length name <= 128
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' -> true
         | _ -> false)
       name

let ssh_transcript ~tracking_name ~head =
  if not (valid_tracking_name tracking_name) then
    Error (Invalid_tracking_name tracking_name)
  else
    let* domain = text "yeokcham:peer-sync:ssh:v1" in
    let* tracking_name = text tracking_name in
    array
      [
        Encoding.integer 1L;
        domain;
        tracking_name;
        Encoding.bytes (Sync_node_id.to_bytes head);
      ]
    |> Result.map Encoding.encode

let tracking_components contact name =
  [ "peer-tracking"; Contact_id.to_hex (contact_id contact); name ]

let tracking_checksum contact name node =
  digest tracking_domain
    (Contact_id.to_bytes (contact_id contact)
    ^ "\000" ^ name ^ "\000" ^ Sync_node_id.to_bytes node)

let tracking_bytes contact name node =
  array
    [
      Encoding.integer 1L;
      Encoding.bytes (Contact_id.to_bytes (contact_id contact));
      Encoding.bytes (Sync_node_id.to_bytes node);
      Encoding.bytes (tracking_checksum contact name node);
    ]
  |> Result.map Encoding.encode

let decode_tracking_bytes contact name bytes_value =
  let* value =
    Encoding.decode bytes_value
    |> Result.map_error (fun error ->
        Binding_error (Encoding.decode_error_to_string error))
  in
  let* tracking_fields = fields "peer tracking ref" 4 value in
  match tracking_fields with
  | [ version; bound_contact; node; checksum ] ->
      let* version = integer "peer tracking ref version" version in
      if not (Int64.equal version 1L) then
        Error (Binding_error "unsupported peer tracking ref version")
      else
        let* bound_contact =
          raw_id "peer tracking contact" Contact_id.of_bytes bound_contact
        in
        if not (Contact_id.equal bound_contact (contact_id contact)) then
          Error (Binding_error "peer tracking ref belongs to another contact")
        else
          let* node = sync_node_id_from_value node in
          let* checksum = bytes "peer tracking checksum" checksum in
          if
            String.length checksum <> 32
            || not (String.equal checksum (tracking_checksum contact name node))
          then Error (Binding_error "peer tracking ref checksum is invalid")
          else
            let* canonical = tracking_bytes contact name node in
            if String.equal canonical bytes_value then Ok node
            else Error (Binding_error "peer tracking ref is noncanonical")
  | _ -> assert false

let tracking_head store ~contact ~name =
  if not (valid_tracking_name name) then Error (Invalid_tracking_name name)
  else
    let* current =
      Store.Ref_file.read store ~components:(tracking_components contact name)
      |> Result.map_error (fun error -> Store_error error)
    in
    match current with
    | None -> Ok None
    | Some bytes ->
        let* node = decode_tracking_bytes contact name bytes in
        let* node_value = load_sync_node store node in
        if
          Peer_id.equal node_value.sync_node_author
            (peer_id (contact_identity contact))
        then Ok (Some node)
        else
          Error
            (Binding_error
               "peer tracking head is not authored by its pinned contact")

let update_tracking_head store ~contact ~name ~expected node =
  if not (valid_tracking_name name) then Error (Invalid_tracking_name name)
  else
    let* node_value = load_sync_node store node in
    if
      not
        (Peer_id.equal node_value.sync_node_author
           (peer_id (contact_identity contact)))
    then Error Contact_mismatch
    else
      let* replacement = tracking_bytes contact name node in
      let components = tracking_components contact name in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      let* () =
        match (expected, current) with
        | None, None -> Ok ()
        | Some expected, Some current ->
            let* actual = decode_tracking_bytes contact name current in
            if Sync_node_id.equal expected actual then Ok ()
            else Error (Tracking_ref_conflict name)
        | None, Some _ | Some _, None -> Error (Tracking_ref_conflict name)
      in
      Store.Ref_file.compare_and_swap store ~components ~expected:current
        ~replacement
      |> Result.map_error (fun error -> Store_error error)

let sorted_unique_object_ids identities =
  List.sort_uniq Store.Stored_object_id.compare identities

let collect_sync_content_objects store seen content =
  let identity = Snapshot.Content.stored_object_id content in
  if List.exists (Store.Stored_object_id.equal identity) seen then Ok seen
  else
    let* object_ =
      Store.get store identity
      |> Result.map_error (fun error -> Store_error error)
    in
    let object_type = Envelope.object_type object_ in
    if object_type = Envelope.Content then Ok (identity :: seen)
    else if object_type = Envelope.File_manifest then
      let* manifest =
        Snapshot.Manifest.load store
          (Snapshot.Manifest.of_stored_object_id identity)
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let rec collect_chunks seen = function
        | [] -> Ok seen
        | (chunk, _) :: rest ->
            let identity = Snapshot.Chunk.stored_object_id chunk in
            if List.exists (Store.Stored_object_id.equal identity) seen then
              collect_chunks seen rest
            else
              let* object_ =
                Store.get store identity
                |> Result.map_error (fun error -> Store_error error)
              in
              if Envelope.object_type object_ <> Envelope.Chunk then
                Error
                  (Invalid_sync_node
                     "peer sync snapshot manifest references a non-chunk object")
              else collect_chunks (identity :: seen) rest
      in
      collect_chunks (identity :: seen) (Snapshot.Manifest.chunks manifest)
    else
      Error
        (Invalid_sync_node
           ("peer sync snapshot content has unsupported object type "
           ^ string_of_int (Envelope.object_type_code object_type)))

let rec collect_sync_tree_objects store seen tree =
  let identity = Snapshot.Tree.stored_object_id tree in
  if List.exists (Store.Stored_object_id.equal identity) seen then Ok seen
  else
    let* tree =
      Snapshot.Tree.load store tree
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let rec collect_entries seen = function
      | [] -> Ok seen
      | (_, Snapshot.Tree.File { content; _ }) :: rest ->
          let* seen = collect_sync_content_objects store seen content in
          collect_entries seen rest
      | (_, Snapshot.Tree.Directory child) :: rest ->
          let* seen = collect_sync_tree_objects store seen child in
          collect_entries seen rest
    in
    collect_entries (identity :: seen) (Snapshot.Tree.entries tree)

let collect_sync_snapshot_objects store snapshot =
  let identity = Snapshot.Snapshot.stored_object_id snapshot in
  let* snapshot =
    Snapshot.Snapshot.load store snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  collect_sync_tree_objects store [ identity ] (Snapshot.Snapshot.root snapshot)

let verify_sync_snapshot_closure store snapshot =
  collect_sync_snapshot_objects store snapshot |> Result.map (fun _ -> ())

let collect_sync_nodes store head =
  let rec visit seen identity =
    let raw = Sync_node_id.to_bytes identity in
    if List.mem_assoc raw seen then Ok seen
    else if List.length seen >= max_sync_graph_nodes then
      Error (Invalid_sync_node "peer sync graph exceeds its verification bound")
    else
      let* node = load_sync_node_raw store identity in
      let* seen =
        List.fold_left
          (fun result parent ->
            let* seen = result in
            visit seen parent)
          (Ok seen) node.sync_node_parents
      in
      Ok ((raw, node) :: seen)
  in
  visit [] head |> Result.map (fun nodes -> List.rev_map snd nodes)

let identity_object_id identity =
  let* payload = identity_payload identity in
  let* envelope =
    Envelope.create ~object_type:Envelope.Peer_identity
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  Ok (Store.id_of_envelope envelope)

let sync_node_object_id node =
  let* payload = sync_node_payload node in
  let* envelope =
    Envelope.create ~object_type:Envelope.Peer_sync_node
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  Ok (Store.id_of_envelope envelope)

let sync_transfer_closure store head =
  let* nodes = collect_sync_nodes store head in
  let* identities =
    collect_results
      (List.map (fun node -> load_identity store node.sync_node_author) nodes)
  in
  let identities =
    List.sort_uniq
      (fun left right ->
        String.compare
          (Peer_id.to_bytes (peer_id left))
          (Peer_id.to_bytes (peer_id right)))
      identities
  in
  let* snapshot_objects =
    List.fold_left
      (fun result node ->
        let* seen = result in
        let* closure =
          collect_sync_snapshot_objects store node.sync_node_snapshot
        in
        Ok (List.rev_append closure seen))
      (Ok []) nodes
  in
  let* identity_objects =
    collect_results (List.map identity_object_id identities)
  in
  let* node_objects = collect_results (List.map sync_node_object_id nodes) in
  let* head_node = load_sync_node store head in
  let* head_object = sync_node_object_id head_node in
  let object_ids =
    sorted_unique_object_ids
      (List.rev_append identity_objects
         (List.rev_append node_objects snapshot_objects))
  in
  Ok (object_ids, head_object)

let exchange_session_id domain proof =
  let* payload = session_proof_payload proof in
  let raw = digest domain (Encoding.encode payload) in
  Exchange.session_id_of_bytes (String.sub raw 0 16)
  |> Result.map_error (fun error ->
      Exchange_error (Exchange_store.Protocol_error error))

let sync_transfer_session proof =
  exchange_session_id "yeokcham:peer-sync-local-transfer-session:v1\000" proof

let ssh_session_id proof =
  exchange_session_id "yeokcham:peer-sync-ssh-transfer-session:v1\000" proof

let sync_node_is_ancestor store ~ancestor ~descendant =
  let target = Sync_node_id.to_bytes ancestor in
  let rec visit seen identity =
    let raw = Sync_node_id.to_bytes identity in
    if String.equal raw target then Ok true
    else if List.exists (String.equal raw) seen then Ok false
    else if List.length seen >= max_sync_graph_nodes then
      Error (Invalid_sync_node "peer sync graph exceeds its verification bound")
    else
      let* node = load_sync_node_raw store identity in
      let rec visit_parents = function
        | [] -> Ok false
        | parent :: rest ->
            let* found = visit (raw :: seen) parent in
            if found then Ok true else visit_parents rest
      in
      visit_parents node.sync_node_parents
  in
  visit [] descendant

let advance_tracking store ~contact ~tracking_name ~head =
  let* received = load_sync_node store head in
  let* current = tracking_head store ~contact ~name:tracking_name in
  match current with
  | None ->
      let* () =
        update_tracking_head store ~contact ~name:tracking_name ~expected:None
          head
      in
      Ok (Tracking_advanced received)
  | Some current when Sync_node_id.equal current head ->
      Ok (Tracking_already_current received)
  | Some current ->
      let* current_node = load_sync_node store current in
      let* current_is_ancestor =
        sync_node_is_ancestor store ~ancestor:current ~descendant:head
      in
      if current_is_ancestor then
        let* () =
          update_tracking_head store ~contact ~name:tracking_name
            ~expected:(Some current) head
        in
        Ok (Tracking_advanced received)
      else
        let* received_is_ancestor =
          sync_node_is_ancestor store ~ancestor:head ~descendant:current
        in
        if received_is_ancestor then Ok (Tracking_already_current current_node)
        else Ok (Tracking_diverged { current; received })

let sync_local ?interrupt_after ~source ~destination ~contact
    ~destination_identity ~source_private_key ~nonce ~transcript ~tracking_name
    ~head () =
  let* contact = load_contact destination (contact_id contact) in
  let* configured_destination_identity =
    load_identity destination (peer_id destination_identity)
  in
  if not (identity_equal configured_destination_identity destination_identity)
  then Error Identity_mismatch
  else
    let* source_identity =
      load_identity source (peer_id (contact_identity contact))
    in
    if not (identity_equal source_identity (contact_identity contact)) then
      Error Contact_mismatch
    else
      let* received = load_sync_node source head in
      if
        not
          (Peer_id.equal received.sync_node_author
             (peer_id (contact_identity contact)))
      then Error Contact_mismatch
      else
        let* unsigned =
          make_unsigned_session ~repository_format:Store.repository_format
            ~initiator:source_identity
            ~responder:configured_destination_identity ~nonce ~transcript
        in
        let* proof = sign_session unsigned ~private_key:source_private_key in
        let* () =
          verify_session ~repository_format:Store.repository_format
            ~expected_signer:contact
            ~expected_initiator:(peer_id source_identity)
            ~expected_responder:(peer_id configured_destination_identity)
            ~expected_nonce:nonce ~expected_transcript:transcript proof
        in
        let* nodes = collect_sync_nodes source head in
        let* identities =
          collect_results
            (List.map
               (fun node -> load_identity source node.sync_node_author)
               nodes)
        in
        let identities =
          List.sort_uniq
            (fun left right ->
              String.compare
                (Peer_id.to_bytes (peer_id left))
                (Peer_id.to_bytes (peer_id right)))
            identities
        in
        let* snapshot_objects =
          List.fold_left
            (fun result node ->
              let* seen = result in
              let* closure =
                collect_sync_snapshot_objects source node.sync_node_snapshot
              in
              Ok (List.rev_append closure seen))
            (Ok []) nodes
        in
        let* identity_objects =
          collect_results (List.map identity_object_id identities)
        in
        let* node_objects =
          collect_results (List.map sync_node_object_id nodes)
        in
        let object_ids =
          sorted_unique_object_ids
            (List.rev_append identity_objects
               (List.rev_append node_objects snapshot_objects))
        in
        let* session_id = sync_transfer_session proof in
        let* outcome =
          Exchange_store.transfer ?interrupt_after ~source ~destination
            ~session_id ~object_ids ()
          |> Result.map_error (fun error -> Exchange_error error)
        in
        let* () =
          List.fold_left
            (fun result identity ->
              let* () = result in
              let* _ = store_identity destination identity in
              Ok ())
            (Ok ()) identities
        in
        let* () =
          List.fold_left
            (fun result node ->
              let* () = result in
              let* _ = store_sync_node destination node in
              Ok ())
            (Ok ()) nodes
        in
        let* decision =
          advance_tracking destination ~contact ~tracking_name ~head
        in
        Ok (outcome, decision)

let entry_equal left right =
  match (left, right) with
  | None, None -> true
  | ( Some (Snapshot.Tree.File { mode = left_mode; content = left_content }),
      Some (Snapshot.Tree.File { mode = right_mode; content = right_content }) )
    ->
      left_mode = right_mode
      && Store.Stored_object_id.equal
           (Snapshot.Content.stored_object_id left_content)
           (Snapshot.Content.stored_object_id right_content)
  | Some (Snapshot.Tree.Directory left), Some (Snapshot.Tree.Directory right) ->
      Snapshot.Tree.equal_id left right
  | None, Some _
  | Some _, None
  | Some (Snapshot.Tree.File _), Some (Snapshot.Tree.Directory _)
  | Some (Snapshot.Tree.Directory _), Some (Snapshot.Tree.File _) ->
      false

let find_tree_entry name entries = List.assoc_opt name entries

let path_compare left right =
  String.compare (String.concat "\000" left) (String.concat "\000" right)

let make_conflict ~base ~local ~remote paths =
  let paths = List.sort_uniq path_compare paths in
  if paths = [] then Error (Invalid_sync_node "peer sync conflict has no paths")
  else
    let* path_values =
      collect_results
        (List.map
           (fun path ->
             if
               path = []
               || List.exists
                    (fun segment ->
                      String.is_empty segment
                      || String.contains segment '\000'
                      || String.contains segment '/')
                    path
             then
               Error
                 (Invalid_sync_node "peer sync conflict has an invalid path")
             else array (List.map (fun segment -> Encoding.bytes segment) path))
           paths)
    in
    let* paths_value = array path_values in
    let* unsigned =
      array
        [
          Encoding.integer 1L;
          Encoding.bytes (Sync_node_id.to_bytes base);
          Encoding.bytes (Sync_node_id.to_bytes local);
          Encoding.bytes (Sync_node_id.to_bytes remote);
          paths_value;
        ]
    in
    let* sync_conflict_identity =
      Sync_conflict_id.of_bytes
        (digest sync_conflict_domain (Encoding.encode unsigned))
      |> Result.map_error (fun error ->
          Invalid_payload (Id.parse_error_to_string error))
    in
    Ok
      {
        sync_conflict_identity;
        sync_conflict_base = base;
        sync_conflict_local = local;
        sync_conflict_remote = remote;
        sync_conflict_paths = paths;
      }

let conflict_id conflict = conflict.sync_conflict_identity
let conflict_paths conflict = conflict.sync_conflict_paths
let conflict_base conflict = conflict.sync_conflict_base
let conflict_local conflict = conflict.sync_conflict_local
let conflict_remote conflict = conflict.sync_conflict_remote

let sync_conflict_payload conflict =
  let* expected =
    make_conflict ~base:conflict.sync_conflict_base
      ~local:conflict.sync_conflict_local ~remote:conflict.sync_conflict_remote
      conflict.sync_conflict_paths
  in
  if
    not
      (Sync_conflict_id.equal expected.sync_conflict_identity
         conflict.sync_conflict_identity)
  then
    Error (Invalid_sync_node "peer sync conflict ID does not match its value")
  else
    let* path_values =
      collect_results
        (List.map
           (fun path ->
             array (List.map (fun segment -> Encoding.bytes segment) path))
           conflict.sync_conflict_paths)
    in
    let* paths = array path_values in
    array
      [
        Encoding.integer 1L;
        Encoding.bytes
          (Sync_conflict_id.to_bytes conflict.sync_conflict_identity);
        Encoding.bytes (Sync_node_id.to_bytes conflict.sync_conflict_base);
        Encoding.bytes (Sync_node_id.to_bytes conflict.sync_conflict_local);
        Encoding.bytes (Sync_node_id.to_bytes conflict.sync_conflict_remote);
        paths;
      ]

let store_sync_conflict store conflict =
  let* _ = load_sync_node store conflict.sync_conflict_base in
  let* _ = load_sync_node store conflict.sync_conflict_local in
  let* _ = load_sync_node store conflict.sync_conflict_remote in
  let* payload = sync_conflict_payload conflict in
  let* envelope =
    Envelope.create ~object_type:Envelope.Peer_sync_conflict
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  store_with_binding store ~lock:"peer-sync-conflicts"
    ~components:
      [
        "peer-sync-conflicts";
        Sync_conflict_id.to_hex conflict.sync_conflict_identity;
      ]
    ~logical:(Sync_conflict_id.to_bytes conflict.sync_conflict_identity)
    ~domain:sync_conflict_binding_domain ~envelope

let rec ancestors store distance node seen =
  let raw = Sync_node_id.to_bytes node in
  if List.mem_assoc raw seen then Ok seen
  else
    let* value = load_sync_node_raw store node in
    let seen = (raw, (node, distance)) :: seen in
    List.fold_left
      (fun result parent ->
        let* seen = result in
        ancestors store (distance + 1) parent seen)
      (Ok seen) value.sync_node_parents

let common_ancestor store left right =
  let* left_ancestors = ancestors store 0 left [] in
  let* right_ancestors = ancestors store 0 right [] in
  let candidates =
    List.filter_map
      (fun (raw, (node, left_distance)) ->
        match List.assoc_opt raw right_ancestors with
        | None -> None
        | Some (_, right_distance) -> Some (node, left_distance + right_distance))
      left_ancestors
  in
  match
    List.sort
      (fun (left_id, left_distance) (right_id, right_distance) ->
        match Int.compare left_distance right_distance with
        | 0 ->
            String.compare
              (Sync_node_id.to_bytes left_id)
              (Sync_node_id.to_bytes right_id)
        | comparison -> comparison)
      candidates
  with
  | (node, _) :: _ -> Ok node
  | [] -> Error No_common_ancestor

let rec merge_tree store ~path ~base ~left ~right =
  let* base_entries =
    match base with
    | None -> Ok []
    | Some id ->
        Snapshot.Tree.load store id
        |> Result.map Snapshot.Tree.entries
        |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* left_entries =
    Snapshot.Tree.load store left
    |> Result.map Snapshot.Tree.entries
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* right_entries =
    Snapshot.Tree.load store right
    |> Result.map Snapshot.Tree.entries
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let names =
    List.sort_uniq String.compare
      (List.map fst base_entries @ List.map fst left_entries
     @ List.map fst right_entries)
  in
  let rec merge_entries entries conflicts = function
    | [] ->
        if conflicts <> [] then Ok (None, conflicts)
        else
          let* tree =
            Snapshot.Tree.create (List.rev entries)
            |> Result.map_error (fun error -> Snapshot_error error)
          in
          let* tree =
            Snapshot.Tree.store store tree
            |> Result.map_error (fun error -> Snapshot_error error)
          in
          Ok (Some tree, [])
    | name :: rest ->
        let base_entry = find_tree_entry name base_entries in
        let left_entry = find_tree_entry name left_entries in
        let right_entry = find_tree_entry name right_entries in
        let* chosen, new_conflicts =
          if entry_equal base_entry left_entry then Ok (right_entry, [])
          else if entry_equal base_entry right_entry then Ok (left_entry, [])
          else if entry_equal left_entry right_entry then Ok (left_entry, [])
          else
            match (left_entry, right_entry) with
            | ( Some (Snapshot.Tree.Directory left_child),
                Some (Snapshot.Tree.Directory right_child) ) ->
                let base_child =
                  match base_entry with
                  | Some (Snapshot.Tree.Directory id) -> Some id
                  | None | Some (Snapshot.Tree.File _) -> None
                in
                let* child, child_conflicts =
                  merge_tree store ~path:(path @ [ name ]) ~base:base_child
                    ~left:left_child ~right:right_child
                in
                Ok
                  ( Option.map (fun child -> Snapshot.Tree.Directory child) child,
                    child_conflicts )
            | None, None -> Ok (None, [])
            | Some (Snapshot.Tree.File _), Some (Snapshot.Tree.File _)
            | Some (Snapshot.Tree.File _), None
            | None, Some (Snapshot.Tree.File _)
            | Some (Snapshot.Tree.Directory _), None
            | None, Some (Snapshot.Tree.Directory _)
            | Some (Snapshot.Tree.File _), Some (Snapshot.Tree.Directory _)
            | Some (Snapshot.Tree.Directory _), Some (Snapshot.Tree.File _) ->
                Ok (None, [ path @ [ name ] ])
        in
        let entries =
          match chosen with
          | None -> entries
          | Some entry -> (name, entry) :: entries
        in
        merge_entries entries (List.rev_append new_conflicts conflicts) rest
  in
  merge_entries [] [] names

let reconcile store ~author ~private_key ~local ~remote =
  let* local_node = load_sync_node store local in
  let* remote_node = load_sync_node store remote in
  let* base = common_ancestor store local remote in
  if Sync_node_id.equal base local then Ok (Fast_forward remote_node)
  else if Sync_node_id.equal base remote then Ok (Already_current local_node)
  else
    let* base_node = load_sync_node store base in
    let* base_snapshot =
      Snapshot.Snapshot.load store base_node.sync_node_snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* local_snapshot =
      Snapshot.Snapshot.load store local_node.sync_node_snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* remote_snapshot =
      Snapshot.Snapshot.load store remote_node.sync_node_snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* merged_root, conflicts =
      merge_tree store ~path:[]
        ~base:(Some (Snapshot.Snapshot.root base_snapshot))
        ~left:(Snapshot.Snapshot.root local_snapshot)
        ~right:(Snapshot.Snapshot.root remote_snapshot)
    in
    match (merged_root, conflicts) with
    | Some root, [] ->
        let snapshot = Snapshot.Snapshot.create ~root in
        let* snapshot =
          Snapshot.Snapshot.store store snapshot
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        let* node =
          make_sync_node ~author ~private_key ~snapshot
            ~parents:[ local; remote ]
        in
        let* _ = store_sync_node store node in
        Ok (Merged node)
    | None, conflicts ->
        let* conflict = make_conflict ~base ~local ~remote conflicts in
        let* _ = store_sync_conflict store conflict in
        Ok (Conflict conflict)
    | Some _, _ :: _ -> assert false
