module Relay = Yeokcham_v1_relay

type log_level = Error_log | Warn | Info | Debug

type t = {
  storage_root : string;
  listen : string;
  health_listen : string;
  metrics_listen : string;
  credential_registry_root : string;
  project_quota_bytes : int;
  session_expiry_seconds : int;
  log_level : log_level;
}

type error =
  | Invalid_syntax of string
  | Unknown_key of string
  | Duplicate_key of string
  | Missing_key of string
  | Invalid_value of { key : string; value : string }
  | Noncanonical
  | Io_error of { path : string; operation : string; message : string }

let schema_version = 1
let max_expiry_seconds = 86_400
let max_path_length = 4096
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_syntax line -> "invalid relay-config-v1 syntax: " ^ line
  | Unknown_key key -> "unknown relay-config-v1 key: " ^ key
  | Duplicate_key key -> "duplicate relay-config-v1 key: " ^ key
  | Missing_key key -> "missing relay-config-v1 key: " ^ key
  | Invalid_value { key; value } ->
      Printf.sprintf "invalid relay-config-v1 value for %s: %s" key value
  | Noncanonical -> "relay-config-v1 is not canonical"
  | Io_error { path; operation; message } ->
      Printf.sprintf "relay config %s %s: %s" operation path message

let default =
  {
    storage_root = "/var/lib/yeokcham-relay";
    listen = "127.0.0.1:8080";
    health_listen = "127.0.0.1:8081";
    metrics_listen = "127.0.0.1:9090";
    credential_registry_root = "/var/lib/yeokcham-relay";
    project_quota_bytes = Relay.V2.default_project_quota_bytes;
    session_expiry_seconds = Int64.to_int Relay.V2.default_expiry_seconds;
    log_level = Info;
  }

let storage_root value = value.storage_root
let listen value = value.listen
let health_listen value = value.health_listen
let metrics_listen value = value.metrics_listen
let credential_registry_root value = value.credential_registry_root
let project_quota_bytes value = value.project_quota_bytes
let session_expiry_seconds value = value.session_expiry_seconds
let log_level value = value.log_level

let has_unsafe_character value =
  String.exists
    (function '\000' | '\r' | '\n' | '\t' -> true | _ -> false)
    value

let valid_path value =
  String.length value > 1
  && String.length value <= max_path_length
  && String.starts_with ~prefix:"/" value
  && (not (has_unsafe_character value))
  && not (List.mem ".." (String.split_on_char '/' value))

let valid_ipv1_host value =
  match String.split_on_char '.' value with
  | [ a; b; c; d ] ->
      List.for_all
        (fun part ->
          String.length part > 0
          && String.for_all
               (fun character -> character >= '0' && character <= '9')
               part
          &&
          match int_of_string_opt part with
          | Some number -> number >= 0 && number <= 255
          | None -> false)
        [ a; b; c; d ]
  | _ -> false

let valid_listen value =
  (not (has_unsafe_character value))
  &&
  match String.split_on_char ':' value with
  | [ host; port ] -> (
      match int_of_string_opt port with
      | Some number -> valid_ipv1_host host && number > 0 && number <= 65_535
      | None -> false)
  | _ -> false

let log_level_to_string = function
  | Error_log -> "error"
  | Warn -> "warn"
  | Info -> "info"
  | Debug -> "debug"

let log_level_of_string = function
  | "error" -> Ok Error_log
  | "warn" -> Ok Warn
  | "info" -> Ok Info
  | "debug" -> Ok Debug
  | value -> Error (Invalid_value { key = "log_level"; value })

let create ~storage_root ~listen ~health_listen ~metrics_listen
    ~credential_registry_root ~project_quota_bytes ~session_expiry_seconds
    ~log_level =
  if not (valid_path storage_root) then
    Error (Invalid_value { key = "storage_root"; value = storage_root })
  else if not (valid_path credential_registry_root) then
    Error
      (Invalid_value
         { key = "credential_registry_root"; value = credential_registry_root })
  else if not (valid_listen listen) then
    Error (Invalid_value { key = "listen"; value = listen })
  else if not (valid_listen health_listen) then
    Error (Invalid_value { key = "health_listen"; value = health_listen })
  else if not (valid_listen metrics_listen) then
    Error (Invalid_value { key = "metrics_listen"; value = metrics_listen })
  else if
    String.equal listen health_listen
    || String.equal listen metrics_listen
    || String.equal health_listen metrics_listen
  then Error (Invalid_value { key = "listen"; value = "listeners must differ" })
  else if
    project_quota_bytes <= 0
    || project_quota_bytes > Relay.V2.max_project_quota_bytes
  then
    Error
      (Invalid_value
         {
           key = "project_quota_bytes";
           value = string_of_int project_quota_bytes;
         })
  else if
    session_expiry_seconds <= 0 || session_expiry_seconds > max_expiry_seconds
  then
    Error
      (Invalid_value
         {
           key = "session_expiry_seconds";
           value = string_of_int session_expiry_seconds;
         })
  else
    Ok
      {
        storage_root;
        listen;
        health_listen;
        metrics_listen;
        credential_registry_root;
        project_quota_bytes;
        session_expiry_seconds;
        log_level;
      }

let fields value =
  [
    ("version", string_of_int schema_version);
    ("storage_root", value.storage_root);
    ("listen", value.listen);
    ("health_listen", value.health_listen);
    ("metrics_listen", value.metrics_listen);
    ("credential_registry_root", value.credential_registry_root);
    ("project_quota_bytes", string_of_int value.project_quota_bytes);
    ("session_expiry_seconds", string_of_int value.session_expiry_seconds);
    ("log_level", log_level_to_string value.log_level);
  ]

let encode value =
  fields value
  |> List.map (fun (key, field) -> key ^ "=" ^ field ^ "\n")
  |> String.concat ""

let known_keys =
  [
    "version";
    "storage_root";
    "listen";
    "health_listen";
    "metrics_listen";
    "credential_registry_root";
    "project_quota_bytes";
    "session_expiry_seconds";
    "log_level";
  ]

let parse_line line =
  match String.split_on_char '=' line with
  | [ key; value ]
    when String.length key > 0
         && String.length value > 0
         && not (String.exists (fun character -> character = ' ') key) ->
      Ok (key, value)
  | _ -> Error (Invalid_syntax line)

let entries bytes =
  if String.length bytes = 0 || not (String.ends_with ~suffix:"\n" bytes) then
    Error (Invalid_syntax "configuration must end in one newline")
  else
    let lines =
      String.sub bytes 0 (String.length bytes - 1) |> String.split_on_char '\n'
    in
    let rec loop seen reversed = function
      | [] -> Ok (List.rev reversed)
      | line :: rest ->
          let* key, value = parse_line line in
          if not (List.mem key known_keys) then Error (Unknown_key key)
          else if List.mem key seen then Error (Duplicate_key key)
          else loop (key :: seen) ((key, value) :: reversed) rest
    in
    loop [] [] lines

let required entries key =
  match List.assoc_opt key entries with
  | Some value -> Ok value
  | None -> Error (Missing_key key)

let decimal key value =
  if
    String.length value = 0
    || not
         (String.for_all
            (fun character -> character >= '0' && character <= '9')
            value)
  then Error (Invalid_value { key; value })
  else
    match int_of_string_opt value with
    | Some number -> Ok number
    | None -> Error (Invalid_value { key; value })

let of_entries entries =
  let* version = required entries "version" in
  let* version = decimal "version" version in
  if version <> schema_version then
    Error (Invalid_value { key = "version"; value = string_of_int version })
  else
    let* storage_root = required entries "storage_root" in
    let* listen = required entries "listen" in
    let* health_listen = required entries "health_listen" in
    let* metrics_listen = required entries "metrics_listen" in
    let* credential_registry_root =
      required entries "credential_registry_root"
    in
    let* quota = required entries "project_quota_bytes" in
    let* project_quota_bytes = decimal "project_quota_bytes" quota in
    let* expiry = required entries "session_expiry_seconds" in
    let* session_expiry_seconds = decimal "session_expiry_seconds" expiry in
    let* log_level_value = required entries "log_level" in
    let* log_level = log_level_of_string log_level_value in
    create ~storage_root ~listen ~health_listen ~metrics_listen
      ~credential_registry_root ~project_quota_bytes ~session_expiry_seconds
      ~log_level

let decode bytes =
  let* parsed = entries bytes in
  let* value = of_entries parsed in
  if String.equal (encode value) bytes then Ok value else Error Noncanonical

let load ~path =
  try In_channel.with_open_bin path In_channel.input_all |> decode
  with Sys_error message ->
    Error (Io_error { path; operation = "read"; message })

let environment_key = function
  | "YEOKCHAM_RELAY_STORAGE_ROOT" -> Some "storage_root"
  | "YEOKCHAM_RELAY_LISTEN" -> Some "listen"
  | "YEOKCHAM_RELAY_HEALTH_LISTEN" -> Some "health_listen"
  | "YEOKCHAM_RELAY_METRICS_LISTEN" -> Some "metrics_listen"
  | "YEOKCHAM_RELAY_CREDENTIAL_REGISTRY_ROOT" -> Some "credential_registry_root"
  | "YEOKCHAM_RELAY_PROJECT_QUOTA_BYTES" -> Some "project_quota_bytes"
  | "YEOKCHAM_RELAY_SESSION_EXPIRY_SECONDS" -> Some "session_expiry_seconds"
  | "YEOKCHAM_RELAY_LOG_LEVEL" -> Some "log_level"
  | _ -> None

let override_environment value environment =
  let rec collect seen reversed = function
    | [] -> Ok (List.rev reversed)
    | (name, setting) :: rest -> (
        match environment_key name with
        | Some key when List.mem key seen -> Error (Duplicate_key name)
        | Some key -> collect (key :: seen) ((key, setting) :: reversed) rest
        | None when String.starts_with ~prefix:"YEOKCHAM_RELAY_" name ->
            Error (Unknown_key name)
        | None -> collect seen reversed rest)
  in
  let* overrides = collect [] [] environment in
  let updated =
    List.fold_left
      (fun current (key, setting) ->
        List.map
          (fun (current_key, current_value) ->
            if String.equal key current_key then (key, setting)
            else (current_key, current_value))
          current)
      (fields value) overrides
  in
  of_entries updated
