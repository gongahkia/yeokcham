(** Pure V2 scratch scan scheduling. The scheduler emits advisory scan work; it
    neither reads a working tree nor creates a checkpoint. *)

module Watcher = Yeokcham_watcher

type timestamp = int64
type config
type t
type emission
type scan_result = Unchanged | Changed
type publication = No_checkpoint | Publish_checkpoint

type error =
  | Nonpositive_quiet_period of int64
  | Nonpositive_max_latency of int64
  | Max_latency_shorter_than_quiet_period of {
      quiet_period : int64;
      max_latency : int64;
    }
  | Non_monotonic_timestamp of { previous : timestamp; current : timestamp }

val error_to_string : error -> string

val make_config :
  quiet_period:int64 -> max_latency:int64 -> (config, error) result
(** Durations are positive monotonic-clock milliseconds. [max_latency] bounds a
    continuous burst and must not be shorter than [quiet_period]. *)

val create : config -> t
val next_due_at : t -> timestamp option

val observe :
  t ->
  at:timestamp ->
  Watcher.scan_request ->
  (t * emission option, error) result
(** Adds or coalesces one normalized watcher request. When [at] is already due,
    the old request is emitted before the new request becomes pending. *)

val advance : t -> at:timestamp -> (t * emission option, error) result
(** Emits a pending request at most once after its due time. *)

val emission_request : emission -> Watcher.scan_request
val emission_due_at : emission -> timestamp

val publication_for_scan : scan_result -> publication
(** [Unchanged] never asks a caller to publish a checkpoint. *)
