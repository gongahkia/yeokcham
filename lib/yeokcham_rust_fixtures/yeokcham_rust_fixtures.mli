(** Deterministic nonpersistent Rust rename/move fixture inputs. The exact-byte
    oracle is only for [Yeokcham_textual_patch]; it is not a Rust semantic
    retargeting result. *)

type expected_outcome = Exact_textual_bytes of string | Safe_conflict

type textual_operation = {
  original_path : string;
  original_start_byte : int;
  expected_preimage : string;
  replacement : string;
  before_context : string;
  after_context : string;
}

type fallback_expectation = {
  parser_complete : bool;
  textual_fallback_required : bool;
  fallback_syntax_kinds : string list;
}

type module_expectation = {
  root_files : string list;
  module_paths_complete : bool;
  module_statuses : string list;
}

type fixture = {
  dataset_version : int;
  fixture_id : string;
  category : string;
  original_project : (string * string) list;
  authored_changed_project : (string * string) list;
  retarget_base : (string * string) list;
  target_path : string;
  textual_operation : textual_operation;
  expected_target_span : Yeokcham_textual_patch.span option;
  expected_outcome : expected_outcome;
  fallback_expectation : fallback_expectation;
  module_expectation : module_expectation option;
  adversarial_explanation : string;
}

val version : int
val all : fixture list
val find : string -> fixture option
val target_bytes : fixture -> string
val textual_patch : fixture -> (Yeokcham_textual_patch.operation, string) result
