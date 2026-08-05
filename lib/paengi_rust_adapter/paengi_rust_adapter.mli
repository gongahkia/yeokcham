module Protocol : sig
  val version : int
  val maximum_request_bytes : int
  val maximum_response_bytes : int
  val maximum_source_files : int
  val maximum_source_bytes : int
  val maximum_item_records : int

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

  val make_source_file : path:string -> contents:string -> source_file
  val make_span : start_byte:int -> end_byte:int -> span
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
