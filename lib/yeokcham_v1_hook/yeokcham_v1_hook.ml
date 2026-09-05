module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

type event =
  | Init
  | Save
  | Restore
  | Workspace_activate
  | Workspace_update
  | Draft_new
  | Share
  | Withdraw
  | Resolve
  | Deliver
  | Pin
  | Unpin
  | Compact

type hook = { id_value : string; event_value : event; argv_value : string list }
type registry = { hooks_value : hook list }

type error =
  | Invalid_id of string
  | Invalid_argv of string
  | Duplicate_hook of string
  | Unknown_hook of string
  | Unsupported_version of int64
  | Invalid_encoding of string
  | Noncanonical_encoding

let schema_version = 1L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_id value -> "invalid V1 hook ID: " ^ value
  | Invalid_argv value -> "invalid V1 hook argv: " ^ value
  | Duplicate_hook value -> "V1 hook already exists: " ^ value
  | Unknown_hook value -> "V1 hook does not exist: " ^ value
  | Unsupported_version value ->
      Printf.sprintf "unsupported V1 hooks version: %Ld" value
  | Invalid_encoding value -> "invalid V1 hooks encoding: " ^ value
  | Noncanonical_encoding -> "V1 hooks bytes are noncanonical"

let event_to_string = function
  | Init -> "init"
  | Save -> "save"
  | Restore -> "restore"
  | Workspace_activate -> "workspace-activate"
  | Workspace_update -> "workspace-update"
  | Draft_new -> "draft-new"
  | Share -> "share"
  | Withdraw -> "withdraw"
  | Resolve -> "resolve"
  | Deliver -> "deliver"
  | Pin -> "pin"
  | Unpin -> "unpin"
  | Compact -> "compact"

let event_of_string = function
  | "init" -> Ok Init
  | "save" -> Ok Save
  | "restore" -> Ok Restore
  | "workspace-activate" -> Ok Workspace_activate
  | "workspace-update" -> Ok Workspace_update
  | "draft-new" -> Ok Draft_new
  | "share" -> Ok Share
  | "withdraw" -> Ok Withdraw
  | "resolve" -> Ok Resolve
  | "deliver" -> Ok Deliver
  | "pin" -> Ok Pin
  | "unpin" -> Ok Unpin
  | "compact" -> Ok Compact
  | value -> Error (Invalid_encoding ("unknown hook event: " ^ value))

let valid_text value =
  String.length value > 0
  && String.length value <= 4096
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          value)

let valid_argv = function
  | [] -> Error (Invalid_argv "argv is empty")
  | program :: arguments ->
      if not (String.starts_with ~prefix:"/" program) then
        Error (Invalid_argv "program must be an absolute path")
      else if
        List.length arguments > 255
        || not (List.for_all valid_text (program :: arguments))
      then Error (Invalid_argv "argv contains an invalid value")
      else Ok ()

let hex_of_raw raw =
  let alphabet = "0123456789abcdef" in
  let output = Bytes.create (String.length raw * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set output (index * 2) alphabet.[value lsr 4];
      Bytes.set output ((index * 2) + 1) alphabet.[value land 0x0f])
    raw;
  Bytes.unsafe_to_string output

let raw_of_hex value =
  let nibble = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (10 + Char.code character - Char.code 'a')
    | _ -> None
  in
  if String.length value <> 64 then None
  else
    let raw = Bytes.create 32 in
    let rec loop offset =
      if offset = 64 then Some (Bytes.unsafe_to_string raw)
      else
        match (nibble value.[offset], nibble value.[offset + 1]) with
        | Some high, Some low ->
            Bytes.set raw (offset / 2) (Char.chr ((high lsl 4) lor low));
            loop (offset + 2)
        | None, _ | _, None -> None
    in
    loop 0

let valid_id value = Option.is_some (raw_of_hex value)

let array values =
  match Encoding.array values with Ok value -> value | Error _ -> assert false

let text value =
  match Encoding.text value with Ok value -> value | Error _ -> assert false

let entry_value ~event ~argv =
  array [ text (event_to_string event); array (List.map text argv) ]

let id_of ~event ~argv =
  Hash.feed_string Hash.empty "yeokcham:v1:hook:v1\000" |> fun context ->
  Hash.feed_string context (Encoding.encode (entry_value ~event ~argv))
  |> Hash.get |> Hash.to_raw_string |> hex_of_raw

let make ~event ~argv =
  let* () = valid_argv argv in
  Ok { id_value = id_of ~event ~argv; event_value = event; argv_value = argv }

let hook_id hook = hook.id_value
let hook_event hook = hook.event_value
let hook_argv hook = hook.argv_value
let empty = { hooks_value = [] }
let hooks registry = registry.hooks_value
let compare_hook left right = String.compare left.id_value right.id_value
let normalized hooks = List.sort compare_hook hooks

let add registry hook =
  if
    List.exists
      (fun existing -> String.equal existing.id_value hook.id_value)
      registry.hooks_value
  then Error (Duplicate_hook hook.id_value)
  else Ok { hooks_value = normalized (hook :: registry.hooks_value) }

let remove registry ~id =
  if not (valid_id id) then Error (Invalid_id id)
  else
    match
      List.partition
        (fun hook -> String.equal hook.id_value id)
        registry.hooks_value
    with
    | [], _ -> Error (Unknown_hook id)
    | [ _ ], remaining -> Ok { hooks_value = remaining }
    | _ -> assert false

let encode_entry hook =
  let raw = Option.get (raw_of_hex hook.id_value) in
  array
    [
      Encoding.bytes raw;
      text (event_to_string hook.event_value);
      array (List.map text hook.argv_value);
    ]

let encode registry =
  array
    [
      Encoding.integer schema_version;
      array (List.map encode_entry registry.hooks_value);
    ]
  |> Encoding.encode

let[@warning "-4"] values name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | _ -> Error (Invalid_encoding (Printf.sprintf "%s has the wrong shape" name))

let[@warning "-4"] parse_text name = function
  | Encoding.Text value when valid_text value -> Ok value
  | Encoding.Text _ -> Error (Invalid_encoding (name ^ " is invalid"))
  | _ -> Error (Invalid_encoding (name ^ " must be text"))

let[@warning "-4"] parse_id = function
  | Encoding.Bytes raw when String.length raw = 32 -> Ok (hex_of_raw raw)
  | Encoding.Bytes _ -> Error (Invalid_encoding "hook ID must be 32 bytes")
  | _ -> Error (Invalid_encoding "hook ID must be bytes")

let[@warning "-4"] parse_argv = function
  | Encoding.Array values ->
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* value = parse_text "hook argv" value in
            loop (value :: reversed) rest
      in
      loop [] values
  | _ -> Error (Invalid_encoding "hook argv must be an array")

let parse_entry = function
  | value -> (
      let* values = values "hook" 3 value in
      match values with
      | [ id; event; argv ] ->
          let* id = parse_id id in
          let* event = parse_text "hook event" event in
          let* event = event_of_string event in
          let* argv = parse_argv argv in
          let* hook = make ~event ~argv in
          if String.equal id hook.id_value then Ok hook
          else Error (Invalid_encoding "hook ID does not match its argv")
      | _ -> assert false)

let[@warning "-4"] decode input =
  let* value =
    Encoding.decode input
    |> Result.map_error (fun error ->
        Invalid_encoding (Encoding.decode_error_to_string error))
  in
  let* fields = values "hooks" 2 value in
  match fields with
  | [ Encoding.Integer version; entries ] ->
      if not (Int64.equal version schema_version) then
        Error (Unsupported_version version)
      else
        let* entries =
          match entries with
          | Encoding.Array entries -> Ok entries
          | _ -> Error (Invalid_encoding "hook entries must be an array")
        in
        let* registry =
          List.fold_left
            (fun result entry ->
              let* registry = result in
              let* hook = parse_entry entry in
              add registry hook)
            (Ok empty) entries
        in
        if String.equal input (encode registry) then Ok registry
        else Error Noncanonical_encoding
  | [ _; _ ] -> Error (Invalid_encoding "hooks version must be an integer")
  | _ -> assert false
