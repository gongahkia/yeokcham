module Daemon = Yeokcham_local_daemon
module Linux_scratch_daemon = Yeokcham_v2_linux_scratch_daemon
module Scheduler = Yeokcham_v2_scratch_scheduler
module Secret_service = Yeokcham_v2_secret_service

let fail error =
  prerr_endline (Daemon.error_to_string error);
  exit 2

let fail_scratch error =
  prerr_endline (Linux_scratch_daemon.error_to_string error);
  exit 2

let fail_secret error =
  prerr_endline (Secret_service.error_to_string error);
  exit 2

let fail_scheduler error =
  prerr_endline (Scheduler.error_to_string error);
  exit 2

let usage () =
  prerr_endline
    "usage: yeokchamd --root PATH --quiet-period-ms INTEGER --max-latency-ms \
     INTEGER [--runtime-dir PATH] [--recover-stale]";
  exit 2

let positive_int64 value =
  match Int64.of_string_opt value with
  | Some value when Int64.compare value 0L > 0 -> Some value
  | Some _ | None -> None

let () =
  match Array.to_list Sys.argv with
  | _ :: arguments -> (
      let rec parse root runtime_dir recover_stale quiet_period max_latency =
        function
        | [] -> (
            match (root, quiet_period, max_latency) with
            | Some root, Some quiet_period, Some max_latency ->
                (root, runtime_dir, recover_stale, quiet_period, max_latency)
            | None, _, _ | _, None, _ | _, _, None -> usage ())
        | "--root" :: path :: rest when Option.is_none root ->
            parse (Some path) runtime_dir recover_stale quiet_period max_latency
              rest
        | "--runtime-dir" :: path :: rest when Option.is_none runtime_dir ->
            parse root (Some path) recover_stale quiet_period max_latency rest
        | "--recover-stale" :: rest when not recover_stale ->
            parse root runtime_dir true quiet_period max_latency rest
        | "--quiet-period-ms" :: value :: rest when Option.is_none quiet_period
          -> (
            match positive_int64 value with
            | Some value ->
                parse root runtime_dir recover_stale (Some value) max_latency
                  rest
            | None -> usage ())
        | "--max-latency-ms" :: value :: rest when Option.is_none max_latency
          -> (
            match positive_int64 value with
            | Some value ->
                parse root runtime_dir recover_stale quiet_period (Some value)
                  rest
            | None -> usage ())
        | _ -> usage ()
      in
      let root, runtime_dir, recover_stale, quiet_period, max_latency =
        parse None None false None None arguments
      in
      let runtime_dir =
        match runtime_dir with
        | Some path -> path
        | None -> (
            match Daemon.default_runtime_location () with
            | Ok (Daemon.Xdg_runtime path) -> path
            | Ok (Daemon.Fallback_runtime path) ->
                prerr_endline
                  "warning: XDG_RUNTIME_DIR is unavailable; using a temporary \
                   runtime directory";
                path
            | Error error -> fail error)
      in
      let recovered =
        if recover_stale then Daemon.recover_stale ~root ~runtime_dir else Ok ()
      in
      match recovered with
      | Error error -> fail error
      | Ok () -> (
          let scheduler_config =
            match Scheduler.make_config ~quiet_period ~max_latency with
            | Ok config -> config
            | Error error -> fail_scheduler error
          in
          let bootstrap_repository =
            match
              Secret_service.open_repository
                ~service:(Secret_service.default_service ())
                ~root
            with
            | Ok repository -> repository
            | Error error -> fail_secret error
          in
          match
            Linux_scratch_daemon.start ~root ~runtime_dir ~bootstrap_repository
              ~scheduler_config ()
          with
          | Error error -> fail_scratch error
          | Ok daemon ->
              Fun.protect
                ~finally:(fun () -> Linux_scratch_daemon.close daemon)
                (fun () ->
                  match Linux_scratch_daemon.serve daemon with
                  | Ok () -> ()
                  | Error error -> fail_scratch error)))
  | [] -> usage ()
