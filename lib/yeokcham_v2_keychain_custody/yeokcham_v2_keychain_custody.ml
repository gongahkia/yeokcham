module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model

type item = { service_name : string; account : string; legacy_key_tag : string }

type lookup_result =
  | Found of string
  | Missing
  | Locked
  | Unavailable
  | Non_exportable_key
  | Unsupported_key_item

type store_result =
  | Stored
  | Already_present
  | Store_locked
  | Store_unavailable

type remove_result =
  | Removed
  | Remove_missing
  | Remove_locked
  | Remove_unavailable

type backend = {
  lookup : item -> lookup_result;
  store : item -> string -> store_result;
  remove : item -> remove_result;
}

type service = { backend : backend }
type initialization = Initialized | Already_initialized

type enrollment = {
  initialization : initialization;
  repository : Bootstrap_store.repository;
}

type error =
  | Keychain_unavailable
  | Keychain_locked
  | Keychain_item_missing
  | Keychain_handle_in_use
  | Keychain_non_exportable_key
  | Keychain_unsupported_key_item
  | Invalid_keychain_material
  | Bootstrap_error of Bootstrap.error
  | Bootstrap_store_error of Bootstrap_store.error
  | Entropy_failure

let ( let* ) = Result.bind
let service_name = "io.github.gongahkia.yeokcham.v2.local-capability"
let account_prefix = "v2-local-capability-1/"
let legacy_key_tag_prefix = "io.github.gongahkia.yeokcham/v2/local-capability/"
let capability_prefix = "yeokcham-v2-local-capability-v1:"

let error_to_string = function
  | Keychain_unavailable ->
      "macOS Keychain is unavailable or rejected the request"
  | Keychain_locked -> "macOS Keychain is locked or requires user interaction"
  | Keychain_item_missing -> "local capability is missing from macOS Keychain"
  | Keychain_handle_in_use ->
      "macOS Keychain already contains different material for this key handle"
  | Keychain_non_exportable_key ->
      "a non-exportable macOS key exists for this locator; raw capability \
       fallback is unavailable"
  | Keychain_unsupported_key_item ->
      "an unsupported exportable macOS key exists for this locator"
  | Invalid_keychain_material ->
      "macOS Keychain returned invalid local capability material"
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Bootstrap_store_error error -> Bootstrap_store.error_to_string error
  | Entropy_failure -> "OS CSPRNG unavailable while generating local capability"

let service ~backend = { backend }

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

let account_of_key_handle handle =
  account_prefix ^ Bootstrap.Key_handle.to_hex handle

let item_of_key_handle handle =
  let account = account_of_key_handle handle in
  {
    service_name;
    account;
    legacy_key_tag = legacy_key_tag_prefix ^ Bootstrap.Key_handle.to_hex handle;
  }

let encode_capability capability =
  let encryption_key, address_key, signing_key =
    Bootstrap.secret_material capability
  in
  String.concat ":"
    [
      capability_prefix ^ hex_of_bytes encryption_key;
      hex_of_bytes address_key;
      hex_of_bytes signing_key;
    ]

let decode_capability value =
  if not (String.starts_with ~prefix:capability_prefix value) then
    Error Invalid_keychain_material
  else
    match
      String.sub value
        (String.length capability_prefix)
        (String.length value - String.length capability_prefix)
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
            |> Result.map_error (fun _ -> Invalid_keychain_material)
        | Error (), _, _ | _, Error (), _ | _, _, Error () ->
            Error Invalid_keychain_material)
    | _ -> Error Invalid_keychain_material

let read_capability ~service ~key_handle =
  match service.backend.lookup (item_of_key_handle key_handle) with
  | Found value -> decode_capability value
  | Missing -> Error Keychain_item_missing
  | Locked -> Error Keychain_locked
  | Unavailable -> Error Keychain_unavailable
  | Non_exportable_key -> Error Keychain_non_exportable_key
  | Unsupported_key_item -> Error Keychain_unsupported_key_item

let check_existing ~capability value =
  let* existing = decode_capability value in
  if String.equal (encode_capability existing) (encode_capability capability)
  then Ok Already_initialized
  else Error Keychain_handle_in_use

let store_capability ~service ~key_handle ~capability =
  let item = item_of_key_handle key_handle in
  match service.backend.lookup item with
  | Found value -> check_existing ~capability value
  | Missing -> (
      match service.backend.store item (encode_capability capability) with
      | Stored -> Ok Initialized
      | Already_present -> (
          match service.backend.lookup item with
          | Found value -> check_existing ~capability value
          | Missing -> Error Keychain_item_missing
          | Locked -> Error Keychain_locked
          | Unavailable -> Error Keychain_unavailable
          | Non_exportable_key -> Error Keychain_non_exportable_key
          | Unsupported_key_item -> Error Keychain_unsupported_key_item)
      | Store_locked -> Error Keychain_locked
      | Store_unavailable -> Error Keychain_unavailable)
  | Locked -> Error Keychain_locked
  | Unavailable -> Error Keychain_unavailable
  | Non_exportable_key -> Error Keychain_non_exportable_key
  | Unsupported_key_item -> Error Keychain_unsupported_key_item

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

let remove_enrollment ~service ~root =
  let* bootstrap =
    Bootstrap_store.read_bootstrap ~root
    |> Result.map_error (fun error -> Bootstrap_store_error error)
  in
  match
    service.backend.remove (item_of_key_handle (Bootstrap.key_handle bootstrap))
  with
  | Removed -> Ok ()
  | Remove_missing -> Error Keychain_item_missing
  | Remove_locked -> Error Keychain_locked
  | Remove_unavailable -> Error Keychain_unavailable
