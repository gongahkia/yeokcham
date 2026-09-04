type command_error = { code : string; message : string }
type command_result = Completed

type envelope = {
  command_value : string;
  ok_value : bool;
  result_value : Yojson.Safe.t option;
  warnings_value : string list;
  error_value : command_error option;
}

let schema_version = 1

let command_result_json = function
  | Completed -> `Assoc [ ("outcome", `String "completed") ]

let valid_text value =
  String.length value > 0
  && String.length value <= 4096
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          value)

let valid_command value =
  valid_text value
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       value

let valid_error_code = valid_command

let check_command command =
  if valid_command command then Ok () else Error "invalid CLI command name"

let check_warnings warnings =
  if List.for_all valid_text warnings then Ok ()
  else Error "invalid CLI warning"

let check_result = function
  | `Assoc _ -> Ok ()
  | `Null -> Error "CLI result must be an object"
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Tuple _
  | `Variant _ ->
      Error "CLI result must be an object"

let success ~command ~result ~warnings =
  match
    (check_command command, check_result result, check_warnings warnings)
  with
  | Ok (), Ok (), Ok () ->
      {
        command_value = command;
        ok_value = true;
        result_value = Some result;
        warnings_value = warnings;
        error_value = None;
      }
  | Error message, _, _ | _, Error message, _ | _, _, Error message ->
      invalid_arg message

let failure ~command ~error ~warnings =
  match (check_command command, check_warnings warnings) with
  | Error message, _ | _, Error message -> invalid_arg message
  | Ok (), Ok () ->
      if (not (valid_error_code error.code)) || not (valid_text error.message)
      then invalid_arg "invalid CLI error"
      else
        {
          command_value = command;
          ok_value = false;
          result_value = None;
          warnings_value = warnings;
          error_value = Some error;
        }

let command envelope = envelope.command_value
let ok envelope = envelope.ok_value
let result envelope = envelope.result_value
let warnings envelope = envelope.warnings_value
let error envelope = envelope.error_value

let encode envelope =
  let result = Option.value ~default:`Null envelope.result_value in
  let error =
    match envelope.error_value with
    | None -> `Null
    | Some { code; message } ->
        `Assoc [ ("code", `String code); ("message", `String message) ]
  in
  `Assoc
    [
      ("schema_version", `Int schema_version);
      ("command", `String envelope.command_value);
      ("ok", `Bool envelope.ok_value);
      ("result", result);
      ( "warnings",
        `List
          (List.map (fun warning -> `String warning) envelope.warnings_value) );
      ("error", error);
    ]
  |> Yojson.Safe.to_string

let duplicate names =
  let sorted = List.sort String.compare names in
  let rec loop = function
    | left :: right :: _ when String.equal left right -> true
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop sorted

let exactly_fields expected fields =
  let names = List.map fst fields in
  (not (duplicate names))
  && List.sort String.compare names = List.sort String.compare expected

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("CLI envelope is missing " ^ name)

let ( let* ) = Result.bind

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error ("CLI envelope " ^ name ^ " must be a string")

let warnings_field fields =
  let* value = field "warnings" fields in
  match value with
  | `List values ->
      let rec strings reversed = function
        | [] -> Ok (List.rev reversed)
        | `String value :: rest -> strings (value :: reversed) rest
        | _ -> Error "CLI envelope warnings must be strings"
      in
      strings [] values
  | _ -> Error "CLI envelope warnings must be an array"

let error_field fields =
  let* value = field "error" fields in
  match value with
  | `Null -> Ok None
  | `Assoc fields when exactly_fields [ "code"; "message" ] fields ->
      let* code = string_field "code" fields in
      let* message = string_field "message" fields in
      Ok (Some { code; message })
  | `Assoc _ -> Error "CLI envelope error has unknown or duplicate fields"
  | _ -> Error "CLI envelope error must be null or an object"

let decode bytes =
  let value =
    try Ok (Yojson.Safe.from_string bytes)
    with Yojson.Json_error message -> Error ("invalid CLI JSON: " ^ message)
  in
  let* value = value in
  match value with
  | `Assoc fields
    when exactly_fields
           [ "schema_version"; "command"; "ok"; "result"; "warnings"; "error" ]
           fields -> (
      let* version = field "schema_version" fields in
      let* command = string_field "command" fields in
      let* ok = field "ok" fields in
      let* result = field "result" fields in
      let* warnings = warnings_field fields in
      let* error = error_field fields in
      let* () =
        match version with
        | `Int value when value = schema_version -> Ok ()
        | _ -> Error "unsupported CLI envelope schema version"
      in
      let* () = check_command command in
      let* () = check_warnings warnings in
      let* result =
        match result with
        | `Null -> Ok None
        | value ->
            let* () = check_result value in
            Ok (Some value)
      in
      let* ok =
        match ok with
        | `Bool value -> Ok value
        | _ -> Error "CLI envelope ok must be a boolean"
      in
      match (ok, result, error) with
      | true, Some _, None | false, None, Some _ ->
          Ok
            {
              command_value = command;
              ok_value = ok;
              result_value = result;
              warnings_value = warnings;
              error_value = error;
            }
      | _ -> Error "CLI envelope success and error fields disagree")
  | `Assoc _ -> Error "CLI envelope has unknown or duplicate fields"
  | _ -> Error "CLI envelope must be an object"
