module Hook = Yeokcham_v4_hook

type public_event = {
  event_value : Hook.event;
  command_value : string;
  repository_value : string option;
  paths_value : string list;
  identifiers_value : (string * string) list;
}

type warning =
  | Missing_executable of string
  | Nonzero_exit of int
  | Signalled of int
  | Timed_out
  | Malformed_output
  | Io_failure of string

let schema_version = 1
let default_timeout_seconds = 30
let maximum_output_bytes = 4096

let warning_to_string = function
  | Missing_executable path -> "hook executable is unavailable: " ^ path
  | Nonzero_exit status -> Printf.sprintf "hook exited with status %d" status
  | Signalled signal -> Printf.sprintf "hook was terminated by signal %d" signal
  | Timed_out -> "hook exceeded the 30-second timeout"
  | Malformed_output -> "hook produced nonempty observer output"
  | Io_failure detail -> "hook launcher failed: " ^ detail

let valid_text value =
  String.length value > 0
  && String.length value <= 4096
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          value)

let valid_name value =
  valid_text value
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       value

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop offset =
    offset + needle_length <= text_length
    && (String.equal (String.sub text offset needle_length) needle
       || loop (offset + 1))
  in
  needle_length > 0 && loop 0

let secret_name value =
  [
    "token"; "credential"; "secret"; "private"; "passphrase"; "mnemonic"; "key";
  ]
  |> List.exists (contains value)

let make_event ~event ~command ~repository ~paths ~identifiers =
  let names = List.map fst identifiers in
  let sorted = List.sort String.compare names in
  let duplicate =
    let rec loop = function
      | left :: right :: _ when String.equal left right -> true
      | _ :: rest -> loop rest
      | [] -> false
    in
    loop sorted
  in
  if not (valid_name command) then Error "invalid hook command name"
  else if
    Option.exists (fun repository -> not (valid_text repository)) repository
  then Error "invalid hook repository identifier"
  else if not (List.for_all valid_text paths) then Error "invalid hook path"
  else if duplicate || List.length identifiers > 64 then
    Error "invalid hook identifier set"
  else if
    not
      (List.for_all
         (fun (name, value) ->
           valid_name name && valid_text value && not (secret_name name))
         identifiers)
  then Error "hook event cannot contain secret-shaped or invalid identifiers"
  else
    Ok
      {
        event_value = event;
        command_value = command;
        repository_value = repository;
        paths_value = List.sort_uniq String.compare paths;
        identifiers_value =
          List.sort
            (fun (left, _) (right, _) -> String.compare left right)
            identifiers;
      }

let encode_event event =
  let repository =
    match event.repository_value with
    | None -> `Null
    | Some value -> `String value
  in
  let identifiers =
    event.identifiers_value
    |> List.map (fun (name, value) -> (name, `String value))
  in
  `Assoc
    [
      ("schema_version", `Int schema_version);
      ("event", `String (Hook.event_to_string event.event_value));
      ("command", `String event.command_value);
      ("repository", repository);
      ("paths", `List (List.map (fun path -> `String path) event.paths_value));
      ("identifiers", `Assoc identifiers);
    ]
  |> Yojson.Safe.to_string

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let write_all descriptor value =
  let rec loop offset =
    if offset = String.length value then Ok ()
    else
      try
        let written =
          Unix.write_substring descriptor value offset
            (String.length value - offset)
        in
        if written = 0 then Error "event stdin write returned zero"
        else loop (offset + written)
      with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  loop 0

let read_available descriptor output =
  let buffer = Bytes.create 1024 in
  let rec loop () =
    match Unix.select [ descriptor ] [] [] 0.0 with
    | [], _, _ -> Ok ()
    | _ -> (
        try
          match Unix.read descriptor buffer 0 (Bytes.length buffer) with
          | 0 -> Ok ()
          | count ->
              if Buffer.length output + count > maximum_output_bytes then
                Error ()
              else (
                Buffer.add_subbytes output buffer 0 count;
                loop ())
        with
        | Unix.Unix_error (Unix.EAGAIN, _, _) -> Ok ()
        | Unix.Unix_error _ -> Ok ())
  in
  loop ()

let status_warning output = function
  | Unix.WEXITED 0 when Buffer.length output = 0 -> None
  | Unix.WEXITED 0 -> Some Malformed_output
  | Unix.WEXITED 127 -> Some (Missing_executable "configured argv[0]")
  | Unix.WEXITED status -> Some (Nonzero_exit status)
  | Unix.WSIGNALED signal -> Some (Signalled signal)
  | Unix.WSTOPPED signal -> Some (Signalled signal)

let invoke ~timeout_seconds event hook =
  if timeout_seconds <= 0 || timeout_seconds > default_timeout_seconds then
    Some (Io_failure "hook timeout must be between one and 30 seconds")
  else
    try
      let stdin_read, stdin_write = Unix.pipe () in
      let stdout_read, stdout_write = Unix.pipe () in
      let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
      match Unix.fork () with
      | 0 -> (
          close_noerr stdin_write;
          close_noerr stdout_read;
          Unix.dup2 stdin_read Unix.stdin;
          Unix.dup2 stdout_write Unix.stdout;
          Unix.dup2 null Unix.stderr;
          close_noerr stdin_read;
          close_noerr stdout_write;
          close_noerr null;
          let argv = Array.of_list (Hook.hook_argv hook) in
          try Unix.execve argv.(0) argv [| "PATH=/usr/bin:/bin"; "LC_ALL=C" |]
          with Unix.Unix_error _ -> exit 127)
      | process -> (
          close_noerr stdin_read;
          close_noerr stdout_write;
          close_noerr null;
          let write_result =
            write_all stdin_write (encode_event event ^ "\n")
          in
          close_noerr stdin_write;
          match write_result with
          | Error detail ->
              Unix.kill process Sys.sigterm;
              ignore (Unix.waitpid [] process);
              close_noerr stdout_read;
              Some (Io_failure detail)
          | Ok () ->
              let output = Buffer.create 128 in
              let deadline =
                Unix.gettimeofday () +. float_of_int timeout_seconds
              in
              let rec wait () =
                match Unix.waitpid [ Unix.WNOHANG ] process with
                | 0, _ -> (
                    match read_available stdout_read output with
                    | Error () ->
                        (try Unix.kill process Sys.sigterm
                         with Unix.Unix_error _ -> ());
                        ignore (Unix.waitpid [] process);
                        close_noerr stdout_read;
                        Some Malformed_output
                    | Ok () when Unix.gettimeofday () >= deadline ->
                        (try Unix.kill process Sys.sigterm
                         with Unix.Unix_error _ -> ());
                        ignore (Unix.waitpid [] process);
                        close_noerr stdout_read;
                        Some Timed_out
                    | Ok () ->
                        Unix.sleepf 0.005;
                        wait ())
                | _, status -> (
                    match read_available stdout_read output with
                    | Error () ->
                        close_noerr stdout_read;
                        Some Malformed_output
                    | Ok () ->
                        close_noerr stdout_read;
                        status_warning output status)
              in
              wait ())
    with Unix.Unix_error (error, _, _) ->
      Some (Io_failure (Unix.error_message error))
