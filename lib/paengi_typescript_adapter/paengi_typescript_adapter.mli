module Protocol : sig
  val version : int
  val maximum_request_bytes : int
  val maximum_response_bytes : int

  type language = Ts | Tsx
  type source_file = { path : string; language : language; contents : string }

  type compiler_options = {
    strict : bool;
    jsx : [ `Preserve | `React_jsx | `React ] option;
    module_resolution : [ `Bundler | `Node16 | `Node_next ] option;
    base_url : string option;
    paths : (string * string list) list;
  }

  type span = { start_byte : int; end_byte : int }

  type symbol = {
    qualified_name : string;
    alias_qualified_name : string option;
    declaration_locations : string list;
    merged_declaration_count : int;
  }

  type declaration = {
    path : string;
    declaration_kind : string;
    declaration_span : span;
    name_span : span option;
    parent_declaration_path : string list;
    exported : bool;
    default : bool;
    local : bool;
    syntactic_name : string option;
    overload_ordinal : int;
    declaration_shape_digest : string;
    signature_digest : string option;
    symbol : symbol option;
  }

  type diagnostic = {
    code : int;
    category : string;
    message : string;
    path : string option;
    span : span option;
  }

  type resolution_diagnostic = {
    containing_file : string option;
    module_name : string;
  }

  type analysis = {
    snapshot_id : string;
    typescript_version : string;
    parser_complete : bool;
    resolution_complete : bool;
    semantic_complete : bool;
    type_resolution_complete : bool;
    declarations : declaration list;
    parser_diagnostics : diagnostic list;
    resolution_diagnostics : resolution_diagnostic list;
    type_checker_diagnostics : diagnostic list;
    elapsed_ms : float;
  }

  val source_file_path : source_file -> string

  val make_source_file :
    path:string -> language:language -> contents:string -> source_file

  val make_span : start_byte:int -> end_byte:int -> span
  val default_compiler_options : compiler_options
  val analysis_snapshot_id : analysis -> string
  val analysis_typescript_version : analysis -> string
  val analysis_parser_complete : analysis -> bool
  val analysis_resolution_complete : analysis -> bool
  val analysis_semantic_complete : analysis -> bool
  val analysis_declarations : analysis -> declaration list
  val declaration_path : declaration -> string
  val declaration_kind : declaration -> string
  val declaration_span : declaration -> span
  val declaration_name_span : declaration -> span option
  val declaration_syntactic_name : declaration -> string option
  val declaration_exported : declaration -> bool
  val declaration_shape_digest : declaration -> string
  val span_start_byte : span -> int
  val span_end_byte : span -> int
end

type configuration = {
  node : string;
  adapter_path : string;
  timeout_ms : int;
  max_request_bytes : int;
  max_response_bytes : int;
  max_stderr_bytes : int;
}

val default_configuration : configuration

val configuration_with :
  ?node:string ->
  ?adapter_path:string ->
  ?timeout_ms:int ->
  ?max_request_bytes:int ->
  ?max_response_bytes:int ->
  ?max_stderr_bytes:int ->
  configuration ->
  configuration

type unavailable_reason =
  | Adapter_missing of string
  | Node_missing of string
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
  typescript_version : string;
  minimum_node_version : string;
  request_limit_bytes : int;
  response_limit_bytes : int;
  capabilities : string list;
}

val handshake_typescript_version : handshake -> string
val handshake_minimum_node_version : handshake -> string
val handshake_capabilities : handshake -> string list

type 'a result = Available of 'a | Unavailable of unavailable_reason

type replace_target = {
  path : string;
  declaration_span : Protocol.span;
  expected_preimage : string;
  declaration_kind : string;
  declaration_shape_digest : string;
}

val make_replace_target :
  path:string ->
  declaration_span:Protocol.span ->
  expected_preimage:string ->
  declaration_kind:string ->
  declaration_shape_digest:string ->
  replace_target

type replace_outcome =
  | Replaced of {
      path : string;
      contents : string;
      parser_complete : bool;
      resolution_complete : bool;
      type_resolution_complete : bool;
      evidence : string list;
      confidence : string;
      fallback_used : bool;
    }
  | Replace_conflict of { code : string; message : string }

val replace_outcome_contents : replace_outcome -> string option
val replace_outcome_confidence : replace_outcome -> string option
val replace_outcome_fallback_used : replace_outcome -> bool option
val replace_outcome_conflict_code : replace_outcome -> string option
val handshake : configuration -> handshake result

val analyze_files :
  configuration ->
  snapshot_id:string ->
  root_files:string list ->
  files:Protocol.source_file list ->
  compiler_options:Protocol.compiler_options ->
  Protocol.analysis result

val replace_node_files :
  configuration ->
  snapshot_id:string ->
  root_files:string list ->
  files:Protocol.source_file list ->
  compiler_options:Protocol.compiler_options ->
  target:replace_target ->
  replacement:string ->
  replace_outcome result

val analyze_snapshot :
  configuration ->
  store:Paengi_store.repository ->
  snapshot:Paengi_snapshot.Snapshot.id ->
  compiler_options:Protocol.compiler_options ->
  Protocol.analysis result
