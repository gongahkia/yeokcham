[@@@warning "-42"]

module Protocol = struct
  let version = 1
  let maximum_request_bytes = 4 * 1024 * 1024
  let maximum_response_bytes = 4 * 1024 * 1024
  let maximum_source_files = 4_096
  let maximum_source_bytes = 4 * 1024 * 1024
  let maximum_item_records = 4_096
  let maximum_module_facts = 4_096
  let maximum_module_depth = 256

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

  let make_source_file ~path ~contents = { path; contents }
  let make_span ~start_byte ~end_byte = { start_byte; end_byte }

  let make_item ~path ~item_kind ~item_span ~name_span ~syntactic_name : item =
    { path; item_kind; item_span; name_span; syntactic_name }

  let make_diagnostic ~path ~code ~span : diagnostic = { path; code; span }

  let make_module_fact ~root_file ~parent_source_path ~source_path ~module_path
      ~declaration_span ~module_kind ~status : module_fact =
    {
      root_file;
      parent_source_path;
      source_path;
      module_path;
      declaration_span;
      module_kind;
      status;
    }

  let make_item_path_fact ~root_file ~source_path ~module_path
      ~item_path_segments ~item_kind ~item_span ~name_span ~syntactic_name
      ~parser_complete ~status : item_path_fact =
    {
      root_file;
      source_path;
      module_path;
      item_path_segments;
      item_kind;
      item_span;
      name_span;
      syntactic_name;
      parser_complete;
      status;
    }

  let make_unreachable_source ~source_path ~status : unreachable_source =
    { source_path; status }

  let make_analysis ~snapshot_id ~adapter_version ~tree_sitter_version
      ~rust_grammar_version ~parser_complete ~items ~parser_diagnostics :
      analysis =
    {
      snapshot_id;
      adapter_version;
      tree_sitter_version;
      rust_grammar_version;
      parser_complete;
      items;
      parser_diagnostics;
    }

  let make_module_path_analysis ~snapshot_id ~adapter_version
      ~tree_sitter_version ~rust_grammar_version ~parser_complete
      ~module_paths_complete ~module_facts ~item_path_facts ~unreachable_sources
      : module_path_analysis =
    {
      snapshot_id;
      adapter_version;
      tree_sitter_version;
      rust_grammar_version;
      parser_complete;
      module_paths_complete;
      module_facts;
      item_path_facts;
      unreachable_sources;
    }

  let source_file_path (source_file : source_file) = source_file.path
  let source_file_contents (source_file : source_file) = source_file.contents
  let item_path (item : item) = item.path
  let item_kind (item : item) = item.item_kind
  let item_span (item : item) = item.item_span
  let item_name_span (item : item) = item.name_span
  let item_syntactic_name (item : item) = item.syntactic_name
  let diagnostic_path (diagnostic : diagnostic) = diagnostic.path
  let diagnostic_code (diagnostic : diagnostic) = diagnostic.code
  let diagnostic_span (diagnostic : diagnostic) = diagnostic.span
  let analysis_snapshot_id (analysis : analysis) = analysis.snapshot_id
  let analysis_adapter_version (analysis : analysis) = analysis.adapter_version

  let analysis_tree_sitter_version (analysis : analysis) =
    analysis.tree_sitter_version

  let analysis_rust_grammar_version (analysis : analysis) =
    analysis.rust_grammar_version

  let analysis_parser_complete (analysis : analysis) = analysis.parser_complete
  let analysis_items (analysis : analysis) = analysis.items

  let analysis_parser_diagnostics (analysis : analysis) =
    analysis.parser_diagnostics

  let module_fact_root_file (fact : module_fact) = fact.root_file

  let module_fact_parent_source_path (fact : module_fact) =
    fact.parent_source_path

  let module_fact_source_path (fact : module_fact) = fact.source_path
  let module_fact_module_path (fact : module_fact) = fact.module_path
  let module_fact_declaration_span (fact : module_fact) = fact.declaration_span
  let module_fact_kind (fact : module_fact) = fact.module_kind
  let module_fact_status (fact : module_fact) = fact.status
  let item_path_fact_root_file (fact : item_path_fact) = fact.root_file
  let item_path_fact_source_path (fact : item_path_fact) = fact.source_path
  let item_path_fact_module_path (fact : item_path_fact) = fact.module_path
  let item_path_fact_segments (fact : item_path_fact) = fact.item_path_segments
  let item_path_fact_kind (fact : item_path_fact) = fact.item_kind
  let item_path_fact_span (fact : item_path_fact) = fact.item_span
  let item_path_fact_name_span (fact : item_path_fact) = fact.name_span

  let item_path_fact_syntactic_name (fact : item_path_fact) =
    fact.syntactic_name

  let item_path_fact_parser_complete (fact : item_path_fact) =
    fact.parser_complete

  let item_path_fact_status (fact : item_path_fact) = fact.status
  let unreachable_source_path (source : unreachable_source) = source.source_path
  let unreachable_source_status (source : unreachable_source) = source.status

  let module_path_analysis_snapshot_id (analysis : module_path_analysis) =
    analysis.snapshot_id

  let module_path_analysis_parser_complete (analysis : module_path_analysis) =
    analysis.parser_complete

  let module_path_analysis_complete (analysis : module_path_analysis) =
    analysis.module_paths_complete

  let module_path_analysis_module_facts (analysis : module_path_analysis) =
    analysis.module_facts

  let module_path_analysis_item_path_facts (analysis : module_path_analysis) =
    analysis.item_path_facts

  let module_path_analysis_unreachable_sources (analysis : module_path_analysis)
      =
    analysis.unreachable_sources

  let span_start_byte (span : span) = span.start_byte
  let span_end_byte (span : span) = span.end_byte
end

type configuration = {
  adapter_path : string;
  timeout_ms : int;
  max_request_bytes : int;
  max_response_bytes : int;
  max_stderr_bytes : int;
}

let default_configuration =
  {
    adapter_path =
      "tools/paengi-rust-adapter/target/release/paengi-rust-adapter";
    timeout_ms = 5_000;
    max_request_bytes = Protocol.maximum_request_bytes;
    max_response_bytes = Protocol.maximum_response_bytes;
    max_stderr_bytes = 64 * 1024;
  }

let configuration_with ?adapter_path ?timeout_ms ?max_request_bytes
    ?max_response_bytes ?max_stderr_bytes configuration =
  {
    adapter_path = Option.value ~default:configuration.adapter_path adapter_path;
    timeout_ms = Option.value ~default:configuration.timeout_ms timeout_ms;
    max_request_bytes =
      Option.value ~default:configuration.max_request_bytes max_request_bytes;
    max_response_bytes =
      Option.value ~default:configuration.max_response_bytes max_response_bytes;
    max_stderr_bytes =
      Option.value ~default:configuration.max_stderr_bytes max_stderr_bytes;
  }

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

let unavailable_reason_to_string = function
  | Adapter_missing path -> "adapter is missing or not executable: " ^ path
  | Adapter_request_too_large { limit } ->
      Printf.sprintf "adapter request exceeded %d bytes" limit
  | Adapter_timeout { timeout_ms } ->
      Printf.sprintf "adapter timed out after %dms" timeout_ms
  | Adapter_output_too_large { limit } ->
      Printf.sprintf "adapter output exceeded %d bytes" limit
  | Adapter_crashed { exit_code; signal; stderr } ->
      Printf.sprintf "adapter crashed (exit=%s signal=%s stderr=%S)"
        (Option.fold ~none:"none" ~some:string_of_int exit_code)
        (Option.fold ~none:"none" ~some:string_of_int signal)
        stderr
  | Malformed_adapter_response message ->
      "malformed adapter response: " ^ message
  | Unsupported_protocol message -> "unsupported adapter protocol: " ^ message
  | Adapter_error { code; message } ->
      Printf.sprintf "adapter error %s: %s" code message
  | Snapshot_error error -> Paengi_snapshot.error_to_string error

type handshake = {
  adapter_version : string;
  tree_sitter_version : string;
  rust_grammar_version : string;
  request_limit_bytes : int;
  response_limit_bytes : int;
  capabilities : string list;
}

let handshake_adapter_version handshake = handshake.adapter_version
let handshake_tree_sitter_version handshake = handshake.tree_sitter_version
let handshake_rust_grammar_version handshake = handshake.rust_grammar_version
let handshake_capabilities handshake = handshake.capabilities

type 'a result = Available of 'a | Unavailable of unavailable_reason

let ( let* ) = Result.bind

module Json = struct
  type t =
    | Null
    | Bool of bool
    | Number of string
    | String of string
    | Array of t list
    | Object of (string * t) list

  let whitespace = function ' ' | '\n' | '\r' | '\t' -> true | _ -> false

  let parse source =
    let length = String.length source in
    let rec skip index =
      if index < length && whitespace source.[index] then skip (index + 1)
      else index
    in
    let rec value index =
      let index = skip index in
      if index >= length then Error "unexpected end of JSON"
      else
        match source.[index] with
        | 'n' -> literal index "null" Null
        | 't' -> literal index "true" (Bool true)
        | 'f' -> literal index "false" (Bool false)
        | '"' -> string_value (index + 1)
        | '[' -> array (index + 1) []
        | '{' -> object_ (index + 1) []
        | '-' | '0' .. '9' -> number index
        | character ->
            Error (Printf.sprintf "unexpected JSON character %C" character)
    and literal index token parsed =
      let token_length = String.length token in
      if
        index + token_length <= length
        && String.sub source index token_length = token
      then Ok (parsed, index + token_length)
      else Error ("invalid JSON literal " ^ token)
    and string_value index =
      let buffer = Buffer.create 32 in
      let rec loop index =
        if index >= length then Error "unterminated JSON string"
        else
          match source.[index] with
          | '"' -> Ok (String (Buffer.contents buffer), index + 1)
          | '\\' -> escape (index + 1)
          | character when Char.code character < 0x20 ->
              Error "control byte in JSON string"
          | character ->
              Buffer.add_char buffer character;
              loop (index + 1)
      and escape index =
        if index >= length then Error "unterminated JSON escape"
        else
          match source.[index] with
          | '"' ->
              Buffer.add_char buffer '"';
              loop (index + 1)
          | '\\' ->
              Buffer.add_char buffer '\\';
              loop (index + 1)
          | '/' ->
              Buffer.add_char buffer '/';
              loop (index + 1)
          | 'b' ->
              Buffer.add_char buffer '\b';
              loop (index + 1)
          | 'f' ->
              Buffer.add_char buffer '\012';
              loop (index + 1)
          | 'n' ->
              Buffer.add_char buffer '\n';
              loop (index + 1)
          | 'r' ->
              Buffer.add_char buffer '\r';
              loop (index + 1)
          | 't' ->
              Buffer.add_char buffer '\t';
              loop (index + 1)
          | 'u' -> unicode_escape (index + 1)
          | character ->
              Error (Printf.sprintf "invalid JSON escape %C" character)
      and unicode_escape index =
        if index + 4 > length then Error "short JSON unicode escape"
        else
          let hex = String.sub source index 4 in
          match int_of_string_opt ("0x" ^ hex) with
          | None -> Error "invalid JSON unicode escape"
          | Some codepoint ->
              if codepoint >= 0xd800 && codepoint <= 0xdfff then
                Error "JSON surrogate escapes are unsupported"
              else (
                Buffer.add_utf_8_uchar buffer (Uchar.of_int codepoint);
                loop (index + 4))
      in
      loop index
    and array index reversed =
      let index = skip index in
      if index < length && Char.equal source.[index] ']' then
        Ok (Array (List.rev reversed), index + 1)
      else
        let* item, next = value index in
        let next = skip next in
        if next >= length then Error "unterminated JSON array"
        else if Char.equal source.[next] ']' then
          Ok (Array (List.rev (item :: reversed)), next + 1)
        else if Char.equal source.[next] ',' then
          array (next + 1) (item :: reversed)
        else Error "invalid JSON array separator"
    and object_ index reversed =
      let index = skip index in
      if index < length && Char.equal source.[index] '}' then
        Ok (Object (List.rev reversed), index + 1)
      else if index >= length || not (Char.equal source.[index] '"') then
        Error "JSON object key is not a string"
      else
        let* key_value, after_key = string_value (index + 1) in
        match key_value with
        | String key ->
            let after_key = skip after_key in
            if after_key >= length || not (Char.equal source.[after_key] ':')
            then Error "missing JSON object colon"
            else
              let* item, next = value (after_key + 1) in
              let next = skip next in
              if next >= length then Error "unterminated JSON object"
              else if Char.equal source.[next] '}' then
                Ok (Object (List.rev ((key, item) :: reversed)), next + 1)
              else if Char.equal source.[next] ',' then
                object_ (next + 1) ((key, item) :: reversed)
              else Error "invalid JSON object separator"
        | Null | Bool _ | Number _ | Array _ | Object _ ->
            Error "JSON object key is not a string"
    and number index =
      let rec end_ position =
        if position < length then
          match source.[position] with
          | '-' | '+' | '.' | 'e' | 'E' | '0' .. '9' -> end_ (position + 1)
          | _ -> position
        else position
      in
      let next = end_ index in
      let token = String.sub source index (next - index) in
      if Option.is_none (float_of_string_opt token) then
        Error "invalid JSON number"
      else Ok (Number token, next)
    in
    let* parsed, index = value 0 in
    if skip index = length then Ok parsed else Error "trailing JSON bytes"

  let quote value =
    let buffer = Buffer.create (String.length value + 8) in
    Buffer.add_char buffer '"';
    String.iter
      (fun character ->
        match character with
        | '"' -> Buffer.add_string buffer "\\\""
        | '\\' -> Buffer.add_string buffer "\\\\"
        | '\b' -> Buffer.add_string buffer "\\b"
        | '\012' -> Buffer.add_string buffer "\\f"
        | '\n' -> Buffer.add_string buffer "\\n"
        | '\r' -> Buffer.add_string buffer "\\r"
        | '\t' -> Buffer.add_string buffer "\\t"
        | character when Char.code character < 0x20 ->
            Buffer.add_string buffer
              (Printf.sprintf "\\u%04x" (Char.code character))
        | character -> Buffer.add_char buffer character)
      value;
    Buffer.add_char buffer '"';
    Buffer.contents buffer

  let object_field name = function
    | Object fields -> List.assoc_opt name fields
    | Null | Bool _ | Number _ | String _ | Array _ -> None

  let string = function
    | String value -> Some value
    | Null | Bool _ | Number _ | Array _ | Object _ -> None

  let boolean = function
    | Bool value -> Some value
    | Null | Number _ | String _ | Array _ | Object _ -> None

  let integer = function
    | Number value -> int_of_string_opt value
    | Null | Bool _ | String _ | Array _ | Object _ -> None

  let array = function
    | Array values -> Some values
    | Null | Bool _ | Number _ | String _ | Object _ -> None
end

let safe_relative_rust_path path =
  String.length path > 0
  && String.length path <= 4 * 1024
  && String.ends_with ~suffix:".rs" path
  && (not (String.contains path '\000'))
  && (not (String.contains path '\\'))
  && String.split_on_char '/' path
     |> List.for_all (fun component ->
         String.length component > 0
         && not (String.equal component "." || String.equal component ".."))

let valid_snapshot_id snapshot_id =
  String.length snapshot_id = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       snapshot_id

let hex contents =
  let table = "0123456789abcdef" in
  let output = Bytes.create (2 * String.length contents) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set output (2 * index) table.[value lsr 4];
      Bytes.set output ((2 * index) + 1) table.[value land 0xf])
    contents;
  Bytes.unsafe_to_string output

let request_json ~operation fields =
  let fields =
    ("protocolVersion", string_of_int Protocol.version)
    :: ("operation", Json.quote operation)
    :: fields
  in
  "{"
  ^ String.concat ","
      (List.map (fun (name, value) -> Json.quote name ^ ":" ^ value) fields)
  ^ "}"

let request_for_analysis ~snapshot_id files =
  let files =
    files
    |> List.map (fun (file : Protocol.source_file) ->
        "{"
        ^ String.concat ","
            [
              Json.quote "path" ^ ":"
              ^ Json.quote (Protocol.source_file_path file);
              Json.quote "contentsHex" ^ ":"
              ^ Json.quote (hex (Protocol.source_file_contents file));
            ]
        ^ "}")
    |> String.concat ","
  in
  request_json ~operation:"analyze"
    [ ("snapshotId", Json.quote snapshot_id); ("files", "[" ^ files ^ "]") ]

let request_for_module_paths ~snapshot_id ~root_files files =
  let roots =
    root_files |> List.map Json.quote |> String.concat "," |> fun roots ->
    "[" ^ roots ^ "]"
  in
  let files =
    files
    |> List.map (fun (file : Protocol.source_file) ->
        "{"
        ^ String.concat ","
            [
              Json.quote "path" ^ ":"
              ^ Json.quote (Protocol.source_file_path file);
              Json.quote "contentsHex" ^ ":"
              ^ Json.quote (hex (Protocol.source_file_contents file));
            ]
        ^ "}")
    |> String.concat ","
  in
  request_json ~operation:"resolve-module-paths"
    [
      ("snapshotId", Json.quote snapshot_id);
      ("rootFiles", roots);
      ("files", "[" ^ files ^ "]");
    ]

let executable path =
  try
    Unix.access path [ Unix.X_OK ];
    true
  with Unix.Unix_error _ -> false

type process_result = {
  exit_code : int option;
  signal : int option;
  timed_out : bool;
  output_too_large : bool;
  stdout : string;
  stderr : string;
}

let kill_adapter pid signal =
  try Unix.kill pid signal with Unix.Unix_error _ -> ()

let request_descriptor request =
  try
    let path = Filename.temp_file "paengi-rust-request-" ".json" in
    Out_channel.with_open_bin path (fun channel ->
        Out_channel.output_string channel request);
    Ok (path, Unix.openfile path [ Unix.O_RDONLY ] 0o600)
  with Sys_error message | Unix.Unix_error (_, _, message) ->
    Error (Adapter_error { code = "request-io"; message })

let run_process_unsafe configuration request =
  match request_descriptor request with
  | Error reason -> Error reason
  | Ok (request_path, stdin_read) ->
      Fun.protect
        ~finally:(fun () ->
          (try Unix.close stdin_read with Unix.Unix_error _ -> ());
          try Unix.unlink request_path with Unix.Unix_error _ -> ())
        (fun () ->
          let stdout_read, stdout_write = Unix.pipe () in
          let stderr_read, stderr_write = Unix.pipe () in
          let child =
            try
              Ok
                (Unix.create_process_env configuration.adapter_path
                   [| configuration.adapter_path |]
                   [| "PATH=/usr/bin:/bin" |] stdin_read stdout_write
                   stderr_write)
            with Unix.Unix_error (_, _, message) ->
              Error (Adapter_error { code = "start-failed"; message })
          in
          Unix.close stdout_write;
          Unix.close stderr_write;
          match child with
          | Error reason ->
              Unix.close stdout_read;
              Unix.close stderr_read;
              Error reason
          | Ok child ->
              List.iter Unix.set_nonblock [ stdout_read; stderr_read ];
              let stdout_open = ref true in
              let stderr_open = ref true in
              let stdout = Buffer.create 1024 in
              let stderr = Buffer.create 1024 in
              let process_status = ref None in
              let timed_out = ref false in
              let output_too_large = ref false in
              let sent_kill = ref false in
              let terminated_at = ref None in
              let deadline =
                Unix.gettimeofday ()
                +. (float_of_int configuration.timeout_ms /. 1000.)
              in
              let close descriptor open_ =
                if !open_ then (
                  Unix.close descriptor;
                  open_ := false)
              in
              let read descriptor buffer limit open_ =
                let bytes = Bytes.create 8192 in
                let rec loop () =
                  try
                    match Unix.read descriptor bytes 0 (Bytes.length bytes) with
                    | 0 -> close descriptor open_
                    | length ->
                        if Buffer.length buffer + length > limit then (
                          output_too_large := true;
                          close descriptor open_)
                        else (
                          Buffer.add_subbytes buffer bytes 0 length;
                          loop ())
                  with
                  | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                      ()
                  | Unix.Unix_error _ -> close descriptor open_
                in
                loop ()
              in
              while
                Option.is_none !process_status || !stdout_open || !stderr_open
              do
                (if Option.is_none !process_status then
                   match Unix.waitpid [ Unix.WNOHANG ] child with
                   | 0, _ -> ()
                   | _, status -> process_status := Some status);
                let now = Unix.gettimeofday () in
                if
                  Option.is_none !process_status
                  && (((not !timed_out) && now >= deadline) || !output_too_large)
                then (
                  timed_out := !timed_out || now >= deadline;
                  terminated_at := Some now;
                  kill_adapter child Sys.sigterm);
                if
                  Option.is_some !terminated_at
                  && (not !sent_kill)
                  && Option.is_none !process_status
                  && now -. Option.get !terminated_at >= 0.1
                then (
                  sent_kill := true;
                  kill_adapter child Sys.sigkill);
                if !stdout_open then
                  read stdout_read stdout configuration.max_response_bytes
                    stdout_open;
                if !stderr_open then
                  read stderr_read stderr configuration.max_stderr_bytes
                    stderr_open;
                if Option.is_none !process_status then
                  ignore (Unix.select [] [] [] 0.01)
              done;
              let exit_code, signal =
                match !process_status with
                | Some (Unix.WEXITED code) -> (Some code, None)
                | Some (Unix.WSIGNALED signal | Unix.WSTOPPED signal) ->
                    (None, Some signal)
                | None -> (None, None)
              in
              Ok
                {
                  exit_code;
                  signal;
                  timed_out = !timed_out;
                  output_too_large = !output_too_large;
                  stdout = Buffer.contents stdout;
                  stderr = Buffer.contents stderr;
                })

let run_process configuration request =
  try run_process_unsafe configuration request
  with Sys_error message | Unix.Unix_error (_, _, message) ->
    Error (Adapter_error { code = "process-io"; message })

let object_field name value =
  match Json.object_field name value with
  | Some field -> Ok field
  | None -> Error ("missing response field " ^ name)

let string_field name value =
  let* field = object_field name value in
  match Json.string field with
  | Some string -> Ok string
  | None -> Error ("response field " ^ name ^ " is not a string")

let optional_string_field name value =
  match Json.object_field name value with
  | None | Some Json.Null -> Ok None
  | Some (Json.String string) -> Ok (Some string)
  | Some (Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _) ->
      Error ("response field " ^ name ^ " is not a string")

let bool_field name value =
  let* field = object_field name value in
  match Json.boolean field with
  | Some boolean -> Ok boolean
  | None -> Error ("response field " ^ name ^ " is not a bool")

let int_field name value =
  let* field = object_field name value in
  match Json.integer field with
  | Some integer -> Ok integer
  | None -> Error ("response field " ^ name ^ " is not an integer")

let list_field name decode value =
  let* field = object_field name value in
  match Json.array field with
  | None -> Error ("response field " ^ name ^ " is not an array")
  | Some values ->
      List.fold_right
        (fun value accumulated ->
          let* item = decode value in
          let* items = accumulated in
          Ok (item :: items))
        values (Ok [])

let decode_span start_name end_name value =
  let* start_byte = int_field start_name value in
  let* end_byte = int_field end_name value in
  if start_byte < 0 || end_byte < start_byte then Error "invalid byte span"
  else Ok (Protocol.make_span ~start_byte ~end_byte)

let decode_item value =
  let* path = string_field "path" value in
  let* kind = string_field "itemKind" value in
  let* item_span = decode_span "startByte" "endByte" value in
  let* syntactic_name = optional_string_field "syntacticName" value in
  let name_start = Json.object_field "nameStartByte" value in
  let name_end = Json.object_field "nameEndByte" value in
  let name_span =
    match (name_start, name_end) with
    | Some Json.Null, Some Json.Null -> Ok None
    | ( Some
          ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
          | Json.Object _ ),
        Some
          ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
          | Json.Object _ ) ) ->
        decode_span "nameStartByte" "nameEndByte" value
        |> Result.map Option.some
    | None, None
    | None, Some _
    | Some _, None
    | ( Some Json.Null,
        Some
          ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
          | Json.Object _ ) )
    | ( Some
          ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
          | Json.Object _ ),
        Some Json.Null ) ->
        Error "incomplete item name span"
  in
  let* name_span = name_span in
  Ok
    (Protocol.make_item ~path ~item_kind:kind ~item_span ~name_span
       ~syntactic_name)

let decode_diagnostic value =
  let* path = string_field "path" value in
  let* code = string_field "code" value in
  let* span = decode_span "startByte" "endByte" value in
  Ok (Protocol.make_diagnostic ~path ~code ~span)

let decode_analysis value =
  let* snapshot_id = string_field "snapshotId" value in
  let* adapter_version = string_field "adapterVersion" value in
  let* tree_sitter_version = string_field "treeSitterVersion" value in
  let* rust_grammar_version = string_field "rustGrammarVersion" value in
  let* parser_complete = bool_field "parserComplete" value in
  let* items = list_field "items" decode_item value in
  let* parser_diagnostics =
    list_field "parserDiagnostics" decode_diagnostic value
  in
  Ok
    (Protocol.make_analysis ~snapshot_id ~adapter_version ~tree_sitter_version
       ~rust_grammar_version ~parser_complete ~items ~parser_diagnostics)

let nullable_string_field name value =
  let* field = object_field name value in
  match field with
  | Json.Null -> Ok None
  | Json.String string -> Ok (Some string)
  | Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _ ->
      Error ("response field " ^ name ^ " is not a nullable string")

let string_list_field name value =
  list_field name
    (fun item ->
      match Json.string item with
      | Some string -> Ok string
      | None -> Error ("response field " ^ name ^ " contains a non-string"))
    value

let nullable_string_list_field name value =
  let* field = object_field name value in
  match field with
  | Json.Null -> Ok None
  | Json.Array values ->
      List.fold_right
        (fun value accumulated ->
          let* string =
            match Json.string value with
            | Some string -> Ok string
            | None -> Error ("response field " ^ name ^ " contains a non-string")
          in
          let* values = accumulated in
          Ok (string :: values))
        values (Ok [])
      |> Result.map Option.some
  | Json.Bool _ | Json.Number _ | Json.String _ | Json.Object _ ->
      Error ("response field " ^ name ^ " is not a nullable array")

let nullable_span_field start_name end_name value =
  let* start_field = object_field start_name value in
  let* end_field = object_field end_name value in
  match (start_field, end_field) with
  | Json.Null, Json.Null -> Ok None
  | ( ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
      | Json.Object _ ),
      ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
      | Json.Object _ ) ) ->
      decode_span start_name end_name value |> Result.map Option.some
  | ( Json.Null,
      ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
      | Json.Object _ ) )
  | ( ( Json.Bool _ | Json.Number _ | Json.String _ | Json.Array _
      | Json.Object _ ),
      Json.Null ) ->
      Error ("incomplete nullable span " ^ start_name)

let decode_module_fact value =
  let* root_file = string_field "rootFile" value in
  let* parent_source_path = nullable_string_field "parentSourcePath" value in
  let* source_path = nullable_string_field "sourcePath" value in
  let* module_path = string_list_field "modulePath" value in
  let* declaration_span =
    decode_span "declarationStartByte" "declarationEndByte" value
  in
  let* module_kind = string_field "moduleKind" value in
  let* status = string_field "status" value in
  Ok
    (Protocol.make_module_fact ~root_file ~parent_source_path ~source_path
       ~module_path ~declaration_span ~module_kind ~status)

let decode_item_path_fact value =
  let* root_file = string_field "rootFile" value in
  let* source_path = string_field "sourcePath" value in
  let* module_path = string_list_field "modulePath" value in
  let* item_path_segments =
    nullable_string_list_field "itemPathSegments" value
  in
  let* item_kind = string_field "itemKind" value in
  let* item_span = decode_span "startByte" "endByte" value in
  let* name_span = nullable_span_field "nameStartByte" "nameEndByte" value in
  let* syntactic_name = nullable_string_field "syntacticName" value in
  let* parser_complete = bool_field "parserComplete" value in
  let* status = string_field "status" value in
  Ok
    (Protocol.make_item_path_fact ~root_file ~source_path ~module_path
       ~item_path_segments ~item_kind ~item_span ~name_span ~syntactic_name
       ~parser_complete ~status)

let decode_unreachable_source value =
  let* source_path = string_field "sourcePath" value in
  let* status = string_field "status" value in
  Ok (Protocol.make_unreachable_source ~source_path ~status)

let decode_module_path_analysis value =
  let* snapshot_id = string_field "snapshotId" value in
  let* adapter_version = string_field "adapterVersion" value in
  let* tree_sitter_version = string_field "treeSitterVersion" value in
  let* rust_grammar_version = string_field "rustGrammarVersion" value in
  let* parser_complete = bool_field "parserComplete" value in
  let* module_paths_complete = bool_field "modulePathsComplete" value in
  let* module_facts = list_field "moduleFacts" decode_module_fact value in
  let* item_path_facts =
    list_field "itemPathFacts" decode_item_path_fact value
  in
  let* unreachable_sources =
    list_field "unreachableSources" decode_unreachable_source value
  in
  Ok
    (Protocol.make_module_path_analysis ~snapshot_id ~adapter_version
       ~tree_sitter_version ~rust_grammar_version ~parser_complete
       ~module_paths_complete ~module_facts ~item_path_facts
       ~unreachable_sources)

let decode_handshake value =
  let* adapter_version = string_field "adapterVersion" value in
  let* tree_sitter_version = string_field "treeSitterVersion" value in
  let* rust_grammar_version = string_field "rustGrammarVersion" value in
  let* request_limit_bytes = int_field "requestLimitBytes" value in
  let* response_limit_bytes = int_field "responseLimitBytes" value in
  let* capabilities =
    list_field "capabilities"
      (fun item ->
        match Json.string item with
        | Some capability -> Ok capability
        | None -> Error "capability is not a string")
      value
  in
  Ok
    {
      adapter_version;
      tree_sitter_version;
      rust_grammar_version;
      request_limit_bytes;
      response_limit_bytes;
      capabilities;
    }

let decode_response decode output =
  let* response = Json.parse output in
  let* response_version = int_field "protocolVersion" response in
  if response_version <> Protocol.version then
    Error ("unsupported response protocol " ^ string_of_int response_version)
  else
    let* status = string_field "status" response in
    match status with
    | "ok" ->
        let* result = object_field "result" response in
        decode result
    | "error" ->
        let* error = object_field "error" response in
        let* code = string_field "code" error in
        let* message = string_field "message" error in
        Error (code ^ "\000" ^ message)
    | _ -> Error "unknown adapter response status"

let run configuration request decode =
  if not (executable configuration.adapter_path) then
    Unavailable (Adapter_missing configuration.adapter_path)
  else if String.length request > configuration.max_request_bytes then
    Unavailable
      (Adapter_request_too_large { limit = configuration.max_request_bytes })
  else
    match run_process configuration request with
    | Error reason -> Unavailable reason
    | Ok process -> (
        if process.timed_out then
          Unavailable
            (Adapter_timeout { timeout_ms = configuration.timeout_ms })
        else if process.output_too_large then
          Unavailable
            (Adapter_output_too_large
               { limit = configuration.max_response_bytes })
        else
          match (process.exit_code, process.signal) with
          | Some 0, None -> (
              match decode process.stdout with
              | Ok value -> Available value
              | Error message -> (
                  match String.index_opt message '\000' with
                  | Some index ->
                      let code = String.sub message 0 index in
                      let body =
                        String.sub message (index + 1)
                          (String.length message - index - 1)
                      in
                      if String.equal code "unsupported-protocol" then
                        Unavailable (Unsupported_protocol body)
                      else Unavailable (Adapter_error { code; message = body })
                  | None -> Unavailable (Malformed_adapter_response message)))
          | exit_code, signal ->
              Unavailable
                (Adapter_crashed { exit_code; signal; stderr = process.stderr })
        )

let valid_span source span =
  Protocol.span_start_byte span >= 0
  && Protocol.span_end_byte span >= Protocol.span_start_byte span
  && Protocol.span_end_byte span <= String.length source

let source_for_path (files : Protocol.source_file list) path =
  files
  |> List.find_opt (fun file ->
      String.equal (Protocol.source_file_path file) path)
  |> Option.map Protocol.source_file_contents

let compare_item (left : Protocol.item) (right : Protocol.item) =
  let compare =
    String.compare (Protocol.item_path left) (Protocol.item_path right)
  in
  if compare <> 0 then compare
  else
    let compare =
      Int.compare
        (Protocol.span_start_byte (Protocol.item_span left))
        (Protocol.span_start_byte (Protocol.item_span right))
    in
    if compare <> 0 then compare
    else
      let compare =
        Int.compare
          (Protocol.span_end_byte (Protocol.item_span left))
          (Protocol.span_end_byte (Protocol.item_span right))
      in
      if compare <> 0 then compare
      else String.compare (Protocol.item_kind left) (Protocol.item_kind right)

let compare_diagnostic (left : Protocol.diagnostic)
    (right : Protocol.diagnostic) =
  let compare =
    String.compare
      (Protocol.diagnostic_path left)
      (Protocol.diagnostic_path right)
  in
  if compare <> 0 then compare
  else
    let compare =
      Int.compare
        (Protocol.span_start_byte (Protocol.diagnostic_span left))
        (Protocol.span_start_byte (Protocol.diagnostic_span right))
    in
    if compare <> 0 then compare
    else
      let compare =
        Int.compare
          (Protocol.span_end_byte (Protocol.diagnostic_span left))
          (Protocol.span_end_byte (Protocol.diagnostic_span right))
      in
      if compare <> 0 then compare
      else
        String.compare
          (Protocol.diagnostic_code left)
          (Protocol.diagnostic_code right)

let strictly_sorted compare values =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) -> compare left right < 0 && loop rest
  in
  loop values

let validate_analysis ~snapshot_id ~files (analysis : Protocol.analysis) =
  if not (String.equal snapshot_id (Protocol.analysis_snapshot_id analysis))
  then Error "analysis snapshot ID differs from request"
  else if
    List.length (Protocol.analysis_items analysis)
    > Protocol.maximum_item_records
  then Error "analysis exceeds item limit"
  else if not (strictly_sorted compare_item (Protocol.analysis_items analysis))
  then Error "analysis items are not canonically ordered"
  else if
    not
      (strictly_sorted compare_diagnostic
         (Protocol.analysis_parser_diagnostics analysis))
  then Error "analysis diagnostics are not canonically ordered"
  else
    let valid_item (item : Protocol.item) =
      let path = Protocol.item_path item in
      let item_span = Protocol.item_span item in
      match source_for_path files path with
      | None -> false
      | Some source -> (
          safe_relative_rust_path path
          && valid_span source item_span
          &&
          match
            (Protocol.item_name_span item, Protocol.item_syntactic_name item)
          with
          | None, None -> true
          | Some span, Some name ->
              valid_span source span
              && Protocol.span_start_byte item_span
                 <= Protocol.span_start_byte span
              && Protocol.span_end_byte span <= Protocol.span_end_byte item_span
              && String.equal name
                   (String.sub source
                      (Protocol.span_start_byte span)
                      (Protocol.span_end_byte span
                      - Protocol.span_start_byte span))
          | None, Some _ | Some _, None -> false)
    in
    let valid_diagnostic (diagnostic : Protocol.diagnostic) =
      let path = Protocol.diagnostic_path diagnostic in
      match source_for_path files path with
      | None -> false
      | Some source ->
          safe_relative_rust_path path
          && valid_span source (Protocol.diagnostic_span diagnostic)
    in
    if
      List.for_all valid_item (Protocol.analysis_items analysis)
      && List.for_all valid_diagnostic
           (Protocol.analysis_parser_diagnostics analysis)
    then Ok analysis
    else Error "analysis contains an invalid path, span, or syntactic name"

let valid_path_segment segment =
  String.length segment > 0
  && String.length segment <= 4 * 1024
  && (not (String.contains segment '\000'))
  && (not (String.contains segment '/'))
  && not (String.contains segment '\\')

let valid_path_segments segments =
  List.length segments <= Protocol.maximum_module_depth
  && List.for_all valid_path_segment segments

let valid_module_fact_path_segments status segments =
  (List.length segments <= Protocol.maximum_module_depth
  || String.equal status "module-depth-limit"
     && List.length segments = Protocol.maximum_module_depth + 1)
  && List.for_all valid_path_segment segments

let compare_string_lists left right =
  let rec compare = function
    | [], [] -> 0
    | [], _ -> -1
    | _, [] -> 1
    | left :: left_rest, right :: right_rest ->
        let result = String.compare left right in
        if result = 0 then compare (left_rest, right_rest) else result
  in
  compare (left, right)

let compare_optional_string left right =
  match (left, right) with
  | None, None -> 0
  | None, Some _ -> -1
  | Some _, None -> 1
  | Some left, Some right -> String.compare left right

let compare_module_fact (left : Protocol.module_fact)
    (right : Protocol.module_fact) =
  let compare =
    String.compare
      (Protocol.module_fact_root_file left)
      (Protocol.module_fact_root_file right)
  in
  if compare <> 0 then compare
  else
    let compare =
      compare_string_lists
        (Protocol.module_fact_module_path left)
        (Protocol.module_fact_module_path right)
    in
    if compare <> 0 then compare
    else
      let compare =
        compare_optional_string
          (Protocol.module_fact_source_path left)
          (Protocol.module_fact_source_path right)
      in
      if compare <> 0 then compare
      else
        let compare =
          Int.compare
            (Protocol.span_start_byte
               (Protocol.module_fact_declaration_span left))
            (Protocol.span_start_byte
               (Protocol.module_fact_declaration_span right))
        in
        if compare <> 0 then compare
        else
          let compare =
            Int.compare
              (Protocol.span_end_byte
                 (Protocol.module_fact_declaration_span left))
              (Protocol.span_end_byte
                 (Protocol.module_fact_declaration_span right))
          in
          if compare <> 0 then compare
          else
            let compare =
              String.compare
                (Protocol.module_fact_kind left)
                (Protocol.module_fact_kind right)
            in
            if compare <> 0 then compare
            else
              String.compare
                (Protocol.module_fact_status left)
                (Protocol.module_fact_status right)

let compare_item_path_fact (left : Protocol.item_path_fact)
    (right : Protocol.item_path_fact) =
  let compare =
    String.compare
      (Protocol.item_path_fact_root_file left)
      (Protocol.item_path_fact_root_file right)
  in
  if compare <> 0 then compare
  else
    let compare =
      compare_string_lists
        (Protocol.item_path_fact_module_path left)
        (Protocol.item_path_fact_module_path right)
    in
    if compare <> 0 then compare
    else
      let compare =
        String.compare
          (Protocol.item_path_fact_source_path left)
          (Protocol.item_path_fact_source_path right)
      in
      if compare <> 0 then compare
      else
        let compare =
          Int.compare
            (Protocol.span_start_byte (Protocol.item_path_fact_span left))
            (Protocol.span_start_byte (Protocol.item_path_fact_span right))
        in
        if compare <> 0 then compare
        else
          let compare =
            Int.compare
              (Protocol.span_end_byte (Protocol.item_path_fact_span left))
              (Protocol.span_end_byte (Protocol.item_path_fact_span right))
          in
          if compare <> 0 then compare
          else
            let compare =
              String.compare
                (Protocol.item_path_fact_kind left)
                (Protocol.item_path_fact_kind right)
            in
            if compare <> 0 then compare
            else
              String.compare
                (Protocol.item_path_fact_status left)
                (Protocol.item_path_fact_status right)

let module_status status =
  List.mem status
    [
      "resolved";
      "parser-incomplete";
      "duplicate-module";
      "module-depth-limit";
      "conditional-module";
      "unsupported-module-attribute";
      "missing-module";
      "ambiguous-module";
      "module-cycle";
    ]

let item_status status =
  module_status status
  || List.mem status
       [
         "macro-item-deferred";
         "unnamed-item";
         "conditional-item";
         "unsupported-item-attribute";
       ]

let valid_name source item_span name_span syntactic_name =
  match (name_span, syntactic_name) with
  | None, None -> true
  | Some span, Some name ->
      valid_span source span
      && Protocol.span_start_byte item_span <= Protocol.span_start_byte span
      && Protocol.span_end_byte span <= Protocol.span_end_byte item_span
      && String.equal name
           (String.sub source
              (Protocol.span_start_byte span)
              (Protocol.span_end_byte span - Protocol.span_start_byte span))
  | None, Some _ | Some _, None -> false

let validate_module_path_analysis ~snapshot_id ~root_files ~files
    (analysis : Protocol.module_path_analysis) =
  let root_member path = List.mem path root_files in
  let file_member path =
    safe_relative_rust_path path && Option.is_some (source_for_path files path)
  in
  let valid_source_path path =
    match source_for_path files path with
    | None -> false
    | Some _ -> safe_relative_rust_path path
  in
  let valid_module_fact (fact : Protocol.module_fact) =
    let declaration_source =
      Option.value
        ~default:(Protocol.module_fact_root_file fact)
        (Protocol.module_fact_parent_source_path fact)
    in
    let source_path_valid =
      Option.fold ~none:true ~some:valid_source_path
        (Protocol.module_fact_source_path fact)
    in
    let shape_valid =
      match
        ( Protocol.module_fact_kind fact,
          Protocol.module_fact_parent_source_path fact,
          Protocol.module_fact_source_path fact,
          Protocol.module_fact_status fact,
          Protocol.module_fact_module_path fact )
      with
      | "root", None, Some source_path, ("resolved" | "parser-incomplete"), []
        ->
          String.equal source_path (Protocol.module_fact_root_file fact)
      | "inline", Some parent_path, Some source_path, "resolved", _ :: _ ->
          String.equal parent_path source_path
      | "inline", Some _, None, status, _ :: _ ->
          not (String.equal status "resolved")
      | "external", Some _, Some _, ("resolved" | "parser-incomplete"), _ :: _
        ->
          true
      | "external", Some _, None, status, _ :: _ ->
          not
            (String.equal status "resolved"
            || String.equal status "parser-incomplete")
      | _ -> false
    in
    match source_for_path files declaration_source with
    | None -> false
    | Some source ->
        root_member (Protocol.module_fact_root_file fact)
        && valid_source_path declaration_source
        && Option.fold ~none:true ~some:valid_source_path
             (Protocol.module_fact_parent_source_path fact)
        && source_path_valid
        && valid_module_fact_path_segments
             (Protocol.module_fact_status fact)
             (Protocol.module_fact_module_path fact)
        && valid_span source (Protocol.module_fact_declaration_span fact)
        && List.mem
             (Protocol.module_fact_kind fact)
             [ "root"; "inline"; "external" ]
        && module_status (Protocol.module_fact_status fact)
        && shape_valid
  in
  let valid_item_fact (fact : Protocol.item_path_fact) =
    match source_for_path files (Protocol.item_path_fact_source_path fact) with
    | None -> false
    | Some source ->
        let segments = Protocol.item_path_fact_segments fact in
        root_member (Protocol.item_path_fact_root_file fact)
        && valid_source_path (Protocol.item_path_fact_source_path fact)
        && valid_path_segments (Protocol.item_path_fact_module_path fact)
        && Option.fold ~none:true ~some:valid_path_segments segments
        && valid_span source (Protocol.item_path_fact_span fact)
        && valid_name source
             (Protocol.item_path_fact_span fact)
             (Protocol.item_path_fact_name_span fact)
             (Protocol.item_path_fact_syntactic_name fact)
        && item_status (Protocol.item_path_fact_status fact)
        && (Protocol.item_path_fact_parser_complete fact
           || String.equal
                (Protocol.item_path_fact_status fact)
                "parser-incomplete")
        &&
        if String.equal (Protocol.item_path_fact_status fact) "resolved" then
          Option.is_some segments
        else Option.is_none segments
  in
  let valid_unreachable (source : Protocol.unreachable_source) =
    String.equal
      (Protocol.unreachable_source_status source)
      "unreachable-source"
    && file_member (Protocol.unreachable_source_path source)
    && not (root_member (Protocol.unreachable_source_path source))
  in
  let root_fact_count root =
    List.length
      (List.filter
         (fun fact ->
           String.equal root (Protocol.module_fact_root_file fact)
           && String.equal "root" (Protocol.module_fact_kind fact))
         (Protocol.module_path_analysis_module_facts analysis))
  in
  let unreachable_paths =
    Protocol.module_path_analysis_unreachable_sources analysis
    |> List.map Protocol.unreachable_source_path
  in
  let reachable_path path = not (List.mem path unreachable_paths) in
  if
    not
      (String.equal snapshot_id
         (Protocol.module_path_analysis_snapshot_id analysis))
  then Error "module path snapshot ID differs from request"
  else if
    List.length (Protocol.module_path_analysis_module_facts analysis)
    > Protocol.maximum_module_facts
    || List.length (Protocol.module_path_analysis_item_path_facts analysis)
       > Protocol.maximum_item_records
  then Error "module path analysis exceeds configured fact limit"
  else if
    not
      (strictly_sorted compare_module_fact
         (Protocol.module_path_analysis_module_facts analysis))
  then Error "module facts are not canonically ordered"
  else if
    not
      (strictly_sorted compare_item_path_fact
         (Protocol.module_path_analysis_item_path_facts analysis))
  then Error "item path facts are not canonically ordered"
  else if
    not
      (strictly_sorted
         (fun left right ->
           String.compare
             (Protocol.unreachable_source_path left)
             (Protocol.unreachable_source_path right))
         (Protocol.module_path_analysis_unreachable_sources analysis))
  then Error "unreachable sources are not canonically ordered"
  else if not (List.for_all (fun root -> root_fact_count root = 1) root_files)
  then Error "module path analysis is missing or duplicates a root fact"
  else if
    Protocol.module_path_analysis_complete analysis
    && ((not (Protocol.module_path_analysis_parser_complete analysis))
       || Protocol.module_path_analysis_unreachable_sources analysis <> []
       || List.exists
            (fun fact ->
              not (String.equal (Protocol.module_fact_status fact) "resolved"))
            (Protocol.module_path_analysis_module_facts analysis))
  then Error "module path analysis claims unsupported completeness"
  else if
    List.for_all valid_module_fact
      (Protocol.module_path_analysis_module_facts analysis)
    && List.for_all valid_item_fact
         (Protocol.module_path_analysis_item_path_facts analysis)
    && List.for_all valid_unreachable
         (Protocol.module_path_analysis_unreachable_sources analysis)
    && List.for_all
         (fun fact ->
           Option.fold ~none:true ~some:reachable_path
             (Protocol.module_fact_source_path fact)
           && Option.fold ~none:true ~some:reachable_path
                (Protocol.module_fact_parent_source_path fact))
         (Protocol.module_path_analysis_module_facts analysis)
    && List.for_all
         (fun fact -> reachable_path (Protocol.item_path_fact_source_path fact))
         (Protocol.module_path_analysis_item_path_facts analysis)
  then Ok analysis
  else Error "module path analysis contains an invalid fact"

let normalized_files files =
  if List.length files > Protocol.maximum_source_files then
    Error "source file limit exceeded"
  else if
    not
      (List.for_all
         (fun (file : Protocol.source_file) ->
           safe_relative_rust_path (Protocol.source_file_path file)
           && String.length (Protocol.source_file_contents file)
              <= Protocol.maximum_source_bytes)
         files)
  then Error "semantic input contains an unsafe Rust path or oversized source"
  else
    let files =
      List.sort
        (fun (left : Protocol.source_file) right ->
          String.compare
            (Protocol.source_file_path left)
            (Protocol.source_file_path right))
        files
    in
    let rec no_duplicate_paths = function
      | [] | [ _ ] -> true
      | (left : Protocol.source_file) :: (right :: _ as rest) ->
          (not
             (String.equal
                (Protocol.source_file_path left)
                (Protocol.source_file_path right)))
          && no_duplicate_paths rest
    in
    if no_duplicate_paths files then Ok files
    else Error "semantic input contains duplicate Rust paths"

let normalized_roots ~files roots =
  if roots = [] then Error "module path input contains no explicit roots"
  else if List.length roots > Protocol.maximum_source_files then
    Error "module path input exceeds explicit root limit"
  else if not (List.for_all safe_relative_rust_path roots) then
    Error "module path input contains an unsafe root path"
  else
    let roots = List.sort String.compare roots in
    let rec no_duplicate_roots = function
      | [] | [ _ ] -> true
      | left :: (right :: _ as rest) ->
          (not (String.equal left right)) && no_duplicate_roots rest
    in
    if not (no_duplicate_roots roots) then
      Error "module path input contains duplicate root paths"
    else if
      not
        (List.for_all
           (fun root -> Option.is_some (source_for_path files root))
           roots)
    then Error "module path input names a root absent from the source map"
    else Ok roots

let handshake configuration =
  let request = request_json ~operation:"handshake" [] in
  run configuration request (decode_response decode_handshake)

let analyze_files configuration ~snapshot_id ~files =
  if not (valid_snapshot_id snapshot_id) then
    Unavailable
      (Adapter_error
         {
           code = "invalid-snapshot-id";
           message =
             "semantic input snapshot ID is not 64 lowercase hex characters";
         })
  else
    match normalized_files files with
    | Error message ->
        Unavailable (Adapter_error { code = "invalid-input"; message })
    | Ok files -> (
        let request = request_for_analysis ~snapshot_id files in
        match run configuration request (decode_response decode_analysis) with
        | Available analysis -> (
            match validate_analysis ~snapshot_id ~files analysis with
            | Ok analysis -> Available analysis
            | Error message -> Unavailable (Malformed_adapter_response message))
        | Unavailable _ as result -> result)

let resolve_module_paths_files configuration ~snapshot_id ~root_files ~files =
  if not (valid_snapshot_id snapshot_id) then
    Unavailable
      (Adapter_error
         {
           code = "invalid-snapshot-id";
           message =
             "semantic input snapshot ID is not 64 lowercase hex characters";
         })
  else
    match normalized_files files with
    | Error message ->
        Unavailable (Adapter_error { code = "invalid-input"; message })
    | Ok files -> (
        match normalized_roots ~files root_files with
        | Error message ->
            Unavailable (Adapter_error { code = "invalid-input"; message })
        | Ok root_files -> (
            let request =
              request_for_module_paths ~snapshot_id ~root_files files
            in
            match
              run configuration request
                (decode_response decode_module_path_analysis)
            with
            | Available analysis -> (
                match
                  validate_module_path_analysis ~snapshot_id ~root_files ~files
                    analysis
                with
                | Ok analysis -> Available analysis
                | Error message ->
                    Unavailable (Malformed_adapter_response message))
            | Unavailable _ as result -> result))

let collect_snapshot_rust_files store root =
  let rec collect path tree_id =
    let* tree = Paengi_snapshot.Tree.load store tree_id in
    Paengi_snapshot.Tree.entries tree
    |> List.fold_left
         (fun accumulated (name, entry) ->
           let* collected = accumulated in
           let path = path @ [ name ] in
           match entry with
           | Paengi_snapshot.Tree.Directory tree_id ->
               let* nested = collect path tree_id in
               Ok (List.rev_append nested collected)
           | Paengi_snapshot.Tree.File
               { mode = Paengi_snapshot.Symlink; content = _ } ->
               Ok collected
           | Paengi_snapshot.Tree.File
               {
                 mode = Paengi_snapshot.Regular | Paengi_snapshot.Executable;
                 content;
               } ->
               let path = String.concat "/" path in
               if not (String.ends_with ~suffix:".rs" path) then Ok collected
               else
                 let* contents = Paengi_snapshot.Content.load store content in
                 Ok (Protocol.make_source_file ~path ~contents :: collected))
         (Ok [])
  in
  collect [] root

let analyze_snapshot configuration ~store ~snapshot =
  match Paengi_snapshot.Snapshot.load store snapshot with
  | Error error -> Unavailable (Snapshot_error error)
  | Ok snapshot_model -> (
      match
        collect_snapshot_rust_files store
          (Paengi_snapshot.Snapshot.root snapshot_model)
      with
      | Error error -> Unavailable (Snapshot_error error)
      | Ok files ->
          let files =
            List.sort
              (fun (left : Protocol.source_file) right ->
                String.compare
                  (Protocol.source_file_path left)
                  (Protocol.source_file_path right))
              files
          in
          if files = [] then
            Unavailable
              (Adapter_error
                 {
                   code = "no-rust-files";
                   message = "verified snapshot contains no Rust source files";
                 })
          else
            let snapshot_id =
              Paengi_snapshot.Snapshot.stored_object_id snapshot
              |> Paengi_store.Stored_object_id.to_hex
            in
            analyze_files configuration ~snapshot_id ~files)

let resolve_module_paths_snapshot configuration ~store ~snapshot ~root_files =
  match Paengi_snapshot.Snapshot.load store snapshot with
  | Error error -> Unavailable (Snapshot_error error)
  | Ok snapshot_model -> (
      match
        collect_snapshot_rust_files store
          (Paengi_snapshot.Snapshot.root snapshot_model)
      with
      | Error error -> Unavailable (Snapshot_error error)
      | Ok files ->
          let files =
            List.sort
              (fun (left : Protocol.source_file) right ->
                String.compare
                  (Protocol.source_file_path left)
                  (Protocol.source_file_path right))
              files
          in
          if files = [] then
            Unavailable
              (Adapter_error
                 {
                   code = "no-rust-files";
                   message = "verified snapshot contains no Rust source files";
                 })
          else
            let snapshot_id =
              Paengi_snapshot.Snapshot.stored_object_id snapshot
              |> Paengi_store.Stored_object_id.to_hex
            in
            resolve_module_paths_files configuration ~snapshot_id ~root_files
              ~files)
