module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

let ( let* ) = Result.bind

type error =
  | Keychain_unavailable
  | Keychain_locked
  | Keychain_item_missing
  | Keychain_item_conflict
  | Invalid_keychain_material
  | Trust_error of Trust.error

external lookup_raw : string -> string -> int * string option
  = "caml_yeokcham_v4_macos_keychain_lookup"

external store_raw : string -> string -> string -> int
  = "caml_yeokcham_v4_macos_keychain_store"

let service_name = "io.github.gongahkia.yeokcham.v4.device-signing"
let account_prefix = "v4-ed25519-device-1/"

let error_to_string = function
  | Keychain_unavailable ->
      "macOS Keychain is unavailable or rejected the request"
  | Keychain_locked -> "macOS Keychain is locked or requires user interaction"
  | Keychain_item_missing ->
      "local V4 signing key is missing from macOS Keychain"
  | Keychain_item_conflict ->
      "macOS Keychain already contains different material for this V4 device"
  | Invalid_keychain_material ->
      "macOS Keychain returned invalid V4 signing material"
  | Trust_error error -> Trust.error_to_string error

let account device = account_prefix ^ Model.Device_id.to_string device

let capability_for_device device bytes =
  let* capability =
    Trust.signing_capability_of_private_key bytes
    |> Result.map_error (fun _ -> Invalid_keychain_material)
  in
  let public_key = Trust.signing_public_key capability in
  let* actual =
    Trust.device_of_public_key public_key
    |> Result.map_error (fun error -> Trust_error error)
  in
  if Model.Device_id.equal (Trust.device_id actual) device then Ok capability
  else Error Invalid_keychain_material

let lookup device =
  match lookup_raw service_name (account device) with
  | 0, Some bytes -> capability_for_device device bytes
  | 0, None | 3, None | _, Some _ -> Error Keychain_unavailable
  | 1, None -> Error Keychain_item_missing
  | 2, None -> Error Keychain_locked
  | _, None -> Error Keychain_unavailable

let store_new device capability =
  let* bytes =
    Trust.signing_private_key_bytes capability
    |> Result.map_error (fun _ -> Invalid_keychain_material)
  in
  match lookup_raw service_name (account device) with
  | 0, Some existing ->
      let* existing = capability_for_device device existing in
      let* existing =
        Trust.signing_private_key_bytes existing
        |> Result.map_error (fun _ -> Invalid_keychain_material)
      in
      if String.equal existing bytes then Ok ()
      else Error Keychain_item_conflict
  | 0, None | 3, None | _, Some _ -> Error Keychain_unavailable
  | 1, None -> (
      match store_raw service_name (account device) bytes with
      | 0 -> Ok ()
      | 1 -> (
          match lookup device with
          | Ok existing ->
              let* existing =
                Trust.signing_private_key_bytes existing
                |> Result.map_error (fun _ -> Invalid_keychain_material)
              in
              if String.equal existing bytes then Ok ()
              else Error Keychain_item_conflict
          | Error error -> Error error)
      | 2 -> Error Keychain_locked
      | _ -> Error Keychain_unavailable)
  | 2, None -> Error Keychain_locked
  | _, None -> Error Keychain_unavailable

let create () =
  let* generated =
    Trust.generate_device ()
    |> Result.map_error (fun error -> Trust_error error)
  in
  let device = Trust.generated_identity generated in
  let capability = Trust.generated_signing_capability generated in
  let* () = store_new (Trust.device_id device) capability in
  Ok (device, capability)

let load = lookup
