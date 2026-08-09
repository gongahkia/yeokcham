module Daemon = Yeokcham_local_daemon

let fail error =
  prerr_endline (Daemon.error_to_string error);
  exit 2

let usage () =
  prerr_endline
    "usage: yeokchamd --root PATH [--runtime-dir PATH] [--recover-stale]";
  exit 2

let () =
  match Array.to_list Sys.argv with
  | _ :: arguments -> (
      let rec parse root runtime_dir recover_stale = function
        | [] -> (
            match root with
            | None -> usage ()
            | Some root -> (root, runtime_dir, recover_stale))
        | "--root" :: path :: rest when Option.is_none root ->
            parse (Some path) runtime_dir recover_stale rest
        | "--runtime-dir" :: path :: rest when Option.is_none runtime_dir ->
            parse root (Some path) recover_stale rest
        | "--recover-stale" :: rest when not recover_stale ->
            parse root runtime_dir true rest
        | _ -> usage ()
      in
      let root, runtime_dir, recover_stale = parse None None false arguments in
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
          match Daemon.start ~root ~runtime_dir with
          | Error error -> fail error
          | Ok daemon ->
              Fun.protect
                ~finally:(fun () -> Daemon.close daemon)
                (fun () ->
                  match Daemon.serve daemon with
                  | Ok () -> ()
                  | Error error -> fail error)))
  | [] -> usage ()
