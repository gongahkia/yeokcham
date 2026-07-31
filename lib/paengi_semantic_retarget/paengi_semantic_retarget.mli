(** Pure nonpersistent selection from explicit semantic evidence.
    Compiler-derived strings are evidence, never Paengi identities. *)

type span = { start_byte : int; end_byte : int }
type text_context = { before : string; selected : string; after : string }

type completeness = {
  parser_complete : bool;
  resolution_complete : bool;
  type_resolution_complete : bool;
}

type anchor = {
  operation_id : string;
  module_path : string;
  exported_symbol_path : string list;
  resolved_symbol : string option;
  declaration_kind : string;
  overload_ordinal : int;
  signature_digest : string option;
  type_shape_digest : string option;
  lexical_path : string list;
  declaration_shape_digest : string;
  token_digest : string option;
  original_span : span;
  original_bytes : string;
  original_context : text_context;
}

type candidate = {
  candidate_id : string;
  module_path : string;
  exported_symbol_path : string list;
  resolved_symbol : string option;
  declaration_kind : string;
  overload_ordinal : int;
  signature_digest : string option;
  type_shape_digest : string option;
  lexical_path : string list;
  declaration_shape_digest : string;
  token_digest : string option;
  declaration_span : span;
  name_span : span option;
  declaration_bytes : string;
  declaration_context : text_context;
  merged_declaration_count : int;
}

type stage =
  | Exact_original_bytes_and_span
  | Module_and_exported_symbol_path
  | Resolved_alias_or_symbol
  | Declaration_kind_signature_and_type_shape
  | Lexical_or_structural_declaration_path
  | Declaration_shape_and_token_similarity
  | Exact_textual_fallback

type confidence = Exact | High | Medium | Low | Unknown
type outcome = Selected | Missing_anchor | Ambiguous_anchor | Uncertain_anchor

type candidate_report = {
  candidate : candidate;
  supporting_stages : stage list;
  contradictory_or_missing_evidence : string list;
}

type result = {
  operation_id : string;
  outcome : outcome;
  candidates_considered : candidate_report list;
  selected_candidate : candidate option;
  matching_stage : stage option;
  confidence : confidence;
  parser_complete : bool;
  resolution_complete : bool;
  type_resolution_complete : bool;
  alias_resolved : bool;
  textual_fallback_used : bool;
  rejection_or_ambiguity_reason : string option;
}

val select :
  completeness:completeness ->
  anchor:anchor ->
  candidates:candidate list ->
  result

val stage_to_string : stage -> string
val confidence_to_string : confidence -> string
val outcome_to_string : outcome -> string
val permits_automatic_application : result -> bool
