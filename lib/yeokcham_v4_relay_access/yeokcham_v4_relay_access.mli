(** Relay-local V4 access policy.

    This registry is operator policy, not project state, authority, or package
    data. It stores only SHA-256 verifiers for high-entropy access secrets. *)

type scope = Read | Write
type status = Active | Revoked

type credential = private {
  credential_id : string;
  repository : string;
  scopes : scope list;
  issued_at : int64;
  expires_at : int64;
  status : status;
  revoked_at : int64 option;
}

type registry

type grant = {
  grant_credential_id : string;
  grant_secret : string;
  grant_expires_at : int64;
}

type error =
  | Invalid_repository
  | Invalid_credential_id
  | Invalid_scope
  | Invalid_lifetime
  | Unknown_credential
  | Credential_inactive
  | Entropy_failure
  | Invalid_registry of string
  | Noncanonical_registry
  | Registry_too_large
  | Io_error of { path : string; operation : string; message : string }

type authorization_error =
  | Invalid_secret
  | Unknown_secret
  | Expired_secret
  | Revoked_secret
  | Wrong_repository
  | Insufficient_scope

val schema_version : int64
val default_lifetime_seconds : int64
val max_lifetime_seconds : int64
val max_credentials : int
val error_to_string : error -> string
val authorization_error_to_string : authorization_error -> string
val scope_to_string : scope -> string
val scopes_to_string : scope list -> string
val credential_id : credential -> string
val credential_repository : credential -> string
val credential_scopes : credential -> scope list
val credential_issued_at : credential -> int64
val credential_expires_at : credential -> int64
val credential_status : credential -> status
val credential_revoked_at : credential -> int64 option
val empty : registry
val credentials : registry -> credential list
val encode : registry -> (string, error) result
val decode : string -> (registry, error) result

val issue :
  now:int64 ->
  repository:string ->
  scopes:scope list ->
  expires_in:int64 ->
  registry ->
  (registry * grant, error) result

val rotate :
  now:int64 ->
  credential_id:string ->
  expires_in:int64 ->
  registry ->
  (registry * grant, error) result

val revoke :
  now:int64 -> credential_id:string -> registry -> (registry, error) result

val authorize :
  now:int64 ->
  secret:string ->
  repository:string ->
  scope:scope ->
  registry ->
  (unit, authorization_error) result

val authorize_credential :
  now:int64 ->
  secret:string ->
  repository:string ->
  scope:scope ->
  registry ->
  (credential, authorization_error) result
(** Returns only the safe credential record after authorization. Callers must
    never persist or log [secret]. *)

val load : root:string -> (registry, error) result

val update :
  root:string ->
  (registry -> (registry * 'a, error) result) ->
  ('a, error) result
