(** A deterministic language-separated research report. Rust entries describe
    only exact textual results and fallback evidence; they are not semantic
    retargeting outcomes or cross-language rates. *)

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

val run : unit -> report
val report_to_json : report -> string
val write : path:string -> report -> unit
val outcome_to_string : outcome -> string
