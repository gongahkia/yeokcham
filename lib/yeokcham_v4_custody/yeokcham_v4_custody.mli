(** Local-only V4 device custody profiles and external signer adapters.

    A profile selects a device's local signer. It is never V4 authority state,
    package content, relay data, or a source of device identity. *)

module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

type provider =
  | Ssh_agent of { public_key : string }
  | Pkcs11 of {
      module_path : string;
      token_label : string;
      key_id : string;
      public_key : string;
    }

type profile = { device : Model.Device_id.t; provider : provider }

type error =
  | Profile_missing
  | Profile_exists
  | Invalid_profile of string
  | Io_error of { path : string; operation : string; message : string }
  | Ssh_agent_unavailable of string
  | Ssh_agent_key_missing
  | Ssh_agent_protocol of string
  | Pkcs11_unavailable of string
  | Pkcs11_key_missing
  | Pkcs11_locked
  | Pkcs11_unsupported of string
  | Public_key_mismatch
  | Trust_error of Trust.error

val error_to_string : error -> string
val profile_path : root:string -> Model.Device_id.t -> string
val configured : root:string -> Model.Device_id.t -> bool
val save : root:string -> profile -> (unit, error) result
val find : root:string -> Model.Device_id.t -> (profile, error) result
val inspect : root:string -> Model.Device_id.t -> (profile, error) result

val ssh_public_key_file : string -> (string, error) result
(** Reads one OpenSSH [ssh-ed25519] public key and returns its 32 raw public
    bytes. *)

val attach_ssh_agent :
  root:string ->
  public_key:string ->
  (Model.Device_id.t, error) result
(** Confirms the exact key is currently available through [SSH_AUTH_SOCK] and
    saves its local-only profile. *)

val attach_pkcs11 :
  root:string ->
  module_path:string ->
  token_label:string ->
  key_id:string ->
  public_key:string ->
  (Model.Device_id.t, error) result

val create_pkcs11 :
  root:string ->
  module_path:string ->
  token_label:string ->
  key_label:string ->
  key_id:string ->
  (Model.Device_id.t, error) result
(** Generates an Ed25519 key pair on the selected token with the private key
    marked non-extractable, then writes the local-only profile. *)

val load_with_pin :
  root:string -> pin:string -> Model.Device_id.t ->
  (Trust.signing_capability, error) result
(** Test and controlled integration boundary. Production commands use a
    controlling-terminal PIN prompt and never persist this argument. *)

val load :
  root:string -> Model.Device_id.t -> (Trust.signing_capability, error) result

val ssh_agent_available : public_key:string -> (unit, error) result
