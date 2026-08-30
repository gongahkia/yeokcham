module Relay = Yeokcham_v4_relay
module Encoding = Yeokcham_encoding
module Access = Yeokcham_v4_relay_access

type error =
  | Invalid_listen of string
  | Io_error of { path : string; operation : string; message : string }
  | Relay_error of Relay.error

let max_header_bytes = 16 * 1024
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_listen value -> "invalid V4 relay listen address: " ^ value
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 relay HTTP %s %s: %s" operation path message
  | Relay_error error -> Relay.error_to_string error

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

let response descriptor status body =
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
       Content-Type: application/cbor\r\n\
       \r\n"
      status reason (String.length body)
  in
  write_all descriptor header;
  write_all descriptor body

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

let authorize ~root headers ~project scope =
  match bearer headers with
  | None -> Error `Unauthenticated
  | Some secret -> (
      match Access.load ~root with
      | Error _ -> Error `Unavailable
      | Ok registry -> (
          match
            Access.authorize
              ~now:(Int64.of_float (Unix.gettimeofday ()))
              ~secret ~repository:project ~scope registry
          with
          | Ok () -> Ok ()
          | Error
              ( Access.Invalid_secret | Access.Unknown_secret
              | Access.Expired_secret | Access.Revoked_secret ) ->
              Error `Unauthenticated
          | Error (Access.Wrong_repository | Access.Insufficient_scope) ->
              Error `Forbidden))

let handle relay ~access_root descriptor =
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
                match (route target, content_length) with
                | _, None -> response descriptor 400 ""
                | _, Some length when length < 0 -> response descriptor 400 ""
                | _, Some length when length > Relay.max_body_bytes ->
                    response descriptor 413 ""
                | Error (), Some _ -> response descriptor 404 ""
                | Ok (project, kind, id, query), Some length -> (
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
                                    | Ok () -> response descriptor 201 ""
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

let serve ~root ~listen =
  let* relay =
    Relay.open_repository ~root
    |> Result.map_error (fun error -> Relay_error error)
  in
  let* address, port = parse_listen listen in
  try
    let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt listener Unix.SO_REUSEADDR true;
    Unix.bind listener (Unix.ADDR_INET (address, port));
    Unix.listen listener 64;
    Fun.protect
      ~finally:(fun () -> close_noerr listener)
      (fun () ->
        while true do
          try
            let client, _ = Unix.accept listener in
            Fun.protect
              ~finally:(fun () -> close_noerr client)
              (fun () -> handle relay ~access_root:root client)
          with Unix.Unix_error _ -> ()
        done;
        Ok ())
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Io_error { path = listen; operation; message = Unix.error_message error })
