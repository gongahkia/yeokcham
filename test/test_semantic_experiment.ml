[@@@warning "-40-42"]

module Experiment = Paengi_semantic_experiment

let deterministic_classifications_and_metrics () =
  let first = Experiment.run () in
  let second = Experiment.run () in
  Alcotest.(check bool)
    "classifications are deterministic" true
    (Experiment.classifications_equal first second);
  Alcotest.(check int)
    "semantic result count" 40 first.Experiment.overall_semantic.total_cases;
  Alcotest.(check int)
    "textual result count" 40 first.Experiment.overall_textual.total_cases

let no_known_false_confident_semantic_application () =
  let report = Experiment.run () in
  Alcotest.(check bool)
    "critical semantic gate" true
    (Experiment.no_false_confident_semantic report);
  Alcotest.(check int)
    "false confident count" 0
    report.Experiment.overall_semantic.false_confident_applications

let textual_advantages_remain_reported () =
  let report = Experiment.run () in
  Alcotest.(check bool)
    "semantic improves the lexical-scope workload" true
    (report.Experiment.semantic_only_correct > 0);
  Alcotest.(check bool)
    "textual-only wins remain visible" true
    (report.Experiment.textual_only_correct > 0);
  Alcotest.(check bool)
    "binary textual-only case is listed" true
    (List.mem "binary-textual-only"
       report.Experiment.textual_outperforms_fixture_ids)

let result_json_has_versioned_envelope () =
  let json = Experiment.run () |> Experiment.report_to_json in
  Alcotest.(check bool)
    "schema version" true
    (String.starts_with ~prefix:"{\n\"schema_version\":1" json);
  Alcotest.(check bool) "per case tool versions" true (String.contains json '5')

let () =
  Alcotest.run "semantic retargeting experiment"
    [
      ( "results",
        [
          Alcotest.test_case "deterministic metrics" `Quick
            deterministic_classifications_and_metrics;
          Alcotest.test_case "false-confidence gate" `Quick
            no_known_false_confident_semantic_application;
          Alcotest.test_case "textual differences are reported" `Quick
            textual_advantages_remain_reported;
          Alcotest.test_case "versioned JSON envelope" `Quick
            result_json_has_versioned_envelope;
        ] );
    ]
