module Envelope = Yeokcham_envelope
module Event = Yeokcham_ref_event
module Store = Yeokcham_store

type error =
  | Store_error of Store.error
  | Event_error of Event.error
  | Envelope_error of Envelope.creation_error
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Event_error error -> Event.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "unexpected object type: expected %d, got %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)

let ref_state_of_mutable_ref reference =
  Event.make_ref_state
    ~generation:(Store.Mutable_ref.generation reference)
    ~target:(Store.Mutable_ref.target reference)
  |> Result.map_error (fun error -> Event_error error)

let read_ref_state repository ~name =
  match Store.read_ref repository ~name with
  | Error error -> Error (Store_error error)
  | Ok None -> Ok None
  | Ok (Some reference) ->
      ref_state_of_mutable_ref reference |> Result.map Option.some

let store_event repository event =
  let ( let* ) = Result.bind in
  let* payload =
    Event.event_payload event
    |> Result.map_error (fun error -> Event_error error)
  in
  let* envelope =
    Envelope.create ~object_type:Envelope.Ref_event
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_event repository object_id =
  let ( let* ) = Result.bind in
  let* envelope =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type envelope <> Envelope.Ref_event then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Ref_event;
           actual = Envelope.object_type envelope;
         })
  else
    Event.decode_event_payload (Envelope.payload envelope)
    |> Result.map_error (fun error -> Event_error error)
