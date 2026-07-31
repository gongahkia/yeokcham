type strategy = Semantic | Textual
type outcome = Applied | Already_satisfied | Missing | Ambiguous | Rejected

type case_result = {
  fixture_id : string;
  category : string;
  strategy : strategy;
  actual_outcome : outcome;
  expected_outcome : string;
  selected_file : string option;
  selected_span : Paengi_textual_patch.span option;
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

val run : unit -> report
val report_to_json : report -> string
val write : path:string -> report -> unit
val strategy_to_string : strategy -> string
val outcome_to_string : outcome -> string
val no_false_confident_semantic : report -> bool
val classifications_equal : report -> report -> bool
