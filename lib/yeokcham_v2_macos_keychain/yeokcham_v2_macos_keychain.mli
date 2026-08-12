(** macOS Security.framework implementation of the V2 local Keychain custody
    boundary. This module is intentionally available only on macOS. *)

include module type of Yeokcham_v2_keychain_custody

val default_service : unit -> service
(** Uses Data Protection Keychain generic-password items with synchronisation
    disabled and `WhenUnlockedThisDeviceOnly` accessibility. *)
