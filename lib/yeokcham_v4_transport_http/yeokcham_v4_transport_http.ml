module Encoding = Yeokcham_encoding
module Transport = Yeokcham_v4_transport

type client = { url : string; token : string }
type kind = Object | Manifest | Publication

type error =
  | Invalid_url of string
  | Invalid_token
  | Invalid_identifier of string
  | Missing_curl
  | Command_failed of int
  | Unexpected_status of int
  | Response_too_large
  | Invalid_response of string
  | Io_error of { path : string; operation : string; message : string }

let max_response_bytes = 64 * 1024 * 1024
let max_page_size = 128
let curl = "/usr/bin/curl"
let test_enabled_environment = "YEOKCHAM_V4_TEST_TRANSPORT"
let test_ca_bundle_environment = "YEOKCHAM_V4_TEST_TRANSPORT_CA_BUNDLE"
let test_interrupt_upload_environment = "YEOKCHAM_V4_TEST_TRANSPORT_FAIL_PUT"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_url url -> "invalid V4 transport HTTPS URL: " ^ url
  | Invalid_token -> "invalid V4 transport bearer credential"
  | Invalid_identifier id -> "invalid V4 transport route identifier: " ^ id
  | Missing_curl -> "the V4 HTTPS transport client requires /usr/bin/curl"
  | Command_failed code ->
      Printf.sprintf "V4 HTTPS transport request failed with curl exit %d" code
  | Unexpected_status status ->
      Printf.sprintf "V4 relay returned unexpected HTTP status %d" status
  | Response_too_large -> "V4 relay response exceeds the configured limit"
  | Invalid_response detail -> "invalid V4 relay response: " ^ detail
  | Test_interrupted_upload -> "test-only V4 transport upload interruption"
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 HTTPS transport %s %s: %s" operation path message

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
  let root = Filename.temp_file "yeokcham-v4-https-" "" in
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

let put client ~project ~kind ~id ~bytes =
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
