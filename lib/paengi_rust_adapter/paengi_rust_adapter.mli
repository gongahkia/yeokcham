module Protocol : sig
  val version : int
  val maximum_request_bytes : int
  val maximum_response_bytes : int
  val maximum_source_files : int
  val maximum_source_bytes : int
  val maximum_item_records : int
  val maximum_module_facts : int
  val maximum_fallback_facts : int
  val maximum_module_depth : int

  type source_file = { path : string; contents : string }
  type span = { start_byte : int; end_byte : int }

  type item = {
    path : string;
    item_kind : string;
    item_span : span;
    name_span : span option;
    syntactic_name : string option;
  }

  type diagnostic = { path : string; code : string; span : span }

  type analysis = {
    snapshot_id : string;
    adapter_version : string;
    tree_sitter_version : string;
    rust_grammar_version : string;
    parser_complete : bool;
    items : item list;
    parser_diagnostics : diagnostic list;
  }

  type module_fact = {
    root_file : string;
    parent_source_path : string option;
    source_path : string option;
    module_path : string list;
    declaration_span : span;
    module_kind : string;
    status : string;
  }

  type item_path_fact = {
    root_file : string;
    source_path : string;
    module_path : string list;
    item_path_segments : string list option;
    item_kind : string;
    item_span : span;
    name_span : span option;
    syntactic_name : string option;
    parser_complete : bool;
    status : string;
  }

  type unreachable_source = { source_path : string; status : string }

  type module_path_analysis = {
    snapshot_id : string;
    adapter_version : string;
    tree_sitter_version : string;
    rust_grammar_version : string;
    parser_complete : bool;
    module_paths_complete : bool;
    module_facts : module_fact list;
    item_path_facts : item_path_fact list;
    unreachable_sources : unreachable_source list;
  }

  type fallback_fact = {
    path : string;
    fallback_span : span;
    syntax_kind : string;
    status : string;
  }

  type fallback_assessment = {
    snapshot_id : string;
    adapter_version : string;
    tree_sitter_version : string;
    rust_grammar_version : string;
    parser_complete : bool;
    textual_fallback_required : bool;
    fallback_facts : fallback_fact list;
  }

  val make_source_file : path:string -> contents:string -> source_file
  val make_span : start_byte:int -> end_byte:int -> span

  val make_module_fact :
    root_file:string ->
    parent_source_path:string option ->
    source_path:string option ->
    module_path:string list ->
    declaration_span:span ->
    module_kind:string ->
    status:string ->
    module_fact

  val make_item_path_fact :
    root_file:string ->
    source_path:string ->
    module_path:string list ->
    item_path_segments:string list option ->
    item_kind:string ->
    item_span:span ->
    name_span:span option ->
    syntactic_name:string option ->
    parser_complete:bool ->
    status:string ->
    item_path_fact

  val make_unreachable_source :
    source_path:string -> status:string -> unreachable_source

  val make_fallback_fact :
    path:string ->
    fallback_span:span ->
    syntax_kind:string ->
    status:string ->
    fallback_fact

  val source_file_path : source_file -> string
  val source_file_contents : source_file -> string
  val item_path : item -> string
  val item_kind : item -> string
  val item_span : item -> span
  val item_name_span : item -> span option
  val item_syntactic_name : item -> string option
  val diagnostic_path : diagnostic -> string
  val diagnostic_code : diagnostic -> string
  val diagnostic_span : diagnostic -> span
  val analysis_snapshot_id : analysis -> string
  val analysis_adapter_version : analysis -> string
  val analysis_tree_sitter_version : analysis -> string
  val analysis_rust_grammar_version : analysis -> string
  val analysis_parser_complete : analysis -> bool
  val analysis_items : analysis -> item list
  val analysis_parser_diagnostics : analysis -> diagnostic list
  val module_fact_root_file : module_fact -> string
  val module_fact_parent_source_path : module_fact -> string option
  val module_fact_source_path : module_fact -> string option
  val module_fact_module_path : module_fact -> string list
  val module_fact_declaration_span : module_fact -> span
  val module_fact_kind : module_fact -> string
  val module_fact_status : module_fact -> string
  val item_path_fact_root_file : item_path_fact -> string
  val item_path_fact_source_path : item_path_fact -> string
  val item_path_fact_module_path : item_path_fact -> string list
  val item_path_fact_segments : item_path_fact -> string list option
  val item_path_fact_kind : item_path_fact -> string
  val item_path_fact_span : item_path_fact -> span
  val item_path_fact_name_span : item_path_fact -> span option
  val item_path_fact_syntactic_name : item_path_fact -> string option
  val item_path_fact_parser_complete : item_path_fact -> bool
  val item_path_fact_status : item_path_fact -> string
  val unreachable_source_path : unreachable_source -> string
  val unreachable_source_status : unreachable_source -> string
  val fallback_fact_path : fallback_fact -> string
  val fallback_fact_span : fallback_fact -> span
  val fallback_fact_syntax_kind : fallback_fact -> string
  val fallback_fact_status : fallback_fact -> string
  val fallback_assessment_snapshot_id : fallback_assessment -> string
  val fallback_assessment_parser_complete : fallback_assessment -> bool

  val fallback_assessment_textual_fallback_required :
    fallback_assessment -> bool

  val fallback_assessment_facts : fallback_assessment -> fallback_fact list
  val module_path_analysis_snapshot_id : module_path_analysis -> string
  val module_path_analysis_parser_complete : module_path_analysis -> bool
  val module_path_analysis_complete : module_path_analysis -> bool

  val module_path_analysis_module_facts :
    module_path_analysis -> module_fact list

  val module_path_analysis_item_path_facts :
    module_path_analysis -> item_path_fact list

  val module_path_analysis_unreachable_sources :
    module_path_analysis -> unreachable_source list

  val span_start_byte : span -> int
  val span_end_byte : span -> int
end

type configuration = {
  adapter_path : string;
  timeout_ms : int;
  max_request_bytes : int;
  max_response_bytes : int;
  max_stderr_bytes : int;
}

val default_configuration : configuration

val configuration_with :
  ?adapter_path:string ->
  ?timeout_ms:int ->
  ?max_request_bytes:int ->
  ?max_response_bytes:int ->
  ?max_stderr_bytes:int ->
  configuration ->
  configuration

type unavailable_reason =
  | Adapter_missing of string
  | Adapter_request_too_large of { limit : int }
  | Adapter_timeout of { timeout_ms : int }
  | Adapter_output_too_large of { limit : int }
  | Adapter_crashed of {
      exit_code : int option;
      signal : int option;
      stderr : string;
    }
  | Malformed_adapter_response of string
  | Unsupported_protocol of string
  | Adapter_error of { code : string; message : string }
  | Snapshot_error of Paengi_snapshot.error

val unavailable_reason_to_string : unavailable_reason -> string

type handshake = {
  adapter_version : string;
  tree_sitter_version : string;
  rust_grammar_version : string;
  request_limit_bytes : int;
  response_limit_bytes : int;
  capabilities : string list;
}

val handshake_adapter_version : handshake -> string
val handshake_tree_sitter_version : handshake -> string
val handshake_rust_grammar_version : handshake -> string
val handshake_capabilities : handshake -> string list

type 'a result = Available of 'a | Unavailable of unavailable_reason

val handshake : configuration -> handshake result

val analyze_files :
  configuration ->
  snapshot_id:string ->
  files:Protocol.source_file list ->
  Protocol.analysis result

val analyze_snapshot :
  configuration ->
  store:Paengi_store.repository ->
  snapshot:Paengi_snapshot.Snapshot.id ->
  Protocol.analysis result

val resolve_module_paths_files :
  configuration ->
  snapshot_id:string ->
  root_files:string list ->
  files:Protocol.source_file list ->
  Protocol.module_path_analysis result

val resolve_module_paths_snapshot :
  configuration ->
  store:Paengi_store.repository ->
  snapshot:Paengi_snapshot.Snapshot.id ->
  root_files:string list ->
  Protocol.module_path_analysis result

val inspect_fallback_files :
  configuration ->
  snapshot_id:string ->
  files:Protocol.source_file list ->
  Protocol.fallback_assessment result

val inspect_fallback_snapshot :
  configuration ->
  store:Paengi_store.repository ->
  snapshot:Paengi_snapshot.Snapshot.id ->
  Protocol.fallback_assessment result
