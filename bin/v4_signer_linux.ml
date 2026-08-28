module Native = Yeokcham_v4_secret_service
module Test_file = V4_signer_test_file

type error = Native of Native.error | Test of string

let error_to_string = function
  | Native error -> Native.error_to_string error
  | Test error -> error

let create () =
  if Test_file.enabled () then
    Test_file.create () |> Result.map_error (fun e -> Test e)
  else Native.create () |> Result.map_error (fun e -> Native e)

let load device =
  if Test_file.enabled () then
    Test_file.load device |> Result.map_error (fun e -> Test e)
  else Native.load device |> Result.map_error (fun e -> Native e)
