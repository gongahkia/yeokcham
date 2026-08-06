[@@@warning "-40-41-42"]

module Dataset = Yeokcham_rust_fixtures
module Patch = Yeokcham_textual_patch

type outcome = Applied | Safe_conflict | Rejected

type rust_case = {
  fixture_id : string;
  category : string;
  expected_outcome : string;
  actual_outcome : outcome;
  exact_resulting_bytes_correct : bool;
  safe_conflict : bool;
  false_application : bool;
  false_negative : bool;
  parser_complete : bool;
  textual_fallback_required : bool;
}

type report = {
  schema_version : int;
  experiment_id : string;
  typescript_fixture_count : int;
  rust_dataset_version : int;
  rust_cases : rust_case list;
}

let outcome_to_string = function
  | Applied -> "applied"
  | Safe_conflict -> "safe-conflict"
  | Rejected -> "rejected"

let expected_outcome_to_string = function
  | Dataset.Exact_textual_bytes _ -> "exact-textual-bytes"
  | Dataset.Safe_conflict -> "safe-conflict"

let run_case fixture =
  let expected_outcome =
    expected_outcome_to_string fixture.Dataset.expected_outcome
  in
  let fallback = fixture.Dataset.fallback_expectation in
  let actual_outcome, exact_resulting_bytes_correct, safe_conflict =
    match (fixture.Dataset.expected_outcome, Dataset.textual_patch fixture) with
    | Dataset.Exact_textual_bytes expected, Ok operation -> (
        match Patch.apply ~source:(Dataset.target_bytes fixture) operation with
        | Patch.Applied applied ->
            (Applied, String.equal expected applied.contents, false)
        | Patch.Already_satisfied _ | Patch.Conflict _ ->
            (Rejected, false, false))
    | Dataset.Safe_conflict, Ok operation -> (
        match Patch.apply ~source:(Dataset.target_bytes fixture) operation with
        | Patch.Conflict _ -> (Safe_conflict, false, true)
        | Patch.Applied _ | Patch.Already_satisfied _ -> (Applied, false, false)
        )
    | Dataset.Exact_textual_bytes _, Error _ | Dataset.Safe_conflict, Error _ ->
        (Rejected, false, false)
  in
  let false_application =
    actual_outcome = Applied
    && ((not exact_resulting_bytes_correct)
       || String.equal expected_outcome "safe-conflict")
  in
  let false_negative =
    String.equal expected_outcome "exact-textual-bytes"
    && actual_outcome <> Applied
  in
  {
    fixture_id = fixture.Dataset.fixture_id;
    category = fixture.Dataset.category;
    expected_outcome;
    actual_outcome;
    exact_resulting_bytes_correct;
    safe_conflict;
    false_application;
    false_negative;
    parser_complete = fallback.Dataset.parser_complete;
    textual_fallback_required = fallback.Dataset.textual_fallback_required;
  }

let run () =
  {
    schema_version = 1;
    experiment_id = "rust-typescript-retargeting-comparison-v1";
    typescript_fixture_count = 40;
    rust_dataset_version = Dataset.version;
    rust_cases = List.map run_case Dataset.all;
  }

let json_string value =
  let buffer = Buffer.create (String.length value + 8) in
  Buffer.add_char buffer '"';
  String.iter
    (fun character ->
      match character with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | character when Char.code character < 0x20 ->
          Buffer.add_string buffer
            (Printf.sprintf "\\u%04x" (Char.code character))
      | character -> Buffer.add_char buffer character)
    value;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let json_bool value = if value then "true" else "false"

let case_to_json case =
  Printf.sprintf
    "{\"fixture_id\":%s,\"category\":%s,\"expected_outcome\":%s,\"actual_outcome\":%s,\"exact_resulting_bytes_correct\":%s,\"safe_conflict\":%s,\"false_application\":%s,\"false_negative\":%s,\"parser_complete\":%s,\"textual_fallback_required\":%s}"
    (json_string case.fixture_id)
    (json_string case.category)
    (json_string case.expected_outcome)
    (json_string (outcome_to_string case.actual_outcome))
    (json_bool case.exact_resulting_bytes_correct)
    (json_bool case.safe_conflict)
    (json_bool case.false_application)
    (json_bool case.false_negative)
    (json_bool case.parser_complete)
    (json_bool case.textual_fallback_required)

let count predicate cases = List.length (List.filter predicate cases)

let rust_aggregate_json cases =
  Printf.sprintf
    "{\"total_cases\":%d,\"exact_textual_applications\":%d,\"safe_conflicts\":%d,\"false_confident_semantic_applications\":0,\"false_negatives\":%d,\"false_applications\":%d,\"semantic_attempts\":0,\"parser_complete_cases\":%d,\"textual_fallback_required_cases\":%d}"
    (List.length cases)
    (count
       (fun case ->
         case.actual_outcome = Applied && case.exact_resulting_bytes_correct)
       cases)
    (count (fun case -> case.safe_conflict) cases)
    (count (fun case -> case.false_negative) cases)
    (count (fun case -> case.false_application) cases)
    (count (fun case -> case.parser_complete) cases)
    (count (fun case -> case.textual_fallback_required) cases)

let report_to_json report =
  let cases =
    report.rust_cases |> List.map case_to_json |> String.concat ",\n"
  in
  Printf.sprintf
    "{\n\
     \"schema_version\":%d,\n\
     \"experiment_id\":%s,\n\
     \"timing_note\":\"this report has no timing comparison or cross-language \
     rate claim\",\n\
     \"comparison_boundary\":{\"workloads_are_separate\":true,\"cross_language_generalisation\":\"not-supported\",\"rust_semantic_retargeting\":\"not-implemented\"},\n\
     \"typescript_baseline\":{\"source_report\":\"semantic-retargeting-v1\",\"dataset_version\":1,\"fixture_count\":%d,\"semantic\":{\"false_confident_applications\":0,\"false_negatives\":6,\"false_applications\":0},\"textual\":{\"false_confident_applications\":0,\"false_negatives\":1,\"false_applications\":0}},\n\
     \"rust_workload\":{\"dataset_version\":%d,\"fixtures\":[%s],\"aggregate\":%s},\n\
     \"limitations\":[\"TypeScript v1 metrics are preserved by reference and \
     are not recomputed here\",\"Rust cases measure only exact textual patch \
     outcomes plus syntax fallback evidence\",\"No Rust semantic retargeting \
     attempt or confidence result exists\"]\n\
     }\n"
    report.schema_version
    (json_string report.experiment_id)
    report.typescript_fixture_count report.rust_dataset_version cases
    (rust_aggregate_json report.rust_cases)

let write ~path report =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel (report_to_json report))
