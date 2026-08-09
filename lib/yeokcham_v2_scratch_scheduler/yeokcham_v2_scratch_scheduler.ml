module Watcher = Yeokcham_watcher

type timestamp = int64
type config = { quiet_period : int64; max_latency : int64 }

type pending = {
  first_observed_at : timestamp;
  pending_due_at : timestamp;
  pending_request : Watcher.scan_request;
}

type t = {
  config : config;
  last_at : timestamp option;
  pending : pending option;
}

type emission = { request : Watcher.scan_request; due_at : timestamp }
type scan_result = Unchanged | Changed
type publication = No_checkpoint | Publish_checkpoint

type error =
  | Nonpositive_quiet_period of int64
  | Nonpositive_max_latency of int64
  | Max_latency_shorter_than_quiet_period of {
      quiet_period : int64;
      max_latency : int64;
    }
  | Non_monotonic_timestamp of { previous : timestamp; current : timestamp }

let error_to_string = function
  | Nonpositive_quiet_period value ->
      Printf.sprintf "quiet period must be positive, got %Ld" value
  | Nonpositive_max_latency value ->
      Printf.sprintf "maximum latency must be positive, got %Ld" value
  | Max_latency_shorter_than_quiet_period { quiet_period; max_latency } ->
      Printf.sprintf
        "maximum latency %Ld must not be shorter than quiet period %Ld"
        max_latency quiet_period
  | Non_monotonic_timestamp { previous; current } ->
      Printf.sprintf
        "scheduler timestamps must be monotonic: received %Ld after %Ld" current
        previous

let make_config ~quiet_period ~max_latency =
  if Int64.compare quiet_period 0L <= 0 then
    Error (Nonpositive_quiet_period quiet_period)
  else if Int64.compare max_latency 0L <= 0 then
    Error (Nonpositive_max_latency max_latency)
  else if Int64.compare max_latency quiet_period < 0 then
    Error (Max_latency_shorter_than_quiet_period { quiet_period; max_latency })
  else Ok { quiet_period; max_latency }

let create config = { config; last_at = None; pending = None }

let next_due_at state =
  Option.map (fun pending -> pending.pending_due_at) state.pending

let ( let* ) = Result.bind

let saturating_add timestamp duration =
  if Int64.compare timestamp (Int64.sub Int64.max_int duration) > 0 then
    Int64.max_int
  else Int64.add timestamp duration

let request_paths request =
  match request.Watcher.target with
  | Watcher.Whole_root -> None
  | Watcher.Paths paths -> Some paths

let merge_requests first second =
  match (request_paths first, request_paths second) with
  | None, _ -> first
  | _, None -> second
  | Some first_paths, Some second_paths ->
      let paths = List.sort_uniq Stdlib.compare (first_paths @ second_paths) in
      if List.length paths > Watcher.max_paths_per_request then
        {
          Watcher.reason = Watcher.Path_budget_exceeded;
          target = Watcher.Whole_root;
        }
      else
        {
          Watcher.reason =
            (if
               first.Watcher.reason = Watcher.Rename
               || second.Watcher.reason = Watcher.Rename
             then Watcher.Rename
             else Watcher.Path_change);
          target = Watcher.Paths paths;
        }

let validate_timestamp state at =
  match state.last_at with
  | None -> Ok ()
  | Some previous when Int64.compare at previous >= 0 -> Ok ()
  | Some previous -> Error (Non_monotonic_timestamp { previous; current = at })

let advance state ~at =
  let* () = validate_timestamp state at in
  match state.pending with
  | None -> Ok ({ state with last_at = Some at }, None)
  | Some pending when Int64.compare at pending.pending_due_at < 0 ->
      Ok ({ state with last_at = Some at }, None)
  | Some pending ->
      Ok
        ( { state with last_at = Some at; pending = None },
          Some
            {
              request = pending.pending_request;
              due_at = pending.pending_due_at;
            } )

let observe state ~at request =
  let* state, ready = advance state ~at in
  let pending =
    match state.pending with
    | None ->
        let quiet_due = saturating_add at state.config.quiet_period in
        let maximum_due = saturating_add at state.config.max_latency in
        {
          first_observed_at = at;
          pending_due_at = Int64.min quiet_due maximum_due;
          pending_request = request;
        }
    | Some pending ->
        let quiet_due = saturating_add at state.config.quiet_period in
        let maximum_due =
          saturating_add pending.first_observed_at state.config.max_latency
        in
        {
          first_observed_at = pending.first_observed_at;
          pending_due_at = Int64.min quiet_due maximum_due;
          pending_request = merge_requests pending.pending_request request;
        }
  in
  Ok ({ state with pending = Some pending }, ready)

let emission_request emission = emission.request
let emission_due_at emission = emission.due_at

let publication_for_scan = function
  | Unchanged -> No_checkpoint
  | Changed -> Publish_checkpoint
