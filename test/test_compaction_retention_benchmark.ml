module Benchmark = Yeokcham_compaction_benchmark

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Benchmark.error_to_string error)

let fixture_checksum_is_stable () =
  let first = Benchmark.fixture_checksum () in
  let second = Benchmark.fixture_checksum () in
  Alcotest.(check string) "fixture checksum is deterministic" first second;
  Alcotest.(check string)
    "fixture bytes are versioned"
    "77f970749ac96aec6cdeff0cb02a39da7e801590498ed5e4e6006ce2d946c247" first;
  Alcotest.(check int) "fixture checksum length" 64 (String.length first)

let invalid_repetitions_are_structured () =
  match Benchmark.run ~repetitions:0 with
  | Ok _ -> Alcotest.fail "zero repetitions was accepted"
  | Error error ->
      Alcotest.(check string)
        "repetition failure is structured" "repetitions must be positive: 0"
        (Benchmark.error_to_string error)

let timing_summary_is_exact () =
  let timing = Benchmark.summarize [ 9L; 1L; 5L; 3L; 7L ] |> require_ok in
  Alcotest.(check int64) "minimum" 1L timing.Benchmark.min_ns;
  Alcotest.(check int64) "lower median" 5L timing.Benchmark.median_ns;
  Alcotest.(check int64) "maximum" 9L timing.Benchmark.max_ns

let fixture_policies_restore_the_pinned_target () =
  let report = Benchmark.run ~repetitions:1 |> require_ok in
  Alcotest.(check int)
    "four implemented policies" 4
    (List.length report.Benchmark.results);
  List.iter
    (fun (result : Benchmark.policy_result) ->
      Alcotest.(check int)
        "one completed sample" 1
        (List.length result.Benchmark.samples);
      match result.Benchmark.samples with
      | [ sample ] ->
          Alcotest.(check bool)
            "pinned target restores exactly" true
            sample.Benchmark.restored_pinned_target;
          Alcotest.(check bool)
            "active object store is measured" true
            (Int64.compare sample.Benchmark.active_object_store_bytes 0L > 0);
          Alcotest.(check bool)
            "retention has a physical chain" true
            (sample.Benchmark.max_physical_event_depth > 0)
      | _ -> Alcotest.fail "unexpected benchmark sample count")
    report.Benchmark.results

let report_is_versioned_json () =
  let report = Benchmark.run ~repetitions:1 |> require_ok in
  let json = Benchmark.report_to_json report in
  Alcotest.(check bool)
    "versioned envelope" true
    (String.starts_with ~prefix:"{\n\"schema_version\":1" json);
  Alcotest.(check bool)
    "fixture checksum recorded" true (String.contains json 'c')

let () =
  Alcotest.run "scratch retention benchmark"
    [
      ( "report",
        [
          Alcotest.test_case "fixture checksum is stable" `Quick
            fixture_checksum_is_stable;
          Alcotest.test_case "invalid repetitions are structured" `Quick
            invalid_repetitions_are_structured;
          Alcotest.test_case "timing summary is exact" `Quick
            timing_summary_is_exact;
          Alcotest.test_case "implemented policies restore pinned target" `Slow
            fixture_policies_restore_the_pinned_target;
          Alcotest.test_case "report has versioned JSON" `Slow
            report_is_versioned_json;
        ] );
    ]
