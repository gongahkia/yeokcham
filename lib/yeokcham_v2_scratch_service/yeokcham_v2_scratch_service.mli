(** Application boundary from one exact V2 scan to durable scratch publication.

    A local daemon calls this only for a due scheduler emission. The service
    does not run a watcher, own scheduler time, generate nonces, or select a
    divergent causal head. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Scanner = Yeokcham_v2_scanner
module Scratch_store = Yeokcham_v2_scratch_store

type error =
  | Scanner_error of Scanner.error
  | Scratch_store_error of Scratch_store.error

val error_to_string : error -> string

val scan_and_publish :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  snapshot_nonce:Envelope.nonce ->
  ledger_nonce:Envelope.nonce ->
  (Scratch_store.publication, error) result
(** Scans [root] exactly, opens the bootstrap-bound scratch repository, and
    delegates to the snapshot-first causal publication transition. *)
