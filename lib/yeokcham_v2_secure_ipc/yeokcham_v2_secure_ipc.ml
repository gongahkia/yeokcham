module Encoding = Yeokcham_encoding
module Model = Yeokcham_v2_model
module Session_id = Model.Secure_runtime_session_id

type capability = Mls | Device_crypto | Mesh
type operation = Mls_operation | Device_crypto_operation | Mesh_operation
type result_kind = Completed | Refused

type hello = {
  hello_session_id : Session_id.t;
  hello_supported_versions : int64 list;
  hello_required_capabilities : capability list;
  hello_optional_capabilities : capability list;
  hello_mandatory_features : int64;
}

type hello_ack = {
  ack_session_id : Session_id.t;
  ack_selected_version : int64;
  ack_selected_capabilities : capability list;
  ack_mandatory_features : int64;
}

type negotiated = {
  negotiated_session_id : Session_id.t;
  negotiated_version : int64;
  negotiated_capabilities : capability list;
}

type request = {
  request_session_id : Session_id.t;
  request_sequence : int64;
  request_operation : operation;
  request_payload : string;
  request_mandatory_features : int64;
}

type response = {
  response_session_id : Session_id.t;
  response_sequence : int64;
  response_operation : operation;
  response_result : result_kind;
  response_payload : string;
  response_mandatory_features : int64;
}

type active_session = { active_negotiated : negotiated; next_sequence : int64 }

type server = {
  server_supported_versions : int64 list;
  server_capabilities : capability list;
  server_sessions : active_session list;
}

type message =
  | Hello of hello
  | Hello_ack of hello_ack
  | Request of request
  | Response of response

type error =
  | Invalid_session_id of Model.identity_error
  | Invalid_protocol_versions of string
  | Invalid_capabilities of string
  | Invalid_payload_size of int
  | Invalid_sequence of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_frame_version of int64
  | Unsupported_message_kind of int64
  | Invalid_message of string
  | Frame_too_large of int
  | Noncanonical_message
  | Incompatible_protocol
  | Missing_required_capability of capability
  | Acknowledgement_mismatch of string
  | Session_already_active of Session_id.t
  | Unknown_or_stale_session of Session_id.t
  | Sequence_mismatch of { expected : int64; actual : int64 }
  | Operation_not_negotiated of operation
  | Response_mismatch of string

let protocol_version = 1L
let supported_mandatory_features = 0L
let max_frame_bytes = 64 * 1024
let max_payload_bytes = 48 * 1024
let max_supported_versions = 32
let ( let* ) = Result.bind

let capability_to_string = function
  | Mls -> "mls"
  | Device_crypto -> "device-crypto"
  | Mesh -> "mesh"

let operation_to_string = function
  | Mls_operation -> "mls"
  | Device_crypto_operation -> "device-crypto"
  | Mesh_operation -> "mesh"

let operation_capability = function
  | Mls_operation -> Mls
  | Device_crypto_operation -> Device_crypto
  | Mesh_operation -> Mesh

let error_to_string = function
  | Invalid_session_id error -> Model.identity_error_to_string error
  | Invalid_protocol_versions detail ->
      "invalid secure IPC protocol versions: " ^ detail
  | Invalid_capabilities detail -> "invalid secure IPC capabilities: " ^ detail
  | Invalid_payload_size size ->
      Printf.sprintf "invalid secure IPC payload size: %d" size
  | Invalid_sequence sequence ->
      Printf.sprintf "invalid secure IPC sequence: %Ld" sequence
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid secure IPC mandatory feature bits: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported secure IPC mandatory feature bits: %Ld"
        features
  | Unsupported_frame_version version ->
      Printf.sprintf "unsupported secure IPC frame version: %Ld" version
  | Unsupported_message_kind kind ->
      Printf.sprintf "unsupported secure IPC message kind: %Ld" kind
  | Invalid_message detail -> "invalid secure IPC message: " ^ detail
  | Frame_too_large size ->
      Printf.sprintf "secure IPC frame is too large: %d" size
  | Noncanonical_message -> "secure IPC frame is noncanonical"
  | Incompatible_protocol -> "secure IPC peers have no compatible protocol"
  | Missing_required_capability capability ->
      "secure IPC peer lacks required capability: "
      ^ capability_to_string capability
  | Acknowledgement_mismatch detail ->
      "secure IPC acknowledgement does not match hello: " ^ detail
  | Session_already_active session ->
      "secure IPC session is already active: " ^ Session_id.to_hex session
  | Unknown_or_stale_session session ->
      "secure IPC session is unknown or stale: " ^ Session_id.to_hex session
  | Sequence_mismatch { expected; actual } ->
      Printf.sprintf "secure IPC sequence mismatch: expected %Ld, got %Ld"
        expected actual
  | Operation_not_negotiated operation ->
      "secure IPC operation was not negotiated: "
      ^ operation_to_string operation
  | Response_mismatch detail -> "secure IPC response mismatch: " ^ detail

let capability_code = function Mls -> 1L | Device_crypto -> 2L | Mesh -> 3L

let capability_of_code = function
  | 1L -> Ok Mls
  | 2L -> Ok Device_crypto
  | 3L -> Ok Mesh
  | code ->
      Error (Invalid_capabilities (Printf.sprintf "unknown code %Ld" code))

let operation_code = function
  | Mls_operation -> 1L
  | Device_crypto_operation -> 2L
  | Mesh_operation -> 3L

let operation_of_code = function
  | 1L -> Ok Mls_operation
  | 2L -> Ok Device_crypto_operation
  | 3L -> Ok Mesh_operation
  | code ->
      Error (Invalid_message (Printf.sprintf "unknown operation %Ld" code))

let result_code = function Completed -> 1L | Refused -> 2L

let result_of_code = function
  | 1L -> Ok Completed
  | 2L -> Ok Refused
  | code -> Error (Invalid_message (Printf.sprintf "unknown result %Ld" code))

let compare_capability left right =
  Int64.compare (capability_code left) (capability_code right)

let sorted_unique compare values =
  let rec loop previous = function
    | [] -> true
    | value :: rest -> (
        match previous with
        | Some previous when compare previous value >= 0 -> false
        | Some _ | None -> loop (Some value) rest)
  in
  loop None values

let capability_member capability capabilities =
  List.exists (fun value -> value = capability) capabilities

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let check_versions versions =
  if versions = [] then Error (Invalid_protocol_versions "must not be empty")
  else if List.length versions > max_supported_versions then
    Error (Invalid_protocol_versions "exceeds bounded version count")
  else if not (sorted_unique Int64.compare versions) then
    Error (Invalid_protocol_versions "must be sorted and unique")
  else if List.exists (fun version -> Int64.compare version 0L <= 0) versions
  then Error (Invalid_protocol_versions "must be positive")
  else Ok ()

let check_capability_lists ~required ~optional =
  if not (sorted_unique compare_capability required) then
    Error
      (Invalid_capabilities "required capabilities must be sorted and unique")
  else if not (sorted_unique compare_capability optional) then
    Error
      (Invalid_capabilities "optional capabilities must be sorted and unique")
  else if
    List.exists
      (fun capability -> capability_member capability optional)
      required
  then Error (Invalid_capabilities "required and optional capabilities overlap")
  else Ok ()

let check_payload payload =
  let size = String.length payload in
  if size > max_payload_bytes then Error (Invalid_payload_size size) else Ok ()

let make_hello ~session_id ~supported_versions ~required_capabilities
    ~optional_capabilities ~mandatory_features =
  let* () = check_versions supported_versions in
  let* () =
    check_capability_lists ~required:required_capabilities
      ~optional:optional_capabilities
  in
  let* () = check_features mandatory_features in
  Ok
    {
      hello_session_id = session_id;
      hello_supported_versions = supported_versions;
      hello_required_capabilities = required_capabilities;
      hello_optional_capabilities = optional_capabilities;
      hello_mandatory_features = mandatory_features;
    }

let make_server ~supported_versions ~capabilities =
  let* () = check_versions supported_versions in
  let* () = check_capability_lists ~required:capabilities ~optional:[] in
  Ok
    {
      server_supported_versions = supported_versions;
      server_capabilities = capabilities;
      server_sessions = [];
    }

let highest_common_version left right =
  match
    List.filter (fun version -> List.mem version right) left |> List.rev
  with
  | version :: _ -> Some version
  | [] -> None

let selected_capabilities server hello =
  let requested =
    List.sort_uniq compare_capability
      (hello.hello_required_capabilities @ hello.hello_optional_capabilities)
  in
  List.filter
    (fun capability -> capability_member capability server.server_capabilities)
    requested

let negotiate server hello =
  let* version =
    match
      highest_common_version hello.hello_supported_versions
        server.server_supported_versions
    with
    | Some version -> Ok version
    | None -> Error Incompatible_protocol
  in
  let selected = selected_capabilities server hello in
  let* () =
    match
      List.find_opt
        (fun capability -> not (capability_member capability selected))
        hello.hello_required_capabilities
    with
    | Some capability -> Error (Missing_required_capability capability)
    | None -> Ok ()
  in
  Ok
    {
      negotiated_session_id = hello.hello_session_id;
      negotiated_version = version;
      negotiated_capabilities = selected;
    }

let active_session session server =
  List.find_opt
    (fun active ->
      Session_id.equal active.active_negotiated.negotiated_session_id session)
    server.server_sessions

let accept_hello server hello =
  match active_session hello.hello_session_id server with
  | Some _ -> Error (Session_already_active hello.hello_session_id)
  | None ->
      let* negotiated = negotiate server hello in
      let acknowledgement =
        {
          ack_session_id = negotiated.negotiated_session_id;
          ack_selected_version = negotiated.negotiated_version;
          ack_selected_capabilities = negotiated.negotiated_capabilities;
          ack_mandatory_features = 0L;
        }
      in
      Ok
        ( {
            server with
            server_sessions =
              { active_negotiated = negotiated; next_sequence = 0L }
              :: server.server_sessions;
          },
          acknowledgement )

let validate_hello_ack ~hello acknowledgement =
  let* () = check_features acknowledgement.ack_mandatory_features in
  if
    not (Session_id.equal hello.hello_session_id acknowledgement.ack_session_id)
  then Error (Acknowledgement_mismatch "session ID")
  else if
    not
      (List.mem acknowledgement.ack_selected_version
         hello.hello_supported_versions)
  then Error (Acknowledgement_mismatch "selected protocol version")
  else if
    not
      (sorted_unique compare_capability
         acknowledgement.ack_selected_capabilities)
  then
    Error (Acknowledgement_mismatch "selected capabilities are not canonical")
  else
    let requested =
      hello.hello_required_capabilities @ hello.hello_optional_capabilities
    in
    let* () =
      match
        List.find_opt
          (fun capability -> not (capability_member capability requested))
          acknowledgement.ack_selected_capabilities
      with
      | Some capability ->
          Error
            (Acknowledgement_mismatch
               ("unexpected capability " ^ capability_to_string capability))
      | None -> Ok ()
    in
    let* () =
      match
        List.find_opt
          (fun capability ->
            not
              (capability_member capability
                 acknowledgement.ack_selected_capabilities))
          hello.hello_required_capabilities
      with
      | Some capability -> Error (Missing_required_capability capability)
      | None -> Ok ()
    in
    Ok
      {
        negotiated_session_id = acknowledgement.ack_session_id;
        negotiated_version = acknowledgement.ack_selected_version;
        negotiated_capabilities = acknowledgement.ack_selected_capabilities;
      }

let make_request ~negotiated ~sequence ~operation ~payload ~mandatory_features =
  if Int64.compare sequence 0L < 0 then Error (Invalid_sequence sequence)
  else
    let* () = check_payload payload in
    let* () = check_features mandatory_features in
    if
      not
        (capability_member
           (operation_capability operation)
           negotiated.negotiated_capabilities)
    then Error (Operation_not_negotiated operation)
    else
      Ok
        {
          request_session_id = negotiated.negotiated_session_id;
          request_sequence = sequence;
          request_operation = operation;
          request_payload = payload;
          request_mandatory_features = mandatory_features;
        }

let make_response ~request ~result ~payload ~mandatory_features =
  let* () = check_payload payload in
  let* () = check_features mandatory_features in
  Ok
    {
      response_session_id = request.request_session_id;
      response_sequence = request.request_sequence;
      response_operation = request.request_operation;
      response_result = result;
      response_payload = payload;
      response_mandatory_features = mandatory_features;
    }

let accept_request server request =
  let* () = check_features request.request_mandatory_features in
  let* () = check_payload request.request_payload in
  if Int64.compare request.request_sequence 0L < 0 then
    Error (Invalid_sequence request.request_sequence)
  else
    match active_session request.request_session_id server with
    | None -> Error (Unknown_or_stale_session request.request_session_id)
    | Some active ->
        if not (Int64.equal active.next_sequence request.request_sequence) then
          Error
            (Sequence_mismatch
               {
                 expected = active.next_sequence;
                 actual = request.request_sequence;
               })
        else if
          not
            (capability_member
               (operation_capability request.request_operation)
               active.active_negotiated.negotiated_capabilities)
        then Error (Operation_not_negotiated request.request_operation)
        else
          let replacement =
            { active with next_sequence = Int64.succ active.next_sequence }
          in
          Ok
            {
              server with
              server_sessions =
                List.map
                  (fun candidate ->
                    if
                      Session_id.equal
                        candidate.active_negotiated.negotiated_session_id
                        request.request_session_id
                    then replacement
                    else candidate)
                  server.server_sessions;
            }

let validate_response ~request response =
  let* () = check_features response.response_mandatory_features in
  let* () = check_payload response.response_payload in
  if
    not
      (Session_id.equal request.request_session_id response.response_session_id)
  then Error (Response_mismatch "session ID")
  else if not (Int64.equal request.request_sequence response.response_sequence)
  then Error (Response_mismatch "sequence")
  else if request.request_operation <> response.response_operation then
    Error (Response_mismatch "operation")
  else Ok ()

let value_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_message (Encoding.construction_error_to_string error))

let value_capabilities capabilities =
  List.map
    (fun capability -> Encoding.integer (capability_code capability))
    capabilities
  |> value_array

let hello_value hello =
  let* versions =
    List.map Encoding.integer hello.hello_supported_versions |> value_array
  in
  let* required = value_capabilities hello.hello_required_capabilities in
  let* optional = value_capabilities hello.hello_optional_capabilities in
  value_array
    [
      Encoding.bytes (Session_id.to_bytes hello.hello_session_id);
      versions;
      required;
      optional;
    ]

let acknowledgement_value acknowledgement =
  let* capabilities =
    value_capabilities acknowledgement.ack_selected_capabilities
  in
  value_array
    [
      Encoding.bytes (Session_id.to_bytes acknowledgement.ack_session_id);
      Encoding.integer acknowledgement.ack_selected_version;
      capabilities;
    ]

let request_value request =
  value_array
    [
      Encoding.bytes (Session_id.to_bytes request.request_session_id);
      Encoding.integer request.request_sequence;
      Encoding.integer (operation_code request.request_operation);
      Encoding.bytes request.request_payload;
    ]

let response_value response =
  value_array
    [
      Encoding.bytes (Session_id.to_bytes response.response_session_id);
      Encoding.integer response.response_sequence;
      Encoding.integer (operation_code response.response_operation);
      Encoding.integer (result_code response.response_result);
      Encoding.bytes response.response_payload;
    ]

let message_value = function
  | Hello hello ->
      let* body = hello_value hello in
      value_array
        [
          Encoding.integer protocol_version;
          Encoding.integer 1L;
          body;
          Encoding.integer hello.hello_mandatory_features;
        ]
  | Hello_ack acknowledgement ->
      let* body = acknowledgement_value acknowledgement in
      value_array
        [
          Encoding.integer protocol_version;
          Encoding.integer 2L;
          body;
          Encoding.integer acknowledgement.ack_mandatory_features;
        ]
  | Request request ->
      let* body = request_value request in
      value_array
        [
          Encoding.integer protocol_version;
          Encoding.integer 3L;
          body;
          Encoding.integer request.request_mandatory_features;
        ]
  | Response response ->
      let* body = response_value response in
      value_array
        [
          Encoding.integer protocol_version;
          Encoding.integer 4L;
          body;
          Encoding.integer response.response_mandatory_features;
        ]

let encode message =
  match message_value message with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let array name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be an array"))

let fields name count value =
  let* values = array name value in
  if List.length values = count then Ok values
  else Error (Invalid_message (name ^ " has wrong field count"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_message (name ^ " must be bytes"))

let session_id value =
  Session_id.of_bytes value
  |> Result.map_error (fun error -> Invalid_session_id error)

let decode_versions value =
  let* values = array "supported protocol versions" value in
  let* versions =
    List.fold_left
      (fun result value ->
        let* values = result in
        let* version = integer "protocol version" value in
        Ok (version :: values))
      (Ok []) values
  in
  let versions = List.rev versions in
  let* () = check_versions versions in
  Ok versions

let decode_capabilities name value =
  let* values = array name value in
  let* capabilities =
    List.fold_left
      (fun result value ->
        let* values = result in
        let* code = integer name value in
        let* capability = capability_of_code code in
        Ok (capability :: values))
      (Ok []) values
  in
  let capabilities = List.rev capabilities in
  if sorted_unique compare_capability capabilities then Ok capabilities
  else Error (Invalid_capabilities (name ^ " must be sorted and unique"))

let decode_hello body features =
  let* values = fields "hello" 4 body in
  match values with
  | [ session; versions; required; optional ] ->
      let* session = bytes "hello session ID" session in
      let* session_id = session_id session in
      let* versions = decode_versions versions in
      let* required = decode_capabilities "required capabilities" required in
      let* optional = decode_capabilities "optional capabilities" optional in
      make_hello ~session_id ~supported_versions:versions
        ~required_capabilities:required ~optional_capabilities:optional
        ~mandatory_features:features
  | _ -> assert false

let decode_acknowledgement body features =
  let* values = fields "hello acknowledgement" 3 body in
  match values with
  | [ session; version; capabilities ] ->
      let* session = bytes "hello acknowledgement session ID" session in
      let* ack_session_id = session_id session in
      let* ack_selected_version = integer "selected protocol version" version in
      if Int64.compare ack_selected_version 0L <= 0 then
        Error (Invalid_protocol_versions "selected version must be positive")
      else
        let* ack_selected_capabilities =
          decode_capabilities "selected capabilities" capabilities
        in
        let* () = check_features features in
        Ok
          {
            ack_session_id;
            ack_selected_version;
            ack_selected_capabilities;
            ack_mandatory_features = features;
          }
  | _ -> assert false

let decode_request body features =
  let* values = fields "request" 4 body in
  match values with
  | [ session; sequence; operation; payload ] ->
      let* session = bytes "request session ID" session in
      let* session_id = session_id session in
      let* sequence = integer "request sequence" sequence in
      let* operation = integer "request operation" operation in
      let* operation = operation_of_code operation in
      let* payload = bytes "request payload" payload in
      let negotiated =
        {
          negotiated_session_id = session_id;
          negotiated_version = protocol_version;
          negotiated_capabilities = [ operation_capability operation ];
        }
      in
      make_request ~negotiated ~sequence ~operation ~payload
        ~mandatory_features:features
  | _ -> assert false

let decode_response body features =
  let* values = fields "response" 5 body in
  match values with
  | [ session; sequence; operation; result; payload ] ->
      let* session = bytes "response session ID" session in
      let* session_id = session_id session in
      let* sequence = integer "response sequence" sequence in
      if Int64.compare sequence 0L < 0 then Error (Invalid_sequence sequence)
      else
        let* operation = integer "response operation" operation in
        let* operation = operation_of_code operation in
        let* result = integer "response result" result in
        let* result = result_of_code result in
        let* payload = bytes "response payload" payload in
        let* () = check_payload payload in
        let* () = check_features features in
        Ok
          {
            response_session_id = session_id;
            response_sequence = sequence;
            response_operation = operation;
            response_result = result;
            response_payload = payload;
            response_mandatory_features = features;
          }
  | _ -> assert false

let decode encoded =
  if String.length encoded > max_frame_bytes then
    Error (Frame_too_large (String.length encoded))
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_message (Encoding.decode_error_to_string error))
    in
    let* fields = fields "secure IPC frame" 4 value in
    match fields with
    | [ version; kind; body; features ] ->
        let* version = integer "frame version" version in
        if not (Int64.equal version protocol_version) then
          Error (Unsupported_frame_version version)
        else
          let* kind = integer "message kind" kind in
          let* features = integer "mandatory features" features in
          let* message =
            match kind with
            | 1L ->
                decode_hello body features
                |> Result.map (fun hello -> Hello hello)
            | 2L ->
                decode_acknowledgement body features
                |> Result.map (fun acknowledgement -> Hello_ack acknowledgement)
            | 3L ->
                decode_request body features
                |> Result.map (fun request -> Request request)
            | 4L ->
                decode_response body features
                |> Result.map (fun response -> Response response)
            | kind -> Error (Unsupported_message_kind kind)
          in
          if String.equal encoded (encode message) then Ok message
          else Error Noncanonical_message
    | _ -> assert false

type protocol_error = error

let protocol_error_to_string = error_to_string

module Transport = struct
  type error =
    | End_of_stream
    | Truncated_frame
    | Oversized_frame of int
    | Io_error of { operation : string; message : string }
    | Protocol_error of string

  let error_to_string = function
    | End_of_stream -> "secure IPC stream ended before a frame"
    | Truncated_frame -> "secure IPC stream ended in a frame"
    | Oversized_frame size ->
        Printf.sprintf "secure IPC stream frame is too large: %d" size
    | Io_error { operation; message } ->
        Printf.sprintf "secure IPC %s failed: %s" operation message
    | Protocol_error message -> message

  let write_all descriptor bytes =
    let rec write offset =
      if offset = Bytes.length bytes then Ok ()
      else
        try
          let count =
            Unix.write descriptor bytes offset (Bytes.length bytes - offset)
          in
          if count = 0 then
            Error
              (Io_error { operation = "write"; message = "zero-byte write" })
          else write (offset + count)
        with Unix.Unix_error (error, _, _) ->
          Error
            (Io_error
               { operation = "write"; message = Unix.error_message error })
    in
    write 0

  let write descriptor message =
    let encoded = encode message in
    let length = String.length encoded in
    if length > max_frame_bytes then Error (Oversized_frame length)
    else
      let header = Bytes.create 4 in
      Bytes.set header 0 (Char.chr ((length lsr 24) land 0xff));
      Bytes.set header 1 (Char.chr ((length lsr 16) land 0xff));
      Bytes.set header 2 (Char.chr ((length lsr 8) land 0xff));
      Bytes.set header 3 (Char.chr (length land 0xff));
      let* () = write_all descriptor header in
      write_all descriptor (Bytes.of_string encoded)

  let read_exact descriptor bytes ~header =
    let rec read offset =
      if offset = Bytes.length bytes then Ok ()
      else
        try
          let count =
            Unix.read descriptor bytes offset (Bytes.length bytes - offset)
          in
          if count = 0 then
            Error
              (if header && offset = 0 then End_of_stream else Truncated_frame)
          else read (offset + count)
        with Unix.Unix_error (error, _, _) ->
          Error
            (Io_error { operation = "read"; message = Unix.error_message error })
    in
    read 0

  let read descriptor =
    let header = Bytes.create 4 in
    let* () = read_exact descriptor header ~header:true in
    let length =
      (Char.code (Bytes.get header 0) lsl 24)
      lor (Char.code (Bytes.get header 1) lsl 16)
      lor (Char.code (Bytes.get header 2) lsl 8)
      lor Char.code (Bytes.get header 3)
    in
    if length > max_frame_bytes then Error (Oversized_frame length)
    else
      let frame = Bytes.create length in
      let* () = read_exact descriptor frame ~header:false in
      let decoded : (message, protocol_error) result =
        decode (Bytes.unsafe_to_string frame)
      in
      decoded
      |> Result.map_error (fun error ->
          Protocol_error (protocol_error_to_string error))
end
