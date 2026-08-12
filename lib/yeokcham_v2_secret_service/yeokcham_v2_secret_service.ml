module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model

type command = { program : string; arguments : string list; stdin : string }
type command_result = { exit_code : int; stdout : string }
type command_error = Spawn_failed | Timed_out | Output_limit_exceeded
type runner = command -> (command_result, command_error) result
type service = { run : runner; secret_tool : string; busctl : string }
type initialization = Initialized | Already_initialized

type enrollment = {
  initialization : initialization;
  repository : Bootstrap_store.repository;
}

type error =
  | Secret_service_unavailable
  | Secret_service_locked
  | Secret_missing
  | Secret_handle_in_use
  | Invalid_secret_material
  | Bootstrap_error of Bootstrap.error
  | Bootstrap_store_error of Bootstrap_store.error
  | Entropy_failure

let ( let* ) = Result.bind
let max_command_output = 4096
let command_timeout_seconds = 5.0
let application_attribute = "application"
let application_value = "io.github.gongahkia.yeokcham"
let schema_attribute = "schema"
let schema_value = "v2-local-capability-1"
let handle_attribute = "key-handle"
let secret_prefix = "yeokcham-v2-local-capability-v1:"
let secret_label = "Yeokcham V2 local device capability"

let error_to_string = function
  | Secret_service_unavailable ->
      "Linux Secret Service is unavailable or rejected the request"
  | Secret_service_locked -> "Linux Secret Service default collection is locked"
  | Secret_missing -> "local capability is missing from Linux Secret Service"
  | Secret_handle_in_use ->
      "Linux Secret Service already contains different material for this key \
       handle"
  | Invalid_secret_material ->
      "Linux Secret Service returned invalid local capability material"
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Entropy_failure -> "OS CSPRNG unavailable while generating local capability"

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let write_all descriptor bytes =
  let rec write offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let written =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if written = 0 then Error Spawn_failed else write (offset + written)
      with Unix.Unix_error _ -> Error Spawn_failed
  in
  write 0

let drain_nonblocking descriptor buffer =
  let bytes = Bytes.create 512 in
  let rec drain () =
    try
      match Unix.read descriptor bytes 0 (Bytes.length bytes) with
      | 0 -> `Closed
      | count ->
          if Buffer.length buffer + count > max_command_output then `Too_large
          else (
            Buffer.add_subbytes buffer bytes 0 count;
            drain ())
    with
    | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> `Open
    | Unix.Unix_error _ -> `Closed
  in
  drain ()

let run_system command =
  let stdin_read, stdin_write = Unix.pipe () in
  let stdout_read, stdout_write = Unix.pipe () in
  let stderr_read, stderr_write = Unix.pipe () in
  let close_all () =
    List.iter close_noerr
      [
        stdin_read;
        stdin_write;
        stdout_read;
        stdout_write;
        stderr_read;
        stderr_write;
      ]
  in
  try
    List.iter Unix.set_close_on_exec [ stdin_write; stdout_read; stderr_read ];
    let arguments = Array.of_list (command.program :: command.arguments) in
    let process =
      Unix.create_process command.program arguments stdin_read stdout_write
        stderr_write
    in
    close_noerr stdin_read;
    close_noerr stdout_write;
    close_noerr stderr_write;
    let input_result = write_all stdin_write command.stdin in
    close_noerr stdin_write;
    match input_result with
    | Error error ->
        (try Unix.kill process Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] process);
        close_noerr stdout_read;
        close_noerr stderr_read;
        Error error
    | Ok () ->
        Unix.set_nonblock stdout_read;
        Unix.set_nonblock stderr_read;
        let stdout = Buffer.create 256 in
        let stderr = Buffer.create 256 in
        let deadline = Unix.gettimeofday () +. command_timeout_seconds in
        let rec collect stdout_open stderr_open =
          if (not stdout_open) && not stderr_open then
            match Unix.waitpid [] process with
            | _, Unix.WEXITED exit_code ->
                Ok { exit_code; stdout = Buffer.contents stdout }
            | _, Unix.WSIGNALED _ | _, Unix.WSTOPPED _ -> Error Spawn_failed
          else
            let remaining = deadline -. Unix.gettimeofday () in
            if remaining <= 0.0 then Error Timed_out
            else
              let readable =
                (if stdout_open then [ stdout_read ] else [])
                @ if stderr_open then [ stderr_read ] else []
              in
              match Unix.select readable [] [] remaining with
              | [], _, _ -> Error Timed_out
              | ready, _, _ ->
                  let close_stream descriptor buffer open_ =
                    if not (List.mem descriptor ready) then Ok open_
                    else
                      match drain_nonblocking descriptor buffer with
                      | `Open -> Ok true
                      | `Closed ->
                          close_noerr descriptor;
                          Ok false
                      | `Too_large -> Error Output_limit_exceeded
                  in
                  let* stdout_open =
                    close_stream stdout_read stdout stdout_open
                  in
                  let* stderr_open =
                    close_stream stderr_read stderr stderr_open
                  in
                  collect stdout_open stderr_open
        in
        let result = collect true true in
        (match result with
        | Ok _ -> ()
        | Error _ ->
            (try Unix.kill process Sys.sigkill with Unix.Unix_error _ -> ());
            ignore (Unix.waitpid [] process));
        close_noerr stdout_read;
        close_noerr stderr_read;
        result
  with Unix.Unix_error _ ->
    close_all ();
    Error Spawn_failed

let service ~runner ~secret_tool ~busctl = { run = runner; secret_tool; busctl }

let default_service () =
  service ~runner:run_system ~secret_tool:"/usr/bin/secret-tool"
    ~busctl:"/usr/bin/busctl"

let trim_single_newline value =
  if String.ends_with ~suffix:"\n" value then
    String.sub value 0 (String.length value - 1)
  else value

let hex_of_bytes bytes =
  let digits = "0123456789abcdef" in
  let encoded = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set encoded (index * 2) digits.[value lsr 4];
      Bytes.set encoded ((index * 2) + 1) digits.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string encoded

let decode_hex value =
  let nibble = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
    | _ -> None
  in
  if String.length value mod 2 <> 0 then Error ()
  else
    let decoded = Bytes.create (String.length value / 2) in
    let rec decode offset =
      if offset = String.length value then Ok (Bytes.unsafe_to_string decoded)
      else
        match (nibble value.[offset], nibble value.[offset + 1]) with
        | Some high, Some low ->
            Bytes.set decoded (offset / 2) (Char.chr ((high lsl 4) lor low));
            decode (offset + 2)
        | None, _ | _, None -> Error ()
    in
    decode 0

let encode_secret capability =
  let encryption_key, address_key, signing_key =
    Bootstrap.secret_material capability
  in
  String.concat ":"
    [
      secret_prefix ^ hex_of_bytes encryption_key;
      hex_of_bytes address_key;
      hex_of_bytes signing_key;
    ]

let decode_secret value =
  let value = trim_single_newline value in
  if not (String.starts_with ~prefix:secret_prefix value) then
    Error Invalid_secret_material
  else
    match
      String.sub value
        (String.length secret_prefix)
        (String.length value - String.length secret_prefix)
      |> String.split_on_char ':'
    with
    | [ encryption_hex; address_hex; signing_hex ] -> (
        match
          ( decode_hex encryption_hex,
            decode_hex address_hex,
            decode_hex signing_hex )
        with
        | Ok encryption_key, Ok address_key, Ok signing_key ->
            Bootstrap.capability_of_secret_material ~encryption_key ~address_key
              ~signing_key
            |> Result.map_error (fun _ -> Invalid_secret_material)
        | Error (), _, _ | _, Error (), _ | _, _, Error () ->
            Error Invalid_secret_material)
    | _ -> Error Invalid_secret_material

let attributes handle =
  [
    application_attribute;
    application_value;
    schema_attribute;
    schema_value;
    handle_attribute;
    Bootstrap.Key_handle.to_hex handle;
  ]

let preflight service =
  let command =
    {
      program = service.busctl;
      arguments =
        [
          "--user";
          "get-property";
          "org.freedesktop.secrets";
          "/org/freedesktop/secrets/aliases/default";
          "org.freedesktop.Secret.Collection";
          "Locked";
        ];
      stdin = "";
    }
  in
  match service.run command with
  | Error _ -> Error Secret_service_unavailable
  | Ok { exit_code = 0; stdout } -> (
      match String.trim stdout with
      | "b false" -> Ok ()
      | "b true" -> Error Secret_service_locked
      | _ -> Error Secret_service_unavailable)
  | Ok _ -> Error Secret_service_unavailable

let lookup_command service handle =
  {
    program = service.secret_tool;
    arguments = "lookup" :: attributes handle;
    stdin = "";
  }

let store_command service handle secret =
  {
    program = service.secret_tool;
    arguments = "store" :: ("--label=" ^ secret_label) :: attributes handle;
    stdin = secret;
  }

let read_capability ~service ~key_handle =
  let* () = preflight service in
  match service.run (lookup_command service key_handle) with
  | Ok { exit_code = 0; stdout } -> decode_secret stdout
  | Ok { exit_code = 1; stdout } when String.equal stdout "" ->
      Error Secret_missing
  | Ok _ | Error _ -> Error Secret_service_unavailable

let store_capability ~service ~key_handle ~capability =
  let* () = preflight service in
  let secret = encode_secret capability in
  match service.run (lookup_command service key_handle) with
  | Ok { exit_code = 0; stdout } ->
      if String.equal (trim_single_newline stdout) secret then
        Ok Already_initialized
      else Error Secret_handle_in_use
  | Ok { exit_code = 1; stdout } when String.equal stdout "" -> (
      match service.run (store_command service key_handle secret) with
      | Ok { exit_code = 0; _ } -> Ok Initialized
      | Ok _ | Error _ -> Error Secret_service_unavailable)
  | Ok _ | Error _ -> Error Secret_service_unavailable

let key_handle_of_bytes = Bootstrap.Key_handle.of_bytes

let generate_capability () =
  try
    Mirage_crypto_rng_unix.use_default ();
    let encryption_key =
      Mirage_crypto_rng.generate 32
      |> Envelope.key_of_bytes
      |> Result.map_error (fun _ -> Entropy_failure)
    in
    let address_key =
      Mirage_crypto_rng.generate 32
      |> Address.key_of_bytes
      |> Result.map_error (fun _ -> Entropy_failure)
    in
    let signing_key, _ = Mirage_crypto_ec.Ed25519.generate () in
    let* encryption_key = encryption_key in
    let* address_key = address_key in
    Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
    |> Result.map_error (fun error -> Bootstrap_error error)
  with _ -> Error Entropy_failure

let generate_key_handle () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Bootstrap.Key_handle.of_bytes (Mirage_crypto_rng.generate 32)
    |> Result.map_error (fun _ -> Entropy_failure)
  with _ -> Error Entropy_failure

let enrollment_of_initialization initialization repository =
  let initialization =
    match initialization with
    | Bootstrap_store.Initialized -> Initialized
    | Bootstrap_store.Already_initialized -> Already_initialized
  in
  { initialization; repository }

let enroll ~service ~root ~repository_id ~device_id ~key_handle ~capability =
  let* bootstrap =
    Bootstrap.make ~repository_id ~device_id ~key_handle ~capability
      ~mandatory_features:0L
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  let* _ = store_capability ~service ~key_handle ~capability in
  let* initialization =
    Bootstrap_store.initialize ~root bootstrap
    |> Result.map_error (fun error -> Bootstrap_store_error error)
  in
  let* repository =
    Bootstrap_store.open_repository ~root ~capability
    |> Result.map_error (fun error -> Bootstrap_store_error error)
  in
  Ok (enrollment_of_initialization initialization repository)

let create_and_enroll ~service ~root ~repository_id ~device_id =
  let* capability = generate_capability () in
  let* key_handle = generate_key_handle () in
  enroll ~service ~root ~repository_id ~device_id ~key_handle ~capability

let open_repository ~service ~root =
  let* bootstrap =
    Bootstrap_store.read_bootstrap ~root
    |> Result.map_error (fun error -> Bootstrap_store_error error)
  in
  let* capability =
    read_capability ~service ~key_handle:(Bootstrap.key_handle bootstrap)
  in
  Bootstrap_store.open_repository ~root ~capability
  |> Result.map_error (fun error -> Bootstrap_store_error error)
