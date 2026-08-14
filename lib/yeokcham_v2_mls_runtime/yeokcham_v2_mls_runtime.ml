module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Ipc = Yeokcham_v2_secure_ipc
module Model = Yeokcham_v2_model

type configuration = { runtime_path : string }

type add_member_result = {
  add_issuer_runtime_state : string;
  add_recipient_runtime_state : string;
  add_commit : string;
  add_welcome : string;
  add_previous_epoch : int64;
  add_next_epoch : int64;
}

type remove_member_result = {
  remove_issuer_runtime_state : string;
  remove_commit : string;
  remove_previous_epoch : int64;
  remove_next_epoch : int64;
}

type apply_commit_result =
  | Applied of {
      applied_runtime_state : string;
      applied_previous_epoch : int64;
      applied_next_epoch : int64;
    }
  | Removed of { removed_previous_epoch : int64; removed_observed_epoch : int64 }

type error =
  | Runtime_missing of string
  | Runtime_start_failed of string
  | Runtime_io_error of { operation : string; message : string }
  | Runtime_exit of {
      exit_code : int option;
      signal : int option;
      message : string;
    }
  | Ipc_error of Ipc.error
  | Invalid_runtime_response of string
  | Runtime_refused of string
  | Entropy_failure

let max_runtime_state_bytes = 24 * 1024
let request_schema_version = 1L
let operation_bootstrap = 1L
let operation_derive_metadata_key = 2L
let operation_add_member = 3L
let operation_remove_member = 4L
let operation_apply_commit = 5L
let ( let* ) = Result.bind

let default_configuration =
  {
    runtime_path =
      Option.value
        ~default:
          "tools/yeokcham-secure-runtime/target/release/yeokcham-secure-runtime"
        (Sys.getenv_opt "YEOKCHAM_MLS_RUNTIME");
  }

let configuration_with ?runtime_path configuration =
  {
    runtime_path = Option.value ~default:configuration.runtime_path runtime_path;
  }

let error_to_string = function
  | Runtime_missing path ->
      "MLS secure runtime is missing or not executable: " ^ path
  | Runtime_start_failed message ->
      "could not start MLS secure runtime: " ^ message
  | Runtime_io_error { operation; message } ->
      Printf.sprintf "MLS secure runtime %s failed: %s" operation message
  | Runtime_exit { exit_code; signal; message } ->
      Printf.sprintf "MLS secure runtime exited (exit=%s signal=%s): %s"
        (Option.fold ~none:"none" ~some:string_of_int exit_code)
        (Option.fold ~none:"none" ~some:string_of_int signal)
        message
  | Ipc_error error -> Ipc.error_to_string error
  | Invalid_runtime_response detail ->
      "invalid MLS secure-runtime response: " ^ detail
  | Runtime_refused detail -> "MLS secure runtime refused operation: " ^ detail
  | Entropy_failure -> "OS CSPRNG unavailable while creating an MLS IPC session"

let value_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_runtime_response (Encoding.construction_error_to_string error))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_runtime_response (name ^ " must be bytes"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_runtime_response (name ^ " must be an integer"))

let fields name count = function
  | Encoding.Array values when List.length values = count -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_runtime_response
           (Printf.sprintf "%s has the wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_runtime_response (name ^ " must be an array"))

let encode_payload values = value_array values |> Result.map Encoding.encode

let decode_payload payload =
  Encoding.decode payload
  |> Result.map_error (fun error ->
      Invalid_runtime_response (Encoding.decode_error_to_string error))

let generate_session () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Mirage_crypto_rng.generate Ipc.Session_id.byte_length
    |> Ipc.Session_id.of_bytes
    |> Result.map_error (fun _ -> Entropy_failure)
  with _ -> Error Entropy_failure

let executable path =
  try
    Unix.access path [ Unix.X_OK ];
    true
  with Unix.Unix_error _ -> false

let io_error operation = function
  | Unix.Unix_error (error, _, _) ->
      Runtime_io_error { operation; message = Unix.error_message error }
  | Sys_error message -> Runtime_io_error { operation; message }
  | error -> Runtime_io_error { operation; message = Printexc.to_string error }

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
            (Runtime_io_error
               { operation = "write"; message = "zero-byte pipe write" })
        else write (offset + count)
      with (Unix.Unix_error _ | Sys_error _) as error ->
        Error (io_error "write" error)
  in
  write 0

let framed message =
  let payload = Ipc.encode message in
  let length = String.length payload in
  if length > Ipc.max_frame_bytes then
    Error (Ipc_error (Ipc.Frame_too_large length))
  else
    let header = Bytes.create 4 in
    Bytes.set header 0 (Char.chr ((length lsr 24) land 0xff));
    Bytes.set header 1 (Char.chr ((length lsr 16) land 0xff));
    Bytes.set header 2 (Char.chr ((length lsr 8) land 0xff));
    Bytes.set header 3 (Char.chr (length land 0xff));
    Ok (Bytes.unsafe_to_string header ^ payload)

let parse_frames bytes =
  let length = String.length bytes in
  let rec parse offset messages =
    if offset = length then Ok (List.rev messages)
    else if length - offset < 4 then
      Error (Invalid_runtime_response "truncated IPC frame header")
    else
      let frame_length =
        (Char.code bytes.[offset] lsl 24)
        lor (Char.code bytes.[offset + 1] lsl 16)
        lor (Char.code bytes.[offset + 2] lsl 8)
        lor Char.code bytes.[offset + 3]
      in
      if frame_length > Ipc.max_frame_bytes then
        Error (Invalid_runtime_response "oversized IPC frame")
      else if length - offset - 4 < frame_length then
        Error (Invalid_runtime_response "truncated IPC frame")
      else
        let frame = String.sub bytes (offset + 4) frame_length in
        let* message =
          Ipc.decode frame |> Result.map_error (fun error -> Ipc_error error)
        in
        parse (offset + 4 + frame_length) (message :: messages)
  in
  parse 0 []

let read_all descriptor limit =
  let buffer = Buffer.create 1024 in
  let chunk = Bytes.create 4096 in
  let rec read () =
    try
      match Unix.read descriptor chunk 0 (Bytes.length chunk) with
      | 0 -> Ok (Buffer.contents buffer)
      | count ->
          if Buffer.length buffer + count > limit then
            Error
              (Runtime_io_error
                 {
                   operation = "read";
                   message = "runtime output exceeds bound";
                 })
          else (
            Buffer.add_subbytes buffer chunk 0 count;
            read ())
    with (Unix.Unix_error _ | Sys_error _) as error ->
      Error (io_error "read" error)
  in
  read ()

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let run configuration ~hello ~request =
  if not (executable configuration.runtime_path) then
    Error (Runtime_missing configuration.runtime_path)
  else
    let* hello = framed (Ipc.Hello hello) in
    let* request = framed (Ipc.Request request) in
    if String.length hello + String.length request > Ipc.max_frame_bytes then
      Error (Invalid_runtime_response "combined MLS IPC input exceeds bound")
    else
      let stdin_read, stdin_write = Unix.pipe () in
      let stdout_read, stdout_write = Unix.pipe () in
      let stderr_read, stderr_write = Unix.pipe () in
      Fun.protect
        ~finally:(fun () ->
          List.iter close_noerr
            [
              stdin_read;
              stdin_write;
              stdout_read;
              stdout_write;
              stderr_read;
              stderr_write;
            ])
        (fun () ->
          match
            try
              Ok
                (Unix.create_process_env configuration.runtime_path
                   [| configuration.runtime_path |]
                   [| "PATH=/usr/bin:/bin" |] stdin_read stdout_write
                   stderr_write)
            with Unix.Unix_error (_, _, message) ->
              Error (Runtime_start_failed message)
          with
          | Error error -> Error error
          | Ok child -> (
              close_noerr stdin_read;
              close_noerr stdout_write;
              close_noerr stderr_write;
              let* () =
                write_all stdin_write (Bytes.of_string (hello ^ request))
              in
              close_noerr stdin_write;
              let status =
                try Ok (snd (Unix.waitpid [] child))
                with Unix.Unix_error (_, _, message) ->
                  Error (Runtime_start_failed message)
              in
              let output = read_all stdout_read Ipc.max_frame_bytes in
              let stderr = read_all stderr_read 4096 in
              close_noerr stdout_read;
              close_noerr stderr_read;
              let* status = status in
              let* output = output in
              let* stderr = stderr in
              match status with
              | Unix.WEXITED 0 -> parse_frames output
              | Unix.WEXITED exit_code ->
                  Error
                    (Runtime_exit
                       {
                         exit_code = Some exit_code;
                         signal = None;
                         message = stderr;
                       })
              | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
                  Error
                    (Runtime_exit
                       {
                         exit_code = None;
                         signal = Some signal;
                         message = stderr;
                       })))

let invoke configuration payload decode =
  let* session_id = generate_session () in
  let* hello =
    Ipc.make_hello ~session_id ~supported_versions:[ Ipc.protocol_version ]
      ~required_capabilities:[ Ipc.Mls ] ~optional_capabilities:[]
      ~mandatory_features:0L
    |> Result.map_error (fun error -> Ipc_error error)
  in
  let* request_payload = encode_payload payload in
  let* messages =
    let* server_response =
      Ipc.make_server ~supported_versions:[ Ipc.protocol_version ]
        ~capabilities:[ Ipc.Mls ]
      |> Result.map_error (fun error -> Ipc_error error)
    in
    let* acknowledgement =
      Ipc.accept_hello server_response hello
      |> Result.map snd
      |> Result.map_error (fun error -> Ipc_error error)
    in
    let* negotiated =
      Ipc.validate_hello_ack ~hello acknowledgement
      |> Result.map_error (fun error -> Ipc_error error)
    in
    let* request =
      Ipc.make_request ~negotiated ~sequence:0L ~operation:Ipc.Mls_operation
        ~payload:request_payload ~mandatory_features:0L
      |> Result.map_error (fun error -> Ipc_error error)
    in
    run configuration ~hello ~request
    |> Result.map (fun messages -> (request, messages))
  in
  match messages with
  | request, [ acknowledgement_message; response_message ] ->
      let* acknowledgement =
        match Ipc.hello_ack_of_message acknowledgement_message with
        | Some acknowledgement -> Ok acknowledgement
        | None -> Error (Invalid_runtime_response "expected acknowledgement")
      in
      let* response =
        match Ipc.response_of_message response_message with
        | Some response -> Ok response
        | None -> Error (Invalid_runtime_response "expected response")
      in
      let* _ =
        Ipc.validate_hello_ack ~hello acknowledgement
        |> Result.map_error (fun error -> Ipc_error error)
      in
      let* () =
        Ipc.validate_response ~request response
        |> Result.map_error (fun error -> Ipc_error error)
      in
      if Ipc.response_result response = Ipc.Refused then
        Error (Runtime_refused (Ipc.response_payload response))
      else decode (Ipc.response_payload response)
  | _ ->
      Error (Invalid_runtime_response "expected acknowledgement and response")

let bootstrap configuration ~group_id ~device_id =
  let payload =
    [
      Encoding.integer request_schema_version;
      Encoding.integer operation_bootstrap;
      Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
      Encoding.bytes (Model.Device_id.to_bytes device_id);
      Encoding.bytes "";
    ]
  in
  invoke configuration payload (fun response ->
      let* value = decode_payload response in
      let* values = fields "MLS bootstrap response" 2 value in
      match values with
      | [ version; state ] ->
          let* version = integer "MLS bootstrap response version" version in
          let* state = bytes "MLS bootstrap state" state in
          if not (Int64.equal version request_schema_version) then
            Error (Invalid_runtime_response "unsupported MLS response version")
          else if
            String.length state = 0
            || String.length state > max_runtime_state_bytes
          then Error (Invalid_runtime_response "MLS state violates bounds")
          else Ok state
      | _ -> assert false)

let derive_metadata_key configuration ~group_id ~device_id ~runtime_state =
  if
    String.length runtime_state = 0
    || String.length runtime_state > max_runtime_state_bytes
  then Error (Invalid_runtime_response "MLS state violates bounds")
  else
    let payload =
      [
        Encoding.integer request_schema_version;
        Encoding.integer operation_derive_metadata_key;
        Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
        Encoding.bytes (Model.Device_id.to_bytes device_id);
        Encoding.bytes runtime_state;
      ]
    in
    invoke configuration payload (fun response ->
        let* value = decode_payload response in
        let* values = fields "MLS exporter response" 2 value in
        match values with
        | [ version; key ] ->
            let* version = integer "MLS exporter response version" version in
            let* key = bytes "MLS exporter key" key in
            if not (Int64.equal version request_schema_version) then
              Error
                (Invalid_runtime_response "unsupported MLS response version")
            else
              Envelope.key_of_bytes key
              |> Result.map_error (fun error ->
                  Invalid_runtime_response (Envelope.error_to_string error))
        | _ -> assert false)

let add_member configuration ~group_id ~issuer_device_id ~issuer_runtime_state
    ~recipient_device_id =
  if
    String.length issuer_runtime_state = 0
    || String.length issuer_runtime_state > max_runtime_state_bytes
  then Error (Invalid_runtime_response "MLS issuer state violates bounds")
  else
    let payload =
      [
        Encoding.integer request_schema_version;
        Encoding.integer operation_add_member;
        Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
        Encoding.bytes (Model.Device_id.to_bytes issuer_device_id);
        Encoding.bytes issuer_runtime_state;
        Encoding.bytes (Model.Device_id.to_bytes recipient_device_id);
      ]
    in
    invoke configuration payload (fun response ->
        let* value = decode_payload response in
        let* values = fields "MLS add-member response" 7 value in
        match values with
        | [ version; issuer_state; recipient_state; commit; welcome; previous_epoch; next_epoch ] ->
            let* version = integer "MLS add-member response version" version in
            let* issuer_runtime_state =
              bytes "MLS add-member issuer state" issuer_state
            in
            let* recipient_runtime_state =
              bytes "MLS add-member recipient state" recipient_state
            in
            let* commit = bytes "MLS add-member commit" commit in
            let* welcome = bytes "MLS add-member welcome" welcome in
            let* previous_epoch = integer "MLS add-member previous epoch" previous_epoch in
            let* next_epoch = integer "MLS add-member next epoch" next_epoch in
            if not (Int64.equal version request_schema_version) then
              Error
                (Invalid_runtime_response "unsupported MLS response version")
            else if
              String.length issuer_runtime_state = 0
              || String.length issuer_runtime_state > max_runtime_state_bytes
              || String.length recipient_runtime_state = 0
              || String.length recipient_runtime_state > max_runtime_state_bytes
            then
              Error
                (Invalid_runtime_response "MLS response state violates bounds")
            else if String.length commit = 0 || String.length welcome = 0 then
              Error
                (Invalid_runtime_response
                   "MLS add-member response omits protocol bytes")
            else if not (Int64.equal next_epoch (Int64.succ previous_epoch)) then
              Error (Invalid_runtime_response "MLS add-member epoch did not advance once")
            else
              Ok
                {
                  add_issuer_runtime_state = issuer_runtime_state;
                  add_recipient_runtime_state = recipient_runtime_state;
                  add_commit = commit;
                  add_welcome = welcome;
                  add_previous_epoch = previous_epoch;
                  add_next_epoch = next_epoch;
                }
        | _ -> assert false)

let remove_member configuration ~group_id ~issuer_device_id ~issuer_runtime_state
    ~removed_device_id =
  if
    String.length issuer_runtime_state = 0
    || String.length issuer_runtime_state > max_runtime_state_bytes
  then Error (Invalid_runtime_response "MLS issuer state violates bounds")
  else
    let payload =
      [
        Encoding.integer request_schema_version;
        Encoding.integer operation_remove_member;
        Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
        Encoding.bytes (Model.Device_id.to_bytes issuer_device_id);
        Encoding.bytes issuer_runtime_state;
        Encoding.bytes (Model.Device_id.to_bytes removed_device_id);
      ]
    in
    invoke configuration payload (fun response ->
        let* value = decode_payload response in
        let* values = fields "MLS remove-member response" 5 value in
        match values with
        | [ version; issuer_state; commit; previous_epoch; next_epoch ] ->
            let* version = integer "MLS remove-member response version" version in
            let* issuer_runtime_state = bytes "MLS remove-member issuer state" issuer_state in
            let* commit = bytes "MLS remove-member commit" commit in
            let* previous_epoch = integer "MLS remove-member previous epoch" previous_epoch in
            let* next_epoch = integer "MLS remove-member next epoch" next_epoch in
            if not (Int64.equal version request_schema_version) then
              Error (Invalid_runtime_response "unsupported MLS response version")
            else if
              String.length issuer_runtime_state = 0
              || String.length issuer_runtime_state > max_runtime_state_bytes
              || String.length commit = 0
            then Error (Invalid_runtime_response "MLS remove-member response violates bounds")
            else if not (Int64.equal next_epoch (Int64.succ previous_epoch)) then
              Error (Invalid_runtime_response "MLS removal epoch did not advance once")
            else
              Ok
                {
                  remove_issuer_runtime_state = issuer_runtime_state;
                  remove_commit = commit;
                  remove_previous_epoch = previous_epoch;
                  remove_next_epoch = next_epoch;
                }
        | _ -> assert false)

let apply_commit configuration ~group_id ~device_id ~runtime_state ~commit =
  if
    String.length runtime_state = 0
    || String.length runtime_state > max_runtime_state_bytes
    || String.length commit = 0
  then Error (Invalid_runtime_response "MLS apply-commit request violates bounds")
  else
    let payload =
      [
        Encoding.integer request_schema_version;
        Encoding.integer operation_apply_commit;
        Encoding.bytes (Model.Mls_group_id.to_bytes group_id);
        Encoding.bytes (Model.Device_id.to_bytes device_id);
        Encoding.bytes runtime_state;
        Encoding.bytes commit;
      ]
    in
    invoke configuration payload (fun response ->
        let* value = decode_payload response in
        let* values = fields "MLS apply-commit response" 5 value in
        match values with
        | [ version; outcome; state; previous_epoch; next_epoch ] ->
            let* version = integer "MLS apply-commit response version" version in
            let* outcome = integer "MLS apply-commit outcome" outcome in
            let* state = bytes "MLS apply-commit state" state in
            let* previous_epoch = integer "MLS apply-commit previous epoch" previous_epoch in
            let* next_epoch = integer "MLS apply-commit next epoch" next_epoch in
            if not (Int64.equal version request_schema_version) then
              Error (Invalid_runtime_response "unsupported MLS response version")
            else if Int64.equal outcome 1L then
              if
                String.length state = 0
                || String.length state > max_runtime_state_bytes
                || not (Int64.equal next_epoch (Int64.succ previous_epoch))
              then Error (Invalid_runtime_response "MLS active rekey response violates bounds")
              else
                Ok
                  (Applied
                     {
                       applied_runtime_state = state;
                       applied_previous_epoch = previous_epoch;
                       applied_next_epoch = next_epoch;
                     })
            else if Int64.equal outcome 2L && String.equal state "" then
              Ok
                (Removed
                   {
                     removed_previous_epoch = previous_epoch;
                     removed_observed_epoch = next_epoch;
                   })
            else Error (Invalid_runtime_response "MLS apply-commit outcome is invalid")
        | _ -> assert false)
