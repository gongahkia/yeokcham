module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Scheduler = Yeokcham_v2_scratch_scheduler
module Scratch_service = Yeokcham_v2_scratch_service
module Scratch_store = Yeokcham_v2_scratch_store
module Watcher = Yeokcham_watcher

type nonce_source = unit -> (Envelope.nonce, string) result

type t = {
  root : string;
  bootstrap_repository : Bootstrap_store.repository;
  nonce_source : nonce_source;
  mutable scheduler : Scheduler.t;
}

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
  | Scratch_service_error of Scratch_service.error

let ( let* ) = Result.bind

let error_to_string = function
  | Scheduler_error error -> Scheduler.error_to_string error
  | Nonce_source_error detail -> "scratch daemon nonce source failed: " ^ detail
  | Nonce_reuse -> "scratch daemon nonce source reused one publication nonce"
  | Scratch_service_error error -> Scratch_service.error_to_string error

let cryptographic_nonce () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Mirage_crypto_rng.generate 12
    |> Envelope.nonce_of_bytes
    |> Result.map_error Envelope.error_to_string
  with _ -> Error "OS CSPRNG unavailable"

let create ~root ~bootstrap_repository ~config ~nonce_source =
  {
    root;
    bootstrap_repository;
    nonce_source;
    scheduler = Scheduler.create config;
  }

let next_due_at runner = Scheduler.next_due_at runner.scheduler

let publication = function
  | Scratch_store.Unchanged _ -> No_checkpoint
  | Scratch_store.Published checkpoint -> Published_checkpoint checkpoint

let run_emission runner emission =
  let* snapshot_nonce =
    runner.nonce_source ()
    |> Result.map_error (fun error -> Nonce_source_error error)
  in
  let* ledger_nonce =
    runner.nonce_source ()
    |> Result.map_error (fun error -> Nonce_source_error error)
  in
  if
    String.equal
      (Envelope.nonce_to_bytes snapshot_nonce)
      (Envelope.nonce_to_bytes ledger_nonce)
  then Error Nonce_reuse
  else
    let* published =
      Scratch_service.scan_and_publish ~root:runner.root
        ~bootstrap_repository:runner.bootstrap_repository ~snapshot_nonce
        ~ledger_nonce
      |> Result.map_error (fun error -> Scratch_service_error error)
    in
    Ok
      {
        request = Scheduler.emission_request emission;
        due_at = Scheduler.emission_due_at emission;
        publication = publication published;
      }

let observe runner ~at request =
  let* scheduler, emission =
    Scheduler.observe runner.scheduler ~at request
    |> Result.map_error (fun error -> Scheduler_error error)
  in
  runner.scheduler <- scheduler;
  match emission with
  | None -> Ok None
  | Some emission -> run_emission runner emission |> Result.map Option.some

let advance runner ~at =
  let* scheduler, emission =
    Scheduler.advance runner.scheduler ~at
    |> Result.map_error (fun error -> Scheduler_error error)
  in
  runner.scheduler <- scheduler;
  match emission with
  | None -> Ok None
  | Some emission -> run_emission runner emission |> Result.map Option.some
