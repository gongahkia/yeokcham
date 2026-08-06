type path = string list
type span = { start_byte : int; end_byte : int }
type declaration_kind = Function | Class | Interface | Type_alias | Variable
type declaration
type parsed

type parse_error =
  | Unterminated_block_comment of int
  | Unterminated_string_literal of int
  | Unbalanced_delimiter of { offset : int; delimiter : char }

val parse_error_to_string : parse_error -> string
val parse : string -> (parsed, parse_error) result
val declarations : parsed -> declaration list
val declaration_kind : declaration -> declaration_kind
val declaration_name : declaration -> string
val declaration_structural_path : declaration -> path
val declaration_span : declaration -> span
val declaration_name_span : declaration -> span

type text_anchor = {
  before_context : string;
  selected : string;
  after_context : string;
}

type exact_textual_fallback = {
  expected_source : string;
  replacement_source : string;
  textual_anchor : text_anchor;
}

type semantic_anchor = {
  language : string;
  kind : declaration_kind;
  symbol_identity : string option;
  structural_path : path;
  source_signature : string list;
  textual_fallback : exact_textual_fallback;
}

type proposal_kind =
  | Rename_declaration of { from_name : string; to_name : string }
  | Move_declaration of { from_path : path; to_path : path }
  | Replace_declaration of { replacement : string }

type proposal

type inference_error =
  | Before_parse_failure of parse_error
  | After_parse_failure of parse_error

val inference_error_to_string : inference_error -> string

val infer :
  path:path ->
  before:string ->
  after:string ->
  (proposal list, inference_error) result

val proposal_kind : proposal -> proposal_kind
val proposal_anchor : proposal -> semantic_anchor
val proposal_fallback : proposal -> exact_textual_fallback

type confidence = Exact | High | Medium | Low | Unknown

type match_evidence =
  | Exact_symbol_identity of string
  | Structural_path_match of path
  | Token_similarity of { common : int; total : int }
  | Textual_context_match of { occurrences : int }
  | Parse_failure of parse_error

type match_conflict_kind =
  | Missing_anchor
  | Ambiguous_anchor
  | Low_confidence_anchor
  | Textual_fallback_required
  | Target_parse_failure

type match_conflict = {
  match_conflict_kind : match_conflict_kind;
  match_conflict_anchor : semantic_anchor;
  match_conflict_candidates : declaration list;
  match_conflict_evidence : match_evidence list;
}

type anchor_match = {
  matched_declaration : declaration;
  matched_confidence : confidence;
  matched_evidence : match_evidence list;
}

type match_result = Matched of anchor_match | Match_conflict of match_conflict

val locate_anchor : source:string -> semantic_anchor -> match_result
val confidence_to_string : confidence -> string
val match_conflict_kind_to_string : match_conflict_kind -> string

type application_conflict_kind =
  | Matching_conflict of match_conflict_kind
  | Manual_review_required of proposal_kind

val application_conflict_kind_to_string : application_conflict_kind -> string

type application =
  | Applied of {
      applied_source : string;
      applied_confidence : confidence;
      applied_evidence : match_evidence list;
    }
  | Application_conflict of {
      application_conflict_kind : application_conflict_kind;
      application_conflict_evidence : match_evidence list;
      application_conflict_fallback : exact_textual_fallback;
    }

val apply : source:string -> proposal -> application

type fallback_error = Source_does_not_match_exact_fallback

val fallback_error_to_string : fallback_error -> string

val apply_exact_textual_fallback :
  source:string -> proposal -> (string, fallback_error) result
