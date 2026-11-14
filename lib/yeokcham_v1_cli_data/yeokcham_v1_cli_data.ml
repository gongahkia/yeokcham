type command_error = { code : string; message : string }
type command_result = Completed
type success_outcome = [ `Completed | `Unchanged | `Incomplete ]

type failure_outcome =
  [ `Invalid
  | `Choice_required
  | `Conflict
  | `Unavailable
  | `Integrity_failure
  | `Blocked
  | `Interrupted
  | `Incomplete
  | `Failed ]

type outcome = [ success_outcome | failure_outcome ]

type next_action = {
  arguments : string list;
  explanation : string;
  applicable : bool;
  confirmation_required : bool;
}

type domain_details = {
  domain_outcome : outcome;
  domain_code : string;
  domain_message : string;
  domain_data : Yojson.Safe.t;
  domain_actions : next_action list;
  operation_id : string option;
  plan_id : string option;
}

type envelope = {
  command_value : string;
  ok_value : bool;
  result_value : Yojson.Safe.t option;
  warnings_value : string list;
  error_value : command_error option;
  domain_value : domain_details option;
}

let schema_version = 1
let domain_schema_version = 2

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
        domain_value = None;
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
          domain_value = None;
        }

let command envelope = envelope.command_value
let ok envelope = envelope.ok_value
let result envelope = envelope.result_value
let warnings envelope = envelope.warnings_value
let error envelope = envelope.error_value

let outcome_string : outcome -> string = function
  | `Completed -> "completed"
  | `Unchanged -> "unchanged"
  | `Incomplete -> "incomplete"
  | `Invalid -> "invalid"
  | `Choice_required -> "choice-required"
  | `Conflict -> "conflict"
  | `Unavailable -> "unavailable"
  | `Integrity_failure -> "integrity-failure"
  | `Blocked -> "blocked"
  | `Interrupted -> "interrupted"
  | `Failed -> "failed"

let action_json action =
  `Assoc
    [
      ( "arguments",
        `List (List.map (fun value -> `String value) action.arguments) );
      ("explanation", `String action.explanation);
      ("applicable", `Bool action.applicable);
      ("confirmation_required", `Bool action.confirmation_required);
    ]

let check_actions actions =
  if List.length actions > 1024 then Error "too many CLI next actions"
  else if
    List.for_all
      (fun action ->
        valid_text action.explanation
        && action.arguments <> []
        && List.hd action.arguments <> ""
        && List.length action.arguments <= 256
        && List.for_all
             (fun argument ->
               String.length argument <= 4096
               && not (String.contains argument '\000'))
             action.arguments)
      actions
  then Ok ()
  else Error "invalid CLI next action"

let domain_details ?operation_id ?plan_id ~outcome ~code ~message ~data
    ~next_actions () =
  let valid_id = Option.fold ~none:true ~some:valid_text in
  match (check_result data, check_actions next_actions) with
  | Ok (), Ok ()
    when valid_error_code code && valid_text message && valid_id operation_id
         && valid_id plan_id ->
      {
        domain_outcome = outcome;
        domain_code = code;
        domain_message = message;
        domain_data = data;
        domain_actions = next_actions;
        operation_id;
        plan_id;
      }
  | Ok (), Ok () | Error _, (Ok () | Error _) | Ok (), Error _ ->
      invalid_arg "invalid CLI domain outcome"

let domain_success ?operation_id ?plan_id ~command ~(outcome : success_outcome)
    ~code ~message ~data ~warnings ~next_actions () =
  let legacy = success ~command ~result:data ~warnings in
  let details =
    domain_details ?operation_id ?plan_id
      ~outcome:(outcome :> outcome)
      ~code ~message ~data ~next_actions ()
  in
  { legacy with domain_value = Some details }

let domain_failure ?operation_id ?plan_id ~command ~(outcome : failure_outcome)
    ~error ~data ~warnings ~next_actions () =
  let legacy = failure ~command ~error ~warnings in
  let details =
    domain_details ?operation_id ?plan_id
      ~outcome:(outcome :> outcome)
      ~code:error.code ~message:error.message ~data ~next_actions ()
  in
  { legacy with domain_value = Some details }

let version envelope =
  match envelope.domain_value with
  | None -> schema_version
  | Some _ -> domain_schema_version

let outcome envelope =
  Option.map (fun details -> details.domain_outcome) envelope.domain_value

let data envelope =
  match envelope.domain_value with
  | Some details -> Some details.domain_data
  | None -> envelope.result_value

let next_actions envelope =
  Option.fold ~none:[]
    ~some:(fun details -> details.domain_actions)
    envelope.domain_value

let encode envelope =
  let result = Option.value ~default:`Null envelope.result_value in
  let error =
    match envelope.error_value with
    | None -> `Null
    | Some { code; message } ->
        `Assoc [ ("code", `String code); ("message", `String message) ]
  in
  let warnings =
    `List (List.map (fun warning -> `String warning) envelope.warnings_value)
  in
  let fields =
    match envelope.domain_value with
    | None ->
        [
          ("schema_version", `Int schema_version);
          ("command", `String envelope.command_value);
          ("ok", `Bool envelope.ok_value);
          ("result", result);
          ("warnings", warnings);
          ("error", error);
        ]
    | Some details ->
        [
          ("schema_version", `Int domain_schema_version);
          ("command", `String envelope.command_value);
          ("outcome", `String (outcome_string details.domain_outcome));
          ("code", `String details.domain_code);
          ("message", `String details.domain_message);
          ("data", details.domain_data);
          ("warnings", warnings);
          ("next_actions", `List (List.map action_json details.domain_actions));
          ("ok", `Bool envelope.ok_value);
          ("result", result);
          ("error", error);
        ]
        @ Option.fold ~none:[]
            ~some:(fun value -> [ ("operation_id", `String value) ])
            details.operation_id
        @ Option.fold ~none:[]
            ~some:(fun value -> [ ("plan_id", `String value) ])
            details.plan_id
  in
  `Assoc fields |> Yojson.Safe.to_string

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

let decode_legacy bytes =
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
              domain_value = None;
            }
      | _ -> Error "CLI envelope success and error fields disagree")
  | `Assoc _ -> Error "CLI envelope has unknown or duplicate fields"
  | _ -> Error "CLI envelope must be an object"

let outcome_of_string = function
  | "completed" -> Ok `Completed
  | "unchanged" -> Ok `Unchanged
  | "incomplete" -> Ok `Incomplete
  | "invalid" -> Ok `Invalid
  | "choice-required" -> Ok `Choice_required
  | "conflict" -> Ok `Conflict
  | "unavailable" -> Ok `Unavailable
  | "integrity-failure" -> Ok `Integrity_failure
  | "blocked" -> Ok `Blocked
  | "interrupted" -> Ok `Interrupted
  | "failed" -> Ok `Failed
  | _ -> Error "unsupported CLI outcome"

let bool_field name fields =
  let* value = field name fields in
  match value with
  | `Bool value -> Ok value
  | _ -> Error ("CLI field " ^ name ^ " must be boolean")

let actions_field fields =
  let* value = field "next_actions" fields in
  match value with
  | `List actions ->
      let* actions =
        List.fold_left
          (fun result -> function
            | `Assoc fields
              when exactly_fields
                     [
                       "arguments";
                       "explanation";
                       "applicable";
                       "confirmation_required";
                     ]
                     fields ->
                let* actions = result in
                let* arguments = field "arguments" fields in
                let* arguments =
                  match arguments with
                  | `List values ->
                      List.fold_left
                        (fun result -> function
                          | `String value ->
                              let* values = result in
                              Ok (value :: values)
                          | _ -> Error "CLI action arguments must be strings")
                        (Ok []) values
                      |> Result.map List.rev
                  | _ -> Error "CLI action arguments must be an array"
                in
                let* explanation = string_field "explanation" fields in
                let* applicable = bool_field "applicable" fields in
                let* confirmation_required =
                  bool_field "confirmation_required" fields
                in
                Ok
                  ({ arguments; explanation; applicable; confirmation_required }
                  :: actions)
            | _ -> Error "invalid CLI action fields")
          (Ok []) actions
        |> Result.map List.rev
      in
      let* () = check_actions actions in
      Ok actions
  | _ -> Error "CLI next_actions must be an array"

let optional_id name fields =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`String value) when valid_text value -> Ok (Some value)
  | Some _ -> Error ("invalid CLI " ^ name)

let decode_domain fields =
  let legacy_names =
    [ "schema_version"; "command"; "ok"; "result"; "warnings"; "error" ]
  in
  let required =
    legacy_names @ [ "outcome"; "code"; "message"; "data"; "next_actions" ]
  in
  let optional =
    List.filter
      (fun name -> List.mem_assoc name fields)
      [ "operation_id"; "plan_id" ]
  in
  if not (exactly_fields (required @ optional) fields) then
    Error "CLI domain envelope has unknown or duplicate fields"
  else
    let legacy_fields =
      List.filter (fun (name, _) -> List.mem name legacy_names) fields
      |> List.map (fun (name, value) ->
          (name, if name = "schema_version" then `Int schema_version else value))
    in
    let* legacy =
      decode_legacy (Yojson.Safe.to_string (`Assoc legacy_fields))
    in
    let* outcome = string_field "outcome" fields in
    let* outcome = outcome_of_string outcome in
    let* code = string_field "code" fields in
    let* message = string_field "message" fields in
    let* data = field "data" fields in
    let* () = check_result data in
    let* actions = actions_field fields in
    let* operation_id = optional_id "operation_id" fields in
    let* plan_id = optional_id "plan_id" fields in
    let* () =
      if valid_error_code code && valid_text message then Ok ()
      else Error "invalid CLI domain code/message"
    in
    let* () =
      match (legacy.ok_value, outcome) with
      | true, (`Completed | `Unchanged | `Incomplete)
      | ( false,
          ( `Invalid | `Choice_required | `Conflict | `Unavailable
          | `Integrity_failure | `Blocked | `Interrupted | `Incomplete | `Failed
            ) ) ->
          Ok ()
      | _ -> Error "CLI domain outcome disagrees with success"
    in
    let* () =
      if legacy.ok_value then
        if legacy.result_value = Some data then Ok ()
        else Error "CLI result/data aliases disagree"
      else
        match legacy.error_value with
        | Some error when error.code = code && error.message = message -> Ok ()
        | None | Some _ -> Error "CLI error/code aliases disagree"
    in
    Ok
      {
        legacy with
        domain_value =
          Some
            {
              domain_outcome = outcome;
              domain_code = code;
              domain_message = message;
              domain_data = data;
              domain_actions = actions;
              operation_id;
              plan_id;
            };
      }

let decode bytes =
  let* json =
    try Ok (Yojson.Safe.from_string bytes)
    with Yojson.Json_error message -> Error ("invalid CLI JSON: " ^ message)
  in
  match json with
  | `Assoc fields
    when List.assoc_opt "schema_version" fields
         = Some (`Int domain_schema_version) ->
      decode_domain fields
  | _ -> decode_legacy bytes
