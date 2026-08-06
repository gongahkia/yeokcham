module Divergence = Yeokcham_divergence
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Event = Yeokcham_ref_event
module Event_store = Yeokcham_ref_event_store
module Hash = Yeokcham_hash.Sha256
module Object_id = Yeokcham_store.Stored_object_id
module Store = Yeokcham_store

type error =
  | Store_error of Store.error
  | Divergence_error of Divergence.error
  | Event_error of Event.error
  | Ref_event_store_error of Event_store.error
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }
  | Binding_error of string
  | Event_id_mismatch of Event.Event_id.t
  | Untrusted_event of Event.Event_id.t
  | Cas_retry_exhausted of int

let max_cas_retries = 16
let binding_domain = "yeokcham:sync-divergence-binding:v1\000"
let ( let* ) = Result.bind

let is_cas_race = function
  | Store_error (Store.Concurrent_ref_file_update _) -> true
  | _ -> false
[@@warning "-4"]

let is_lock_held = function
  | Store_error (Store.Ref_lock_held _) -> true
  | _ -> false
[@@warning "-4"]

let lowercase_hex bytes =
  let encoded = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index byte ->
      Bytes.set encoded (index * 2) "0123456789abcdef".[Char.code byte lsr 4];
      Bytes.set encoded
        ((index * 2) + 1)
        "0123456789abcdef".[Char.code byte land 15])
    bytes;
  Bytes.unsafe_to_string encoded

let lock_name ref_name =
  "sync-divergence-"
  ^ (Hash.digest_string ("yeokcham:sync-divergence-lock:v1\000" ^ ref_name)
    |> Hash.to_raw_string |> lowercase_hex)

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Divergence_error error -> Divergence.error_to_string error
  | Event_error error -> Event.error_to_string error
  | Ref_event_store_error error -> Event_store.error_to_string error
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "unexpected object type: expected %d, got %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)
  | Binding_error detail -> "invalid sync-divergence binding: " ^ detail
  | Event_id_mismatch event_id ->
      "sync-divergence event ID mismatch: " ^ Event.Event_id.to_hex event_id
  | Untrusted_event event_id ->
      "sync-divergence event is not in the explicit trust map: "
      ^ Event.Event_id.to_hex event_id
  | Cas_retry_exhausted attempts ->
      Printf.sprintf "sync-divergence CAS retries exhausted after %d attempts"
        attempts

let binding_components ~ref_name = [ "sync-divergence"; ref_name ]

let binding_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Binding_error (Encoding.construction_error_to_string error))

let binding_fields expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ -> Error (Binding_error "wrong field count")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Binding_error "must be an array")

let binding_integer = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Binding_error "version must be an integer")

let binding_bytes label = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Binding_error (label ^ " must be bytes"))

let binding_body object_id =
  binding_array
    [ Encoding.integer 1L; Encoding.bytes (Object_id.to_raw_bytes object_id) ]

let binding_checksum body =
  Hash.feed_string Hash.empty binding_domain |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_binding object_id =
  match binding_body object_id with
  | Error error -> invalid_arg (error_to_string error)
  | Ok body -> (
      match body with
      | Encoding.Array [ version; object_id ] ->
          binding_array
            [ version; object_id; Encoding.bytes (binding_checksum body) ]
          |> Result.map Encoding.encode
          |> Result.fold ~ok:Fun.id ~error:(fun error ->
              invalid_arg (error_to_string error))
      | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
          assert false)

let decode_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Binding_error (Encoding.decode_error_to_string error))
  in
  let* values = binding_fields 3 value in
  match values with
  | [ version; raw_object_id; supplied_checksum ] ->
      let* version = binding_integer version in
      if not (Int64.equal version 1L) then
        Error
          (Binding_error (Printf.sprintf "unsupported version: %Ld" version))
      else
        let* raw_object_id = binding_bytes "object ID" raw_object_id in
        let* object_id =
          match Object_id.of_raw_bytes raw_object_id with
          | Some object_id -> Ok object_id
          | None -> Error (Binding_error "object ID must contain 32 bytes")
        in
        let* supplied_checksum = binding_bytes "checksum" supplied_checksum in
        if String.length supplied_checksum <> Hash.digest_size then
          Error (Binding_error "checksum must contain 32 bytes")
        else
          let* body = binding_body object_id in
          let expected_checksum = binding_checksum body in
          if not (String.equal expected_checksum supplied_checksum) then
            Error (Binding_error "checksum mismatch")
          else
            let canonical = encode_binding object_id in
            if String.equal canonical bytes then Ok object_id
            else Error (Binding_error "bytes are noncanonical")
  | _ -> assert false

let store_set repository set =
  let* envelope =
    Divergence.envelope set
    |> Result.map_error (fun error -> Divergence_error error)
  in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_set repository object_id =
  let* envelope =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type envelope <> Envelope.Divergent_ref_set then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Divergent_ref_set;
           actual = Envelope.object_type envelope;
         })
  else
    Divergence.decode_payload (Envelope.payload envelope)
    |> Result.map_error (fun error -> Divergence_error error)

let same_set left right =
  match (Divergence.payload left, Divergence.payload right) with
  | Ok left, Ok right -> Encoding.equal left right
  | Error _, _ | _, Error _ -> false

let validate_set repository ~trusted_keys set =
  let rec collect entries = function
    | [] -> Ok (List.rev entries)
    | link :: rest -> (
        let* event =
          Event_store.load_event repository (Divergence.link_object_id link)
          |> Result.map_error (fun error -> Ref_event_store_error error)
        in
        let unsigned = Event.event_unsigned event in
        let event_id = Event.unsigned_event_id unsigned in
        if not (Event.Event_id.equal event_id (Divergence.link_event_id link))
        then Error (Event_id_mismatch (Divergence.link_event_id link))
        else
          let* verified =
            Event.verify_for_device ~repository_format:Store.repository_format
              ~trusted_keys event
            |> Result.map_error (fun error -> Event_error error)
          in
          match verified with
          | None -> Error (Untrusted_event event_id)
          | Some verified ->
              collect
                (Divergence.entry_of_verified
                   ~object_id:(Divergence.link_object_id link)
                   verified
                :: entries)
                rest)
  in
  let* entries = collect [] (Divergence.entries set) in
  let* validated =
    Divergence.make ~repository_format:Store.repository_format entries
    |> Result.map_error (fun error -> Divergence_error error)
  in
  if same_set set validated then Ok validated
  else
    Error
      (Divergence_error
         (Divergence.Event_context_mismatch
            "stored set fields disagree with verified event links"))

let load_published repository ~trusted_keys ~ref_name =
  let* binding =
    Store.Ref_file.read repository ~components:(binding_components ~ref_name)
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Ok None
  | Some binding ->
      let* object_id = decode_binding binding in
      let* set = load_set repository object_id in
      validate_set repository ~trusted_keys set |> Result.map Option.some

let publish repository ~trusted_keys entries =
  let* supplied =
    Divergence.make ~repository_format:Store.repository_format entries
    |> Result.map_error (fun error -> Divergence_error error)
  in
  let* supplied = validate_set repository ~trusted_keys supplied in
  let components =
    binding_components ~ref_name:(Divergence.ref_name supplied)
  in
  let rec attempt remaining =
    if remaining = 0 then Error (Cas_retry_exhausted max_cas_retries)
    else
      let result =
        Store.with_lock repository
          ~name:(lock_name (Divergence.ref_name supplied))
          ~on_error:(fun error -> Store_error error)
          (fun () ->
            let* current =
              Store.Ref_file.read repository ~components
              |> Result.map_error (fun error -> Store_error error)
            in
            let* candidate, current_id, unchanged =
              match current with
              | None -> Ok (supplied, None, false)
              | Some binding ->
                  let* object_id = decode_binding binding in
                  let* set = load_set repository object_id in
                  let* set = validate_set repository ~trusted_keys set in
                  let* candidate =
                    Divergence.union set supplied
                    |> Result.map_error (fun error -> Divergence_error error)
                  in
                  Ok (candidate, Some object_id, same_set set candidate)
            in
            match (current_id, unchanged) with
            | Some object_id, true -> Ok object_id
            | None, _ | Some _, false -> (
                let* object_id = store_set repository candidate in
                let replacement = encode_binding object_id in
                let publication =
                  Store.Ref_file.compare_and_swap repository ~components
                    ~expected:current ~replacement
                  |> Result.map_error (fun error -> Store_error error)
                in
                match publication with
                | Ok () -> Ok object_id
                | Error error -> Error error))
      in
      match result with
      | Ok _ -> result
      | Error error ->
          if is_lock_held error || is_cas_race error then attempt (remaining - 1)
          else Error error
  in
  attempt max_cas_retries
