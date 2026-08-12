(** Pure custody boundary for a macOS Keychain local V2 capability.

    The injected backend is intentionally limited to one opaque data value per
    public signed bootstrap key handle. It neither receives repository IDs nor
    changes repository state. A macOS Security.framework adapter supplies the
    production backend; tests use an in-memory backend. *)

module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Model = Yeokcham_v2_model

type item = { service_name : string; account : string; legacy_key_tag : string }
(** Public Keychain lookup values derived only from a signed key handle. *)

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

type service
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

val error_to_string : error -> string
val service : backend:backend -> service
val service_name : string
val account_of_key_handle : Bootstrap.Key_handle.t -> string
val item_of_key_handle : Bootstrap.Key_handle.t -> item

val key_handle_of_bytes :
  string -> (Bootstrap.Key_handle.t, Model.identity_error) result

val generate_capability : unit -> (Bootstrap.capability, error) result
val generate_key_handle : unit -> (Bootstrap.Key_handle.t, error) result

val enroll :
  service:service ->
  root:string ->
  repository_id:Model.Repository_id.t ->
  device_id:Model.Device_id.t ->
  key_handle:Bootstrap.Key_handle.t ->
  capability:Bootstrap.capability ->
  (enrollment, error) result
(** Writes the create-only Keychain item before the create-only public
    bootstrap. A failed bootstrap publication can leave an unreachable local
    item; it is not removed automatically. *)

val create_and_enroll :
  service:service ->
  root:string ->
  repository_id:Model.Repository_id.t ->
  device_id:Model.Device_id.t ->
  (enrollment, error) result

val open_repository :
  service:service -> root:string -> (Bootstrap_store.repository, error) result

val remove_enrollment : service:service -> root:string -> (unit, error) result
(** Removes only the local Keychain item named by the existing bootstrap. It
    does not mutate the bootstrap or create a signed device removal. *)
