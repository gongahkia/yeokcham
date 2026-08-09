module Service = Yeokcham_local_service

type command =
  | Init
  | Archive of { archive_name : string }
  | Reset of { archive_name : string }

type parse_error = Invalid_arguments

type response =
  | Initialized
  | Already_initialized
  | Init_refused of Service.root_availability
  | Archived of Service.archive_outcome
  | Reset_completed
  | Already_reset

let parse_reset arguments =
  let rec loop archive_name confirmed = function
    | [] -> (
        match (archive_name, confirmed) with
        | Some archive_name, true -> Ok (Reset { archive_name })
        | None, _ | Some _, false -> Error Invalid_arguments)
    | "--archive" :: name :: rest when Option.is_none archive_name ->
        loop (Some name) confirmed rest
    | "--confirm-v2-reset" :: rest when not confirmed ->
        loop archive_name true rest
    | _ -> Error Invalid_arguments
  in
  loop None false arguments

let parse ~name ~arguments =
  match (name, arguments) with
  | "init", [] -> Ok Init
  | "archive", [ "--name"; archive_name ] -> Ok (Archive { archive_name })
  | "reset", arguments -> parse_reset arguments
  | _ -> Error Invalid_arguments

let execute ~root = function
  | Init ->
      Service.initialize ~root
      |> Result.map (function
        | Service.Initialized -> Initialized
        | Service.Already_initialized -> Already_initialized
        | Service.Init_refused availability -> Init_refused availability)
  | Archive { archive_name } ->
      Service.archive ~root ~archive_name
      |> Result.map (fun result -> Archived result)
  | Reset { archive_name } ->
      Service.reset ~root ~archive_name ~confirm:true
      |> Result.map (function
        | Service.Reset -> Reset_completed
        | Service.Already_reset -> Already_reset)

let render = function
  | Initialized -> "initialized empty V2 repository"
  | Already_initialized -> "V2 repository is already initialized"
  | Init_refused Service.Legacy ->
      "legacy repository detected; init will not overwrite it. Run `yeokcham \
       archive --name <archive-name>` first."
  | Init_refused (Service.Mixed_or_unknown detail) ->
      "init refused mixed or unknown repository state: " ^ detail
  | Init_refused (Service.Incomplete detail) ->
      "init refused incomplete repository state: " ^ detail
  | Init_refused (Service.V2_ready | Service.Uninitialized) ->
      "init reached an invalid root state"
  | Archived outcome ->
      let prefix =
        if outcome.Service.already_archived then "already-archived"
        else "archived"
      in
      Printf.sprintf "%s=%s manifest=%s" prefix outcome.Service.archive_path
        outcome.Service.manifest_path
  | Reset_completed -> "initialized empty V2 repository after verified archive"
  | Already_reset ->
      "V2 repository is already initialized; archive remains verified"

let parse_error_to_string = function
  | Invalid_arguments -> "invalid command arguments"
