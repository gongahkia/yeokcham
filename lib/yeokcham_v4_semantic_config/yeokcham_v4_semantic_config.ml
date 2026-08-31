module Encoding = Yeokcham_encoding

type match_scope = Extensions of string list | Path_globs of string list | All_files
type overlap_sensitivity = Same_symbol | Nearby_ranges | References

type server = {
  name : string;
  program : string;
  arguments : string list;
  enabled : bool;
  match_scope : match_scope;
  overlap_sensitivity : overlap_sensitivity;
}

type error =
  | Invalid_name of string
  | Invalid_program of string
  | Invalid_argument of string
  | Invalid_extension of string
  | Invalid_glob of string
  | Invalid_match_scope of string
  | Duplicate_server of string
  | Unknown_server of string
  | Io_error of { path : string; operation : string; message : string }
  | Encoding_error of string

let file_name = "semantic-lsp-v1.cbor"
let schema_version = 1L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_name name -> "invalid semantic server name: " ^ name
  | Invalid_program program -> "invalid semantic server executable: " ^ program
  | Invalid_argument argument -> "invalid semantic server argument: " ^ argument
  | Invalid_extension extension -> "invalid semantic file extension: " ^ extension
  | Invalid_glob glob -> "invalid semantic path glob: " ^ glob
  | Invalid_match_scope scope -> "invalid semantic match scope: " ^ scope
  | Duplicate_server name -> "semantic server already exists: " ^ name
  | Unknown_server name -> "unknown semantic server: " ^ name
  | Io_error { path; operation; message } ->
      Printf.sprintf "semantic server config %s %s: %s" operation path message
  | Encoding_error detail -> "invalid semantic server config: " ^ detail

let path ~root = Filename.concat (Filename.concat root ".yeokcham") file_name

let valid_text value =
  String.length value > 0
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          value)

let valid_name name =
  valid_text name
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       name

let valid_program program =
  valid_text program && not (Filename.is_relative program)

let valid_extension extension =
  String.length extension > 1
  && extension.[0] = '.'
  && not
       (String.exists
          (function '/' | '\\' | '\000' | '\r' | '\n' -> true | _ -> false)
          extension)

let valid_relative_path value =
  valid_text value
  && not (String.starts_with ~prefix:"/" value)
  && not (String.exists (fun character -> character = '\\') value)
  && value <> "."
  && value <> ".."
  && not (String.starts_with ~prefix:"../" value)
  && not (String.contains value '\000')

let valid_glob glob =
  valid_relative_path glob
  && match Re.Glob.glob_result ~anchored:true glob with
     | Ok _ -> true
     | Error `Parse_error -> false

let sorted_unique compare values =
  values = List.sort compare values
  && List.length values = List.length (List.sort_uniq compare values)

let valid_scope = function
  | All_files -> true
  | Extensions extensions ->
      extensions <> [] && sorted_unique String.compare extensions
      && List.for_all valid_extension extensions
  | Path_globs globs ->
      globs <> [] && sorted_unique String.compare globs && List.for_all valid_glob globs

let valid_server server =
  valid_name server.name
  && valid_program server.program
  && List.for_all valid_text server.arguments
  && valid_scope server.match_scope

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Encoding_error (Encoding.construction_error_to_string error))

let boolean value = Ok (Encoding.bool value)

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Encoding_error (Encoding.construction_error_to_string error))

let string_array values =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | value :: rest ->
        let* value = text value in
        loop (value :: reversed) rest
  in
  loop [] values

let encode_scope = function
  | Extensions extensions ->
      let* extensions = string_array extensions in
      array [ Encoding.integer 0L; extensions ]
  | Path_globs globs ->
      let* globs = string_array globs in
      array [ Encoding.integer 1L; globs ]
  | All_files -> array [ Encoding.integer 2L ]

let encode_sensitivity = function
  | Same_symbol -> Encoding.integer 0L
  | Nearby_ranges -> Encoding.integer 1L
  | References -> Encoding.integer 2L

let encode_server server =
  let* name = text server.name in
  let* program = text server.program in
  let* arguments = string_array server.arguments in
  let* enabled = boolean server.enabled in
  let* match_scope = encode_scope server.match_scope in
  let sensitivity = encode_sensitivity server.overlap_sensitivity in
  array [ name; program; arguments; enabled; match_scope; sensitivity ]

let encode servers =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | server :: rest ->
        let* server = encode_server server in
        loop (server :: reversed) rest
  in
  let* servers = loop [] servers in
  array [ Encoding.integer schema_version; servers ] |> Result.map Encoding.encode

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Encoding_error (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Encoding_error (name ^ " must be text"))

let bool_field name = function
  | Encoding.Bool value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Null -> Error (Encoding_error (name ^ " must be boolean"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Encoding_error (name ^ " must be integer"))

let decode_string_array name value =
  let* values = array_values name value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* value = text_field name value in
        loop (value :: reversed) rest
  in
  loop [] values

let decode_scope value =
  let* fields = array_values "semantic match scope" value in
  match fields with
  | [ tag; values ] ->
      let* tag = integer_field "semantic match scope tag" tag in
      let* values = decode_string_array "semantic match values" values in
      if Int64.equal tag 0L then Ok (Extensions values)
      else if Int64.equal tag 1L then Ok (Path_globs values)
      else Error (Invalid_match_scope (Int64.to_string tag))
  | [ tag ] ->
      let* tag = integer_field "semantic match scope tag" tag in
      if Int64.equal tag 2L then Ok All_files
      else Error (Invalid_match_scope (Int64.to_string tag))
  | _ -> Error (Encoding_error "semantic match scope has the wrong field count")

let decode_sensitivity value =
  let* value = integer_field "semantic overlap sensitivity" value in
  if Int64.equal value 0L then Ok Same_symbol
  else if Int64.equal value 1L then Ok Nearby_ranges
  else if Int64.equal value 2L then Ok References
  else Error (Encoding_error "unsupported semantic overlap sensitivity")

let decode_server value =
  let* fields = array_values "semantic server" value in
  match fields with
  | [ name; program; arguments; enabled; match_scope; sensitivity ] ->
      let* name = text_field "semantic server name" name in
      let* program = text_field "semantic server executable" program in
      let* arguments = decode_string_array "semantic server arguments" arguments in
      let* enabled = bool_field "semantic server enabled" enabled in
      let* match_scope = decode_scope match_scope in
      let* overlap_sensitivity = decode_sensitivity sensitivity in
      let server =
        { name; program; arguments; enabled; match_scope; overlap_sensitivity }
      in
      if valid_server server then Ok server
      else Error (Encoding_error "semantic server contains invalid fields")
  | _ -> Error (Encoding_error "semantic server has the wrong field count")

let decode bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Encoding_error (Encoding.decode_error_to_string error))
  in
  let* fields = array_values "semantic server config" value in
  match fields with
  | [ version; servers ] ->
      let* version = integer_field "semantic server config version" version in
      if not (Int64.equal version schema_version) then
        Error (Encoding_error "unsupported semantic server config version")
      else
        let* servers = array_values "semantic servers" servers in
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | server :: rest ->
              let* server = decode_server server in
              loop (server :: reversed) rest
        in
        let* servers = loop [] servers in
        let names = List.map (fun server -> server.name) servers in
        if not (sorted_unique String.compare names) then
          Error (Encoding_error "semantic servers must be sorted and unique")
        else
          let* canonical = encode servers in
          if String.equal canonical bytes then Ok servers
          else Error (Encoding_error "semantic server config is not canonical")
  | _ -> Error (Encoding_error "semantic server config has the wrong field count")

let read_config ~root =
  let target = path ~root in
  try
    if Sys.file_exists target then
      In_channel.with_open_bin target In_channel.input_all |> decode
    else Ok []
  with Sys_error message -> Error (Io_error { path = target; operation = "read"; message })

let write_all descriptor target bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count = Unix.write_substring descriptor bytes offset (String.length bytes - offset) in
        if count = 0 then
          Error (Io_error { path = target; operation = "write"; message = "write returned zero" })
        else loop (offset + count)
      with Unix.Unix_error (error, operation, _) ->
        Error (Io_error { path = target; operation; message = Unix.error_message error })
  in
  loop 0

let write_config ~root servers =
  let* bytes = encode servers in
  let target = path ~root in
  let directory = Filename.dirname target in
  if not (Sys.file_exists directory) then
    Error (Io_error { path = directory; operation = "open"; message = "repository metadata directory is absent" })
  else
    let temporary = Filename.temp_file ~temp_dir:directory ".semantic-lsp-" ".tmp" in
    try
      let descriptor = Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let result = Fun.protect ~finally:(fun () -> try Unix.close descriptor with Unix.Unix_error _ -> ()) (fun () -> write_all descriptor temporary bytes) in
      match result with
      | Error error ->
          (try Unix.unlink temporary with Unix.Unix_error _ -> ());
          Error error
      | Ok () ->
          Unix.rename temporary target;
          Ok ()
    with Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path = target; operation; message = Unix.error_message error })

let list ~root = read_config ~root

let find ~root ~name =
  let* servers = read_config ~root in
  match List.find_opt (fun server -> String.equal server.name name) servers with
  | Some server -> Ok server
  | None -> Error (Unknown_server name)

let add ~root ~server =
  if not (valid_name server.name) then Error (Invalid_name server.name)
  else if not (valid_program server.program) then Error (Invalid_program server.program)
  else if not (List.for_all valid_text server.arguments) then
    Error (Invalid_argument "arguments contain a control byte")
  else if not (valid_scope server.match_scope) then
    Error (Invalid_match_scope "invalid scope")
  else
    let* servers = read_config ~root in
    if List.exists (fun existing -> String.equal existing.name server.name) servers then
      Error (Duplicate_server server.name)
    else
      write_config ~root
        (List.sort (fun left right -> String.compare left.name right.name) (server :: servers))

let update ~root ~name change =
  let* servers = read_config ~root in
  if not (List.exists (fun server -> String.equal server.name name) servers) then
    Error (Unknown_server name)
  else write_config ~root (List.map (fun server -> if String.equal server.name name then change server else server) servers)

let remove ~root ~name =
  let* servers = read_config ~root in
  if not (List.exists (fun server -> String.equal server.name name) servers) then
    Error (Unknown_server name)
  else write_config ~root (List.filter (fun server -> not (String.equal server.name name)) servers)

let set_enabled ~root ~name ~enabled = update ~root ~name (fun server -> { server with enabled })

let configure ~root ~name ~match_scope ~overlap_sensitivity =
  if not (valid_scope match_scope) then
    Error (Invalid_match_scope "invalid scope")
  else update ~root ~name (fun server -> { server with match_scope; overlap_sensitivity })

let matches_path server candidate =
  if not (valid_relative_path candidate) then false
  else
    match server.match_scope with
    | All_files -> true
    | Extensions extensions -> List.exists (fun extension -> String.ends_with ~suffix:extension candidate) extensions
    | Path_globs globs ->
        List.exists
          (fun glob ->
            match Re.Glob.glob_result ~anchored:true glob with
            | Ok expression -> Re.execp (Re.compile expression) candidate
            | Error `Parse_error -> false)
          globs

let match_scope_to_string = function
  | Extensions _ -> "extensions"
  | Path_globs _ -> "path-globs"
  | All_files -> "all-files"

let overlap_sensitivity_to_string = function
  | Same_symbol -> "same-symbol"
  | Nearby_ranges -> "nearby-ranges"
  | References -> "references"
