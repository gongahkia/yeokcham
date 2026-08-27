module Linux_watcher = Yeokcham_linux_watcher
module Service = Yeokcham_v4_local_service
module Watcher = Yeokcham_watcher

let ignorable request =
  match request.Watcher.target with
  | Watcher.Whole_root -> false
  | Watcher.Paths paths ->
      List.for_all
        (function ".git" :: _ | ".yeokcham" :: _ -> true | _ -> false)
        paths

let lost request =
  match request.Watcher.reason with
  | Watcher.Overflow | Watcher.Watcher_lost | Watcher.Path_budget_exceeded ->
      true
  | Watcher.Initial_scan | Watcher.Path_change | Watcher.Rename -> false

let capture root =
  match Service.save ~root with
  | Ok (Service.Unchanged _) -> ()
  | Ok (Service.Saved status) ->
      Printf.printf "save recorded\nsaved %s\n"
        (Yeokcham_v4_model.Snapshot_id.to_string status.Service.checkpoint)
  | Error error -> prerr_endline (Service.error_to_string error)

let rec start_watcher root =
  match Linux_watcher.start ~root with
  | Ok watcher -> watcher
  | Error error ->
      prerr_endline (Linux_watcher.error_to_string error);
      Unix.sleep 1;
      start_watcher root

let rec loop root watcher window =
  let now = Unix.gettimeofday () in
  let timeout = Service.Capture_window.timeout window ~now in
  match Linux_watcher.poll watcher ~timeout with
  | Error Linux_watcher.Needs_restart | Error Linux_watcher.Closed ->
      Linux_watcher.close watcher;
      capture root;
      loop root (start_watcher root) Service.Capture_window.clear
  | Error error ->
      prerr_endline (Linux_watcher.error_to_string error);
      Unix.sleep 1;
      loop root watcher window
  | Ok None ->
      let now = Unix.gettimeofday () in
      if Service.Capture_window.due window ~now then (
        capture root;
        loop root watcher Service.Capture_window.clear)
      else loop root watcher window
  | Ok (Some request) when ignorable request -> loop root watcher window
  | Ok (Some request) when lost request ->
      Linux_watcher.close watcher;
      capture root;
      loop root (start_watcher root) Service.Capture_window.clear
  | Ok (Some _) ->
      let now = Unix.gettimeofday () in
      let window = Service.Capture_window.observe window ~now in
      if Service.Capture_window.due window ~now then (
        capture root;
        loop root watcher Service.Capture_window.clear)
      else loop root watcher window

let run ~root =
  let watcher = start_watcher root in
  Fun.protect
    ~finally:(fun () -> Linux_watcher.close watcher)
    (fun () -> loop root watcher Service.Capture_window.empty)
