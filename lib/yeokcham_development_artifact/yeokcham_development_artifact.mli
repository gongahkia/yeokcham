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
