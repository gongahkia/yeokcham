module Comparison = Paengi_rust_retarget_comparison

let contains ~needle value =
  let needle_length = String.length needle in
  let rec search index =
    index + needle_length <= String.length value
    && (String.equal (String.sub value index needle_length) needle
       || search (index + 1))
  in
  search 0

let report_is_deterministic_and_language_separated () =
  let first = Comparison.run () in
  let second = Comparison.run () in
  Alcotest.(check string)
    "deterministic report"
    (Comparison.report_to_json first)
    (Comparison.report_to_json second);
  Alcotest.(check int)
    "TypeScript baseline stays separate" 40
    first.Comparison.typescript_fixture_count;
  Alcotest.(check int)
    "Rust case count" 6
    (List.length first.Comparison.rust_cases)

let rust_reports_textual_outcomes_without_semantic_claims () =
  let report = Comparison.run () in
  let cases = report.Comparison.rust_cases in
  Alcotest.(check int)
    "exact textual applications" 5
    (List.length
       (List.filter
          (fun case ->
            String.equal "applied"
              (Comparison.outcome_to_string case.Comparison.actual_outcome)
            && case.Comparison.exact_resulting_bytes_correct)
          cases));
  Alcotest.(check int)
    "safe conflict" 1
    (List.length
       (List.filter (fun case -> case.Comparison.safe_conflict) cases));
  Alcotest.(check int)
    "fallback-required cases" 2
    (List.length
       (List.filter
          (fun case -> case.Comparison.textual_fallback_required)
          cases));
  Alcotest.(check bool)
    "no false applications" true
    (not (List.exists (fun case -> case.Comparison.false_application) cases));
  Alcotest.(check bool)
    "no false negatives" true
    (not (List.exists (fun case -> case.Comparison.false_negative) cases))

let json_has_explicit_non_comparability_boundary () =
  let json = Comparison.run () |> Comparison.report_to_json in
  Alcotest.(check bool)
    "schema version" true
    (String.starts_with ~prefix:"{\n\"schema_version\":1" json);
  Alcotest.(check bool)
    "no generalisation" true
    (contains ~needle:"\"cross_language_generalisation\":\"not-supported\"" json)

let () =
  Alcotest.run "Rust TypeScript retarget comparison"
    [
      ( "comparison",
        [
          Alcotest.test_case "deterministic separate workloads" `Quick
            report_is_deterministic_and_language_separated;
          Alcotest.test_case "textual outcomes without semantic claims" `Quick
            rust_reports_textual_outcomes_without_semantic_claims;
          Alcotest.test_case "explicit non-comparability boundary" `Quick
            json_has_explicit_non_comparability_boundary;
        ] );
    ]
