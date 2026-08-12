module Custody = Yeokcham_v2_keychain_custody
include Custody

external lookup_raw : string -> string -> string -> int * string option
  = "caml_yeokcham_v2_macos_keychain_lookup"

external store_raw : string -> string -> string -> int
  = "caml_yeokcham_v2_macos_keychain_store"

external remove_raw : string -> string -> int
  = "caml_yeokcham_v2_macos_keychain_remove"

let lookup item =
  match
    lookup_raw item.Custody.service_name item.Custody.account
      item.Custody.legacy_key_tag
  with
  | 0, Some value -> Found value
  | 0, None -> Unavailable
  | 1, None -> Missing
  | 2, None -> Locked
  | 3, None -> Unavailable
  | 4, None -> Non_exportable_key
  | 5, None -> Unsupported_key_item
  | _, _ -> Unavailable

let store item value =
  match store_raw item.Custody.service_name item.Custody.account value with
  | 0 -> Stored
  | 1 -> Already_present
  | 2 -> Store_locked
  | _ -> Store_unavailable

let remove item =
  match remove_raw item.Custody.service_name item.Custody.account with
  | 0 -> Removed
  | 1 -> Remove_missing
  | 2 -> Remove_locked
  | _ -> Remove_unavailable

let default_service () =
  service ~backend:{ Custody.lookup; Custody.store; Custody.remove }
