(** Linux runtime edge for automatic V2 scratch checkpoints. It composes the
    advisory inotify source, the client-agnostic scratch runner, and the local
    socket lifecycle. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Runner = Yeokcham_v2_scratch_daemon
module Scheduler = Yeokcham_v2_scratch_scheduler

type t

type error =
  | Runtime_error of Yeokcham_local_daemon.error
  | Watcher_error of Yeokcham_linux_watcher.error
  | Runner_error of Runner.error
  | Clock_error of Yeokcham_v2_monotonic_clock.error

val error_to_string : error -> string

val start :
  root:string ->
  runtime_dir:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  scheduler_config:Scheduler.config ->
  ?nonce_source:Runner.nonce_source ->
  unit ->
  (t, error) result
(** Starts the runtime socket and a Linux watcher, then schedules an initial
    whole-root scan. The caller injects an already-authenticated bootstrap
    repository; this adapter never reads a key store or treats the socket
    capability as a repository credential. *)

val tick : t -> at:Scheduler.timestamp -> (Runner.outcome list, error) result
(** Advances due work, then consumes at most one nonblocking inotify batch.
    Watcher loss is an explicit error; callers must start a fresh daemon and let
    its initial whole-root scan replace the lost coverage. *)

val next_due_at : t -> Scheduler.timestamp option
val serve : t -> (unit, error) result
val close : t -> unit
