module type Source = sig
  module Watcher : module type of Yeokcham_watcher

  type t
  type error

  val start : root:string -> (t, error) result
  val poll : t -> timeout:float -> (Watcher.scan_request option, error) result
  val close : t -> unit
  val error_to_string : error -> string
  val retry_start : error -> bool
  val restart_error : error -> bool
  val closed_error : error -> bool
end

module Make (Source : Source) = struct
  module Service = Yeokcham_v1_local_service
  module Model = Yeokcham_v1_model
  module Output = V1_cli_output
  module Watcher = Source.Watcher

  let ignorable request =
    match request.Watcher.target with
    | Watcher.Whole_root -> false
    | Watcher.Paths paths ->
        List.for_all
          (function ".git" :: _ | ".yeokcham" :: _ -> true | _ -> false)
          paths

  let restart_after request =
    match request.Watcher.reason with
    | Watcher.Overflow | Watcher.Watcher_lost | Watcher.Path_budget_exceeded ->
        true
    | Watcher.Initial_scan | Watcher.Path_change | Watcher.Rename
    | Watcher.Rescan_required ->
        false

  let capture root =
    match Service.save ~root with
    | Ok (Service.Unchanged _) -> ()
    | Ok (Service.Saved status) ->
        Output.print_string
          (Printf.sprintf "save recorded\nsaved %s\n"
             (Model.Snapshot_id.to_string status.Service.checkpoint));
        flush stdout
    | Error error -> Output.print_error (Service.error_to_string error)

  let rec start root =
    match Source.start ~root with
    | Ok watcher -> Ok watcher
    | Error error when Source.retry_start error ->
        Output.print_error (Source.error_to_string error);
        Unix.sleep 1;
        start root
    | Error error -> Error error

  let rec wait_for_request root watcher window =
    let now = Unix.gettimeofday () in
    let timeout = Service.Capture_window.timeout window ~now in
    match Source.poll watcher ~timeout with
    | Error error when Source.restart_error error || Source.closed_error error
      ->
        `Restart
    | Error error ->
        Output.print_error (Source.error_to_string error);
        Unix.sleep 1;
        wait_for_request root watcher window
    | Ok None ->
        let now = Unix.gettimeofday () in
        if Service.Capture_window.due window ~now then (
          capture root;
          wait_for_request root watcher Service.Capture_window.clear)
        else wait_for_request root watcher window
    | Ok (Some request) when ignorable request ->
        wait_for_request root watcher window
    | Ok (Some request) when restart_after request -> `Restart
    | Ok (Some _) ->
        let now = Unix.gettimeofday () in
        let window = Service.Capture_window.observe window ~now in
        if Service.Capture_window.due window ~now then (
          capture root;
          wait_for_request root watcher Service.Capture_window.clear)
        else wait_for_request root watcher window

  let rec run_watcher root watcher =
    let action =
      Fun.protect
        ~finally:(fun () -> Source.close watcher)
        (fun () -> wait_for_request root watcher Service.Capture_window.empty)
    in
    match action with
    | `Restart ->
        capture root;
        restart root

  and restart root =
    match start root with
    | Ok watcher -> run_watcher root watcher
    | Error error -> Error error

  let run ~root =
    match start root with
    | Error error ->
        Output.print_error (Source.error_to_string error);
        exit 2
    | Ok watcher -> (
        let result = run_watcher root watcher in
        match result with
        | Ok () -> ()
        | Error error ->
            Output.print_error (Source.error_to_string error);
            exit 2)
end
