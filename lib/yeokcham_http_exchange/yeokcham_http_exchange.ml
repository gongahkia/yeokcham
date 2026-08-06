module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
module Object_id = Yeokcham_store.Stored_object_id
module Store = Yeokcham_store

type receiver_state = Await_hello | Open of Exchange.receiver

type server = {
  destination : Store.repository;
  object_byte_budget : int;
  receiver_state : receiver_state;
}

type endpoint = { address : Unix.inet_addr; port : int }

type error =
  | Invalid_endpoint of int
  | Transport_error of string
  | Timeout of string
  | Header_too_large of int
  | Body_too_large of int
  | Malformed_http of string
  | Unsupported_method of string
  | Unsupported_path of string
  | Unsupported_content_type of string option
  | Protocol_error of Exchange.error
  | Adapter_error of Exchange_store.error
  | Session_in_progress
  | Unexpected_client_message of string
  | Unexpected_response of string
  | Peer_rejected of { status : int; detail : string }
  | Interrupted_after of int
  | Invalid_transfer_input of string

type outcome = {
  offered : int;
  requested : int;
  transferred : Object_id.t list;
}

type request_value = {
  method_name : string;
  path : string;
  request_headers : (string * string) list;
  request_body : string;
}

type response_value = { status : int; response_body : string }

let max_header_bytes = 16 * 1024

let max_body_bytes =
  Store.max_object_bytes + Exchange.max_control_message_bytes + 8

let io_timeout_seconds = 5.0
let exchange_content_type = "application/vnd.yeokcham.exchange-v1"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_endpoint port -> Printf.sprintf "invalid HTTP port: %d" port
  | Transport_error detail -> "HTTP transport error: " ^ detail
  | Timeout operation -> "HTTP transport timed out during " ^ operation
  | Header_too_large size ->
      Printf.sprintf "HTTP header is %d bytes; limit is %d" size
        max_header_bytes
  | Body_too_large size ->
      Printf.sprintf "HTTP body is %d bytes; limit is %d" size max_body_bytes
  | Malformed_http detail -> "malformed HTTP: " ^ detail
  | Unsupported_method method_name -> "unsupported HTTP method: " ^ method_name
  | Unsupported_path path -> "unsupported HTTP path: " ^ path
  | Unsupported_content_type value ->
      "unsupported HTTP content type: " ^ Option.value value ~default:"absent"
  | Protocol_error error -> Exchange.error_to_string error
  | Adapter_error error -> Exchange_store.error_to_string error
  | Session_in_progress -> "HTTP exchange already has an active session"
  | Unexpected_client_message detail ->
      "unexpected HTTP exchange message: " ^ detail
  | Unexpected_response detail -> "unexpected HTTP exchange response: " ^ detail
  | Peer_rejected { status; detail } ->
      Printf.sprintf "HTTP peer rejected request (%d): %s" status detail
  | Interrupted_after count ->
      Printf.sprintf "HTTP exchange interrupted after %d publications" count
  | Invalid_transfer_input detail -> "invalid HTTP exchange input: " ^ detail

let lowercase value = String.lowercase_ascii value

let find_marker input marker =
  let input_length = String.length input in
  let marker_length = String.length marker in
  let rec loop index =
    if index + marker_length > input_length then None
    else if String.sub input index marker_length = marker then Some index
    else loop (index + 1)
  in
  loop 0

let strip_cr line =
  let length = String.length line in
  if length > 0 && Char.equal line.[length - 1] '\r' then
    String.sub line 0 (length - 1)
  else line

let split_once separator value =
  match String.index_opt value separator with
  | None -> None
  | Some index ->
      Some
        ( String.sub value 0 index,
          String.sub value (index + 1) (String.length value - index - 1) )

let parse_headers lines =
  let rec loop values = function
    | [] -> Ok (List.rev values)
    | line :: rest -> (
        match split_once ':' line with
        | None -> Error (Malformed_http "header is missing a colon")
        | Some (name, value) ->
            if String.length name = 0 then
              Error (Malformed_http "empty header name")
            else loop ((lowercase name, String.trim value) :: values) rest)
  in
  loop [] lines

let content_length headers =
  let values =
    List.filter_map
      (fun (name, value) ->
        if String.equal name "content-length" then Some value else None)
      headers
  in
  match values with
  | [ value ] -> (
      match int_of_string_opt value with
      | Some length
        when length >= 0 && String.equal value (string_of_int length) ->
          Ok length
      | _ -> Error (Malformed_http "invalid Content-Length"))
  | [] -> Error (Malformed_http "missing Content-Length")
  | _ -> Error (Malformed_http "duplicate Content-Length")

let header_value name headers = List.assoc_opt (lowercase name) headers

let parse_request input =
  match find_marker input "\r\n\r\n" with
  | None -> Error (Malformed_http "missing header terminator")
  | Some header_end -> (
      let header_size = header_end + 4 in
      if header_size > max_header_bytes then
        Error (Header_too_large header_size)
      else
        let header = String.sub input 0 header_end in
        let lines = String.split_on_char '\n' header |> List.map strip_cr in
        match lines with
        | request_line :: header_lines -> (
            match String.split_on_char ' ' request_line with
            | [ method_name; path; "HTTP/1.1" ] ->
                let* headers = parse_headers header_lines in
                let* length = content_length headers in
                if length > max_body_bytes then Error (Body_too_large length)
                else if String.length input <> header_size + length then
                  Error (Malformed_http "Content-Length does not match body")
                else
                  Ok
                    {
                      method_name;
                      path;
                      request_headers = headers;
                      request_body = String.sub input header_size length;
                    }
            | _ -> Error (Malformed_http "invalid request line"))
        | [] -> Error (Malformed_http "empty request"))

let parse_response input =
  match find_marker input "\r\n\r\n" with
  | None -> Error (Malformed_http "missing response header terminator")
  | Some header_end -> (
      let header_size = header_end + 4 in
      if header_size > max_header_bytes then
        Error (Header_too_large header_size)
      else
        let header = String.sub input 0 header_end in
        let lines = String.split_on_char '\n' header |> List.map strip_cr in
        match lines with
        | status_line :: header_lines -> (
            match String.split_on_char ' ' status_line with
            | "HTTP/1.1" :: status :: _ -> (
                match int_of_string_opt status with
                | None -> Error (Malformed_http "invalid response status")
                | Some status ->
                    let* headers = parse_headers header_lines in
                    let* length = content_length headers in
                    if length > max_body_bytes then
                      Error (Body_too_large length)
                    else if String.length input <> header_size + length then
                      Error (Malformed_http "response Content-Length mismatch")
                    else
                      Ok
                        {
                          status;
                          response_body = String.sub input header_size length;
                        })
            | _ -> Error (Malformed_http "invalid response line"))
        | [] -> Error (Malformed_http "empty response"))

let render_response ~status ~reason ?content_type body =
  let content_type =
    match content_type with
    | None -> ""
    | Some value -> "Content-Type: " ^ value ^ "\r\n"
  in
  Printf.sprintf
    "HTTP/1.1 %d %s\r\nContent-Length: %d\r\n%sConnection: close\r\n\r\n%s"
    status reason (String.length body) content_type body

let render_request body =
  Printf.sprintf
    "POST /v1/exchange HTTP/1.1\r\n\
     Host: yeokcham.local\r\n\
     Content-Type: %s\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n\
     %s"
    exchange_content_type (String.length body) body

let create_server ?(object_byte_budget = Exchange.max_total_object_bytes)
    destination =
  if object_byte_budget < 0 then
    Error (Invalid_transfer_input "object byte budget must be non-negative")
  else Ok { destination; object_byte_budget; receiver_state = Await_hello }

let destination_missing destination object_id =
  let path = Store.object_path destination object_id in
  if not (Sys.file_exists path) then Ok true
  else
    Store.get destination object_id
    |> Result.map (fun _ -> false)
    |> Result.map_error (fun error ->
        Adapter_error (Exchange_store.Destination_store_error error))

let check_want ~session_id ~sequence expected = function
  | Exchange.Want
      { session_id = actual; sequence = actual_sequence; object_ids; _ }
    when String.equal
           (Exchange.session_id_to_bytes actual)
           (Exchange.session_id_to_bytes session_id)
         && Int64.equal actual_sequence sequence
         && List.length object_ids = List.length expected
         && List.for_all2 Object_id.equal object_ids expected ->
      Ok ()
  | Exchange.Want _ -> Error (Unexpected_response "Want changed after decoding")
  | Exchange.Hello _ | Exchange.Inventory _ | Exchange.Object _ | Exchange.End _
  | Exchange.Error_message _ ->
      Error (Unexpected_response "expected Want")

let server_message server message =
  match (server.receiver_state, message) with
  | Await_hello, Exchange.Hello _ ->
      let* receiver =
        Exchange.initial_receiver ~object_byte_budget:server.object_byte_budget
        |> Result.map_error (fun error -> Protocol_error error)
      in
      let* receiver =
        Exchange.accept_hello receiver message
        |> Result.map_error (fun error -> Protocol_error error)
      in
      Ok ({ server with receiver_state = Open receiver }, None)
  | Await_hello, _ -> Error (Protocol_error Exchange.Hello_required)
  | Open _, Exchange.Hello _ -> Error Session_in_progress
  | Open receiver, Exchange.Inventory { session_id; sequence; _ } ->
      let* receiver, offered =
        Exchange.accept_inventory receiver message
        |> Result.map_error (fun error -> Protocol_error error)
      in
      let rec missing values = function
        | [] -> Ok (List.rev values)
        | object_id :: rest ->
            let* absent = destination_missing server.destination object_id in
            missing (if absent then object_id :: values else values) rest
      in
      let* wanted = missing [] offered in
      let* receiver, want =
        Exchange.register_want receiver ~sequence wanted
        |> Result.map_error (fun error -> Protocol_error error)
      in
      let* want_bytes =
        Exchange.encode want
        |> Result.map_error (fun error -> Protocol_error error)
      in
      let* decoded_want =
        Exchange.decode want_bytes
        |> Result.map_error (fun error -> Protocol_error error)
      in
      let* () = check_want ~session_id ~sequence wanted decoded_want in
      Ok ({ server with receiver_state = Open receiver }, Some want_bytes)
  | Open receiver, Exchange.Object _ ->
      let* receiver, _ =
        Exchange_store.receive_object server.destination receiver message
        |> Result.map_error (fun error -> Adapter_error error)
      in
      Ok ({ server with receiver_state = Open receiver }, None)
  | Open receiver, Exchange.End _ ->
      let* _ =
        Exchange.accept_end receiver message
        |> Result.map_error (fun error -> Protocol_error error)
      in
      Ok ({ server with receiver_state = Await_hello }, None)
  | Open _, Exchange.Want _ ->
      Error (Unexpected_client_message "client cannot send Want")
  | Open _, Exchange.Error_message _ ->
      Error (Unexpected_client_message "client cannot send Error")

let handle server input =
  let* request = parse_request input in
  if not (String.equal request.method_name "POST") then
    Error (Unsupported_method request.method_name)
  else if not (String.equal request.path "/v1/exchange") then
    Error (Unsupported_path request.path)
  else if
    not
      (Option.exists
         (String.equal exchange_content_type)
         (header_value "content-type" request.request_headers))
  then
    Error
      (Unsupported_content_type
         (header_value "content-type" request.request_headers))
  else
    let* message =
      Exchange.decode request.request_body
      |> Result.map_error (fun error -> Protocol_error error)
    in
    let* server, response = server_message server message in
    match response with
    | None -> Ok (server, render_response ~status:204 ~reason:"No Content" "")
    | Some body ->
        Ok
          ( server,
            render_response ~status:200 ~reason:"OK"
              ~content_type:exchange_content_type body )

let wait_readable descriptor =
  try
    match Unix.select [ descriptor ] [] [] io_timeout_seconds with
    | _ :: _, _, _ -> Ok ()
    | [], _, _ -> Error (Timeout "read")
  with Unix.Unix_error (error, _, _) ->
    Error (Transport_error (Unix.error_message error))

let wait_writable descriptor =
  try
    match Unix.select [] [ descriptor ] [] io_timeout_seconds with
    | _, _ :: _, _ -> Ok ()
    | _, [], _ -> Error (Timeout "write")
  with Unix.Unix_error (error, _, _) ->
    Error (Transport_error (Unix.error_message error))

let write_all descriptor bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      let* () = wait_writable descriptor in
      try
        let written =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if written = 0 then Error (Transport_error "write returned zero bytes")
        else loop (offset + written)
      with Unix.Unix_error (error, _, _) ->
        Error (Transport_error (Unix.error_message error))
  in
  loop 0

let read_all descriptor =
  let buffer = Bytes.create 65_536 in
  let output = Buffer.create 4096 in
  let rec loop total =
    if total > max_header_bytes + max_body_bytes then
      Error (Body_too_large total)
    else
      let* () = wait_readable descriptor in
      try
        let read = Unix.read descriptor buffer 0 (Bytes.length buffer) in
        if read = 0 then Ok (Buffer.contents output)
        else (
          Buffer.add_subbytes output buffer 0 read;
          loop (total + read))
      with Unix.Unix_error (error, _, _) ->
        Error (Transport_error (Unix.error_message error))
  in
  loop 0

let error_response error =
  render_response ~status:400 ~reason:"Bad Request" (error_to_string error)

let serve_once server descriptor =
  let result =
    let* input = read_all descriptor in
    handle server input
  in
  match result with
  | Ok (next, response) ->
      let* () = write_all descriptor response in
      Ok next
  | Error error ->
      let* () = write_all descriptor (error_response error) in
      Ok server

let endpoint ~address ~port =
  if port <= 0 || port > 65_535 then Error (Invalid_endpoint port)
  else Ok { address; port }

let request endpoint bytes =
  let descriptor = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
      try
        Unix.connect descriptor
          (Unix.ADDR_INET (endpoint.address, endpoint.port));
        let* () = write_all descriptor bytes in
        Unix.shutdown descriptor Unix.SHUTDOWN_SEND;
        read_all descriptor
      with Unix.Unix_error (error, _, _) ->
        Error (Transport_error (Unix.error_message error)))

let strictly_sorted_ids ids =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) ->
        Object_id.compare left right < 0 && loop rest
  in
  loop ids

let chunks size values =
  let rec take count values =
    if count = 0 then ([], values)
    else
      match values with
      | [] -> ([], [])
      | value :: rest ->
          let taken, remaining = take (count - 1) rest in
          (value :: taken, remaining)
  in
  let rec loop values =
    match values with
    | [] -> []
    | _ ->
        let page, rest = take size values in
        page :: loop rest
  in
  loop values

let response send message =
  let* frame =
    Exchange.encode message
    |> Result.map_error (fun error -> Protocol_error error)
  in
  let* raw = send (render_request frame) in
  let* response = parse_response raw in
  if response.status >= 400 then
    Error
      (Peer_rejected
         { status = response.status; detail = response.response_body })
  else Ok response

let expect_empty send message =
  let* response = response send message in
  if response.status = 204 && String.length response.response_body = 0 then
    Ok ()
  else Error (Unexpected_response "expected HTTP 204 with an empty body")

let transfer_with ?interrupt_after ~source ~send ~session_id ~object_ids () =
  if not (strictly_sorted_ids object_ids) then
    Error (Invalid_transfer_input "object IDs must be strictly ascending")
  else if List.length object_ids > Exchange.max_session_object_ids then
    Error (Invalid_transfer_input "object ID count exceeds the session limit")
  else
    let hello =
      Exchange.Hello
        {
          repository_format = Store.repository_format;
          supported_versions = [ Exchange.protocol_version ];
          required_features = Exchange.supported_required_features;
        }
    in
    let* () = expect_empty send hello in
    let rec transfer_pages object_sequence requested transferred page_index =
      function
      | [] ->
          let end_message =
            Exchange.End
              {
                session_id;
                status = Exchange.Complete;
                required_features = Exchange.supported_required_features;
              }
          in
          let* () = expect_empty send end_message in
          Ok
            {
              offered = List.length object_ids;
              requested;
              transferred = List.rev transferred;
            }
      | page :: rest ->
          let inventory =
            Exchange.Inventory
              {
                session_id;
                sequence = Int64.of_int page_index;
                final = rest = [];
                object_ids = page;
                required_features = Exchange.supported_required_features;
              }
          in
          let* inventory_response = response send inventory in
          if inventory_response.status <> 200 then
            Error (Unexpected_response "expected HTTP 200 Want response")
          else
            let* want =
              Exchange.decode inventory_response.response_body
              |> Result.map_error (fun error -> Protocol_error error)
            in
            let* () =
              match want with
              | Exchange.Want { object_ids = wanted; _ } ->
                  check_want ~session_id ~sequence:(Int64.of_int page_index)
                    wanted want
              | Exchange.Hello _ | Exchange.Inventory _ | Exchange.Object _
              | Exchange.End _ | Exchange.Error_message _ ->
                  Error (Unexpected_response "inventory response is not Want")
            in
            let wanted =
              match want with
              | Exchange.Want { object_ids; _ } -> object_ids
              | Exchange.Hello _ | Exchange.Inventory _ | Exchange.Object _
              | Exchange.End _ | Exchange.Error_message _ ->
                  []
            in
            let rec send_objects sequence transferred = function
              | [] -> Ok (sequence, transferred)
              | object_id :: rest ->
                  if
                    match interrupt_after with
                    | Some limit -> List.length transferred >= limit
                    | None -> false
                  then Error (Interrupted_after (List.length transferred))
                  else
                    let* object_message =
                      Exchange_store.object_message source ~session_id ~sequence
                        object_id
                      |> Result.map_error (fun error -> Adapter_error error)
                    in
                    let* () = expect_empty send object_message in
                    send_objects
                      Int64.(add sequence 1L)
                      (object_id :: transferred) rest
            in
            let* object_sequence, transferred =
              send_objects object_sequence transferred wanted
            in
            transfer_pages object_sequence
              (requested + List.length wanted)
              transferred (page_index + 1) rest
    in
    transfer_pages 0L 0 [] 0 (chunks Exchange.max_ids_per_page object_ids)

let transfer ?interrupt_after ~source ~endpoint ~session_id ~object_ids () =
  transfer_with ?interrupt_after ~source ~send:(request endpoint) ~session_id
    ~object_ids ()
