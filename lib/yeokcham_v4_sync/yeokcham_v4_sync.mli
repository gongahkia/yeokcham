(** Shared V4 HTTPS synchronization orchestration.

    This service owns no model or authority transition. It uses the existing
    staged receipt boundary and transport publication adapters, and reports
    post-receive upload failure as pending work. *)

type upload = Uploaded of int | Pending of string

type report = {
  discovered_publications : int;
  received_revisions : int;
  deferred_publications : int;
  created_decisions : int;
  upload : upload;
}

type error

val error_to_string : error -> string

val run :
  root:string ->
  remote:string ->
  load_signing_capability:
    (Yeokcham_v4_model.Device_id.t ->
    (Yeokcham_v4_trust.signing_capability, string) result) ->
  (report, error) result
(** Runs one explicit receive-first synchronization. It never scans or
    materialises the working tree. *)
