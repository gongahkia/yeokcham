module Envelope = Paengi_envelope
module Exchange = Paengi_exchange
module Object_id = Paengi_store.Stored_object_id
module Store = Paengi_store

type error =
  | Protocol_error of Exchange.error
  | Source_store_error of Store.error
  | Destination_store_error of Store.error
  | Envelope_error of Envelope.decode_error
  | Noncanonical_envelope_bytes
  | Object_identity_mismatch of { expected : Object_id.t; actual : Object_id.t }
  | Interrupted_after of int
  | Invalid_transfer_input of string

type outcome = {
  offered : int;
  requested : int;
  transferred : Object_id.t list;
}

let error_to_string = function
  | Protocol_error error -> Exchange.error_to_string error
  | Source_store_error error -> "source store: " ^ Store.error_to_string error
  | Destination_store_error error -> "destination store: " ^ Store.error_to_string error
  | Envelope_error error -> "received envelope: " ^ Envelope.decode_error_to_string error
  | Noncanonical_envelope_bytes -> "received envelope bytes are not canonical"
  | Object_identity_mismatch { expected; actual } ->
      Printf.sprintf "received object ID mismatch: expected %s, got %s"
        (Object_id.to_hex expected) (Object_id.to_hex actual)
  | Interrupted_after count ->
      Printf.sprintf "local exchange interrupted after %d publications" count
  | Invalid_transfer_input message -> "invalid local exchange input: " ^ message

let ( let* ) = Result.bind

let round_trip message =
  let* frame = Exchange.encode message |> Result.map_error (fun error -> Protocol_error error) in
  Exchange.decode frame |> Result.map_error (fun error -> Protocol_error error)

let object_message repository ~session_id ~sequence object_id =
  let* envelope = Store.get repository object_id |> Result.map_error (fun error -> Source_store_error error) in
  let envelope_bytes = Envelope.encode envelope in
  let actual = Store.id_of_envelope envelope in
  if not (Object_id.equal object_id actual) then
    Error (Object_identity_mismatch { expected = object_id; actual })
  else
    Ok
      (Exchange.Object
         {
           session_id;
           sequence;
           object_id;
           envelope_bytes;
           required_features = Exchange.supported_required_features;
         })

let receive_object repository receiver message =
  let* next_receiver, receipt =
    Exchange.accept_object receiver message
    |> Result.map_error (fun error -> Protocol_error error)
  in
  let expected = Exchange.received_object_id receipt in
  let envelope_bytes = Exchange.received_object_bytes receipt in
  let* envelope = Envelope.decode envelope_bytes |> Result.map_error (fun error -> Envelope_error error) in
  if not (String.equal envelope_bytes (Envelope.encode envelope)) then
    Error Noncanonical_envelope_bytes
  else
    let actual = Store.id_of_envelope envelope in
    if not (Object_id.equal expected actual) then
      Error (Object_identity_mismatch { expected; actual })
    else
      let* published =
        Store.put repository envelope
        |> Result.map_error (fun error -> Destination_store_error error)
      in
      if not (Object_id.equal expected published) then
        Error (Object_identity_mismatch { expected; actual = published })
      else Ok (next_receiver, published)

let rec chunks size values =
  if values = [] then []
  else
    let rec take count accumulator rest =
      if count = 0 then List.rev accumulator, rest
      else
        match rest with
        | [] -> List.rev accumulator, []
        | value :: rest -> take (count - 1) (value :: accumulator) rest
    in
    let page, rest = take size [] values in
    page :: chunks size rest

let strictly_sorted_ids ids =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) ->
        Object_id.compare left right < 0 && loop rest
  in
  loop ids

let destination_missing destination object_id =
  let path = Store.object_path destination object_id in
  if not (Sys.file_exists path) then Ok true
  else
    Store.get destination object_id
    |> Result.map (fun _ -> false)
    |> Result.map_error (fun error -> Destination_store_error error)

let check_want ~session_id ~sequence expected = function
  | Exchange.Want { session_id = actual; sequence = actual_sequence; object_ids; _ }
    when String.equal (Exchange.session_id_to_bytes actual)
           (Exchange.session_id_to_bytes session_id)
         && Int64.equal actual_sequence sequence
         && List.length object_ids = List.length expected
         && List.for_all2 Object_id.equal object_ids expected ->
      Ok ()
  | Exchange.Want _ -> Error (Invalid_transfer_input "decoded Want changed")
  | Exchange.Hello _ | Exchange.Inventory _ | Exchange.Object _ | Exchange.End _
  | Exchange.Error_message _ ->
      Error (Invalid_transfer_input "expected Want after inventory")

let transfer ?interrupt_after ?(object_byte_budget = Exchange.max_total_object_bytes)
    ~source ~destination ~session_id ~object_ids () =
  if not (strictly_sorted_ids object_ids) then
    Error (Invalid_transfer_input "object IDs must be strictly ascending")
  else if List.length object_ids > Exchange.max_session_object_ids then
    Error (Invalid_transfer_input "object ID count exceeds the session limit")
  else
    let* receiver =
      Exchange.initial_receiver ~object_byte_budget
      |> Result.map_error (fun error -> Protocol_error error)
    in
    let hello =
      Exchange.Hello
        {
          repository_format = Store.repository_format;
          supported_versions = [ Exchange.protocol_version ];
          required_features = Exchange.supported_required_features;
        }
    in
    let* hello = round_trip hello in
    let* receiver =
      Exchange.accept_hello receiver hello
      |> Result.map_error (fun error -> Protocol_error error)
    in
    let rec transfer_pages receiver object_sequence requested transferred page_index = function
      | [] ->
          let end_message =
            Exchange.End
              {
                session_id;
                status = Exchange.Complete;
                required_features = Exchange.supported_required_features;
              }
          in
          let* end_message = round_trip end_message in
          let* _ =
            Exchange.accept_end receiver end_message
            |> Result.map_error (fun error -> Protocol_error error)
          in
          Ok
            {
              offered = List.length object_ids;
              requested;
              transferred = List.rev transferred;
            }
      | page :: rest ->
          let final = rest = [] in
          let inventory =
            Exchange.Inventory
              {
                session_id;
                sequence = Int64.of_int page_index;
                final;
                object_ids = page;
                required_features = Exchange.supported_required_features;
              }
          in
          let* inventory = round_trip inventory in
          let* receiver, offered =
            Exchange.accept_inventory receiver inventory
            |> Result.map_error (fun error -> Protocol_error error)
          in
          let rec select_missing accumulator = function
            | [] -> Ok (List.rev accumulator)
            | object_id :: ids ->
                let* missing = destination_missing destination object_id in
                select_missing (if missing then object_id :: accumulator else accumulator) ids
          in
          let* wants = select_missing [] offered in
          let* receiver, want =
            Exchange.register_want receiver ~sequence:(Int64.of_int page_index) wants
            |> Result.map_error (fun error -> Protocol_error error)
          in
          let* decoded_want = round_trip want in
          let* () = check_want ~session_id ~sequence:(Int64.of_int page_index) wants decoded_want in
          let rec transfer_wants receiver object_sequence transferred = function
            | [] -> Ok (receiver, object_sequence, transferred)
            | object_id :: ids ->
                if
                  match interrupt_after with
                  | Some limit -> List.length transferred >= limit
                  | None -> false
                then Error (Interrupted_after (List.length transferred))
                else
                  let* object_message =
                    object_message source ~session_id ~sequence:object_sequence object_id
                  in
                  let* object_message = round_trip object_message in
                  let* receiver, published =
                    receive_object destination receiver object_message
                  in
                  transfer_wants receiver Int64.(add object_sequence 1L)
                    (published :: transferred) ids
          in
          let* receiver, object_sequence, transferred =
            transfer_wants receiver object_sequence transferred wants
          in
          transfer_pages receiver object_sequence
            (requested + List.length wants)
            transferred (page_index + 1) rest
    in
    transfer_pages receiver 0L 0 [] 0 (chunks Exchange.max_ids_per_page object_ids)
