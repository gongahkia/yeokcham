module Device = Yeokcham_device
module Envelope = Yeokcham_envelope
module Store = Yeokcham_store

type error =
  | Store_error of Store.error
  | Device_error of Device.error
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Device_error error -> Device.error_to_string error
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "unexpected object type: expected %d, got %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)

let store_identity repository identity =
  let ( let* ) = Result.bind in
  let* envelope =
    Device.identity_envelope identity
    |> Result.map_error (fun error -> Device_error error)
  in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_identity repository object_id =
  let ( let* ) = Result.bind in
  let* envelope =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type envelope <> Envelope.Device_identity then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Device_identity;
           actual = Envelope.object_type envelope;
         })
  else
    Device.decode_identity_payload (Envelope.payload envelope)
    |> Result.map_error (fun error -> Device_error error)

let registry_entry repository object_id =
  let ( let* ) = Result.bind in
  let* identity = load_identity repository object_id in
  Device.registry_entry ~identity ~object_id
  |> Result.map_error (fun error -> Device_error error)

let registry_of_objects repository object_ids =
  let ( let* ) = Result.bind in
  let rec entries values = function
    | [] -> Ok (List.rev values)
    | object_id :: rest ->
        let ( let* ) = Result.bind in
        let* entry = registry_entry repository object_id in
        entries (entry :: values) rest
  in
  let* entries = entries [] object_ids in
  Device.make_registry entries
  |> Result.map_error (fun error -> Device_error error)
