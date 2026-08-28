(** Explicit test-only signer provider.

    It is unavailable unless the test runner sets the directory environment
    variable. Production commands therefore never downgrade native custody to a
    project-file key. *)

module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

let ( let* ) = Result.bind
let environment = "YEOKCHAM_V4_TEST_SIGNER_DIRECTORY"
let enabled () = Option.is_some (Sys.getenv_opt environment)

let directory () =
  match Sys.getenv_opt environment with
  | Some directory -> Ok directory
  | None -> Error "the explicit V4 test signer is not enabled"

let error_of_unix path operation error =
  Printf.sprintf "V4 test signer %s %s: %s" operation path
    (Unix.error_message error)

let private_key_path directory device =
  Filename.concat directory (Model.Device_id.to_string device)

let capability_for_device device bytes =
  let* capability =
    Trust.signing_capability_of_private_key bytes
    |> Result.map_error (fun _ ->
        "V4 test signer has invalid private key bytes")
  in
  let* actual =
    Trust.device_of_public_key (Trust.signing_public_key capability)
    |> Result.map_error Trust.error_to_string
  in
  if Model.Device_id.equal (Trust.device_id actual) device then Ok capability
  else Error "V4 test signer key does not match its public device identifier"

let load device =
  let* directory = directory () in
  let path = private_key_path directory device in
  try
    let info = Unix.lstat path in
    if info.Unix.st_kind <> Unix.S_REG then
      Error "V4 test signer item is not a regular file"
    else
      In_channel.with_open_bin path In_channel.input_all
      |> capability_for_device device
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error "V4 test signer key is missing"
  | Unix.Unix_error (error, operation, _) ->
      Error (error_of_unix path operation error)
  | Sys_error message -> Error ("V4 test signer read " ^ path ^ ": " ^ message)

let store_new device capability =
  let* directory = directory () in
  let path = private_key_path directory device in
  let bytes = Trust.signing_private_key_bytes capability in
  try
    let channel =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      |> Unix.out_channel_of_descr
    in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        Out_channel.output_string channel bytes;
        Out_channel.flush channel);
    Ok ()
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> (
      match load device with
      | Ok existing ->
          if String.equal (Trust.signing_private_key_bytes existing) bytes then
            Ok ()
          else Error "V4 test signer device item already contains another key"
      | Error error -> Error error)
  | Unix.Unix_error (error, operation, _) ->
      Error (error_of_unix path operation error)

let create () =
  let* generated =
    Trust.generate_device () |> Result.map_error Trust.error_to_string
  in
  let device = Trust.generated_identity generated in
  let capability = Trust.generated_signing_capability generated in
  let* () = store_new (Trust.device_id device) capability in
  Ok (device, capability)
