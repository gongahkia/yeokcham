type path_state = Available | Missing | Not_directory | Not_writable | Invalid

type readiness_failure =
  | Storage of path_state
  | Credential_registry of path_state

type readiness = Ready | Not_ready of readiness_failure

let assess_readiness ~storage ~credential_registry =
  match storage with
  | Available -> (
      match credential_registry with
      | Available -> Ready
      | Missing | Not_directory | Not_writable | Invalid ->
          Not_ready (Credential_registry credential_registry))
  | Missing | Not_directory | Not_writable | Invalid ->
      Not_ready (Storage storage)

type event =
  | Request_succeeded
  | Request_refused
  | Request_failed
  | Object_stored
  | Session_started
  | Session_completed
  | Quota_refused
  | Sessions_expired of { count : int; reclaimed_bytes : int }

type counter_error =
  | Invalid_expiration of { count : int; reclaimed_bytes : int }

type counters = {
  requests_total : int64;
  refusals_total : int64;
  failures_total : int64;
  objects_stored_total : int64;
  sessions_started_total : int64;
  sessions_completed_total : int64;
  quota_refusals_total : int64;
  expired_sessions_total : int64;
  reclaimed_session_bytes_total : int64;
}

let zero =
  {
    requests_total = 0L;
    refusals_total = 0L;
    failures_total = 0L;
    objects_stored_total = 0L;
    sessions_started_total = 0L;
    sessions_completed_total = 0L;
    quota_refusals_total = 0L;
    expired_sessions_total = 0L;
    reclaimed_session_bytes_total = 0L;
  }

let saturating_add left right =
  if Int64.compare right 0L <= 0 then left
  else if Int64.compare left (Int64.sub Int64.max_int right) > 0 then
    Int64.max_int
  else Int64.add left right

let increment counters =
  { counters with requests_total = saturating_add counters.requests_total 1L }

let record counters = function
  | Request_succeeded -> Ok (increment counters)
  | Request_refused ->
      Ok
        {
          (increment counters) with
          refusals_total = saturating_add counters.refusals_total 1L;
        }
  | Request_failed ->
      Ok
        {
          (increment counters) with
          failures_total = saturating_add counters.failures_total 1L;
        }
  | Object_stored ->
      Ok
        {
          counters with
          objects_stored_total = saturating_add counters.objects_stored_total 1L;
        }
  | Session_started ->
      Ok
        {
          counters with
          sessions_started_total =
            saturating_add counters.sessions_started_total 1L;
        }
  | Session_completed ->
      Ok
        {
          counters with
          sessions_completed_total =
            saturating_add counters.sessions_completed_total 1L;
        }
  | Quota_refused ->
      Ok
        {
          counters with
          quota_refusals_total = saturating_add counters.quota_refusals_total 1L;
        }
  | Sessions_expired { count; reclaimed_bytes } ->
      if count < 0 || reclaimed_bytes < 0 then
        Error (Invalid_expiration { count; reclaimed_bytes })
      else
        Ok
          {
            counters with
            expired_sessions_total =
              saturating_add counters.expired_sessions_total
                (Int64.of_int count);
            reclaimed_session_bytes_total =
              saturating_add counters.reclaimed_session_bytes_total
                (Int64.of_int reclaimed_bytes);
          }

let requests_total value = value.requests_total
let refusals_total value = value.refusals_total
let failures_total value = value.failures_total
let objects_stored_total value = value.objects_stored_total
let sessions_started_total value = value.sessions_started_total
let sessions_completed_total value = value.sessions_completed_total
let quota_refusals_total value = value.quota_refusals_total
let expired_sessions_total value = value.expired_sessions_total
let reclaimed_session_bytes_total value = value.reclaimed_session_bytes_total

let metric name kind help value =
  Printf.sprintf "# HELP %s %s\n# TYPE %s %s\n%s %Ld\n" name help name kind name
    value

let prometheus counters =
  String.concat ""
    [
      metric "yeokcham_relay_expired_sessions_total" "counter"
        "Relay transfer sessions removed after expiry."
        counters.expired_sessions_total;
      metric "yeokcham_relay_failures_total" "counter"
        "Relay requests that failed with a server error."
        counters.failures_total;
      metric "yeokcham_relay_objects_stored_total" "counter"
        "Immutable relay objects stored by successful upload completion."
        counters.objects_stored_total;
      metric "yeokcham_relay_quota_refusals_total" "counter"
        "V2 upload starts refused by the configured temporary-byte quota."
        counters.quota_refusals_total;
      metric "yeokcham_relay_reclaimed_session_bytes_total" "counter"
        "Temporary transfer bytes reclaimed after session expiry."
        counters.reclaimed_session_bytes_total;
      metric "yeokcham_relay_refusals_total" "counter"
        "Relay requests refused by validation or authorization."
        counters.refusals_total;
      metric "yeokcham_relay_requests_total" "counter"
        "Relay requests handled by this process." counters.requests_total;
      metric "yeokcham_relay_sessions_completed_total" "counter"
        "V2 upload sessions completed by this process."
        counters.sessions_completed_total;
      metric "yeokcham_relay_sessions_started_total" "counter"
        "V2 upload sessions started by this process."
        counters.sessions_started_total;
    ]
