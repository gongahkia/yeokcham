[@@@warning "-41-42"]

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

let stages =
  [
    Exact_original_bytes_and_span;
    Module_and_exported_symbol_path;
    Resolved_alias_or_symbol;
    Declaration_kind_signature_and_type_shape;
    Lexical_or_structural_declaration_path;
    Declaration_shape_and_token_similarity;
    Exact_textual_fallback;
  ]

let head_opt = function [] -> None | value :: _ -> Some value

let stage_to_string = function
  | Exact_original_bytes_and_span -> "exact-original-bytes-and-span"
  | Module_and_exported_symbol_path -> "module-and-exported-symbol-path"
  | Resolved_alias_or_symbol -> "resolved-alias-or-symbol"
  | Declaration_kind_signature_and_type_shape ->
      "declaration-kind-signature-and-type-shape"
  | Lexical_or_structural_declaration_path ->
      "lexical-or-structural-declaration-path"
  | Declaration_shape_and_token_similarity ->
      "declaration-shape-and-token-similarity"
  | Exact_textual_fallback -> "exact-textual-fallback"

let confidence_to_string = function
  | Exact -> "exact"
  | High -> "high"
  | Medium -> "medium"
  | Low -> "low"
  | Unknown -> "unknown"

let outcome_to_string = function
  | Selected -> "selected"
  | Missing_anchor -> "missing-anchor"
  | Ambiguous_anchor -> "ambiguous-anchor"
  | Uncertain_anchor -> "uncertain-anchor"

let same_span left right =
  left.start_byte = right.start_byte && left.end_byte = right.end_byte

let same_context left right =
  String.equal left.before right.before
  && String.equal left.selected right.selected
  && String.equal left.after right.after

let option_equal left right =
  match (left, right) with
  | None, None -> true
  | Some left, Some right -> String.equal left right
  | None, Some _ | Some _, None -> false

let stage_matches stage (anchor : anchor) (candidate : candidate) =
  match stage with
  | Exact_original_bytes_and_span ->
      String.equal anchor.module_path candidate.module_path
      && same_span anchor.original_span candidate.declaration_span
      && String.equal anchor.original_bytes candidate.declaration_bytes
      && same_context anchor.original_context candidate.declaration_context
  | Module_and_exported_symbol_path ->
      String.equal anchor.module_path candidate.module_path
      && anchor.exported_symbol_path = candidate.exported_symbol_path
  | Resolved_alias_or_symbol -> (
      match (anchor.resolved_symbol, candidate.resolved_symbol) with
      | Some anchor, Some candidate -> String.equal anchor candidate
      | None, None | None, Some _ | Some _, None -> false)
  | Declaration_kind_signature_and_type_shape ->
      String.equal anchor.declaration_kind candidate.declaration_kind
      && anchor.overload_ordinal = candidate.overload_ordinal
      && option_equal anchor.signature_digest candidate.signature_digest
      && option_equal anchor.type_shape_digest candidate.type_shape_digest
      && String.equal anchor.declaration_shape_digest
           candidate.declaration_shape_digest
  | Lexical_or_structural_declaration_path ->
      anchor.lexical_path = candidate.lexical_path
  | Declaration_shape_and_token_similarity ->
      String.equal anchor.declaration_shape_digest
        candidate.declaration_shape_digest
      && option_equal anchor.token_digest candidate.token_digest
  | Exact_textual_fallback ->
      String.equal anchor.original_bytes candidate.declaration_bytes
      && same_context anchor.original_context candidate.declaration_context

let missing_details stage (anchor : anchor) (candidate : candidate) =
  if stage_matches stage anchor candidate then None
  else Some (stage_to_string stage ^ " did not match")

let report (anchor : anchor) (candidate : candidate) =
  let supporting_stages =
    List.filter (fun stage -> stage_matches stage anchor candidate) stages
  in
  let contradictory_or_missing_evidence =
    List.filter_map (fun stage -> missing_details stage anchor candidate) stages
  in
  { candidate; supporting_stages; contradictory_or_missing_evidence }

let compare_candidate (left : candidate) (right : candidate) =
  match String.compare left.candidate_id right.candidate_id with
  | 0 -> (
      match String.compare left.module_path right.module_path with
      | 0 ->
          compare left.declaration_span.start_byte
            right.declaration_span.start_byte
      | comparison -> comparison)
  | comparison -> comparison

let confidence (completeness : completeness) selected_stages =
  let has stage = List.mem stage selected_stages in
  if has Exact_original_bytes_and_span then Exact
  else if
    completeness.parser_complete && completeness.resolution_complete
    && completeness.type_resolution_complete
    && has Declaration_kind_signature_and_type_shape
    && (has Module_and_exported_symbol_path || has Resolved_alias_or_symbol)
  then High
  else if has Exact_textual_fallback then Low
  else if has Declaration_kind_signature_and_type_shape then Medium
  else if
    has Lexical_or_structural_declaration_path
    || has Declaration_shape_and_token_similarity
  then Low
  else Unknown

let select ~(completeness : completeness) ~(anchor : anchor) ~candidates =
  let candidates = List.sort compare_candidate candidates in
  let candidates_considered = List.map (report anchor) candidates in
  let rec refine remaining selected_stages = function
    | [] -> (remaining, List.rev selected_stages)
    | stage :: rest ->
        let supporting =
          List.filter
            (fun candidate -> stage_matches stage anchor candidate)
            remaining
        in
        if supporting = [] then refine remaining selected_stages rest
        else refine supporting (stage :: selected_stages) rest
  in
  let remaining, selected_stages = refine candidates [] stages in
  let parser_complete = completeness.parser_complete in
  let resolution_complete = completeness.resolution_complete in
  let type_resolution_complete = completeness.type_resolution_complete in
  let alias_resolved =
    match anchor.resolved_symbol with Some _ -> true | None -> false
  in
  match remaining with
  | [] ->
      {
        operation_id = anchor.operation_id;
        outcome = Missing_anchor;
        candidates_considered;
        selected_candidate = None;
        matching_stage = None;
        confidence = Unknown;
        parser_complete;
        resolution_complete;
        type_resolution_complete;
        alias_resolved;
        textual_fallback_used = false;
        rejection_or_ambiguity_reason = Some "no candidates were supplied";
      }
  | [ candidate ] ->
      let confidence = confidence completeness selected_stages in
      let matching_stage = head_opt selected_stages in
      let textual_fallback_used =
        Option.exists
          (fun stage -> stage = Exact_textual_fallback)
          matching_stage
      in
      let outcome, reason =
        match confidence with
        | Exact | High -> (Selected, None)
        | Medium | Low | Unknown ->
            ( Uncertain_anchor,
              Some
                "unique candidate lacks sufficient complete semantic evidence \
                 for automatic application" )
      in
      {
        operation_id = anchor.operation_id;
        outcome;
        candidates_considered;
        selected_candidate = Some candidate;
        matching_stage;
        confidence;
        parser_complete;
        resolution_complete;
        type_resolution_complete;
        alias_resolved;
        textual_fallback_used;
        rejection_or_ambiguity_reason = reason;
      }
  | candidates ->
      {
        operation_id = anchor.operation_id;
        outcome = Ambiguous_anchor;
        candidates_considered;
        selected_candidate = None;
        matching_stage = head_opt selected_stages;
        confidence = Unknown;
        parser_complete;
        resolution_complete;
        type_resolution_complete;
        alias_resolved;
        textual_fallback_used = false;
        rejection_or_ambiguity_reason =
          Some
            (Printf.sprintf
               "%d candidates remain equivalent after ordered evidence stages"
               (List.length candidates));
      }

let permits_automatic_application result =
  result.outcome = Selected
  && (result.confidence = Exact || result.confidence = High)
