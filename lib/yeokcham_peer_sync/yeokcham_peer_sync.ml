module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Store = Yeokcham_store

module Peer_id = Id.Peer_id
module Contact_id = Id.Peer_contact_id

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
  | Invalid_peer_id length -> Printf.sprintf "peer ID must contain 32 bytes, got %d" length
  | Invalid_public_key length -> Printf.sprintf "peer Ed25519 public key must contain 32 bytes, got %d" length
  | Invalid_private_key detail -> "invalid peer private key: " ^ detail
  | Invalid_signature length -> Printf.sprintf "peer Ed25519 signature must contain 64 bytes, got %d" length
  | Invalid_nonce length -> Printf.sprintf "peer nonce must contain %d bytes, got %d" nonce_bytes length
  | Invalid_name detail -> "invalid peer contact name: " ^ detail
  | Invalid_endpoint detail -> "invalid peer endpoint: " ^ detail
  | Duplicate_endpoint -> "peer contact contains a duplicate endpoint"
  | Invalid_repository_format -> "peer session repository format is empty"
  | Repository_format_mismatch -> "peer session repository format does not match"
  | Identity_mismatch -> "peer identity does not match its public key"
  | Contact_mismatch -> "peer session does not match its pinned contact"
  | Signature_verification_failed -> "peer session signature verification failed"
  | Entropy_failure detail -> "peer entropy failure: " ^ detail
  | Unsupported_schema_version version -> Printf.sprintf "unsupported peer schema version: %Ld" version
  | Invalid_payload detail -> "invalid peer payload: " ^ detail
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Store_error error -> Store.error_to_string error
  | Binding_error detail -> "peer binding error: " ^ detail
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "peer object has type %d, expected %d"
        (Envelope.object_type_code actual) (Envelope.object_type_code expected)

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let repository_digest bytes = Hash.digest_string bytes |> Hash.to_raw_string

let array values =
  Encoding.array values
  |> Result.map_error (fun error -> Invalid_payload (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error -> Invalid_payload (Encoding.construction_error_to_string error))

let fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ -> Error (Invalid_payload (Printf.sprintf "%s has the wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be bytes"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be text"))

let raw_id name parser value =
  let* raw = bytes name value in
  if String.length raw <> 32 then Error (Invalid_peer_id (String.length raw))
  else parser raw |> Result.map_error (fun error -> Invalid_payload (Id.parse_error_to_string error))

let peer_id identity = identity.identity_id
let public_key identity = identity.identity_public_key
let identity_equal left right = Peer_id.equal left.identity_id right.identity_id && String.equal left.identity_public_key right.identity_public_key

let derive_peer_id public_key =
  if String.length public_key <> 32 then Error (Invalid_public_key (String.length public_key))
  else
    Peer_id.of_bytes (digest identity_domain public_key)
    |> Result.map_error (fun error -> Invalid_payload (Id.parse_error_to_string error))

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
  array [ Encoding.integer 1L; Encoding.bytes (Peer_id.to_bytes identity.identity_id); algorithm; Encoding.bytes identity.identity_public_key ]

let decode_identity_payload value =
  let* fields = fields "peer identity" 4 value in
  match fields with
  | [ version; supplied_id; algorithm_value; public_key ] ->
      let* version = integer "peer identity version" version in
      if not (Int64.equal version 1L) then Error (Unsupported_schema_version version)
      else
        let* supplied_id = raw_id "peer identity ID" Peer_id.of_bytes supplied_id in
        let* algorithm_value = text_field "peer identity algorithm" algorithm_value in
        if not (String.equal algorithm_value algorithm) then Error (Invalid_payload "unsupported peer identity algorithm")
        else
          let* public_key = bytes "peer identity public key" public_key in
          let* identity = make_identity ~public_key in
          if not (Peer_id.equal supplied_id identity.identity_id) then Error Identity_mismatch
          else
            let* canonical = identity_payload identity in
            if Encoding.equal canonical value then Ok identity else Error (Invalid_payload "peer identity is noncanonical")
  | _ -> assert false

let endpoint_key = function
  | Local_path path -> "0\000" ^ path
  | Ssh { target; root } -> "1\000" ^ target ^ "\000" ^ root
  | Relay path -> "2\000" ^ path

let valid_absolute_path path =
  not (String.is_empty path)
  && String.length path <= max_endpoint_bytes
  && not (Filename.is_relative path)
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
      if valid_absolute_path path then Ok () else Error (Invalid_endpoint "path must be absolute, bounded, and NUL-free")
  | Ssh { target; root } ->
      if String.is_empty target || String.length target > max_endpoint_bytes || String.contains target '\000' || String.contains target '\n' || String.contains target '\r' then Error (Invalid_endpoint "SSH target is malformed")
      else if valid_absolute_path root then Ok ()
      else Error (Invalid_endpoint "SSH remote root must be absolute, bounded, and NUL-free")

let endpoint_value endpoint =
  let* () = validate_endpoint endpoint in
  match endpoint with
  | Local_path path -> array [ Encoding.integer 0L; Encoding.bytes path ]
  | Ssh { target; root } -> array [ Encoding.integer 1L; Encoding.bytes target; Encoding.bytes root ]
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
  | Encoding.Array _ -> Error (Invalid_payload "peer endpoint has an unsupported shape")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null -> Error (Invalid_payload "peer endpoint must be an array")

let normalized_endpoints endpoints =
  if endpoints = [] || List.length endpoints > max_endpoints then Error (Invalid_endpoint "contact must contain 1 through 32 endpoints")
  else
    let sorted = List.sort (fun left right -> String.compare (endpoint_key left) (endpoint_key right)) endpoints in
    let rec validate previous = function
      | [] -> Ok sorted
      | endpoint :: rest ->
          let* () = validate_endpoint endpoint in
          let key = endpoint_key endpoint in
          if Option.exists (String.equal key) previous then Error Duplicate_endpoint
          else validate (Some key) rest
    in
    validate None sorted

let derive_contact_id name identity endpoints =
  let* endpoints = collect_results (List.map endpoint_value endpoints) in
  let* endpoints = array endpoints in
  let* identity_value = identity_payload identity in
  let* preimage = array [ Encoding.integer 1L; Encoding.bytes name; identity_value; endpoints ] in
  Contact_id.of_bytes (digest contact_domain (Encoding.encode preimage))
  |> Result.map_error (fun error -> Invalid_payload (Id.parse_error_to_string error))

let make_contact ~name ~identity ~endpoints =
  if String.is_empty name || String.length name > max_name_bytes || String.contains name '\000' || String.contains name '\n' || String.contains name '\r' then Error (Invalid_name "name must be nonempty, bounded, and line-safe")
  else
    let* endpoints = normalized_endpoints endpoints in
    let* contact_identity = derive_contact_id name identity endpoints in
    Ok { contact_identity; contact_name = name; contact_peer = identity; contact_endpoints = endpoints }

let contact_id contact = contact.contact_identity
let contact_name contact = contact.contact_name
let contact_identity contact = contact.contact_peer
let contact_endpoints contact = contact.contact_endpoints

let contact_payload contact =
  let* endpoints = collect_results (List.map endpoint_value contact.contact_endpoints) in
  let* endpoints = array endpoints in
  array [ Encoding.integer 1L; Encoding.bytes (Contact_id.to_bytes contact.contact_identity); Encoding.bytes contact.contact_name; Encoding.bytes (Peer_id.to_bytes contact.contact_peer.identity_id); Encoding.bytes contact.contact_peer.identity_public_key; endpoints ]

let decode_contact_payload value =
  let* fields = fields "peer contact" 6 value in
  match fields with
  | [ version; supplied_id; name; supplied_peer; public_key; endpoints ] ->
      let* version = integer "peer contact version" version in
      if not (Int64.equal version 1L) then Error (Unsupported_schema_version version)
      else
        let* supplied_id = raw_id "peer contact ID" Contact_id.of_bytes supplied_id in
        let* name = bytes "peer contact name" name in
        let* supplied_peer = raw_id "peer contact peer ID" Peer_id.of_bytes supplied_peer in
        let* public_key = bytes "peer contact public key" public_key in
        let* identity = make_identity ~public_key in
        if not (Peer_id.equal supplied_peer identity.identity_id) then Error Identity_mismatch
        else
          let* endpoints =
            match endpoints with
            | Encoding.Array values ->
                List.fold_left (fun result value -> let* reversed = result in let* endpoint = decode_endpoint value in Ok (endpoint :: reversed)) (Ok []) values |> Result.map List.rev
            | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null -> Error (Invalid_payload "peer contact endpoints must be an array")
          in
          let* contact = make_contact ~name ~identity ~endpoints in
          if not (Contact_id.equal supplied_id contact.contact_identity) then Error Contact_mismatch
          else
            let* canonical = contact_payload contact in
            if Encoding.equal canonical value then Ok contact else Error (Invalid_payload "peer contact is noncanonical")
  | _ -> assert false

let binding_body logical physical = array [ Encoding.integer 1L; Encoding.bytes logical; Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical) ]
let binding_bytes domain logical physical =
  let* body = binding_body logical physical in
  array [ Encoding.integer 1L; Encoding.bytes logical; Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical); Encoding.bytes (digest domain (Encoding.encode body)) ] |> Result.map Encoding.encode

let decode_binding ~domain ~validate bytes_value =
  let* value = Encoding.decode bytes_value |> Result.map_error (fun error -> Binding_error (Encoding.decode_error_to_string error)) in
  let* fields = fields "peer binding" 4 value in
  match fields with
  | [ version; logical; physical; checksum ] ->
      let* version = integer "peer binding version" version in
      if not (Int64.equal version 1L) then Error (Binding_error "unsupported peer binding version")
      else
        let* logical = bytes "peer binding logical ID" logical in
        let* () = validate logical in
        let* physical = bytes "peer binding physical ID" physical in
        let physical = match Store.Stored_object_id.of_raw_bytes physical with Some value -> Ok value | None -> Error (Binding_error "peer binding physical ID must contain 32 bytes") in
        let* physical = physical in
        let* checksum = bytes "peer binding checksum" checksum in
        if String.length checksum <> 32 then Error (Binding_error "peer binding checksum must contain 32 bytes")
        else
          let* body = binding_body logical physical in
          if not (String.equal checksum (digest domain (Encoding.encode body))) then Error (Binding_error "peer binding checksum mismatch")
          else Ok (logical, physical)
  | _ -> assert false

let identity_components id = [ "peer-identities"; Peer_id.to_hex id ]
let contact_components id = [ "peer-contacts"; Contact_id.to_hex id ]

let store_with_binding store ~lock ~components ~logical ~domain ~envelope =
  let* physical = Store.put store envelope |> Result.map_error (fun error -> Store_error error) in
  let* replacement = binding_bytes domain logical physical in
  Store.with_lock store ~name:lock ~on_error:(fun error -> Store_error error) (fun () ->
      let* existing = Store.Ref_file.read store ~components |> Result.map_error (fun error -> Store_error error) in
      match existing with
      | None -> Store.Ref_file.compare_and_swap store ~components ~expected:None ~replacement |> Result.map_error (fun error -> Store_error error) |> Result.map (fun () -> physical)
      | Some current ->
          let* current_logical, current_physical =
            decode_binding ~domain ~validate:(fun _ -> Ok ()) current
          in
          if String.equal current_logical logical then Ok current_physical else Error (Binding_error "peer binding has a different logical ID"))

let store_identity store identity =
  let* payload = identity_payload identity in
  let* envelope = Envelope.create ~object_type:Envelope.Peer_identity ~object_format_version:Envelope.current_object_format_version ~mandatory_features:Envelope.supported_mandatory_features ~payload () |> Result.map_error (fun error -> Envelope_error error) in
  store_with_binding store ~lock:"peer-identities" ~components:(identity_components identity.identity_id) ~logical:(Peer_id.to_bytes identity.identity_id) ~domain:identity_binding_domain ~envelope

let store_contact store contact =
  let* _ = store_identity store contact.contact_peer in
  let* payload = contact_payload contact in
  let* envelope = Envelope.create ~object_type:Envelope.Peer_contact ~object_format_version:Envelope.current_object_format_version ~mandatory_features:Envelope.supported_mandatory_features ~payload () |> Result.map_error (fun error -> Envelope_error error) in
  store_with_binding store ~lock:"peer-contacts" ~components:(contact_components contact.contact_identity) ~logical:(Contact_id.to_bytes contact.contact_identity) ~domain:contact_binding_domain ~envelope

let load_identity store id =
  let* binding = Store.Ref_file.read store ~components:(identity_components id) |> Result.map_error (fun error -> Store_error error) in
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
      if not (Peer_id.equal logical id) then Error (Binding_error "peer identity binding disagrees with its path")
      else
        let* envelope = Store.get store physical |> Result.map_error (fun error -> Store_error error) in
        if Envelope.object_type envelope <> Envelope.Peer_identity then Error (Unexpected_object_type { expected = Envelope.Peer_identity; actual = Envelope.object_type envelope })
        else
          let* identity = decode_identity_payload (Envelope.payload envelope) in
          if Peer_id.equal identity.identity_id id then Ok identity else Error Identity_mismatch

let load_contact store id =
  let* binding = Store.Ref_file.read store ~components:(contact_components id) |> Result.map_error (fun error -> Store_error error) in
  match binding with
  | None -> Error (Binding_error "peer contact binding is absent")
  | Some binding ->
      let* logical, physical =
        decode_binding ~domain:contact_binding_domain
          ~validate:(fun raw ->
            Contact_id.of_bytes raw
            |> Result.map (fun _ -> ())
            |> Result.map_error (fun _ -> Binding_error "invalid peer contact ID"))
          binding
      in
      let* logical =
        Contact_id.of_bytes logical
        |> Result.map_error (fun _ -> Binding_error "invalid peer contact ID")
      in
      if not (Contact_id.equal logical id) then Error (Binding_error "peer contact binding disagrees with its path")
      else
        let* envelope = Store.get store physical |> Result.map_error (fun error -> Store_error error) in
        if Envelope.object_type envelope <> Envelope.Peer_contact then Error (Unexpected_object_type { expected = Envelope.Peer_contact; actual = Envelope.object_type envelope })
        else
          let* contact = decode_contact_payload (Envelope.payload envelope) in
          if Contact_id.equal contact.contact_identity id then Ok contact else Error Contact_mismatch

let make_unsigned_session ~repository_format ~initiator ~responder ~nonce ~transcript =
  if String.is_empty repository_format then Error Invalid_repository_format
  else if String.length nonce <> nonce_bytes then Error (Invalid_nonce (String.length nonce))
  else if String.length transcript > max_transcript_bytes then Error (Invalid_payload "peer session transcript exceeds its bound")
  else Ok { session_repository_digest = repository_digest repository_format; session_initiator = initiator.identity_id; session_responder = responder.identity_id; session_nonce = nonce; session_transcript = transcript }

let unsigned_session_nonce value = value.session_nonce
let unsigned_session_initiator value = value.session_initiator
let unsigned_session_responder value = value.session_responder

let unsigned_session_payload session =
  array [ Encoding.integer 1L; Encoding.bytes session.session_repository_digest; Encoding.bytes (Peer_id.to_bytes session.session_initiator); Encoding.bytes (Peer_id.to_bytes session.session_responder); Encoding.bytes session.session_nonce; Encoding.bytes session.session_transcript ]

let session_signing_bytes session = unsigned_session_payload session |> Result.map Encoding.encode |> Result.map (fun payload -> session_domain ^ payload)

let sign_session unsigned_session ~private_key =
  let* signing_bytes = session_signing_bytes unsigned_session in
  try
    let proof_signature = Mirage_crypto_ec.Ed25519.sign ~key:private_key signing_bytes in
    if String.length proof_signature <> 64 then Error (Invalid_private_key "Ed25519 signer returned an invalid signature length")
    else Ok { proof_unsigned = unsigned_session; proof_algorithm = algorithm; proof_signature }
  with _ -> Error (Invalid_private_key "Ed25519 signing failed")

let session_proof_payload proof =
  let* unsigned = unsigned_session_payload proof.proof_unsigned in
  let* algorithm = text proof.proof_algorithm in
  if String.length proof.proof_signature <> 64 then Error (Invalid_signature (String.length proof.proof_signature))
  else array [ Encoding.integer 1L; unsigned; algorithm; Encoding.bytes proof.proof_signature ]

let decode_session_proof_payload value =
  let* proof_fields = fields "peer session proof" 4 value in
  match proof_fields with
  | [ version; unsigned; algorithm_value; signature ] ->
      let* version = integer "peer session proof version" version in
      if not (Int64.equal version 1L) then Error (Unsupported_schema_version version)
      else
        let* unsigned_fields = fields "peer session unsigned" 6 unsigned in
        let* session =
          match unsigned_fields with
          | [ unsigned_version; digest; initiator; responder; nonce; transcript ] ->
              let* unsigned_version = integer "peer session unsigned version" unsigned_version in
              if not (Int64.equal unsigned_version 1L) then Error (Unsupported_schema_version unsigned_version)
              else
                let* session_repository_digest = bytes "peer session repository digest" digest in
                let* session_initiator = raw_id "peer session initiator" Peer_id.of_bytes initiator in
                let* session_responder = raw_id "peer session responder" Peer_id.of_bytes responder in
                let* session_nonce = bytes "peer session nonce" nonce in
                let* session_transcript = bytes "peer session transcript" transcript in
                if String.length session_repository_digest <> 32 then Error (Invalid_payload "peer session repository digest must contain 32 bytes")
                else if String.length session_nonce <> nonce_bytes then Error (Invalid_nonce (String.length session_nonce))
                else if String.length session_transcript > max_transcript_bytes then Error (Invalid_payload "peer session transcript exceeds its bound")
                else Ok { session_repository_digest; session_initiator; session_responder; session_nonce; session_transcript }
          | _ -> assert false
        in
        let* proof_algorithm = text_field "peer session algorithm" algorithm_value in
        let* proof_signature = bytes "peer session signature" signature in
        if not (String.equal proof_algorithm algorithm) then Error (Invalid_payload "unsupported peer session algorithm")
        else if String.length proof_signature <> 64 then Error (Invalid_signature (String.length proof_signature))
        else
          let proof = { proof_unsigned = session; proof_algorithm; proof_signature } in
          let* canonical = session_proof_payload proof in
          if Encoding.equal canonical value then Ok proof else Error (Invalid_payload "peer session proof is noncanonical")
  | _ -> assert false

let verify_session ~repository_format ~expected_signer ~expected_initiator ~expected_responder ~expected_nonce ~expected_transcript proof =
  if String.is_empty repository_format then Error Invalid_repository_format
  else if String.length expected_nonce <> nonce_bytes then Error (Invalid_nonce (String.length expected_nonce))
  else if not (String.equal proof.proof_algorithm algorithm) then Error (Invalid_payload "unsupported peer session algorithm")
  else if String.length proof.proof_signature <> 64 then Error (Invalid_signature (String.length proof.proof_signature))
  else
    let session = proof.proof_unsigned in
    if not (String.equal session.session_repository_digest (repository_digest repository_format)) then Error Repository_format_mismatch
    else if
      not
        (Peer_id.equal session.session_initiator expected_initiator
        && Peer_id.equal session.session_responder expected_responder
        && String.equal session.session_nonce expected_nonce
        && String.equal session.session_transcript expected_transcript)
    then Error Contact_mismatch
    else if not (Peer_id.equal expected_signer.contact_peer.identity_id expected_initiator) then Error Contact_mismatch
    else
      let* signing_bytes = session_signing_bytes session in
      match
        Mirage_crypto_ec.Ed25519.pub_of_octets
          expected_signer.contact_peer.identity_public_key
      with
      | Error _ -> Error Signature_verification_failed
      | Ok public_key ->
          try
            if
              Mirage_crypto_ec.Ed25519.verify ~key:public_key
                proof.proof_signature ~msg:signing_bytes
            then Ok () else Error Signature_verification_failed
          with _ -> Error Signature_verification_failed
