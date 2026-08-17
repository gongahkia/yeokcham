module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
module Id = Yeokcham_id
module Peer_sync = Yeokcham_peer_sync
module Store = Yeokcham_store
module Peer_id = Id.Peer_id
module Sync_node_id = Id.Peer_sync_node_id

type request = {
  request_remote_root : string;
  request_source : Peer_id.t;
  request_destination : Peer_sync.identity;
  request_nonce : string;
  request_tracking_name : string;
  request_head : Sync_node_id.t;
}

type response =
  | Accepted of {
      proof : Peer_sync.session_proof;
      head_object : Store.Stored_object_id.t;
    }
  | Rejected of { code : string; detail : string }

type error =
  | Invalid_request of string
  | Invalid_response of string
  | Protocol_error of Exchange.error
  | Exchange_error of Exchange_store.error
  | Peer_error of Peer_sync.error
  | Remote_error of { code : string; detail : string }
  | Transport_error of string

let ( let* ) = Result.bind
let max_handshake_bytes = 1024 * 1024
let max_remote_error_bytes = 4096
let max_path_bytes = 4096
let max_target_bytes = 255
let remote_command = "yeokcham peer sync ssh-serve"

let error_to_string = function
  | Invalid_request detail -> "invalid SSH peer-sync request: " ^ detail
  | Invalid_response detail -> "invalid SSH peer-sync response: " ^ detail
  | Protocol_error error -> Exchange.error_to_string error
  | Exchange_error error -> Exchange_store.error_to_string error
  | Peer_error error -> Peer_sync.error_to_string error
  | Remote_error { code; detail } ->
      "remote SSH peer-sync failure (" ^ code ^ "): " ^ detail
  | Transport_error detail -> "SSH peer-sync transport failure: " ^ detail

let invalid_request detail = Error (Invalid_request detail)
let invalid_response detail = Error (Invalid_response detail)

let result_list values =
  List.fold_left
    (fun result value ->
      let* reversed = result in
      let* value = value in
      Ok (value :: reversed))
    (Ok []) values
  |> Result.map List.rev

let array values =
  let* values = result_list values in
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_request (Encoding.construction_error_to_string error))

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_request (Encoding.construction_error_to_string error))

let safe_unix_path path =
  (not (String.is_empty path))
  && (not (Filename.is_relative path))
  && String.length path <= max_path_bytes
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '.' | '-' | '_' -> true
         | _ -> false)
       path

let safe_local_path path =
  (not (String.is_empty path))
  && (not (Filename.is_relative path))
  && String.length path <= max_path_bytes
  && (not (String.contains path '\000'))
  && (not (String.contains path '\n'))
  && not (String.contains path '\r')

let safe_ssh_target target =
  (not (String.is_empty target))
  && String.length target <= max_target_bytes
  && String.for_all
       (function
         | 'a' .. 'z'
         | 'A' .. 'Z'
         | '0' .. '9'
         | '.' | '-' | '_' | '@' | ':' | '[' | ']' ->
             true
         | _ -> false)
       target

let capability_path ~root =
  Filename.concat root ".yeokcham/bootstrap/peer-sync-ed25519"

let make_request ~remote_root ~source ~destination ~nonce ~tracking_name ~head =
  if not (safe_unix_path remote_root) then
    invalid_request "remote repository root must be an absolute safe Unix path"
  else if String.length nonce <> Peer_sync.nonce_bytes then
    invalid_request "challenge has the wrong length"
  else
    let* _ =
      Peer_sync.ssh_transcript ~tracking_name ~head
      |> Result.map_error (fun error -> Peer_error error)
    in
    Ok
      {
        request_remote_root = remote_root;
        request_source = source;
        request_destination = destination;
        request_nonce = nonce;
        request_tracking_name = tracking_name;
        request_head = head;
      }

let request_remote_root value = value.request_remote_root
let request_source value = value.request_source
let request_destination value = value.request_destination
let request_nonce value = value.request_nonce
let request_tracking_name value = value.request_tracking_name
let request_head value = value.request_head

let request_payload value =
  let* destination =
    Peer_sync.identity_payload value.request_destination
    |> Result.map_error (fun error -> Peer_error error)
  in
  array
    [
      Ok (Encoding.integer 1L);
      Ok (Encoding.bytes value.request_remote_root);
      Ok (Encoding.bytes (Peer_id.to_bytes value.request_source));
      Ok destination;
      Ok (Encoding.bytes value.request_nonce);
      text value.request_tracking_name;
      Ok (Encoding.bytes (Sync_node_id.to_bytes value.request_head));
    ]

let fields kind count = function
  | Encoding.Array values when List.length values = count -> Ok values
  | Encoding.Array _ -> invalid_request (kind ^ " has the wrong field count")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_request (kind ^ " must be an array")

let integer kind = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_request (kind ^ " must be an integer")

let bytes kind = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_request (kind ^ " must be bytes")

let text_field kind = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      invalid_request (kind ^ " must be text")

let decode_request_payload value =
  let* values = fields "SSH peer-sync request" 7 value in
  match values with
  | [ version; root; source; destination; nonce; tracking_name; head ] ->
      let* version = integer "SSH peer-sync request version" version in
      if not (Int64.equal version 1L) then
        invalid_request "unsupported SSH peer-sync request version"
      else
        let* remote_root = bytes "SSH peer-sync remote root" root in
        let* source = bytes "SSH peer-sync source identity" source in
        let* source =
          Peer_id.of_bytes source
          |> Result.map_error (fun _ ->
              Invalid_request "SSH peer-sync source identity has wrong length")
        in
        let* destination =
          Peer_sync.decode_identity_payload destination
          |> Result.map_error (fun error -> Peer_error error)
        in
        let* nonce = bytes "SSH peer-sync challenge" nonce in
        let* tracking_name =
          text_field "SSH peer-sync tracking name" tracking_name
        in
        let* head = bytes "SSH peer-sync head" head in
        let* head =
          Sync_node_id.of_bytes head
          |> Result.map_error (fun _ ->
              Invalid_request "SSH peer-sync head has wrong length")
        in
        let* request =
          make_request ~remote_root ~source ~destination ~nonce ~tracking_name
            ~head
        in
        let* canonical = request_payload request in
        if Encoding.equal canonical value then Ok request
        else invalid_request "SSH peer-sync request is noncanonical"
  | _ -> assert false

let response_payload = function
  | Accepted { proof; head_object } ->
      let* proof =
        Peer_sync.session_proof_payload proof
        |> Result.map_error (fun error -> Peer_error error)
      in
      array
        [
          Ok (Encoding.integer 1L);
          Ok (Encoding.integer 0L);
          Ok proof;
          Ok (Encoding.bytes (Store.Stored_object_id.to_raw_bytes head_object));
        ]
  | Rejected { code; detail } ->
      if
        String.length code > 128
        || String.length detail > max_remote_error_bytes
      then invalid_response "remote error exceeds its bound"
      else
        let* values =
          result_list [ text code; text detail ]
          |> Result.map_error (fun _ ->
              Invalid_response "remote error is not valid UTF-8")
        in
        let code, detail =
          match values with
          | [ code; detail ] -> (code, detail)
          | _ -> assert false
        in
        Encoding.array
          [ Encoding.integer 1L; Encoding.integer 1L; code; detail ]
        |> Result.map_error (fun error ->
            Invalid_response (Encoding.construction_error_to_string error))

let decode_response_payload value =
  let fields_response count =
    match value with
    | Encoding.Array values when List.length values = count -> Ok values
    | Encoding.Array _ ->
        invalid_response "SSH peer-sync response has the wrong field count"
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        invalid_response "SSH peer-sync response must be an array"
  in
  let integer_response kind = function
    | Encoding.Integer value -> Ok value
    | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        invalid_response (kind ^ " must be an integer")
  in
  let bytes_response kind = function
    | Encoding.Bytes value -> Ok value
    | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        invalid_response (kind ^ " must be bytes")
  in
  let text_response kind = function
    | Encoding.Text value -> Ok value
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        invalid_response (kind ^ " must be text")
  in
  let* values = fields_response 4 in
  match values with
  | [ version; kind; third; fourth ] ->
      let* version =
        integer_response "SSH peer-sync response version" version
      in
      if not (Int64.equal version 1L) then
        invalid_response "unsupported SSH peer-sync response version"
      else
        let* kind = integer_response "SSH peer-sync response kind" kind in
        if Int64.equal kind 0L then
          let* proof =
            Peer_sync.decode_session_proof_payload third
            |> Result.map_error (fun error -> Peer_error error)
          in
          let* raw = bytes_response "SSH peer-sync head object" fourth in
          let* head_object =
            match Store.Stored_object_id.of_raw_bytes raw with
            | Some value -> Ok value
            | None ->
                invalid_response "SSH peer-sync head object has wrong length"
          in
          let response = Accepted { proof; head_object } in
          let* canonical = response_payload response in
          if Encoding.equal canonical value then Ok response
          else invalid_response "SSH peer-sync response is noncanonical"
        else if Int64.equal kind 1L then
          let* code = text_response "SSH peer-sync remote error code" third in
          let* detail =
            text_response "SSH peer-sync remote error detail" fourth
          in
          if String.is_empty code || String.length code > 128 then
            invalid_response "SSH peer-sync remote error code is invalid"
          else if String.length detail > max_remote_error_bytes then
            invalid_response
              "SSH peer-sync remote error detail exceeds its bound"
          else
            let response = Rejected { code; detail } in
            let* canonical = response_payload response in
            if Encoding.equal canonical value then Ok response
            else invalid_response "SSH peer-sync response is noncanonical"
        else invalid_response "unknown SSH peer-sync response kind"
  | _ -> assert false

let frame value =
  let length = String.length value in
  if length < 1 || length > max_handshake_bytes then
    invalid_response "SSH peer-sync frame exceeds its bound"
  else
    let header = Bytes.create 8 in
    for index = 0 to 7 do
      let shift = (7 - index) * 8 in
      Bytes.set header index
        (Char.chr
           (Int64.to_int
              (Int64.logand 0xffL
                 (Int64.shift_right (Int64.of_int length) shift))))
    done;
    Ok (Bytes.unsafe_to_string header ^ value)

let write_value channel value =
  let* encoded = Encoding.encode value |> frame in
  try
    Out_channel.output_string channel encoded;
    Out_channel.flush channel;
    Ok ()
  with Sys_error detail -> Error (Transport_error detail)

let read_exact channel length =
  let bytes = Bytes.create length in
  let rec read offset =
    if offset = length then Ok (Bytes.unsafe_to_string bytes)
    else
      try
        let count = In_channel.input channel bytes offset (length - offset) in
        if count = 0 then
          Error (Transport_error "peer transport ended mid-frame")
        else read (offset + count)
      with
      | End_of_file -> Error (Transport_error "peer transport ended mid-frame")
      | Sys_error detail -> Error (Transport_error detail)
  in
  read 0

let read_value channel =
  let* header = read_exact channel 8 in
  let length = ref 0L in
  for index = 0 to 7 do
    length :=
      Int64.logor
        (Int64.shift_left !length 8)
        (Int64.of_int (Char.code header.[index]))
  done;
  if
    Int64.compare !length 1L < 0
    || Int64.compare !length (Int64.of_int max_handshake_bytes) > 0
  then Error (Transport_error "SSH peer-sync frame length is out of bounds")
  else
    let* raw = read_exact channel (Int64.to_int !length) in
    Encoding.decode raw
    |> Result.map_error (fun error ->
        Invalid_response (Encoding.decode_error_to_string error))

let write_request channel request =
  let* payload = request_payload request in
  write_value channel payload

let read_request channel =
  let* value = read_value channel in
  decode_request_payload value

let write_response channel response =
  let* payload = response_payload response in
  write_value channel payload

let read_response channel =
  let* value = read_value channel in
  decode_response_payload value

let write_remote_error channel ~code ~detail =
  write_response channel (Rejected { code; detail })

let ssh_arguments ~target ~known_hosts ?ssh_config () =
  if not (safe_ssh_target target) then
    Error (Transport_error "SSH target contains unsupported characters")
  else if not (safe_local_path known_hosts) then
    Error (Transport_error "known-hosts path must be absolute and bounded")
  else
    let* config =
      match ssh_config with
      | None -> Ok []
      | Some path when safe_local_path path -> Ok [ "-F"; path ]
      | Some _ ->
          Error (Transport_error "SSH config path must be absolute and bounded")
    in
    Ok
      (Array.of_list
         ([
            "ssh";
            "-T";
            "-o";
            "BatchMode=yes";
            "-o";
            "StrictHostKeyChecking=yes";
            "-o";
            "UserKnownHostsFile=" ^ known_hosts;
            "-o";
            "GlobalKnownHostsFile=none";
            "-o";
            "ClearAllForwardings=yes";
            "-o";
            "ForwardAgent=no";
            "-o";
            "RequestTTY=no";
          ]
         @ config
         @ [ "--"; target; remote_command ]))

let exchange_frame_length header =
  let value = ref 0L in
  for index = 0 to 7 do
    value :=
      Int64.logor
        (Int64.shift_left !value 8)
        (Int64.of_int (Char.code header.[index]))
  done;
  let maximum =
    Int64.add
      (Int64.of_int Store.max_object_bytes)
      (Int64.of_int Exchange.max_control_message_bytes)
  in
  if Int64.compare !value 1L < 0 || Int64.compare !value maximum > 0 then
    Error (Transport_error "peer exchange frame length is out of bounds")
  else Ok (Int64.to_int !value)

let read_message channel =
  let* header = read_exact channel 8 in
  let* length = exchange_frame_length header in
  let* payload = read_exact channel length in
  Exchange.decode (header ^ payload)
  |> Result.map_error (fun error -> Protocol_error error)

let write_message channel message =
  let* bytes =
    Exchange.encode message
    |> Result.map_error (fun error -> Protocol_error error)
  in
  try
    Out_channel.output_string channel bytes;
    Out_channel.flush channel;
    Ok ()
  with Sys_error detail -> Error (Transport_error detail)

let hello =
  Exchange.Hello
    {
      repository_format = Store.repository_format;
      supported_versions = [ Exchange.protocol_version ];
      required_features = Exchange.supported_required_features;
    }

let strict_ids identities =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) ->
        Store.Stored_object_id.compare left right < 0 && loop rest
  in
  loop identities

let chunks size values =
  let rec loop reversed = function
    | [] -> List.rev reversed
    | values ->
        let rec take count reversed = function
          | [] -> (List.rev reversed, [])
          | rest when count = 0 -> (List.rev reversed, rest)
          | value :: rest -> take (count - 1) (value :: reversed) rest
        in
        let page, rest = take size [] values in
        loop (page :: reversed) rest
  in
  loop [] values

let validate_want ~session_id ~sequence ~offered = function
  | Exchange.Want
      {
        session_id = actual_session;
        sequence = actual_sequence;
        object_ids;
        required_features;
      } ->
      if
        not
          (String.equal
             (Exchange.session_id_to_bytes session_id)
             (Exchange.session_id_to_bytes actual_session))
      then Error (Transport_error "peer Want uses another session")
      else if not (Int64.equal sequence actual_sequence) then
        Error (Transport_error "peer Want uses another inventory sequence")
      else if required_features <> Exchange.supported_required_features then
        Error (Transport_error "peer Want uses incompatible required features")
      else if not (strict_ids object_ids) then
        Error (Transport_error "peer Want object IDs are not strictly ordered")
      else if
        not
          (List.for_all
             (fun id -> List.exists (Store.Stored_object_id.equal id) offered)
             object_ids)
      then Error (Transport_error "peer Want requests an unoffered object")
      else Ok object_ids
  | Exchange.Hello _ | Exchange.Inventory _ | Exchange.Object _ | Exchange.End _
  | Exchange.Error_message _ ->
      Error (Transport_error "peer transport expected Want")

let serve_exchange ~source ~session_id ~object_ids ~input ~output =
  if List.length object_ids > Exchange.max_session_object_ids then
    Error (Transport_error "peer sync closure exceeds exchange object bound")
  else
    let* receiver =
      Exchange.initial_receiver
        ~object_byte_budget:Exchange.max_total_object_bytes
      |> Result.map_error (fun error -> Protocol_error error)
    in
    let* remote_hello = read_message input in
    let* _ =
      Exchange.accept_hello receiver remote_hello
      |> Result.map_error (fun error -> Protocol_error error)
    in
    let* () = write_message output hello in
    let pages = chunks Exchange.max_ids_per_page object_ids in
    let rec send_pages sequence object_sequence = function
      | [] ->
          write_message output
            (Exchange.End
               {
                 session_id;
                 status = Exchange.Complete;
                 required_features = Exchange.supported_required_features;
               })
      | page :: rest ->
          let inventory =
            Exchange.Inventory
              {
                session_id;
                sequence;
                final = rest = [];
                object_ids = page;
                required_features = Exchange.supported_required_features;
              }
          in
          let* () = write_message output inventory in
          let* want = read_message input in
          let* wanted =
            validate_want ~session_id ~sequence ~offered:page want
          in
          let rec send_objects sequence = function
            | [] -> Ok sequence
            | id :: rest ->
                let* object_ =
                  Exchange_store.object_message source ~session_id ~sequence id
                  |> Result.map_error (fun error -> Exchange_error error)
                in
                let* () = write_message output object_ in
                send_objects Int64.(add sequence 1L) rest
          in
          let* object_sequence = send_objects object_sequence wanted in
          send_pages Int64.(add sequence 1L) object_sequence rest
    in
    send_pages 0L 0L pages

let destination_missing destination id =
  if not (Sys.file_exists (Store.object_path destination id)) then Ok true
  else
    Store.get destination id
    |> Result.map (fun _ -> false)
    |> Result.map_error (fun error -> Peer_error (Peer_sync.Store_error error))

let fetch_exchange ?interrupt_after ~destination ~session_id ~input ~output () =
  let* receiver =
    Exchange.initial_receiver
      ~object_byte_budget:Exchange.max_total_object_bytes
    |> Result.map_error (fun error -> Protocol_error error)
  in
  let* () = write_message output hello in
  let* remote_hello = read_message input in
  let* receiver =
    Exchange.accept_hello receiver remote_hello
    |> Result.map_error (fun error -> Protocol_error error)
  in
  let interrupted = ref 0 in
  let rec receive receiver offered requested transferred offered_ids =
    let* inventory = read_message input in
    let* () =
      match inventory with
      | Exchange.Inventory { session_id = actual; _ }
        when String.equal
               (Exchange.session_id_to_bytes actual)
               (Exchange.session_id_to_bytes session_id) ->
          Ok ()
      | Exchange.Inventory _ ->
          Error (Transport_error "peer inventory uses another session")
      | Exchange.Hello _ | Exchange.Want _ | Exchange.Object _ | Exchange.End _
      | Exchange.Error_message _ ->
          Error (Transport_error "peer transport expected inventory")
    in
    let* receiver, offered_page =
      Exchange.accept_inventory receiver inventory
      |> Result.map_error (fun error -> Protocol_error error)
    in
    let sequence, final =
      match inventory with
      | Exchange.Inventory { sequence; final; _ } -> (sequence, final)
      | Exchange.Hello _ | Exchange.Want _ | Exchange.Object _ | Exchange.End _
      | Exchange.Error_message _ ->
          assert false
    in
    let rec select_missing reversed = function
      | [] -> Ok (List.rev reversed)
      | id :: rest ->
          let* missing = destination_missing destination id in
          select_missing (if missing then id :: reversed else reversed) rest
    in
    let* wanted = select_missing [] offered_page in
    let* receiver, want =
      Exchange.register_want receiver ~sequence wanted
      |> Result.map_error (fun error -> Protocol_error error)
    in
    let* () = write_message output want in
    let rec receive_objects receiver transferred = function
      | [] -> Ok (receiver, transferred)
      | _ :: rest ->
          if Option.equal Int.equal interrupt_after (Some !interrupted) then
            Error
              (Exchange_error (Exchange_store.Interrupted_after !interrupted))
          else
            let* object_ = read_message input in
            let* receiver, id =
              Exchange_store.receive_object destination receiver object_
              |> Result.map_error (fun error -> Exchange_error error)
            in
            incr interrupted;
            receive_objects receiver (id :: transferred) rest
    in
    let* receiver, transferred = receive_objects receiver transferred wanted in
    let offered = offered + List.length offered_page in
    let requested = requested + List.length wanted in
    let offered_ids = List.rev_append offered_page offered_ids in
    if final then
      let* end_message = read_message input in
      let* _ =
        Exchange.accept_end receiver end_message
        |> Result.map_error (fun error -> Protocol_error error)
      in
      Ok
        ( {
            Exchange_store.offered;
            requested;
            transferred = List.rev transferred;
          },
          List.rev offered_ids )
    else receive receiver offered requested transferred offered_ids
  in
  receive receiver 0 0 [] []

let add_identity identities identity =
  let key = Peer_id.to_bytes (Peer_sync.peer_id identity) in
  match Hashtbl.find_opt identities key with
  | None ->
      Hashtbl.add identities key identity;
      Ok ()
  | Some existing when Peer_sync.identity_equal existing identity -> Ok ()
  | Some _ ->
      Error (Invalid_response "peer identity appears with conflicting bytes")

let add_node nodes node =
  let key = Sync_node_id.to_bytes (Peer_sync.sync_node_id node) in
  match Hashtbl.find_opt nodes key with
  | None ->
      Hashtbl.add nodes key node;
      Ok ()
  | Some _ -> Error (Invalid_response "peer sync node appears more than once")

let inspect_metadata destination ~head_object offered =
  let identities = Hashtbl.create 32 in
  let nodes = Hashtbl.create 32 in
  let offered =
    if List.exists (Store.Stored_object_id.equal head_object) offered then
      offered
    else head_object :: offered
  in
  let rec inspect = function
    | [] -> Ok (identities, nodes)
    | id :: rest ->
        let* envelope =
          Store.get destination id
          |> Result.map_error (fun error ->
              Peer_error (Peer_sync.Store_error error))
        in
        let* () =
          let object_type = Envelope.object_type envelope in
          if object_type = Envelope.Peer_identity then
            let* identity =
              Peer_sync.decode_identity_payload (Envelope.payload envelope)
              |> Result.map_error (fun error -> Peer_error error)
            in
            add_identity identities identity
          else if object_type = Envelope.Peer_sync_node then
            let* node =
              Peer_sync.decode_sync_node_payload (Envelope.payload envelope)
              |> Result.map_error (fun error -> Peer_error error)
            in
            add_node nodes node
          else Ok ()
        in
        inspect rest
  in
  inspect offered

let graph_nodes ~nodes ~head =
  let rec visit seen ordered id =
    let key = Sync_node_id.to_bytes id in
    if Hashtbl.mem seen key then Ok (seen, ordered)
    else
      match Hashtbl.find_opt nodes key with
      | None ->
          Error (Invalid_response "peer sync closure omits a causal parent")
      | Some node ->
          Hashtbl.add seen key ();
          let* seen, ordered =
            List.fold_left
              (fun result parent ->
                let* seen, ordered = result in
                visit seen ordered parent)
              (Ok (seen, ordered))
              (Peer_sync.sync_node_parents node)
          in
          Ok (seen, node :: ordered)
  in
  let* _, ordered = visit (Hashtbl.create 32) [] head in
  Ok (List.rev ordered)

let import_closure destination ~contact ~head_object ~head offered =
  let* identities, nodes = inspect_metadata destination ~head_object offered in
  let* head_node =
    match Hashtbl.find_opt nodes (Sync_node_id.to_bytes head) with
    | Some node -> Ok node
    | None -> Error (Invalid_response "peer sync head object is absent")
  in
  if not (Sync_node_id.equal (Peer_sync.sync_node_id head_node) head) then
    Error (Invalid_response "peer sync head object does not match the request")
  else if
    not
      (Peer_id.equal
         (Peer_sync.sync_node_author head_node)
         (Peer_sync.peer_id (Peer_sync.contact_identity contact)))
  then Error (Peer_error Peer_sync.Contact_mismatch)
  else
    let* graph = graph_nodes ~nodes ~head in
    let source_identity = Peer_sync.contact_identity contact in
    let* () = add_identity identities source_identity in
    let* graph_identities =
      List.fold_left
        (fun result node ->
          let* values = result in
          match
            Hashtbl.find_opt identities
              (Peer_id.to_bytes (Peer_sync.sync_node_author node))
          with
          | Some identity -> Ok (identity :: values)
          | None ->
              Error
                (Invalid_response "peer sync closure omits an author identity"))
        (Ok []) graph
    in
    let graph_identities =
      List.sort_uniq
        (fun left right ->
          String.compare
            (Peer_id.to_bytes (Peer_sync.peer_id left))
            (Peer_id.to_bytes (Peer_sync.peer_id right)))
        graph_identities
    in
    let* () =
      List.fold_left
        (fun result identity ->
          let* () = result in
          Peer_sync.store_identity destination identity
          |> Result.map_error (fun error -> Peer_error error)
          |> Result.map (fun _ -> ()))
        (Ok ()) graph_identities
    in
    let* () =
      List.fold_left
        (fun result node ->
          let* () = result in
          Peer_sync.store_sync_node destination node
          |> Result.map_error (fun error -> Peer_error error)
          |> Result.map (fun _ -> ()))
        (Ok ()) graph
    in
    let snapshots =
      List.sort_uniq Store.Stored_object_id.compare
        (List.map
           (fun node ->
             Peer_sync.sync_node_snapshot node
             |> Yeokcham_snapshot.Snapshot.stored_object_id)
           graph)
    in
    List.fold_left
      (fun result snapshot ->
        let* () = result in
        Peer_sync.verify_sync_snapshot_closure destination
          (Yeokcham_snapshot.Snapshot.of_stored_object_id snapshot)
        |> Result.map_error (fun error -> Peer_error error))
      (Ok ()) snapshots

let serve_stream ~source ~source_identity ~source_private_key ~request ~input
    ~output =
  let* configured_source =
    Peer_sync.load_identity source (request_source request)
    |> Result.map_error (fun error -> Peer_error error)
  in
  if not (Peer_sync.identity_equal configured_source source_identity) then
    Error (Peer_error Peer_sync.Identity_mismatch)
  else
    let* head =
      Peer_sync.load_sync_node source (request_head request)
      |> Result.map_error (fun error -> Peer_error error)
    in
    if
      not
        (Peer_id.equal
           (Peer_sync.sync_node_author head)
           (Peer_sync.peer_id source_identity))
    then Error (Peer_error Peer_sync.Contact_mismatch)
    else
      let* transcript =
        Peer_sync.ssh_transcript
          ~tracking_name:(request_tracking_name request)
          ~head:(request_head request)
        |> Result.map_error (fun error -> Peer_error error)
      in
      let* unsigned =
        Peer_sync.make_unsigned_session
          ~repository_format:Store.repository_format ~initiator:source_identity
          ~responder:(request_destination request)
          ~nonce:(request_nonce request) ~transcript
        |> Result.map_error (fun error -> Peer_error error)
      in
      let* proof =
        Peer_sync.sign_session unsigned ~private_key:source_private_key
        |> Result.map_error (fun error -> Peer_error error)
      in
      let* object_ids, head_object =
        Peer_sync.sync_transfer_closure source (request_head request)
        |> Result.map_error (fun error -> Peer_error error)
      in
      let* () = write_response output (Accepted { proof; head_object }) in
      let* session_id =
        Peer_sync.ssh_session_id proof
        |> Result.map_error (fun error -> Peer_error error)
      in
      serve_exchange ~source ~session_id ~object_ids ~input ~output

let sync_stream ?interrupt_after ~destination ~contact ~destination_identity
    ~request ~input ~output () =
  let* configured_contact =
    Peer_sync.load_contact destination (Peer_sync.contact_id contact)
    |> Result.map_error (fun error -> Peer_error error)
  in
  let* configured_destination =
    Peer_sync.load_identity destination (Peer_sync.peer_id destination_identity)
    |> Result.map_error (fun error -> Peer_error error)
  in
  if not (Peer_sync.identity_equal configured_destination destination_identity)
  then Error (Peer_error Peer_sync.Identity_mismatch)
  else if
    not
      (Peer_id.equal (request_source request)
         (Peer_sync.peer_id (Peer_sync.contact_identity configured_contact)))
  then Error (Peer_error Peer_sync.Contact_mismatch)
  else if
    not
      (Peer_sync.identity_equal
         (request_destination request)
         configured_destination)
  then Error (Peer_error Peer_sync.Identity_mismatch)
  else
    let* () = write_request output request in
    let* response = read_response input in
    match response with
    | Rejected { code; detail } -> Error (Remote_error { code; detail })
    | Accepted { proof; head_object } ->
        let* transcript =
          Peer_sync.ssh_transcript
            ~tracking_name:(request_tracking_name request)
            ~head:(request_head request)
          |> Result.map_error (fun error -> Peer_error error)
        in
        let* () =
          Peer_sync.verify_session ~repository_format:Store.repository_format
            ~expected_signer:configured_contact
            ~expected_initiator:
              (Peer_sync.peer_id
                 (Peer_sync.contact_identity configured_contact))
            ~expected_responder:(Peer_sync.peer_id configured_destination)
            ~expected_nonce:(request_nonce request)
            ~expected_transcript:transcript proof
          |> Result.map_error (fun error -> Peer_error error)
        in
        let* session_id =
          Peer_sync.ssh_session_id proof
          |> Result.map_error (fun error -> Peer_error error)
        in
        let* outcome, offered =
          fetch_exchange ?interrupt_after ~destination ~session_id ~input
            ~output ()
        in
        let* () =
          import_closure destination ~contact:configured_contact ~head_object
            ~head:(request_head request) offered
        in
        let* decision =
          Peer_sync.advance_tracking destination ~contact:configured_contact
            ~tracking_name:(request_tracking_name request)
            ~head:(request_head request)
          |> Result.map_error (fun error -> Peer_error error)
        in
        Ok (outcome, decision)

let read_limited channel limit =
  let bytes = Bytes.create limit in
  try
    let count = In_channel.input channel bytes 0 limit in
    Bytes.sub_string bytes 0 count
  with End_of_file | Sys_error _ -> ""

let ssh_endpoint contact =
  let rec first = function
    | [] -> Error (Transport_error "contact has no SSH endpoint")
    | Peer_sync.Ssh { target; root } :: _ -> Ok (target, root)
    | Peer_sync.Local_path _ :: rest | Peer_sync.Relay _ :: rest -> first rest
  in
  first (Peer_sync.contact_endpoints contact)

let sync_ssh ?interrupt_after ~destination ~contact ~destination_identity
    ~known_hosts ?ssh_config ~nonce ~tracking_name ~head () =
  let* target, remote_root = ssh_endpoint contact in
  let* request =
    make_request ~remote_root
      ~source:(Peer_sync.peer_id (Peer_sync.contact_identity contact))
      ~destination:destination_identity ~nonce ~tracking_name ~head
  in
  let* arguments = ssh_arguments ~target ~known_hosts ?ssh_config () in
  try
    let input, output, error =
      Unix.open_process_args_full "ssh" arguments (Unix.environment ())
    in
    let result =
      Fun.protect
        ~finally:(fun () -> ())
        (fun () ->
          sync_stream ?interrupt_after ~destination ~contact
            ~destination_identity ~request ~input ~output ())
    in
    let stderr = read_limited error 4096 in
    let status = Unix.close_process_full (input, output, error) in
    if status = Unix.WEXITED 0 || Result.is_error result then result
    else
      Error
        (Transport_error
           ("SSH peer command failed"
           ^ if String.is_empty stderr then "" else ": " ^ stderr))
  with Unix.Unix_error (error, operation, argument) ->
    Error
      (Transport_error
         (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
