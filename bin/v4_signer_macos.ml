module Native = Yeokcham_v4_macos_keychain
module Test_file = V4_signer_test_file
module Custody = Yeokcham_v4_custody

type error = Native of Native.error | Test of string | Custody of Custody.error

let error_to_string = function
  | Native error -> Native.error_to_string error
  | Test error -> error
  | Custody error -> Custody.error_to_string error

let create () =
  if Test_file.enabled () then
    Test_file.create () |> Result.map_error (fun e -> Test e)
  else Native.create () |> Result.map_error (fun e -> Native e)

let load_native device =
  if Test_file.enabled () then
    Test_file.load device |> Result.map_error (fun e -> Test e)
  else Native.load device |> Result.map_error (fun e -> Native e)

let load ~root device =
  if Test_file.enabled () then load_native device
  else if Custody.configured ~root device then
    Custody.load ~root device |> Result.map_error (fun error -> Custody error)
  else load_native device
