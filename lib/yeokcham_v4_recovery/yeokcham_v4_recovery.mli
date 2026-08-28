(** Offline V4 recovery packages. A 24-word BIP-39 mnemonic decrypts one
    active recovery signing key and the complete public authority closure.
    The mnemonic is high-entropy recovery material, not a password. *)

module Trust = Yeokcham_v4_trust

type secret
type package
type recovered

type ceremony = {
  mnemonic : string;
  package : package;
}

type error =
  | Invalid_secret of string
  | Invalid_mnemonic of Yeokcham_v4_mnemonic.error
  | Entropy_failure
  | Invalid_package of string
  | Unsupported_version of int64
  | Unsupported_algorithm of string
  | Noncanonical_package
  | Decryption_failed
  | Trust_error of Trust.error

val error_to_string : error -> string
val generate_secret : unit -> (secret, error) result
val secret_of_mnemonic : string -> (secret, error) result
val mnemonic : secret -> string

val verification_phrase : Trust.certificate -> string
(** A deterministic 12-word public phrase derived from the repository root
    certificate. Peers compare it during enrollment; it grants no authority. *)

val make :
  secret:secret ->
  nonce:string ->
  authority:Trust.authority ->
  recovery_capability:Trust.signing_capability ->
  (package, error) result

val create :
  authority:Trust.authority ->
  recovery_capability:Trust.signing_capability ->
  (ceremony, error) result
val refresh :
  secret:secret ->
  authority:Trust.authority ->
  recovery_capability:Trust.signing_capability ->
  (package, error) result
(** Re-encrypts the current authority closure with a fresh nonce while keeping
    the supplied 24-word recovery secret and active recovery device.  This is
    for making an additional offline copy; it does not change authority. *)

val encode : package -> string
val decode : string -> (package, error) result
val recovery_device : package -> Trust.device

val recover : mnemonic:string -> package:package -> (recovered, error) result
val recovered_authority : recovered -> Trust.authority
val recovered_capability : recovered -> Trust.signing_capability
