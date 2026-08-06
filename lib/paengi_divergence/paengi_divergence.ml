module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Event = Paengi_ref_event
module Hash = Paengi_hash.Sha256
module Object_id = Paengi_store.Stored_object_id

type link = { event_id : Event.Event_id.t; object_id : Object_id.t }
type entry = { link : link; verified : Event.verified }

type t = {
  repository_digest : string;
  ref_name : string;
  observed : Event.ref_state;
  entries : link list;
}

type error =
  | Invalid_repository_format
  | Invalid_ref_name of string
  | Invalid_repository_digest of int
  | Invalid_entry_count of int
  | Duplicate_event_id of Event.Event_id.t
  | Event_context_mismatch of string
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_mandatory_features of int64
  | Set_too_large of int
  | Incompatible_sets
  | Event_error of Event.error
  | Envelope_error of Envelope.creation_error

let max_entries = 4096
let max_encoded_bytes = 16 * 1024 * 1024
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_repository_format -> "divergence repository format is empty"
  | Invalid_ref_name name ->
      Printf.sprintf "invalid divergence ref name: %S" name
  | Invalid_repository_digest length ->
      Printf.sprintf
        "divergence repository digest must contain 32 bytes, got %d" length
  | Invalid_entry_count count ->
      Printf.sprintf "divergence set has %d entries; expected 2..%d" count
        max_entries
  | Duplicate_event_id event_id ->
      "duplicate divergence event ID: " ^ Event.Event_id.to_hex event_id
  | Event_context_mismatch detail ->
      "divergence event context mismatch: " ^ detail
  | Invalid_payload detail -> "invalid divergence payload: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported divergence schema version: %Ld" version
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported divergence mandatory features: %Ld" features
  | Set_too_large size ->
      Printf.sprintf "divergence set encoding is %d bytes; limit is %d" size
        max_encoded_bytes
  | Incompatible_sets -> "divergence sets have different contexts"
  | Event_error error -> Event.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error

let valid_ref_name name =
  let length = String.length name in
  length > 0 && length <= 255
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
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

let nonnegative_integer name value =
  let* value = integer name value in
  if Int64.compare value 0L < 0 then
    Error (Invalid_payload (name ^ " must be non-negative"))
  else Ok value

let object_id name = function
  | Encoding.Null -> Ok None
  | Encoding.Bytes bytes -> (
      match Object_id.of_raw_bytes bytes with
      | Some object_id -> Ok (Some object_id)
      | None ->
          Error (Invalid_payload (name ^ " must contain a 32-byte object ID")))
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      Error (Invalid_payload (name ^ " must be object ID bytes or null"))

let object_id_value = function
  | None -> Encoding.null
  | Some object_id -> Encoding.bytes (Object_id.to_raw_bytes object_id)

let repository_digest repository_format =
  Hash.digest_string repository_format |> Hash.to_raw_string

let entry_of_verified ~object_id verified =
  let event = Event.verified_event verified in
  {
    link =
      {
        event_id = Event.unsigned_event_id (Event.event_unsigned event);
        object_id;
      };
    verified;
  }

let entry_event_id entry = entry.link.event_id
let entry_object_id entry = entry.link.object_id
let entry_verified_event entry = entry.verified
let link_event_id link = link.event_id
let link_object_id link = link.object_id
let ref_name set = set.ref_name
let observed set = set.observed
let entries set = set.entries

let compare_link left right =
  Event.Event_id.compare left.event_id right.event_id

let check_count entries =
  let count = List.length entries in
  if count < 2 || count > max_entries then Error (Invalid_entry_count count)
  else Ok ()

let check_strictly_ascending entries =
  let rec loop previous = function
    | [] -> Ok ()
    | entry :: rest -> (
        match previous with
        | None -> loop (Some entry.event_id) rest
        | Some previous ->
            let comparison = Event.Event_id.compare previous entry.event_id in
            if comparison < 0 then loop (Some entry.event_id) rest
            else Error (Duplicate_event_id entry.event_id))
  in
  loop None entries

let links_of_entries entries =
  entries |> List.map (fun entry -> entry.link) |> List.sort compare_link

let check_entry_context ~repository_digest ~ref_name ~observed entry =
  let event = Event.verified_event entry.verified in
  let unsigned = Event.event_unsigned event in
  let event_id = Event.unsigned_event_id unsigned in
  if not (Event.Event_id.equal entry.link.event_id event_id) then
    Error
      (Event_context_mismatch "entry event ID does not match verified event")
  else if
    not
      (String.equal
         (Event.unsigned_repository_format_digest unsigned)
         repository_digest)
  then Error (Event_context_mismatch "repository format digest")
  else if not (String.equal (Event.unsigned_ref_name unsigned) ref_name) then
    Error (Event_context_mismatch "ref name")
  else if
    not (Event.ref_state_equal (Event.unsigned_observed unsigned) observed)
  then Error (Event_context_mismatch "observed state")
  else Ok ()

let check_size set =
  let* payload =
    let entries =
      set.entries
      |> List.map (fun entry ->
          array
            [
              Encoding.bytes (Event.event_id_to_bytes entry.event_id);
              Encoding.bytes (Object_id.to_raw_bytes entry.object_id);
            ])
    in
    let rec collect values = function
      | [] -> Ok (List.rev values)
      | value :: rest ->
          let* value = value in
          collect (value :: values) rest
    in
    let* entries = collect [] entries in
    let* ref_name = text set.ref_name in
    let* entries = array entries in
    array
      [
        Encoding.integer 1L;
        Encoding.bytes set.repository_digest;
        ref_name;
        Encoding.integer (Event.ref_state_generation set.observed);
        object_id_value (Event.ref_state_target set.observed);
        entries;
        Encoding.integer 0L;
      ]
  in
  let size = String.length (Encoding.encode payload) in
  if size > max_encoded_bytes then Error (Set_too_large size) else Ok ()

let make ~repository_format entries =
  if String.length repository_format = 0 then Error Invalid_repository_format
  else
    match entries with
    | [] | [ _ ] -> Error (Invalid_entry_count (List.length entries))
    | first :: _ ->
        let event = Event.verified_event first.verified in
        let unsigned = Event.event_unsigned event in
        let repository_digest = repository_digest repository_format in
        let ref_name = Event.unsigned_ref_name unsigned in
        let observed = Event.unsigned_observed unsigned in
        if not (valid_ref_name ref_name) then Error (Invalid_ref_name ref_name)
        else
          let* () = check_count entries in
          let* () =
            List.fold_left
              (fun result entry ->
                let* () = result in
                check_entry_context ~repository_digest ~ref_name ~observed entry)
              (Ok ()) entries
          in
          let set =
            {
              repository_digest;
              ref_name;
              observed;
              entries = links_of_entries entries;
            }
          in
          let* () = check_strictly_ascending set.entries in
          let* () = check_size set in
          Ok set

let payload set =
  let* () = check_count set.entries in
  let* () = check_strictly_ascending set.entries in
  if String.length set.repository_digest <> Hash.digest_size then
    Error (Invalid_repository_digest (String.length set.repository_digest))
  else if not (valid_ref_name set.ref_name) then
    Error (Invalid_ref_name set.ref_name)
  else
    let* entry_values =
      let rec loop values = function
        | [] -> Ok (List.rev values)
        | entry :: rest ->
            let* value =
              array
                [
                  Encoding.bytes (Event.event_id_to_bytes entry.event_id);
                  Encoding.bytes (Object_id.to_raw_bytes entry.object_id);
                ]
            in
            loop (value :: values) rest
      in
      loop [] set.entries
    in
    let* ref_name = text set.ref_name in
    let* entry_values = array entry_values in
    let* value =
      array
        [
          Encoding.integer 1L;
          Encoding.bytes set.repository_digest;
          ref_name;
          Encoding.integer (Event.ref_state_generation set.observed);
          object_id_value (Event.ref_state_target set.observed);
          entry_values;
          Encoding.integer 0L;
        ]
    in
    let size = String.length (Encoding.encode value) in
    if size > max_encoded_bytes then Error (Set_too_large size) else Ok value

let decode_link value =
  let* values = fields "divergence entry" 2 value in
  match values with
  | [ event_id; object_id_value ] -> (
      let* event_id = bytes "divergence event ID" event_id in
      let* event_id =
        Event.event_id_of_bytes event_id
        |> Result.map_error (fun error -> Event_error error)
      in
      let* object_id = bytes "divergence event object ID" object_id_value in
      match Object_id.of_raw_bytes object_id with
      | Some object_id -> Ok { event_id; object_id }
      | None ->
          Error
            (Invalid_payload "divergence event object ID must contain 32 bytes")
      )
  | _ -> assert false

let decode_payload value =
  let* values = fields "divergence set" 7 value in
  match values with
  | [
   version;
   repository_digest;
   ref_name;
   generation;
   target;
   raw_entries;
   features;
  ] ->
      let* version = integer "divergence schema version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* features = integer "divergence mandatory features" features in
        if not (Int64.equal features 0L) then
          Error (Unsupported_mandatory_features features)
        else
          let* repository_digest =
            bytes "divergence repository digest" repository_digest
          in
          if String.length repository_digest <> Hash.digest_size then
            Error (Invalid_repository_digest (String.length repository_digest))
          else
            let* ref_name = text_field "divergence ref name" ref_name in
            if not (valid_ref_name ref_name) then
              Error (Invalid_ref_name ref_name)
            else
              let* generation =
                nonnegative_integer "divergence observed generation" generation
              in
              let* target = object_id "divergence observed target" target in
              let* observed =
                Event.make_ref_state ~generation ~target
                |> Result.map_error (fun error -> Event_error error)
              in
              let* raw_entries =
                match raw_entries with
                | Encoding.Array entries -> Ok entries
                | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
                | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
                    Error
                      (Invalid_payload "divergence entries must be an array")
              in
              let rec decode_entries values = function
                | [] -> Ok (List.rev values)
                | value :: rest ->
                    let* entry = decode_link value in
                    decode_entries (entry :: values) rest
              in
              let* entries = decode_entries [] raw_entries in
              let set = { repository_digest; ref_name; observed; entries } in
              let* () = check_count entries in
              let* () = check_strictly_ascending entries in
              let* canonical = payload set in
              if
                String.equal (Encoding.encode canonical) (Encoding.encode value)
              then Ok set
              else
                Error (Invalid_payload "divergence set payload is noncanonical")
  | _ -> assert false

let envelope set =
  let* payload = payload set in
  Envelope.create ~object_type:Envelope.Divergent_ref_set
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let union left right =
  if
    (not (String.equal left.repository_digest right.repository_digest))
    || (not (String.equal left.ref_name right.ref_name))
    || not (Event.ref_state_equal left.observed right.observed)
  then Error Incompatible_sets
  else
    let rec merge values left right =
      match (left, right) with
      | [], rest | rest, [] -> Ok (List.rev_append values rest)
      | left_entry :: left_rest, right_entry :: right_rest ->
          let comparison = compare_link left_entry right_entry in
          if comparison = 0 then
            if Object_id.equal left_entry.object_id right_entry.object_id then
              merge (left_entry :: values) left_rest right_rest
            else Error (Duplicate_event_id left_entry.event_id)
          else if comparison < 0 then
            merge (left_entry :: values) left_rest right
          else merge (right_entry :: values) left right_rest
    in
    let* entries = merge [] left.entries right.entries in
    let set = { left with entries } in
    let* () = check_count entries in
    let* () = check_strictly_ascending entries in
    let* () = check_size set in
    Ok set
