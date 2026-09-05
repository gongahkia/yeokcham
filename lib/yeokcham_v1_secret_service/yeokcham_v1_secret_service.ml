module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust

type error =
  | Secret_service_unavailable
  | Secret_service_locked
  | Secret_missing
  | Secret_conflict
  | Invalid_secret_material
  | Trust_error of Trust.error

let ( let* ) = Result.bind
let secret_tool = "/usr/bin/secret-tool"
let busctl = "/usr/bin/busctl"
let max_output = 4096
let timeout_seconds = 5.0
let application = "io.github.gongahkia.yeokcham"
let schema = "v1-device-signing-1"
let label = "Yeokcham V1 device signing key"
let secret_prefix = "yeokcham-v1-ed25519-1:"

let error_to_string = function
  | Secret_service_unavailable ->
      "Linux Secret Service is unavailable or rejected the request"
  | Secret_service_locked -> "Linux Secret Service default collection is locked"
  | Secret_missing ->
      "local V1 signing key is missing from Linux Secret Service"
  | Secret_conflict ->
      "Linux Secret Service already contains different material for this V1 \
       device"
  | Invalid_secret_material ->
      "Linux Secret Service returned invalid V1 signing material"
  | Trust_error error -> Trust.error_to_string error

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let write_all descriptor bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if count = 0 then Error () else loop (offset + count)
      with Unix.Unix_error _ -> Error ()
  in
  loop 0

let command ~program ~arguments ~stdin =
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
    let process =
      Unix.create_process program
        (Array.of_list (program :: arguments))
        stdin_read stdout_write stderr_write
    in
    close_noerr stdin_read;
    close_noerr stdout_write;
    close_noerr stderr_write;
    let input = write_all stdin_write stdin in
    close_noerr stdin_write;
    match input with
    | Error () ->
        (try Unix.kill process Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] process);
        close_noerr stdout_read;
        close_noerr stderr_read;
        Error ()
    | Ok () ->
        Unix.set_nonblock stdout_read;
        Unix.set_nonblock stderr_read;
        let output = Buffer.create 128 in
        let scratch = Bytes.create 512 in
        let rec drain descriptor open_ =
          if not open_ then Ok false
          else
            try
              match Unix.read descriptor scratch 0 (Bytes.length scratch) with
              | 0 ->
                  close_noerr descriptor;
                  Ok false
              | count ->
                  if Buffer.length output + count > max_output then Error ()
                  else (
                    Buffer.add_subbytes output scratch 0 count;
                    drain descriptor true)
            with
            | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                Ok true
            | Unix.Unix_error _ ->
                close_noerr descriptor;
                Ok false
        in
        let deadline = Unix.gettimeofday () +. timeout_seconds in
        let rec collect stdout_open stderr_open =
          if (not stdout_open) && not stderr_open then
            match Unix.waitpid [] process with
            | _, Unix.WEXITED code -> Ok (code, Buffer.contents output)
            | _, Unix.WSIGNALED _ | _, Unix.WSTOPPED _ -> Error ()
          else
            let remaining = deadline -. Unix.gettimeofday () in
            if remaining <= 0.0 then Error ()
            else
              let readable =
                (if stdout_open then [ stdout_read ] else [])
                @ if stderr_open then [ stderr_read ] else []
              in
              match Unix.select readable [] [] remaining with
              | [], _, _ -> Error ()
              | ready, _, _ ->
                  let* stdout_open =
                    if List.mem stdout_read ready then drain stdout_read true
                    else Ok stdout_open
                  in
                  let* stderr_open =
                    if List.mem stderr_read ready then drain stderr_read true
                    else Ok stderr_open
                  in
                  collect stdout_open stderr_open
        in
        let result = collect true true in
        (match result with
        | Ok _ -> ()
        | Error () ->
            (try Unix.kill process Sys.sigkill with Unix.Unix_error _ -> ());
            ignore (Unix.waitpid [] process));
        close_noerr stdout_read;
        close_noerr stderr_read;
        result
  with Unix.Unix_error _ ->
    close_all ();
    Error ()

let hex bytes =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length bytes * 2)
    (fun index ->
      let value = Char.code bytes.[index / 2] in
      if index mod 2 = 0 then alphabet.[value lsr 4]
      else alphabet.[value land 0x0f])

let decode_hex text =
  let nibble = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
    | _ -> None
  in
  if String.length text mod 2 <> 0 then Error ()
  else
    let decoded = Bytes.create (String.length text / 2) in
    let rec loop offset =
      if offset = String.length text then Ok (Bytes.unsafe_to_string decoded)
      else
        match (nibble text.[offset], nibble text.[offset + 1]) with
        | Some high, Some low ->
            Bytes.set decoded (offset / 2) (Char.chr ((high lsl 4) lor low));
            loop (offset + 2)
        | None, _ | _, None -> Error ()
    in
    loop 0

let trim_one_newline value =
  if String.ends_with ~suffix:"\n" value then
    String.sub value 0 (String.length value - 1)
  else value

let attributes device =
  [
    "application";
    application;
    "schema";
    schema;
    "device";
    Model.Device_id.to_string device;
  ]

let preflight () =
  match
    command ~program:busctl
      ~arguments:
        [
          "--user";
          "get-property";
          "org.freedesktop.secrets";
          "/org/freedesktop/secrets/aliases/default";
          "org.freedesktop.Secret.Collection";
          "Locked";
        ]
      ~stdin:""
  with
  | Ok (0, value) -> (
      match String.trim value with
      | "b false" -> Ok ()
      | "b true" -> Error Secret_service_locked
      | _ -> Error Secret_service_unavailable)
  | Ok _ | Error () -> Error Secret_service_unavailable

let encoded_secret capability =
  Trust.signing_private_key_bytes capability
  |> Result.map (fun bytes -> secret_prefix ^ hex bytes)
  |> Result.map_error (fun _ -> Invalid_secret_material)

let capability_for_device device secret =
  let secret = trim_one_newline secret in
  if not (String.starts_with ~prefix:secret_prefix secret) then
    Error Invalid_secret_material
  else
    let encoded =
      String.sub secret
        (String.length secret_prefix)
        (String.length secret - String.length secret_prefix)
    in
    let* private_key =
      decode_hex encoded |> Result.map_error (fun () -> Invalid_secret_material)
    in
    let* capability =
      Trust.signing_capability_of_private_key private_key
      |> Result.map_error (fun _ -> Invalid_secret_material)
    in
    let* actual =
      Trust.device_of_public_key (Trust.signing_public_key capability)
      |> Result.map_error (fun error -> Trust_error error)
    in
    if Model.Device_id.equal (Trust.device_id actual) device then Ok capability
    else Error Invalid_secret_material

let load device =
  let* () = preflight () in
  match
    command ~program:secret_tool
      ~arguments:("lookup" :: attributes device)
      ~stdin:""
  with
  | Ok (0, secret) -> capability_for_device device secret
  | Ok (1, "") -> Error Secret_missing
  | Ok _ | Error () -> Error Secret_service_unavailable

let store_new device capability =
  let* () = preflight () in
  let* secret = encoded_secret capability in
  match
    command ~program:secret_tool
      ~arguments:("lookup" :: attributes device)
      ~stdin:""
  with
  | Ok (0, existing) ->
      if String.equal (trim_one_newline existing) secret then Ok ()
      else Error Secret_conflict
  | Ok (1, "") -> (
      match
        command ~program:secret_tool
          ~arguments:("store" :: ("--label=" ^ label) :: attributes device)
          ~stdin:secret
      with
      | Ok (0, _) -> Ok ()
      | Ok _ | Error () -> Error Secret_service_unavailable)
  | Ok _ | Error () -> Error Secret_service_unavailable

let create () =
  let* generated =
    Trust.generate_device ()
    |> Result.map_error (fun error -> Trust_error error)
  in
  let device = Trust.generated_identity generated in
  let capability = Trust.generated_signing_capability generated in
  let* () = store_new (Trust.device_id device) capability in
  Ok (device, capability)
