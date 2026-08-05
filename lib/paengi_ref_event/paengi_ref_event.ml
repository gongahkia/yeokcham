module Encoding = Paengi_encoding
module Event_id = Paengi_id.Ref_event_id
module Hash = Paengi_hash.Sha256
module Object_id = Paengi_store.Stored_object_id

type signer_key_id = string
type ref_state = { generation : int64; target : Object_id.t option }

type unsigned = {
  event_id : Event_id.t;
  repository_format_digest : string;
  ref_name : string;
  signer_key_id : signer_key_id;
  signer_sequence : int64;
  previous : Event_id.t option;
  observed : ref_state;
  proposed : ref_state;
  mandatory_features : int64;
}

type t = { unsigned : unsigned; algorithm : string; signature : string }
type trusted_key = { key_id : signer_key_id; public_key : string }
type verification = Verified | Untrusted

type evaluation =
  | Ready
  | Replayed of Event_id.t
  | Stale_observed_ref
  | Missing_predecessor of Event_id.t
  | Signer_sequence_reused of int64
  | Divergent of Event_id.t list

type error =
  | Invalid_ref_name of string
  | Invalid_generation of int64
  | Invalid_proposed_generation of { observed : int64; proposed : int64 }
  | Invalid_signer_sequence of int64
  | Invalid_signer_key_id of int
  | Invalid_event_id of int
  | Invalid_public_key of int
  | Invalid_signature of int
  | Unsupported_algorithm of string
  | Unsupported_mandatory_features of int64
  | Invalid_repository_format
  | Repository_format_mismatch
  | Invalid_identity of string
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Trust_map_too_large of int
  | Invalid_trust_map of string
  | Signature_verification_failed
  | Cryptographic_failure of string
  | Evaluation_too_large of int

let max_trusted_keys = 256
let max_candidate_events = 4096
let max_total_event_bytes = 16 * 1024 * 1024
let algorithm = "ed25519"
let key_domain = "paengi:ref-key:v1\000"
let event_domain = "paengi:ref-event:v1\000"
let signature_domain = "paengi:ref-event-signature:v1\000"
let digest_size = Hash.digest_size
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_ref_name name ->
      Printf.sprintf "invalid ref-event ref name: %S" name
  | Invalid_generation generation ->
      Printf.sprintf "ref-event generation must be non-negative: %Ld" generation
  | Invalid_proposed_generation { observed; proposed } ->
      Printf.sprintf "ref-event proposed generation %Ld does not follow %Ld"
        proposed observed
  | Invalid_signer_sequence sequence ->
      Printf.sprintf "ref-event signer sequence must be non-negative: %Ld"
        sequence
  | Invalid_signer_key_id length ->
      Printf.sprintf "ref-event signer key ID must contain 32 bytes, got %d"
        length
  | Invalid_event_id length ->
      Printf.sprintf "ref-event ID must contain 32 bytes, got %d" length
  | Invalid_public_key length ->
      Printf.sprintf
        "ref-event Ed25519 public key must contain 32 bytes, got %d" length
  | Invalid_signature length ->
      Printf.sprintf "ref-event Ed25519 signature must contain 64 bytes, got %d"
        length
  | Unsupported_algorithm value ->
      Printf.sprintf "unsupported ref-event signature algorithm: %s" value
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported ref-event mandatory features: %Ld" features
  | Invalid_repository_format -> "ref-event repository format is empty"
  | Repository_format_mismatch -> "ref-event repository format does not match"
  | Invalid_identity detail -> "invalid ref-event identity: " ^ detail
  | Invalid_payload detail -> "invalid ref-event payload: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported ref-event schema version: %Ld" version
  | Trust_map_too_large count ->
      Printf.sprintf "ref-event trust map has %d keys; limit is %d" count
        max_trusted_keys
  | Invalid_trust_map detail -> "invalid ref-event trust map: " ^ detail
  | Signature_verification_failed -> "ref-event signature verification failed"
  | Cryptographic_failure detail -> "ref-event cryptographic failure: " ^ detail
  | Evaluation_too_large count ->
      Printf.sprintf "ref-event evaluation has %d candidates; limit is %d" count
        max_candidate_events

let evaluation_to_string = function
  | Ready -> "ready"
  | Replayed event_id -> "replayed:" ^ Event_id.to_hex event_id
  | Stale_observed_ref -> "stale-observed-ref"
  | Missing_predecessor event_id ->
      "missing-predecessor:" ^ Event_id.to_hex event_id
  | Signer_sequence_reused sequence ->
      Printf.sprintf "signer-sequence-reused:%Ld" sequence
  | Divergent event_ids ->
      "divergent:" ^ String.concat "," (List.map Event_id.to_hex event_ids)

let verification_to_string = function
  | Verified -> "verified"
  | Untrusted -> "untrusted"

let invalid_payload detail = Error (Invalid_payload detail)

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let repository_format_digest bytes =
  Hash.digest_string bytes |> Hash.to_raw_string

let signer_key_id_of_bytes bytes =
  if String.length bytes = digest_size then Ok bytes
  else Error (Invalid_signer_key_id (String.length bytes))

let signer_key_id_to_bytes key_id = key_id
let signer_key_id_compare = String.compare

let signer_key_id_of_public_key public_key =
  if String.length public_key <> 32 then
    Error (Invalid_public_key (String.length public_key))
  else signer_key_id_of_bytes (digest key_domain public_key)

let event_id_of_bytes bytes =
  if String.length bytes <> digest_size then
    Error (Invalid_event_id (String.length bytes))
  else
    Event_id.of_bytes bytes
    |> Result.map_error (fun error ->
        Invalid_identity (Paengi_id.parse_error_to_string error))

let event_id_to_bytes = Event_id.to_bytes

let valid_ref_name name =
  String.length name > 0
  && String.length name <= 256
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let make_ref_state ~generation ~target =
  if Int64.compare generation 0L < 0 then Error (Invalid_generation generation)
  else Ok { generation; target }

let ref_state_generation state = state.generation
let ref_state_target state = state.target

let ref_state_equal left right =
  Int64.equal left.generation right.generation
  && Option.equal Object_id.equal left.target right.target

let check_features features =
  if Int64.equal features 0L then Ok ()
  else Error (Unsupported_mandatory_features features)

let raw_object_id = function
  | None -> Encoding.null
  | Some object_id -> Encoding.bytes (Object_id.to_raw_bytes object_id)

let raw_event_id = function
  | None -> Encoding.null
  | Some event_id -> Encoding.bytes (event_id_to_bytes event_id)

let unsigned_without_id_value ~repository_format_digest ~ref_name ~signer_key_id
    ~signer_sequence ~previous ~observed ~proposed ~mandatory_features =
  let* ref_name = text ref_name in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes repository_format_digest;
      ref_name;
      Encoding.bytes (signer_key_id_to_bytes signer_key_id);
      Encoding.integer signer_sequence;
      raw_event_id previous;
      Encoding.integer observed.generation;
      raw_object_id observed.target;
      Encoding.integer proposed.generation;
      raw_object_id proposed.target;
      Encoding.integer mandatory_features;
    ]

let unsigned_payload unsigned =
  let* ref_name = text unsigned.ref_name in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes (event_id_to_bytes unsigned.event_id);
      Encoding.bytes unsigned.repository_format_digest;
      ref_name;
      Encoding.bytes (signer_key_id_to_bytes unsigned.signer_key_id);
      Encoding.integer unsigned.signer_sequence;
      raw_event_id unsigned.previous;
      Encoding.integer unsigned.observed.generation;
      raw_object_id unsigned.observed.target;
      Encoding.integer unsigned.proposed.generation;
      raw_object_id unsigned.proposed.target;
      Encoding.integer unsigned.mandatory_features;
    ]

let signing_bytes unsigned =
  unsigned_payload unsigned |> Result.map Encoding.encode
  |> Result.map (fun payload -> signature_domain ^ payload)

let make_unsigned ~repository_format ~ref_name ~signer_key_id ~signer_sequence
    ~previous ~observed ~proposed ~mandatory_features =
  if String.length repository_format = 0 then Error Invalid_repository_format
  else if not (valid_ref_name ref_name) then Error (Invalid_ref_name ref_name)
  else if Int64.compare signer_sequence 0L < 0 then
    Error (Invalid_signer_sequence signer_sequence)
  else
    let* () =
      signer_key_id_of_bytes signer_key_id |> Result.map (fun _ -> ())
    in
    let* () = check_features mandatory_features in
    let* () =
      if Int64.equal observed.generation Int64.max_int then
        Error
          (Invalid_proposed_generation
             { observed = observed.generation; proposed = proposed.generation })
      else if Int64.equal proposed.generation Int64.(add observed.generation 1L)
      then Ok ()
      else
        Error
          (Invalid_proposed_generation
             { observed = observed.generation; proposed = proposed.generation })
    in
    let repository_format_digest = repository_format_digest repository_format in
    let* without_id =
      unsigned_without_id_value ~repository_format_digest ~ref_name
        ~signer_key_id ~signer_sequence ~previous ~observed ~proposed
        ~mandatory_features
    in
    let* event_id =
      event_id_of_bytes (digest event_domain (Encoding.encode without_id))
    in
    Ok
      {
        event_id;
        repository_format_digest;
        ref_name;
        signer_key_id;
        signer_sequence;
        previous;
        observed;
        proposed;
        mandatory_features;
      }

let unsigned_event_id unsigned = unsigned.event_id
let unsigned_ref_name unsigned = unsigned.ref_name
let unsigned_signer_key_id unsigned = unsigned.signer_key_id
let unsigned_signer_sequence unsigned = unsigned.signer_sequence
let unsigned_previous unsigned = unsigned.previous
let unsigned_observed unsigned = unsigned.observed
let unsigned_proposed unsigned = unsigned.proposed

let validate_algorithm algorithm_value =
  if String.equal algorithm_value algorithm then Ok ()
  else Error (Unsupported_algorithm algorithm_value)

let make ~unsigned ~algorithm:algorithm_value ~signature =
  let* () = validate_algorithm algorithm_value in
  if String.length signature <> 64 then
    Error (Invalid_signature (String.length signature))
  else
    let* _ = unsigned_payload unsigned in
    Ok { unsigned; algorithm = algorithm_value; signature }

let event_unsigned event = event.unsigned
let event_algorithm event = event.algorithm
let event_signature event = event.signature

let event_payload event =
  let* unsigned = unsigned_payload event.unsigned in
  match unsigned with
  | Encoding.Array values ->
      let* algorithm_value = text event.algorithm in
      array (values @ [ algorithm_value; Encoding.bytes event.signature ])
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_payload "unsigned payload is not an array"

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ ->
      invalid_payload (Printf.sprintf "%s has the wrong field count" name)
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_payload (name ^ " must be an array")

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_payload (name ^ " must be an integer")

let nonnegative_integer name value =
  let* value = integer name value in
  if Int64.compare value 0L < 0 then
    invalid_payload (name ^ " must be non-negative")
  else Ok value

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_payload (name ^ " must be bytes")

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_payload (name ^ " must be text")

let optional_event_id = function
  | Encoding.Null -> Ok None
  | Encoding.Bytes value -> event_id_of_bytes value |> Result.map Option.some
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      invalid_payload "previous signer event ID must be bytes or null"

let optional_object_id = function
  | Encoding.Null -> Ok None
  | Encoding.Bytes value -> (
      match Object_id.of_raw_bytes value with
      | Some object_id -> Ok (Some object_id)
      | None -> invalid_payload "ref target must contain 32 bytes")
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      invalid_payload "ref target must be bytes or null"

let decode_event_payload value =
  let* values = fields "ref event" 14 value in
  match values with
  | [
   version;
   event_id;
   repository_format_digest;
   ref_name;
   signer_key_id;
   signer_sequence;
   previous;
   observed_generation;
   observed_target;
   proposed_generation;
   proposed_target;
   mandatory_features;
   algorithm_value;
   signature;
  ] ->
      let* version = nonnegative_integer "ref-event schema version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* event_id_bytes = bytes "ref-event ID" event_id in
        let* event_id = event_id_of_bytes event_id_bytes in
        let* repository_format_digest =
          bytes "repository format digest" repository_format_digest
        in
        let* () =
          if String.length repository_format_digest = digest_size then Ok ()
          else invalid_payload "repository format digest must contain 32 bytes"
        in
        let* ref_name = text_field "ref name" ref_name in
        let* signer_key_id_bytes = bytes "signer key ID" signer_key_id in
        let* signer_key_id = signer_key_id_of_bytes signer_key_id_bytes in
        let* signer_sequence =
          nonnegative_integer "signer sequence" signer_sequence
        in
        let* previous = optional_event_id previous in
        let* observed_generation =
          nonnegative_integer "observed generation" observed_generation
        in
        let* observed_target = optional_object_id observed_target in
        let* proposed_generation =
          nonnegative_integer "proposed generation" proposed_generation
        in
        let* proposed_target = optional_object_id proposed_target in
        let* mandatory_features =
          integer "mandatory features" mandatory_features
        in
        let* algorithm_value =
          text_field "signature algorithm" algorithm_value
        in
        let* signature = bytes "signature" signature in
        let* observed =
          make_ref_state ~generation:observed_generation ~target:observed_target
        in
        let* proposed =
          make_ref_state ~generation:proposed_generation ~target:proposed_target
        in
        let* unsigned =
          make_unsigned ~repository_format:"placeholder" ~ref_name
            ~signer_key_id ~signer_sequence ~previous ~observed ~proposed
            ~mandatory_features
        in
        let unsigned = { unsigned with repository_format_digest } in
        let* without_id =
          unsigned_without_id_value ~repository_format_digest ~ref_name
            ~signer_key_id ~signer_sequence ~previous ~observed ~proposed
            ~mandatory_features
        in
        let* expected_event_id =
          event_id_of_bytes (digest event_domain (Encoding.encode without_id))
        in
        if not (Event_id.equal event_id expected_event_id) then
          Error (Invalid_identity "event ID does not match unsigned payload")
        else
          let unsigned = { unsigned with event_id } in
          let* event = make ~unsigned ~algorithm:algorithm_value ~signature in
          let* canonical = event_payload event in
          if Encoding.equal canonical value then Ok event
          else invalid_payload "ref-event payload is noncanonical"
  | _ -> invalid_payload "ref event has the wrong field count"

let trust_map trusted_keys =
  if List.length trusted_keys > max_trusted_keys then
    Error (Trust_map_too_large (List.length trusted_keys))
  else
    let rec loop previous values = function
      | [] -> Ok (List.rev values)
      | ({ key_id; public_key } as key) :: rest -> (
          let* expected = signer_key_id_of_public_key public_key in
          if not (String.equal expected key_id) then
            Error (Invalid_trust_map "key ID does not match public key")
          else
            match previous with
            | Some previous when signer_key_id_compare previous key_id >= 0 ->
                Error (Invalid_trust_map "keys are not strictly ascending")
            | None | Some _ -> loop (Some key_id) (key :: values) rest)
    in
    loop None [] trusted_keys

let crypto_error error = Format.asprintf "%a" Mirage_crypto_ec.pp_error error

let verify ~repository_format ~trusted_keys event =
  if String.length repository_format = 0 then Error Invalid_repository_format
  else
    let* trusted_keys = trust_map trusted_keys in
    if
      not
        (String.equal event.unsigned.repository_format_digest
           (repository_format_digest repository_format))
    then Error Repository_format_mismatch
    else
      match
        List.find_opt
          (fun key -> String.equal key.key_id event.unsigned.signer_key_id)
          trusted_keys
      with
      | None -> Ok Untrusted
      | Some key -> (
          match Mirage_crypto_ec.Ed25519.pub_of_octets key.public_key with
          | Error error -> Error (Cryptographic_failure (crypto_error error))
          | Ok public_key -> (
              let* signed = signing_bytes event.unsigned in
              try
                if
                  Mirage_crypto_ec.Ed25519.verify ~key:public_key
                    event.signature ~msg:signed
                then Ok Verified
                else Error Signature_verification_failed
              with Mirage_crypto_ec.Message_too_long ->
                Error (Cryptographic_failure "signed preimage is too long")))

let same_event left right =
  Event_id.equal
    (unsigned_event_id left.unsigned)
    (unsigned_event_id right.unsigned)

let same_signer left right =
  String.equal left.unsigned.signer_key_id right.unsigned.signer_key_id

let event_size event =
  event_payload event
  |> Result.map (fun value -> String.length (Encoding.encode value))

let evaluate_verified ~current ~known event =
  if List.length known >= max_candidate_events then
    Error (Evaluation_too_large (List.length known + 1))
  else
    let rec total_bytes total = function
      | [] -> Ok total
      | event :: rest ->
          let* size = event_size event in
          let total = total + size in
          if total > max_total_event_bytes then
            Error (Evaluation_too_large (List.length known))
          else total_bytes total rest
    in
    let* _ = total_bytes 0 (event :: known) in
    match
      List.find_opt (fun known_event -> same_event known_event event) known
    with
    | Some known_event -> Ok (Replayed (unsigned_event_id known_event.unsigned))
    | None -> (
        if not (ref_state_equal current event.unsigned.observed) then
          Ok Stale_observed_ref
        else
          let signer_events =
            List.filter (fun known_event -> same_signer known_event event) known
          in
          if
            List.exists
              (fun known_event ->
                Int64.equal known_event.unsigned.signer_sequence
                  event.unsigned.signer_sequence)
              signer_events
          then Ok (Signer_sequence_reused event.unsigned.signer_sequence)
          else if
            List.exists
              (fun known_event ->
                Int64.compare event.unsigned.signer_sequence
                  known_event.unsigned.signer_sequence
                <= 0)
              signer_events
          then Ok (Signer_sequence_reused event.unsigned.signer_sequence)
          else
            let ordering =
              match (event.unsigned.previous, signer_events) with
              | None, [] -> `Ready
              | None, _ -> `Missing (unsigned_event_id event.unsigned)
              | Some previous, _ -> (
                  match
                    List.find_opt
                      (fun known_event ->
                        Event_id.equal
                          (unsigned_event_id known_event.unsigned)
                          previous)
                      signer_events
                  with
                  | None -> `Missing previous
                  | Some predecessor ->
                      if
                        Int64.compare event.unsigned.signer_sequence
                          predecessor.unsigned.signer_sequence
                        > 0
                      then `Ready
                      else `Reused)
            in
            match ordering with
            | `Missing previous -> Ok (Missing_predecessor previous)
            | `Reused ->
                Ok (Signer_sequence_reused event.unsigned.signer_sequence)
            | `Ready ->
                let divergent =
                  List.filter_map
                    (fun known_event ->
                      if
                        String.equal known_event.unsigned.ref_name
                          event.unsigned.ref_name
                        && ref_state_equal known_event.unsigned.observed
                             event.unsigned.observed
                        && not
                             (ref_state_equal known_event.unsigned.proposed
                                event.unsigned.proposed)
                      then Some (unsigned_event_id known_event.unsigned)
                      else None)
                    known
                in
                if divergent = [] then Ok Ready else Ok (Divergent divergent))
