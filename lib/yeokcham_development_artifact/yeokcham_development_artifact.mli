(** Versioned external development-artifact records. These values are never V4
    repository state. *)

type artifact_kind = Client_archive | Fedora_rpm | Relay_oci

type artifact = {
  kind : artifact_kind;
  filename : string;
  sha256 : string;
  size : int64;
}

type signing_identity = {
  workflow_identity : string;
  oidc_issuer : string;
  certificate_sha256 : string;
  bundle_filename : string;
}

type smoke_receipt
type record

val schema_version : int

val make :
  source_commit:string ->
  source_timestamp:int64 ->
  architecture:string ->
  ocaml_version:string ->
  dune_version:string ->
  opam_lock_sha256:string ->
  builder_image:string ->
  fedora_image:string ->
  sbom_sha256:string ->
  signing:signing_identity ->
  artifacts:artifact list ->
  (record, string) result

val encode : record -> string
val decode : string -> (record, string) result

val make_smoke_receipt :
  source_commit:string ->
  artifact_filename:string ->
  archive_installed:bool ->
  rpm_lifecycle_checked:bool ->
  relay_journey_checked:bool ->
  ordinary_source_unchanged:bool ->
  (smoke_receipt, string) result

val smoke_receipt_source_commit : smoke_receipt -> string
val smoke_receipt_artifact_filename : smoke_receipt -> string
val smoke_receipt_is_complete : smoke_receipt -> bool
