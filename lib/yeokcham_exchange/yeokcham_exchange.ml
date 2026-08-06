module Encoding = Yeokcham_encoding
module Object_id = Yeokcham_store.Stored_object_id

type session_id = string
type end_status = Complete | Incomplete

type message =
  | Hello of {
      repository_format : string;
      supported_versions : int list;
      required_features : int64;
    }
  | Inventory of {
      session_id : session_id;
      sequence : int64;
      final : bool;
      object_ids : Object_id.t list;
      required_features : int64;
    }
  | Want of {
      session_id : session_id;
      sequence : int64;
      object_ids : Object_id.t list;
      required_features : int64;
    }
  | Object of {
      session_id : session_id;
      sequence : int64;
      object_id : Object_id.t;
      envelope_bytes : string;
      required_features : int64;
    }
  | End of {
      session_id : session_id;
      status : end_status;
      required_features : int64;
    }
  | Error_message of {
      session_id : session_id option;
      code : string;
      detail : string;
      required_features : int64;
    }

type error =
  | Invalid_session_id of int
  | Truncated_frame of int
  | Frame_length_mismatch of { declared : int64; actual : int }
  | Frame_too_large of int64
  | Invalid_cbor of string
  | Noncanonical_cbor
  | Invalid_message of string
  | Unsupported_version of int64
  | Unsupported_features of int64
  | Message_too_large of { size : int; limit : int }
  | Object_too_large of { size : int; limit : int }
  | Hello_required
  | Duplicate_hello
  | Incompatible_repository_format
  | No_compatible_version
  | Session_mismatch
  | Session_closed
  | Out_of_order_sequence of { previous : int64; current : int64 }
  | Inventory_closed
  | Unknown_inventory_sequence of int64
  | Unoffered_object of Object_id.t
  | Unrequested_object of Object_id.t
  | Duplicate_request of Object_id.t
  | Requested_object_limit_exceeded of { count : int; limit : int }
  | Transferred_object_limit_exceeded of { count : int; limit : int }
  | Control_budget_exceeded of { used : int; limit : int }
  | Object_budget_exceeded of { used : int; limit : int }
  | End_with_pending_requests of int
  | Peer_error of { code : string; detail : string }

type receiver = {
  object_byte_budget : int;
  hello_seen : bool;
  session : session_id option;
  inventories : (int64 * Object_id.t list) list;
  last_inventory_sequence : int64 option;
  last_object_sequence : int64 option;
  requested : Object_id.t list;
  requested_count : int;
  transferred_count : int;
  control_bytes : int;
  object_bytes : int;
  inventory_closed : bool;
  closed : bool;
}

type received_object = { object_id : Object_id.t; envelope_bytes : string }

let protocol_version = 1
let supported_required_features = 0L
let max_control_message_bytes = 1024 * 1024
let max_ids_per_page = 4096
let max_session_control_bytes = 16 * 1024 * 1024
let max_session_object_ids = 65_536
let max_total_object_bytes = 1024 * 1024 * 1024

let error_to_string = function
  | Invalid_session_id size ->
      Printf.sprintf "exchange session ID must contain 16 bytes, got %d" size
  | Truncated_frame size ->
      Printf.sprintf "exchange frame is truncated at %d" size
  | Frame_length_mismatch { declared; actual } ->
      Printf.sprintf "exchange frame length mismatch: declared %Ld, actual %d"
        declared actual
  | Frame_too_large size ->
      Printf.sprintf "exchange frame is too large: %Ld" size
  | Invalid_cbor message -> "invalid exchange CBOR: " ^ message
  | Noncanonical_cbor -> "exchange CBOR is not canonical"
  | Invalid_message message -> "invalid exchange message: " ^ message
  | Unsupported_version version ->
      Printf.sprintf "unsupported exchange protocol version: %Ld" version
  | Unsupported_features features ->
      Printf.sprintf "unsupported exchange required features: %Ld" features
  | Message_too_large { size; limit } ->
      Printf.sprintf "exchange control message is %d bytes; limit is %d" size
        limit
  | Object_too_large { size; limit } ->
      Printf.sprintf "exchange object is %d bytes; limit is %d" size limit
  | Hello_required -> "exchange Hello must precede this message"
  | Duplicate_hello -> "exchange Hello was already accepted"
  | Incompatible_repository_format -> "exchange repository formats differ"
  | No_compatible_version ->
      "exchange peers have no compatible protocol version"
  | Session_mismatch -> "exchange session ID does not match"
  | Session_closed -> "exchange session is closed"
  | Out_of_order_sequence { previous; current } ->
      Printf.sprintf "exchange sequence %Ld does not follow %Ld" current
        previous
  | Inventory_closed -> "exchange inventory was already final"
  | Unknown_inventory_sequence sequence ->
      Printf.sprintf "exchange inventory sequence %Ld is unavailable" sequence
  | Unoffered_object id ->
      Printf.sprintf "exchange object was not offered: %s" (Object_id.to_hex id)
  | Unrequested_object id ->
      Printf.sprintf "exchange object was not requested: %s"
        (Object_id.to_hex id)
  | Duplicate_request id ->
      Printf.sprintf "exchange object was already requested: %s"
        (Object_id.to_hex id)
  | Requested_object_limit_exceeded { count; limit } ->
      Printf.sprintf "exchange requested %d objects; limit is %d" count limit
  | Transferred_object_limit_exceeded { count; limit } ->
      Printf.sprintf "exchange transferred %d objects; limit is %d" count limit
  | Control_budget_exceeded { used; limit } ->
      Printf.sprintf "exchange control bytes %d exceed limit %d" used limit
  | Object_budget_exceeded { used; limit } ->
      Printf.sprintf "exchange object bytes %d exceed limit %d" used limit
  | End_with_pending_requests count ->
      Printf.sprintf "exchange ended with %d requested objects missing" count
  | Peer_error { code; detail } ->
      Printf.sprintf "exchange peer error %s: %s" code detail

let session_id_of_bytes bytes =
  if String.length bytes = 16 then Ok bytes
  else Error (Invalid_session_id (String.length bytes))

let session_id_to_bytes session_id = session_id
let ( let* ) = Result.bind

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_message (Encoding.construction_error_to_string error))

let int value = Encoding.integer value
let bytes value = Encoding.bytes value

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_message (Encoding.construction_error_to_string error))

let encode_ids ids =
  List.map (fun id -> bytes (Object_id.to_raw_bytes id)) ids |> array

let strictly_sorted_ids ids =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) ->
        Object_id.compare left right < 0 && loop rest
  in
  loop ids

let check_ids name ids =
  if List.length ids > max_ids_per_page then
    Error
      (Invalid_message
         (Printf.sprintf "%s contains more than %d IDs" name max_ids_per_page))
  else if strictly_sorted_ids ids then Ok ()
  else Error (Invalid_message (name ^ " IDs are not strictly ascending"))

let check_features required_features =
  if Int64.equal required_features supported_required_features then Ok ()
  else Error (Unsupported_features required_features)

let check_sequence sequence =
  if Int64.compare sequence 0L < 0 then
    Error (Invalid_message "sequence must be non-negative")
  else Ok ()

let encode_payload message =
  let* values =
    match message with
    | Hello { repository_format; supported_versions; required_features } ->
        let versions =
          List.map
            (fun version -> int (Int64.of_int version))
            supported_versions
        in
        let* versions = array versions in
        array
          [
            int 1L;
            int 0L;
            int required_features;
            bytes repository_format;
            versions;
          ]
    | Inventory { session_id; sequence; final; object_ids; required_features }
      ->
        let* ids = encode_ids object_ids in
        array
          [
            int 1L;
            int 1L;
            int required_features;
            bytes session_id;
            int sequence;
            Encoding.bool final;
            ids;
          ]
    | Want { session_id; sequence; object_ids; required_features } ->
        let* ids = encode_ids object_ids in
        array
          [
            int 1L;
            int 2L;
            int required_features;
            bytes session_id;
            int sequence;
            ids;
          ]
    | Object
        { session_id; sequence; object_id; envelope_bytes; required_features }
      ->
        array
          [
            int 1L;
            int 3L;
            int required_features;
            bytes session_id;
            int sequence;
            bytes (Object_id.to_raw_bytes object_id);
            bytes envelope_bytes;
          ]
    | End { session_id; status; required_features } ->
        let status = match status with Complete -> 0L | Incomplete -> 1L in
        array
          [
            int 1L; int 4L; int required_features; bytes session_id; int status;
          ]
    | Error_message { session_id; code; detail; required_features } ->
        let session =
          match session_id with
          | None -> Ok Encoding.null
          | Some value -> Ok (bytes value)
        in
        let* session = session in
        let* code = text code in
        let* detail = text detail in
        array [ int 1L; int 5L; int required_features; session; code; detail ]
  in
  Ok (Encoding.encode values)

let validate_message = function
  | Hello { repository_format; supported_versions; required_features } ->
      let* () = check_features required_features in
      if String.length repository_format = 0 then
        Error (Invalid_message "repository format is empty")
      else if supported_versions = [] then
        Error (Invalid_message "supported versions are empty")
      else if List.exists (fun version -> version < 0) supported_versions then
        Error (Invalid_message "supported version is negative")
      else if
        List.sort_uniq Int.compare supported_versions <> supported_versions
      then
        Error (Invalid_message "supported versions are not strictly ascending")
      else Ok ()
  | Inventory { session_id; sequence; object_ids; required_features; _ } ->
      let* () = check_features required_features in
      let* () = session_id_of_bytes session_id |> Result.map (fun _ -> ()) in
      let* () = check_sequence sequence in
      check_ids "inventory" object_ids
  | Want { session_id; sequence; object_ids; required_features } ->
      let* () = check_features required_features in
      let* () = session_id_of_bytes session_id |> Result.map (fun _ -> ()) in
      let* () = check_sequence sequence in
      check_ids "want" object_ids
  | Object
      { session_id; sequence; object_id = _; envelope_bytes; required_features }
    ->
      let* () = check_features required_features in
      let* () = session_id_of_bytes session_id |> Result.map (fun _ -> ()) in
      let* () = check_sequence sequence in
      if String.length envelope_bytes > Yeokcham_store.max_object_bytes then
        Error
          (Object_too_large
             {
               size = String.length envelope_bytes;
               limit = Yeokcham_store.max_object_bytes;
             })
      else Ok ()
  | End { session_id; required_features; _ } ->
      let* () = check_features required_features in
      session_id_of_bytes session_id |> Result.map (fun _ -> ())
  | Error_message { session_id; code; required_features; _ } ->
      let* () = check_features required_features in
      let* () =
        match session_id with
        | None -> Ok ()
        | Some value -> session_id_of_bytes value |> Result.map (fun _ -> ())
      in
      if String.length code = 0 then
        Error (Invalid_message "error code is empty")
      else Ok ()

let control_size message payload =
  match message with
  | Object { envelope_bytes; _ } ->
      String.length payload - String.length envelope_bytes
  | Hello _ | Inventory _ | Want _ | End _ | Error_message _ ->
      String.length payload

let check_message_size message payload =
  let control = control_size message payload in
  if control > max_control_message_bytes then
    Error
      (Message_too_large { size = control; limit = max_control_message_bytes })
  else Ok ()

let frame payload =
  let length = String.length payload in
  let output = Bytes.create (length + 8) in
  let value = Int64.of_int length in
  for index = 0 to 7 do
    let shift = (7 - index) * 8 in
    let byte = Int64.(to_int (logand (shift_right_logical value shift) 255L)) in
    Bytes.set output index (Char.chr byte)
  done;
  Bytes.blit_string payload 0 output 8 length;
  Bytes.unsafe_to_string output

let encode message =
  let* () = validate_message message in
  let* payload = encode_payload message in
  let* () = check_message_size message payload in
  Ok (frame payload)

let parse_uint name = function
  | Encoding.Integer value when Int64.compare value 0L >= 0 -> Ok value
  | Encoding.Integer _ ->
      Error (Invalid_message (name ^ " must be non-negative"))
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be an integer"))

let parse_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be bytes"))

let parse_text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be text"))

let parse_bool name = function
  | Encoding.Bool value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be a boolean"))

let parse_at_least_fields name count = function
  | Encoding.Array fields when List.length fields >= count -> Ok fields
  | Encoding.Array _ ->
      Error
        (Invalid_message
           (Printf.sprintf "%s must contain at least %d fields" name count))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be an array"))

let parse_session value =
  let* bytes = parse_bytes "session ID" value in
  session_id_of_bytes bytes

let parse_id value =
  let* raw = parse_bytes "stored object ID" value in
  match Object_id.of_raw_bytes raw with
  | Some id -> Ok id
  | None -> Error (Invalid_message "stored object ID must contain 32 bytes")

let parse_ids value =
  match value with
  | Encoding.Array values ->
      let rec loop accumulator = function
        | [] -> Ok (List.rev accumulator)
        | value :: rest ->
            let* id = parse_id value in
            loop (id :: accumulator) rest
      in
      let* ids = loop [] values in
      let* () = check_ids "object ID page" ids in
      Ok ids
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message "object ID page must be an array")

let parse_versions value =
  match value with
  | Encoding.Array values ->
      let rec loop accumulator = function
        | [] -> Ok (List.rev accumulator)
        | value :: rest ->
            let* version = parse_uint "supported version" value in
            if Int64.compare version (Int64.of_int max_int) > 0 then
              Error (Invalid_message "supported version is out of range")
            else loop (Int64.to_int version :: accumulator) rest
      in
      loop [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message "supported versions must be an array")

let parse_payload payload =
  let* value =
    Encoding.decode payload
    |> Result.map_error (fun error ->
        Invalid_cbor (Encoding.decode_error_to_string error))
  in
  if not (String.equal payload (Encoding.encode value)) then
    Error Noncanonical_cbor
  else
    let* fields = parse_at_least_fields "exchange message" 3 value in
    match fields with
    | version :: kind :: required_features :: rest ->
        let* version = parse_uint "protocol version" version in
        if not (Int64.equal version 1L) then Error (Unsupported_version version)
        else
          let required_features =
            match required_features with
            | Encoding.Integer value -> Ok value
            | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
            | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
                Error (Invalid_message "required features must be an integer")
          in
          let* required_features = required_features in
          let* () = check_features required_features in
          let* kind = parse_uint "message kind" kind in
          let message =
            match (kind, rest) with
            | 0L, [ repository_format; versions ] ->
                let* repository_format =
                  parse_bytes "repository format" repository_format
                in
                let* supported_versions = parse_versions versions in
                Ok
                  (Hello
                     {
                       repository_format;
                       supported_versions;
                       required_features;
                     })
            | 1L, [ session_id; sequence; final; object_ids ] ->
                let* session_id = parse_session session_id in
                let* sequence = parse_uint "inventory sequence" sequence in
                let* final = parse_bool "inventory final" final in
                let* object_ids = parse_ids object_ids in
                Ok
                  (Inventory
                     {
                       session_id;
                       sequence;
                       final;
                       object_ids;
                       required_features;
                     })
            | 2L, [ session_id; sequence; object_ids ] ->
                let* session_id = parse_session session_id in
                let* sequence = parse_uint "want sequence" sequence in
                let* object_ids = parse_ids object_ids in
                Ok
                  (Want { session_id; sequence; object_ids; required_features })
            | 3L, [ session_id; sequence; object_id; envelope_bytes ] ->
                let* session_id = parse_session session_id in
                let* sequence = parse_uint "object sequence" sequence in
                let* object_id = parse_id object_id in
                let* envelope_bytes =
                  parse_bytes "object envelope bytes" envelope_bytes
                in
                Ok
                  (Object
                     {
                       session_id;
                       sequence;
                       object_id;
                       envelope_bytes;
                       required_features;
                     })
            | 4L, [ session_id; status ] ->
                let* session_id = parse_session session_id in
                let* status = parse_uint "end status" status in
                let* status =
                  match status with
                  | 0L -> Ok Complete
                  | 1L -> Ok Incomplete
                  | _ -> Error (Invalid_message "end status is unsupported")
                in
                Ok (End { session_id; status; required_features })
            | 5L, [ session_id; code; detail ] ->
                let* session_id =
                  if Encoding.equal session_id Encoding.null then Ok None
                  else parse_session session_id |> Result.map Option.some
                in
                let* code = parse_text "error code" code in
                let* detail = parse_text "error detail" detail in
                Ok
                  (Error_message { session_id; code; detail; required_features })
            | _ ->
                Error (Invalid_message "message kind or fields are unsupported")
          in
          let* message = message in
          let* () = validate_message message in
          let* () = check_message_size message payload in
          Ok message
    | _ -> Error (Invalid_message "exchange message has fewer than 3 fields")

let decode_length input =
  if String.length input < 8 then Error (Truncated_frame (String.length input))
  else
    let value = ref 0L in
    for index = 0 to 7 do
      value :=
        Int64.logor
          (Int64.shift_left !value 8)
          (Int64.of_int (Char.code input.[index]))
    done;
    if Int64.compare !value 0L < 0 then Error (Frame_too_large !value)
    else Ok !value

let decode input =
  let* declared = decode_length input in
  let actual = String.length input - 8 in
  if not (Int64.equal declared (Int64.of_int actual)) then
    Error (Frame_length_mismatch { declared; actual })
  else if
    Int64.compare declared
      (Int64.of_int (Yeokcham_store.max_object_bytes + max_control_message_bytes))
    > 0
  then Error (Frame_too_large declared)
  else parse_payload (String.sub input 8 actual)

let initial_receiver ~object_byte_budget =
  if object_byte_budget < 0 || object_byte_budget > max_total_object_bytes then
    Error
      (Object_budget_exceeded
         { used = object_byte_budget; limit = max_total_object_bytes })
  else
    Ok
      {
        object_byte_budget;
        hello_seen = false;
        session = None;
        inventories = [];
        last_inventory_sequence = None;
        last_object_sequence = None;
        requested = [];
        requested_count = 0;
        transferred_count = 0;
        control_bytes = 0;
        object_bytes = 0;
        inventory_closed = false;
        closed = false;
      }

let message_control_size message =
  let* payload = encode_payload message in
  Ok (control_size message payload)

let add_control receiver message =
  let* size = message_control_size message in
  let used = receiver.control_bytes + size in
  if used > max_session_control_bytes then
    Error (Control_budget_exceeded { used; limit = max_session_control_bytes })
  else Ok { receiver with control_bytes = used }

let require_open receiver =
  if receiver.closed then Error Session_closed else Ok ()

let require_hello receiver =
  if receiver.hello_seen then Ok () else Error Hello_required

let accept_hello receiver message =
  let* () = require_open receiver in
  match message with
  | Hello { repository_format; supported_versions; _ } ->
      if receiver.hello_seen then Error Duplicate_hello
      else if
        not (String.equal repository_format Yeokcham_store.repository_format)
      then Error Incompatible_repository_format
      else if not (List.mem protocol_version supported_versions) then
        Error No_compatible_version
      else
        let* receiver = add_control receiver message in
        Ok { receiver with hello_seen = true }
  | Inventory _ | Want _ | Object _ | End _ | Error_message _ ->
      Error Hello_required

let check_session receiver session_id =
  match receiver.session with
  | None -> Ok ()
  | Some expected when String.equal expected session_id -> Ok ()
  | Some _ -> Error Session_mismatch

let follows previous current =
  match previous with
  | None -> Ok ()
  | Some previous when Int64.compare current previous > 0 -> Ok ()
  | Some previous -> Error (Out_of_order_sequence { previous; current })

let accept_inventory receiver message =
  let* () = require_open receiver in
  let* () = require_hello receiver in
  match message with
  | Inventory { session_id; sequence; final; object_ids; _ } ->
      if receiver.inventory_closed then Error Inventory_closed
      else
        let* () = check_session receiver session_id in
        let* () = follows receiver.last_inventory_sequence sequence in
        let* receiver = add_control receiver message in
        Ok
          ( {
              receiver with
              session = Some session_id;
              inventories = (sequence, object_ids) :: receiver.inventories;
              last_inventory_sequence = Some sequence;
              inventory_closed = final;
            },
            object_ids )
  | Hello _ | Want _ | Object _ | End _ | Error_message _ ->
      Error (Invalid_message "expected inventory")

let contains ids id =
  List.exists (fun candidate -> Object_id.equal candidate id) ids

let find_inventory receiver sequence =
  match List.assoc_opt sequence receiver.inventories with
  | Some ids -> Ok ids
  | None -> Error (Unknown_inventory_sequence sequence)

let register_want receiver ~sequence object_ids =
  let* () = require_open receiver in
  let* () = require_hello receiver in
  let* offered = find_inventory receiver sequence in
  let* () = check_ids "want" object_ids in
  let rec check = function
    | [] -> Ok ()
    | id :: rest ->
        if not (contains offered id) then Error (Unoffered_object id)
        else if contains receiver.requested id then Error (Duplicate_request id)
        else check rest
  in
  let* () = check object_ids in
  let count = receiver.requested_count + List.length object_ids in
  if count > max_session_object_ids then
    Error
      (Requested_object_limit_exceeded { count; limit = max_session_object_ids })
  else
    match receiver.session with
    | None -> Error (Invalid_message "inventory did not establish a session")
    | Some session_id ->
        let message =
          Want
            {
              session_id;
              sequence;
              object_ids;
              required_features = supported_required_features;
            }
        in
        let* receiver = add_control receiver message in
        Ok
          ( {
              receiver with
              requested = object_ids @ receiver.requested;
              requested_count = count;
            },
            message )

let accept_object receiver message =
  let* () = require_open receiver in
  let* () = require_hello receiver in
  match message with
  | Object { session_id; sequence; object_id; envelope_bytes; _ } ->
      let* () = check_session receiver session_id in
      let* () = follows receiver.last_object_sequence sequence in
      if not (contains receiver.requested object_id) then
        Error (Unrequested_object object_id)
      else
        let count = receiver.transferred_count + 1 in
        if count > max_session_object_ids then
          Error
            (Transferred_object_limit_exceeded
               { count; limit = max_session_object_ids })
        else
          let object_bytes =
            receiver.object_bytes + String.length envelope_bytes
          in
          if object_bytes > receiver.object_byte_budget then
            Error
              (Object_budget_exceeded
                 { used = object_bytes; limit = receiver.object_byte_budget })
          else
            let* receiver = add_control receiver message in
            Ok
              ( {
                  receiver with
                  requested =
                    List.filter
                      (fun requested ->
                        not (Object_id.equal requested object_id))
                      receiver.requested;
                  transferred_count = count;
                  object_bytes;
                  last_object_sequence = Some sequence;
                },
                { object_id; envelope_bytes } )
  | Hello _ | Inventory _ | Want _ | End _ | Error_message _ ->
      Error (Invalid_message "expected object")

let accept_end receiver message =
  let* () = require_open receiver in
  let* () = require_hello receiver in
  match message with
  | End { session_id; status; _ } ->
      let* () = check_session receiver session_id in
      let* receiver = add_control receiver message in
      if status = Complete && receiver.requested <> [] then
        Error (End_with_pending_requests (List.length receiver.requested))
      else Ok { receiver with closed = true }
  | Hello _ | Inventory _ | Want _ | Object _ | Error_message _ ->
      Error (Invalid_message "expected end")

let accept_error receiver message =
  let* () = require_open receiver in
  let* () = require_hello receiver in
  match message with
  | Error_message { session_id; code; detail; _ } ->
      let* () =
        match (session_id, receiver.session) with
        | None, _ | Some _, None -> Ok ()
        | Some actual, Some expected when String.equal actual expected -> Ok ()
        | Some _, Some _ -> Error Session_mismatch
      in
      Error (Peer_error { code; detail })
  | Hello _ | Inventory _ | Want _ | Object _ | End _ ->
      Error (Invalid_message "expected error")

let received_object_id receipt = receipt.object_id
let received_object_bytes receipt = receipt.envelope_bytes
