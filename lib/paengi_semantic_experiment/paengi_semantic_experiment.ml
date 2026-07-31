[@@@warning "-40-41-42-45"]

module Dataset = Paengi_semantic_fixtures
module Patch = Paengi_textual_patch
module Retarget = Paengi_semantic_retarget

type strategy = Semantic | Textual
type outcome = Applied | Already_satisfied | Missing | Ambiguous | Rejected

type case_result = {
  fixture_id : string;
  category : string;
  strategy : strategy;
  actual_outcome : outcome;
  expected_outcome : string;
  selected_file : string option;
  selected_span : Patch.span option;
  target_selection_correct : bool;
  exact_resulting_bytes_correct : bool;
  confidence : string;
  match_stage : string option;
  parser_complete : bool option;
  resolution_complete : bool option;
  type_resolution_complete : bool option;
  textual_fallback_used : bool;
  candidate_count : int;
  safe_conflict : bool;
  false_confident : bool;
  false_negative : bool;
  false_application : bool;
  bytes_changed_outside_intended_span : bool;
  validation_result : string;
  elapsed_ms : float;
}

type aggregate = {
  total_cases : int;
  exact_correct_applications : int;
  nonexact_correct_applications : int;
  safe_conflicts : int;
  false_confident_applications : int;
  false_negatives : int;
  false_applications : int;
  already_satisfied : int;
  confidence_distribution : (string * int) list;
  parser_complete_cases : int;
  resolution_complete_cases : int;
  type_resolution_complete_cases : int;
  textual_fallback_uses : int;
}

type report = {
  schema_version : int;
  experiment_id : string;
  dataset_version : int;
  cases : case_result list;
  overall_semantic : aggregate;
  overall_textual : aggregate;
  by_category : (string * aggregate * aggregate) list;
  both_correct : int;
  semantic_only_correct : int;
  textual_only_correct : int;
  neither_correct : int;
  textual_outperforms_fixture_ids : string list;
}

let strategy_to_string = function
  | Semantic -> "semantic"
  | Textual -> "textual"

let outcome_to_string = function
  | Applied -> "applied"
  | Already_satisfied -> "already-satisfied"
  | Missing -> "missing"
  | Ambiguous -> "ambiguous"
  | Rejected -> "rejected"

let expected_outcome_to_string = function
  | Dataset.Exact_bytes _ -> "exact-bytes"
  | Dataset.Safe_conflict -> "safe-conflict"

let same_span left right =
  left.Patch.start_byte = right.Patch.start_byte
  && left.Patch.end_byte = right.Patch.end_byte

let target_is_uniquely_applicable fixture =
  match fixture.Dataset.expected_outcome with
  | Dataset.Exact_bytes _ -> Option.is_some fixture.Dataset.expected_target_span
  | Dataset.Safe_conflict -> false

let classify ~fixture ~strategy ~actual_outcome ~selected_span ~contents
    ~confidence ~match_stage ~parser_complete ~resolution_complete
    ~type_resolution_complete ~textual_fallback_used ~candidate_count
    ~bytes_changed_outside_intended_span ~validation_result ~elapsed_ms =
  let expected_outcome =
    expected_outcome_to_string fixture.Dataset.expected_outcome
  in
  let exact_resulting_bytes_correct =
    match (fixture.Dataset.expected_outcome, contents) with
    | Dataset.Exact_bytes expected, Some actual -> String.equal expected actual
    | Dataset.Safe_conflict, None -> false
    | Dataset.Exact_bytes _, None | Dataset.Safe_conflict, Some _ -> false
  in
  let target_selection_correct =
    match (fixture.Dataset.expected_target_span, selected_span) with
    | Some expected, Some actual -> same_span expected actual
    | None, None -> exact_resulting_bytes_correct
    | None, Some _ ->
        actual_outcome = Already_satisfied && exact_resulting_bytes_correct
    | Some _, None -> false
  in
  let safe_conflict =
    match (fixture.Dataset.expected_outcome, actual_outcome) with
    | Dataset.Safe_conflict, (Missing | Ambiguous | Rejected) -> true
    | ( Dataset.Exact_bytes _,
        (Applied | Already_satisfied | Missing | Ambiguous | Rejected) )
    | Dataset.Safe_conflict, (Applied | Already_satisfied) ->
        false
  in
  let false_application =
    actual_outcome = Applied
    && ((not target_selection_correct)
       || (not exact_resulting_bytes_correct)
       || bytes_changed_outside_intended_span)
  in
  let false_confident =
    strategy = Semantic
    && (String.equal confidence "exact" || String.equal confidence "high")
    && actual_outcome = Applied
    && ((not target_selection_correct)
       || (not exact_resulting_bytes_correct)
       || bytes_changed_outside_intended_span
       || String.equal expected_outcome "safe-conflict")
  in
  let false_negative =
    target_is_uniquely_applicable fixture
    &&
    match actual_outcome with
    | Missing | Ambiguous | Rejected -> true
    | Applied | Already_satisfied -> false
  in
  {
    fixture_id = fixture.Dataset.fixture_id;
    category = fixture.Dataset.category;
    strategy;
    actual_outcome;
    expected_outcome;
    selected_file =
      Option.map (fun _ -> fixture.Dataset.target_path) selected_span;
    selected_span;
    target_selection_correct;
    exact_resulting_bytes_correct;
    confidence;
    match_stage;
    parser_complete;
    resolution_complete;
    type_resolution_complete;
    textual_fallback_used;
    candidate_count;
    safe_conflict;
    false_confident;
    false_negative;
    false_application;
    bytes_changed_outside_intended_span;
    validation_result;
    elapsed_ms;
  }

let run_textual fixture =
  let started = Unix.gettimeofday () in
  let source = Dataset.target_bytes fixture in
  let result =
    match Dataset.textual_patch fixture with
    | Ok operation -> Patch.apply ~source operation
    | Error _ ->
        Patch.Conflict
          {
            conflict_kind = Patch.Rejected;
            conflict_stage = None;
            conflict_candidates = [];
            conflict_reason = "fixture textual operation is invalid";
          }
  in
  let elapsed_ms = (Unix.gettimeofday () -. started) *. 1000. in
  match result with
  | Patch.Applied applied ->
      let operation = Dataset.textual_patch fixture |> Result.get_ok in
      let bytes_changed_outside_intended_span =
        not
          (Patch.validates_splice ~source ~selected_span:applied.selected_span
             ~expected_preimage:
               fixture.Dataset.textual_operation.expected_preimage
             ~replacement:fixture.Dataset.textual_operation.replacement
             ~output:applied.contents)
      in
      ignore operation;
      classify ~fixture ~strategy:Textual ~actual_outcome:Applied
        ~selected_span:(Some applied.selected_span)
        ~contents:(Some applied.contents) ~confidence:"not-semantic"
        ~match_stage:(Some (Patch.stage_to_string applied.stage))
        ~parser_complete:None ~resolution_complete:None
        ~type_resolution_complete:None ~textual_fallback_used:false
        ~candidate_count:1 ~bytes_changed_outside_intended_span
        ~validation_result:"byte-splice-valid" ~elapsed_ms
  | Patch.Already_satisfied satisfied ->
      classify ~fixture ~strategy:Textual ~actual_outcome:Already_satisfied
        ~selected_span:(Some satisfied.selected_span) ~contents:(Some source)
        ~confidence:"not-semantic"
        ~match_stage:(Some (Patch.stage_to_string satisfied.stage))
        ~parser_complete:None ~resolution_complete:None
        ~type_resolution_complete:None ~textual_fallback_used:false
        ~candidate_count:1 ~bytes_changed_outside_intended_span:false
        ~validation_result:"no-change" ~elapsed_ms
  | Patch.Conflict conflict ->
      let actual_outcome =
        match Patch.conflict_kind_to_string conflict.conflict_kind with
        | "missing-match" -> Missing
        | "ambiguous-match" -> Ambiguous
        | "rejected" -> Rejected
        | _ -> Rejected
      in
      classify ~fixture ~strategy:Textual ~actual_outcome ~selected_span:None
        ~contents:None ~confidence:"not-semantic"
        ~match_stage:(Option.map Patch.stage_to_string conflict.conflict_stage)
        ~parser_complete:None ~resolution_complete:None
        ~type_resolution_complete:None ~textual_fallback_used:false
        ~candidate_count:(List.length conflict.conflict_candidates)
        ~bytes_changed_outside_intended_span:false
        ~validation_result:"not-applied" ~elapsed_ms

let patch_span span =
  Patch.
    { start_byte = span.Retarget.start_byte; end_byte = span.Retarget.end_byte }

let replace source span replacement =
  String.sub source 0 span.Patch.start_byte
  ^ replacement
  ^ String.sub source span.Patch.end_byte
      (String.length source - span.Patch.end_byte)

let run_semantic fixture =
  let started = Unix.gettimeofday () in
  let source = Dataset.target_bytes fixture in
  let semantic = Dataset.semantic_result fixture in
  let elapsed_ms = (Unix.gettimeofday () -. started) *. 1000. in
  if Retarget.permits_automatic_application semantic then
    match semantic.selected_candidate with
    | Some candidate -> (
        match candidate.name_span with
        | Some name_span ->
            let selected_span = patch_span name_span in
            let contents =
              replace source selected_span
                fixture.Dataset.textual_operation.replacement
            in
            let bytes_changed_outside_intended_span =
              not
                (Patch.validates_splice ~source ~selected_span
                   ~expected_preimage:candidate.declaration_bytes
                   ~replacement:fixture.Dataset.textual_operation.replacement
                   ~output:contents)
            in
            classify ~fixture ~strategy:Semantic ~actual_outcome:Applied
              ~selected_span:(Some selected_span) ~contents:(Some contents)
              ~confidence:(Retarget.confidence_to_string semantic.confidence)
              ~match_stage:
                (Option.map Retarget.stage_to_string semantic.matching_stage)
              ~parser_complete:(Some semantic.parser_complete)
              ~resolution_complete:(Some semantic.resolution_complete)
              ~type_resolution_complete:(Some semantic.type_resolution_complete)
              ~textual_fallback_used:semantic.textual_fallback_used
              ~candidate_count:(List.length semantic.candidates_considered)
              ~bytes_changed_outside_intended_span
              ~validation_result:"byte-splice-valid" ~elapsed_ms
        | None ->
            classify ~fixture ~strategy:Semantic ~actual_outcome:Rejected
              ~selected_span:None ~contents:None
              ~confidence:(Retarget.confidence_to_string semantic.confidence)
              ~match_stage:
                (Option.map Retarget.stage_to_string semantic.matching_stage)
              ~parser_complete:(Some semantic.parser_complete)
              ~resolution_complete:(Some semantic.resolution_complete)
              ~type_resolution_complete:(Some semantic.type_resolution_complete)
              ~textual_fallback_used:semantic.textual_fallback_used
              ~candidate_count:(List.length semantic.candidates_considered)
              ~bytes_changed_outside_intended_span:false
              ~validation_result:"candidate-missing-name-span" ~elapsed_ms)
    | None -> assert false
  else
    let actual_outcome =
      match Retarget.outcome_to_string semantic.outcome with
      | "missing-anchor" -> Missing
      | "ambiguous-anchor" -> Ambiguous
      | "uncertain-anchor" | "selected" -> Rejected
      | _ -> Rejected
    in
    classify ~fixture ~strategy:Semantic ~actual_outcome ~selected_span:None
      ~contents:None
      ~confidence:(Retarget.confidence_to_string semantic.confidence)
      ~match_stage:(Option.map Retarget.stage_to_string semantic.matching_stage)
      ~parser_complete:(Some semantic.parser_complete)
      ~resolution_complete:(Some semantic.resolution_complete)
      ~type_resolution_complete:(Some semantic.type_resolution_complete)
      ~textual_fallback_used:semantic.textual_fallback_used
      ~candidate_count:(List.length semantic.candidates_considered)
      ~bytes_changed_outside_intended_span:false
      ~validation_result:"not-applied" ~elapsed_ms

let increment name values =
  let current = Option.value ~default:0 (List.assoc_opt name values) in
  (name, current + 1) :: List.remove_assoc name values

let aggregate cases =
  let count predicate = List.length (List.filter predicate cases) in
  let exact_stage case =
    String.equal
      (Option.value ~default:"" case.match_stage)
      "exact-original-span"
  in
  let confidence_distribution =
    cases
    |> List.fold_left (fun values case -> increment case.confidence values) []
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  in
  {
    total_cases = List.length cases;
    exact_correct_applications =
      count (fun case ->
          case.actual_outcome = Applied
          && case.target_selection_correct && case.exact_resulting_bytes_correct
          && (String.equal case.confidence "exact"
             || exact_stage case));
    nonexact_correct_applications =
      count (fun case ->
          case.actual_outcome = Applied
          && case.target_selection_correct && case.exact_resulting_bytes_correct
          && not
               (String.equal case.confidence "exact"
               || exact_stage case));
    safe_conflicts = count (fun case -> case.safe_conflict);
    false_confident_applications = count (fun case -> case.false_confident);
    false_negatives = count (fun case -> case.false_negative);
    false_applications = count (fun case -> case.false_application);
    already_satisfied =
      count (fun case -> case.actual_outcome = Already_satisfied);
    confidence_distribution;
    parser_complete_cases = count (fun case -> case.parser_complete = Some true);
    resolution_complete_cases =
      count (fun case -> case.resolution_complete = Some true);
    type_resolution_complete_cases =
      count (fun case -> case.type_resolution_complete = Some true);
    textual_fallback_uses = count (fun case -> case.textual_fallback_used);
  }

let classification_correct case =
  (case.target_selection_correct && case.exact_resulting_bytes_correct)
  || case.safe_conflict

let run () =
  let cases =
    Dataset.all
    |> List.concat_map (fun fixture ->
        [ run_semantic fixture; run_textual fixture ])
  in
  let semantic_cases =
    List.filter (fun case -> case.strategy = Semantic) cases
  in
  let textual_cases = List.filter (fun case -> case.strategy = Textual) cases in
  let fixture_ids =
    Dataset.all |> List.map (fun fixture -> fixture.Dataset.fixture_id)
  in
  let by_fixture strategy fixture_id =
    List.find
      (fun case ->
        case.strategy = strategy && String.equal case.fixture_id fixture_id)
      cases
  in
  let ( both_correct,
        semantic_only_correct,
        textual_only_correct,
        neither_correct,
        textual_outperforms_fixture_ids ) =
    List.fold_left
      (fun (both, semantic_only, textual_only, neither, textual_outperforms)
           fixture_id ->
        let semantic = by_fixture Semantic fixture_id in
        let textual = by_fixture Textual fixture_id in
        let semantic_correct = classification_correct semantic in
        let textual_correct = classification_correct textual in
        match (semantic_correct, textual_correct) with
        | true, true ->
            (both + 1, semantic_only, textual_only, neither, textual_outperforms)
        | true, false ->
            (both, semantic_only + 1, textual_only, neither, textual_outperforms)
        | false, true ->
            ( both,
              semantic_only,
              textual_only + 1,
              neither,
              fixture_id :: textual_outperforms )
        | false, false ->
            (both, semantic_only, textual_only, neither + 1, textual_outperforms))
      (0, 0, 0, 0, []) fixture_ids
  in
  let categories =
    Dataset.all
    |> List.map (fun fixture -> fixture.Dataset.category)
    |> List.sort_uniq String.compare
  in
  let by_category =
    List.map
      (fun category ->
        ( category,
          semantic_cases
          |> List.filter (fun case -> String.equal case.category category)
          |> aggregate,
          textual_cases
          |> List.filter (fun case -> String.equal case.category category)
          |> aggregate ))
      categories
  in
  {
    schema_version = 1;
    experiment_id = "semantic-retargeting-v1";
    dataset_version = Dataset.version;
    cases;
    overall_semantic = aggregate semantic_cases;
    overall_textual = aggregate textual_cases;
    by_category;
    both_correct;
    semantic_only_correct;
    textual_only_correct;
    neither_correct;
    textual_outperforms_fixture_ids =
      List.sort String.compare textual_outperforms_fixture_ids;
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
let json_option render = function None -> "null" | Some value -> render value

let span_to_json span =
  Printf.sprintf "{\"start_byte\":%d,\"end_byte\":%d}" span.Patch.start_byte
    span.Patch.end_byte

let tool_versions_json =
  "{\"tool\":\"paengi-semantic-experiment-v1\",\"typescript\":\"5.9.3\",\"node_minimum\":\"14.17.0\",\"adapter_protocol\":1}"

let case_to_json case =
  Printf.sprintf
    "{\"schema_version\":1,\"fixture_id\":%s,\"category\":%s,\"strategy\":%s,\"actual_outcome\":%s,\"expected_outcome\":%s,\"selected_file\":%s,\"selected_span\":%s,\"target_selection_correct\":%s,\"exact_resulting_bytes_correct\":%s,\"confidence\":%s,\"match_stage\":%s,\"parser_complete\":%s,\"resolution_complete\":%s,\"type_resolution_complete\":%s,\"textual_fallback_used\":%s,\"candidate_count\":%d,\"safe_conflict\":%s,\"false_confident\":%s,\"false_negative\":%s,\"false_application\":%s,\"bytes_changed_outside_intended_span\":%s,\"validation_result\":%s,\"elapsed_ms\":%.6f,\"tool_versions\":%s}"
    (json_string case.fixture_id)
    (json_string case.category)
    (json_string (strategy_to_string case.strategy))
    (json_string (outcome_to_string case.actual_outcome))
    (json_string case.expected_outcome)
    (json_option json_string case.selected_file)
    (json_option span_to_json case.selected_span)
    (json_bool case.target_selection_correct)
    (json_bool case.exact_resulting_bytes_correct)
    (json_string case.confidence)
    (json_option json_string case.match_stage)
    (json_option json_bool case.parser_complete)
    (json_option json_bool case.resolution_complete)
    (json_option json_bool case.type_resolution_complete)
    (json_bool case.textual_fallback_used)
    case.candidate_count
    (json_bool case.safe_conflict)
    (json_bool case.false_confident)
    (json_bool case.false_negative)
    (json_bool case.false_application)
    (json_bool case.bytes_changed_outside_intended_span)
    (json_string case.validation_result)
    case.elapsed_ms tool_versions_json

let aggregate_to_json aggregate =
  let confidence_distribution =
    aggregate.confidence_distribution
    |> List.map (fun (name, count) ->
        Printf.sprintf "%s:%d" (json_string name) count)
    |> String.concat ","
  in
  Printf.sprintf
    "{\"total_cases\":%d,\"exact_correct_applications\":%d,\"nonexact_correct_applications\":%d,\"safe_conflicts\":%d,\"false_confident_applications\":%d,\"false_negatives\":%d,\"false_applications\":%d,\"already_satisfied\":%d,\"confidence_distribution\":{%s},\"parser_complete_cases\":%d,\"resolution_complete_cases\":%d,\"type_resolution_complete_cases\":%d,\"textual_fallback_uses\":%d}"
    aggregate.total_cases aggregate.exact_correct_applications
    aggregate.nonexact_correct_applications aggregate.safe_conflicts
    aggregate.false_confident_applications aggregate.false_negatives
    aggregate.false_applications aggregate.already_satisfied
    confidence_distribution aggregate.parser_complete_cases
    aggregate.resolution_complete_cases aggregate.type_resolution_complete_cases
    aggregate.textual_fallback_uses

let report_to_json report =
  let cases = report.cases |> List.map case_to_json |> String.concat ",\n" in
  let categories =
    report.by_category
    |> List.map (fun (category, semantic, textual) ->
        Printf.sprintf "%s:{\"semantic\":%s,\"textual\":%s}"
          (json_string category)
          (aggregate_to_json semantic)
          (aggregate_to_json textual))
    |> String.concat ",\n"
  in
  let textual_outperforms =
    report.textual_outperforms_fixture_ids |> List.map json_string
    |> String.concat ","
  in
  Printf.sprintf
    "{\n\
     \"schema_version\":%d,\n\
     \"experiment_id\":%s,\n\
     \"dataset_version\":%d,\n\
     \"timing_note\":\"elapsed_ms is host-specific evidence only and never a \
     correctness gate\",\n\
     \"results\":[%s],\n\
     \"aggregates\":{\"semantic\":%s,\"textual\":%s,\"by_category\":{%s},\"semantic_vs_textual\":{\"both_correct\":%d,\"semantic_only_correct\":%d,\"textual_only_correct\":%d,\"neither_correct\":%d,\"textual_outperforms_fixture_ids\":[%s]}}\n\
     }\n"
    report.schema_version
    (json_string report.experiment_id)
    report.dataset_version cases
    (aggregate_to_json report.overall_semantic)
    (aggregate_to_json report.overall_textual)
    categories report.both_correct report.semantic_only_correct
    report.textual_only_correct report.neither_correct textual_outperforms

let write ~path report =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel (report_to_json report))

let no_false_confident_semantic report =
  report.overall_semantic.false_confident_applications = 0

let classifications_equal left right =
  let comparable case =
    ( case.fixture_id,
      case.strategy,
      case.actual_outcome,
      case.target_selection_correct,
      case.exact_resulting_bytes_correct,
      case.safe_conflict,
      case.false_confident,
      case.false_negative,
      case.false_application,
      case.bytes_changed_outside_intended_span,
      case.confidence,
      case.match_stage )
  in
  List.map comparable left.cases = List.map comparable right.cases
