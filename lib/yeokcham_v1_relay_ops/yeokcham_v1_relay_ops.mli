(** Operator-only readiness and aggregate observability for the development
    relay. These values are process-local: they are neither V1 records nor
    persistent relay data. *)

type path_state = Available | Missing | Not_directory | Not_writable | Invalid

type readiness_failure =
  | Storage of path_state
  | Credential_registry of path_state

type readiness = Ready | Not_ready of readiness_failure

val assess_readiness :
  storage:path_state -> credential_registry:path_state -> readiness

type event =
  | Request_succeeded
  | Request_refused
  | Request_failed
  | Object_stored
  | Session_started
  | Session_completed
  | Quota_refused
  | Sessions_expired of { count : int; reclaimed_bytes : int }

type counter_error =
  | Invalid_expiration of { count : int; reclaimed_bytes : int }

type counters

val zero : counters
val record : counters -> event -> (counters, counter_error) result
val requests_total : counters -> int64
val refusals_total : counters -> int64
val failures_total : counters -> int64
val objects_stored_total : counters -> int64
val sessions_started_total : counters -> int64
val sessions_completed_total : counters -> int64
val quota_refusals_total : counters -> int64
val expired_sessions_total : counters -> int64
val reclaimed_session_bytes_total : counters -> int64

val prometheus : counters -> string
(** Produces a bounded, canonical Prometheus text exposition. It has no labels
    and so cannot disclose a repository, object, credential, payload, or path.
*)
