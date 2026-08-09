module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Repository_id = Yeokcham_v2_model.Repository_id
module Opaque_object_ref = Yeokcham_v2_model.Opaque_object_ref
module Event_id = Yeokcham_v2_model.Ref_event_id
module Signer_key_id = Yeokcham_v2_model.Signer_key_id

module Ref_name = struct
  type t = string

  let max_bytes = 255

  let of_string value =
    let length = String.length value in
    if length = 0 then Error "ref name must not be empty"
    else if length > max_bytes then
      Error
        (Printf.sprintf "ref name is %d bytes; limit is %d" length max_bytes)
    else if
      String.exists
        (function '\000' | '/' | '\\' | '\r' | '\n' -> true | _ -> false)
        value
    then Error "ref name contains a reserved character"
    else
      Encoding.text value
      |> Result.map (fun _ -> value)
      |> Result.map_error (fun error ->
          "ref name is not valid UTF-8: "
          ^ Encoding.construction_error_to_string error)

  let to_string value = value
  let compare = String.compare
  let equal = String.equal
end

module Ref_target = struct
  type t = Opaque_object_ref.t

  let of_opaque_object_ref value = value
  let to_opaque_object_ref value = value
end

type unsigned = {
  repository_id : Repository_id.t;
  ref_name : Ref_name.t;
  signer_key_id : Signer_key_id.t;
  predecessor : Event_id.t option;
  target : Ref_target.t option;
  mandatory_features : int64;
}

type t = { unsigned : unsigned; signature : string }
type verified = Verified of t
type public_key_registry = (Signer_key_id.t * string) list

type verification =
  | Cryptographically_valid of verified
  | Unknown_signer of Signer_key_id.t

type divergence = { parent : Event_id.t option; children : Event_id.t list }
type head_set = { heads : verified list; divergences : divergence list }

type error =
  | Invalid_public_key_length of int
  | Invalid_signature_length of int
  | Invalid_ref_name of string
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Invalid_payload of string
  | Invalid_event_id
  | Noncanonical_event
  | Too_many_public_keys of int
  | Duplicate_public_key of Signer_key_id.t
  | Noncanonical_public_key_order of {
      previous : Signer_key_id.t;
      current : Signer_key_id.t;
    }
  | Cryptographic_failure of string
  | Signature_verification_failed
  | Duplicate_event of Event_id.t
  | Missing_predecessor of { event : Event_id.t; predecessor : Event_id.t }
  | Cross_scope_predecessor of { event : Event_id.t; predecessor : Event_id.t }
  | Causal_cycle of Event_id.t

let algorithm = "ed25519"
let current_schema_version = 1L
let supported_mandatory_features = 0L
let public_key_size = 32
let signature_size = 64
let max_public_keys = 256
let max_candidate_events = 4096
let event_domain = "yeokcham:v2:ref-ledger-event:1\000"
let signature_domain = "yeokcham:v2:ref-ledger-signature:1\000"
let signer_key_domain = "yeokcham:v2:ledger-signer-key:1\000"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_public_key_length length ->
      Printf.sprintf "ledger Ed25519 public key must contain 32 bytes, got %d"
        length
  | Invalid_signature_length length ->
      Printf.sprintf "ledger Ed25519 signature must contain 64 bytes, got %d"
        length
  | Invalid_ref_name detail -> "invalid ledger ref name: " ^ detail
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid ledger mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported ledger mandatory feature bits: %Ld" features
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported ref-ledger schema version: %Ld" version
  | Unsupported_algorithm value ->
      Printf.sprintf "unsupported ref-ledger signature algorithm: %s" value
  | Invalid_payload detail -> "invalid ref-ledger record: " ^ detail
  | Invalid_event_id -> "ref-ledger event ID does not match its unsigned record"
  | Noncanonical_event -> "ref-ledger record is noncanonical"
  | Too_many_public_keys count ->
      Printf.sprintf "ledger public-key registry has %d entries; limit is %d"
        count max_public_keys
  | Duplicate_public_key key ->
      Printf.sprintf "duplicate ledger public-key ID: %s"
        (Signer_key_id.to_hex key)
  | Noncanonical_public_key_order { previous; current } ->
      Printf.sprintf "ledger public-key IDs are not canonical: %s >= %s"
        (Signer_key_id.to_hex previous)
        (Signer_key_id.to_hex current)
  | Cryptographic_failure detail ->
      "ledger cryptographic verification failed: " ^ detail
  | Signature_verification_failed -> "ref-ledger Ed25519 signature is invalid"
  | Duplicate_event event ->
      Printf.sprintf "duplicate ref-ledger event: %s" (Event_id.to_hex event)
  | Missing_predecessor { event; predecessor } ->
      Printf.sprintf "ref-ledger event %s has missing predecessor %s"
        (Event_id.to_hex event)
        (Event_id.to_hex predecessor)
  | Cross_scope_predecessor { event; predecessor } ->
      Printf.sprintf "ref-ledger event %s crosses repository or ref at %s"
        (Event_id.to_hex event)
        (Event_id.to_hex predecessor)
  | Causal_cycle event ->
      Printf.sprintf "ref-ledger causal cycle includes %s"
        (Event_id.to_hex event)

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let signer_key_id_of_public_key public_key =
  if String.length public_key <> public_key_size then
    Error (Invalid_public_key_length (String.length public_key))
  else
    let digest =
      Hash.feed_string Hash.empty signer_key_domain |> fun context ->
      Hash.feed_string context public_key |> Hash.get |> Hash.to_raw_string
    in
    match Signer_key_id.of_bytes digest with
    | Ok key -> Ok key
    | Error _ -> assert false

let make_public_key_registry entries =
  if List.length entries > max_public_keys then
    Error (Too_many_public_keys (List.length entries))
  else
    let rec validate = function
      | [] | [ _ ] -> Ok entries
      | (previous, _) :: ((current, _) :: _ as rest) ->
          let comparison = Signer_key_id.compare previous current in
          if comparison = 0 then Error (Duplicate_public_key current)
          else if comparison > 0 then
            Error (Noncanonical_public_key_order { previous; current })
          else validate rest
    in
    let* registry = validate entries in
    let rec verify_keys = function
      | [] -> Ok registry
      | (key_id, public_key) :: rest ->
          let* actual = signer_key_id_of_public_key public_key in
          if Signer_key_id.equal key_id actual then verify_keys rest
          else
            Error
              (Invalid_payload
                 "ledger public-key registry key ID does not match public key")
    in
    verify_keys registry

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let unsigned_value unsigned =
  let* ref_name = text (Ref_name.to_string unsigned.ref_name) in
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Repository_id.to_bytes unsigned.repository_id);
      ref_name;
      Encoding.bytes (Signer_key_id.to_bytes unsigned.signer_key_id);
      (match unsigned.predecessor with
      | None -> Encoding.null
      | Some predecessor -> Encoding.bytes (Event_id.to_bytes predecessor));
      (match unsigned.target with
      | None -> Encoding.null
      | Some target ->
          Encoding.bytes
            (Opaque_object_ref.to_bytes
               (Ref_target.to_opaque_object_ref target)));
      Encoding.integer unsigned.mandatory_features;
    ]

let unsigned_bytes unsigned =
  match unsigned_value unsigned with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let unsigned_event_id unsigned =
  let digest =
    Hash.feed_string Hash.empty event_domain |> fun context ->
    Hash.feed_string context (unsigned_bytes unsigned)
    |> Hash.get |> Hash.to_raw_string
  in
  match Event_id.of_bytes digest with
  | Ok event -> event
  | Error _ -> assert false

let signing_bytes unsigned =
  signature_domain ^ Event_id.to_bytes (unsigned_event_id unsigned)

let make_unsigned ~repository_id ~ref_name ~signer_key_id ~predecessor ~target
    ~mandatory_features =
  let* () = check_mandatory_features mandatory_features in
  Ok
    {
      repository_id;
      ref_name;
      signer_key_id;
      predecessor;
      target;
      mandatory_features;
    }

let unsigned_repository_id unsigned = unsigned.repository_id
let unsigned_ref_name unsigned = unsigned.ref_name
let unsigned_signer_key_id unsigned = unsigned.signer_key_id
let unsigned_predecessor unsigned = unsigned.predecessor
let unsigned_target unsigned = unsigned.target

let make ~unsigned ~algorithm:algorithm_value ~signature =
  if not (String.equal algorithm_value algorithm) then
    Error (Unsupported_algorithm algorithm_value)
  else if String.length signature <> signature_size then
    Error (Invalid_signature_length (String.length signature))
  else Ok { unsigned; signature }

let event_id event = unsigned_event_id event.unsigned
let event_unsigned event = event.unsigned
let event_signature event = event.signature

let event_value event =
  let* unsigned = unsigned_value event.unsigned in
  let* algorithm = text algorithm in
  match unsigned with
  | Encoding.Array fields ->
      array
        (fields
        @ [
            Encoding.bytes (Event_id.to_bytes (event_id event));
            algorithm;
            Encoding.bytes event.signature;
          ])
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      assert false

let encode event =
  match event_value event with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let fields name count = function
  | Encoding.Array values when List.length values = count -> Ok values
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

let option_bytes name constructor = function
  | Encoding.Null -> Ok None
  | Encoding.Bytes value ->
      constructor value |> Result.map Option.some
      |> Result.map_error (fun _ ->
          Invalid_payload (name ^ " has invalid length"))
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      Error (Invalid_payload (name ^ " must be bytes or null"))

let decode encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "ref-ledger event" 10 value in
  match values with
  | [
   version;
   repository_id;
   ref_name;
   signer_key_id;
   predecessor;
   target;
   mandatory_features;
   stored_event_id;
   algorithm_value;
   signature;
  ] ->
      let* version = integer "ref-ledger schema version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* repository_id = bytes "ref-ledger repository ID" repository_id in
        let* repository_id =
          Repository_id.of_bytes repository_id
          |> Result.map_error (fun _ ->
              Invalid_payload "ref-ledger repository ID has invalid length")
        in
        let* ref_name = text_field "ref-ledger ref name" ref_name in
        let* ref_name =
          Ref_name.of_string ref_name
          |> Result.map_error (fun error -> Invalid_ref_name error)
        in
        let* signer_key_id = bytes "ref-ledger signer key ID" signer_key_id in
        let* signer_key_id =
          Signer_key_id.of_bytes signer_key_id
          |> Result.map_error (fun _ ->
              Invalid_payload "ref-ledger signer key ID has invalid length")
        in
        let* predecessor =
          option_bytes "ref-ledger predecessor" Event_id.of_bytes predecessor
        in
        let* target =
          option_bytes "ref-ledger target" Opaque_object_ref.of_bytes target
          |> Result.map (Option.map Ref_target.of_opaque_object_ref)
        in
        let* mandatory_features =
          integer "ref-ledger mandatory features" mandatory_features
        in
        let* unsigned =
          make_unsigned ~repository_id ~ref_name ~signer_key_id ~predecessor
            ~target ~mandatory_features
        in
        let* stored_event_id = bytes "ref-ledger event ID" stored_event_id in
        let* stored_event_id =
          Event_id.of_bytes stored_event_id
          |> Result.map_error (fun _ ->
              Invalid_payload "ref-ledger event ID has invalid length")
        in
        let* algorithm_value =
          text_field "ref-ledger signature algorithm" algorithm_value
        in
        let* signature = bytes "ref-ledger signature" signature in
        let* event = make ~unsigned ~algorithm:algorithm_value ~signature in
        if not (Event_id.equal stored_event_id (event_id event)) then
          Error Invalid_event_id
        else if String.equal encoded (encode event) then Ok event
        else Error Noncanonical_event
  | _ -> assert false

let find_key registry key_id =
  List.find_map
    (fun (candidate, public_key) ->
      if Signer_key_id.equal candidate key_id then Some public_key else None)
    registry

let verify ~public_keys event =
  let expected = unsigned_event_id event.unsigned in
  let actual = event_id event in
  if not (Event_id.equal expected actual) then Error Invalid_event_id
  else
    match find_key public_keys event.unsigned.signer_key_id with
    | None -> Ok (Unknown_signer event.unsigned.signer_key_id)
    | Some public_key -> (
        match Mirage_crypto_ec.Ed25519.pub_of_octets public_key with
        | Error error ->
            Error
              (Cryptographic_failure
                 (Format.asprintf "%a" Mirage_crypto_ec.pp_error error))
        | Ok public_key -> (
            try
              if
                Mirage_crypto_ec.Ed25519.verify ~key:public_key event.signature
                  ~msg:(signing_bytes event.unsigned)
              then Ok (Cryptographically_valid (Verified event))
              else Error Signature_verification_failed
            with Mirage_crypto_ec.Message_too_long ->
              Error (Cryptographic_failure "ledger signing message is too long")
            ))

let verified_event (Verified event) = event
let compare_event left right = Event_id.compare (event_id left) (event_id right)

let compare_predecessor left right =
  match (left, right) with
  | None, None -> 0
  | None, Some _ -> -1
  | Some _, None -> 1
  | Some left, Some right -> Event_id.compare left right

let scope_matches ~repository_id ~ref_name event =
  Repository_id.equal repository_id event.unsigned.repository_id
  && Ref_name.equal ref_name event.unsigned.ref_name

let evaluate ~repository_id ~ref_name verified_events =
  if List.length verified_events > max_candidate_events then
    Error (Invalid_payload "too many verified ledger events")
  else
    let all_events = List.map verified_event verified_events in
    let sorted = List.sort compare_event all_events in
    let rec reject_duplicates = function
      | [] | [ _ ] -> Ok ()
      | left :: (right :: _ as rest) ->
          if Event_id.equal (event_id left) (event_id right) then
            Error (Duplicate_event (event_id right))
          else reject_duplicates rest
    in
    let* () = reject_duplicates sorted in
    let scoped = List.filter (scope_matches ~repository_id ~ref_name) sorted in
    let find_event identity =
      List.find_opt
        (fun event -> Event_id.equal (event_id event) identity)
        sorted
    in
    let rec validate_predecessors = function
      | [] -> Ok ()
      | event :: rest -> (
          match event.unsigned.predecessor with
          | None -> validate_predecessors rest
          | Some predecessor -> (
              match find_event predecessor with
              | None ->
                  Error
                    (Missing_predecessor { event = event_id event; predecessor })
              | Some predecessor_event ->
                  if scope_matches ~repository_id ~ref_name predecessor_event
                  then validate_predecessors rest
                  else
                    Error
                      (Cross_scope_predecessor
                         { event = event_id event; predecessor })))
    in
    let* () = validate_predecessors scoped in
    let rec reaches_cycle visiting visited event =
      let identity = event_id event in
      if List.exists (Event_id.equal identity) visiting then
        Error (Causal_cycle identity)
      else if List.exists (Event_id.equal identity) visited then Ok visited
      else
        match event.unsigned.predecessor with
        | None -> Ok (identity :: visited)
        | Some predecessor -> (
            match find_event predecessor with
            | None -> assert false
            | Some previous ->
                reaches_cycle (identity :: visiting) visited previous)
    in
    let rec validate_cycles visited = function
      | [] -> Ok ()
      | event :: rest ->
          let* visited = reaches_cycle [] visited event in
          validate_cycles visited rest
    in
    let* () = validate_cycles [] scoped in
    let children predecessor =
      scoped
      |> List.filter (fun event ->
          match (predecessor, event.unsigned.predecessor) with
          | None, None -> true
          | Some left, Some right -> Event_id.equal left right
          | None, Some _ | Some _, None -> false)
      |> List.map event_id |> List.sort Event_id.compare
    in
    let parents =
      None
      :: (scoped
         |> List.filter_map (fun event -> event.unsigned.predecessor)
         |> List.map Option.some)
    in
    let rec unique_parents result = function
      | [] -> List.rev result
      | current :: rest -> (
          match result with
          | previous :: _ when compare_predecessor previous current = 0 ->
              unique_parents result rest
          | _ -> unique_parents (current :: result) rest)
    in
    let parents = List.sort compare_predecessor parents |> unique_parents [] in
    let divergences =
      List.filter_map
        (fun predecessor ->
          let children = children predecessor in
          if List.length children > 1 then
            Some { parent = predecessor; children }
          else None)
        parents
    in
    let referenced identity =
      List.exists
        (fun event ->
          match event.unsigned.predecessor with
          | None -> false
          | Some predecessor -> Event_id.equal predecessor identity)
        scoped
    in
    let heads =
      scoped
      |> List.filter (fun event -> not (referenced (event_id event)))
      |> List.map (fun event -> Verified event)
    in
    Ok { heads; divergences }

let heads result = result.heads
let divergences result = result.divergences
let divergence_predecessor divergence = divergence.parent
let divergence_children divergence = divergence.children
