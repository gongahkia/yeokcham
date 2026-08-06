(** A deterministic byte-only contextual patch baseline. Strings are treated as
    arbitrary bytes; this module has no parser, compiler, or semantic inputs. *)

type span = { start_byte : int; end_byte : int }

type stage =
  | Exact_original_span
  | Unique_exact_preimage
  | Unique_full_context
  | Relaxed_context of int

type operation

val make :
  original_span:span ->
  expected_preimage:string ->
  replacement:string ->
  before_context:string ->
  after_context:string ->
  relaxed_context_bytes:int list ->
  (operation, string) result

val default_relaxed_context_bytes : int list

type conflict_kind = Missing_match | Ambiguous_match | Rejected

type conflict = {
  conflict_kind : conflict_kind;
  conflict_stage : stage option;
  conflict_candidates : span list;
  conflict_reason : string;
}

type outcome =
  | Applied of { contents : string; selected_span : span; stage : stage }
  | Already_satisfied of { selected_span : span; stage : stage }
  | Conflict of conflict

val apply : source:string -> operation -> outcome
val stage_to_string : stage -> string
val conflict_kind_to_string : conflict_kind -> string

val validates_splice :
  source:string ->
  selected_span:span ->
  expected_preimage:string ->
  replacement:string ->
  output:string ->
  bool
(** Checks the strategy-neutral splice invariant: [output] differs from [source]
    only at [selected_span], which must contain [expected_preimage]. *)
