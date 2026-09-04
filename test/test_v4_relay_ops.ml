module Ops = Yeokcham_v4_relay_ops

let require_ok = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "expected OK"

let readiness_is_fail_closed () =
  Alcotest.(check bool)
    "both usable paths are ready" true
    (Ops.assess_readiness ~storage:Ops.Available
       ~credential_registry:Ops.Available
    = Ops.Ready);
  Alcotest.(check bool)
    "storage failure is not ready" true
    (Ops.assess_readiness ~storage:Ops.Not_writable
       ~credential_registry:Ops.Available
    = Ops.Not_ready (Ops.Storage Ops.Not_writable));
  Alcotest.(check bool)
    "registry failure is not ready" true
    (Ops.assess_readiness ~storage:Ops.Available
       ~credential_registry:Ops.Missing
    = Ops.Not_ready (Ops.Credential_registry Ops.Missing))

let counters_are_aggregate_and_canonical () =
  let counters =
    List.fold_left
      (fun counters event -> Ops.record counters event |> require_ok)
      Ops.zero
      [
        Ops.Request_succeeded;
        Ops.Request_refused;
        Ops.Request_failed;
        Ops.Object_stored;
        Ops.Session_started;
        Ops.Session_completed;
        Ops.Quota_refused;
        Ops.Sessions_expired { count = 2; reclaimed_bytes = 11 };
      ]
  in
  Alcotest.(check int64)
    "every request is counted" 3L
    (Ops.requests_total counters);
  Alcotest.(check int64) "refusal count" 1L (Ops.refusals_total counters);
  Alcotest.(check int64) "failure count" 1L (Ops.failures_total counters);
  Alcotest.(check int64) "object count" 1L (Ops.objects_stored_total counters);
  Alcotest.(check int64)
    "expired session count" 2L
    (Ops.expired_sessions_total counters);
  Alcotest.(check int64)
    "reclaimed bytes" 11L
    (Ops.reclaimed_session_bytes_total counters);
  let metrics = Ops.prometheus counters in
  Alcotest.(check bool)
    "no identifiers are represented" false
    (String.contains metrics '{');
  Alcotest.(check string)
    "canonical exposition is stable" metrics (Ops.prometheus counters)

let invalid_expiration_is_refused () =
  match
    Ops.record Ops.zero
      (Ops.Sessions_expired { count = -1; reclaimed_bytes = 0 })
  with
  | Error (Ops.Invalid_expiration _) -> ()
  | Ok _ -> Alcotest.fail "negative expiry count was accepted"

let event_of_code = function
  | 0 -> Ops.Request_succeeded
  | 1 -> Ops.Request_refused
  | 2 -> Ops.Request_failed
  | 3 -> Ops.Object_stored
  | 4 -> Ops.Session_started
  | 5 -> Ops.Session_completed
  | 6 -> Ops.Quota_refused
  | _ -> Ops.Sessions_expired { count = 1; reclaimed_bytes = 1 }

let generated_events_preserve_bounded_aggregate_invariants =
  QCheck2.Test.make ~name:"relay aggregate events remain monotonic and bounded"
    ~count:300
    QCheck2.Gen.(list_size (int_range 0 128) (int_range 0 7))
    (fun codes ->
      let events = List.map event_of_code codes in
      let counters =
        List.fold_left
          (fun counters event -> Ops.record counters event |> Result.get_ok)
          Ops.zero events
      in
      let requests =
        List.fold_left
          (fun total event ->
            match event with
            | Ops.Request_succeeded | Ops.Request_refused | Ops.Request_failed
              ->
                Int64.succ total
            | Ops.Object_stored | Ops.Session_started | Ops.Session_completed
            | Ops.Quota_refused | Ops.Sessions_expired _ ->
                total)
          0L events
      in
      Int64.equal (Ops.requests_total counters) requests
      && Int64.compare (Ops.requests_total counters) 0L >= 0
      && Int64.compare (Ops.expired_sessions_total counters) 0L >= 0
      && Int64.compare (Ops.reclaimed_session_bytes_total counters) 0L >= 0
      && not (String.contains (Ops.prometheus counters) '{'))

let () =
  Alcotest.run "V4 relay operations"
    [
      ( "records",
        [
          Alcotest.test_case "readiness is fail-closed" `Quick
            readiness_is_fail_closed;
          Alcotest.test_case "aggregate counters are canonical" `Quick
            counters_are_aggregate_and_canonical;
          Alcotest.test_case "invalid expiration is refused" `Quick
            invalid_expiration_is_refused;
        ] );
      ( "properties",
        [
          QCheck_alcotest.to_alcotest
            generated_events_preserve_bounded_aggregate_invariants;
        ] );
    ]
