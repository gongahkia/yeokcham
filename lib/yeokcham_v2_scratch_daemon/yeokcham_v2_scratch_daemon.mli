(** Runtime-only orchestration from advisory scan requests to exact V2 scratch
    publication. The runner owns no watcher source, daemon socket, key store, or
    persistent scheduler state. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Scheduler = Yeokcham_v2_scratch_scheduler
module Scratch_store = Yeokcham_v2_scratch_store
module Watcher = Yeokcham_watcher

type nonce_source = unit -> (Envelope.nonce, string) result
type t

type publication =
  | No_checkpoint
  | Published_checkpoint of Scratch_store.checkpoint

type outcome = {
  request : Watcher.scan_request;
  due_at : Scheduler.timestamp;
  publication : publication;
}

type error =
  | Scheduler_error of Scheduler.error
  | Nonce_source_error of string
  | Nonce_reuse
  | Scratch_service_error of Yeokcham_v2_scratch_service.error

val error_to_string : error -> string
val cryptographic_nonce : nonce_source

val create :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  config:Scheduler.config ->
  nonce_source:nonce_source ->
  t

val next_due_at : t -> Scheduler.timestamp option

val observe :
  t ->
  at:Scheduler.timestamp ->
  Watcher.scan_request ->
  (outcome option, error) result
(** Coalesces one normalized request. If the old request is already due, it is
    scanned and published before the new request becomes pending. *)

val advance : t -> at:Scheduler.timestamp -> (outcome option, error) result
(** Processes one due request. No watcher input, scheduler state, or outcome is
    persisted; a restarted caller must provide a fresh whole-root request. *)
