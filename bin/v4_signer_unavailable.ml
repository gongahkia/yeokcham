module Model = Yeokcham_v4_model

type error = Unsupported_platform

let error_to_string Unsupported_platform =
  "V4 native signing is supported only by macOS Keychain or Linux Secret \
   Service"

let create () = Error Unsupported_platform
let load_native (_ : Model.Device_id.t) = Error Unsupported_platform
let load ~root:_ (_ : Model.Device_id.t) = Error Unsupported_platform
