module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Object_store = Yeokcham_store
module Transport = Yeokcham_v1_transport

type client = { url : string; token : string }
type kind = Object | Manifest | Publication | Bootstrap

type error =
  | Invalid_url of string
  | Invalid_token
  | Invalid_identifier of string
  | Missing_curl
  | Command_failed of int
  | Unexpected_status of int
  | Response_too_large
  | Invalid_response of string
  | Test_interrupted_upload
  | Io_error of { path : string; operation : string; message : string }

type http_client_error = error

let max_response_bytes = 64 * 1024 * 1024
let max_page_size = 128
let curl = "/usr/bin/curl"
let test_enabled_environment = "YEOKCHAM_V1_TEST_TRANSPORT"
let test_ca_bundle_environment = "YEOKCHAM_V1_TEST_TRANSPORT_CA_BUNDLE"
let test_interrupt_upload_environment = "YEOKCHAM_V1_TEST_TRANSPORT_FAIL_PUT"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_url url -> "invalid V1 transport HTTPS URL: " ^ url
  | Invalid_token -> "invalid V1 transport bearer credential"
  | Invalid_identifier id -> "invalid V1 transport route identifier: " ^ id
  | Missing_curl -> "the V1 HTTPS transport client requires /usr/bin/curl"
  | Command_failed code ->
      Printf.sprintf "V1 HTTPS transport request failed with curl exit %d" code
  | Unexpected_status status ->
      Printf.sprintf "V1 relay returned unexpected HTTP status %d" status
  | Response_too_large -> "V1 relay response exceeds the configured limit"
  | Invalid_response detail -> "invalid V1 relay response: " ^ detail
  | Test_interrupted_upload -> "test-only V1 transport upload interruption"
  | Io_error { path; operation; message } ->
      Printf.sprintf "V1 HTTPS transport %s %s: %s" operation path message

let valid_url url =
  String.starts_with ~prefix:"https://" url
  && String.length url > String.length "https://"
  && (not
        (String.exists
           (function '\000' | '\r' | '\n' | ' ' | '\t' -> true | _ -> false)
           url))
  && not
       (String.exists
          (fun character ->
            character = '@' || character = '?' || character = '#')
          url)

let valid_token token =
  String.length token > 0
  && String.length token <= 4096
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          token)

let test_ca_bundle () =
  match
    ( Sys.getenv_opt test_enabled_environment,
      Sys.getenv_opt test_ca_bundle_environment )
  with
  | Some "1", Some path
    when String.length path > 0
         && String.length path <= 4096
         && (not
               (String.exists
                  (function '\000' | '\r' | '\n' -> true | _ -> false)
                  path))
         && Sys.file_exists path ->
      Some path
  | _ -> None

let test_interrupt_upload () =
  match
    ( Sys.getenv_opt test_enabled_environment,
      Sys.getenv_opt test_interrupt_upload_environment )
  with
  | Some "1", Some "1" -> true
  | _ -> false

let create ~url ~token =
  if not (valid_url url) then Error (Invalid_url url)
  else if not (valid_token token) then Error Invalid_token
  else if not (Sys.file_exists curl) then Error Missing_curl
  else Ok { url; token }

let valid_id value = Transport.valid_digest value

let check_id value =
  if valid_id value then Ok () else Error (Invalid_identifier value)

let kind_name = function
  | Object -> "objects"
  | Manifest -> "manifests"
  | Publication -> "publications"
  | Bootstrap -> "bootstraps"

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let write_file path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
    in
    let rec write offset =
      if offset = String.length bytes then Ok ()
      else
        try
          let count =
            Unix.write_substring descriptor bytes offset
              (String.length bytes - offset)
          in
          if count = 0 then
            Error
              (Io_error
                 { path; operation = "write"; message = "write returned zero" })
          else write (offset + count)
        with Unix.Unix_error (error, operation, _) ->
          Error
            (Io_error { path; operation; message = Unix.error_message error })
    in
    Fun.protect ~finally:(fun () -> close_noerr descriptor) (fun () -> write 0)
  with Unix.Unix_error (error, operation, _) ->
    Error (Io_error { path; operation; message = Unix.error_message error })

let read_file_limited path =
  try
    let info = Unix.lstat path in
    if info.Unix.st_size > max_response_bytes then Error Response_too_large
    else In_channel.with_open_bin path In_channel.input_all |> Result.ok
  with
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path; operation; message = Unix.error_message error })
  | Sys_error message -> Error (Io_error { path; operation = "read"; message })

let curl_escape value =
  value |> String.split_on_char '\\' |> String.concat "\\\\"
  |> String.split_on_char '"' |> String.concat "\\\""

let with_temporary_directory run =
  let root = Filename.temp_file "yeokcham-v1-https-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let remove () =
    Sys.readdir root
    |> Array.iter (fun name ->
        try Unix.unlink (Filename.concat root name)
        with Unix.Unix_error _ -> ());
    try Unix.rmdir root with Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:remove (fun () -> run root)

let status_of_output output =
  match int_of_string_opt (String.trim output) with
  | Some status when status >= 100 && status <= 599 -> Ok status
  | _ -> Error (Invalid_response "curl did not emit one HTTP status")

let statuses_of_output ~count output =
  let lines =
    String.split_on_char '\n' output
    |> List.filter (fun line -> String.length (String.trim line) > 0)
  in
  if List.length lines <> count then
    Error (Invalid_response "curl did not emit one status per V2 segment")
  else
    let rec decode reversed = function
      | [] -> Ok (List.rev reversed)
      | line :: rest ->
          let* status = status_of_output line in
          decode (status :: reversed) rest
    in
    decode [] lines

type parallel_request = {
  request_method : string;
  request_url : string;
  request_body : string option;
}

let run client ~method_ ~url ~body =
  with_temporary_directory (fun temporary ->
      let config = Filename.concat temporary "curl.conf" in
      let response = Filename.concat temporary "response" in
      let body_path = Filename.concat temporary "body" in
      let config_body =
        "url = \"" ^ curl_escape url ^ "\"\nheader = \"Authorization: Bearer "
        ^ curl_escape client.token ^ "\"\n"
      in
      let* () = write_file config config_body in
      let* body_argument =
        match body with
        | None -> Ok []
        | Some bytes ->
            let* () = write_file body_path bytes in
            Ok [ "--data-binary"; "@" ^ body_path ]
      in
      let stdout_read, stdout_write = Unix.pipe () in
      try
        let arguments =
          [
            curl;
            "--disable";
            "--silent";
            "--show-error";
            "--fail-with-body";
            "--proto";
            "=https";
            "--tlsv1.2";
            "--connect-timeout";
            "5";
            "--max-time";
            "30";
            "--max-filesize";
            string_of_int max_response_bytes;
            "--request";
            method_;
            "--config";
            config;
            "--output";
            response;
            "--write-out";
            "%{http_code}";
          ]
          @ (match test_ca_bundle () with
            | None -> []
            | Some bundle -> [ "--cacert"; bundle ])
          @ body_argument
        in
        let process =
          Unix.create_process curl (Array.of_list arguments) Unix.stdin
            stdout_write Unix.stderr
        in
        close_noerr stdout_write;
        let read_status () =
          let buffer = Buffer.create 4 in
          let scratch = Bytes.create 16 in
          let rec loop () =
            match Unix.read stdout_read scratch 0 (Bytes.length scratch) with
            | 0 -> Ok (Buffer.contents buffer)
            | count ->
                if Buffer.length buffer + count > 15 then
                  Error (Invalid_response "curl status output is oversized")
                else (
                  Buffer.add_subbytes buffer scratch 0 count;
                  loop ())
          in
          loop ()
        in
        let status_output =
          Fun.protect ~finally:(fun () -> close_noerr stdout_read) read_status
        in
        let _, process_status = Unix.waitpid [] process in
        let* status_output = status_output in
        let* status = status_of_output status_output in
        match process_status with
        | Unix.WEXITED 0 ->
            let* response = read_file_limited response in
            Ok (status, response)
        | Unix.WEXITED code ->
            if status >= 400 then Ok (status, "")
            else Error (Command_failed code)
        | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error (Command_failed 128)
      with Unix.Unix_error (error, operation, _) ->
        close_noerr stdout_read;
        close_noerr stdout_write;
        Error
          (Io_error
             { path = curl; operation; message = Unix.error_message error }))

let run_parallel client ~parallelism requests =
  with_temporary_directory (fun temporary ->
      let rec prepare index reversed = function
        | [] -> Ok (List.rev reversed)
        | { request_method; request_url; request_body } :: rest ->
            let config =
              Filename.concat temporary (Printf.sprintf "curl-%d.conf" index)
            in
            let response =
              Filename.concat temporary (Printf.sprintf "response-%d" index)
            in
            let body_path =
              Filename.concat temporary (Printf.sprintf "body-%d" index)
            in
            let config_body =
              "url = \"" ^ curl_escape request_url
              ^ "\"\nheader = \"Authorization: Bearer "
              ^ curl_escape client.token ^ "\"\n"
            in
            let* () = write_file config config_body in
            let* body_arguments =
              match request_body with
              | None -> Ok []
              | Some bytes ->
                  let* () = write_file body_path bytes in
                  Ok [ "--data-binary"; "@" ^ body_path ]
            in
            let arguments =
              [
                "--proto";
                "=https";
                "--tlsv1.2";
                "--connect-timeout";
                "5";
                "--max-time";
                "30";
                "--max-filesize";
                string_of_int max_response_bytes;
                "--fail-with-body";
                "--request";
                request_method;
                "--config";
                config;
                "--output";
                response;
                "--write-out";
                "%{http_code}\\n";
              ]
              @ (match test_ca_bundle () with
                | None -> []
                | Some bundle -> [ "--cacert"; bundle ])
              @ body_arguments
            in
            prepare (index + 1) ((arguments, response) :: reversed) rest
      in
      let* prepared = prepare 0 [] requests in
      let blocks =
        List.mapi
          (fun index (arguments, _) ->
            if index = 0 then arguments else "--next" :: arguments)
          prepared
        |> List.concat
      in
      let stdout_read, stdout_write = Unix.pipe () in
      try
        let arguments =
          [
            curl;
            "--disable";
            "--silent";
            "--show-error";
            "--parallel";
            "--parallel-max";
            string_of_int parallelism;
          ]
          @ blocks
        in
        let process =
          Unix.create_process curl (Array.of_list arguments) Unix.stdin
            stdout_write Unix.stderr
        in
        close_noerr stdout_write;
        let read_statuses () =
          let buffer = Buffer.create 32 in
          let scratch = Bytes.create 128 in
          let rec loop () =
            match Unix.read stdout_read scratch 0 (Bytes.length scratch) with
            | 0 -> Ok (Buffer.contents buffer)
            | count ->
                if Buffer.length buffer + count > 1024 then
                  Error (Invalid_response "curl V2 status output is oversized")
                else (
                  Buffer.add_subbytes buffer scratch 0 count;
                  loop ())
          in
          loop ()
        in
        let status_output =
          Fun.protect ~finally:(fun () -> close_noerr stdout_read) read_statuses
        in
        let _, process_status = Unix.waitpid [] process in
        let* status_output = status_output in
        let* statuses =
          statuses_of_output ~count:(List.length prepared) status_output
        in
        let* responses =
          let rec read reversed = function
            | [] -> Ok (List.rev reversed)
            | (_, response) :: rest ->
                let* bytes = read_file_limited response in
                read (bytes :: reversed) rest
          in
          read [] prepared
        in
        match process_status with
        | Unix.WEXITED 0 | Unix.WEXITED _ ->
            Ok (List.combine statuses responses)
        | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error (Command_failed 128)
      with Unix.Unix_error (error, operation, _) ->
        close_noerr stdout_read;
        close_noerr stdout_write;
        Error
          (Io_error
             { path = curl; operation; message = Unix.error_message error }))

let route client ~project ~kind ~id =
  let* () = check_id project in
  let* () = check_id id in
  Ok
    (client.url ^ "/v1/repositories/" ^ project ^ "/" ^ kind_name kind ^ "/"
   ^ id)

let get client ~project ~kind ~id =
  let* url = route client ~project ~kind ~id in
  let* status, response = run client ~method_:"GET" ~url ~body:None in
  if status = 200 then Ok response else Error (Unexpected_status status)

let put_v1 client ~project ~kind ~id ~bytes =
  if test_interrupt_upload () then Error Test_interrupted_upload
  else
    let* url = route client ~project ~kind ~id in
    let* status, _ = run client ~method_:"PUT" ~url ~body:(Some bytes) in
    if status = 201 || status = 204 then Ok ()
    else Error (Unexpected_status status)

let list_url client ~project ~cursor ~limit =
  let* () = check_id project in
  if limit <= 0 || limit > max_page_size then
    Error (Invalid_response "invalid page limit")
  else
    let* () =
      match cursor with None -> Ok () | Some value -> check_id value
    in
    let suffix =
      match cursor with
      | None -> "?limit=" ^ string_of_int limit
      | Some cursor -> "?cursor=" ^ cursor ^ "&limit=" ^ string_of_int limit
    in
    Ok (client.url ^ "/v1/repositories/" ^ project ^ "/publications" ^ suffix)

let list_publications client ~project ~cursor ~limit =
  let* url = list_url client ~project ~cursor ~limit in
  let* status, response = run client ~method_:"GET" ~url ~body:None in
  if status <> 200 then Error (Unexpected_status status)
  else
    let* value =
      Encoding.decode response
      |> Result.map_error (fun error ->
          Invalid_response (Encoding.decode_error_to_string error))
    in
    match value with
    | Encoding.Array [ Encoding.Array ids; cursor ] ->
        let rec decode_ids reversed = function
          | [] -> Ok (List.rev reversed)
          | Encoding.Text id :: rest when Transport.valid_digest id ->
              decode_ids (id :: reversed) rest
          | Encoding.Text _ :: _
          | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _
            | Encoding.Map _ | Encoding.Bool _ | Encoding.Null )
            :: _ ->
              Error (Invalid_response "publication list contains invalid ID")
        in
        let* ids = decode_ids [] ids in
        let cursor =
          match cursor with
          | Encoding.Null -> Ok None
          | Encoding.Text value when Transport.valid_digest value ->
              Ok (Some value)
          | Encoding.Text _ | Encoding.Integer _ | Encoding.Bytes _
          | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ ->
              Error (Invalid_response "publication cursor is invalid")
        in
        let* cursor = cursor in
        Ok (ids, cursor)
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
        Error (Invalid_response "publication list has wrong shape")

let client_error_to_string = error_to_string

module V2 = struct
  module Transfer = Transport.V2
  module Wire = Transport.V2_wire

  type error =
    | V2_unavailable
    | Http_error of string
    | Protocol_error of string
    | Transfer_error of Transfer.error
    | Wire_error of Wire.error

  let ( let* ) = Result.bind

  let error_to_string = function
    | V2_unavailable -> "the relay does not provide V2 transfer"
    | Http_error detail -> "V2 HTTPS request failed: " ^ detail
    | Protocol_error detail -> "invalid V2 HTTPS response: " ^ detail
    | Transfer_error error -> Transfer.error_to_string error
    | Wire_error error -> Wire.error_to_string error

  let http_error error = Http_error (client_error_to_string error)

  let retryable_client_error (error : http_client_error) =
    match error with
    | Command_failed _ -> true
    | Invalid_url _ | Invalid_token | Invalid_identifier _ | Missing_curl
    | Unexpected_status _ | Response_too_large | Invalid_response _
    | Test_interrupted_upload | Io_error _ ->
        false

  let retry_after ~attempt error =
    match Transfer.retry ~attempt error with
    | Transfer.Do_not_retry -> false
    | Transfer.Retry_after_ms milliseconds ->
        Unix.sleepf (float_of_int milliseconds /. 1000.0);
        true

  let rec run_idempotent ~attempt
      (operation : unit -> (int * string, http_client_error) result) =
    match operation () with
    | Ok (status, response) when status >= 500 && status <= 599 ->
        if retry_after ~attempt (Transfer.Http_server_error status) then
          run_idempotent ~attempt:(attempt + 1) operation
        else Ok (status, response)
    | Ok (status, response) -> Ok (status, response)
    | Error error ->
        if
          retryable_client_error error
          && retry_after ~attempt Transfer.Transient_network
        then run_idempotent ~attempt:(attempt + 1) operation
        else Error error

  let rec run_parallel_idempotent ~attempt
      (operation : unit -> ((int * string) list, http_client_error) result) =
    match operation () with
    | Ok responses ->
        let has_server_failure =
          List.exists
            (fun (status, _) -> status >= 500 && status <= 599)
            responses
        in
        let has_client_failure =
          List.exists
            (fun (status, _) -> status >= 400 && status <= 499)
            responses
        in
        if has_server_failure && not has_client_failure then
          if retry_after ~attempt (Transfer.Http_server_error 500) then
            run_parallel_idempotent ~attempt:(attempt + 1) operation
          else Ok responses
        else Ok responses
    | Error error ->
        if
          retryable_client_error error
          && retry_after ~attempt Transfer.Transient_network
        then run_parallel_idempotent ~attempt:(attempt + 1) operation
        else Error error

  let route client ~project suffix =
    let* () = check_id project |> Result.map_error http_error in
    Ok (client.url ^ "/v2/repositories/" ^ project ^ suffix)

  let valid_segment ~offset ~length =
    offset >= 0 && length > 0 && length <= Transfer.segment_bytes

  let encode_capability_offer sender offered =
    let* encoded =
      Transfer.encode_capability sender
      |> Result.map_error (fun error -> Transfer_error error)
    in
    let rec encode_offered reversed = function
      | [] -> Ok (List.rev reversed)
      | id :: rest ->
          let* id =
            Encoding.text id
            |> Result.map_error (fun _ -> Protocol_error "invalid offered ID")
          in
          encode_offered (id :: reversed) rest
    in
    let offered = encode_offered [] offered in
    let* offered = offered in
    let* offered =
      Encoding.array offered
      |> Result.map_error (fun _ ->
          Protocol_error "capability request is invalid")
    in
    Encoding.array [ Encoding.bytes encoded; offered ]
    |> Result.map_error (fun _ ->
        Protocol_error "capability request is invalid")
    |> Result.map Encoding.encode

  let decode_capability bytes =
    Transfer.decode_capability bytes
    |> Result.map_error (fun error -> Transfer_error error)

  let encode_start ~object_id ~raw_size ~expires_in =
    if raw_size < 0 || raw_size > Transfer.max_raw_object_bytes then
      Error (Protocol_error "raw object size is outside the V2 relay bound")
    else if expires_in <= 0 || expires_in > 86_400 then
      Error (Protocol_error "session expiry is outside the V2 bound")
    else
      let* object_id =
        Encoding.text object_id
        |> Result.map_error (fun _ -> Protocol_error "object ID is invalid")
      in
      Encoding.array
        [
          object_id;
          Encoding.integer (Int64.of_int raw_size);
          Encoding.integer (Int64.of_int expires_in);
        ]
      |> Result.map_error (fun _ -> Protocol_error "upload request is invalid")
      |> Result.map Encoding.encode

  let decode_session bytes =
    Transfer.decode_session bytes
    |> Result.map_error (fun error -> Transfer_error error)

  let negotiate_upload client ~project ~sender ~offered =
    let* body = encode_capability_offer sender offered in
    let* url = route client ~project "/capabilities" in
    let* status, response =
      run_idempotent ~attempt:0 (fun () ->
          run client ~method_:"POST" ~url ~body:(Some body))
      |> Result.map_error http_error
    in
    if status = 404 then Error V2_unavailable
    else if status <> 200 then
      Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))
    else decode_capability response

  let start_upload client ~project ~object_id ~raw_size ~expires_in =
    let* () = check_id object_id |> Result.map_error http_error in
    let* body = encode_start ~object_id ~raw_size ~expires_in in
    let* url = route client ~project "/uploads" in
    let* status, response =
      run client ~method_:"POST" ~url ~body:(Some body)
      |> Result.map_error http_error
    in
    if status = 404 then Error V2_unavailable
    else if status <> 201 then
      Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))
    else
      let* session = decode_session response in
      let offer = Transfer.session_offer session in
      if
        String.equal (Transfer.offer_project offer) project
        && String.equal (Transfer.offer_object_id offer) object_id
        && Transfer.offer_raw_size offer = raw_size
      then Ok session
      else
        Error (Protocol_error "upload session does not bind the offered object")

  let resume_upload client ~project ~session_id =
    let* () = check_id session_id |> Result.map_error http_error in
    let* url = route client ~project ("/uploads/" ^ session_id) in
    let* status, response =
      run_idempotent ~attempt:0 (fun () ->
          run client ~method_:"GET" ~url ~body:None)
      |> Result.map_error http_error
    in
    if status = 404 then Error (Protocol_error "upload session is absent")
    else if status <> 200 then
      Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))
    else decode_session response

  let put_segment client ~project ~session_id ~offset ~raw =
    let length = String.length raw in
    if not (valid_segment ~offset ~length) then
      Error (Transfer_error Transfer.Range_failure)
    else if test_interrupt_upload () then
      Error (Http_error (client_error_to_string Test_interrupted_upload))
    else
      let* () = check_id session_id |> Result.map_error http_error in
      let* compressed =
        Wire.compress raw |> Result.map_error (fun error -> Wire_error error)
      in
      let raw_sha256 = Transport.sha256 raw in
      let suffix =
        Printf.sprintf "/uploads/%s/segments/%d/%d/%s" session_id offset length
          raw_sha256
      in
      let* url = route client ~project suffix in
      let* status, _ =
        run_idempotent ~attempt:0 (fun () ->
            run client ~method_:"PUT" ~url ~body:(Some compressed))
        |> Result.map_error http_error
      in
      if status = 204 then Ok ()
      else Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))

  let complete_upload client ~project ~session_id =
    let* () = check_id session_id |> Result.map_error http_error in
    let* url = route client ~project ("/uploads/" ^ session_id ^ "/complete") in
    let* status, _ =
      run client ~method_:"POST" ~url ~body:None |> Result.map_error http_error
    in
    if status = 201 then Ok ()
    else Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))

  let get_segment client ~project ~object_id ~offset ~length =
    if not (valid_segment ~offset ~length) then
      Error (Transfer_error Transfer.Range_failure)
    else
      let* () = check_id object_id |> Result.map_error http_error in
      let* url =
        route client ~project
          (Printf.sprintf "/objects/%s?offset=%d&length=%d" object_id offset
             length)
      in
      let* status, compressed =
        run_idempotent ~attempt:0 (fun () ->
            run client ~method_:"GET" ~url ~body:None)
        |> Result.map_error http_error
      in
      if status <> 200 then
        Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))
      else
        Wire.decompress ~raw_length:length compressed
        |> Result.map_error (fun error -> Wire_error error)

  let checked_parallelism = function
    | None -> Ok Transfer.default_parallelism
    | Some value when value >= 1 && value <= Transfer.max_parallelism ->
        Ok value
    | Some _ ->
        Error (Protocol_error "V2 parallelism must be between one and eight")

  let validate_canonical_object ~object_id bytes =
    match Envelope.decode bytes with
    | Error _ -> Error (Transfer_error Transfer.Canonical_bytes_failure)
    | Ok envelope ->
        if not (String.equal (Envelope.encode envelope) bytes) then
          Error (Transfer_error Transfer.Canonical_bytes_failure)
        else
          let actual =
            Object_store.id_of_envelope envelope
            |> Object_store.Stored_object_id.to_hex
          in
          if String.equal actual object_id then Ok ()
          else Error (Transfer_error Transfer.Identity_failure)

  let upload_ranges client ~parallelism ~project ~session_id ~bytes ranges =
    if test_interrupt_upload () then
      Error (Http_error (client_error_to_string Test_interrupted_upload))
    else
      let rec requests reversed = function
        | [] -> Ok (List.rev reversed)
        | range :: rest ->
            let raw =
              String.sub bytes
                (Transfer.range_offset range)
                (Transfer.range_length range)
            in
            let* compressed =
              Wire.compress raw
              |> Result.map_error (fun error -> Wire_error error)
            in
            let raw_sha256 = Transport.sha256 raw in
            let suffix =
              Printf.sprintf "/uploads/%s/segments/%d/%d/%s" session_id
                (Transfer.range_offset range)
                (Transfer.range_length range)
                raw_sha256
            in
            let* url = route client ~project suffix in
            requests
              ({
                 request_method = "PUT";
                 request_url = url;
                 request_body = Some compressed;
               }
              :: reversed)
              rest
      in
      let* requests = requests [] ranges in
      let* responses =
        run_parallel_idempotent ~attempt:0 (fun () ->
            run_parallel client ~parallelism requests)
        |> Result.map_error http_error
      in
      match List.find_opt (fun (status, _) -> status <> 204) responses with
      | None -> Ok ()
      | Some (status, _) ->
          Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))

  let download_ranges client ~parallelism ~project ~object_id ranges =
    let rec requests reversed = function
      | [] -> Ok (List.rev reversed)
      | range :: rest ->
          let* url =
            route client ~project
              (Printf.sprintf "/objects/%s?offset=%d&length=%d" object_id
                 (Transfer.range_offset range)
                 (Transfer.range_length range))
          in
          requests
            (( { request_method = "GET"; request_url = url; request_body = None },
               Transfer.range_length range )
            :: reversed)
            rest
    in
    let* requests = requests [] ranges in
    let requests, lengths = List.split requests in
    let* responses =
      run_parallel_idempotent ~attempt:0 (fun () ->
          run_parallel client ~parallelism requests)
      |> Result.map_error http_error
    in
    let rec decompress reversed = function
      | [], [] -> Ok (List.rev reversed)
      | (status, compressed) :: response_rest, length :: length_rest ->
          if status <> 200 then
            Error (Http_error (Printf.sprintf "relay returned HTTP %d" status))
          else
            let* raw =
              Wire.decompress ~raw_length:length compressed
              |> Result.map_error (fun error -> Wire_error error)
            in
            decompress (raw :: reversed) (response_rest, length_rest)
      | _ -> Error (Protocol_error "parallel V2 response count changed")
    in
    decompress [] (responses, lengths)

  let upload_object ?parallelism client ~project ~object_id bytes =
    let* parallelism = checked_parallelism parallelism in
    let* () = check_id object_id |> Result.map_error http_error in
    let* () = validate_canonical_object ~object_id bytes in
    let* sender =
      Transfer.capability
        ~versions:[ Transfer.protocol_version ]
        ~zstd:true ~max_segment_bytes:Transfer.segment_bytes
        ~max_in_flight:parallelism ~missing:[]
      |> Result.map_error (fun error -> Transfer_error error)
    in
    let* receiver =
      negotiate_upload client ~project ~sender ~offered:[ object_id ]
    in
    let* negotiated =
      Transfer.intersect_capability ~sender ~receiver
      |> Result.map_error (fun error -> Transfer_error error)
    in
    let parallelism =
      min parallelism (Transfer.capability_max_in_flight negotiated)
    in
    if
      not
        (List.mem object_id
           (Transfer.missing_ids (Transfer.missing_objects negotiated)))
    then Ok ()
    else
      let* session =
        start_upload client ~project ~object_id ~raw_size:(String.length bytes)
          ~expires_in:900
      in
      let* ranges =
        Transfer.partition (Transfer.session_offer session)
        |> Result.map_error (fun error -> Transfer_error error)
      in
      let session_id = Transfer.session_id session in
      let* () =
        upload_ranges client ~parallelism ~project ~session_id ~bytes ranges
      in
      complete_upload client ~project ~session_id

  let download_object ?parallelism client ~project ~object_id ~raw_size =
    let* parallelism = checked_parallelism parallelism in
    let* () = check_id object_id |> Result.map_error http_error in
    let* offer =
      Transfer.object_offer ~project ~object_id ~raw_size
      |> Result.map_error (fun error -> Transfer_error error)
    in
    let* ranges =
      Transfer.partition offer
      |> Result.map_error (fun error -> Transfer_error error)
    in
    let* parts =
      download_ranges client ~parallelism ~project ~object_id ranges
    in
    let bytes = String.concat "" parts in
    let* () = validate_canonical_object ~object_id bytes in
    Ok bytes
end

let put client ~project ~kind ~id ~bytes =
  match kind with
  | Object -> (
      match V2.upload_object client ~project ~object_id:id bytes with
      | Ok () -> Ok ()
      | Error error ->
          if error = V2.V2_unavailable then
            put_v1 client ~project ~kind ~id ~bytes
          else Error (Invalid_response (V2.error_to_string error)))
  | Manifest | Publication | Bootstrap ->
      put_v1 client ~project ~kind ~id ~bytes
