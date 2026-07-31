type expected_outcome = Exact_bytes of string | Safe_conflict

type textual_operation = {
  original_start_byte : int;
  expected_preimage : string;
  replacement : string;
  before_context : string;
  after_context : string;
}

type fixture = {
  dataset_version : int;
  fixture_id : string;
  category : string;
  operation_id : string;
  original_project : (string * string) list;
  authored_changed_project : (string * string) list;
  retarget_base : (string * string) list;
  target_path : string;
  textual_operation : textual_operation;
  semantic_anchor : Paengi_semantic_retarget.anchor;
  semantic_candidates : Paengi_semantic_retarget.candidate list;
  expected_target_span : Paengi_textual_patch.span option;
  expected_outcome : expected_outcome;
  acceptable_confidence_ceiling : Paengi_semantic_retarget.confidence;
  parser_complete : bool;
  resolution_complete : bool;
  type_resolution_complete : bool;
  adversarial_explanation : string;
}

val version : int
val all : fixture list
val find : string -> fixture option
val textual_patch : fixture -> (Paengi_textual_patch.operation, string) result
val target_bytes : fixture -> string
val semantic_result : fixture -> Paengi_semantic_retarget.result
