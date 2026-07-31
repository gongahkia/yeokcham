[@@@warning "-42"]

module Protocol = struct
  let version = 1
  let maximum_request_bytes = 4 * 1024 * 1024
  let maximum_response_bytes = 4 * 1024 * 1024

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
  type resolution_diagnostic = { containing_file : string option; module_name : string }
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

  let source_file_path (file : source_file) = file.path
  let source_file_language (file : source_file) = file.language
  let source_file_contents (file : source_file) = file.contents
  let make_source_file ~path ~language ~contents : source_file = { path; language; contents }
  let compiler_strict (options : compiler_options) = options.strict
  let compiler_jsx (options : compiler_options) = options.jsx
  let compiler_module_resolution (options : compiler_options) = options.module_resolution
  let compiler_base_url (options : compiler_options) = options.base_url
  let compiler_paths (options : compiler_options) = options.paths
  let make_span ~start_byte ~end_byte = { start_byte; end_byte }
  let make_symbol ~qualified_name ~alias_qualified_name ~declaration_locations ~merged_declaration_count : symbol =
    { qualified_name; alias_qualified_name; declaration_locations; merged_declaration_count }
  let make_declaration ~path ~declaration_kind ~declaration_span ~name_span
      ~parent_declaration_path ~exported ~default ~local ~syntactic_name
      ~overload_ordinal ~declaration_shape_digest ~signature_digest ~symbol : declaration =
    {
      path;
      declaration_kind;
      declaration_span;
      name_span;
      parent_declaration_path;
      exported;
      default;
      local;
      syntactic_name;
      overload_ordinal;
      declaration_shape_digest;
      signature_digest;
      symbol;
    }
  let make_diagnostic ~code ~category ~message ~path ~span : diagnostic = { code; category; message; path; span }
  let make_resolution_diagnostic ~containing_file ~module_name : resolution_diagnostic = { containing_file; module_name }
  let make_analysis ~snapshot_id ~typescript_version ~parser_complete
      ~resolution_complete ~semantic_complete ~type_resolution_complete
      ~declarations ~parser_diagnostics ~resolution_diagnostics
      ~type_checker_diagnostics ~elapsed_ms : analysis =
    {
      snapshot_id;
      typescript_version;
      parser_complete;
      resolution_complete;
      semantic_complete;
      type_resolution_complete;
      declarations;
      parser_diagnostics;
      resolution_diagnostics;
      type_checker_diagnostics;
      elapsed_ms;
    }
  let analysis_snapshot_id (analysis : analysis) = analysis.snapshot_id
  let analysis_typescript_version (analysis : analysis) = analysis.typescript_version
  let analysis_parser_complete (analysis : analysis) = analysis.parser_complete
  let analysis_resolution_complete (analysis : analysis) = analysis.resolution_complete
  let analysis_semantic_complete (analysis : analysis) = analysis.semantic_complete
  let analysis_declarations (analysis : analysis) = analysis.declarations
  let declaration_path (declaration : declaration) = declaration.path
  let declaration_kind (declaration : declaration) = declaration.declaration_kind
  let declaration_name_span (declaration : declaration) = declaration.name_span
  let declaration_syntactic_name (declaration : declaration) = declaration.syntactic_name
  let declaration_exported (declaration : declaration) = declaration.exported
  let span_start_byte (span : span) = span.start_byte
  let span_end_byte (span : span) = span.end_byte
end

type configuration = {
  node : string;
  adapter_path : string;
  timeout_ms : int;
  max_request_bytes : int;
  max_response_bytes : int;
  max_stderr_bytes : int;
}

let default_configuration =
  {
    node = "node";
    adapter_path = "tools/paengi-typescript-adapter/adapter.mjs";
    timeout_ms = 5_000;
    max_request_bytes = Protocol.maximum_request_bytes;
    max_response_bytes = Protocol.maximum_response_bytes;
    max_stderr_bytes = 64 * 1024;
  }

type unavailable_reason =
  | Adapter_missing of string
  | Node_missing of string
  | Adapter_timeout of { timeout_ms : int }
  | Adapter_output_too_large of { limit : int }
  | Adapter_crashed of { exit_code : int option; signal : int option; stderr : string }
  | Malformed_adapter_response of string
  | Unsupported_protocol of string
  | Adapter_error of { code : string; message : string }
  | Snapshot_error of Paengi_snapshot.error

let unavailable_reason_to_string = function
  | Adapter_missing path -> "adapter is missing: " ^ path
  | Node_missing path -> "node executable is missing: " ^ path
  | Adapter_timeout { timeout_ms } ->
      Printf.sprintf "adapter timed out after %dms" timeout_ms
  | Adapter_output_too_large { limit } ->
      Printf.sprintf "adapter output exceeded %d bytes" limit
  | Adapter_crashed { exit_code; signal; stderr } ->
      Printf.sprintf "adapter crashed (exit=%s signal=%s stderr=%S)"
        (Option.fold ~none:"none" ~some:string_of_int exit_code)
        (Option.fold ~none:"none" ~some:string_of_int signal)
        stderr
  | Malformed_adapter_response message -> "malformed adapter response: " ^ message
  | Unsupported_protocol message -> "unsupported adapter protocol: " ^ message
  | Adapter_error { code; message } ->
      Printf.sprintf "adapter error %s: %s" code message
  | Snapshot_error error -> Paengi_snapshot.error_to_string error

type handshake = {
  typescript_version : string;
  minimum_node_version : string;
  request_limit_bytes : int;
  response_limit_bytes : int;
  capabilities : string list;
}

type 'a result = Available of 'a | Unavailable of unavailable_reason

let ( let* ) = Result.bind

module Json = struct
  type t = Null | Bool of bool | Number of string | String of string | Array of t list | Object of (string * t) list

  let whitespace = function ' ' | '\n' | '\r' | '\t' -> true | _ -> false

  let parse source =
    let length = String.length source in
    let rec skip index =
      if index < length && whitespace source.[index] then skip (index + 1) else index
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
        | character -> Error (Printf.sprintf "unexpected JSON character %C" character)
    and literal index token parsed =
      let token_length = String.length token in
      if index + token_length <= length && String.sub source index token_length = token
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
          | '"' -> Buffer.add_char buffer '"'; loop (index + 1)
          | '\\' -> Buffer.add_char buffer '\\'; loop (index + 1)
          | '/' -> Buffer.add_char buffer '/'; loop (index + 1)
          | 'b' -> Buffer.add_char buffer '\b'; loop (index + 1)
          | 'f' -> Buffer.add_char buffer '\012'; loop (index + 1)
          | 'n' -> Buffer.add_char buffer '\n'; loop (index + 1)
          | 'r' -> Buffer.add_char buffer '\r'; loop (index + 1)
          | 't' -> Buffer.add_char buffer '\t'; loop (index + 1)
          | 'u' -> unicode_escape (index + 1)
          | character -> Error (Printf.sprintf "invalid JSON escape %C" character)
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
      if index < length && Char.equal source.[index] ']' then Ok (Array (List.rev reversed), index + 1)
      else
        let* (item, next) = value index in
        let next = skip next in
        if next >= length then Error "unterminated JSON array"
        else if Char.equal source.[next] ']' then Ok (Array (List.rev (item :: reversed)), next + 1)
        else if Char.equal source.[next] ',' then array (next + 1) (item :: reversed)
        else Error "invalid JSON array separator"
    and object_ index reversed =
      let index = skip index in
      if index < length && Char.equal source.[index] '}' then Ok (Object (List.rev reversed), index + 1)
      else
        let* (key_value, after_key) = string_value index in
        match key_value with
        | String key ->
            let after_key = skip after_key in
            if after_key >= length || not (Char.equal source.[after_key] ':') then Error "missing JSON object colon"
            else
              let* (item, next) = value (after_key + 1) in
              let next = skip next in
              if next >= length then Error "unterminated JSON object"
              else if Char.equal source.[next] '}' then Ok (Object (List.rev ((key, item) :: reversed)), next + 1)
              else if Char.equal source.[next] ',' then object_ (next + 1) ((key, item) :: reversed)
              else Error "invalid JSON object separator"
        | Null | Bool _ | Number _ | Array _ | Object _ -> Error "JSON object key is not a string"
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
      if Option.is_none (float_of_string_opt token) then Error "invalid JSON number"
      else Ok (Number token, next)
    in
    let* (parsed, index) = value 0 in
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
            Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code character))
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
  let number = function
    | Number value -> float_of_string_opt value
    | Null | Bool _ | String _ | Array _ | Object _ -> None
  let integer value =
    match number value with
    | Some number when Float.is_integer number && number <= float_of_int max_int && number >= float_of_int min_int -> Some (int_of_float number)
    | Some _ | None -> None
  let array = function
    | Array values -> Some values
    | Null | Bool _ | Number _ | String _ | Object _ -> None
end

let safe_relative_path path =
  String.length path > 0
  && not (String.contains path '\000')
  && not (Filename.is_relative path |> not)
  && not (String.contains path '\\')
  && not (String.equal path "." || String.equal path ".." || String.starts_with ~prefix:"../" path)

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

let language_to_string = function Protocol.Ts -> "ts" | Protocol.Tsx -> "tsx"

let compiler_options_json options =
  let fields = [ "strict", string_of_bool (Protocol.compiler_strict options) ] in
  let fields =
    match Protocol.compiler_jsx options with
    | None -> fields
    | Some `Preserve -> ("jsx", Json.quote "preserve") :: fields
    | Some `React_jsx -> ("jsx", Json.quote "react-jsx") :: fields
    | Some `React -> ("jsx", Json.quote "react") :: fields
  in
  let fields =
    match Protocol.compiler_module_resolution options with
    | None -> fields
    | Some `Bundler -> ("moduleResolution", Json.quote "bundler") :: fields
    | Some `Node16 -> ("moduleResolution", Json.quote "node16") :: fields
    | Some `Node_next -> ("moduleResolution", Json.quote "nodenext") :: fields
  in
  let fields =
    match Protocol.compiler_base_url options with
    | None -> fields
    | Some value -> ("baseUrl", Json.quote value) :: fields
  in
  let paths =
    Protocol.compiler_paths options
    |> List.map (fun (name, targets) ->
           Json.quote name ^ ":["
           ^ String.concat "," (List.map Json.quote targets)
           ^ "]")
    |> String.concat ","
  in
  let fields = if paths = "" then fields else ("paths", "{" ^ paths ^ "}") :: fields in
  "{" ^ String.concat "," (List.map (fun (name, value) -> Json.quote name ^ ":" ^ value) fields) ^ "}"

let request_json ~operation fields =
  let fields = ("protocolVersion", string_of_int Protocol.version) :: ("operation", Json.quote operation) :: fields in
  "{" ^ String.concat "," (List.map (fun (name, value) -> Json.quote name ^ ":" ^ value) fields) ^ "}"

let request_for_analysis ~snapshot_id ~root_files ~files ~compiler_options ~timeout_ms =
  let files =
    files
    |> List.map (fun (file : Protocol.source_file) ->
           let file_path = Protocol.source_file_path file in
           "{"
           ^ String.concat ","
               [
                 Json.quote "path" ^ ":" ^ Json.quote file_path;
                 Json.quote "language" ^ ":" ^ Json.quote (language_to_string (Protocol.source_file_language file));
                 Json.quote "contentsHex" ^ ":" ^ Json.quote (hex (Protocol.source_file_contents file));
               ]
           ^ "}")
    |> String.concat ","
  in
  request_json ~operation:"analyze"
    [
      "snapshotId", Json.quote snapshot_id;
      "rootFiles", "[" ^ String.concat "," (List.map Json.quote root_files) ^ "]";
      "files", "[" ^ files ^ "]";
      "compilerOptions", compiler_options_json compiler_options;
      "timeoutMs", string_of_int timeout_ms;
    ]

let executable_path executable =
  if String.contains executable '/' then
    if Sys.file_exists executable then Some executable else None
  else
    match Sys.getenv_opt "PATH" with
    | None -> None
    | Some path ->
        String.split_on_char ':' path
        |> List.find_map (fun directory ->
               let candidate = Filename.concat directory executable in
               try
                 Unix.access candidate [ Unix.X_OK ];
                 Some candidate
               with Unix.Unix_error _ -> None)

type process_result = {
  exit_code : int option;
  signal : int option;
  timed_out : bool;
  output_too_large : bool;
  stdout : string;
  stderr : string;
}

let kill_process_group pid signal =
  try Unix.kill (-pid) signal with Unix.Unix_error _ -> (try Unix.kill pid signal with Unix.Unix_error _ -> ())

let run_process configuration request =
  match executable_path configuration.node with
  | None -> Error (Node_missing configuration.node)
  | Some node ->
      let stdin_read, stdin_write = Unix.pipe () in
      let stdout_read, stdout_write = Unix.pipe () in
      let stderr_read, stderr_write = Unix.pipe () in
      let child = Unix.fork () in
      if child = 0 then (
        (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
        Unix.close stdin_write;
        Unix.close stdout_read;
        Unix.close stderr_read;
        Unix.dup2 stdin_read Unix.stdin;
        Unix.dup2 stdout_write Unix.stdout;
        Unix.dup2 stderr_write Unix.stderr;
        Unix.close stdin_read;
        Unix.close stdout_write;
        Unix.close stderr_write;
        let argv = [| node; configuration.adapter_path |] in
        Unix.execve node argv [| "PATH=/usr/bin:/bin" |])
      else (
        Unix.close stdin_read;
        Unix.close stdout_write;
        Unix.close stderr_write;
        List.iter Unix.set_nonblock [ stdin_write; stdout_read; stderr_read ];
        let input_offset = ref 0 in
        let input_open = ref true in
        let stdout_open = ref true in
        let stderr_open = ref true in
        let stdout = Buffer.create 1024 in
        let stderr = Buffer.create 1024 in
        let process_status = ref None in
        let timed_out = ref false in
        let output_too_large = ref false in
        let sent_kill = ref false in
        let terminated_at = ref None in
        let deadline = Unix.gettimeofday () +. (float_of_int configuration.timeout_ms /. 1000.) in
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
            | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
            | Unix.Unix_error _ -> close descriptor open_
          in
          loop ()
        in
        while Option.is_none !process_status || !stdout_open || !stderr_open do
          if Option.is_none !process_status then
            match Unix.waitpid [ Unix.WNOHANG ] child with
            | 0, _ -> ()
            | _, status -> process_status := Some status;
          let now = Unix.gettimeofday () in
          if Option.is_none !process_status && ((not !timed_out && now >= deadline) || !output_too_large) then (
            timed_out := !timed_out || now >= deadline;
            terminated_at := Some now;
            kill_process_group child Sys.sigterm);
          if Option.is_some !terminated_at && not !sent_kill && Option.is_none !process_status
             && now -. Option.get !terminated_at >= 0.1 then (
            sent_kill := true;
            kill_process_group child Sys.sigkill);
          if !input_open && !input_offset = String.length request then close stdin_write input_open;
          let reads = (if !stdout_open then [ stdout_read ] else []) @ if !stderr_open then [ stderr_read ] else [] in
          let writes = if !input_open then [ stdin_write ] else [] in
          if reads <> [] || writes <> [] then (
            let readable, writable, _ = Unix.select reads writes [] 0.01 in
            if List.mem stdout_read readable then read stdout_read stdout configuration.max_response_bytes stdout_open;
            if List.mem stderr_read readable then read stderr_read stderr configuration.max_stderr_bytes stderr_open;
            if List.mem stdin_write writable && !input_offset < String.length request then
              try
                let written = Unix.write_substring stdin_write request !input_offset (String.length request - !input_offset) in
                input_offset := !input_offset + written
              with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EPIPE), _, _) -> close stdin_write input_open)
          else if Option.is_none !process_status then ignore (Unix.select [] [] [] 0.01)
        done;
        let exit_code, signal =
          match !process_status with
          | Some (Unix.WEXITED code) -> Some code, None
          | Some (Unix.WSIGNALED signal | Unix.WSTOPPED signal) -> None, Some signal
          | None -> None, None
        in
        Ok { exit_code; signal; timed_out = !timed_out; output_too_large = !output_too_large; stdout = Buffer.contents stdout; stderr = Buffer.contents stderr })

let object_field name value =
  match Json.object_field name value with
  | Some field -> Ok field
  | None -> Error ("missing response field " ^ name)

let string_field name value =
  let* field = object_field name value in
  match Json.string field with Some string -> Ok string | None -> Error ("response field " ^ name ^ " is not a string")

let optional_string_field name value =
  match Json.object_field name value with
  | None | Some Json.Null -> Ok None
  | Some (Json.String string) -> Ok (Some string)
  | Some (Json.Bool _ | Json.Number _ | Json.Array _ | Json.Object _) ->
      Error ("response field " ^ name ^ " is not a string")

let bool_field name value =
  let* field = object_field name value in
  match Json.boolean field with Some boolean -> Ok boolean | None -> Error ("response field " ^ name ^ " is not a bool")

let int_field name value =
  let* field = object_field name value in
  match Json.integer field with Some integer -> Ok integer | None -> Error ("response field " ^ name ^ " is not an integer")

let float_field name value =
  let* field = object_field name value in
  match Json.number field with Some number -> Ok number | None -> Error ("response field " ^ name ^ " is not a number")

let list_field name decode value =
  let* field = object_field name value in
  match Json.array field with
  | None -> Error ("response field " ^ name ^ " is not an array")
  | Some values -> List.fold_right (fun value accumulated -> let* item = decode value in let* items = accumulated in Ok (item :: items)) values (Ok [])

let decode_span start_name end_name value =
  let* start_byte = int_field start_name value in
  let* end_byte = int_field end_name value in
  if start_byte < 0 || end_byte < start_byte then Error "invalid byte span"
  else Ok (Protocol.make_span ~start_byte ~end_byte)

let decode_symbol value =
  let* qualified_name = string_field "qualifiedName" value in
  let* alias_qualified_name = optional_string_field "aliasQualifiedName" value in
  let* declaration_locations = list_field "declarationLocations" (fun item -> match Json.string item with Some string -> Ok string | None -> Error "symbol declaration location is not a string") value in
  let* merged_declaration_count = int_field "mergedDeclarationCount" value in
  Ok
    (Protocol.make_symbol ~qualified_name ~alias_qualified_name
       ~declaration_locations ~merged_declaration_count)

let decode_declaration value =
  let* path = string_field "path" value in
  let* declaration_kind = string_field "declarationKind" value in
  let* declaration_span = decode_span "declarationStartByte" "declarationEndByte" value in
  let name_span =
    match Json.object_field "nameStartByte" value, Json.object_field "nameEndByte" value with
    | None, None -> Ok None
    | Some _, Some _ -> decode_span "nameStartByte" "nameEndByte" value |> Result.map Option.some
    | Some _, None | None, Some _ -> Error "incomplete declaration name span"
  in
  let* name_span = name_span in
  let* parent_declaration_path = list_field "parentDeclarationPath" (fun item -> match Json.string item with Some string -> Ok string | None -> Error "parent declaration path item is not a string") value in
  let* exported = bool_field "exported" value in
  let* default = bool_field "default" value in
  let* local = bool_field "local" value in
  let* syntactic_name = optional_string_field "syntacticName" value in
  let* overload_ordinal = int_field "overloadOrdinal" value in
  let* declaration_shape_digest = string_field "declarationShapeDigest" value in
  let signature_digest =
    match Json.object_field "signature" value with
    | Some signature -> optional_string_field "digest" signature
    | None -> Ok None
  in
  let* signature_digest = signature_digest in
  let symbol =
    match Json.object_field "symbol" value with
    | Some symbol -> (
        match Json.object_field "available" symbol with
        | Some (Json.Bool true) -> decode_symbol symbol |> Result.map Option.some
        | Some (Json.Bool false) -> Ok None
        | Some (Json.Null | Json.Number _ | Json.String _ | Json.Array _ | Json.Object _) | None ->
            Error "symbol availability is invalid")
    | None -> Ok None
  in
  let* symbol = symbol in
  Ok
    (Protocol.make_declaration ~path ~declaration_kind ~declaration_span
       ~name_span ~parent_declaration_path ~exported ~default ~local
       ~syntactic_name ~overload_ordinal ~declaration_shape_digest
       ~signature_digest ~symbol)

let decode_diagnostic value =
  let* code = int_field "code" value in
  let* category = string_field "category" value in
  let* message = string_field "message" value in
  let* path = optional_string_field "path" value in
  let span =
    match Json.object_field "startByte" value, Json.object_field "endByte" value with
    | None, None -> Ok None
    | Some _, Some _ -> decode_span "startByte" "endByte" value |> Result.map Option.some
    | Some _, None | None, Some _ -> Error "incomplete diagnostic span"
  in
  let* span = span in
  Ok (Protocol.make_diagnostic ~code ~category ~message ~path ~span)

let decode_resolution_diagnostic value =
  let* containing_file = optional_string_field "containingFile" value in
  let* module_name = string_field "moduleName" value in
  Ok (Protocol.make_resolution_diagnostic ~containing_file ~module_name)

let decode_analysis value =
  let* snapshot_id = string_field "snapshotId" value in
  let* typescript_version = string_field "typescriptVersion" value in
  let* parser_complete = bool_field "parserComplete" value in
  let* resolution_complete = bool_field "resolutionComplete" value in
  let* semantic_complete = bool_field "semanticComplete" value in
  let* type_resolution_complete = bool_field "typeResolutionComplete" value in
  let* declarations = list_field "declarations" decode_declaration value in
  let* parser_diagnostics = list_field "parserDiagnostics" decode_diagnostic value in
  let* resolution_diagnostics = list_field "resolutionDiagnostics" decode_resolution_diagnostic value in
  let* type_checker_diagnostics = list_field "typeCheckerDiagnostics" decode_diagnostic value in
  let* elapsed_ms = float_field "elapsedMs" value in
  Ok
    (Protocol.make_analysis ~snapshot_id ~typescript_version ~parser_complete
       ~resolution_complete ~semantic_complete ~type_resolution_complete
       ~declarations ~parser_diagnostics ~resolution_diagnostics
       ~type_checker_diagnostics ~elapsed_ms)

let decode_handshake value =
  let* typescript_version = string_field "typescriptVersion" value in
  let* minimum_node_version = string_field "minimumNodeVersion" value in
  let* request_limit_bytes = int_field "requestLimitBytes" value in
  let* response_limit_bytes = int_field "responseLimitBytes" value in
  let* capabilities = list_field "capabilities" (fun item -> match Json.string item with Some string -> Ok string | None -> Error "capability is not a string") value in
  Ok { typescript_version; minimum_node_version; request_limit_bytes; response_limit_bytes; capabilities }

let decode_response decode output =
  let* response = Json.parse output in
  let* response_version = int_field "protocolVersion" response in
  if response_version <> Protocol.version then Error ("unsupported response protocol " ^ string_of_int response_version)
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
  if not (Sys.file_exists configuration.adapter_path) then Unavailable (Adapter_missing configuration.adapter_path)
  else if String.length request > configuration.max_request_bytes then Unavailable (Adapter_output_too_large { limit = configuration.max_request_bytes })
  else
    match run_process configuration request with
    | Error reason -> Unavailable reason
    | Ok process ->
        if process.timed_out then Unavailable (Adapter_timeout { timeout_ms = configuration.timeout_ms })
        else if process.output_too_large then Unavailable (Adapter_output_too_large { limit = configuration.max_response_bytes })
        else
          match process.exit_code, process.signal with
          | Some 0, None -> (
              match decode_response decode process.stdout with
              | Ok value -> Available value
              | Error message ->
                  let separator = String.index_opt message '\000' in
                  (match separator with
                  | Some index ->
                      let code = String.sub message 0 index in
                      let body = String.sub message (index + 1) (String.length message - index - 1) in
                      if String.equal code "unsupported-protocol" then Unavailable (Unsupported_protocol body)
                      else Unavailable (Adapter_error { code; message = body })
                  | None -> Unavailable (Malformed_adapter_response message)))
          | exit_code, signal -> Unavailable (Adapter_crashed { exit_code; signal; stderr = process.stderr })

let handshake configuration =
  let request = request_json ~operation:"handshake" [] in
  run configuration request decode_handshake

let analyze_files configuration ~snapshot_id ~root_files ~files ~compiler_options =
  if not
       (List.for_all
          (fun (file : Protocol.source_file) ->
            safe_relative_path (Protocol.source_file_path file))
          files)
     || not (List.for_all safe_relative_path root_files)
  then Unavailable (Adapter_error { code = "invalid-path"; message = "semantic input contains an unsafe project-relative path" })
  else
    let request = request_for_analysis ~snapshot_id ~root_files ~files ~compiler_options ~timeout_ms:configuration.timeout_ms in
    run configuration request decode_analysis

let language_for_path path =
  if String.ends_with ~suffix:".tsx" path then Some Protocol.Tsx
  else if String.ends_with ~suffix:".ts" path || String.ends_with ~suffix:".d.ts" path then Some Protocol.Ts
  else None

let analyze_snapshot configuration ~store ~snapshot ~compiler_options =
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
           | Paengi_snapshot.Tree.File { mode = _; content } -> (
               match language_for_path (String.concat "/" path) with
               | None -> Ok collected
               | Some language ->
                   let* contents = Paengi_snapshot.Content.load store content in
                   Ok
                     (Protocol.make_source_file
                        ~path:(String.concat "/" path) ~language ~contents
                     :: collected)))
         (Ok [])
  in
  match Paengi_snapshot.Snapshot.load store snapshot with
  | Error error -> Unavailable (Snapshot_error error)
  | Ok snapshot_model -> (
      match collect [] (Paengi_snapshot.Snapshot.root snapshot_model) with
      | Error error -> Unavailable (Snapshot_error error)
      | Ok files ->
          let files =
            List.sort
              (fun left right ->
                String.compare (Protocol.source_file_path left)
                  (Protocol.source_file_path right))
              files
          in
          let root_files = List.map Protocol.source_file_path files in
          let snapshot_id =
            Paengi_snapshot.Snapshot.stored_object_id snapshot
            |> Paengi_store.Stored_object_id.to_hex
          in
          if files = [] then Unavailable (Adapter_error { code = "no-typescript-files"; message = "verified snapshot contains no TypeScript source files" })
          else analyze_files configuration ~snapshot_id ~root_files ~files ~compiler_options)
