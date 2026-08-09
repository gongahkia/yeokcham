module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Scanner = Yeokcham_v2_scanner
module Scratch_store = Yeokcham_v2_scratch_store

type error =
  | Scanner_error of Scanner.error
  | Scratch_store_error of Scratch_store.error

let ( let* ) = Result.bind

let error_to_string = function
  | Scanner_error error -> Scanner.error_to_string error
  | Scratch_store_error error -> Scratch_store.error_to_string error

let scan_and_publish ~root ~bootstrap_repository ~snapshot_nonce ~ledger_nonce =
  let* snapshot =
    Scanner.scan ~root |> Result.map_error (fun error -> Scanner_error error)
  in
  let* scratch =
    Scratch_store.open_repository ~root ~bootstrap_repository
    |> Result.map_error (fun error -> Scratch_store_error error)
  in
  Scratch_store.publish scratch ~snapshot ~snapshot_nonce ~ledger_nonce
  |> Result.map_error (fun error -> Scratch_store_error error)
