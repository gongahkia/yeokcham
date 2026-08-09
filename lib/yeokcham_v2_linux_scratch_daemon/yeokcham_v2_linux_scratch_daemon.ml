module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Clock = Yeokcham_v2_monotonic_clock
module Linux_watcher = Yeokcham_linux_watcher
module Runtime = Yeokcham_local_daemon
module Runner = Yeokcham_v2_scratch_daemon
module Scheduler = Yeokcham_v2_scratch_scheduler
module Watcher = Yeokcham_watcher

type t = {
  runtime : Runtime.daemon;
  watcher : Linux_watcher.t;
  runner : Runner.t;
  mutable closed : bool;
}

type error =
  | Runtime_error of Runtime.error
  | Watcher_error of Linux_watcher.error
  | Runner_error of Runner.error
  | Clock_error of Clock.error

let ( let* ) = Result.bind
let idle_timeout = 0.05

let error_to_string = function
  | Runtime_error error -> Runtime.error_to_string error
  | Watcher_error error -> Linux_watcher.error_to_string error
  | Runner_error error -> Runner.error_to_string error
  | Clock_error error -> Clock.error_to_string error

let start ~root ~runtime_dir ~bootstrap_repository ~scheduler_config
    ?(nonce_source = Runner.cryptographic_nonce) () =
  let* runtime =
    Runtime.start ~root ~runtime_dir
    |> Result.map_error (fun error -> Runtime_error error)
  in
  match Linux_watcher.start ~root with
  | Error error ->
      Runtime.close runtime;
      Error (Watcher_error error)
  | Ok watcher -> (
      let runner =
        Runner.create ~root ~bootstrap_repository ~config:scheduler_config
          ~nonce_source
      in
      let initial_request =
        { Watcher.reason = Watcher.Initial_scan; target = Watcher.Whole_root }
      in
      match Clock.now () with
      | Error error ->
          Linux_watcher.close watcher;
          Runtime.close runtime;
          Error (Clock_error error)
      | Ok at -> (
          match Runner.observe runner ~at initial_request with
          | Error error ->
              Linux_watcher.close watcher;
              Runtime.close runtime;
              Error (Runner_error error)
          | Ok _ -> Ok { runtime; watcher; runner; closed = false }))

let tick daemon ~at =
  let* due =
    Runner.advance daemon.runner ~at
    |> Result.map_error (fun error -> Runner_error error)
  in
  let* request =
    Linux_watcher.poll daemon.watcher ~timeout:0.0
    |> Result.map_error (fun error -> Watcher_error error)
  in
  let* observed =
    match request with
    | None -> Ok None
    | Some request ->
        Runner.observe daemon.runner ~at request
        |> Result.map_error (fun error -> Runner_error error)
  in
  Ok (List.filter_map Fun.id [ due; observed ])

let next_due_at daemon = Runner.next_due_at daemon.runner

let close daemon =
  if not daemon.closed then (
    daemon.closed <- true;
    Linux_watcher.close daemon.watcher;
    Runtime.close daemon.runtime)

let serve daemon =
  Fun.protect
    ~finally:(fun () -> close daemon)
    (fun () ->
      Runtime.serve_with daemon.runtime ~idle_timeout ~on_idle:(fun () ->
          let* at = Clock.now () |> Result.map_error Clock.error_to_string in
          tick daemon ~at
          |> Result.map (fun _ -> ())
          |> Result.map_error error_to_string)
      |> Result.map_error (fun error -> Runtime_error error))
