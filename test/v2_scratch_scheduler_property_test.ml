module Scheduler = Yeokcham_v2_scratch_scheduler
module Watcher = Yeokcham_watcher

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let () =
  Printf.printf "V2 scratch scheduler property base seed: %d\n%!" base_seed

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Scheduler.error_to_string error)

let config =
  Scheduler.make_config ~quiet_period:10L ~max_latency:30L |> require_ok

let create () = Scheduler.create config

let paths_request ?(reason = Watcher.Path_change) names =
  {
    Watcher.reason;
    target = Watcher.Paths (List.map (fun name -> [ name ]) names);
  }

let whole_root reason = { Watcher.reason; target = Watcher.Whole_root }

let expect_none name = function
  | None -> ()
  | Some _ -> Alcotest.failf "%s unexpectedly emitted a scan" name

let expect_some name = function
  | Some value -> value
  | None -> Alcotest.failf "%s did not emit a scan" name

let burst_coalesces_paths_and_rename () =
  let state, emission =
    Scheduler.observe (create ()) ~at:0L (paths_request [ "z" ]) |> require_ok
  in
  expect_none "first observation" emission;
  let state, emission =
    Scheduler.observe state ~at:5L
      (paths_request ~reason:Watcher.Rename [ "b"; "a" ])
    |> require_ok
  in
  expect_none "coalesced observation" emission;
  Alcotest.(check (option int64))
    "quiet deadline moves" (Some 15L)
    (Scheduler.next_due_at state);
  let state, emission = Scheduler.advance state ~at:14L |> require_ok in
  expect_none "before deadline" emission;
  let _, emission = Scheduler.advance state ~at:15L |> require_ok in
  let emission = expect_some "deadline" emission in
  Alcotest.(check int64)
    "emission retains deadline" 15L
    (Scheduler.emission_due_at emission);
  Alcotest.(check bool)
    "paths are ordered and rename remains explicit" true
    (Scheduler.emission_request emission
    = paths_request ~reason:Watcher.Rename [ "a"; "b"; "z" ])

let whole_root_requests_dominate_paths () =
  let state, _ =
    Scheduler.observe (create ()) ~at:0L (paths_request [ "a" ]) |> require_ok
  in
  let state, _ =
    Scheduler.observe state ~at:5L (whole_root Watcher.Overflow) |> require_ok
  in
  let _, emission = Scheduler.advance state ~at:15L |> require_ok in
  let emission = expect_some "full rescan" emission in
  Alcotest.(check bool)
    "overflow dominates paths" true
    (Scheduler.emission_request emission = whole_root Watcher.Overflow)

let continuous_bursts_emit_at_maximum_latency () =
  let state, _ =
    Scheduler.observe (create ()) ~at:0L (paths_request [ "a" ]) |> require_ok
  in
  let state, _ =
    Scheduler.observe state ~at:9L (paths_request [ "b" ]) |> require_ok
  in
  let state, _ =
    Scheduler.observe state ~at:18L (paths_request [ "c" ]) |> require_ok
  in
  let state, _ =
    Scheduler.observe state ~at:27L (paths_request [ "d" ]) |> require_ok
  in
  Alcotest.(check (option int64))
    "maximum latency bounds burst" (Some 30L)
    (Scheduler.next_due_at state);
  let state, emission = Scheduler.advance state ~at:29L |> require_ok in
  expect_none "before maximum latency" emission;
  let _, emission = Scheduler.advance state ~at:30L |> require_ok in
  let emission = expect_some "maximum latency" emission in
  Alcotest.(check bool)
    "one ordered scan is emitted" true
    (Scheduler.emission_request emission = paths_request [ "a"; "b"; "c"; "d" ])

let late_observation_emits_then_reschedules () =
  let state, _ =
    Scheduler.observe (create ()) ~at:0L (paths_request [ "a" ]) |> require_ok
  in
  let state, emission =
    Scheduler.observe state ~at:15L (paths_request [ "b" ]) |> require_ok
  in
  let emission = expect_some "late observation" emission in
  Alcotest.(check bool)
    "old request emits first" true
    (Scheduler.emission_request emission = paths_request [ "a" ]);
  Alcotest.(check (option int64))
    "new request is pending" (Some 25L)
    (Scheduler.next_due_at state);
  let _, emission = Scheduler.advance state ~at:25L |> require_ok in
  let emission = expect_some "new deadline" emission in
  Alcotest.(check bool)
    "new request stays separate" true
    (Scheduler.emission_request emission = paths_request [ "b" ])

let no_change_never_requests_a_checkpoint () =
  Alcotest.(check bool)
    "unchanged scan has no publication" true
    (Scheduler.publication_for_scan Scheduler.Unchanged
    = Scheduler.No_checkpoint);
  Alcotest.(check bool)
    "changed scan requests publication" true
    (Scheduler.publication_for_scan Scheduler.Changed
    = Scheduler.Publish_checkpoint)

let invalid_configuration_and_time_are_rejected () =
  Alcotest.(check bool)
    "zero quiet period rejects" true
    (Result.is_error (Scheduler.make_config ~quiet_period:0L ~max_latency:1L));
  Alcotest.(check bool)
    "zero maximum latency rejects" true
    (Result.is_error (Scheduler.make_config ~quiet_period:1L ~max_latency:0L));
  Alcotest.(check bool)
    "inverted duration bounds reject" true
    (Result.is_error (Scheduler.make_config ~quiet_period:2L ~max_latency:1L));
  let state, _ =
    Scheduler.observe (create ()) ~at:10L (paths_request [ "a" ]) |> require_ok
  in
  Alcotest.(check bool)
    "time cannot move backwards" true
    (Result.is_error (Scheduler.advance state ~at:9L))

let generated_bursts_emit_one_bounded_normalized_request =
  QCheck2.Test.make ~count:200 ~name:"V2 scheduler coalesces same-tick bursts"
    QCheck2.Gen.(
      map (List.map string_of_int)
        (list_size (int_range 0 400) (int_range 0 400)))
    (fun names ->
      let state, premature =
        List.fold_left
          (fun (state, premature) name ->
            match Scheduler.observe state ~at:0L (paths_request [ name ]) with
            | Ok (state, emission) ->
                (state, premature || Option.is_some emission)
            | Error _ -> (state, true))
          (create (), false)
          names
      in
      match Scheduler.advance state ~at:30L with
      | Error _ -> false
      | Ok (_, emission) ->
          let paths = List.sort_uniq String.compare names in
          let expected =
            if paths = [] then None
            else if List.length paths > Watcher.max_paths_per_request then
              Some (whole_root Watcher.Path_budget_exceeded)
            else Some (paths_request paths)
          in
          (not premature)
          && Option.map Scheduler.emission_request emission = expected)

let () =
  Alcotest.run "V2 scratch scheduler"
    [
      ( "unit",
        [
          Alcotest.test_case "burst coalesces paths and rename" `Quick
            burst_coalesces_paths_and_rename;
          Alcotest.test_case "whole-root requests dominate paths" `Quick
            whole_root_requests_dominate_paths;
          Alcotest.test_case "continuous bursts respect maximum latency" `Quick
            continuous_bursts_emit_at_maximum_latency;
          Alcotest.test_case "late input emits and reschedules" `Quick
            late_observation_emits_then_reschedules;
          Alcotest.test_case "no change does not publish" `Quick
            no_change_never_requests_a_checkpoint;
          Alcotest.test_case "invalid configuration and time reject" `Quick
            invalid_configuration_and_time_are_rejected;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed |])
            generated_bursts_emit_one_bounded_normalized_request;
        ] );
    ]
