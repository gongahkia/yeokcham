module Relay = Yeokcham_v4_relay
module Encoding = Yeokcham_encoding
module Access = Yeokcham_v4_relay_access
module Config = Yeokcham_v4_relay_config
module Ops = Yeokcham_v4_relay_ops
module Transfer = Yeokcham_v4_transport.V2
module Wire = Yeokcham_v4_transport.V2_wire

type error =
  | Invalid_listen of string
  | Io_error of { path : string; operation : string; message : string }
  | Relay_error of Relay.error
  | Operator_not_ready

let max_header_bytes = 16 * 1024
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_listen value -> "invalid V4 relay listen address: " ^ value
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 relay HTTP %s %s: %s" operation path message
  | Relay_error error -> Relay.error_to_string error
  | Operator_not_ready ->
      "V4 relay operator storage or credential registry is not ready"

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let parse_listen value =
  match String.split_on_char ':' value with
  | [ host; port ] -> (
      match int_of_string_opt port with
      | Some port when port > 0 && port <= 65535 -> (
          try Ok (Unix.inet_addr_of_string host, port)
          with Failure _ -> Error (Invalid_listen value))
      | _ -> Error (Invalid_listen value))
  | _ -> Error (Invalid_listen value)

let find_header_end value =
  let rec loop index =
    if index + 3 >= String.length value then None
    else if String.sub value index 4 = "\r\n\r\n" then Some index
    else loop (index + 1)
  in
  loop 0

let read_request descriptor =
  let buffer = Buffer.create 1024 in
  let scratch = Bytes.create 4096 in
  let rec headers () =
    match find_header_end (Buffer.contents buffer) with
    | Some ending -> Ok (ending, Buffer.contents buffer)
    | None when Buffer.length buffer >= max_header_bytes -> Error ()
    | None -> (
        try
          match Unix.read descriptor scratch 0 (Bytes.length scratch) with
          | 0 -> Error ()
          | count ->
              Buffer.add_subbytes buffer scratch 0 count;
              headers ()
        with Unix.Unix_error _ -> Error ())
  in
  match headers () with
  | Error () -> Error ()
  | Ok (ending, value) ->
      let header = String.sub value 0 ending in
      let remainder =
        String.sub value (ending + 4) (String.length value - ending - 4)
      in
      Ok (header, remainder)

let parse_headers header =
  match String.split_on_char '\n' header with
  | [] -> Error ()
  | request_line :: fields ->
      let request_line = String.trim request_line |> String.split_on_char ' ' in
      let fields =
        List.filter_map
          (fun field ->
            let field = String.trim field in
            match String.index_opt field ':' with
            | None -> None
            | Some index ->
                Some
                  ( String.sub field 0 index |> String.lowercase_ascii,
                    String.sub field (index + 1)
                      (String.length field - index - 1)
                    |> String.trim ))
          fields
      in
      Ok (request_line, fields)

let header fields name = List.assoc_opt (String.lowercase_ascii name) fields

let body descriptor remainder length =
  if length < 0 || length > Relay.max_body_bytes then Error ()
  else if String.length remainder > length then Error ()
  else
    let bytes = Bytes.create length in
    Bytes.blit_string remainder 0 bytes 0 (String.length remainder);
    let rec read offset =
      if offset = length then Ok (Bytes.unsafe_to_string bytes)
      else
        try
          match Unix.read descriptor bytes offset (length - offset) with
          | 0 -> Error ()
          | count -> read (offset + count)
        with Unix.Unix_error _ -> Error ()
    in
    read (String.length remainder)

let write_all descriptor bytes =
  let rec loop offset =
    if offset = String.length bytes then ()
    else
      try
        let count =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if count > 0 then loop (offset + count)
      with Unix.Unix_error _ -> ()
  in
  loop 0

type handled = { status : int; events : Ops.event list }

let response ?(content_type = "application/cbor") ?(events = []) descriptor
    status body =
  let reason =
    match status with
    | 200 -> "OK"
    | 201 -> "Created"
    | 204 -> "No Content"
    | 400 -> "Bad Request"
    | 401 -> "Unauthorized"
    | 403 -> "Forbidden"
    | 404 -> "Not Found"
    | 405 -> "Method Not Allowed"
    | 409 -> "Conflict"
    | 413 -> "Payload Too Large"
    | 503 -> "Service Unavailable"
    | _ -> "Internal Server Error"
  in
  let header =
    Printf.sprintf
      "HTTP/1.1 %d %s\r\n\
       Content-Length: %d\r\n\
       Connection: close\r\n\
       Content-Type: %s\r\n\
       \r\n"
      status reason (String.length body) content_type
  in
  write_all descriptor header;
  write_all descriptor body;
  { status; events }

let request_path target =
  match String.split_on_char '?' target with
  | [ path ] -> (path, [])
  | [ path; query ] ->
      let arguments =
        query |> String.split_on_char '&'
        |> List.filter_map (fun value ->
            match String.split_on_char '=' value with
            | [ key; value ] -> Some (key, value)
            | _ -> None)
      in
      (path, arguments)
  | _ -> ("", [])

let route target =
  let path, query = request_path target in
  let segments =
    path |> String.split_on_char '/' |> List.filter (fun value -> value <> "")
  in
  match segments with
  | [ "v1"; "repositories"; project; "objects"; id ] ->
      Ok (project, Relay.Object, id, query)
  | [ "v1"; "repositories"; project; "manifests"; id ] ->
      Ok (project, Relay.Manifest, id, query)
  | [ "v1"; "repositories"; project; "publications"; id ] ->
      Ok (project, Relay.Publication, id, query)
  | [ "v1"; "repositories"; project; "bootstraps"; id ] ->
      Ok (project, Relay.Bootstrap, id, query)
  | [ "v1"; "repositories"; project; "publications" ] ->
      Ok (project, Relay.Publication, "", query)
  | _ -> Error ()

type v2_route =
  | Capability of string
  | Uploads of string
  | Upload of string * string
  | Upload_segment of string * string * int * int * string
  | Upload_complete of string * string
  | Object_segment of string * string * int * int

let v2_route target =
  let path, query = request_path target in
  let segments =
    path |> String.split_on_char '/' |> List.filter (fun value -> value <> "")
  in
  let integer value =
    match int_of_string_opt value with
    | Some value when value >= 0 -> Some value
    | _ -> None
  in
  match segments with
  | [ "v2"; "repositories"; project; "capabilities" ] -> Ok (Capability project)
  | [ "v2"; "repositories"; project; "uploads" ] -> Ok (Uploads project)
  | [ "v2"; "repositories"; project; "uploads"; session_id ] ->
      Ok (Upload (project, session_id))
  | [ "v2"; "repositories"; project; "uploads"; session_id; "complete" ] ->
      Ok (Upload_complete (project, session_id))
  | [
   "v2";
   "repositories";
   project;
   "uploads";
   session_id;
   "segments";
   offset;
   length;
   raw_sha256;
  ] -> (
      match (integer offset, integer length) with
      | Some offset, Some length ->
          Ok (Upload_segment (project, session_id, offset, length, raw_sha256))
      | None, _ | _, None -> Error ())
  | [ "v2"; "repositories"; project; "objects"; object_id ] -> (
      match (List.assoc_opt "offset" query, List.assoc_opt "length" query) with
      | Some offset, Some length -> (
          match (integer offset, integer length) with
          | Some offset, Some length ->
              Ok (Object_segment (project, object_id, offset, length))
          | None, _ | _, None -> Error ())
      | None, _ | _, None -> Error ())
  | _ -> Error ()

let encode_list ids cursor =
  let ids =
    ids
    |> List.map (fun id -> Encoding.text id |> Result.get_ok)
    |> Encoding.array |> Result.get_ok
  in
  let cursor =
    match cursor with
    | None -> Encoding.null
    | Some value -> Encoding.text value |> Result.get_ok
  in
  Encoding.array [ ids; cursor ] |> Result.get_ok |> Encoding.encode

let bearer headers =
  match header headers "authorization" with
  | Some value when String.starts_with ~prefix:"Bearer " value ->
      Some (String.sub value 7 (String.length value - 7))
  | _ -> None

let required_scope method_ id kind =
  match method_ with
  | "PUT" when id <> "" -> Some Access.Write
  | "GET" when id <> "" -> Some Access.Read
  | "GET" when kind = Relay.Publication && id = "" -> Some Access.Read
  | _ -> None

let authorize_credential ~root headers ~project scope =
  match bearer headers with
  | None -> Error `Unauthenticated
  | Some secret -> (
      match Access.load ~root with
      | Error _ -> Error `Unavailable
      | Ok registry -> (
          match
            Access.authorize_credential
              ~now:(Int64.of_float (Unix.gettimeofday ()))
              ~secret ~repository:project ~scope registry
          with
          | Ok credential -> Ok (Access.credential_id credential)
          | Error
              ( Access.Invalid_secret | Access.Unknown_secret
              | Access.Expired_secret | Access.Revoked_secret ) ->
              Error `Unauthenticated
          | Error (Access.Wrong_repository | Access.Insufficient_scope) ->
              Error `Forbidden))

let authorize ~root headers ~project scope =
  authorize_credential ~root headers ~project scope |> Result.map (fun _ -> ())

let exact_array count = function
  | Encoding.Array values when List.length values = count -> Some values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      None

let nonnegative_int = function
  | Encoding.Integer value
    when Int64.compare value 0L >= 0
         && Int64.compare value (Int64.of_int max_int) <= 0 ->
      Some (Int64.to_int value)
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      None

let text_values = function
  | Encoding.Array values ->
      let rec loop reversed = function
        | [] -> Some (List.rev reversed)
        | Encoding.Text value :: rest -> loop (value :: reversed) rest
        | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _
          | Encoding.Map _ | Encoding.Bool _ | Encoding.Null )
          :: _ ->
            None
      in
      loop [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      None

let[@warning "-4"] decode_capability_offer bytes =
  match Encoding.decode bytes with
  | Ok value -> (
      match exact_array 2 value with
      | Some [ first; offered ] -> (
          match first with
          | Encoding.Bytes capability -> (
              match
                (Transfer.decode_capability capability, text_values offered)
              with
              | Ok capability, Some offered -> (
                  let validator =
                    Transfer.capability
                      ~versions:[ Transfer.protocol_version ]
                      ~zstd:true ~max_segment_bytes:Transfer.segment_bytes
                      ~max_in_flight:Transfer.default_parallelism ~missing:[]
                  in
                  match validator with
                  | Error _ -> None
                  | Ok validator ->
                      if
                        Result.is_ok
                          (Transfer.plan_missing ~offered
                             (Transfer.missing_objects validator))
                      then Some (capability, offered)
                      else None)
              | Error _, _ | _, None -> None)
          | _ -> None)
      | Some _ | None -> None)
  | Error _ -> None

let encode_capability capability = Transfer.encode_capability capability

let[@warning "-4"] decode_upload_start bytes =
  match Encoding.decode bytes with
  | Ok value -> (
      match exact_array 3 value with
      | Some [ first; raw_size; expiry ] -> (
          match first with
          | Encoding.Text object_id -> (
              match (nonnegative_int raw_size, nonnegative_int expiry) with
              | Some raw_size, Some expiry -> Some (object_id, raw_size, expiry)
              | None, _ | _, None -> None)
          | _ -> None)
      | Some _ | None -> None)
  | Error _ -> None

let missing_offers relay ~project offered =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | object_id :: rest -> (
        match Relay.get relay ~project ~kind:Relay.Object ~id:object_id with
        | Ok _ -> loop reversed rest
        | Error error when Relay.is_missing error ->
            loop (object_id :: reversed) rest
        | Error _ -> Error ())
  in
  loop [] offered

let v2_scope = function
  | Capability _ | Uploads _ | Upload _ | Upload_segment _ | Upload_complete _
    ->
      Access.Write
  | Object_segment _ -> Access.Read

let v2_project = function
  | Capability project
  | Uploads project
  | Upload (project, _)
  | Upload_segment (project, _, _, _, _)
  | Upload_complete (project, _)
  | Object_segment (project, _, _, _) ->
      project

let encode_session session = Transfer.encode_session session

let[@warning "-4"] handle_v2 relay ~access_root ~project_quota_bytes
    ~session_expiry_seconds descriptor ~headers ~method_ ~route ~length
    ~remainder =
  let project = v2_project route in
  match
    authorize_credential ~root:access_root headers ~project (v2_scope route)
  with
  | Error `Unauthenticated -> response descriptor 401 ""
  | Error `Forbidden -> response descriptor 403 ""
  | Error `Unavailable -> response descriptor 503 ""
  | Ok credential_id -> (
      match (route, method_) with
      | Capability _, "POST" -> (
          match body descriptor remainder length with
          | Error () -> response descriptor 400 ""
          | Ok bytes -> (
              match decode_capability_offer bytes with
              | None -> response descriptor 400 ""
              | Some (_, offered) -> (
                  match missing_offers relay ~project offered with
                  | Error () -> response descriptor 400 ""
                  | Ok missing -> (
                      match
                        Transfer.capability
                          ~versions:[ Transfer.protocol_version ]
                          ~zstd:true ~max_segment_bytes:Transfer.segment_bytes
                          ~max_in_flight:Transfer.default_parallelism ~missing
                      with
                      | Error _ -> response descriptor 400 ""
                      | Ok capability -> (
                          match encode_capability capability with
                          | Ok bytes -> response descriptor 200 bytes
                          | Error _ -> response descriptor 500 "")))))
      | Uploads _, "POST" -> (
          match body descriptor remainder length with
          | Error () -> response descriptor 400 ""
          | Ok bytes -> (
              match decode_upload_start bytes with
              | None -> response descriptor 400 ""
              | Some (object_id, raw_size, expiry) -> (
                  if expiry > session_expiry_seconds then
                    response descriptor 400 ""
                  else
                    match
                      Relay.V2.start_upload relay
                        ~now:(Int64.of_float (Unix.gettimeofday ()))
                        ~project ~object_id ~raw_size ~credential_id
                        ~expires_in:(Int64.of_int expiry) ~project_quota_bytes
                    with
                    | Error (Relay.V2.Transfer_error Transfer.Quota_exceeded) ->
                        response ~events:[ Ops.Quota_refused ] descriptor 400 ""
                    | Error _ -> response descriptor 400 ""
                    | Ok session -> (
                        match encode_session session with
                        | Ok bytes ->
                            response ~events:[ Ops.Session_started ] descriptor
                              201 bytes
                        | Error _ -> response descriptor 500 ""))))
      | Upload (project, session_id), "GET" when length = 0 -> (
          match
            Relay.V2.resume_upload relay
              ~now:(Int64.of_float (Unix.gettimeofday ()))
              ~project ~session_id ~credential_id
          with
          | Ok session -> (
              match encode_session session with
              | Ok bytes -> response descriptor 200 bytes
              | Error _ -> response descriptor 500 "")
          | Error error when Relay.V2.is_session_missing error ->
              response descriptor 404 ""
          | Error _ -> response descriptor 400 "")
      | ( Upload_segment (project, session_id, offset, raw_length, raw_sha256),
          "PUT" )
        when length <= Wire.max_compressed_segment_bytes -> (
          match body descriptor remainder length with
          | Error () -> response descriptor 400 ""
          | Ok compressed -> (
              match Wire.decompress ~raw_length compressed with
              | Error _ -> response descriptor 400 ""
              | Ok raw -> (
                  match
                    Relay.V2.receive_upload_segment relay
                      ~now:(Int64.of_float (Unix.gettimeofday ()))
                      ~project ~session_id ~credential_id ~offset
                      ~length:raw_length ~raw_sha256 ~bytes:raw
                  with
                  | Ok _ -> response descriptor 204 ""
                  | Error error when Relay.V2.is_session_missing error ->
                      response descriptor 404 ""
                  | Error _ -> response descriptor 400 "")))
      | Upload_segment _, "PUT" -> response descriptor 413 ""
      | Upload_complete (project, session_id), "POST" when length = 0 -> (
          match
            Relay.V2.complete_upload relay
              ~now:(Int64.of_float (Unix.gettimeofday ()))
              ~project ~session_id ~credential_id
          with
          | Ok () ->
              response
                ~events:[ Ops.Session_completed; Ops.Object_stored ]
                descriptor 201 ""
          | Error error when Relay.V2.is_session_missing error ->
              response descriptor 404 ""
          | Error _ -> response descriptor 400 "")
      | Object_segment (_, object_id, offset, raw_length), "GET" when length = 0
        -> (
          match Relay.get relay ~project ~kind:Relay.Object ~id:object_id with
          | Error error when Relay.is_missing error ->
              response descriptor 404 ""
          | Error _ -> response descriptor 400 ""
          | Ok object_bytes -> (
              match
                Transfer.object_offer ~project ~object_id
                  ~raw_size:(String.length object_bytes)
              with
              | Error _ -> response descriptor 400 ""
              | Ok offer -> (
                  match Transfer.partition offer with
                  | Error _ -> response descriptor 400 ""
                  | Ok ranges ->
                      if
                        List.exists
                          (fun range ->
                            Transfer.range_offset range = offset
                            && Transfer.range_length range = raw_length)
                          ranges
                      then
                        let raw = String.sub object_bytes offset raw_length in
                        match Wire.compress raw with
                        | Ok compressed -> response descriptor 200 compressed
                        | Error _ -> response descriptor 500 ""
                      else response descriptor 400 "")))
      | _ -> response descriptor 405 "")

let handle relay ~access_root ~project_quota_bytes ~session_expiry_seconds
    descriptor =
  match read_request descriptor with
  | Error () -> response descriptor 400 ""
  | Ok (header_bytes, remainder) -> (
      match parse_headers header_bytes with
      | Error () -> response descriptor 400 ""
      | Ok (request_line, headers) -> (
          match request_line with
          | [ method_; target; "HTTP/1.1" ] -> (
              let content_length =
                match header headers "content-length" with
                | None -> Some 0
                | Some value -> int_of_string_opt value
              in
              if Option.is_some (header headers "transfer-encoding") then
                response descriptor 400 ""
              else
                match (route target, v2_route target, content_length) with
                | _, _, None -> response descriptor 400 ""
                | _, _, Some length when length < 0 ->
                    response descriptor 400 ""
                | _, _, Some length when length > Relay.max_body_bytes ->
                    response descriptor 413 ""
                | Error (), Error (), Some _ -> response descriptor 404 ""
                | Error (), Ok route, Some length ->
                    handle_v2 relay ~access_root ~project_quota_bytes
                      ~session_expiry_seconds descriptor ~headers ~method_
                      ~route ~length ~remainder
                | Ok (project, kind, id, query), _, Some length -> (
                    match required_scope method_ id kind with
                    | None -> response descriptor 405 ""
                    | Some scope -> (
                        match
                          authorize ~root:access_root headers ~project scope
                        with
                        | Error `Unauthenticated -> response descriptor 401 ""
                        | Error `Forbidden -> response descriptor 403 ""
                        | Error `Unavailable -> response descriptor 503 ""
                        | Ok () -> (
                            match method_ with
                            | "PUT" when id <> "" -> (
                                match body descriptor remainder length with
                                | Error () -> response descriptor 400 ""
                                | Ok bytes -> (
                                    match
                                      Relay.create relay ~project ~kind ~id
                                        ~bytes
                                    with
                                    | Ok () ->
                                        let events =
                                          match kind with
                                          | Relay.Object ->
                                              [ Ops.Object_stored ]
                                          | Relay.Manifest | Relay.Publication
                                          | Relay.Bootstrap ->
                                              []
                                        in
                                        response ~events descriptor 201 ""
                                    | Error error ->
                                        if Relay.is_immutable_conflict error
                                        then response descriptor 409 ""
                                        else response descriptor 400 ""))
                            | "GET" when id <> "" && length = 0 -> (
                                match Relay.get relay ~project ~kind ~id with
                                | Ok bytes -> response descriptor 200 bytes
                                | Error error ->
                                    if Relay.is_missing error then
                                      response descriptor 404 ""
                                    else response descriptor 400 "")
                            | "GET"
                              when kind = Relay.Publication && id = ""
                                   && length = 0 -> (
                                let cursor = List.assoc_opt "cursor" query in
                                let limit =
                                  match List.assoc_opt "limit" query with
                                  | None -> Some Relay.max_page_size
                                  | Some value -> int_of_string_opt value
                                in
                                match limit with
                                | None -> response descriptor 400 ""
                                | Some limit -> (
                                    match
                                      Relay.list_publications relay ~project
                                        ~cursor ~limit
                                    with
                                    | Ok (ids, cursor) ->
                                        response descriptor 200
                                          (encode_list ids cursor)
                                    | Error _ -> response descriptor 400 ""))
                            | "GET" | "PUT" -> response descriptor 405 ""
                            | _ -> response descriptor 405 ""))))
          | _ -> response descriptor 400 ""))

let readiness_probe = ref 0

let next_readiness_probe path =
  let value = !readiness_probe in
  readiness_probe := value + 1;
  Filename.concat path
    (Printf.sprintf ".yeokcham-relay-readiness-%d-%d" (Unix.getpid ()) value)

let remove_probe path = try Unix.unlink path with Unix.Unix_error _ -> ()

let directory_state path =
  try
    let info = Unix.lstat path in
    if info.Unix.st_kind <> Unix.S_DIR then Ops.Not_directory
    else
      try
        Unix.access path [ Unix.R_OK; Unix.W_OK; Unix.X_OK ];
        let probe = next_readiness_probe path in
        Fun.protect
          ~finally:(fun () -> remove_probe probe)
          (fun () ->
            let descriptor =
              Unix.openfile probe
                [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
                0o600
            in
            Unix.close descriptor;
            Ops.Available)
      with Unix.Unix_error _ -> Ops.Not_writable
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ops.Missing
  | Unix.Unix_error _ -> Ops.Not_writable

let credential_registry_state root =
  match directory_state root with
  | Ops.Available -> (
      match Access.load ~root with
      | Ok _ -> Ops.Available
      | Error _ -> Ops.Invalid)
  | (Ops.Missing | Ops.Not_directory | Ops.Not_writable | Ops.Invalid) as state
    ->
      state

let current_readiness ~root ~access_root =
  Ops.assess_readiness ~storage:(directory_state root)
    ~credential_registry:(credential_registry_state access_root)

let require_readiness ~root ~access_root =
  match current_readiness ~root ~access_root with
  | Ops.Ready -> Ok ()
  | Ops.Not_ready _ -> Error Operator_not_ready

let open_listener listen =
  let* address, port = parse_listen listen in
  let descriptor = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  try
    Unix.setsockopt descriptor Unix.SO_REUSEADDR true;
    Unix.bind descriptor (Unix.ADDR_INET (address, port));
    Unix.listen descriptor 64;
    Ok descriptor
  with Unix.Unix_error (error, operation, _) ->
    close_noerr descriptor;
    Error
      (Io_error { path = listen; operation; message = Unix.error_message error })

let endpoint_request descriptor handler =
  match read_request descriptor with
  | Error () ->
      response ~content_type:"text/plain; charset=utf-8" descriptor 400 ""
  | Ok (header_bytes, remainder) -> (
      match parse_headers header_bytes with
      | Error () ->
          response ~content_type:"text/plain; charset=utf-8" descriptor 400 ""
      | Ok (request_line, headers) -> (
          let content_length =
            match header headers "content-length" with
            | None -> Some 0
            | Some value -> int_of_string_opt value
          in
          match (request_line, content_length) with
          | [ "GET"; target; "HTTP/1.1" ], Some 0
            when Option.is_none (header headers "transfer-encoding") -> (
              match handler target with
              | Some handled -> handled
              | None ->
                  response ~content_type:"text/plain; charset=utf-8" descriptor
                    404 "")
          | _ ->
              ignore remainder;
              response ~content_type:"text/plain; charset=utf-8" descriptor 400
                ""))

let handle_health ~root ~access_root descriptor =
  endpoint_request descriptor (function
    | "/healthz" ->
        Some
          (response ~content_type:"text/plain; charset=utf-8" descriptor 200
             "ok\n")
    | "/readyz" -> (
        match current_readiness ~root ~access_root with
        | Ops.Ready ->
            Some
              (response ~content_type:"text/plain; charset=utf-8" descriptor 200
                 "ready\n")
        | Ops.Not_ready _ ->
            Some
              (response ~content_type:"text/plain; charset=utf-8" descriptor 503
                 "not ready\n"))
    | _ -> None)

let handle_metrics counters descriptor =
  endpoint_request descriptor (function
    | "/metrics" ->
        Some
          (response ~content_type:"text/plain; version=0.0.4; charset=utf-8"
             descriptor 200 (Ops.prometheus !counters))
    | _ -> None)

let observe counters event =
  match Ops.record !counters event with
  | Ok next -> counters := next
  | Error _ -> ()

let observe_handled counters handled =
  let request_event =
    if handled.status >= 200 && handled.status < 400 then Ops.Request_succeeded
    else if handled.status >= 500 then Ops.Request_failed
    else Ops.Request_refused
  in
  observe counters request_event;
  List.iter (observe counters) handled.events

let cleanup_expired relay counters =
  match
    Relay.V2.cleanup_expired relay ~now:(Int64.of_float (Unix.gettimeofday ()))
  with
  | Ok { Relay.V2.expired_sessions; reclaimed_bytes } ->
      observe counters
        (Ops.Sessions_expired { count = expired_sessions; reclaimed_bytes })
  | Error _ -> ()

type listener_kind = Relay_listener | Health_listener | Metrics_listener

let serve_internal ~root ~listen ~health_listen ~metrics_listen ~access_root
    ~project_quota_bytes ~session_expiry_seconds =
  let* relay =
    Relay.open_repository ~root
    |> Result.map_error (fun error -> Relay_error error)
  in
  let* () = require_readiness ~root ~access_root in
  let* relay_listener = open_listener listen in
  let open_optional_listener = function
    | None -> Ok None
    | Some listen -> open_listener listen |> Result.map Option.some
  in
  match open_optional_listener health_listen with
  | Error error ->
      close_noerr relay_listener;
      Error error
  | Ok health_listener -> (
      match open_optional_listener metrics_listen with
      | Error error ->
          close_noerr relay_listener;
          Option.iter close_noerr health_listener;
          Error error
      | Ok metrics_listener ->
          let counters = ref Ops.zero in
          let listeners =
            [
              Some (relay_listener, Relay_listener);
              Option.map
                (fun listener -> (listener, Health_listener))
                health_listener;
              Option.map
                (fun listener -> (listener, Metrics_listener))
                metrics_listener;
            ]
            |> List.filter_map Fun.id
          in
          Fun.protect
            ~finally:(fun () ->
              close_noerr relay_listener;
              Option.iter close_noerr health_listener;
              Option.iter close_noerr metrics_listener)
            (fun () ->
              while true do
                cleanup_expired relay counters;
                let readable, _, _ =
                  Unix.select (List.map fst listeners) [] [] 1.0
                in
                List.iter
                  (fun listener ->
                    match
                      List.find_opt
                        (fun (value, _) -> value = listener)
                        listeners
                    with
                    | None -> ()
                    | Some (_, kind) -> (
                        try
                          let client, _ = Unix.accept listener in
                          Fun.protect
                            ~finally:(fun () -> close_noerr client)
                            (fun () ->
                              match kind with
                              | Relay_listener ->
                                  handle relay ~access_root ~project_quota_bytes
                                    ~session_expiry_seconds client
                                  |> observe_handled counters
                              | Health_listener ->
                                  ignore
                                    (handle_health ~root ~access_root client)
                              | Metrics_listener ->
                                  ignore (handle_metrics counters client))
                        with Unix.Unix_error _ -> ()))
                  readable
              done;
              Ok ()))

let serve ~root ~listen =
  serve_internal ~root ~listen ~health_listen:None ~metrics_listen:None
    ~access_root:root ~project_quota_bytes:Relay.V2.default_project_quota_bytes
    ~session_expiry_seconds:(Int64.to_int Relay.V2.default_expiry_seconds)

let serve_with_config config =
  serve_internal
    ~root:(Config.storage_root config)
    ~listen:(Config.listen config)
    ~health_listen:(Some (Config.health_listen config))
    ~metrics_listen:(Some (Config.metrics_listen config))
    ~access_root:(Config.credential_registry_root config)
    ~project_quota_bytes:(Config.project_quota_bytes config)
    ~session_expiry_seconds:(Config.session_expiry_seconds config)
