type error = Unavailable | Missing | Rejected | Invalid

let secret_tool = "/usr/bin/secret-tool"
let application = "io.github.gongahkia.yeokcham"
let schema = "v4-relay-bearer-1"
let test_enabled_environment = "YEOKCHAM_V4_TEST_TRANSPORT"
let test_token_environment = "YEOKCHAM_V4_TEST_TRANSPORT_TOKEN"
let max_output = 8192

let error_to_string = function
  | Unavailable -> "V4 transport credential store is unavailable"
  | Missing -> "V4 transport credential is absent"
  | Rejected -> "V4 transport credential store rejected the request"
  | Invalid -> "V4 transport credential is invalid"

let valid_token token =
  String.length token > 0
  && String.length token <= 4096
  && not (String.exists (function '\000' | '\r' | '\n' -> true | _ -> false) token)

let test_token () =
  match (Sys.getenv_opt test_enabled_environment, Sys.getenv_opt test_token_environment) with
  | Some "1", Some token when valid_token token -> Some token
  | _ -> None

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let write_all descriptor bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count = Unix.write_substring descriptor bytes offset (String.length bytes - offset) in
        if count = 0 then Error () else loop (offset + count)
      with Unix.Unix_error _ -> Error ()
  in
  loop 0

let command arguments stdin =
  if not (Sys.file_exists secret_tool) then Error Unavailable
  else
    let stdin_read, stdin_write = Unix.pipe () in
    let stdout_read, stdout_write = Unix.pipe () in
    try
      let process =
        Unix.create_process secret_tool (Array.of_list (secret_tool :: arguments))
          stdin_read stdout_write Unix.stderr
      in
      close_noerr stdin_read;
      close_noerr stdout_write;
      let input = write_all stdin_write stdin in
      close_noerr stdin_write;
      let output = Buffer.create 128 in
      let scratch = Bytes.create 512 in
      let rec read () =
        try
          match Unix.read stdout_read scratch 0 (Bytes.length scratch) with
          | 0 -> Ok ()
          | count ->
              if Buffer.length output + count > max_output then Error ()
              else (
                Buffer.add_subbytes output scratch 0 count;
                read ())
        with Unix.Unix_error _ -> Error ()
      in
      let result = read () in
      close_noerr stdout_read;
      let _, status = Unix.waitpid [] process in
      (match (input, result) with
      | Ok (), Ok () -> (
          match status with
          | Unix.WEXITED code -> Ok (code, Buffer.contents output)
          | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> Error Unavailable)
      | Ok (), Error () | Error (), Ok () | Error (), Error () -> Error Unavailable)
    with Unix.Unix_error _ ->
      close_noerr stdin_read;
      close_noerr stdin_write;
      close_noerr stdout_read;
      close_noerr stdout_write;
      Error Unavailable

let attributes remote =
  [ "application"; application; "schema"; schema; "remote"; remote ]

let trim_newline value =
  if String.ends_with ~suffix:"\n" value then String.sub value 0 (String.length value - 1)
  else value

let load ~remote =
  match test_token () with
  | Some token -> Ok token
  | None -> (
      match command ("lookup" :: attributes remote) "" with
      | Ok (0, token) ->
          let token = trim_newline token in
          if valid_token token then Ok token else Error Invalid
      | Ok (1, "") -> Error Missing
      | Ok _ -> Error Rejected
      | Error error -> Error error)

let save ~remote ~token =
  if not (valid_token token) then Error Invalid
  else
    match test_token () with
    | Some _ -> Ok ()
    | None -> (
        match command ("store" :: "--label=Yeokcham V4 relay credential" :: attributes remote) token with
        | Ok (0, _) -> Ok ()
        | Ok _ -> Error Rejected
        | Error error -> Error error)
