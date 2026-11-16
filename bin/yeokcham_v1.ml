module Journal = Yeokcham_v1_restore_journal
module History = Yeokcham_v1_undo
module Model = Yeokcham_v1_model
module Core = Model.Core
module Local = Yeokcham_v1_store.Local
module Store = Yeokcham_v1_store
module Service = Yeokcham_v1_local_service
module Text_diff = Service.Text_diff
module Trust = Yeokcham_v1_trust
module Package = Yeokcham_v1_package
module Bootstrap = Yeokcham_v1_bootstrap
module Inspection = Yeokcham_v1_inspection
module Gc = Yeokcham_v1_gc
module Proposal = Yeokcham_v1_proposal
module Recovery = Yeokcham_v1_recovery
module Custody = Yeokcham_v1_custody
module Runtime = V1_runtime
module Sync = Yeokcham_v1_sync
module Transport = Yeokcham_v1_transport
module Transport_config = Yeokcham_v1_transport_config
module Transport_credential = Yeokcham_v1_transport_credential
module Transport_http = Yeokcham_v1_transport_http
module Relay_http = Yeokcham_v1_relay_http
module Relay_access = Yeokcham_v1_relay_access
module Relay_config = Yeokcham_v1_relay_config
module Semantic_config = Yeokcham_v1_semantic_config
module Workspace = Yeokcham_v1_workspace
module Cli_data = Yeokcham_v1_cli_data
module Cli_spec = Yeokcham_v1_cli_spec
module Health = Yeokcham_v1_health
module Health_repository = Yeokcham_v1_health_repository
module Health_store = Yeokcham_v1_health_store
module Hook = Yeokcham_v1_hook
module Hook_runner = Yeokcham_v1_hook_runner
module Hook_store = Yeokcham_v1_hook_store
module Repair = Yeokcham_v1_repair
module Output = V1_cli_output
module Standard_printf = Printf

module Printf = struct
  include Standard_printf

  let printf format = Standard_printf.ksprintf Output.print_string format
end

let print_endline = Output.print_endline
let print_string = Output.print_string
let prerr_endline = Output.print_error

[@@@warning "-40-42"]

type requested_format = Text_format | Json_format

let raw_arguments () = Array.to_list Sys.argv

let detail_arguments () =
  let takes_value name =
    Cli_spec.option_specs () |> List.exists (fun option ->
        option.Cli_spec.option_name = name && option.Cli_spec.option_value <> Cli_spec.Flag)
  in
  let rec scan count reversed = function
    | "--" :: rest -> (List.rev_append reversed ("--" :: rest),count)
    | "--details" :: rest -> scan (count + 1) reversed rest
    | name :: value :: rest when takes_value name -> scan count (value :: name :: reversed) rest
    | value :: rest -> scan count (value :: reversed) rest
    | [] -> (List.rev reversed,count)
  in
  scan 0 [] (raw_arguments ())

let requested_details () = snd (detail_arguments ()) > 0

let rec legacy_share_arguments = function
  | [] | "--" :: _ -> false
  | ("--change" | "--revision") :: _ -> true
  | ("--root" | "--title" | "--update" | "--authority" | "--format" | "--color")
    :: _ :: rest ->
      legacy_share_arguments rest
  | _ :: rest -> legacy_share_arguments rest

let rec legacy_resolve_arguments = function
  | [] | "--" :: _ -> false
  | "--decision" :: _ -> true
  | ("--root" | "--plan" | "--use" | "--file" | "--format" | "--color")
    :: _ :: rest ->
      legacy_resolve_arguments rest
  | _ :: rest -> legacy_resolve_arguments rest

let requested_format () =
  let rec loop = function
    | "--" :: _ -> Text_format
    | "--format" :: "json" :: _ -> Json_format
    | "--format" :: "text" :: rest -> loop rest
    | _ :: rest -> loop rest
    | [] -> Text_format
  in
  loop (raw_arguments ())

let requested_color () =
  let rec loop selected = function
    | "--" :: _ -> Ok (Option.value selected ~default:Output.Auto)
    | "--color" :: value :: rest -> (
        match (selected, value) with
        | Some _, _ -> Error "--color may be specified only once"
        | None, "auto" -> loop (Some Output.Auto) rest
        | None, "always" -> loop (Some Output.Always) rest
        | None, "never" -> loop (Some Output.Never) rest
        | None, _ -> Error "--color must be auto, always, or never")
    | "--color" :: [] -> Error "--color requires auto, always, or never"
    | _ :: rest -> loop selected rest
    | [] -> Ok (Option.value selected ~default:Output.Auto)
  in
  loop None (raw_arguments ())

let command_arguments () =
  let rec loop before_separator reversed = function
    | "--" :: rest when before_separator ->
        List.rev_append reversed ("--" :: rest)
    | "--format" :: ("text" | "json") :: rest when before_separator ->
        loop true reversed rest
    | "--color" :: ("auto" | "always" | "never") :: rest when before_separator
      ->
        loop true reversed rest
    | argument :: rest -> loop before_separator (argument :: reversed) rest
    | [] -> List.rev reversed
  in
  loop true [] (fst (detail_arguments ()))

let rec is_prefix prefix values =
  match (prefix, values) with
  | [], _ -> true
  | left :: prefix, right :: values when String.equal left right ->
      is_prefix prefix values
  | _ -> false

let command_name () =
  match command_arguments () with
  | _ :: arguments -> (
      match
        Cli_spec.command_paths ()
        |> List.filter (fun path -> is_prefix path arguments)
        |> List.sort (fun left right ->
            Int.compare (List.length right) (List.length left))
      with
      | path :: _ -> String.concat "-" path
      | [] -> "cli")
  | [] -> "cli"

let native_json_command command =
  (command = "share" && not (legacy_share_arguments (raw_arguments ())))
  || (command = "resolve" && not (legacy_resolve_arguments (raw_arguments ())))
  || List.mem command
       [
         "status";
         "exchange";
         "clone";
         "integrate";
         "conflicts";
         "operation";
         "operation-show";
         "operation-resume";
         "operation-recover";
         "operation-forget";
         "history";
         "diff";
         "changes";
         "save";
         "ignore-explain";
         "branch";
         "branch-list";
         "branch-create";
         "switch";
         "restore";
         "verify";
         "repair-plan";
         "repair-apply";
         "repair-defer";
         "hook-list";
         "undo-tree";
         "undo";
         "redo";
       ]

let json_stdout_destination : Unix.file_descr option ref = ref None
let public_warnings : string list ref = ref []
let pending_domain_output : (unit -> unit) option ref = ref None

let record_warning warning =
  if requested_format () = Json_format then
    public_warnings := warning :: !public_warnings;
  Output.print_warning ("warning: " ^ warning)

let print_json bytes =
  match !json_stdout_destination with
  | None -> Output.print_raw_endline bytes
  | Some descriptor ->
      let output = Unix.out_channel_of_descr (Unix.dup descriptor) in
      Fun.protect
        ~finally:(fun () -> close_out_noerr output)
        (fun () ->
          Out_channel.output_string output bytes;
          Out_channel.output_char output '\n';
          Out_channel.flush output)

let domain_command command =
  (command = "share" && not (legacy_share_arguments (raw_arguments ())))
  || (command = "resolve" && not (legacy_resolve_arguments (raw_arguments ())))
  || List.mem command
       [
         "status";
         "exchange";
         "clone";
         "integrate";
         "conflicts";
         "operation";
         "operation-show";
         "operation-resume";
         "operation-recover";
         "operation-forget";
         "history";
         "diff";
         "changes";
         "save";
         "ignore-explain";
         "branch";
         "branch-list";
         "branch-create";
         "switch";
         "undo";
         "redo";
         "restore";
       ]

let local_failure_context :
    (unit -> Yojson.Safe.t * Cli_data.next_action list * string option) option
    ref =
  ref None

let public_error_message message =
  let first_line =
    match String.index_opt message '\n' with
    | Some index -> String.sub message 0 index
    | None -> message
  in
  let first_line = String.trim first_line in
  let first_line =
    if String.is_empty first_line then "Command failed" else first_line
  in
  let first_line =
    if
      Result.is_error (Yeokcham_encoding.text first_line)
      || String.exists
           (function '\000' | '\r' -> true | _ -> false)
           first_line
    then String.escaped first_line
    else first_line
  in
  if String.length first_line <= 4000 then first_line
  else
    let stop = ref 3997 in
    while !stop > 0 && Char.code first_line.[!stop] land 0xc0 = 0x80 do
      decr stop
    done;
    String.sub first_line 0 !stop ^ "..."

let failure_outcome = function
  | 2 -> `Invalid
  | 3 -> `Choice_required
  | 4 -> `Conflict
  | 5 -> `Unavailable
  | 6 -> `Integrity_failure
  | 7 -> `Blocked
  | 8 -> `Interrupted
  | _ -> `Failed

let fail_with_status status code message =
  (if requested_format () = Json_format then
     let command_label = command_name () in
     let error = Cli_data.{ code; message = public_error_message message } in
     let data, context_actions, operation_id =
       match !local_failure_context with
       | None -> (`Assoc [], [], None)
       | Some context -> (
           try context ()
           with _ ->
             ( `Assoc
                 [ ("recovery", `Assoc [ ("state", `String "unreadable") ]) ],
               [],
               None ))
     in
     (if domain_command command_label then
        Cli_data.domain_failure ?operation_id ~command:command_label
          ~outcome:(failure_outcome status) ~error ~data ~warnings:[]
          ~next_actions:
            (if context_actions <> [] then context_actions
             else
               [
                 Cli_data.
                   {
                     arguments =
                       [ "yeokcham"; "help" ]
                       @ String.split_on_char '-' command_label;
                     explanation =
                       "Inspect supported arguments and recovery boundaries.";
                     applicable = true;
                     confirmation_required = false;
                   };
               ])
          ()
      else Cli_data.failure ~command:command_label ~warnings:[] ~error)
     |> Cli_data.encode |> print_json);
  prerr_endline message;
  exit status

let domain_json ?operation_id ?plan_id ~outcome ~code ~message ~data
    ~next_actions () =
  let emit () =
    Cli_data.domain_success ?operation_id ?plan_id ~command:(command_name ())
      ~outcome ~code ~message ~data
      ~warnings:(List.rev !public_warnings)
      ~next_actions ()
    |> Cli_data.encode |> print_json
  in
  match !pending_domain_output with
  | None -> pending_domain_output := Some emit
  | Some _ -> invalid_arg "multiple domain results for one command"

let flush_domain_output () =
  let pending = !pending_domain_output in
  pending_domain_output := None;
  Option.iter (fun emit -> emit ()) pending

let append_before_literal arguments extra =
  let rec loop reversed = function
    | [] -> List.rev reversed @ extra
    | "--" :: rest -> List.rev reversed @ extra @ ("--" :: rest)
    | value :: rest -> loop (value :: reversed) rest
  in
  loop [] arguments

let action ?(confirmation_required = false) ~root arguments explanation =
  let root_representable = Result.is_ok (Yeokcham_encoding.text root) in
  let arguments_representable =
    List.for_all
      (fun argument -> Result.is_ok (Yeokcham_encoding.text argument))
      arguments
  in
  let action_arguments =
    "yeokcham"
    ::
    (if root_representable then
       append_before_literal arguments [ "--root"; root ]
     else arguments)
  in
  let action_arguments =
    List.map
      (fun argument ->
        if Result.is_ok (Yeokcham_encoding.text argument) then argument
        else String.escaped argument)
      action_arguments
  in
  let explanation =
    explanation
    ^ (if root_representable then ""
       else
         " Run this from the inspected workspace; its root path is not UTF-8.")
    ^
    if arguments_representable then ""
    else
      " Non-UTF-8 arguments are escaped display values; supply their original \
       bytes using the exact path bytes in data."
  in
  Cli_data.
    {
      arguments = action_arguments;
      explanation;
      applicable = root_representable && arguments_representable;
      confirmation_required;
    }

let[@warning "-4"] fail_local = function
  | Service.History_error message
    when String.starts_with ~prefix:"clone is incomplete" message ->
      fail_with_status 8 "clone-incomplete" message
  | Service.Share_error (Service.Share.Invalid message) ->
      fail_with_status 2 "invalid-share" message
  | Service.Share_error (Service.Share.Choice message) ->
      fail_with_status 3 "share-choice-required" message
  | Service.Share_error (Service.Share.Policy message) ->
      fail_with_status 7 "share-authority-blocked" message
  | Service.Share_error
      (Service.Share.Content (Yeokcham_v1_composition.Invalid_input message)) ->
      fail_with_status 2 "invalid-share-selection" message
  | Service.Share_error
      (Service.Share.Content (Yeokcham_v1_composition.Conflicts paths)) ->
      fail_with_status 4 "share-selection-conflict"
        ("Selected paths require a decision: "
        ^ String.concat ", " (List.map (String.concat "/") paths))
  | Service.Share_error
      (Service.Share.Content (Yeokcham_v1_composition.Unavailable message)) ->
      fail_with_status 5 "share-content-unavailable" message
  | Service.History_error message
    when String.starts_with ~prefix:"choose a redo branch" message
         || String.starts_with ~prefix:"choose a recovery operation" message ->
      fail_with_status 3 "selection-choice-required" message
  | Service.History_error message
    when String.starts_with ~prefix:"already at a history root" message
         || String.starts_with ~prefix:"there is no redo branch" message ->
      fail_with_status 3 "navigation-unavailable" message
  | Service.History_error message
    when String.starts_with ~prefix:"the selected redo node" message
         || String.starts_with ~prefix:"unknown restore operation" message ->
      fail_with_status 2 "invalid-selection" message
  | Service.History_error message
    when String.starts_with ~prefix:"working files have unsaved edits" message
    ->
      fail_with_status 4 "unsaved-work-conflict" message
  | Service.Selection_unavailable message ->
      fail_with_status 5 "selection-unavailable" message
  | Service.Selection_integrity message ->
      fail_with_status 6 "selection-integrity-failure" message
  | Service.History_error message
    when String.starts_with ~prefix:"unknown branch " message ->
      fail_with_status 2 "unknown-branch" message
  | Service.History_error message
    when String.starts_with ~prefix:"shared branch " message ->
      fail_with_status 3 "shared-branch-not-materialized" message
  | Service.History_error message
    when String.starts_with ~prefix:"private branch basis differs" message ->
      fail_with_status 3 "branch-integration-required" message
  | Service.History_error message
    when String.starts_with ~prefix:"branch has divergent" message
         || String.starts_with ~prefix:"branch name " message
            && String.ends_with ~suffix:"explicitly" message ->
      fail_with_status 3 "branch-choice-required" message
  | Service.History_error message
    when String.starts_with
           ~prefix:"branch creation inputs changed while signing" message ->
      fail_with_status 3 "branch-creation-stale" message
  | Service.History_error message
    when String.starts_with ~prefix:"local selection plan is stale" message
         || String.starts_with ~prefix:"working files changed after preview"
              message ->
      fail_with_status 3 "stale-selection-plan" message
  | Service.Selection_conflict message ->
      fail_with_status 4 "selection-conflict" message
  | Service.Safe_application_error message ->
      fail_with_status 8 "file-application-conflict" message
  | Service.Snapshot_error
      ( Yeokcham_snapshot.Invalid_ignore_rule _
      | Yeokcham_snapshot.Invalid_ignore_path _ ) as error ->
      fail_with_status 2 "invalid-ignore-rule" (Service.error_to_string error)
  | Service.Snapshot_error
      ( Yeokcham_snapshot.Scan_error _
      | Yeokcham_snapshot.Unsupported_file_type _
      | Yeokcham_snapshot.Observation_changed _
      | Yeokcham_snapshot.Capture_unstable _ ) as error ->
      fail_with_status 5 "capture-incomplete" (Service.error_to_string error)
  | Service.Snapshot_error
      (Yeokcham_snapshot.Store_error (Yeokcham_store.Io_error _)) as error ->
      fail_with_status 5 "content-unavailable" (Service.error_to_string error)
  | Service.Unknown_checkpoint _ as error ->
      fail_with_status 5 "state-not-retained" (Service.error_to_string error)
  | Service.History_error message
    when String.starts_with ~prefix:"a restore is incomplete" message ->
      fail_with_status 8 "recovery-pending" message
  | Service.History_error message
    when String.starts_with ~prefix:"history identity belongs" message
         || String.starts_with ~prefix:"unknown local history node" message ->
      fail_with_status 2 "invalid-state" message
  | Service.History_error "workspace history sequence is exhausted" ->
      fail_with_status 5 "history-sequence-exhausted"
        "The workspace history sequence is exhausted; its existing identities \
         were preserved."
  | Service.History_error message
    when String.starts_with ~prefix:"core identity entropy unavailable:" message
    ->
      fail_with_status 5 "identity-entropy-unavailable" message
  | Service.Trust_error _ as error ->
      fail_with_status 7 "authority-blocked" (Service.error_to_string error)
  | Service.Store_error (Yeokcham_v1_store.Trust_error _) as error ->
      fail_with_status 7 "authority-blocked" (Service.error_to_string error)
  | Service.Store_error
      (Yeokcham_v1_store.Store_error
         ( Yeokcham_store.Repository_not_initialized _
         | Yeokcham_store.Root_not_directory _ | Yeokcham_store.Io_error _ )) as
    error ->
      fail_with_status 5 "repository-unavailable"
        (Service.error_to_string error)
  | error ->
      fail_with_status 6 "local-operation-refused"
        (Service.error_to_string error)

let require_local = function
  | Ok value -> value
  | Error error -> fail_local error

let fail_with code message = fail_with_status 2 code message
let fail message = fail_with "operation-failed" message

let run_generic_json command action =
  if List.mem command [ "init"; "recovery-use" ] then
    fail_with "recovery-ceremony-requires-text"
      "this command displays a new recovery mnemonic exactly once; rerun with \
       --format text in a private terminal so you can record it offline";
  let saved_stdout = Unix.dup Unix.stdout in
  let restored = ref false in
  let restore () =
    if not !restored then (
      flush stdout;
      Unix.dup2 saved_stdout Unix.stdout;
      Unix.close saved_stdout;
      json_stdout_destination := None;
      restored := true)
  in
  json_stdout_destination := Some saved_stdout;
  public_warnings := [];
  try
    let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
    flush stdout;
    Unix.dup2 null Unix.stdout;
    Unix.close null;
    action ();
    restore ();
    Cli_data.success ~command
      ~result:(Cli_data.command_result_json Cli_data.Completed)
      ~warnings:(List.rev !public_warnings)
    |> Cli_data.encode |> print_json
  with error ->
    restore ();
    raise error

let usage_text =
  "usage: yeokcham [--color auto|always|never] COMMAND [OPTIONS]\n\n\
   commands:\n\
  \  yeokcham undo-tree [--root PATH]\n\
  \  yeokcham undo [--root PATH] [--to NODE] [--preview|--yes] [--plan ID]\n\
  \  yeokcham redo [--root PATH] [--node NODE] [--preview|--yes] [--plan ID]\n\
  \  yeokcham init [PATH] [--username NAME] [--draft ID] [--title TITLE]\n\
  \  yeokcham join [--root PATH] --username NAME --draft ID --title TITLE \\\n\
  \     --device ID --from PATH --verify-phrase \"TWELVE WORDS\"\n\
  \  yeokcham save [--root PATH]\n\
  \  yeokcham integrate [CHANGE...] [--all] [--preview|--yes] [--plan ID]\n\
  \  yeokcham conflicts [--plan ID] [--root PATH]\n\
  \  yeokcham resolve CONFLICT (--use VERSION|--file PATH|--defer) [--plan ID]\n\
  \  yeokcham operation show|resume ID [--root PATH]\n\
  \  yeokcham operation recover ID [--preview|--yes] [--plan ID] \
   [--keep-current] [--replan]\n\
  \  yeokcham operation forget ID [--preview|--yes] [--plan ID]\n\
  \  yeokcham branch list [--root PATH]\n\
  \  yeokcham branch create NAME [--root PATH]\n\
  \  yeokcham switch NAME [--root PATH] [--preview|--yes] [--plan ID]\n\
  \  yeokcham status [--root PATH]\n\
  \  yeokcham history [--root PATH] [--before SEQUENCE] [--limit 1-200] [--all]\n\
  \  yeokcham diff [STATE_A [STATE_B]] [--root PATH]\n\
  \  yeokcham ignore explain PATH [--root PATH]\n\
  \  yeokcham changes [--root PATH]\n\
  \  yeokcham log [--root PATH]\n\
  \  yeokcham graph [--root PATH] [--authority]\n\
  \  yeokcham daemon start [--root PATH]\n\
  \  yeokcham daemon status [--root PATH]\n\
  \  yeokcham daemon stop [--root PATH]\n\
  \  yeokcham daemon sync [--root PATH] REMOTE\n\
  \  yeokcham device create [--provider native]\n\
  \  yeokcham device create --provider pkcs11 --root PATH --module PATH \\\n\
  \     --token-label LABEL --key-label LABEL --key-id HEX\n\
  \  yeokcham device attach --root PATH --provider ssh-agent --public-key FILE\n\
  \  yeokcham device attach --root PATH --provider pkcs11 --module PATH \\\n\
  \     --token-label LABEL --key-id HEX --public-key HEX\n\
  \  yeokcham device custody [--root PATH] --device ID\n\
  \  yeokcham device show [--root PATH]\n\
  \  yeokcham device enroll [--root PATH] --device ID --public-key HEX \
   --username NAME [--administrator] [--parent EPOCH]\n\
  \  yeokcham device revoke [--root PATH] --device ID [--parent EPOCH]\n\
  \  yeokcham device rotate [--root PATH] --device ID --public-key HEX \
   [--parent EPOCH]\n\
  \  yeokcham authority heads [--root PATH]\n\
  \  yeokcham authority reconcile [--root PATH] --parents EPOCH,EPOCH[,EPOCH]\n\
  \  yeokcham recovery use [--root PATH] --package PATH --mnemonic \"TWENTY \
   FOUR WORDS\" --replacement ID --replaced ID --output PATH\n\
  \  yeokcham recovery refresh [--root PATH] --package PATH --mnemonic \
   \"TWENTY FOUR WORDS\" --output PATH\n\
  \  yeokcham user register [--root PATH] --device ID --username NAME\n\
  \  yeokcham timeline [--root PATH]\n\
  \  yeokcham restore STATE [--root PATH] [--to DIRECTORY] [--preview|--yes] \
   [--plan ID]\n\
  \  yeokcham restore --resume [--operation ID] [--preview|--yes]\n\
  \  yeokcham restore proofs [--root PATH]\n\
  \  yeokcham restore retain [--root PATH] --operation ID\n\
  \  yeokcham restore forget [--root PATH] --operation ID\n\
  \  yeokcham workspace activate [--root PATH]\n\
  \  yeokcham workspace update [--root PATH] [--replace]\n\
  \  yeokcham draft new [--root PATH] --id ID --title TITLE\n\
  \  yeokcham share [PATH...] [--root PATH] [--title TITLE] [--update CHANGE] \
   [--preview]\n\
  \  yeokcham withdraw [--root PATH] --change ID\n\
  \  yeokcham resolve [--root PATH] --decision ID --change ID --revision ID \
   [--tree PATH] [--authority EPOCH]\n\
  \  yeokcham decision show [--root PATH] --decision ID\n\
  \  yeokcham decision inspect [--root PATH] --decision ID\n\
  \  yeokcham decision diff [--root PATH] --decision ID --candidate REV \
   [--against base|REV]\n\
  \  yeokcham decision propose [--root PATH] --decision ID [--left REV --right \
   REV] [--semantic-server NAME]\n\
  \  yeokcham decision materialize-proposal [--root PATH] --decision ID --left \
   REV --right REV --destination PATH\n\
  \  yeokcham decision materialize [--root PATH] --decision ID --destination \
   PATH\n\
  \  yeokcham package create [--root PATH] --destination PATH\n\
  \  yeokcham package adopt [--root PATH] --from PATH --revision ID \
   [--authority EPOCH]\n\
  \  yeokcham receive [--root PATH] --from PATH [--review]\n\
  \  yeokcham bootstrap publish [--root PATH] REMOTE\n\
  \  yeokcham bootstrap [--root PATH] --remote NAME --url HTTPS_URL \
   --repository ID --basis ID --username NAME --draft ID --title TITLE \
   --device ID --verify-phrase \"TWELVE WORDS\"\n\
  \  receipt rule: receive, sync, and bootstrap never scan or materialize\n\
  \     the working tree; restore and workspace actions are explicit\n\
  \  yeokcham remote add [--root PATH] NAME URL\n\
  \  yeokcham remote remove [--root PATH] NAME\n\
  \  yeokcham remote login [--root PATH] NAME\n\
  \  yeokcham semantic server add [--root PATH] NAME --program ABS_PATH [--arg \
   VALUE]... [--match extensions|path-globs|all-files] [--extension EXT]... \
   [--glob PATTERN]... [--overlap same-symbol|nearby-ranges|references]\n\
  \  yeokcham semantic server list [--root PATH]\n\
  \  yeokcham semantic server configure [--root PATH] NAME --match \
   extensions|path-globs|all-files [--extension EXT]... [--glob PATTERN]... \
   --overlap same-symbol|nearby-ranges|references\n\
  \  yeokcham semantic server enable|disable|remove [--root PATH] NAME\n\
  \  yeokcham sync [--root PATH] NAME\n\
  \  yeokcham exchange [--root PATH] NAME [--format text|json]\n\
  \  yeokcham clone URL [DIRECTORY] --device ID --verify-phrase WORDS \
   [--branch NAME] [--preview] [--request ID] [--token-stdin]\n\
  \  yeokcham clone --resume DIRECTORY [--format text|json]\n\
  \  yeokcham relay serve --config PATH\n\
  \  yeokcham relay serve --storage PATH --listen ADDRESS:PORT\n\
  \  yeokcham relay access issue --storage PATH --repository ID --scope \
   read,write [--expires-in SECONDS]\n\
  \  yeokcham relay access rotate --storage PATH --id ID [--expires-in SECONDS]\n\
  \  yeokcham relay access revoke --storage PATH --id ID\n\
  \  yeokcham relay access list --storage PATH [--repository ID]\n\
  \  yeokcham deliver [--root PATH] --id ID --draft ID --title TITLE\n\
  \  yeokcham pin [--root PATH] --checkpoint ID\n\
  \  yeokcham unpin [--root PATH] --checkpoint ID\n\
  \  yeokcham compact [--root PATH] [--keep N] [--dry-run] [--explain]\n\
  \  yeokcham storage roots [--root PATH]\n\
  \  yeokcham storage gc [--root PATH] [--dry-run] [--explain]\n\
  \  yeokcham storage gc --root PATH --apply\n\
  \  yeokcham storage gc status [--root PATH]\n\
  \  yeokcham storage gc resume|restore|purge [--root PATH] --id ID\n\
  \  yeokcham completion bash|zsh|fish\n\
  \  yeokcham hook add [--root PATH] --event EVENT -- PROGRAM [ARGUMENT...]\n\
  \  yeokcham hook list [--root PATH] [--format text|json]\n\
  \  yeokcham hook remove|test [--root PATH] --id HOOK_ID\n\
  \  yeokcham verify [--root PATH] [--format text|json]\n\
  \  yeokcham repair plan [--root PATH] --from SOURCE [--format text|json]\n\
  \  yeokcham repair apply [--root PATH] --plan PLAN_ID --select CANDIDATE_ID \\\n\
   --approve PLAN_DIGEST [--format text|json]\n\
  \  yeokcham repair defer [--root PATH] [--format text|json]\n\
  \  yeokcham watch [--root PATH]"

let usage () = fail_with "invalid-invocation" usage_text
let version_text = "yeokcham V1 source build (unreleased)"

let help_for = function
  | [] ->
      Some
        ("Yeokcham is an experimental, local-first V1 VCS. It keeps local "
       ^ "checkpoints, explicit shared revisions, unresolved decisions, and "
       ^ "deliveries distinct.\n\n"
       ^ "Start with a source build, then read docs/GETTING_STARTED.md. "
       ^ "This checkout is development source. Native HTTPS clone requires an "
       ^ "enrolled local device and independent root verification. Git \
          interchange " ^ "is not supported.\n\n"
       ^ "Use `yeokcham help COMMAND` or `yeokcham COMMAND --help` for one "
       ^ "supported command. Invalid invocations exit with an error.\n\n"
       ^ usage_text)
  | [ "init" ] ->
      Some
        "usage: yeokcham init [PATH] [--root PATH] [--username NAME] [--draft \
         ID] [--title TITLE]\n\n\
         Capture existing files privately in a new local repository. \
         Workspace, branch and draft identities are generated. It prints one \
         public root-verification phrase and one recovery mnemonic; record the \
         mnemonic offline. This ceremony requires --format text; JSON requests \
         are refused before creating custody or repository state."
  | [ "join" ] ->
      Some
        "usage: yeokcham join [--root PATH] --username NAME --draft ID --title \
         TITLE --device ID --from PACKAGE --verify-phrase \"TWELVE WORDS\"\n\n\
         Initialise an already-enrolled local device after exact package \
         authority verification and independent phrase comparison. Join \
         neither imports package objects nor materialises source; run receive \
         separately."
  | [ "save" ] ->
      Some
        "usage: yeokcham save [--root PATH]\n\n\
         Create a local checkpoint only if the exact working tree changed. A \
         save is recovery, not shared intent."
  | [ "undo-tree" ] ->
      Some
        "usage: yeokcham undo-tree [--root PATH]\n\n\
         Show persistent local history, parent links, current position, and \
         compacted checkpoints. This does not scan files or contact a relay."
  | [ "undo" ] ->
      Some
        "usage: yeokcham undo [--root PATH] [--to NODE] [--preview|--yes] \
         [--plan ID]\n\n\
         Move to the parent node, or a selected node. Unsaved disk edits are \
         preserved first. --preview (or --dry-run) inspects exact path changes \
         without moving history/files. --yes confirms fresh validation; --plan \
         ID binds a prior preview. Noninteractive application needs \
         confirmation. Navigation leaves shared history unchanged."
  | [ "redo" ] ->
      Some
        "usage: yeokcham redo [--root PATH] [--node NODE] [--preview|--yes] \
         [--plan ID]\n\n\
         Move to a child of the current node. Choose --node when there are \
         several branches. Save or undo outstanding disk edits first. An \
         interrupted navigation resumes its original target without taking \
         another step."
  | [ "ignore" ] | [ "ignore"; "explain" ] ->
      Some
        "usage: yeokcham ignore explain PATH [--root DIRECTORY]\n\n\
         Show the winning native .yeokchamignore rule or mandatory metadata \
         exclusion. Git ignore files are not consulted."
  | [ "branch" ] | [ "branch"; "list" ] | [ "branch"; "create" ] ->
      Some
        "usage: yeokcham branch list [--root PATH] [--format json]\n\n\
         yeokcham branch create NAME [--root PATH] [--format json]\n\n\
         List authenticated shared branches or create a named fork without \
         changing selection. Private disk edits are captured locally; creation \
         does not accept or publish them. Use switch NAME to select a private \
         position."
  | [ "switch" ] ->
      Some
        "usage: yeokcham switch NAME [--root PATH] [--preview|--yes] [--plan \
         ID] [--format json]\n\n\
         Select an authenticated named branch and its private cursor. Preview \
         lists effects without moving files/history. Noninteractive \
         application requires --yes; ignored obstructions and unavailable \
         targets refuse before replacement. Interrupted switches resume their \
         exact target. First selection of a received branch uses its verified \
         accepted contents. Returning to a saved branch restores its private \
         position; inspect newer shared work with integrate --preview."
  | [ "restore" ] ->
      Some
        "usage: yeokcham restore STATE [--to DIRECTORY] [--root PATH] \
         [--preview|--yes] [--plan ID] [--format json]\n\n\
         yeokcham restore --resume [--operation ID] [--preview|--yes]\n\n\
         Select a saved history node, workspace:sequence, current saved state \
         or snapshot ID. --to makes a separate verified copy into a new/empty \
         same-filesystem directory. --checkpoint and --destination remain \
         aliases. Confirmation defaults to cancel; noninteractive writes need \
         --yes. Resume uses the original recorded target and retains \
         unexpected external edits."
  | [ "history" ] ->
      Some
        "usage: yeokcham history [--root PATH] [--before SEQUENCE] [--limit \
         1-200] [--all] [--format json]\n\n\
         Inspect exact saved states, alternatives, changed paths and verified \
         availability. Default page size is 50. No working-tree scan or \
         archive success is implied."
  | [ "diff" ] ->
      Some
        "usage: yeokcham diff [STATE_A [STATE_B]] [--root PATH] [--format \
         json]\n\n\
         Compare exact states without saving or rewriting files. States are \
         current, working, local sequences, workspace:sequence identities or \
         retained snapshot IDs. With no states compare current with working; \
         with one compare it with working. Text display is bounded; \
         opaque/type/mode changes retain exact identities."
  | [ "status" ] ->
      Some
        "usage: yeokcham status [--root PATH]\n\n\
         Show actual changed paths, local cursor/branch and complete or \
         incomplete capture state. Inspection does not save history or rewrite \
         working files. Watcher state is reported separately from saved data."
  | [ "changes" ] ->
      Some
        "usage: yeokcham changes [--root PATH]\n\n\
         Compare the exact current working tree with the active draft's latest \
         saved checkpoint. It lists stable-order paths with missing, \
         directory, or file mode/content entries; it never saves, shares, or \
         writes source. Like status, it can store unreferenced immutable scan \
         objects."
  | [ "log" ] ->
      Some
        "usage: yeokcham log [--root PATH]\n\n\
         Render persisted shared revisions, decisions, resolutions, \
         deliveries, and deferred review references. It does not scan the \
         working tree or contact a relay."
  | [ "graph" ] ->
      Some
        "usage: yeokcham graph [--root PATH] [--authority]\n\n\
         Render the persisted work graph, or the separate authority-epoch DAG \
         with --authority. It never infers policy from concurrent heads."
  | [ "timeline" ] ->
      Some
        "usage: yeokcham timeline [--root PATH]\n\n\
         List local checkpoints for recovery and their exact snapshot IDs."
  | [ "restore"; "proofs" ] ->
      Some
        "usage: yeokcham restore proofs [--root PATH]\n\n\
         List durable local safety/target proofs retained after in-place \
         restore."
  | [ "restore"; "retain" ] ->
      Some
        "usage: yeokcham restore retain [--root PATH] --operation ID\n\n\
         Create a durable proof for an eligible legacy completed restore \
         journal."
  | [ "restore"; "forget" ] ->
      Some
        "usage: yeokcham restore forget [--root PATH] --operation ID\n\n\
         Explicitly remove one durable local restore proof."
  | [ "workspace" ] ->
      Some
        "usage: yeokcham workspace activate [--root PATH]\n\
        \       yeokcham workspace update [--root PATH] [--replace]\n\n\
         Explicitly materialise or refresh the verified imported projection. \
         Bootstrap, receive, sync, and daemon commands never call this path."
  | [ "workspace"; "activate" ] ->
      Some
        "usage: yeokcham workspace activate [--root PATH]\n\n\
         Materialise the verified imported projection only into a root with no \
         ordinary source entries. It creates a local activation receipt after \
         materialisation; it never contacts a remote or selects authority."
  | [ "workspace"; "update" ] ->
      Some
        "usage: yeokcham workspace update [--root PATH] [--replace]\n\n\
         Compare the exact working tree against its activation receipt. A \
         dirty tree is refused unless --replace is explicit; replacement first \
         creates and prints a durable local safety checkpoint and proof."
  | [ "draft" ] ->
      Some
        "usage: yeokcham draft new [--root PATH] --id ID --title TITLE\n\n\
         Start a new local draft. Drafts are local scratch lines, not shared \
         branches."
  | [ "draft"; "new" ] ->
      Some
        "usage: yeokcham draft new [--root PATH] --id ID --title TITLE\n\n\
         Start a new local draft from the current local recovery state."
  | [ "share" ] ->
      Some
        "usage: yeokcham share [PATH...] [--root PATH] [--title TITLE] \
         [--update CHANGE] [--preview]\n\n\
         Capture current disk contents privately and record only selected \
         included changes. With no paths, select all included changes. Change \
         and revision identities are generated. --update explicitly revises a \
         change; --preview signs and publishes nothing. Local recording and \
         pending transfer are separate from acceptance. Advanced V1 sharing \
         with --change ID --revision ID [--authority EPOCH] remains available."
  | [ "integrate" ] ->
      Some
        "usage: yeokcham integrate [CHANGE...] [--all] [--root PATH] \
         [--preview|--yes] [--plan ID] [--reconcile HEAD]...\n\n\
         Prepare an exact accepted/private result, then confirm before \
         applying it. Change IDs select a sole current revision; exact \
         revision IDs are also accepted. With no IDs, select a sole eligible \
         change or explain the choice. --all selects all eligible changes. \
         Divergent branches require every event and accepted head explicitly \
         named with --reconcile. Receipt and local acceptance remain separate; \
         outbound transfer can remain pending."
  | [ "operation" ] | [ "operation"; "show" ] ->
      Some
        "usage: yeokcham operation show ID [--root PATH]\n\n\
         Inspect the durable integration phase, plan, safety/target identities \
         and pending outbound work without scanning or rewriting working \
         files."
  | [ "operation"; "recover" ] ->
      Some
        "usage: yeokcham operation recover ID [--root PATH] [--preview|--yes] \
         [--plan ID] [--keep-current] [--replan]\n\n\
         Restore pre-integration private contents, preserving the current disk \
         tree separately. --keep-current explicitly keeps the observed tree as \
         private work. --replan creates a new recovery attempt and retains \
         prior observations. This cannot undo committed shared acceptance."
  | [ "operation"; "forget" ] ->
      Some
        "usage: yeokcham operation forget ID [--root PATH] [--preview|--yes]\n\n\
         Explicitly release a completed recovery's extra snapshot roots/proof. \
         Live files, accepted records and private history are unchanged; later \
         GC may collect unreferenced alternatives."
  | [ "operation"; "resume" ] ->
      Some
        "usage: yeokcham operation resume ID [--root PATH]\n\n\
         Resume the same previously confirmed integration. No new acceptance \
         or navigation is created on retry. Unexpected external edits pause \
         application; Materialized/Committed retries never replay files."
  | [ "withdraw" ] ->
      Some
        "usage: yeokcham withdraw [--root PATH] --change ID\n\n\
         Withdraw an eligible local shared change through the V1 model."
  | [ "conflicts" ] ->
      Some
        "usage: yeokcham conflicts [--plan ID] [--root PATH]\n\n\
         Inspect exact shared/private conflicts and named versions. \
         Incomparable plans remain explicit; no acceptance or ordinary-file \
         changes."
  | [ "resolve" ] ->
      Some
        "usage: yeokcham resolve CONFLICT (--use VERSION|--file PATH|--defer) \
         [--plan ID] [--root PATH]\n\n\
         Prepare a fresh exact plan. Shared choices publish a scoped \
         resolution proposal; workspace choices stay private. Then inspect and \
         confirm integrate --plan ID. No acceptance or ordinary-file \
         replacement occurs here.\n\n\
         Advanced V1: resolve [--root PATH] --decision ID --change ID \
         --revision ID [--tree PATH] [--authority EPOCH]\n\n\
         Explicitly resolve one decision; it does not infer or automatically \
         merge a conflict."
  | [ "decision" ] ->
      Some
        "usage: yeokcham decision \
         show|inspect|diff|propose|materialize-proposal|materialize ...\n\n\
         Inspect unresolved composition explicitly. Proposals and optional LSP \
         advice are not decisions or persistent acceptance."
  | [ "decision"; "show" ] | [ "decision"; "inspect" ] ->
      Some
        "usage: yeokcham decision show|inspect [--root PATH] --decision ID\n\n\
         Show one unresolved decision and its candidate revisions."
  | [ "decision"; "diff" ] ->
      Some
        "usage: yeokcham decision diff [--root PATH] --decision ID --candidate \
         REV --against base|REV\n\n\
         Compare named decision snapshots by exact paths and entries, without \
         text diff or mutation."
  | [ "decision"; "propose" ] ->
      Some
        "usage: yeokcham decision propose [--root PATH] --decision ID [--left \
         REV --right REV] [--semantic-server NAME]\n\n\
         Produce a byte-exact proposal. A configured external LSP can provide \
         disposable advisory observations only."
  | [ "decision"; "materialize-proposal" ] ->
      Some
        "usage: yeokcham decision materialize-proposal [--root PATH] \
         --decision ID --left REV --right REV --destination PATH\n\n\
         Write a ready exact proposal only to an empty directory outside the \
         working tree; it remains unaccepted."
  | [ "decision"; "materialize" ] ->
      Some
        "usage: yeokcham decision materialize [--root PATH] --decision ID \
         --destination PATH\n\n\
         Materialise candidate trees under an isolated destination for \
         inspection."
  | [ "package" ] ->
      Some
        "usage: yeokcham package create|adopt ...\n\n\
         Create an offline public package or explicitly adopt one reviewed \
         late revision. Packages do not carry private keys or mutable state."
  | [ "package"; "create" ] ->
      Some
        "usage: yeokcham package create [--root PATH] --destination PATH\n\n\
         Write a new offline package directory with public authority closure, \
         signed work, and exact objects."
  | [ "package"; "adopt" ] ->
      Some
        "usage: yeokcham package adopt [--root PATH] --from PATH --revision ID \
         [--authority EPOCH]\n\n\
         Persist an exact administrator adoption for a reviewed late revision; \
         it imports no package."
  | [ "receive" ] ->
      Some
        "usage: yeokcham receive [--root PATH] --from PATH [--review]\n\n\
         Review or verify and receive an offline package. Receipt never scans, \
         resolves, or materialises the working tree."
  | [ "bootstrap" ] ->
      Some
        "usage: yeokcham bootstrap publish [--root PATH] REMOTE\n\
        \       yeokcham bootstrap [--root PATH] --remote NAME --url HTTPS_URL \
         --repository ID --basis ID --username NAME --draft ID --title TITLE \
         --device ID --verify-phrase \"TWELVE WORDS\"\n\n\
         Publish or consume one named, verified relay bootstrap basis. This is \
         explicit initialisation, not clone; it does not materialise source."
  | [ "bootstrap"; "publish" ] ->
      Some
        "usage: yeokcham bootstrap publish [--root PATH] REMOTE\n\n\
         Explicitly publish one signed immutable bootstrap basis to an already \
         configured equivalent relay."
  | [ "remote" ] ->
      Some
        "usage: yeokcham remote add|remove|login [--root PATH] ...\n\n\
         Manage local HTTPS relay aliases and local credential entry. A relay \
         is an untrusted byte courier."
  | [ "remote"; "add" ] ->
      Some
        "usage: yeokcham remote add [--root PATH] NAME URL\n\n\
         Save one local HTTPS relay alias. This does not contact the relay."
  | [ "remote"; "remove" ] ->
      Some
        "usage: yeokcham remote remove [--root PATH] NAME\n\n\
         Remove one local relay alias and its local configuration."
  | [ "remote"; "login" ] ->
      Some
        "usage: yeokcham remote login [--root PATH] NAME\n\n\
         Prompt for and save one configured relay's local bearer credential \
         after interactive entry."
  | [ "semantic" ] ->
      Some
        "usage: yeokcham semantic server \
         add|list|configure|enable|disable|remove ...\n\n\
         Configure an optional external LSP for disposable decision \
         observations. It is never a parser, merge engine, or trust input."
  | [ "semantic"; "server" ] ->
      Some
        "usage: yeokcham semantic server \
         add|list|configure|enable|disable|remove ...\n\n\
         Manage named local external-LSP configurations."
  | [ "semantic"; "server"; "add" ] ->
      Some
        "usage: yeokcham semantic server add [--root PATH] NAME --program \
         ABS_PATH [--arg VALUE]... [--match extensions|path-globs|all-files] \
         [--extension EXT]... [--glob PATTERN]... [--overlap \
         same-symbol|nearby-ranges|references]\n\n\
         Add one explicit external-LSP configuration for disposable proposal \
         observations."
  | [ "semantic"; "server"; "list" ] ->
      Some
        "usage: yeokcham semantic server list [--root PATH]\n\n\
         List local external-LSP configurations."
  | [ "semantic"; "server"; "configure" ] ->
      Some
        "usage: yeokcham semantic server configure [--root PATH] NAME --match \
         extensions|path-globs|all-files [--extension EXT]... [--glob \
         PATTERN]... --overlap same-symbol|nearby-ranges|references\n\n\
         Change matching and advisory-overlap settings for one named local \
         server."
  | [ "semantic"; "server"; ("enable" | "disable" | "remove") ] ->
      Some
        "usage: yeokcham semantic server enable|disable|remove [--root PATH] \
         NAME\n\n\
         Enable, disable, or remove one named local external-LSP configuration."
  | [ "sync" ] ->
      Some
        "usage: yeokcham sync [--root PATH] NAME\n\n\
         Use one configured relay alias for staged receive-first \
         synchronization. It does not materialise source or select authority."
  | [ "exchange" ] ->
      Some
        "usage: yeokcham exchange [--root PATH] NAME [--format text|json]\n\n\
         Receive verified shared work and send the exact durable outgoing \
         batch through a configured native HTTPS relay. Requires existing \
         enrollment and remote login. Receipt preserves working files/private \
         history. Transfers run in the foreground; retry this command after \
         interruption. Local acceptance and relay acknowledgement are separate \
         facts."
  | [ "clone" ] ->
      Some
        "usage: yeokcham clone https://RELAY/v1/repositories/REPOSITORY \
         [DIRECTORY] --device DEVICE --verify-phrase \"PUBLIC WORDS\" \
         [--branch NAME] [--preview] [--request ID] [--token-stdin] [--format \
         text|json]\n\
        \       yeokcham clone --resume DIRECTORY [--format text|json]\n\n\
         Verify shared records and complete contents before creating a \
         workspace in a new/empty directory. Requires an already enrolled \
         local signing device, independent public root phrase, HTTPS trust and \
         a relay bearer. A bearer does not enroll a member. Default branch: \
         main. Preview creates no destination and returns an exact request ID. \
         Tokens come from scoped custody or an interactive prompt; \
         --token-stdin reads one bounded secret line without echo. Resume an \
         attached clone locally without network or a signing provider. Clone \
         never executes project hooks."
  | [ "relay" ] ->
      Some
        "usage: yeokcham relay serve|access issue|rotate|revoke|list ...\n\n\
         Operate immutable relay byte storage and repository-scoped access \
         credentials behind an operator-managed HTTPS proxy."
  | [ "relay"; "serve" ] ->
      Some
        "usage: yeokcham relay serve --config PATH\n\
        \       yeokcham relay serve --storage PATH --listen ADDRESS:PORT\n\n\
         Run the plain-HTTP relay backend. The explicit relay-config-v1 path \
         enables separate storage, credential, health, metrics, quota, and \
         expiry settings with documented YEOKCHAM_RELAY_* overrides. The \
         legacy storage/listen form has no health or metrics listener. Put \
         either form behind an operator-managed HTTPS reverse proxy."
  | [ "relay"; "access" ] ->
      Some
        "usage: yeokcham relay access issue|rotate|revoke|list --storage PATH \
         ...\n\n\
         Manage repository-scoped relay credentials; this does not change V1 \
         authority."
  | [ "relay"; "access"; "issue" ] ->
      Some
        "usage: yeokcham relay access issue --storage PATH --repository ID \
         --scope read,write [--expires-in SECONDS]\n\n\
         Issue a repository-scoped relay secret and display it once on a \
         controlling terminal."
  | [ "relay"; "access"; "rotate" ] ->
      Some
        "usage: yeokcham relay access rotate --storage PATH --id ID \
         [--expires-in SECONDS]\n\n\
         Replace one relay credential by local credential ID."
  | [ "relay"; "access"; "revoke" ] ->
      Some
        "usage: yeokcham relay access revoke --storage PATH --id ID\n\n\
         Revoke one relay credential by local credential ID."
  | [ "relay"; "access"; "list" ] ->
      Some
        "usage: yeokcham relay access list --storage PATH [--repository ID]\n\n\
         List local relay access metadata without exposing bearer secrets."
  | [ "device" ] ->
      Some
        "usage: yeokcham device \
         create|attach|custody|show|enroll|revoke|rotate ...\n\n\
         Inspect or manage device custody and explicit authority membership. \
         Device IDs derive from public keys; usernames are display data."
  | [ "device"; "create" ] ->
      Some
        "usage: yeokcham device create [--provider native]\n\
        \       yeokcham device create --provider pkcs11 --root PATH --module \
         PATH --token-label LABEL --key-label LABEL --key-id HEX\n\n\
         Create local native or PKCS#11 device custody. It grants no authority."
  | [ "device"; "attach" ] ->
      Some
        "usage: yeokcham device attach --root PATH --provider ssh-agent \
         --public-key FILE\n\
        \       yeokcham device attach --root PATH --provider pkcs11 --module \
         PATH --token-label LABEL --key-id HEX --public-key HEX\n\n\
         Attach an existing local external custody provider; authority remains \
         unchanged."
  | [ "device"; "custody" ] ->
      Some
        "usage: yeokcham device custody [--root PATH] --device ID\n\n\
         Show one saved optional custody provider and its local availability."
  | [ "device"; "show" ] ->
      Some
        "usage: yeokcham device show [--root PATH]\n\n\
         Show current repository, local device public key, and membership role."
  | [ "device"; "enroll" ] ->
      Some
        "usage: yeokcham device enroll [--root PATH] --device ID --public-key \
         HEX --username NAME [--administrator] [--parent EPOCH]\n\n\
         Explicitly enroll a device in authority."
  | [ "device"; "revoke" ] ->
      Some
        "usage: yeokcham device revoke [--root PATH] --device ID [--parent \
         EPOCH]\n\n\
         Explicitly revoke a device in one named authority branch when \
         necessary."
  | [ "device"; "rotate" ] ->
      Some
        "usage: yeokcham device rotate [--root PATH] --device ID --public-key \
         HEX [--parent EPOCH]\n\n\
         Explicitly replace the current device identity in authority."
  | [ "authority" ] ->
      Some
        "usage: yeokcham authority heads|reconcile [--root PATH] ...\n\n\
         Inspect concurrent authority heads or explicitly reconcile selected \
         heads."
  | [ "authority"; "heads" ] ->
      Some
        "usage: yeokcham authority heads [--root PATH]\n\n\
         List every current authority head without choosing one."
  | [ "authority"; "reconcile" ] ->
      Some
        "usage: yeokcham authority reconcile [--root PATH] --parents \
         EPOCH,EPOCH[,EPOCH]\n\n\
         Create an explicit multi-parent reconciliation when the local \
         administrator is active in each selected head."
  | [ "recovery" ] ->
      Some
        "usage: yeokcham recovery use|refresh ...\n\n\
         Use or copy the explicit encrypted recovery package. Mnemonics passed \
         as arguments can appear in shell history or process listings."
  | [ "recovery"; "use" ] ->
      Some
        "usage: yeokcham recovery use [--root PATH] --package PATH --mnemonic \
         \"TWENTY FOUR WORDS\" --replacement ID --replaced ID --output PATH\n\n\
         Recover authority through the encrypted package, replacing one device \
         and writing a new package before state advances. Use --format text to \
         record the replacement recovery mnemonic; JSON is refused before any \
         recovery action."
  | [ "recovery"; "refresh" ] ->
      Some
        "usage: yeokcham recovery refresh [--root PATH] --package PATH \
         --mnemonic \"TWENTY FOUR WORDS\" --output PATH\n\n\
         Write a fresh encrypted copy of the current recovery closure without \
         changing authority."
  | [ "user" ] ->
      Some
        "usage: yeokcham user register [--root PATH] --device ID --username \
         NAME\n\n\
         Store local display metadata. A username is not identity or authority."
  | [ "user"; "register" ] ->
      Some
        "usage: yeokcham user register [--root PATH] --device ID --username \
         NAME\n\n\
         Associate display-only local username metadata with one public device \
         ID."
  | [ "daemon" ] ->
      Some
        "usage: yeokcham daemon start|status|stop [--root PATH]\n\
        \       yeokcham daemon sync [--root PATH] REMOTE\n\n\
         Run Linux-only advisory capture in a private XDG runtime. It never \
         follows remotes automatically."
  | [ "daemon"; ("start" | "status" | "stop") ] ->
      Some
        "usage: yeokcham daemon start|status|stop [--root PATH]\n\n\
         Manage the Linux-only advisory capture process for one repository."
  | [ "daemon"; "sync" ] ->
      Some
        "usage: yeokcham daemon sync [--root PATH] REMOTE\n\n\
         Request one explicit receive-first synchronization through the \
         running Linux daemon."
  | [ "deliver" ] ->
      Some
        "usage: yeokcham deliver [--root PATH] --id ID --draft ID --title \
         TITLE\n\n\
         Record an explicit delivery milestone and begin the named next draft."
  | [ "pin" ] | [ "unpin" ] ->
      Some
        "usage: yeokcham pin|unpin [--root PATH] --checkpoint ID\n\n\
         Add or remove explicit local retention for one checkpoint."
  | [ "compact" ] ->
      Some
        "usage: yeokcham compact [--root PATH] [--keep N] [--dry-run] \
         [--explain]\n\n\
         Plan or compact local checkpoint retention. Use storage gc separately \
         for recoverable object collection."
  | [ "storage" ] ->
      Some
        "usage: yeokcham storage roots|gc ...\n\n\
         Inspect retention roots or use the explicit local \
         quarantine-and-purge collection workflow."
  | [ "storage"; "roots" ] ->
      Some
        "usage: yeokcham storage roots [--root PATH]\n\n\
         List and validate the exact non-recent storage roots."
  | [ "storage"; "gc" ] ->
      Some
        "usage: yeokcham storage gc [--root PATH] [--dry-run] [--explain]\n\
        \       yeokcham storage gc --root PATH --apply\n\
        \       yeokcham storage gc status|resume|restore|purge [--root PATH] \
         [--id ID]\n\n\
         Review a local reachability plan, then explicitly quarantine, \
         restore, or purge. It never contacts a relay or writes source."
  | [ "storage"; "gc"; "status" ] ->
      Some
        "usage: yeokcham storage gc status [--root PATH]\n\n\
         List local garbage-collection quarantine transactions."
  | [ "storage"; "gc"; ("resume" | "restore" | "purge") ] ->
      Some
        "usage: yeokcham storage gc resume|restore|purge [--root PATH] --id ID\n\n\
         Resume staging, return a pre-purge quarantine, or irreversibly purge \
         one named local transaction."
  | [ "completion" ] ->
      Some
        "usage: yeokcham completion bash|zsh|fish\n\n\
         Print a static shell completion script generated from the V1 command \
         specification. It never opens a repository, relay, or credential \
         provider."
  | [ "hook" ] | [ "hook"; ("add" | "list" | "remove" | "test") ] ->
      Some
        "usage: yeokcham hook add [--root PATH] --event EVENT -- PROGRAM \
         [ARGUMENT ...]\n\
         yeokcham hook list [--root PATH] [--format text|json]\n\
         yeokcham hook remove|test [--root PATH] --id HOOK_ID\n\n\
         Store explicit local post-success observers as an argv list. Hooks \
         receive only a redacted event on stdin; warning outcomes never change \
         the V1 command result."
  | [ "verify" ] ->
      Some
        "usage: yeokcham verify [--root PATH] [--format text|json]\n\n\
         Read and report damaged V1 closures. It never creates a lock, plan, \
         object, receipt, quarantine, or ordinary source file."
  | [ "repair" ] | [ "repair"; ("plan" | "apply" | "defer") ] ->
      Some
        "usage: yeokcham repair plan --from SOURCE [--root PATH] [--format \
         text|json]\n\
         yeokcham repair apply --plan PLAN_ID --select CANDIDATE_ID --approve \
         PLAN_DIGEST [--root PATH] [--format text|json]\n\
         yeokcham repair defer [--root PATH] [--format text|json]\n\n\
         SOURCE is backup:PATH, gc:TRANSACTION_ID, package:PATH, relay:ALIAS, \
         or bootstrap:ARTIFACT_DIRECTORY. Plan has no selection; apply \
         rechecks source bytes and damage before add-if-missing publish."
  | [ "watch" ] ->
      Some
        "usage: yeokcham watch [--root PATH]\n\n\
         Run foreground advisory capture on Linux or macOS. It requests exact \
         save after debounce; unsupported platforms fail explicitly."
  | _ -> None

let print_help path =
  match help_for path with
  | Some text -> print_endline text
  | None ->
      fail
        ("unknown help topic: " ^ String.concat " " path ^ "\n\n" ^ usage_text)

let require_ok render = function
  | Ok value -> value
  | Error error -> fail (render error)

let default_root = Sys.getcwd ()
let ( let* ) = Result.bind

let parse_root = function
  | [] -> default_root
  | [ "--root"; root ] -> root
  | _ -> usage ()

let parse_identifier name parser value =
  parser value
  |> require_ok (fun error -> name ^ ": " ^ Model.error_to_string error)

let hex_of_bytes bytes =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length bytes * 2)
    (fun index ->
      let value = Char.code bytes.[index / 2] in
      if index mod 2 = 0 then alphabet.[value lsr 4]
      else alphabet.[value land 0x0f])

let bytes_of_hex value =
  let nibble = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
    | _ -> None
  in
  if String.length value mod 2 <> 0 then
    fail "public key must be lowercase hexadecimal"
  else
    let bytes = Bytes.create (String.length value / 2) in
    let rec decode offset =
      if offset = String.length value then Bytes.unsafe_to_string bytes
      else
        match (nibble value.[offset], nibble value.[offset + 1]) with
        | Some high, Some low ->
            Bytes.set bytes (offset / 2) (Char.chr ((high lsl 4) lor low));
            decode (offset + 2)
        | None, _ | _, None -> fail "public key must be lowercase hexadecimal"
    in
    decode 0

let render_status ?(uncaptured_known = true) status =
  Printf.printf "device %s\n" (Model.Device_id.to_string status.Service.creator);
  Printf.printf "saved %s\n"
    (Model.Snapshot_id.to_string status.Service.checkpoint);
  Printf.printf "draft %s %s\n"
    (Model.Draft_id.to_string status.Service.active_draft.Model.draft_id)
    (Output.display_value status.Service.active_draft.Model.title);
  Printf.printf "shared %d\n" status.Service.shared_change_count;
  List.iter
    (fun change ->
      Printf.printf "change %s\n"
        (Model.Change_id.to_string change.Model.change_id))
    status.Service.shared_changes;
  Printf.printf "needs-decision %d\n"
    (List.length status.Service.open_decisions);
  List.iter
    (fun decision ->
      Printf.printf "decision %s\n"
        (Model.Decision_id.to_string decision.Model.decision_id))
    status.Service.open_decisions;
  Printf.printf "delivered %d\n" status.Service.delivery_count;
  List.iter
    (fun delivery ->
      Printf.printf "delivery %s\n"
        (Model.Delivery_id.to_string delivery.Model.delivery_id))
    status.Service.deliveries;
  Printf.printf "users %d\n" (List.length status.Service.usernames);
  status.Service.usernames
  |> List.sort (fun left right ->
      Model.Device_id.compare left.Model.username_device
        right.Model.username_device)
  |> List.iter (fun registration ->
      Printf.printf "user %s %s\n"
        (Model.Device_id.to_string registration.Model.username_device)
        (Model.Username.to_string registration.Model.username));
  print_endline "capture command";
  Printf.printf "uncaptured %s\n"
    (if not uncaptured_known then "unknown"
     else if status.Service.uncaptured then "yes"
     else "no")

let parse_init arguments =
  let rec loop root username draft title = function
    | [] ->
        let root = Option.value root ~default:default_root in
        let username =
          match username with
          | Some value -> value
          | None -> (
              let candidate =
                try (Unix.getpwuid (Unix.getuid ())).Unix.pw_name
                with Not_found -> "local"
              in
              match Model.Username.of_string candidate with
              | Ok _ -> candidate
              | Error _ -> "local")
        in
        let draft =
          match draft with
          | Some value -> value
          | None ->
              Core.Change_id.generate ~random_bytes:Trust.random_bytes ()
              |> require_ok Core.error_to_string
              |> Core.Change_id.to_hex
        in
        let basename = Filename.basename root in
        let default_title =
          if Result.is_ok (Yeokcham_encoding.text basename) then
            "Work on " ^ basename
          else "Local work"
        in
        let title = Option.value title ~default:default_title in
        (root, username, draft, title)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) username draft title rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root (Some value) draft title rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root username (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root username draft (Some value) rest
    | "--" :: [ value ] when Option.is_none root ->
        loop (Some value) username draft title []
    | value :: rest
      when Option.is_none root && not (String.starts_with ~prefix:"-" value) ->
        loop (Some value) username draft title rest
    | _ -> usage ()
  in
  loop None None None None arguments

let parse_new_draft arguments =
  let rec loop root id title = function
    | [] -> (
        match (id, title) with
        | Some id, Some title ->
            (Option.value root ~default:default_root, id, title)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id title rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root id (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let parse_workspace_activate arguments =
  let rec loop root = function
    | [] -> Option.value root ~default:default_root
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) rest
    | _ -> usage ()
  in
  loop None arguments

let parse_workspace_update arguments =
  let rec loop root replace = function
    | [] -> (Option.value root ~default:default_root, replace)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) replace rest
    | "--replace" :: rest when not replace -> loop root true rest
    | _ -> usage ()
  in
  loop None false arguments

type health_format = Health_text | Health_json

let health_format_from_request () =
  match requested_format () with
  | Text_format -> Health_text
  | Json_format -> Health_json

type health_source =
  | Backup_source of string
  | Gc_source of string
  | Package_source of string
  | Relay_source of string
  | Bootstrap_source of string

let parse_health_format = function
  | "text" -> Health_text
  | "json" -> Health_json
  | _ -> usage ()

let parse_health_arguments arguments =
  let rec loop root format = function
    | [] -> (Option.value root ~default:default_root, format)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) format rest
    | "--format" :: value :: rest when format = Health_text ->
        loop root (parse_health_format value) rest
    | _ -> usage ()
  in
  loop None (health_format_from_request ()) arguments

let parse_repair_plan arguments =
  let rec loop root source format = function
    | [] -> (
        match source with
        | Some source ->
            (Option.value root ~default:default_root, source, format)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) source format rest
    | "--from" :: value :: rest when Option.is_none source ->
        loop root (Some value) format rest
    | "--format" :: value :: rest when format = Health_text ->
        loop root source (parse_health_format value) rest
    | _ -> usage ()
  in
  loop None None (health_format_from_request ()) arguments

let parse_repair_apply arguments =
  let rec loop root plan candidate approval format = function
    | [] -> (
        match (plan, candidate, approval) with
        | Some plan, Some candidate, Some approval ->
            ( Option.value root ~default:default_root,
              plan,
              candidate,
              approval,
              format )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) plan candidate approval format rest
    | "--plan" :: value :: rest when Option.is_none plan ->
        loop root (Some value) candidate approval format rest
    | "--select" :: value :: rest when Option.is_none candidate ->
        loop root plan (Some value) approval format rest
    | "--approve" :: value :: rest when Option.is_none approval ->
        loop root plan candidate (Some value) format rest
    | "--format" :: value :: rest when format = Health_text ->
        loop root plan candidate approval (parse_health_format value) rest
    | _ -> usage ()
  in
  loop None None None None (health_format_from_request ()) arguments

let source_of_argument value =
  match String.split_on_char ':' value with
  | prefix :: locator :: rest when String.length locator > 0 -> (
      let locator = String.concat ":" (locator :: rest) in
      match prefix with
      | "backup" -> Backup_source locator
      | "gc" -> Gc_source locator
      | "package" -> Package_source locator
      | "relay" -> Relay_source locator
      | "bootstrap" -> Bootstrap_source locator
      | _ ->
          fail
            "repair source must be backup:PATH, gc:TRANSACTION_ID, \
             package:PATH, relay:ALIAS, or bootstrap:ARTIFACT_DIRECTORY")
  | _ ->
      fail
        "repair source must be backup:PATH, gc:TRANSACTION_ID, package:PATH, \
         relay:ALIAS, or bootstrap:ARTIFACT_DIRECTORY"

let json_of_affected = function
  | Health.Object id ->
      `Assoc [ ("kind", `String "object"); ("id", `String id) ]
  | Health.Durable_record (kind, id) ->
      let kind =
        match kind with
        | Health.State_head -> "state-head"
        | Health.Restore_proof -> "restore-proof"
        | Health.Workspace_receipt -> "workspace-receipt"
        | Health.Gc_transaction -> "gc-transaction"
        | Health.Repair_plan_record -> "repair-plan"
        | Health.Integration_plan_record -> "integration-plan"
      in
      `Assoc [ ("kind", `String kind); ("id", `String id) ]
  | Health.Temporary_state (kind, id) ->
      let kind =
        match kind with
        | Health.Restore_temporary -> "restore-temporary"
        | Health.Gc_temporary -> "gc-temporary"
        | Health.Transfer_temporary -> "transfer-temporary"
        | Health.Repair_temporary -> "repair-temporary"
      in
      `Assoc [ ("kind", `String kind); ("id", `String id) ]

let json_of_damage damage =
  `Assoc
    [
      ( "code",
        `String (Health.damage_code damage |> Health.damage_code_to_string) );
      ("affected", json_of_affected (Health.damage_affected damage));
      ( "blocked_operations",
        `List
          (Health.damage_blocked_operations damage
          |> List.map (fun operation ->
              `String (Health.blocked_operation_to_string operation))) );
    ]

let json_of_candidate candidate =
  `Assoc
    [
      ("id", `String (Health.candidate_id candidate));
      ("object_id", `String (Health.candidate_object_id candidate));
      ("bytes_id", `String (Health.candidate_bytes_id candidate));
      ( "source",
        `String
          (Health.candidate_source candidate |> Health.repair_source_to_string)
      );
    ]

let json_of_report report =
  `Assoc
    [
      ( "damages",
        `List (Health.report_damages report |> List.map json_of_damage) );
    ]

let json_of_plan plan =
  `Assoc
    [
      ("id", `String (Health.plan_id plan));
      ("digest", `String (Health.plan_digest plan));
      ( "source",
        `String (Health.plan_source plan |> Health.repair_source_to_string) );
      ("state_head", `String (Health.plan_state_head plan));
      ("expires_at", `Intlit (Int64.to_string (Health.plan_expires_at plan)));
      ("damages", `List (Health.plan_damages plan |> List.map json_of_damage));
      ( "candidates",
        `List (Health.plan_candidates plan |> List.map json_of_candidate) );
    ]

let render_health_result format command result text =
  match format with
  | Health_text -> text ()
  | Health_json ->
      Cli_data.success ~command ~result ~warnings:[]
      |> Cli_data.encode |> Output.print_raw_endline

let fail_health format command code message =
  (match format with
  | Health_text -> ()
  | Health_json ->
      Cli_data.failure ~command ~warnings:[] ~error:{ Cli_data.code; message }
      |> Cli_data.encode |> Output.print_raw_endline);
  prerr_endline message;
  exit 2

let affected_text affected =
  match affected with
  | Health.Object id -> "object " ^ id
  | Health.Durable_record (_, id) -> "durable " ^ id
  | Health.Temporary_state (_, id) -> "temporary " ^ id

let render_health_report report =
  if Health.report_is_clean report then print_endline "verify clean"
  else
    Health.report_damages report
    |> List.iter (fun damage ->
        Printf.printf "damage %s %s blocks %s\n"
          (Health.damage_code damage |> Health.damage_code_to_string)
          (affected_text (Health.damage_affected damage))
          (Health.damage_blocked_operations damage
          |> List.map Health.blocked_operation_to_string
          |> String.concat ","))

let render_repair_plan plan =
  Printf.printf "repair plan %s\n" (Health.plan_id plan);
  Printf.printf "digest %s\n" (Health.plan_digest plan);
  Printf.printf "source %s\n"
    (Health.plan_source plan |> Health.repair_source_to_string);
  Printf.printf "expires-at %Ld\n" (Health.plan_expires_at plan);
  Health.plan_damages plan
  |> List.iter (fun damage ->
      Printf.printf "damage %s %s\n"
        (Health.damage_code damage |> Health.damage_code_to_string)
        (affected_text (Health.damage_affected damage)));
  Health.plan_candidates plan
  |> List.iter (fun candidate ->
      Printf.printf "candidate %s object %s bytes %s\n"
        (Health.candidate_id candidate)
        (Health.candidate_object_id candidate)
        (Health.candidate_bytes_id candidate))

let health_refusal_code = function
  | Health.Invalid_identifier _ -> "invalid-identifier"
  | Health.Invalid_locator _ -> "invalid-locator"
  | Health.Duplicate_observation _ -> "duplicate-observation"
  | Health.No_damage -> "no-damage"
  | Health.Invalid_expiry _ -> "invalid-expiry"
  | Health.Candidate_source_mismatch -> "candidate-source-mismatch"
  | Health.Candidate_not_missing -> "candidate-not-missing"
  | Health.Plan_expired -> "plan-expired"
  | Health.Plan_id_mismatch -> "plan-id-mismatch"
  | Health.Plan_digest_mismatch -> "plan-digest-mismatch"
  | Health.Candidate_not_in_plan -> "candidate-not-in-plan"
  | Health.Candidate_changed -> "candidate-changed"
  | Health.State_head_changed -> "state-head-changed"
  | Health.Damage_changed -> "damage-changed"
  | Health.Destination_no_longer_missing -> "destination-no-longer-missing"

let current_unix_seconds () = Int64.of_float (Unix.gettimeofday ())

let run_completion = function
  | [ "bash" ] ->
      Output.print_raw_string (Cli_spec.render_completion Cli_spec.Bash)
  | [ "zsh" ] ->
      Output.print_raw_string (Cli_spec.render_completion Cli_spec.Zsh)
  | [ "fish" ] ->
      Output.print_raw_string (Cli_spec.render_completion Cli_spec.Fish)
  | _ -> usage ()

let hook_event_for_path path =
  let event =
    match path with
    | [ "init" ] -> Some Hook.Init
    | [ "save" ] -> Some Hook.Save
    | [ "undo" ]
    | [ "redo" ]
    | [ "restore" ]
    | [ "restore"; "retain" ]
    | [ "restore"; "forget" ] ->
        Some Hook.Restore
    | [ "workspace"; "activate" ] -> Some Hook.Workspace_activate
    | [ "workspace"; "update" ] -> Some Hook.Workspace_update
    | [ "draft"; "new" ] -> Some Hook.Draft_new
    | [ "share" ] -> Some Hook.Share
    | [ "withdraw" ] -> Some Hook.Withdraw
    | [ "resolve" ] -> Some Hook.Resolve
    | [ "deliver" ] -> Some Hook.Deliver
    | [ "pin" ] -> Some Hook.Pin
    | [ "unpin" ] -> Some Hook.Unpin
    | [ "compact" ] -> Some Hook.Compact
    | _ -> None
  in
  match (Cli_spec.find path, event) with
  | Some { Cli_spec.command_hook_eligible = true; _ }, Some event -> Some event
  | _ -> None

let root_from_arguments arguments =
  let rec loop = function
    | "--root" :: root :: _ -> root
    | _ :: rest -> loop rest
    | [] -> default_root
  in
  loop arguments

let run_hooks_after_success path arguments =
  match hook_event_for_path path with
  | None -> ()
  | Some event -> (
      let root = root_from_arguments arguments in
      match Hook_store.load ~root with
      | Error error -> record_warning (Hook_store.error_to_string error)
      | Ok registry -> (
          let public_event =
            Hook_runner.make_event ~event ~command:(String.concat "-" path)
              ~repository:None ~paths:[] ~identifiers:[]
          in
          match public_event with
          | Error error -> record_warning error
          | Ok public_event ->
              Hook.hooks registry
              |> List.filter (fun hook -> Hook.hook_event hook = event)
              |> List.iter (fun hook ->
                  match
                    Hook_runner.invoke
                      ~timeout_seconds:Hook_runner.default_timeout_seconds
                      public_event hook
                  with
                  | None -> ()
                  | Some warning ->
                      record_warning (Hook_runner.warning_to_string warning))))

let observe_after_success path arguments action =
  action ();
  run_hooks_after_success path arguments

let observe_after_commit path arguments action =
  if action () then run_hooks_after_success path arguments

let parse_hook_add arguments =
  let rec loop root event = function
    | "--" :: argv -> (
        match (event, argv) with
        | Some event, _ :: _ ->
            (Option.value root ~default:default_root, event, argv)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) event rest
    | "--event" :: value :: rest when Option.is_none event ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_hook_id arguments =
  let rec loop root id = function
    | [] -> (
        match id with
        | Some id -> (Option.value root ~default:default_root, id)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_hook_list arguments =
  let rec loop root format = function
    | [] -> (Option.value root ~default:default_root, format)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) format rest
    | "--format" :: value :: rest when format = Health_text ->
        loop root (parse_health_format value) rest
    | _ -> usage ()
  in
  loop None (health_format_from_request ()) arguments

let json_of_hook hook =
  let program =
    match Hook.hook_argv hook with
    | program :: _ -> program
    | [] -> assert false
  in
  `Assoc
    [
      ("id", `String (Hook.hook_id hook));
      ("event", `String (Hook.event_to_string (Hook.hook_event hook)));
      ("program", `String program);
    ]

let run_hook_add arguments =
  let root, event, argv = parse_hook_add arguments in
  let event = Hook.event_of_string event |> require_ok Hook.error_to_string in
  let hook = Hook.make ~event ~argv |> require_ok Hook.error_to_string in
  let registry =
    Hook_store.load ~root |> require_ok Hook_store.error_to_string
  in
  let registry = Hook.add registry hook |> require_ok Hook.error_to_string in
  Hook_store.save ~root registry |> require_ok Hook_store.error_to_string;
  Printf.printf "hook %s event %s\n" (Hook.hook_id hook)
    (Hook.event_to_string event)

let run_hook_list arguments =
  let root, format = parse_hook_list arguments in
  let hooks =
    Hook_store.load ~root |> require_ok Hook_store.error_to_string |> Hook.hooks
  in
  render_health_result format "hook-list"
    (`Assoc [ ("hooks", `List (List.map json_of_hook hooks)) ])
    (fun () ->
      List.iter
        (fun hook ->
          Printf.printf "hook %s event %s program %s\n" (Hook.hook_id hook)
            (Hook.event_to_string (Hook.hook_event hook))
            (List.hd (Hook.hook_argv hook)))
        hooks)

let find_hook root id =
  Hook_store.load ~root
  |> require_ok Hook_store.error_to_string
  |> Hook.hooks
  |> List.find_opt (fun hook -> String.equal id (Hook.hook_id hook))

let run_hook_remove arguments =
  let root, id = parse_hook_id arguments in
  let registry =
    Hook_store.load ~root |> require_ok Hook_store.error_to_string
  in
  let registry = Hook.remove registry ~id |> require_ok Hook.error_to_string in
  Hook_store.save ~root registry |> require_ok Hook_store.error_to_string;
  Printf.printf "hook removed %s\n" id

let run_hook_test arguments =
  let root, id = parse_hook_id arguments in
  match find_hook root id with
  | None -> fail (Hook.error_to_string (Hook.Unknown_hook id))
  | Some hook -> (
      let public_event =
        Hook_runner.make_event ~event:(Hook.hook_event hook)
          ~command:"hook-test" ~repository:None ~paths:[] ~identifiers:[]
        |> require_ok Fun.id
      in
      match
        Hook_runner.invoke ~timeout_seconds:Hook_runner.default_timeout_seconds
          public_event hook
      with
      | None -> Printf.printf "hook test passed %s\n" id
      | Some warning ->
          let warning = Hook_runner.warning_to_string warning in
          if requested_format () = Json_format then record_warning warning
          else Printf.printf "hook test warning %s\n" warning)

let run_hook = function
  | "add" :: arguments -> run_hook_add arguments
  | "list" :: arguments -> run_hook_list arguments
  | "remove" :: arguments -> run_hook_remove arguments
  | "test" :: arguments -> run_hook_test arguments
  | _ -> usage ()

let run_verify arguments =
  let root, format = parse_health_arguments arguments in
  let report = Health_repository.verify ~root in
  render_health_result format "verify" (json_of_report report) (fun () ->
      render_health_report report)

let run_repair_plan arguments =
  let root, source, format = parse_repair_plan arguments in
  let now = current_unix_seconds () in
  let expires_at = Int64.add now 3600L in
  let result =
    match source_of_argument source with
    | Backup_source backup ->
        Repair.plan_from_backup ~root ~backup ~created_at:now ~expires_at
    | Gc_source transaction_id ->
        Repair.plan_from_gc_quarantine ~root ~transaction_id ~created_at:now
          ~expires_at
    | Package_source package ->
        Repair.plan_from_offline_package ~root ~package ~created_at:now
          ~expires_at
    | Relay_source remote ->
        Repair.plan_from_configured_relay ~root ~remote ~created_at:now
          ~expires_at
    | Bootstrap_source artifact ->
        Repair.plan_from_bootstrap_artifact ~root ~artifact ~created_at:now
          ~expires_at
  in
  match result with
  | Ok plan ->
      render_health_result format "repair-plan" (json_of_plan plan) (fun () ->
          render_repair_plan plan)
  | Error error ->
      fail_health format "repair-plan" "repair-plan-failed"
        (Repair.error_to_string error)

let run_repair_apply arguments =
  let root, plan_id, candidate_id, approval, format =
    parse_repair_apply arguments
  in
  let plan =
    match Health_store.find ~root ~id:plan_id with
    | Ok plan -> plan
    | Error error ->
        fail_health format "repair-apply" "repair-plan-unavailable"
          (Health_store.error_to_string error)
  in
  let selection : Health.selection =
    {
      Health.selection_plan_id = plan_id;
      selection_candidate_id = candidate_id;
      selection_approved_digest = approval;
    }
  in
  let result =
    match Health.plan_source plan with
    | Health.Backup _ ->
        Repair.apply_from_backup ~root ~plan_id ~selection
          ~now:(current_unix_seconds ())
    | Health.Gc_quarantine _ ->
        Repair.apply_from_gc_quarantine ~root ~plan_id ~selection
          ~now:(current_unix_seconds ())
    | Health.Offline_package _ ->
        Repair.apply_from_offline_package ~root ~plan_id ~selection
          ~now:(current_unix_seconds ())
    | Health.Configured_relay _ ->
        Repair.apply_from_configured_relay ~root ~plan_id ~selection
          ~now:(current_unix_seconds ())
    | Health.Bootstrap_artifact _ ->
        Repair.apply_from_bootstrap_artifact ~root ~plan_id ~selection
          ~now:(current_unix_seconds ())
  in
  match result with
  | Error error ->
      fail_health format "repair-apply" "repair-apply-failed"
        (Repair.error_to_string error)
  | Ok (Repair.Refused refusal) ->
      fail_health format "repair-apply"
        (health_refusal_code refusal)
        (Health.refusal_to_string refusal)
  | Ok (Repair.Applied candidate) ->
      render_health_result format "repair-apply"
        (`Assoc [ ("candidate", json_of_candidate candidate) ])
        (fun () ->
          Printf.printf "repair applied %s\n" (Health.candidate_id candidate))

let run_repair_defer arguments =
  let root, format = parse_health_arguments arguments in
  let report = Health_repository.verify ~root in
  render_health_result format "repair-defer"
    (`Assoc [ ("deferred", `Bool true); ("report", json_of_report report) ])
    (fun () -> print_endline "repair deferred; no repair was recorded")

let render_workspace_materialization verb materialized =
  let receipt = materialized.Service.workspace_receipt in
  Printf.printf "workspace %s\n" verb;
  Printf.printf "basis %s\n" (Workspace.receipt_imported_basis_id receipt);
  Printf.printf "snapshot %s\n"
    (Model.Snapshot_id.to_string (Workspace.receipt_snapshot receipt));
  Printf.printf "tree %s\n" (Workspace.receipt_canonical_tree receipt);
  Printf.printf "activation-generation %Ld\n"
    (Workspace.receipt_activation_generation receipt);
  match
    ( materialized.Service.workspace_safety_checkpoint,
      materialized.Service.workspace_restore_proof )
  with
  | Some checkpoint, Some proof ->
      Printf.printf "safety-checkpoint %s\n"
        (Model.Snapshot_id.to_string checkpoint);
      Printf.printf "restore-proof %s\n" proof
  | None, None -> ()
  | Some _, None | None, Some _ ->
      fail "workspace materialisation returned incomplete safety evidence"

let run_workspace_activate arguments =
  let root = parse_workspace_activate arguments in
  Service.workspace_activate ~root
  |> require_ok Service.error_to_string
  |> render_workspace_materialization "activated"

let run_workspace_update arguments =
  let root, replace = parse_workspace_update arguments in
  match
    Service.workspace_update ~root ~replace
    |> require_ok Service.error_to_string
  with
  | Service.Workspace_already_current receipt ->
      Printf.printf "workspace already-current\n";
      Printf.printf "basis %s\n" (Workspace.receipt_imported_basis_id receipt);
      Printf.printf "activation-generation %Ld\n"
        (Workspace.receipt_activation_generation receipt);
      false
  | Service.Workspace_updated materialized ->
      render_workspace_materialization "updated" materialized;
      true

let run_init arguments =
  let root, username, draft, title = parse_init arguments in
  let initial_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  (try
     let metadata = Filename.concat root ".yeokcham" in
     (match Unix.lstat metadata with
     | _ ->
         fail_with_status 2 "already-initialized"
           "refusing to initialize over existing Yeokcham metadata"
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
     match Unix.lstat root with
     | stats when stats.Unix.st_kind = Unix.S_DIR -> ()
     | _ ->
         fail_with_status 2 "invalid-root" "initialization requires a directory"
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Unix.mkdir root 0o755
   with Unix.Unix_error (error, operation, _) ->
     fail_with_status 5 "initialization-unavailable"
       (operation ^ " failed: " ^ Unix.error_message error));
  let repository =
    Trust.Repository_id.generate ()
    |> require_ok (fun error ->
        "could not generate V1 repository identity: " ^ error)
  in
  let device, signing_capability =
    match V1_signer.create () with
    | Ok value -> value
    | Error error ->
        fail_with_status 5 "credential-provider-unavailable"
          (V1_signer.error_to_string error)
  in
  let recovery = Trust.generate_device () |> require_ok Trust.error_to_string in
  let recovery_device = Trust.generated_identity recovery in
  let recovery_capability = Trust.generated_signing_capability recovery in
  let root_certificate =
    Trust.root_certificate ~repository ~device signing_capability
    |> require_ok Trust.error_to_string
  in
  let status, ceremony =
    Service.init_local_signed_with_recovery ~root ~username ~initial_draft
      ~title ~repository ~device ~signing_capability ~recovery_device
      ~recovery_capability
    |> require_ok Service.error_to_string
  in
  if requested_details () then (
    render_status status;
    print_endline "branch main (initial files remain private)";
    print_endline "automatic-capture not configured; run save or foreground watch";
    print_endline "private-backup not configured";
    print_endline "root-verification-phrase (compare during device join)";
    Printf.printf "%s\n" (Recovery.verification_phrase root_certificate);
    Printf.printf "recovery-package %s\n" (Output.display_value (Service.recovery_package_path root));
    print_endline "recovery-mnemonic (record offline; it is shown only now)";
    Printf.printf "%s\n" ceremony.Yeokcham_v1_recovery.mnemonic)
  else (
    Output.line ~tone:Output.Good (Output.symbol ~ascii:"+" ~unicode:"✓" ^ " Project ready");
    Output.line ("  " ^ Output.display_value (Filename.basename (Unix.realpath root)) ^ " / main");
    Output.line ~tone:Output.Muted "  Existing files saved privately on this device.";
    Output.line "";
    Output.line ~tone:Output.Caution "Recovery words - shown once";
    let words = String.split_on_char ' ' ceremony.Yeokcham_v1_recovery.mnemonic in
    let rec rows = function
      | [] -> ()
      | words ->
          let count = if Output.terminal_width () < 60 then 3 else 6 in
          let rec take n acc rest = if n = 0 then (List.rev acc,rest) else match rest with [] -> (List.rev acc,[]) | word :: rest -> take (n - 1) (word :: acc) rest in
          let row,rest = take count [] words in
          Output.line ("  " ^ String.concat " " row); rows rest
    in rows words;
    Output.line ~tone:Output.Muted "  Record offline. Keep private.";
    Output.line "";
    Output.line "Next  edit your files, then run yeokcham save";
    Output.line ~tone:Output.Muted "Capture is manual; private backup is not configured.")

let parse_join arguments =
  let rec loop root username draft title device package phrase = function
    | [] -> (
        match (username, draft, title, device, package, phrase) with
        | ( Some username,
            Some draft,
            Some title,
            Some device,
            Some package,
            Some phrase ) ->
            ( Option.value root ~default:default_root,
              username,
              draft,
              title,
              device,
              package,
              phrase )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) username draft title device package phrase rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root (Some value) draft title device package phrase rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root username (Some value) title device package phrase rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root username draft (Some value) device package phrase rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root username draft title (Some value) package phrase rest
    | "--from" :: value :: rest when Option.is_none package ->
        loop root username draft title device (Some value) phrase rest
    | "--verify-phrase" :: value :: rest when Option.is_none phrase ->
        loop root username draft title device package (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None None arguments

let run_join arguments =
  let root, username, draft, title, device, package, phrase =
    parse_join arguments
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  let initial_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  let device_id =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let authority =
    Package.inspect_authority ~package |> require_ok Package.error_to_string
  in
  let root_certificate =
    match
      Trust.certificates (Trust.authority_membership authority)
      |> List.find_opt (fun certificate ->
          Trust.certificate_issuer certificate = None)
    with
    | Some certificate -> certificate
    | None -> fail "authority closure has no root certificate"
  in
  if not (String.equal phrase (Recovery.verification_phrase root_certificate))
  then fail "root verification phrase does not match the authority closure";
  let signing_capability =
    V1_signer.load_native device_id |> require_ok V1_signer.error_to_string
  in
  let local_device =
    Trust.signing_public_key signing_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal device_id (Trust.device_id local_device)) then
    fail "local signing capability does not match --device";
  let local_certificate =
    match
      Trust.certificates (Trust.authority_membership authority)
      |> List.find_opt (fun certificate ->
          Model.Device_id.equal
            (Trust.device_id (Trust.certificate_subject certificate))
            device_id)
    with
    | Some certificate -> Trust.certificate_id certificate
    | None -> fail "device is not enrolled in the authority closure"
  in
  Service.init_authority_collaboration ~root ~username ~initial_draft ~title
    ~device:local_device ~authority ~local_certificate
  |> require_ok Service.error_to_string
  |> render_status;
  print_endline
    "join verified authority closure; receive the package separately"

let local_signing_capability root =
  let identity = Service.identity ~root |> require_ok Service.error_to_string in
  V1_signer.load ~root (Trust.device_id identity.Service.device)
  |> require_ok V1_signer.error_to_string

let parse_user_register arguments =
  let rec loop root device username = function
    | [] -> (
        match (device, username) with
        | Some device, Some username ->
            (Option.value root ~default:default_root, device, username)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device username rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) username rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root device (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_user_register arguments =
  let root, device, username = parse_user_register arguments in
  let device =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  Service.register_username ~root ~device ~username
  |> require_ok Service.error_to_string
  |> render_status

let run_save arguments =
  let root = parse_root arguments in
  let result = Service.save ~root |> require_local in
  let changed, status =
    match result with
    | Service.Unchanged status -> (false, status)
    | Service.Saved status -> (true, status)
  in
  (match requested_format () with
  | Json_format ->
      domain_json
        ~outcome:(if changed then `Completed else `Unchanged)
        ~code:(if changed then "capture-saved" else "capture-unchanged")
        ~message:
          (if changed then "A complete local capture was saved."
           else "The saved contents already match disk.")
        ~data:
          (`Assoc
             [
               ( "snapshot_id",
                 `String (Model.Snapshot_id.to_string status.Service.checkpoint)
               );
               ( "draft_id",
                 `String
                   (Model.Draft_id.to_string
                      status.Service.active_draft.Model.draft_id) );
               ("changed", `Bool changed);
               ("private_backup", `String "not-configured");
             ])
        ~next_actions:
          [ action ~root [ "history" ] "Inspect saved work and alternatives." ]
        ()
  | Text_format ->
      if requested_details () then (
        print_endline (if changed then "save recorded" else "save unchanged");
        render_status status)
      else Output.line ~tone:Output.Good
          (let history = Service.local_history ~root |> require_local in
           let sequence = (History.current history.Service.undo_tree).History.id in
           (if changed then Output.symbol ~ascii:"+" ~unicode:"✓" ^ " Saved #"
            else Output.symbol ~ascii:"=" ~unicode:"✓" ^ " Already saved #")
           ^ Int64.to_string sequence ^ " on this device"));
  changed

let[@warning "-4"] run_ignore_explain arguments =
  let rec parse root path = function
    | "--root" :: value :: rest when Option.is_none root ->
        parse (Some value) path rest
    | [ "--"; value ] when Option.is_none path ->
        (Option.value root ~default:default_root, value)
    | value :: rest
      when Option.is_none path && not (String.starts_with ~prefix:"-" value) ->
        parse root (Some value) rest
    | [] -> (
        match path with
        | Some path -> (Option.value root ~default:default_root, path)
        | None -> usage ())
    | _ -> usage ()
  in
  let root, path = parse None None arguments in
  let rec strip_relative p =
    if String.starts_with ~prefix:"./" p then
      strip_relative (String.sub p 2 (String.length p - 2))
    else p
  in
  let path = strip_relative path in
  let directory = String.ends_with ~suffix:"/" path in
  let path =
    if directory then String.sub path 0 (String.length path - 1) else path
  in
  let explanation =
    match
      Service.ignore_explain ~directory ~root (String.split_on_char '/' path)
    with
    | Ok explanation -> explanation
    | Error
        (Service.Snapshot_error (Yeokcham_snapshot.Invalid_ignore_rule _) as
         error) ->
        fail_with "invalid-ignore-rule" (Service.error_to_string error)
    | Error (Service.Snapshot_error (Yeokcham_snapshot.Invalid_name _) as error)
      ->
        fail_with "invalid-path" (Service.error_to_string error)
    | Error error ->
        fail_with_status 5 "ignore-inspection-unavailable"
          (Service.error_to_string error)
  in
  let source, line, pattern, mandatory =
    match explanation.Yeokcham_snapshot.reason with
    | Yeokcham_snapshot.Mandatory_exclusion -> (None, None, None, true)
    | Yeokcham_snapshot.No_rule -> (None, None, None, false)
    | Yeokcham_snapshot.Native_rule rule ->
        ( Some (Yeokcham_snapshot.Ignore.source rule),
          Some (Yeokcham_snapshot.Ignore.line rule),
          Some (Yeokcham_snapshot.Ignore.pattern rule),
          false )
  in
  let string_option = function
    | None -> `Null
    | Some s when Result.is_ok (Yeokcham_encoding.text s) -> `String s
    | Some _ -> `Null
  in
  match requested_format () with
  | Json_format ->
      Cli_data.domain_success ~command:"ignore-explain" ~outcome:`Completed
        ~code:"ignore-explained" ~message:"Capture rules inspected."
        ~warnings:[]
        ~data:
          (`Assoc
             [
               ("outcome", `String "completed");
               ("path", string_option (Some path));
               ("path_display", `String (Output.display_value path));
               ("path_bytes_hex", `String (hex_of_bytes path));
               ("ignored", `Bool explanation.Yeokcham_snapshot.ignored);
               ("mandatory", `Bool mandatory);
               ("source", string_option source);
               ( "source_bytes_hex",
                 Option.fold ~none:`Null
                   ~some:(fun value -> `String (hex_of_bytes value))
                   source );
               ("line", match line with None -> `Null | Some n -> `Int n);
               ("pattern", string_option pattern);
               ( "pattern_bytes_hex",
                 Option.fold ~none:`Null
                   ~some:(fun value -> `String (hex_of_bytes value))
                   pattern );
               ( "blocked_by_parent",
                 `Bool explanation.Yeokcham_snapshot.blocked_by_parent );
             ])
        ~next_actions:[] ()
      |> Cli_data.encode |> print_json
  | Text_format ->
      Printf.printf "%s: %s\n"
        (Output.display_value path)
        (if explanation.Yeokcham_snapshot.ignored then "excluded from capture"
         else "included in capture");
      (if mandatory then print_endline "mandatory Yeokcham metadata exclusion"
       else
         match (source, line, pattern) with
         | Some source, Some line, Some pattern ->
             Printf.printf "rule %s:%d %s\n"
               (Output.display_value source)
               line
               (Output.display_value pattern)
         | _ -> print_endline "no native rule matched");
      if explanation.Yeokcham_snapshot.blocked_by_parent then
        print_endline
          "the parent is excluded; re-include it before re-including this path"

let inspection_width () =
  match Option.bind (Sys.getenv_opt "COLUMNS") int_of_string_opt with
  | Some width when width >= 40 -> width
  | Some _ | None -> 80

let inspection_state root =
  let state =
    Service.inspection_state ~root |> require_ok Service.error_to_string
  in
  Inspection.state ~project:state.Service.inspection_project
    ~signed_revisions:state.Service.inspection_signed_revisions
    ~authority:state.Service.inspection_authority
    ~review_publications:state.Service.inspection_review_publications

let run_log arguments =
  let root = parse_root arguments in
  inspection_state root
  |> Inspection.render_log ~width:(inspection_width ())
  |> print_string

let parse_graph arguments =
  let rec loop root authority = function
    | [] -> (Option.value root ~default:default_root, authority)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) authority rest
    | "--authority" :: rest when not authority -> loop root true rest
    | _ -> usage ()
  in
  loop None false arguments

let run_graph arguments =
  let root, authority = parse_graph arguments in
  let state = inspection_state root in
  let width = inspection_width () in
  if authority then
    match Inspection.render_authority_graph ~width state with
    | Some output -> print_string output
    | None -> fail "authority graph requires signed authority state"
  else Inspection.render_work_graph ~width state |> print_string

let parse_device_create arguments =
  let rec loop root provider module_path token_label key_label key_id = function
    | [] ->
        ( root,
          Option.value provider ~default:"native",
          module_path,
          token_label,
          key_label,
          key_id )
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) provider module_path token_label key_label key_id rest
    | "--provider" :: value :: rest when Option.is_none provider ->
        loop root (Some value) module_path token_label key_label key_id rest
    | "--module" :: value :: rest when Option.is_none module_path ->
        loop root provider (Some value) token_label key_label key_id rest
    | "--token-label" :: value :: rest when Option.is_none token_label ->
        loop root provider module_path (Some value) key_label key_id rest
    | "--key-label" :: value :: rest when Option.is_none key_label ->
        loop root provider module_path token_label (Some value) key_id rest
    | "--key-id" :: value :: rest when Option.is_none key_id ->
        loop root provider module_path token_label key_label (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None arguments

let run_device_create arguments =
  let root, provider, module_path, token_label, key_label, key_id =
    parse_device_create arguments
  in
  let device =
    match provider with
    | "native" ->
        if
          Option.is_some root || Option.is_some module_path
          || Option.is_some token_label || Option.is_some key_label
          || Option.is_some key_id
        then usage ();
        let device, _ =
          V1_signer.create () |> require_ok V1_signer.error_to_string
        in
        device
    | "pkcs11" -> (
        match (root, module_path, token_label, key_label, key_id) with
        | ( Some root,
            Some module_path,
            Some token_label,
            Some key_label,
            Some key_id ) -> (
            Custody.create_pkcs11 ~root ~module_path ~token_label ~key_label
              ~key_id:(bytes_of_hex key_id)
            |> require_ok Custody.error_to_string
            |> fun device_id ->
            Custody.inspect ~root device_id
            |> require_ok Custody.error_to_string
            |> fun profile ->
            match profile.Custody.provider with
            | Custody.Pkcs11 { public_key; _ } ->
                Trust.device_of_public_key public_key
                |> require_ok Trust.error_to_string
            | Custody.Ssh_agent _ -> fail "invalid PKCS#11 custody profile")
        | _ -> usage ())
    | _ -> fail "--provider must be native or pkcs11"
  in
  Printf.printf "device %s\n"
    (Model.Device_id.to_string (Trust.device_id device));
  Printf.printf "public-key %s\n"
    (hex_of_bytes (Trust.device_public_key device));
  if String.equal provider "pkcs11" then
    print_endline
      "non-extractable token key created; authority remains unchanged"

let run_device_show arguments =
  let root = parse_root arguments in
  let identity = Service.identity ~root |> require_ok Service.error_to_string in
  Printf.printf "repository %s\n"
    (Trust.Repository_id.to_string identity.Service.repository);
  Printf.printf "device %s\n"
    (Model.Device_id.to_string (Trust.device_id identity.Service.device));
  Printf.printf "public-key %s\n"
    (hex_of_bytes (Trust.device_public_key identity.Service.device));
  Printf.printf "role %s\n"
    (match identity.Service.role with
    | Trust.Member -> "member"
    | Trust.Administrator -> "administrator");
  if requested_format () = Text_format then (
    let state = Service.inspection_state ~root |> require_ok Service.error_to_string in
    Option.iter (fun authority ->
        Trust.certificates (Trust.authority_membership authority)
        |> List.find_opt (fun certificate -> Trust.certificate_issuer certificate = None)
        |> Option.iter (fun certificate ->
            print_endline "root-verification-phrase (compare during device join)";
            print_endline (Recovery.verification_phrase certificate))) state.Service.inspection_authority)

let parse_device_attach arguments =
  let rec loop root provider public_key module_path token_label key_id =
    function
    | [] -> (
        match (root, provider, public_key) with
        | Some root, Some provider, Some public_key ->
            (root, provider, public_key, module_path, token_label, key_id)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) provider public_key module_path token_label key_id
          rest
    | "--provider" :: value :: rest when Option.is_none provider ->
        loop root (Some value) public_key module_path token_label key_id rest
    | "--public-key" :: value :: rest when Option.is_none public_key ->
        loop root provider (Some value) module_path token_label key_id rest
    | "--module" :: value :: rest when Option.is_none module_path ->
        loop root provider public_key (Some value) token_label key_id rest
    | "--token-label" :: value :: rest when Option.is_none token_label ->
        loop root provider public_key module_path (Some value) key_id rest
    | "--key-id" :: value :: rest when Option.is_none key_id ->
        loop root provider public_key module_path token_label (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None arguments

let run_device_attach arguments =
  let root, provider, public_key, module_path, token_label, key_id =
    parse_device_attach arguments
  in
  let device =
    match provider with
    | "ssh-agent" ->
        if
          Option.is_some module_path || Option.is_some token_label
          || Option.is_some key_id
        then usage ();
        let public_key =
          Custody.ssh_public_key_file public_key
          |> require_ok Custody.error_to_string
        in
        Custody.attach_ssh_agent ~root ~public_key
        |> require_ok Custody.error_to_string
    | "pkcs11" -> (
        match (module_path, token_label, key_id) with
        | Some module_path, Some token_label, Some key_id ->
            let public_key = bytes_of_hex public_key in
            let key_id = bytes_of_hex key_id in
            Custody.attach_pkcs11 ~root ~module_path ~token_label ~key_id
              ~public_key
            |> require_ok Custody.error_to_string
        | _ -> usage ())
    | _ -> fail "--provider must be ssh-agent or pkcs11"
  in
  Printf.printf "device %s\n" (Model.Device_id.to_string device);
  print_endline "custody profile saved locally; authority remains unchanged"

let parse_device_custody arguments =
  let rec loop root device = function
    | [] -> (
        match device with
        | Some device -> (Option.value root ~default:default_root, device)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_device_custody arguments =
  let root, device = parse_device_custody arguments in
  let device =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let profile =
    Custody.inspect ~root device |> require_ok Custody.error_to_string
  in
  Printf.printf "device %s\n" (Model.Device_id.to_string profile.Custody.device);
  match profile.Custody.provider with
  | Custody.Ssh_agent { public_key } -> (
      print_endline "provider ssh-agent";
      Printf.printf "public-key %s\n" (hex_of_bytes public_key);
      match Custody.ssh_agent_available ~public_key with
      | Ok () -> print_endline "availability available"
      | Error error ->
          Printf.printf "availability unavailable: %s\n"
            (Custody.error_to_string error))
  | Custody.Pkcs11 { module_path; token_label; key_id; public_key } -> (
      print_endline "provider pkcs11";
      Printf.printf "public-key %s\n" (hex_of_bytes public_key);
      match Custody.pkcs11_available ~module_path ~token_label ~key_id with
      | Ok () ->
          print_endline
            "availability available (public key found; PIN signing is separate)"
      | Error error ->
          Printf.printf "availability unavailable: %s\n"
            (Custody.error_to_string error))

let parse_device_enroll arguments =
  let rec loop root device public_key username administrator parent = function
    | [] -> (
        match (device, public_key, username) with
        | Some device, Some public_key, Some username ->
            ( Option.value root ~default:default_root,
              device,
              public_key,
              username,
              administrator,
              parent )
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device public_key username administrator parent rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) public_key username administrator parent rest
    | "--public-key" :: value :: rest when Option.is_none public_key ->
        loop root device (Some value) username administrator parent rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root device public_key (Some value) administrator parent rest
    | "--administrator" :: rest when not administrator ->
        loop root device public_key username true parent rest
    | "--parent" :: value :: rest when Option.is_none parent ->
        loop root device public_key username administrator (Some value) rest
    | _ -> usage ()
  in
  loop None None None None false None arguments

let run_device_enroll arguments =
  let root, device, public_key, username, administrator, parent =
    parse_device_enroll arguments
  in
  let expected =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let subject =
    bytes_of_hex public_key |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal expected (Trust.device_id subject)) then
    fail "device identifier does not match public key";
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  let signing_capability = local_signing_capability root in
  let role = if administrator then Trust.Administrator else Trust.Member in
  Service.enroll_device ~parent ~root ~subject ~role ~username
    ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_device_only arguments =
  let rec loop root device parent = function
    | [] -> (
        match device with
        | Some device ->
            (Option.value root ~default:default_root, device, parent)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device parent rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) parent rest
    | "--parent" :: value :: rest when Option.is_none parent ->
        loop root device (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_device_revoke arguments =
  let root, device, parent = parse_device_only arguments in
  let device =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let signing_capability = local_signing_capability root in
  Service.revoke_device ~parent ~root ~device ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_device_key arguments =
  let rec loop root device public_key parent = function
    | [] -> (
        match (device, public_key) with
        | Some device, Some public_key ->
            (Option.value root ~default:default_root, device, public_key, parent)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device public_key parent rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) public_key parent rest
    | "--public-key" :: value :: rest when Option.is_none public_key ->
        loop root device (Some value) parent rest
    | "--parent" :: value :: rest when Option.is_none parent ->
        loop root device public_key (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_device_rotate arguments =
  let root, device, public_key, parent = parse_device_key arguments in
  let expected =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let replacement =
    bytes_of_hex public_key |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal expected (Trust.device_id replacement)) then
    fail "device identifier does not match public key";
  let signing_capability = local_signing_capability root in
  Service.rotate_local_device ~parent ~root ~replacement ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let run_authority_heads arguments =
  let root = parse_root arguments in
  Service.authority_heads ~root
  |> require_ok Service.error_to_string
  |> List.iter (fun epoch -> Printf.printf "authority-head %s\n" epoch)

let parse_authority_reconcile arguments =
  let rec loop root parents = function
    | [] -> (
        match parents with
        | Some parents -> (Option.value root ~default:default_root, parents)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) parents rest
    | "--parents" :: value :: rest when Option.is_none parents ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_authority_reconcile arguments =
  let root, parents = parse_authority_reconcile arguments in
  let parents =
    if String.equal parents "" then
      fail "--parents must name at least two authority heads"
    else String.split_on_char ',' parents
  in
  let signing_capability = local_signing_capability root in
  Service.reconcile_authority ~root ~parents ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_recovery_use arguments =
  let rec loop root package mnemonic replacement replaced output = function
    | [] -> (
        match (package, mnemonic, replacement, replaced, output) with
        | ( Some package,
            Some mnemonic,
            Some replacement,
            Some replaced,
            Some output ) ->
            ( Option.value root ~default:default_root,
              package,
              mnemonic,
              replacement,
              replaced,
              output )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package mnemonic replacement replaced output rest
    | "--package" :: value :: rest when Option.is_none package ->
        loop root (Some value) mnemonic replacement replaced output rest
    | "--mnemonic" :: value :: rest when Option.is_none mnemonic ->
        loop root package (Some value) replacement replaced output rest
    | "--replacement" :: value :: rest when Option.is_none replacement ->
        loop root package mnemonic (Some value) replaced output rest
    | "--replaced" :: value :: rest when Option.is_none replaced ->
        loop root package mnemonic replacement (Some value) output rest
    | "--output" :: value :: rest when Option.is_none output ->
        loop root package mnemonic replacement replaced (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None arguments

let run_recovery_use arguments =
  let root, package, mnemonic, replacement, replaced, output =
    parse_recovery_use arguments
  in
  let replacement_id =
    parse_identifier "invalid replacement device identifier"
      Model.Device_id.of_string replacement
  in
  let replaced =
    parse_identifier "invalid replaced device identifier"
      Model.Device_id.of_string replaced
  in
  let replacement_capability =
    V1_signer.load ~root replacement_id |> require_ok V1_signer.error_to_string
  in
  let replacement_device =
    Trust.signing_public_key replacement_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let status, ceremony =
    Service.recover_authority ~root ~package ~mnemonic ~output
      ~replacement:replacement_device ~replaced
    |> require_ok Service.error_to_string
  in
  render_status status;
  Printf.printf "recovery-package %s\n" output;
  print_endline "recovery-mnemonic (record offline; it is shown only now)";
  Printf.printf "%s\n" ceremony.Recovery.mnemonic

let parse_recovery_refresh arguments =
  let rec loop root package mnemonic output = function
    | [] -> (
        match (package, mnemonic, output) with
        | Some package, Some mnemonic, Some output ->
            (Option.value root ~default:default_root, package, mnemonic, output)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package mnemonic output rest
    | "--package" :: value :: rest when Option.is_none package ->
        loop root (Some value) mnemonic output rest
    | "--mnemonic" :: value :: rest when Option.is_none mnemonic ->
        loop root package (Some value) output rest
    | "--output" :: value :: rest when Option.is_none output ->
        loop root package mnemonic (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_recovery_refresh arguments =
  let root, package, mnemonic, output = parse_recovery_refresh arguments in
  Service.refresh_recovery_package ~root ~package ~mnemonic ~output
  |> require_ok Service.error_to_string;
  Printf.printf "recovery-package %s\n" output

let run_timeline arguments =
  let root = parse_root arguments in
  let state =
    Service.inspection_state ~root |> require_ok Service.error_to_string
  in
  List.iter
    (fun checkpoint ->
      Printf.printf "checkpoint %s\n"
        (Model.Snapshot_id.to_string checkpoint.Model.checkpoint_snapshot))
    (Model.checkpoints state.Service.inspection_project)

let parse_restore_operation arguments =
  let rec loop root operation = function
    | [] -> (
        match operation with
        | Some operation -> (Option.value root ~default:default_root, operation)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) operation rest
    | "--operation" :: value :: rest when Option.is_none operation ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_restore_proofs arguments =
  Service.restore_proofs ~root:(parse_root arguments)
  |> require_ok Service.error_to_string
  |> List.iter (fun proof ->
      Printf.printf "restore-proof %s safety %s target %s\n"
        proof.Service.proof_operation
        (Model.Snapshot_id.to_string proof.Service.proof_safety)
        (Model.Snapshot_id.to_string proof.Service.proof_target))

let run_restore_retain arguments =
  let root, operation = parse_restore_operation arguments in
  let proof =
    Service.retain_restore_proof ~root ~operation
    |> require_ok Service.error_to_string
  in
  Printf.printf "restore-proof %s safety %s target %s\n"
    proof.Service.proof_operation
    (Model.Snapshot_id.to_string proof.Service.proof_safety)
    (Model.Snapshot_id.to_string proof.Service.proof_target)

let run_restore_forget arguments =
  let root, operation = parse_restore_operation arguments in
  Service.forget_restore_proof ~root ~operation
  |> require_ok Service.error_to_string;
  Printf.printf "restore-proof forgotten %s\n" operation

let run_storage_roots arguments =
  Service.storage_roots ~root:(parse_root arguments)
  |> require_ok Service.error_to_string
  |> List.iter (fun root ->
      Printf.printf "root %s %s\n"
        (Model.Snapshot_id.to_string root.Service.root_snapshot)
        (root.Service.root_reasons
        |> List.map Model.protection_reason_to_string
        |> String.concat ","))

let render_gc_plan plan explain =
  if explain then
    List.iter
      (fun object_ ->
        let object_id =
          Yeokcham_store.Stored_object_id.to_hex object_.Gc.object_id
        in
        match object_.Gc.disposition with
        | Gc.Retain reasons ->
            Printf.printf "retain %s type:%d bytes:%d %s\n" object_id
              (Yeokcham_envelope.object_type_code object_.Gc.object_type)
              object_.Gc.stored_bytes
              (reasons |> List.map Gc.root_reason_to_string |> String.concat ",")
        | Gc.Collect ->
            Printf.printf "collect %s type:%d bytes:%d\n" object_id
              (Yeokcham_envelope.object_type_code object_.Gc.object_type)
              object_.Gc.stored_bytes)
      plan.Gc.objects;
  let retained_objects =
    List.length
      (List.filter
         (fun object_ ->
           match object_.Gc.disposition with
           | Gc.Retain _ -> true
           | Gc.Collect -> false)
         plan.Gc.objects)
  in
  let collectible_objects = List.length plan.Gc.objects - retained_objects in
  Printf.printf "retain-objects %d\n" retained_objects;
  Printf.printf "retain-bytes %d\n" plan.Gc.retained_bytes;
  Printf.printf "collect-objects %d\n" collectible_objects;
  Printf.printf "collect-bytes %d\n" plan.Gc.collectible_bytes

let parse_storage_gc arguments =
  let rec loop root dry_run apply explain = function
    | [] ->
        if dry_run && apply then usage ()
        else (Option.value root ~default:default_root, apply, explain)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) dry_run apply explain rest
    | "--dry-run" :: rest when not dry_run -> loop root true apply explain rest
    | "--apply" :: rest when not apply -> loop root dry_run true explain rest
    | "--explain" :: rest when not explain -> loop root dry_run apply true rest
    | _ -> usage ()
  in
  loop None false false false arguments

let parse_storage_gc_id arguments =
  let rec loop root id = function
    | [] -> (
        match id with
        | Some id -> (Option.value root ~default:default_root, id)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let render_gc_progress progress =
  let transaction = progress.Gc.progress_transaction in
  Printf.printf "gc-transaction %s\n" (Gc.transaction_id transaction);
  Printf.printf "staged-objects %d\n" (List.length progress.Gc.staged_objects);
  Printf.printf "active-objects %d\n" (List.length progress.Gc.active_objects);
  Printf.printf "purged-objects %d\n" (List.length progress.Gc.purged_objects);
  Printf.printf "purge-started %s\n"
    (if progress.Gc.purge_started then "yes" else "no")

let run_storage_gc = function
  | "status" :: arguments ->
      Gc.transactions ~root:(parse_root arguments)
      |> require_ok Gc.error_to_string
      |> List.iter render_gc_progress
  | "resume" :: arguments ->
      let root, id = parse_storage_gc_id arguments in
      Gc.resume ~root ~id |> require_ok Gc.error_to_string |> render_gc_progress
  | "restore" :: arguments ->
      let root, id = parse_storage_gc_id arguments in
      Gc.restore ~root ~id |> require_ok Gc.error_to_string;
      Printf.printf "gc-restored %s\n" id
  | "purge" :: arguments ->
      let root, id = parse_storage_gc_id arguments in
      let reclaimed = Gc.purge ~root ~id |> require_ok Gc.error_to_string in
      Printf.printf "gc-purged %s bytes:%d\n" id reclaimed
  | arguments ->
      let root, apply, explain = parse_storage_gc arguments in
      if apply then (
        if explain then usage ();
        Gc.apply ~root |> require_ok Gc.error_to_string |> render_gc_progress)
      else
        Gc.plan ~root |> require_ok Gc.error_to_string |> fun plan ->
        render_gc_plan plan explain

let parse_share arguments =
  let rec loop root change revision authority = function
    | [] -> (
        match (change, revision) with
        | Some change, Some revision ->
            ( Option.value root ~default:default_root,
              change,
              revision,
              authority )
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) change revision authority rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root (Some value) revision authority rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root change (Some value) authority rest
    | "--authority" :: value :: rest when Option.is_none authority ->
        loop root change revision (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let parse_withdraw arguments =
  let rec loop root change = function
    | [] -> (
        match change with
        | Some change -> (Option.value root ~default:default_root, change)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) change rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_resolve arguments =
  let rec loop root decision change revision tree authority = function
    | [] -> (
        match (decision, change, revision) with
        | Some decision, Some change, Some revision ->
            ( Option.value root ~default:default_root,
              decision,
              change,
              revision,
              tree,
              authority )
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision change revision tree authority rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) change revision tree authority rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root decision (Some value) revision tree authority rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root decision change (Some value) tree authority rest
    | "--tree" :: value :: rest when Option.is_none tree ->
        loop root decision change revision (Some value) authority rest
    | "--authority" :: value :: rest when Option.is_none authority ->
        loop root decision change revision tree (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None arguments

let parse_decision_show arguments =
  let rec loop root decision = function
    | [] -> (
        match decision with
        | Some decision -> (Option.value root ~default:default_root, decision)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_decision_materialize arguments =
  let rec loop root decision destination = function
    | [] -> (
        match (decision, destination) with
        | Some decision, Some destination ->
            (Option.value root ~default:default_root, decision, destination)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision destination rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root decision (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let parse_decision_propose arguments =
  let rec loop root decision left right semantic_server = function
    | [] -> (
        match (decision, left, right) with
        | Some decision, None, None ->
            ( Option.value root ~default:default_root,
              decision,
              None,
              semantic_server )
        | Some decision, Some left, Some right ->
            ( Option.value root ~default:default_root,
              decision,
              Some (left, right),
              semantic_server )
        | None, _, _ | Some _, None, Some _ | Some _, Some _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision left right semantic_server rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) left right semantic_server rest
    | "--left" :: value :: rest when Option.is_none left ->
        loop root decision (Some value) right semantic_server rest
    | "--right" :: value :: rest when Option.is_none right ->
        loop root decision left (Some value) semantic_server rest
    | "--semantic-server" :: value :: rest when Option.is_none semantic_server
      ->
        loop root decision left right (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None arguments

let parse_decision_materialize_proposal arguments =
  let rec loop root decision left right destination = function
    | [] -> (
        match (decision, left, right, destination) with
        | Some decision, Some left, Some right, Some destination ->
            ( Option.value root ~default:default_root,
              decision,
              left,
              right,
              destination )
        | None, _, _, _ | _, None, _, _ | _, _, None, _ | _, _, _, None ->
            usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision left right destination rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) left right destination rest
    | "--left" :: value :: rest when Option.is_none left ->
        loop root decision (Some value) right destination rest
    | "--right" :: value :: rest when Option.is_none right ->
        loop root decision left (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root decision left right (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None arguments

let parse_decision_diff arguments =
  let rec loop root decision candidate against = function
    | [] -> (
        match (decision, candidate) with
        | Some decision, Some candidate ->
            ( Option.value root ~default:default_root,
              decision,
              candidate,
              Option.value against ~default:"base" )
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision candidate against rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) candidate against rest
    | "--candidate" :: value :: rest when Option.is_none candidate ->
        loop root decision (Some value) against rest
    | "--against" :: value :: rest when Option.is_none against ->
        loop root decision candidate (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let decision_kind_name = function
  | Model.Stale_base -> "stale-base"
  | Model.Edit_overlap -> "edit-overlap"

let edit_kind_name = function
  | Model.Whole_path -> "whole-path"
  | Model.Text span ->
      Printf.sprintf "text:%d-%d" span.Model.start_byte span.Model.end_byte

let render_decision (inspection : Service.decision_inspection) =
  let decision = inspection.Service.inspected_decision in
  Printf.printf "decision %s\n"
    (Model.Decision_id.to_string decision.Model.decision_id);
  Printf.printf "kind %s\n" (decision_kind_name decision.Model.decision_kind);
  List.iter
    (fun path ->
      Printf.printf "path %s\n"
        (Output.display_value (Model.Path.to_string path)))
    decision.Model.decision_paths;
  List.iter
    (fun candidate ->
      let revision = candidate.Service.inspected_revision in
      let username =
        match candidate.Service.inspected_username with
        | None -> "unregistered"
        | Some username -> Model.Username.to_string username
      in
      Printf.printf
        "candidate %s change %s author %s username %s base %s snapshot %s\n"
        (Model.Revision_id.to_string revision.Model.revision)
        (Model.Change_id.to_string revision.Model.change)
        (Model.Device_id.to_string revision.Model.revision_author)
        username
        (Model.Snapshot_id.to_string revision.Model.base_snapshot)
        (Model.Snapshot_id.to_string revision.Model.result_snapshot))
    inspection.Service.inspected_candidates;
  List.iter
    (fun candidate ->
      let revision = candidate.Model.candidate_revision in
      Printf.printf "edit %s %d %s %s\n"
        (Model.Revision_id.to_string revision.Model.revision)
        candidate.Model.candidate_edit_index
        (Output.display_value
           (Model.Path.to_string candidate.Model.candidate_edit.Model.edit_path))
        (edit_kind_name candidate.Model.candidate_edit.Model.edit_kind))
    decision.Model.candidates

let run_decision_show arguments =
  let root, decision = parse_decision_show arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  Service.inspect_decision ~root ~decision
  |> require_ok Service.error_to_string
  |> render_decision

let snapshot_entry_kind_name = function
  | Service.File -> "file"
  | Service.Directory -> "directory"

let snapshot_mode_name = function
  | Yeokcham_snapshot.Regular -> "regular"
  | Yeokcham_snapshot.Executable -> "executable"
  | Yeokcham_snapshot.Symlink -> "symlink"

let render_snapshot_entry = function
  | None -> "missing"
  | Some entry -> (
      let kind = snapshot_entry_kind_name entry.Service.kind in
      let mode = Option.map snapshot_mode_name entry.Service.mode in
      match (mode, entry.Service.content) with
      | None, None -> kind
      | Some mode, Some content -> kind ^ " " ^ mode ^ " " ^ content
      | Some mode, None -> kind ^ " " ^ mode
      | None, Some content -> kind ^ " " ^ content)

let history_json_node node =
  `Assoc
    [
      ("node", `String (Int64.to_string node.History.id));
      ( "parent",
        Option.fold ~none:`Null
          ~some:(fun id -> `String (Int64.to_string id))
          node.History.parent );
      ("checkpoint", `String (Model.Snapshot_id.to_string node.History.snapshot));
      ("draft", `String (Model.Draft_id.to_string node.History.draft));
      ("created_at", `Intlit (Int64.to_string node.History.created_at));
    ]

let history_json_result command result =
  Cli_data.success ~command ~result ~warnings:(List.rev !public_warnings)
  |> Cli_data.encode |> print_json

let json_ids values =
  `List (List.map (fun id -> `String (Core.Record_id.to_hex id)) values)

let render_branches ?created_branch listing =
  let selected = listing.Service.selected_branch in
  let workspace =
    Option.map Core.Workspace_id.to_hex listing.Service.workspace
  in
  let data =
    `Assoc
      [
        ( "workspace_id",
          Option.fold ~none:`Null ~some:(fun value -> `String value) workspace
        );
        ("selected_branch_id", `String (Core.Branch_id.to_hex selected));
        ( "created_branch_id",
          Option.fold ~none:`Null
            ~some:(fun id -> `String (Core.Branch_id.to_hex id))
            created_branch );
        ( "branches",
          `List
            (List.map
               (fun row ->
                 let position =
                   List.find_opt
                     (fun p ->
                       Core.Branch_id.equal p.Local.branch row.Core.branch_id)
                     listing.Service.private_positions
                 in
                 `Assoc
                   [
                     ("id", `String (Core.Branch_id.to_hex row.Core.branch_id));
                     ( "names",
                       `List
                         (List.map
                            (fun name -> `String name)
                            row.Core.display_names) );
                     ( "selected",
                       `Bool (Core.Branch_id.equal selected row.Core.branch_id)
                     );
                     ( "local_state",
                       `String
                         (if Core.Branch_id.equal selected row.Core.branch_id
                          then "selected"
                          else if Option.is_some position then "private_saved"
                          else "known_shared") );
                     ("event_heads", json_ids row.Core.event_heads);
                     ("accepted_heads", json_ids row.Core.accepted_heads);
                     ( "private_position",
                       Option.fold ~none:`Null
                         ~some:(fun p ->
                           `Assoc
                             [
                               ( "sequence",
                                 `String (Int64.to_string p.Local.cursor) );
                               ( "working_basis",
                                 `String (Core.Record_id.to_hex p.Local.basis)
                               );
                             ])
                         position );
                   ])
               listing.Service.shared_branches) );
      ]
  in
  match requested_format () with
  | Json_format ->
      domain_json ~outcome:`Completed
        ~code:
          (if Option.is_some created_branch then "branch-created"
           else "branches-inspected")
        ~message:
          (if Option.is_some created_branch then
             "A named branch was created; selection was preserved."
           else "Authenticated branches and private positions inspected.")
        ~data ~next_actions:[] ()
  | Text_format ->
      List.iter
        (fun row ->
          Printf.printf "%s %s branch:%s accepted:%s local:%s\n"
            (if Core.Branch_id.equal selected row.Core.branch_id then "*"
             else " ")
            (String.concat ", "
               (List.map Output.display_value row.Core.display_names))
            (Core.Branch_id.to_hex row.Core.branch_id)
            (String.concat ","
               (List.map Core.Record_id.to_hex row.Core.accepted_heads))
            (if
               List.exists
                 (fun position ->
                   Core.Branch_id.equal position.Local.branch row.Core.branch_id)
                 listing.Service.private_positions
             then "saved"
             else "known-shared"))
        listing.Service.shared_branches

let[@warning "-4"] fail_branch = function
  | Service.Snapshot_error error -> (
      match error with
      | Yeokcham_snapshot.Invalid_ignore_rule _
      | Yeokcham_snapshot.Invalid_ignore_path _ ->
          fail_with_status 2 "invalid-ignore-rule"
            (Yeokcham_snapshot.error_to_string error)
      | _ ->
          fail_with_status 5 "capture-incomplete"
            (Yeokcham_snapshot.error_to_string error))
  | Service.Trust_error error ->
      fail_with_status 7 "branch-authority-blocked"
        (Trust.error_to_string error)
  | Service.History_error message
    when String.starts_with ~prefix:"branch name " message
         && String.ends_with ~suffix:"it was not retargeted" message ->
      fail_with_status 2 "branch-name-exists" message
  | Service.History_error message
    when String.starts_with ~prefix:"core identity entropy unavailable:" message
    ->
      fail_with_status 5 "identity-entropy-unavailable" message
  | Service.History_error message
    when String.starts_with ~prefix:"branch has divergent" message
         || String.starts_with ~prefix:"branch name " message
            && String.ends_with ~suffix:"before switching" message ->
      fail_with_status 3 "branch-choice-required" message
  | Service.History_error message
    when String.starts_with ~prefix:"shared branch " message ->
      fail_with_status 3 "shared-branch-not-materialized" message
  | Service.History_error message
    when String.starts_with ~prefix:"unknown branch " message ->
      fail_with_status 2 "unknown-branch" message
  | (Service.Safe_application_error _ | Service.Selection_conflict _) as error
    ->
      fail_local error
  | error ->
      fail_with_status 6 "branch-operation-refused"
        (Service.error_to_string error)

let run_branch_list arguments =
  match Service.branch_list ~root:(parse_root arguments) with
  | Ok listing -> render_branches listing
  | Error error -> fail_branch error

let run_branch_create arguments =
  let rec parse root name = function
    | [] -> (
        match name with
        | Some name -> (Option.value root ~default:default_root, name)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        parse (Some value) name rest
    | "--" :: [ value ] when Option.is_none name -> parse root (Some value) []
    | value :: rest
      when Option.is_none name && not (String.starts_with ~prefix:"-" value) ->
        parse root (Some value) rest
    | _ -> usage ()
  in
  let root, name = parse None None arguments in
  (match Core.validate_branch_name name with
  | Ok () -> ()
  | Error error ->
      fail_with_status 2 "invalid-branch-name" (Core.error_to_string error));
  let identity = Service.identity ~root |> require_local in
  let signing_capability =
    match V1_signer.load ~root (Trust.device_id identity.Service.device) with
    | Ok capability -> capability
    | Error error ->
        fail_with_status 5 "credential-provider-unavailable"
          (V1_signer.error_to_string error)
  in
  match Service.branch_create ~root ~name ~signing_capability with
  | Ok listing ->
      let row =
        List.find
          (fun row -> List.mem name row.Core.display_names)
          listing.Service.shared_branches
      in
      render_branches ~created_branch:row.Core.branch_id listing
  | Error error -> fail_branch error

let json_optional f = Option.fold ~none:`Null ~some:f

let json_history_identity id =
  `Assoc
    [
      ( "workspace_id",
        `String (Core.Workspace_id.to_hex (Core.History_id.workspace id)) );
      ("sequence", `String (Int64.to_string (Core.History_id.sequence id)));
      ( "id",
        `String
          (Core.Workspace_id.to_hex (Core.History_id.workspace id)
          ^ ":"
          ^ Int64.to_string (Core.History_id.sequence id)) );
    ]

module Native_integrate = Service.Integrate
module Integration = Service.Integration
module Integration_op = Local.Operation

let phase_name = function
  | Integration_op.Prepared -> "prepared"
  | Integration_op.Applying -> "applying"
  | Integration_op.Materialized -> "materialized"
  | Integration_op.Committed -> "committed"
  | Integration_op.Completed -> "completed"
  | Integration_op.Paused _ -> "paused"

let recovery_progress_name = function
  | Integration_op.Recovery_prepared -> "prepared"
  | Integration_op.Recovery_applying -> "applying"
  | Integration_op.Recovery_materialized -> "materialized"
  | Integration_op.Recovery_committed -> "committed"
  | Integration_op.Recovery_completed -> "completed"

let recovery_mode_name = function
  | Integration_op.Restore_safety -> "restore_safety"
  | Integration_op.Keep_current -> "keep_current"

let recovery_target_of_operation operation recovery =
  match recovery.Integration_op.mode with
  | Integration_op.Restore_safety -> operation.Integration_op.safety
  | Integration_op.Keep_current -> recovery.Integration_op.observed

let json_operation_recovery operation =
  json_optional
    (fun recovery ->
      `Assoc
        [
          ( "plan_id",
            `String (Core.Digest.to_hex recovery.Integration_op.plan_id) );
          ( "attempt_id",
            `String (Core.Operation_id.to_hex recovery.Integration_op.attempt)
          );
          ("mode", `String (recovery_mode_name recovery.Integration_op.mode));
          ( "phase",
            `String (recovery_progress_name recovery.Integration_op.progress) );
          ( "observed_snapshot",
            `String (Core.Object_id.to_hex recovery.Integration_op.observed) );
          ( "target_snapshot",
            `String
              (Core.Object_id.to_hex
                 (recovery_target_of_operation operation recovery)) );
          ( "history_sequence",
            `Intlit (Int64.to_string operation.Integration_op.target_sequence)
          );
          ( "history_allocated",
            `Bool
              (match recovery.Integration_op.progress with
              | Integration_op.Recovery_committed
              | Integration_op.Recovery_completed ->
                  true
              | Integration_op.Recovery_prepared
              | Integration_op.Recovery_applying
              | Integration_op.Recovery_materialized ->
                  false) );
          ("retained", `Bool recovery.Integration_op.retained);
          ( "pause_reason",
            json_optional
              (fun reason -> `String reason)
              recovery.Integration_op.pause_reason );
          ( "previous_attempts",
            `Int (List.length operation.Integration_op.previous_recoveries) );
          ( "retained_observations",
            `List
              (List.map
                 (fun earlier ->
                   `String
                     (Core.Object_id.to_hex earlier.Integration_op.observed))
                 operation.Integration_op.previous_recoveries) );
        ])
    operation.Integration_op.recovery

let integration_transfer_state operation =
  if operation.Integration_op.acknowledged then "acknowledged"
  else if Integration_op.committed operation then
    if operation.Integration_op.staged = [] then "not_required" else "pending"
  else "not_committed"

let publication_transfer_state status revision =
  match status.Service.status_transfers with
  | Error _ -> ("unavailable", [])
  | Ok records -> (
      match List.assoc_opt revision records with
      | None | Some [] -> ("pending", [])
      | Some remotes -> ("acknowledged", remotes))

let json_integration_operation operation =
  `Assoc
    [
      ( "operation_id",
        `String (Core.Operation_id.to_hex operation.Integration_op.token) );
      ("plan_id", `String (Core.Plan_id.to_hex operation.Integration_op.plan));
      ("phase", `String (phase_name operation.Integration_op.phase));
      ("committed", `Bool (Integration_op.committed operation));
      ("recovered", `Bool (Integration_op.recovered operation));
      ("recovery", json_operation_recovery operation);
      ("outbound_state", `String (integration_transfer_state operation));
      ( "branch_id",
        `String (Core.Branch_id.to_hex operation.Integration_op.branch) );
      ("source_history", json_history_identity operation.Integration_op.source);
      ( "target_sequence",
        `Intlit (Int64.to_string operation.Integration_op.target_sequence) );
      ("target_sequence_allocated", `Bool (Integration_op.committed operation));
      ( "safety_snapshot",
        `String (Core.Object_id.to_hex operation.Integration_op.safety) );
      ( "workspace_snapshot",
        `String (Core.Object_id.to_hex operation.Integration_op.target) );
      ( "accepted_record",
        `String (Core.Record_id.to_hex operation.Integration_op.accepted) );
      ( "pause_reason",
        match operation.Integration_op.phase with
        | Integration_op.Paused (_, reason) -> `String reason
        | Integration_op.Prepared | Integration_op.Applying
        | Integration_op.Materialized | Integration_op.Committed
        | Integration_op.Completed ->
            `Null );
    ]

let json_state state =
  `Assoc
    [
      ("id", `String state.Service.state_name);
      ( "snapshot_id",
        `String (Model.Snapshot_id.to_string state.Service.state_snapshot) );
      ( "history",
        json_optional json_history_identity state.Service.history_identity );
    ]

let json_entry =
  json_optional (fun entry ->
      `Assoc
        [
          ( "kind",
            `String
              (match entry.Service.kind with
              | Service.File -> "file"
              | Service.Directory -> "directory") );
          ( "mode",
            json_optional
              (fun mode ->
                `String
                  (match mode with
                  | Yeokcham_snapshot.Regular -> "regular"
                  | Yeokcham_snapshot.Executable -> "executable"
                  | Yeokcham_snapshot.Symlink -> "symlink"))
              entry.Service.mode );
          ( "content_id",
            json_optional (fun id -> `String id) entry.Service.content );
        ])

let path_fields path =
  let raw = Model.Path.to_string path in
  let valid = Result.is_ok (Yeokcham_encoding.text raw) in
  [
    ("path", if valid then `String raw else `Null);
    ( "path_display",
      `String (if valid then Output.display_value raw else String.escaped raw)
    );
    ("path_bytes_hex", `String (hex_of_bytes raw));
  ]

let json_difference difference =
  `Assoc
    (path_fields difference.Service.path
    @ [
        ("before", json_entry difference.Service.before);
        ("after", json_entry difference.Service.after);
      ])

type local_selection_flags = {
  selection_root : string;
  selection_preview : bool;
  selection_yes : bool;
  selection_plan : string option;
}

let parse_local_selection_flags arguments =
  let rec loop root preview yes plan remaining = function
    | [] ->
        ( {
            selection_root = Option.value root ~default:default_root;
            selection_preview = preview;
            selection_yes = yes;
            selection_plan = plan;
          },
          List.rev remaining )
    | (("--to" | "--node" | "--checkpoint" | "--destination" | "--operation") as
       option)
      :: value :: rest ->
        loop root preview yes plan (value :: option :: remaining) rest
    | "--" :: rest ->
        ( {
            selection_root = Option.value root ~default:default_root;
            selection_preview = preview;
            selection_yes = yes;
            selection_plan = plan;
          },
          List.rev remaining @ ("--" :: rest) )
    | "--root" :: value :: rest when root = None ->
        loop (Some value) preview yes plan remaining rest
    | ("--preview" | "--dry-run") :: rest when not preview ->
        loop root true yes plan remaining rest
    | "--yes" :: rest when not yes -> loop root preview true plan remaining rest
    | "--plan" :: value :: rest when plan = None ->
        if
          String.length value <> 64
          || not
               (String.for_all
                  (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
                  value)
        then
          fail_with_status 2 "invalid-plan-id"
            "--plan needs a lowercase 64-digit plan ID from a preview";
        loop root preview yes (Some value) remaining rest
    | ("--root" | "--preview" | "--dry-run" | "--yes" | "--plan") :: _ ->
        fail_with_status 2 "invalid-invocation"
          "selection flags cannot be duplicated or omit their values"
    | value :: rest -> loop root preview yes plan (value :: remaining) rest
  in
  let flags, remaining = loop None false false None [] arguments in
  if flags.selection_preview && flags.selection_yes then
    fail_with_status 2 "invalid-invocation"
      "--preview and --yes are mutually exclusive";
  (flags, remaining)

let json_byte_path path =
  let utf8 = Result.is_ok (Yeokcham_encoding.text path) in
  `Assoc
    [
      ("path", if utf8 then `String path else `Null);
      ( "display",
        `String
          (if utf8 then Output.display_value path else String.escaped path) );
      ("bytes_hex", `String (hex_of_bytes path));
    ]

let journal_phase = function
  | Journal.Prepared -> "prepared"
  | Journal.Applying -> "applying"
  | Journal.Materialized -> "materialized"
  | Journal.Published -> "published"

let operation_json ~history journal =
  let history_id =
    match (History.workspace history, Journal.history_node journal) with
    | Some workspace, Some sequence ->
        Core.History_id.make ~workspace ~sequence
        |> Result.to_option
        |> Option.map json_history_identity
    | None, _ | _, None -> None
  in
  `Assoc
    [
      ("operation_id", `String (Journal.operation_id journal));
      ( "scope",
        `String
          (if Journal.destination journal <> None then "copy-out"
           else if Journal.requires_source_proof journal then "in-place"
           else "metadata-only") );
      ("phase", `String (journal_phase (Journal.phase journal)));
      ( "safety_snapshot_id",
        `String (Model.Snapshot_id.to_string (Journal.safety journal)) );
      ( "target_snapshot_id",
        `String (Model.Snapshot_id.to_string (Journal.target journal)) );
      ("target_history", Option.value history_id ~default:`Null);
      ( "target_branch_id",
        match Journal.plan journal with
        | Some (_, Some branch) -> `String (Core.Branch_id.to_hex branch)
        | None | Some (_, None) -> `Null );
      ("destination", json_optional json_byte_path (Journal.destination journal));
      ( "plan_id",
        json_optional
          (fun raw -> `String (hex_of_bytes raw))
          (Journal.selection_plan journal) );
      ( "retained_directory_relative",
        `String (".yeokcham/restore-staging/" ^ Journal.operation_id journal) );
      ("current_contents_verified", `Bool false);
    ]

let latest_recovery_journals ~root =
  let journals =
    match Journal.scan ~root with
    | Ok journals -> journals
    | Error error ->
        fail_with_status 6 "recovery-integrity-failure"
          (Journal.error_to_string error)
  in
  let table = Hashtbl.create 16 in
  List.iter
    (fun journal ->
      match Hashtbl.find_opt table (Journal.operation_id journal) with
      | Some previous
        when Journal.generation previous >= Journal.generation journal ->
          ()
      | None | Some _ ->
          Hashtbl.replace table (Journal.operation_id journal) journal)
    journals;
  Hashtbl.to_seq_values table
  |> List.of_seq
  |> List.sort (fun a b ->
      String.compare (Journal.operation_id a) (Journal.operation_id b))

let set_local_failure_context ~root =
  local_failure_context :=
    Some
      (fun () ->
        let history =
          Service.local_history ~root
          |> Result.to_option
          |> Option.map (fun h -> h.Service.undo_tree)
        in
        let pending = Journal.pending ~root in
        let operations =
          match (pending, history) with
          | Ok journals, Some history ->
              List.map (operation_json ~history) journals
          | Ok _, None | Error _, _ -> []
        in
        let actions =
          match pending with
          | Ok journals ->
              List.concat_map
                (fun j ->
                  [
                    action ~confirmation_required:true ~root
                      [
                        "restore";
                        "--resume";
                        "--operation";
                        Journal.operation_id j;
                        "--yes";
                      ]
                      "Resume this exact operation after validating retained \
                       and live data.";
                    action ~root
                      [
                        "restore";
                        "--resume";
                        "--operation";
                        Journal.operation_id j;
                        "--preview";
                      ]
                      "Inspect the recorded recovery target without changing \
                       files or history.";
                  ])
                journals
          | Error _ -> []
        in
        let saved =
          json_optional
            (fun history ->
              let node = History.current history in
              `Assoc
                [
                  ( "history",
                    json_optional json_history_identity
                      (History.identity history node |> Result.to_option) );
                  ( "snapshot_id",
                    `String (Model.Snapshot_id.to_string node.History.snapshot)
                  );
                ])
            history
        in
        let redo_choices =
          match history with
          | None -> []
          | Some history ->
              History.children history (History.current history).History.id
              |> List.map (fun node ->
                  `Assoc
                    [
                      ( "history",
                        json_optional json_history_identity
                          (History.identity history node |> Result.to_option) );
                      ( "snapshot_id",
                        `String
                          (Model.Snapshot_id.to_string node.History.snapshot) );
                    ])
        in
        let redo_actions =
          match (history, pending) with
          | Some history, Ok [] ->
              History.children history (History.current history).History.id
              |> List.map (fun node ->
                  action ~root
                    [
                      "redo";
                      "--node";
                      Int64.to_string node.History.id;
                      "--preview";
                    ]
                    "Inspect this exact redo continuation before selection.")
          | None, _ | _, (Ok _ | Error _) -> []
        in
        let operation =
          match pending with
          | Ok [ journal ] -> Some (Journal.operation_id journal)
          | Ok _ | Error _ -> None
        in
        ( `Assoc
            [
              ("saved", saved);
              ("redo_choices", `List redo_choices);
              ("pending_operations", `List operations);
              ( "recovery_state",
                `String
                  (match pending with
                  | Error _ -> "unreadable"
                  | Ok [] -> "none"
                  | Ok _ -> "pending") );
            ],
          actions @ redo_actions
          @ [
              action ~root [ "history" ]
                "Inspect saved alternatives and availability.";
              action ~root [ "status" ] "Inspect capture and recovery state.";
            ],
          operation ))

let selection_choice ?plan_id ~data ~next_actions ~message () =
  if requested_format () = Json_format then
    Cli_data.domain_failure ?plan_id ~command:(command_name ())
      ~outcome:`Choice_required
      ~error:Cli_data.{ code = "confirmation-required"; message }
      ~data ~warnings:[] ~next_actions ()
    |> Cli_data.encode |> print_json;
  prerr_endline message;
  exit 3

let confirm_local_selection ?plan_id ~data ~next_actions ~render () =
  if requested_format () = Json_format || not (Unix.isatty Unix.stdin) then
    selection_choice ?plan_id ~data ~next_actions
      ~message:
        "Preview the affected files, then rerun with --yes to confirm the \
         freshly validated selection."
      ();
  render ();
  prerr_string "Apply this selection and preserve current private work? [y/N] ";
  flush stderr;
  let answer =
    try read_line () |> String.trim |> String.lowercase_ascii
    with End_of_file -> ""
  in
  answer = "y" || answer = "yes"

let switch_json ~root result =
  let history =
    Service.local_history ~root |> require_local |> fun h -> h.Service.undo_tree
  in
  let identity =
    if result.Service.switch_target_provisional then
      Option.bind (History.workspace history) (fun workspace ->
          Core.History_id.make ~workspace
            ~sequence:result.Service.switch_target.History.id
          |> Result.to_option)
    else
      History.identity history result.Service.switch_target |> Result.to_option
  in
  `Assoc
    [
      ("source_state_head", `String result.Service.switch_state_head);
      ( "observed_snapshot_id",
        json_optional
          (fun id -> `String (Model.Snapshot_id.to_string id))
          result.Service.switch_observed );
      ( "from_branch_id",
        `String (Core.Branch_id.to_hex result.Service.switch_from) );
      ( "target_branch_id",
        `String (Core.Branch_id.to_hex result.Service.switch_to) );
      ("target_history", json_optional json_history_identity identity);
      ( "target_history_provisional",
        `Bool result.Service.switch_target_provisional );
      ( "creates_private_position",
        `Bool result.Service.switch_registers_position );
      ( "target_working_basis",
        `String (Core.Record_id.to_hex result.Service.switch_basis) );
      ( "known_accepted_heads",
        `List
          (List.map
             (fun id -> `String (Core.Record_id.to_hex id))
             result.Service.switch_known_heads) );
      ( "target_snapshot_id",
        `String
          (Model.Snapshot_id.to_string
             result.Service.switch_target.History.snapshot) );
      ("captures_unsaved", `Bool result.Service.switch_captures_unsaved);
      ("applied", `Bool result.Service.switch_applied);
      ("changes", `List (List.map json_difference result.Service.switch_changes));
      ( "recovery",
        json_optional
          (fun r ->
            `Assoc
              [
                ("operation_id", `String r.Service.restore_operation);
                ( "safety_snapshot_id",
                  `String
                    (Model.Snapshot_id.to_string r.Service.safety_checkpoint) );
                ( "target_snapshot_id",
                  `String
                    (Model.Snapshot_id.to_string r.Service.restored_checkpoint)
                );
                ("resumed", `Bool r.Service.resumed);
                ( "retained_directory_relative",
                  `String
                    (".yeokcham/restore-staging/" ^ r.Service.restore_operation)
                );
              ])
          result.Service.switch_restore );
    ]

let render_switch_text result =
  Printf.printf "%s branch:%s at node %Ld (snapshot %s)\n"
    (if result.Service.switch_applied then "selected" else "selection")
    (Core.Branch_id.to_hex result.Service.switch_to)
    result.Service.switch_target.History.id
    (Model.Snapshot_id.to_string result.Service.switch_target.History.snapshot);
  if result.Service.switch_captures_unsaved then
    print_endline "Preserve unsaved disk edits on the source branch.";
  if result.Service.switch_registers_position then
    print_endline
      "Select this branch's verified accepted contents; keep source work on \
       its private history.";
  if result.Service.switch_target_provisional then
    print_endline
      "The proposed history position is allocated only when this selection is \
       recorded.";
  if result.Service.switch_known_heads <> [ result.Service.switch_basis ] then
    print_endline
      "This selects your saved private position. Shared updates are available; \
       preview integration to inspect them.";
  List.iter
    (fun d ->
      Printf.printf "%s: %s -> %s\n"
        (Output.display_value (Model.Path.to_string d.Service.path))
        (render_snapshot_entry d.Service.before)
        (render_snapshot_entry d.Service.after))
    result.Service.switch_changes;
  Option.iter
    (fun r ->
      Printf.printf "%s %s%s\n"
        (if
           Model.Snapshot_id.equal r.Service.safety_checkpoint
             r.Service.restored_checkpoint
         then "selection-operation"
         else "restore-proof")
        r.Service.restore_operation
        (if r.Service.resumed then " (resumed original switch)" else ""))
    result.Service.switch_restore

let run_switch arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  let root = flags.selection_root in
  set_local_failure_context ~root;
  let name =
    match remaining with [ name ] | [ "--"; name ] -> name | _ -> usage ()
  in
  (match Core.validate_branch_name name with
  | Ok () -> ()
  | Error error ->
      fail_with_status 2 "invalid-branch-name" (Core.error_to_string error));
  let inspected =
    if flags.selection_yes then None
    else
      Some
        (Service.branch_switch_plan ~root ~name ~dry_run:true
           ~expected_plan:flags.selection_plan
        |> require_local)
  in
  let unchanged =
    Option.fold ~none:false
      ~some:(fun result ->
        Core.Branch_id.equal result.Service.switch_from result.Service.switch_to)
      inspected
  in
  let base =
    if String.starts_with ~prefix:"-" name then [ "switch"; "--"; name ]
    else [ "switch"; name ]
  in
  let next_actions result =
    [
      action ~confirmation_required:true ~root
        (append_before_literal base
           ([ "--yes" ]
           @ Option.fold ~none:[]
               ~some:(fun id -> [ "--plan"; id ])
               result.Service.switch_plan))
        "Apply this exact freshly validated branch selection.";
      action ~root
        (append_before_literal base [ "--preview" ])
        "Inspect selection effects without changing files or history.";
    ]
  in
  let cancelled =
    (not flags.selection_yes)
    && (not flags.selection_preview)
    && (not unchanged)
    && not
         (let result = Option.get inspected in
          confirm_local_selection ?plan_id:result.Service.switch_plan
            ~data:(switch_json ~root result) ~next_actions:(next_actions result)
            ~render:(fun () -> render_switch_text result)
            ())
  in
  let result =
    if flags.selection_yes then
      Service.branch_switch_plan ~root ~name ~dry_run:false
        ~expected_plan:flags.selection_plan
      |> require_local
    else if flags.selection_preview || unchanged || cancelled then
      Option.get inspected
    else
      let preview = Option.get inspected in
      Service.branch_switch_confirmed ~root ~name ~preview |> require_local
  in
  let unchanged =
    (not result.Service.switch_applied)
    && Core.Branch_id.equal result.Service.switch_from result.Service.switch_to
  in
  if requested_format () = Json_format then
    domain_json ?plan_id:result.Service.switch_plan
      ?operation_id:
        (Option.map
           (fun recovery -> recovery.Service.restore_operation)
           result.Service.switch_restore)
      ~outcome:(if cancelled || unchanged then `Unchanged else `Completed)
      ~code:
        (if cancelled then "selection-cancelled"
         else if unchanged then "branch-already-selected"
         else if flags.selection_preview then "switch-preview"
         else "branch-selected")
      ~message:
        (if cancelled then
           "Selection cancelled; files and history are unchanged."
         else if flags.selection_preview then
           "Branch selection preview; files and history are unchanged."
         else if unchanged then "The named branch is already selected."
         else "Branch and exact private history position selected.")
      ~data:(switch_json ~root result)
      ~next_actions:
        (if flags.selection_preview then next_actions result
         else
           [ action ~root [ "status" ] "Inspect local work after selection." ]
           @
           if
             result.Service.switch_known_heads
             <> [ result.Service.switch_basis ]
           then
             [
               action ~root
                 [ "integrate"; "--preview" ]
                 "Inspect shared updates against this saved private position.";
             ]
           else [])
      ()
  else if cancelled then
    print_endline "Selection cancelled; files and history are unchanged."
  else render_switch_text result;
  result.Service.switch_applied

let json_hunk hunk =
  `Assoc
    [
      ("old_start", `Int hunk.Text_diff.old_start);
      ("old_count", `Int hunk.Text_diff.old_count);
      ("new_start", `Int hunk.Text_diff.new_start);
      ("new_count", `Int hunk.Text_diff.new_count);
      ( "lines",
        `List
          (List.map
             (fun line ->
               `Assoc
                 [
                   ( "kind",
                     `String
                       (match line.Text_diff.kind with
                       | Text_diff.Context -> "context"
                       | Text_diff.Removed -> "removed"
                       | Text_diff.Added -> "added") );
                   ("text", `String line.Text_diff.text);
                   ("newline", `Bool line.Text_diff.newline);
                 ])
             hunk.Text_diff.lines) );
    ]

let json_display_difference difference =
  let fields =
    path_fields difference.Service.entry_difference.Service.path
    @ [
        ("before", json_entry difference.Service.entry_difference.Service.before);
        ("after", json_entry difference.Service.entry_difference.Service.after);
        ( "text",
          match difference.Service.text_difference with
          | None -> `Assoc [ ("state", `String "metadata-only") ]
          | Some (Text_diff.Opaque reason) ->
              `Assoc [ ("state", `String "opaque"); ("reason", `String reason) ]
          | Some (Text_diff.Text hunks) ->
              `Assoc
                [
                  ("state", `String "text");
                  ("hunks", `List (List.map json_hunk hunks));
                ] );
      ]
  in
  `Assoc fields

let display_line value =
  if Result.is_error (Yeokcham_encoding.text value) then String.escaped value
  else
    let buffer = Buffer.create (String.length value) in
    String.iter
      (function
        | '\r' -> Buffer.add_string buffer "\\r"
        | ('\000' .. '\008' | '\011' .. '\031' | '\127') as byte ->
            Buffer.add_string buffer
              (Standard_printf.sprintf "\\x%02x" (Char.code byte))
        | byte -> Buffer.add_char buffer byte)
      value;
    Buffer.contents buffer

let compact_entry = function
  | None -> "missing"
  | Some entry -> match entry.Service.kind,entry.Service.mode with
      | Service.Directory,_ -> "directory"
      | Service.File,Some Yeokcham_snapshot.Executable -> "executable file"
      | Service.File,Some Yeokcham_snapshot.Symlink -> "symlink"
      | Service.File,(None | Some Yeokcham_snapshot.Regular) -> "file"

let compact_change difference =
  match difference.Service.before,difference.Service.after with
  | None,Some _ -> ("A",Output.Good,"added")
  | Some _,None -> ("D",Output.Bad,"deleted")
  | Some before,Some after when before.Service.kind <> after.Service.kind -> ("T",Output.Caution,"type changed")
  | Some before,Some after when before.Service.mode <> after.Service.mode -> ("M",Output.Caution,"mode changed")
  | Some _,Some _ | None,None -> ("M",Output.Caution,"modified")

let render_compact_path difference =
  let code,tone,_ = compact_change difference in
  let mode = match difference.Service.before,difference.Service.after with
    | Some before,Some after when before.Service.mode <> after.Service.mode || before.Service.kind <> after.Service.kind ->
        " (" ^ compact_entry (Some before) ^ " -> " ^ compact_entry (Some after) ^ ")"
    | None,Some after when after.Service.kind = Service.Directory || after.Service.mode = Some Yeokcham_snapshot.Symlink ->
        " (" ^ compact_entry (Some after) ^ ")"
    | None,Some _ | Some _,None | Some _,Some _ | None,None -> ""
  in
  Output.line ("  " ^ Output.paint tone code ^ " " ^ Output.display_value (Model.Path.to_string difference.Service.path) ^ mode)

let render_display_difference difference =
  let entry = difference.Service.entry_difference in
  if requested_details () then (
    Printf.printf "diff %s\n" (Output.display_value (Model.Path.to_string entry.Service.path));
    Printf.printf "  before %s\n  after  %s\n" (render_snapshot_entry entry.Service.before) (render_snapshot_entry entry.Service.after))
  else (
    let _,_,description = compact_change entry in
    Output.line ~tone:Output.Accent (Output.display_value (Model.Path.to_string entry.Service.path));
    if entry.Service.before = None || entry.Service.after = None then
      Output.line ~tone:Output.Muted ("  " ^ description ^ " / " ^ compact_entry (if entry.Service.after = None then entry.Service.before else entry.Service.after));
    if Option.map (fun e -> e.Service.mode,e.Service.kind) entry.Service.before <> Option.map (fun e -> e.Service.mode,e.Service.kind) entry.Service.after
       && entry.Service.before <> None && entry.Service.after <> None then
      Output.line ~tone:Output.Muted ("  " ^ compact_entry entry.Service.before ^ " -> " ^ compact_entry entry.Service.after));
  match difference.Service.text_difference with
  | None -> ()
  | Some (Text_diff.Opaque reason) -> Output.line ~tone:Output.Muted ("  " ^ display_line reason)
  | Some (Text_diff.Text hunks) ->
      List.iter
        (fun hunk ->
          Output.line ~tone:Output.Muted (Standard_printf.sprintf "@@ -%d,%d +%d,%d @@" hunk.Text_diff.old_start
            hunk.Text_diff.old_count hunk.Text_diff.new_start
            hunk.Text_diff.new_count);
          List.iter
            (fun line ->
              Output.line ~tone:(match line.Text_diff.kind with Text_diff.Added -> Output.Good | Text_diff.Removed -> Output.Bad | Text_diff.Context -> Output.Plain)
                (Standard_printf.sprintf "%s%s"
                (match line.Text_diff.kind with
                | Text_diff.Context -> " "
                | Text_diff.Removed -> "-"
                | Text_diff.Added -> "+")
                (display_line line.Text_diff.text));
              if not line.Text_diff.newline then
                Output.line ~tone:Output.Muted "\\ No newline at end of file")
            hunk.Text_diff.lines)
        hunks

let metadata_failure metadata =
  match Service.metadata_validation_failure metadata with
  | `Unavailable message ->
      (5, `Unavailable, "saved-contents-unavailable", message)
  | `Integrity message ->
      (6, `Integrity_failure, "saved-state-unverified", message)

let render_metadata_status ~root metadata =
  let status, outcome, code, message = metadata_failure metadata in
  let history = metadata.Store.metadata_history in
  let node = History.current history in
  let identity = History.identity history node |> Result.to_option in
  let local = metadata.Store.metadata_local in
  let selected = Option.map Local.Metadata.selected local in
  let branch =
    Option.bind local (fun local ->
        List.find_opt
          (fun row ->
            Core.Branch_id.equal row.Core.branch_id
              (Local.Metadata.selected local).Local.branch)
          (Local.Metadata.branches local))
  in
  let branch_json row =
    `Assoc
      [
        ("id", `String (Core.Branch_id.to_hex row.Core.branch_id));
        ( "names",
          `List (List.map (fun name -> `String name) row.Core.display_names) );
        ("event_heads", json_ids row.Core.event_heads);
        ("accepted_heads", json_ids row.Core.accepted_heads);
      ]
  in
  let contents =
    match
      Service.inspect_saved_snapshot ~root ~snapshot:node.History.snapshot
    with
    | Ok () -> `Assoc [ ("state", `String "available") ]
    | Error error ->
        `Assoc
          [
            ("state", `String "unavailable");
            ( "message",
              `String (public_error_message (Service.error_to_string error)) );
          ]
  in
  let data =
    `Assoc
      [
        ( "state_head",
          `String
            (Yeokcham_store.Stored_object_id.to_hex
               metadata.Store.metadata_object_id) );
        ( "saved",
          `Assoc
            [
              ( "id",
                `String
                  (Option.fold
                     ~none:("node:" ^ Int64.to_string node.History.id)
                     ~some:(fun id ->
                       Core.Workspace_id.to_hex (Core.History_id.workspace id)
                       ^ ":"
                       ^ Int64.to_string (Core.History_id.sequence id))
                     identity) );
              ("history", json_optional json_history_identity identity);
              ( "snapshot_id",
                `String (Model.Snapshot_id.to_string node.History.snapshot) );
              ("contents", contents);
            ] );
        ("branch", json_optional branch_json branch);
        ( "known_branches",
          `List
            (Option.fold ~none:[]
               ~some:(fun local ->
                 List.map branch_json (Local.Metadata.branches local))
               local) );
        ( "working_basis",
          json_optional
            (fun p -> `String (Core.Record_id.to_hex p.Local.basis))
            selected );
        ( "state_validation",
          `Assoc
            [
              ("state", `String "unverified");
              ("message", `String (public_error_message message));
            ] );
        ("record_signatures", if local = None then `Null else `String "verified");
        ( "shared_records",
          `List
            (Option.fold ~none:[]
               ~some:(fun local ->
                 Local.Metadata.records local
                 |> List.map (fun (id, body) ->
                     let fields =
                       match body.Core.payload with
                       | Core.Shared_revision revision ->
                           [
                             ( "change_id",
                               `String
                                 (Core.Change_id.to_hex revision.Core.change) );
                             ( "previous_revisions",
                               json_ids revision.Core.previous_revisions );
                             ( "dependencies",
                               json_ids revision.Core.dependencies );
                             ( "base_snapshot",
                               `String
                                 (Core.Object_id.to_hex
                                    revision.Core.base_snapshot) );
                             ( "result_snapshot",
                               `String
                                 (Core.Object_id.to_hex
                                    revision.Core.result_snapshot) );
                           ]
                       | Core.Accepted_version version ->
                           [
                             ( "branch_id",
                               `String
                                 (Core.Branch_id.to_hex version.Core.branch) );
                             ( "accepted_parents",
                               json_ids version.Core.accepted_parents );
                             ( "chosen_revisions",
                               json_ids version.Core.chosen_revisions );
                             ( "result_snapshot",
                               `String
                                 (Core.Object_id.to_hex
                                    version.Core.result_snapshot) );
                           ]
                       | Core.Resolution_revision resolution ->
                           [
                             ( "branch_id",
                               `String
                                 (Core.Branch_id.to_hex resolution.Core.branch)
                             );
                             ( "accepted_heads",
                               json_ids resolution.Core.accepted_heads );
                             ( "chosen_revisions",
                               json_ids resolution.Core.chosen_revisions );
                             ( "superseded_variants",
                               json_ids resolution.Core.superseded_variants );
                             ( "decision_scope_root",
                               `String
                                 (Core.Object_id.to_hex
                                    resolution.Core.decision_scope_root) );
                             ( "comparison_snapshot",
                               `String
                                 (Core.Object_id.to_hex
                                    resolution.Core.comparison_snapshot) );
                             ( "replacement_snapshot",
                               `String
                                 (Core.Object_id.to_hex
                                    resolution.Core.replacement_snapshot) );
                           ]
                       | Core.Branch_event event ->
                           [
                             ( "branch_id",
                               `String (Core.Branch_id.to_hex event.Core.branch)
                             );
                           ]
                     in
                     `Assoc
                       ([
                          ("id", `String (Core.Record_id.to_hex id));
                          ( "kind",
                            `String
                              (Core.kind_name (Core.kind body.Core.payload)) );
                        ]
                       @ fields)))
               local) );
        ( "capture",
          `Assoc
            [
              ("state", `String "not_attempted");
              ( "message",
                `String
                  "Saved state requires validation before working-tree \
                   observation." );
            ] );
        ("uncaptured", `Null);
        ("changes", `Null);
        ("local_publications", `Null);
        ("integration_operations", `Null);
        ("resolution_proposals", `Null);
        ("recovery", `Null);
        ("pending_operations", `Null);
        ( "recovery_inspection_error",
          `String
            "Saved state requires verification before recovery inspection." );
        ( "transfer_inspection_error",
          `String
            "Saved state requires verification before transfer inspection." );
        ("watcher", `Assoc [ ("state", `String "not-inspected") ]);
        ("managed_service", `String "not-implemented");
        ("private_backup", `String "not-configured");
        ("outgoing", `Assoc [ ("state", `String "unverified") ]);
      ]
  in
  let next_actions =
    [
      action ~root [ "history" ]
        "Inspect saved identities and unavailable contents without changing \
         files.";
      action ~root [ "verify" ] "Inspect the repository validation failure.";
    ]
  in
  (match requested_format () with
  | Json_format ->
      Cli_data.domain_failure ~command:(command_name ()) ~outcome
        ~error:Cli_data.{ code; message = public_error_message message }
        ~data ~warnings:[] ~next_actions ()
      |> Cli_data.encode |> print_json
  | Text_format ->
      Printf.printf "recorded private position %Ld snapshot %s\n"
        node.History.id
        (Model.Snapshot_id.to_string node.History.snapshot);
      Option.iter
        (fun row ->
          Printf.printf "branch %s (%s)\n"
            (String.concat ", "
               (List.map Output.display_value row.Core.display_names))
            (Core.Branch_id.to_hex row.Core.branch_id))
        branch;
      Printf.printf "state verification unavailable: %s\n"
        (display_line (public_error_message message));
      print_endline
        "Working files were not scanned. Inspect history and run verify for \
         details.");
  exit status

let compact_state (state : Service.state_view) =
  match state.Service.history_identity with
  | Some identity -> "#" ^ Int64.to_string (Core.History_id.sequence identity)
  | None when state.Service.state_name = "working" -> "working files"
  | None -> "snapshot " ^ String.sub (Model.Snapshot_id.to_string state.Service.state_snapshot) 0 8

let render_compact_status ~next_actions status =
  let branch = Option.bind status.Service.status_branch (fun listing ->
      List.find_opt (fun row -> Core.Branch_id.equal row.Core.branch_id listing.Service.selected_branch)
        listing.Service.shared_branches) in
  let branch_name = Option.fold ~none:"Local work" ~some:(fun row ->
      match row.Core.display_names with
      | [name] -> Output.display_value name
      | [] -> "Unnamed branch"
      | names -> String.concat ", " (List.map Output.display_value names)) branch in
  Output.line ~tone:Output.Accent (branch_name ^ " / saved " ^ compact_state status.Service.status_cursor);
  (match status.Service.capture_observation with
   | Error message ->
       Output.line ~tone:Output.Caution "! Changes unknown - capture incomplete";
       Output.line ("  " ^ display_line (public_error_message message))
   | Ok comparison ->
       let count = List.length comparison.Service.differences in
       if count = 0 then Output.line ~tone:Output.Good (Output.symbol ~ascii:"=" ~unicode:"✓" ^ " Working files match the saved version")
       else (
         Output.line (Standard_printf.sprintf "%d %s to save" count (if count = 1 then "path" else "paths"));
         List.iter render_compact_path comparison.Service.differences));
  let diverged = Option.fold ~none:false ~some:(fun row -> List.length row.Core.event_heads <> 1 || List.length row.Core.accepted_heads <> 1 || List.length row.Core.display_names <> 1) branch in
  if diverged then Output.line ~tone:Output.Caution "! Branch needs reconciliation; run yeokcham branch list";
  let incoming = Option.fold ~none:false ~some:(fun (row : Core.branch_state) ->
      Option.fold ~none:false ~some:(fun basis -> not (List.exists (Core.Record_id.equal basis) row.Core.accepted_heads)) status.Service.status_basis) branch in
  if incoming && not diverged then Output.line "Incoming accepted work / yeokcham integrate --preview";
  let pending_publications = List.filter (fun publication -> fst (publication_transfer_state status publication.Local.revision) = "pending") status.Service.status_publications |> List.length in
  if pending_publications > 0 then Output.line (Standard_printf.sprintf "Sharing  %d local publication%s awaiting exchange" pending_publications (if pending_publications = 1 then "" else "s"));
  let pending_acceptances = List.filter (fun operation -> Integration_op.committed operation && not operation.Integration_op.acknowledged) status.Service.status_integrations |> List.length in
  if pending_acceptances > 0 then Output.line (Standard_printf.sprintf "Accepted  %d local integration%s awaiting exchange" pending_acceptances (if pending_acceptances = 1 then "" else "s"));
  List.iter (fun operation ->
      if Integration_op.pending operation then (
        Output.line ~tone:Output.Caution ("! Integration " ^ phase_name operation.Integration_op.phase);
        Output.line ("  yeokcham operation show " ^ Core.Operation_id.to_hex operation.Integration_op.token))) status.Service.status_integrations;
  if status.Service.pending_local_recovery <> None || status.Service.pending_recovery_journals <> [] then (
    Output.line ~tone:Output.Caution "! Interrupted local selection needs recovery";
    List.iter (fun action -> Output.line ("  " ^ String.concat " " (List.map Filename.quote action.Cli_data.arguments))) next_actions);
  Option.iter (fun message -> Output.line ~tone:Output.Caution ("! Recovery state unknown: " ^ display_line (public_error_message message))) status.Service.recovery_inspection_error;
  (match status.Service.status_transfers with Error message -> Output.line ~tone:Output.Caution ("! Transfer state unknown: " ^ display_line (public_error_message message)) | Ok _ -> ());
  if status.Service.status_resolutions <> [] then Output.line "Resolution proposals available / yeokcham conflicts";
  Output.line "";
  (match status.Service.capture_observation with
   | Ok comparison when comparison.Service.differences <> [] -> Output.line "Next  yeokcham diff / yeokcham save"
   | Error _ | Ok _ -> ());
  Output.line ~tone:Output.Muted "Capture: manual / Backup: not configured"

let run_status arguments =
  let root = parse_root arguments in
  let status =
    match Service.inspect_local_status ~root with
    | Ok status -> status
    | Error original -> (
        match Service.inspect_saved_state ~root with
        | Error _ -> fail_local original
        | Ok (Store.Metadata_only metadata) ->
            render_metadata_status ~root metadata
        | Ok (Store.Verified _) ->
            Service.inspect_local_status ~root |> require_local)
  in
  let capture, uncaptured, changed_paths =
    match status.Service.capture_observation with
    | Ok comparison ->
        ( `Assoc
            [
              ("state", `String "complete");
              ( "observed_snapshot",
                `String
                  (Model.Snapshot_id.to_string
                     comparison.Service.observed_snapshot) );
            ],
          `Bool status.Service.saved_metadata.Service.uncaptured,
          `List (List.map json_difference comparison.Service.differences) )
    | Error message ->
        ( `Assoc
            [
              ("state", `String "incomplete");
              ("message", `String (public_error_message message));
            ],
          `Null,
          `Null )
  in
  let branch =
    Option.map
      (fun listing ->
        let row =
          List.find
            (fun row ->
              Core.Branch_id.equal row.Core.branch_id
                listing.Service.selected_branch)
            listing.Service.shared_branches
        in
        `Assoc
          [
            ("id", `String (Core.Branch_id.to_hex row.Core.branch_id));
            ( "names",
              `List (List.map (fun name -> `String name) row.Core.display_names)
            );
            ("event_heads", json_ids row.Core.event_heads);
            ("accepted_heads", json_ids row.Core.accepted_heads);
          ])
      status.Service.status_branch
  in
  let recovery =
    Option.map
      (fun pending ->
        `Assoc
          [
            ("operation_id", `String pending.Service.recovery_operation);
            ( "target_snapshot",
              `String
                (Model.Snapshot_id.to_string pending.Service.recovery_target) );
          ])
      status.Service.pending_local_recovery
  in
  let recovery_history =
    Service.local_history ~root |> require_local |> fun result ->
    result.Service.undo_tree
  in
  let data =
    `Assoc
      [
        ("saved", json_state status.Service.status_cursor);
        ("state_head", `String status.Service.status_head);
        ("branch", Option.value branch ~default:`Null);
        ( "working_basis",
          json_optional
            (fun id -> `String (Core.Record_id.to_hex id))
            status.Service.status_basis );
        ( "shared_revisions",
          `List
            (List.map
               (fun (id, revision) ->
                 `Assoc
                   [
                     ("revision_id", `String (Core.Record_id.to_hex id));
                     ( "change_id",
                       `String (Core.Change_id.to_hex revision.Core.change) );
                     ( "previous_revisions",
                       json_ids revision.Core.previous_revisions );
                     ( "base_snapshot",
                       `String
                         (Core.Object_id.to_hex revision.Core.base_snapshot) );
                     ( "result_snapshot",
                       `String
                         (Core.Object_id.to_hex revision.Core.result_snapshot)
                     );
                   ])
               status.Service.status_shared_revisions) );
        ( "local_publications",
          `List
            (List.map
               (fun p ->
                 let transfer, remotes =
                   publication_transfer_state status p.Local.revision
                 in
                 `Assoc
                   [
                     ( "operation_id",
                       `String (Core.Operation_id.to_hex p.Local.operation) );
                     ( "revision_id",
                       `String (Core.Record_id.to_hex p.Local.revision) );
                     ("title", `String p.Local.title);
                     ("transfer_state", `String transfer);
                     ( "acknowledged_remotes",
                       `List (List.map (fun name -> `String name) remotes) );
                   ])
               status.Service.status_publications) );
        ( "transfer_inspection_error",
          match status.Service.status_transfers with
          | Ok _ -> `Null
          | Error message -> `String (public_error_message message) );
        ( "integration_operations",
          `List
            (List.map json_integration_operation
               status.Service.status_integrations) );
        ( "resolution_proposals",
          `List
            (List.map
               (fun (id, (resolution : Core.resolution_revision), accepted_by)
                  ->
                 `Assoc
                   [
                     ("resolution_id", `String (Core.Record_id.to_hex id));
                     ( "branch_id",
                       `String (Core.Branch_id.to_hex resolution.Core.branch) );
                     ("accepted_heads", json_ids resolution.Core.accepted_heads);
                     ( "chosen_revisions",
                       json_ids resolution.Core.chosen_revisions );
                     ( "decision_scope_root",
                       `String
                         (Core.Object_id.to_hex
                            resolution.Core.decision_scope_root) );
                     ( "comparison_snapshot",
                       `String
                         (Core.Object_id.to_hex
                            resolution.Core.comparison_snapshot) );
                     ( "replacement_snapshot",
                       `String
                         (Core.Object_id.to_hex
                            resolution.Core.replacement_snapshot) );
                     ("accepted_by", json_ids accepted_by);
                     ( "state",
                       `String
                         (if accepted_by = [] then "recorded_proposal"
                          else "referenced_by_accepted_versions") );
                   ])
               status.Service.status_resolutions) );
        ("capture", capture);
        ("uncaptured", uncaptured);
        ("changes", changed_paths);
        ("recovery", Option.value recovery ~default:`Null);
        ( "pending_operations",
          `List
            (List.map
               (operation_json ~history:recovery_history)
               status.Service.pending_recovery_journals) );
        ( "recovery_inspection_error",
          json_optional
            (fun message -> `String (public_error_message message))
            status.Service.recovery_inspection_error );
        ( "watcher",
          `Assoc
            [
              ("state", `String "not-inspected");
              ( "message",
                `String
                  "Foreground watch and the disposable runtime are inspected \
                   separately." );
            ] );
        ("managed_service", `String "not-implemented");
        ("private_backup", `String "not-configured");
      ]
  in
  let next_actions =
    match
      (status.Service.pending_local_recovery, status.Service.capture_observation)
    with
    | Some _, _ ->
        List.concat_map
          (fun journal ->
            [
              action ~root
                [
                  "restore";
                  "--resume";
                  "--operation";
                  Journal.operation_id journal;
                  "--preview";
                ]
                "Inspect this recorded recovery operation.";
              action ~confirmation_required:true ~root
                [
                  "restore";
                  "--resume";
                  "--operation";
                  Journal.operation_id journal;
                  "--yes";
                ]
                "Resume this exact operation after validating retained and \
                 live data.";
            ])
          status.Service.pending_recovery_journals
    | None, Ok comparison when comparison.Service.differences <> [] ->
        [
          action ~root [ "diff" ] "Inspect text and exact file changes.";
          action ~root [ "save" ] "Save a complete private local capture.";
        ]
    | None, (Ok _ | Error _) ->
        [ action ~root [ "history" ] "Inspect saved work and alternatives." ]
  in
  let next_actions =
    if
      status.Service.status_resolutions = []
      || status.Service.pending_local_recovery <> None
      || List.exists Integration_op.pending status.Service.status_integrations
    then next_actions
    else
      next_actions
      @ [
          action ~root [ "conflicts" ]
            "Inspect exact current resolution plans and remaining \
             shared/private conflicts.";
        ]
  in
  match requested_format () with
  | Json_format ->
      domain_json
        ~outcome:
          (if Result.is_ok status.Service.capture_observation then `Completed
           else `Incomplete)
        ~code:
          (if Result.is_ok status.Service.capture_observation then
             "status-inspected"
           else "capture-incomplete")
        ~message:
          (if Result.is_ok status.Service.capture_observation then
             "Local workspace inspected."
           else "Capture is incomplete; saved metadata remains available.")
        ~data ~next_actions ()
  | Text_format when not (requested_details ()) -> render_compact_status ~next_actions status
  | Text_format ->
      render_status
        ~uncaptured_known:(Result.is_ok status.Service.capture_observation)
        status.Service.saved_metadata;
      Option.iter
        (fun basis ->
          Printf.printf "working-basis %s\n" (Core.Record_id.to_hex basis))
        status.Service.status_basis;
      List.iter
        (fun (id, revision) ->
          Printf.printf "shared-revision %s change:%s\n"
            (Core.Record_id.to_hex id)
            (Core.Change_id.to_hex revision.Core.change))
        status.Service.status_shared_revisions;
      List.iter
        (fun (id, _, accepted_by) ->
          Printf.printf "resolution %s accepted-by:%s\n"
            (Core.Record_id.to_hex id)
            (if accepted_by = [] then "none (recorded proposal)"
             else String.concat "," (List.map Core.Record_id.to_hex accepted_by)))
        status.Service.status_resolutions;
      List.iter
        (fun p ->
          let transfer, remotes =
            publication_transfer_state status p.Local.revision
          in
          Printf.printf
            "publication %s revision:%s transfer:%s remotes:%s title:%s\n"
            (Core.Operation_id.to_hex p.Local.operation)
            (Core.Record_id.to_hex p.Local.revision)
            transfer
            (String.concat "," remotes)
            (Output.display_value p.Local.title))
        status.Service.status_publications;
      List.iter
        (fun operation ->
          Printf.printf "integration %s phase:%s acceptance:%s transfer:%s\n"
            (Core.Operation_id.to_hex operation.Integration_op.token)
            (phase_name operation.Integration_op.phase)
            (if Integration_op.committed operation then "committed"
             else "not_committed")
            (integration_transfer_state operation))
        status.Service.status_integrations;
      Printf.printf "cursor %s\n"
        status.Service.status_cursor.Service.state_name;
      (match status.Service.status_branch with
      | None ->
          print_endline "branch metadata unavailable for this V1 repository"
      | Some listing ->
          let row =
            List.find
              (fun row ->
                Core.Branch_id.equal row.Core.branch_id
                  listing.Service.selected_branch)
              listing.Service.shared_branches
          in
          Printf.printf "branch %s %s\n"
            (String.concat ", "
               (List.map Output.display_value row.Core.display_names))
            (Core.Branch_id.to_hex row.Core.branch_id);
          Printf.printf "accepted-heads %s\n"
            (String.concat ","
               (List.map Core.Record_id.to_hex row.Core.accepted_heads));
          if
            List.length row.Core.event_heads <> 1
            || List.length row.Core.accepted_heads <> 1
            || List.length row.Core.display_names <> 1
          then
            print_endline "branch reconciliation is required before selection");
      (match status.Service.capture_observation with
      | Error message ->
          Printf.printf "capture incomplete: %s\n" (display_line message)
      | Ok comparison ->
          List.iter
            (fun difference ->
              Printf.printf "changed %s before %s after %s\n"
                (Output.display_value
                   (Model.Path.to_string difference.Service.path))
                (render_snapshot_entry difference.Service.before)
                (render_snapshot_entry difference.Service.after))
            comparison.Service.differences);
      List.iter
        (fun journal ->
          Printf.printf
            "recovery-operation %s %s; inspect restore --resume --operation %s \
             --preview\n"
            (Journal.operation_id journal)
            (journal_phase (Journal.phase journal))
            (Journal.operation_id journal))
        status.Service.pending_recovery_journals;
      print_endline
        "watcher state not inspected; use watch or daemon status where \
         supported";
      print_endline
        "managed service not implemented; private backup not configured"

let[@warning "-4"] parse_state value =
  let invalid () =
    fail_with_status 2 "invalid-state"
      "state must be current, working, a local sequence, workspace:sequence, \
       or a retained snapshot ID"
  in
  match value with
  | "current" | "saved" -> Service.Current_saved
  | "working" -> Service.Working_tree
  | _ -> (
      match String.split_on_char ':' value with
      | [ workspace; sequence ] -> (
          let workspace = Core.Workspace_id.of_hex workspace in
          let sequence = Int64.of_string_opt sequence in
          match (workspace, sequence) with
          | Ok workspace, Some sequence when Int64.compare sequence 0L >= 0 ->
              Service.Exact_history
                (Core.History_id.make ~workspace ~sequence
                |> require_ok Core.error_to_string)
          | _ -> invalid ())
      | [ _ ] when String.length value = 64 -> (
          match Yeokcham_store.Stored_object_id.of_hex value with
          | Ok id ->
              Service.Snapshot_state
                (Model.Snapshot_id.of_string
                   (Yeokcham_store.Stored_object_id.to_hex id)
                |> require_ok Model.error_to_string)
          | Error _ -> invalid ())
      | [ _ ] -> (
          match Int64.of_string_opt value with
          | Some sequence when Int64.compare sequence 0L >= 0 ->
              Service.History_node sequence
          | _ -> invalid ())
      | _ -> invalid ())

let scoped_history_node ~root state =
  let history =
    Service.local_history ~root |> require_local |> fun result ->
    result.Service.undo_tree
  in
  let sequence =
    match state with
    | Service.Current_saved -> (History.current history).History.id
    | Service.History_node sequence -> sequence
    | Service.Exact_history identity ->
        (match History.workspace history with
        | Some workspace
          when Core.Workspace_id.equal workspace
                 (Core.History_id.workspace identity) ->
            ()
        | Some _ | None ->
            fail_with_status 2 "wrong-workspace"
              "history identity belongs to another or unbound workspace");
        Core.History_id.sequence identity
    | Service.Working_tree | Service.Snapshot_state _ ->
        fail_with_status 2 "invalid-history-target"
          "choose a saved history node or workspace:sequence identity"
  in
  History.find history sequence |> function
  | Ok node -> node
  | Error message -> fail_with_status 2 "unknown-history-node" message

let restore_state ~root value =
  match parse_state value with
  | Service.Snapshot_state snapshot ->
      (snapshot, Service.Restore_snapshot snapshot)
  | Service.Working_tree ->
      fail_with_status 2 "invalid-restore-state"
        "restore needs a saved state; save working files before selecting them \
         as a target"
  | (Service.Current_saved | Service.History_node _ | Service.Exact_history _)
    as state ->
      let node = scoped_history_node ~root state in
      (node.History.snapshot, Service.Go_to node.History.id)

let parse_diff arguments =
  let rec loop root states = function
    | [] -> (Option.value root ~default:default_root, List.rev states)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) states rest
    | value :: rest
      when List.length states < 2 && not (String.starts_with ~prefix:"-" value)
      ->
        loop root (value :: states) rest
    | _ -> usage ()
  in
  let root, states = loop None [] arguments in
  let before, after =
    match states with
    | [] -> (Service.Current_saved, Service.Working_tree)
    | [ before ] -> (parse_state before, Service.Working_tree)
    | [ before; after ] -> (parse_state before, parse_state after)
    | _ -> usage ()
  in
  (root, before, after)

let run_diff arguments =
  let root, before, after = parse_diff arguments in
  let comparison =
    Service.compare_local_states ~root ~before ~after |> require_local
  in
  let changed = comparison.Service.display_differences <> [] in
  match requested_format () with
  | Json_format ->
      domain_json
        ~outcome:(if changed then `Completed else `Unchanged)
        ~code:(if changed then "states-differ" else "states-equal")
        ~message:
          (if changed then "Exact states differ."
           else "Exact states have equal contents.")
        ~data:
          (`Assoc
             [
               ("before", json_state comparison.Service.before_state);
               ("after", json_state comparison.Service.after_state);
               ( "differences",
                 `List
                   (List.map json_display_difference
                      comparison.Service.display_differences) );
             ])
        ~next_actions:[] ()
  | Text_format ->
      if requested_details () then Printf.printf "before %s snapshot %s\nafter %s snapshot %s\n"
        comparison.Service.before_state.Service.state_name
        (Model.Snapshot_id.to_string
           comparison.Service.before_state.Service.state_snapshot)
        comparison.Service.after_state.Service.state_name
        (Model.Snapshot_id.to_string
           comparison.Service.after_state.Service.state_snapshot)
      else if changed then Output.line ~tone:Output.Muted (compact_state comparison.Service.before_state ^ " -> " ^ compact_state comparison.Service.after_state);
      if not changed then Output.line ~tone:Output.Good "No differences"
      else
        List.iter render_display_difference
          comparison.Service.display_differences

let run_changes arguments =
  let root = parse_root arguments in
  let comparison =
    Service.compare_local_states ~root ~before:Service.Current_saved
      ~after:Service.Working_tree
    |> require_local
  in
  let differences =
    List.map
      (fun display -> display.Service.entry_difference)
      comparison.Service.display_differences
  in
  match requested_format () with
  | Json_format ->
      domain_json
        ~outcome:(if differences = [] then `Unchanged else `Completed)
        ~code:"changes-inspected"
        ~message:"Exact working-tree changes inspected."
        ~data:
          (`Assoc
             [
               ("saved", json_state comparison.Service.before_state);
               ("observed", json_state comparison.Service.after_state);
               ("differences", `List (List.map json_difference differences));
             ])
        ~next_actions:
          [ action ~root [ "diff" ] "Inspect readable text differences." ]
        ()
  | Text_format when not (requested_details ()) ->
      if differences = [] then Output.line ~tone:Output.Good "No changes to save"
      else List.iter render_compact_path differences
  | Text_format -> (
      Printf.printf "saved %s\nobserved %s\n"
        (Model.Snapshot_id.to_string
           comparison.Service.before_state.Service.state_snapshot)
        (Model.Snapshot_id.to_string
           comparison.Service.after_state.Service.state_snapshot);
      match differences with
      | [] -> print_endline "changes unchanged"
      | differences ->
          List.iter
            (fun difference ->
              Printf.printf "change %s before %s after %s\n"
                (Output.display_value
                   (Model.Path.to_string difference.Service.path))
                (render_snapshot_entry difference.Service.before)
                (render_snapshot_entry difference.Service.after))
            differences)

let display_capture_time timestamp =
  if timestamp = 0L then "capture time unrecorded"
  else
    try
      let time = Unix.gmtime (Int64.to_float timestamp) in
      Standard_printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d UTC"
        (time.Unix.tm_year + 1900) (time.Unix.tm_mon + 1) time.Unix.tm_mday
        time.Unix.tm_hour time.Unix.tm_min time.Unix.tm_sec
    with Unix.Unix_error _ | Invalid_argument _ -> "capture time unavailable"

let compact_capture_time timestamp =
  if timestamp = 0L then "" else
  try
    let time = Unix.localtime (Int64.to_float timestamp) in
    let today = Unix.localtime (Unix.gettimeofday ()) in
    if time.Unix.tm_year = today.Unix.tm_year && time.Unix.tm_yday = today.Unix.tm_yday then
      Standard_printf.sprintf "%02d:%02d" time.Unix.tm_hour time.Unix.tm_min
    else Standard_printf.sprintf "%04d-%02d-%02d" (time.Unix.tm_year + 1900) (time.Unix.tm_mon + 1) time.Unix.tm_mday
  with Unix.Unix_error _ | Invalid_argument _ -> "time unknown"

let render_compact_history page =
  Output.line ~tone:Output.Accent "Local history";
  List.iter (fun row ->
      let node = row.Service.history_node in
      let marker = if node.History.id = page.Service.page_cursor then "*" else "o" in
      let label = if node.History.parent = None then "Initial capture" else
        match row.Service.history_title,row.Service.history_paths with
        | Some title,_ when not (String.starts_with ~prefix:"Work on " title) -> Output.display_value title
        | _,Ok [] -> "No file changes"
        | _,Ok (path :: rest) -> Output.display_value (Model.Path.to_string path) ^ (if rest = [] then "" else Standard_printf.sprintf " +%d" (List.length rest))
        | _,Error _ -> "Changes unavailable"
      in
      let prefix = marker ^ " #" ^ Int64.to_string node.History.id ^ "  " in
      let time = compact_capture_time node.History.created_at in
      let label = Output.ellipsize ~max_columns:(Output.terminal_width () - String.length prefix - String.length time - 2) label in
      Output.line ~tone:(if marker = "*" then Output.Accent else Output.Plain) (prefix ^ label ^ (if time = "" then "" else "  " ^ time));
      Option.iter (fun parent ->
          let forked = List.exists (fun previous -> previous.Service.history_node.History.id = parent && List.length previous.Service.history_children > 1) page.Service.entries in
          if forked || parent <> Int64.pred node.History.id then
            Output.line ~tone:Output.Muted ("    from #" ^ Int64.to_string parent)) node.History.parent;
      if List.length row.Service.history_children > 1 then
        Output.line ~tone:Output.Muted ("    alternatives " ^ String.concat ", " (List.map (fun id -> "#" ^ Int64.to_string id) row.Service.history_children));
      (match row.Service.availability with
       | Service.Available -> ()
       | Service.Not_retained -> Output.line ~tone:Output.Caution "    ! Contents no longer retained"
       | Service.Unavailable reason -> Output.line ~tone:Output.Caution ("    ! Contents unavailable: " ^ display_line (public_error_message reason)))) page.Service.entries

let run_history arguments =
  let rec parse root before limit = function
    | [] ->
        ( Option.value root ~default:default_root,
          before,
          Option.value limit ~default:50 )
    | "--root" :: value :: rest when Option.is_none root ->
        parse (Some value) before limit rest
    | "--all" :: rest -> parse root before limit rest
    | "--before" :: value :: rest when Option.is_none before -> (
        match Int64.of_string_opt value with
        | Some value when Int64.compare value 0L >= 0 ->
            parse root (Some value) limit rest
        | _ ->
            fail_with_status 2 "invalid-history-cursor"
              "history cursor must be a nonnegative sequence")
    | "--limit" :: value :: rest when Option.is_none limit -> (
        match int_of_string_opt value with
        | Some value when value >= 1 && value <= 200 ->
            parse root before (Some value) rest
        | _ ->
            fail_with_status 2 "invalid-history-limit"
              "history limit must be 1-200")
    | _ -> usage ()
  in
  let root, before, limit = parse None None None arguments in
  let page =
    Service.inspect_local_history ~root ~before ~limit |> require_local
  in
  let reference sequence =
    Option.fold
      ~none:("node:" ^ Int64.to_string sequence)
      ~some:(fun workspace ->
        Core.Workspace_id.to_hex workspace ^ ":" ^ Int64.to_string sequence)
      page.Service.page_workspace
  in
  let availability = function
    | Service.Available -> "available"
    | Service.Not_retained -> "not-retained"
    | Service.Unavailable _ -> "unavailable"
  in
  let row_json row =
    `Assoc
      [
        ("id", `String (reference row.Service.history_node.History.id));
        ( "history",
          json_optional json_history_identity row.Service.history_identity );
        ( "sequence",
          `String (Int64.to_string row.Service.history_node.History.id) );
        ( "parent",
          json_optional
            (fun sequence -> `String (reference sequence))
            row.Service.history_node.History.parent );
        ( "children",
          `List
            (List.map
               (fun sequence -> `String (reference sequence))
               row.Service.history_children) );
        ( "snapshot_id",
          `String
            (Model.Snapshot_id.to_string
               row.Service.history_node.History.snapshot) );
        ( "title",
          json_optional (fun title -> `String title) row.Service.history_title
        );
        ( "captured_at",
          if row.Service.history_node.History.created_at = 0L then `Null
          else
            `Intlit
              (Int64.to_string row.Service.history_node.History.created_at) );
        ("availability", `String (availability row.Service.availability));
        ( "unavailable_reason",
          match row.Service.availability with
          | Service.Unavailable reason -> `String (public_error_message reason)
          | Service.Available | Service.Not_retained -> `Null );
        ( "changed_paths",
          match row.Service.history_paths with
          | Ok paths ->
              `List (List.map (fun path -> `Assoc (path_fields path)) paths)
          | Error _ -> `Null );
        ( "path_comparison_unavailable",
          match row.Service.history_paths with
          | Error reason -> `String (public_error_message reason)
          | Ok _ -> `Null );
        ( "referenced_by_branches",
          `List
            (List.map
               (fun id -> `String (Core.Branch_id.to_hex id))
               row.Service.referenced_by_branches) );
      ]
  in
  let next_actions =
    Option.fold ~none:[]
      ~some:(fun before ->
        [
          action ~root
            [
              "history";
              "--before";
              Int64.to_string before;
              "--limit";
              string_of_int limit;
            ]
            "Read the next page of saved history.";
        ])
      page.Service.next_before
    @ List.filter_map
        (fun row ->
          match row.Service.availability with
          | Service.Available when page.Service.page_verification = `Verified ->
              Some
                (action ~root
                   [
                     "undo";
                     "--to";
                     Int64.to_string row.Service.history_node.History.id;
                     "--dry-run";
                   ]
                   ("Preview recovery of "
                   ^ reference row.Service.history_node.History.id
                   ^ "."))
          | Service.Available | Service.Not_retained | Service.Unavailable _ ->
              None)
        page.Service.entries
  in
  let failure =
    match page.Service.page_verification with
    | `Verified -> None
    | `Unavailable message ->
        Some (5, `Unavailable, "saved-contents-unavailable", message)
    | `Integrity message ->
        Some (6, `Integrity_failure, "saved-state-unverified", message)
  in
  let next_actions =
    next_actions
    @
    if failure = None then []
    else
      [
        action ~root [ "verify" ]
          "Inspect the unavailable or invalid repository state.";
      ]
  in
  let data =
    `Assoc
      [
        ( "workspace_id",
          json_optional
            (fun id -> `String (Core.Workspace_id.to_hex id))
            page.Service.page_workspace );
        ("current", `String (reference page.Service.page_cursor));
        ("entries", `List (List.map row_json page.Service.entries));
        ( "next_before",
          json_optional
            (fun before -> `String (Int64.to_string before))
            page.Service.next_before );
        ("archive", `String "not-configured");
        ( "state_validation",
          match failure with
          | None -> `Assoc [ ("state", `String "verified") ]
          | Some (_, _, _, reason) ->
              `Assoc
                [
                  ("state", `String "unverified");
                  ("message", `String (public_error_message reason));
                ] );
      ]
  in
  (match requested_format () with
  | Json_format -> (
      match failure with
      | Some (_, outcome, code, message) ->
          Cli_data.domain_failure ~command:(command_name ()) ~outcome
            ~error:Cli_data.{ code; message = public_error_message message }
            ~data ~warnings:[] ~next_actions ()
          |> Cli_data.encode |> print_json
      | None ->
          domain_json ~outcome:`Completed ~code:"history-inspected"
            ~message:"Saved local history inspected." ~data ~next_actions ())
  | Text_format when not (requested_details ()) ->
      render_compact_history page;
      Option.iter (fun before -> Output.line ~tone:Output.Muted (Standard_printf.sprintf "More  yeokcham history --before %Ld --limit %d" before limit)) page.Service.next_before;
      Option.iter (fun (_,_,_,reason) -> Output.line ~tone:Output.Caution ("! Saved state unverified: " ^ display_line (public_error_message reason))) failure
  | Text_format ->
      Printf.printf "current %s\n" (reference page.Service.page_cursor);
      List.iter
        (fun row ->
          Printf.printf "%s %s %s %s %s\n"
            (if row.Service.history_node.History.id = page.Service.page_cursor
             then "*"
             else " ")
            (reference row.Service.history_node.History.id)
            (availability row.Service.availability)
            (display_capture_time row.Service.history_node.History.created_at)
            (Option.fold ~none:"title unavailable" ~some:Output.display_value
               row.Service.history_title);
          Printf.printf "  snapshot %s parent %s children %s\n"
            (Model.Snapshot_id.to_string
               row.Service.history_node.History.snapshot)
            (Option.fold ~none:"none" ~some:reference
               row.Service.history_node.History.parent)
            (String.concat ","
               (List.map reference row.Service.history_children));
          (match row.Service.history_paths with
          | Ok paths ->
              Printf.printf "  paths %s\n"
                (String.concat ", "
                   (List.map
                      (fun path ->
                        Output.display_value (Model.Path.to_string path))
                      paths))
          | Error reason ->
              Printf.printf "  paths unavailable: %s\n" (display_line reason));
          match row.Service.availability with
          | Service.Unavailable reason ->
              Printf.printf "  unavailable: %s\n" (display_line reason)
          | Service.Available | Service.Not_retained -> ())
        page.Service.entries;
      Option.iter
        (fun before ->
          Printf.printf "more: history --before %Ld --limit %d\n" before limit)
        page.Service.next_before;
      print_endline
        "archive not configured; availability describes local retained contents";
      Option.iter
        (fun (_, _, _, reason) ->
          Printf.printf "state verification unavailable: %s\n"
            (display_line (public_error_message reason)))
        failure);
  Option.iter (fun (status, _, _, _) -> exit status) failure

let run_undo_tree arguments =
  let root = parse_root arguments in
  let history =
    Service.local_history ~root |> require_ok Service.error_to_string
  in
  let tree = history.Service.undo_tree in
  let cursor = (History.current tree).History.id in
  let available node =
    List.exists
      (Model.Snapshot_id.equal node.History.snapshot)
      history.Service.retained_checkpoints
  in
  if requested_format () = Json_format then
    history_json_result "undo-tree"
      (`Assoc
         [
           ("current", `String (Int64.to_string cursor));
           ( "nodes",
             `List
               (List.map
                  (fun node ->
                    `Assoc
                      [
                        ("entry", history_json_node node);
                        ("available", `Bool (available node));
                      ])
                  (History.nodes tree)) );
         ])
  else (
    print_endline
      "Local undo tree (* = current; parent links identify branches)";
    List.iter
      (fun node ->
        Printf.printf "%s node %Ld <- %s  checkpoint %s  draft %s%s\n"
          (if Int64.equal cursor node.History.id then "*" else " ")
          node.History.id
          (Option.fold ~none:"root" ~some:Int64.to_string node.History.parent)
          (Model.Snapshot_id.to_string node.History.snapshot)
          (Output.display_value (Model.Draft_id.to_string node.History.draft))
          (if available node then "" else " [compacted]"))
      (History.nodes tree))

let recovery_json restored =
  `Assoc
    [
      ("operation_id", `String restored.Service.restore_operation);
      ( "safety_snapshot_id",
        `String (Model.Snapshot_id.to_string restored.Service.safety_checkpoint)
      );
      ( "target_snapshot_id",
        `String
          (Model.Snapshot_id.to_string restored.Service.restored_checkpoint) );
      ("resumed", `Bool restored.Service.resumed);
      ( "source_proof",
        if
          Model.Snapshot_id.equal restored.Service.safety_checkpoint
            restored.Service.restored_checkpoint
        then `Null
        else `String restored.Service.restore_operation );
      ( "retained_directory_relative",
        `String
          (".yeokcham/restore-staging/" ^ restored.Service.restore_operation) );
    ]

let navigation_json ~root result =
  let history =
    Service.local_history ~root |> require_local |> fun value ->
    value.Service.undo_tree
  in
  `Assoc
    [
      ("applied", `Bool result.Service.history_applied);
      ("source_node", `String (Int64.to_string result.Service.source_node));
      ("target", history_json_node result.Service.target_node);
      ( "target_history",
        json_optional json_history_identity
          (History.identity history result.Service.target_node
          |> Result.to_option) );
      ("target_provisional", `Bool result.Service.target_provisional);
      ("captures_unsaved", `Bool result.Service.captures_unsaved);
      ( "changes",
        `List (List.map json_difference result.Service.history_changes) );
      ("recovery", json_optional recovery_json result.Service.history_restore);
    ]

let render_navigation_details ~preview result =
  Printf.printf "%s node %Ld (snapshot %s)%s\n"
    (if preview then "would select" else "current")
    result.Service.target_node.History.id
    (Model.Snapshot_id.to_string result.Service.target_node.History.snapshot)
    (if result.Service.target_provisional then " [provisional; not allocated]"
     else "");
  if result.Service.captures_unsaved then
    print_endline
      (if preview then "would preserve unsaved disk edits as a new node"
       else "preserved unsaved disk edits as a new node");
  List.iter
    (fun difference ->
      Printf.printf "%s: %s -> %s\n"
        (Output.display_value (Model.Path.to_string difference.Service.path))
        (render_snapshot_entry difference.Service.before)
        (render_snapshot_entry difference.Service.after))
    result.Service.history_changes;
  Option.iter
    (fun recovery ->
      Printf.printf "%s %s%s\n"
        (if
           Model.Snapshot_id.equal recovery.Service.safety_checkpoint
             recovery.Service.restored_checkpoint
         then "selection-operation"
         else "restore-proof")
        recovery.Service.restore_operation
        (if recovery.Service.resumed then " (resumed original selection)"
         else "");
      Printf.printf "safety %s\nrestored %s in-place\n"
        (Model.Snapshot_id.to_string recovery.Service.safety_checkpoint)
        (Model.Snapshot_id.to_string recovery.Service.restored_checkpoint))
    result.Service.history_restore

let render_navigation_text ~preview result =
  if requested_details () then render_navigation_details ~preview result
  else (
    let number = Int64.to_string result.Service.target_node.History.id in
    let summary =
      if preview then "Preview / select saved version #" ^ number
      else if result.Service.history_applied then Output.symbol ~ascii:"+" ~unicode:"✓" ^ " Restored saved version #" ^ number
      else Output.symbol ~ascii:"=" ~unicode:"✓" ^ " Already at saved version #" ^ number
    in
    Output.line ~tone:(if preview then Output.Accent else Output.Good) summary;
    List.iter render_compact_path result.Service.history_changes;
    if result.Service.target_provisional then Output.line ~tone:Output.Muted "  New saved version; allocated only on confirmation.";
    if result.Service.captures_unsaved then Output.line ~tone:Output.Muted
        (if preview then "  Unsaved edits will be saved separately." else "  Unsaved edits saved separately.");
    if preview then Output.line ~tone:Output.Muted "Preview only. Rerun with --yes to apply.")

let run_local_navigation ~flags ~base_arguments ~direction =
  let root = flags.selection_root in
  set_local_failure_context ~root;
  let inspected =
    if flags.selection_yes then None
    else
      Some
        (Service.navigate_history_plan ~root ~direction ~dry_run:true
           ~expected_plan:flags.selection_plan
        |> require_local)
  in
  let is_noop result =
    let history = Service.local_history ~root |> require_local in
    (not result.Service.captures_unsaved)
    && (History.current history.Service.undo_tree).History.id
       = result.Service.target_node.History.id
  in
  let unchanged = Option.fold ~none:false ~some:is_noop inspected in
  let actions result =
    [
      action ~confirmation_required:true ~root
        (append_before_literal base_arguments
           ([ "--yes" ]
           @ Option.fold ~none:[]
               ~some:(fun id -> [ "--plan"; id ])
               result.Service.selection_plan))
        "Apply this exact saved-state selection after fresh validation.";
      action ~root
        (append_before_literal base_arguments [ "--preview" ])
        "Inspect selection effects without changing history or files.";
    ]
  in
  let cancelled =
    (not flags.selection_yes)
    && (not flags.selection_preview)
    && (not unchanged)
    && not
         (let result = Option.get inspected in
          confirm_local_selection ?plan_id:result.Service.selection_plan
            ~data:(navigation_json ~root result)
            ~next_actions:(actions result)
            ~render:(fun () -> render_navigation_text ~preview:true result)
            ())
  in
  let result =
    if flags.selection_yes then
      Service.navigate_history_plan ~root ~direction ~dry_run:false
        ~expected_plan:flags.selection_plan
      |> require_local
    else if flags.selection_preview || unchanged || cancelled then
      Option.get inspected
    else
      let preview = Option.get inspected in
      Service.navigate_history_plan ~root ~direction ~dry_run:false
        ~expected_plan:preview.Service.selection_plan
      |> require_local
  in
  if requested_format () = Json_format then
    domain_json ?plan_id:result.Service.selection_plan
      ?operation_id:
        (Option.map
           (fun recovery -> recovery.Service.restore_operation)
           result.Service.history_restore)
      ~outcome:
        (if
           cancelled
           || (not flags.selection_preview)
              && not result.Service.history_applied
         then `Unchanged
         else `Completed)
      ~code:
        (if cancelled then "selection-cancelled"
         else if flags.selection_preview then "selection-preview"
         else if result.Service.history_applied then "state-selected"
         else "state-unchanged")
      ~message:
        (if cancelled then
           "Selection cancelled; files and history are unchanged."
         else if flags.selection_preview then
           "Exact saved-state selection preview; files and history are \
            unchanged."
         else if result.Service.history_applied then
           "Exact saved state selected; private alternatives retained."
         else "The exact saved state is already selected.")
      ~data:(navigation_json ~root result)
      ~next_actions:
        (if flags.selection_preview then actions result
         else
           [
             action ~root [ "status" ] "Inspect local files and capture state.";
             action ~root [ "history" ] "Inspect retained alternatives.";
           ])
      ()
  else if cancelled then
    print_endline "Selection cancelled; files and history are unchanged."
  else render_navigation_text ~preview:flags.selection_preview result;
  result.Service.history_applied

let run_history_navigation command arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  let root = flags.selection_root in
  set_local_failure_context ~root;
  let target =
    match remaining with
    | [] -> None
    | [ option; value ]
      when option = if command = "undo" then "--to" else "--node" ->
        Some (scoped_history_node ~root (parse_state value)).History.id
    | _ -> usage ()
  in
  let direction =
    match (command, target) with
    | "undo", None -> Service.Undo
    | "undo", Some node -> Service.Go_to node
    | _, target -> Service.Redo target
  in
  let applied =
    run_local_navigation ~flags ~base_arguments:(command :: remaining)
      ~direction
  in
  if applied then run_hooks_after_success [ command ] arguments;
  applied

let copyout_json result =
  `Assoc
    [
      ( "snapshot_id",
        `String (Model.Snapshot_id.to_string result.Service.copy_snapshot) );
      ("destination", json_byte_path result.Service.copy_destination);
      ("applied", `Bool result.Service.copy_applied);
      ("resumed", `Bool result.Service.copy_resumed);
      ( "operation_id",
        json_optional (fun id -> `String id) result.Service.copy_operation );
      ("source_history_changed", `Bool false);
      ("source_branch_changed", `Bool false);
      ( "retained_directory_relative",
        json_optional
          (fun op -> `String (".yeokcham/restore-staging/" ^ op))
          result.Service.copy_operation );
    ]

let render_copyout_text ~preview result =
  Printf.printf "%s snapshot %s to %s%s\n"
    (if preview then "would copy" else "copied")
    (Model.Snapshot_id.to_string result.Service.copy_snapshot)
    (Output.display_value result.Service.copy_destination)
    (if result.Service.copy_resumed then " (resumed original operation)" else "");
  print_endline "source history and branch selection unchanged";
  Option.iter
    (fun op -> Printf.printf "recovery-operation %s\n" op)
    result.Service.copy_operation

let run_copyout ~flags ~base_arguments ~checkpoint ~destination =
  let root = flags.selection_root in
  let inspected =
    if flags.selection_yes then None
    else
      Some
        (Service.preview_copy_out ~root ~checkpoint ~destination
        |> require_local)
  in
  (match (flags.selection_plan, inspected) with
  | Some expected, Some preview when expected <> preview.Service.copy_plan ->
      fail_with_status 3 "stale-selection-plan"
        "Recovery-copy inputs changed; inspect a fresh preview."
  | None, _ | Some _, _ -> ());
  let actions result =
    [
      action ~confirmation_required:true ~root
        (append_before_literal base_arguments
           [ "--yes"; "--plan"; result.Service.copy_plan ])
        "Create this exact recovery copy without changing source history.";
      action ~root
        (append_before_literal base_arguments [ "--preview" ])
        "Inspect the recovery-copy destination before application.";
    ]
  in
  let cancelled =
    (not flags.selection_yes)
    && (not flags.selection_preview)
    && not
         (let preview = Option.get inspected in
          confirm_local_selection ~plan_id:preview.Service.copy_plan
            ~data:(copyout_json preview) ~next_actions:(actions preview)
            ~render:(fun () -> render_copyout_text ~preview:true preview)
            ())
  in
  let result =
    if flags.selection_yes then
      Service.copy_out ~root ~checkpoint ~destination
        ~expected_plan:flags.selection_plan
      |> require_local
    else if flags.selection_preview || cancelled then Option.get inspected
    else
      let preview = Option.get inspected in
      Service.copy_out ~root ~checkpoint ~destination
        ~expected_plan:(Some preview.Service.copy_plan)
      |> require_local
  in
  if requested_format () = Json_format then
    domain_json ?operation_id:result.Service.copy_operation
      ?plan_id:
        (if result.Service.copy_plan = "" then None
         else Some result.Service.copy_plan)
      ~outcome:(if cancelled then `Unchanged else `Completed)
      ~code:
        (if cancelled then "selection-cancelled"
         else if flags.selection_preview then "copy-preview"
         else "snapshot-copied")
      ~message:
        (if cancelled then
           "Recovery copy cancelled; files and history are unchanged."
         else if flags.selection_preview then
           "Recovery-copy preview; destination and source history are \
            unchanged."
         else
           "Saved snapshot copied; source history and branch selection are \
            unchanged.")
      ~data:(copyout_json result)
      ~next_actions:
        (if flags.selection_preview then actions result
         else [ action ~root [ "history" ] "Inspect source alternatives." ])
      ()
  else if cancelled then
    print_endline "Recovery copy cancelled; files and history are unchanged."
  else render_copyout_text ~preview:flags.selection_preview result;
  false

let recorded_selection_plan ~root journal =
  match
    ( Journal.selection_plan journal,
      Journal.destination journal,
      Journal.plan journal )
  with
  | Some raw, _, _ -> Some (hex_of_bytes raw)
  | None, Some _, Some (digest, None) ->
      let id =
        match
          Yeokcham_store.Stored_object_id.of_hex
            (Model.Snapshot_id.to_string (Journal.target journal))
        with
        | Ok id -> id
        | Error _ ->
            fail_with_status 6 "recovery-integrity-failure"
              "Copy-out target identity is malformed."
      in
      let target = Yeokcham_snapshot.Snapshot.of_stored_object_id id in
      let physical =
        match
          Service.Safe_apply.load ~root
            ~operation:(Journal.operation_id journal)
            ~digest ~safety:target ~target
        with
        | Ok plan -> plan
        | Error error ->
            let status =
              match error with
              | Service.Safe_apply.Unavailable _ -> 5
              | Service.Safe_apply.Invalid_plan _ -> 6
              | Service.Safe_apply.Conflict _ -> 8
            in
            fail_with_status status "recovery-plan-unavailable"
              (Service.Safe_apply.error_to_string error)
      in
      let token =
        match Service.Safe_apply.copyout_token physical with
        | Ok token -> token
        | Error error ->
            fail_with_status 6 "recovery-integrity-failure"
              (Service.Safe_apply.error_to_string error)
      in
      Some (hex_of_bytes token)
  | None, None, _ | None, Some _, (None | Some (_, Some _)) -> None

let run_recovery_resume ~flags ~operation =
  let root = flags.selection_root in
  let history =
    Service.local_history ~root |> require_local |> fun result ->
    result.Service.undo_tree
  in
  let journals = latest_recovery_journals ~root in
  let selected =
    match operation with
    | Some op -> (
        match List.find_opt (fun j -> Journal.operation_id j = op) journals with
        | Some j -> Some j
        | None ->
            fail_with_status 2 "unknown-operation"
              "No recorded recovery operation has that ID.")
    | None -> (
        match
          List.filter (fun j -> Journal.phase j <> Journal.Published) journals
        with
        | [] -> None
        | [ j ] -> Some j
        | pending ->
            selection_choice
              ~data:
                (`Assoc
                   [
                     ( "operations",
                       `List (List.map (operation_json ~history) pending) );
                   ])
              ~next_actions:
                (List.map
                   (fun j ->
                     action ~confirmation_required:true ~root
                       [
                         "restore";
                         "--resume";
                         "--operation";
                         Journal.operation_id j;
                         "--yes";
                       ]
                       "Resume this exact recorded operation.")
                   pending)
              ~message:"Choose a recovery operation with --operation." ())
  in
  match selected with
  | None ->
      if requested_format () = Json_format then
        domain_json ~outcome:`Unchanged ~code:"no-recovery-pending"
          ~message:"No recovery operation is pending."
          ~data:(`Assoc [ ("operations", `List []) ])
          ~next_actions:[] ()
      else print_endline "no recovery operation is pending";
      false
  | Some journal ->
      let op = Journal.operation_id journal in
      let plan =
        if flags.selection_plan = None then
          Option.map hex_of_bytes (Journal.selection_plan journal)
        else recorded_selection_plan ~root journal
      in
      (match flags.selection_plan with
      | Some expected when plan <> Some expected ->
          fail_with_status 3 "stale-selection-plan"
            "The recorded recovery operation has a different plan."
      | None | Some _ -> ());
      let data = operation_json ~history journal in
      let actions =
        [
          action ~confirmation_required:true ~root
            ([ "restore"; "--resume"; "--operation"; op; "--yes" ]
            @ Option.fold ~none:[]
                ~some:(fun p -> [ "--plan"; p ])
                flags.selection_plan)
            "Resume this recorded target after validating retained and live \
             data.";
          action ~root
            [ "restore"; "--resume"; "--operation"; op; "--preview" ]
            "Inspect this recorded recovery operation.";
        ]
      in
      let already = Journal.phase journal = Journal.Published in
      let cancelled =
        (not flags.selection_yes)
        && (not flags.selection_preview)
        && (not already)
        && not
             (confirm_local_selection
                ?plan_id:
                  (Option.map hex_of_bytes (Journal.selection_plan journal))
                ~data ~next_actions:actions
                ~render:(fun () ->
                  Printf.printf "recovery-operation %s target %s (%s)\n" op
                    (Model.Snapshot_id.to_string (Journal.target journal))
                    (journal_phase (Journal.phase journal)))
                ())
      in
      if flags.selection_preview || cancelled then (
        if requested_format () = Json_format then
          domain_json ~operation_id:op
            ?plan_id:(Option.map hex_of_bytes (Journal.selection_plan journal))
            ~outcome:(if cancelled then `Unchanged else `Completed)
            ~code:
              (if cancelled then "selection-cancelled" else "recovery-preview")
            ~message:
              (if cancelled then
                 "Recovery cancelled; files and history are unchanged."
               else
                 "Recorded recovery target inspected; current files were not \
                  scanned or rewritten.")
            ~data ~next_actions:actions ()
        else
          print_endline
            (if cancelled then
               "Recovery cancelled; files and history are unchanged."
             else
               "recorded recovery target inspected; files and history are \
                unchanged");
        false)
      else
        let recovered =
          Service.recover_operation_plan ~root ~operation:(Some op)
            ~expected_plan:flags.selection_plan
          |> require_local |> Option.get
        in
        let in_place =
          match recovered.Service.recovered with
          | Service.Recovered_in_place _ -> true
          | Service.Recovered_copy_out _ -> false
        in
        let data =
          `Assoc
            [
              ("operation", data);
              ("already_completed", `Bool recovered.Service.already_completed);
              ("applied", `Bool (not recovered.Service.already_completed));
              ("current_contents_reverified", `Bool false);
              ( "result",
                match recovered.Service.recovered with
                | Service.Recovered_in_place result -> recovery_json result
                | Service.Recovered_copy_out result -> copyout_json result );
            ]
        in
        if requested_format () = Json_format then
          domain_json ~operation_id:op
            ?plan_id:(Option.map hex_of_bytes (Journal.selection_plan journal))
            ~outcome:
              (if recovered.Service.already_completed then `Unchanged
               else `Completed)
            ~code:
              (if recovered.Service.already_completed then
                 "operation-already-completed"
               else "operation-recovered")
            ~message:
              (if recovered.Service.already_completed then
                 "The recorded operation completed earlier; current files were \
                  not reverified or rewritten."
               else
                 "The original recorded operation completed without another \
                  navigation step.")
            ~data
            ~next_actions:
              [
                action ~root [ "status" ]
                  "Inspect local files and capture state.";
              ]
            ()
        else
          Printf.printf
            "%s recovery-operation %s; current files were not rescanned\n"
            (if recovered.Service.already_completed then "already completed"
             else "completed original")
            op;
        in_place && not recovered.Service.already_completed

let run_restore arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  let root = flags.selection_root in
  set_local_failure_context ~root;
  let rec parse state destination resume operation = function
    | [] -> (state, destination, resume, operation)
    | "--resume" :: rest when not resume ->
        parse state destination true operation rest
    | "--operation" :: op :: rest when operation = None ->
        if
          String.length op <> 64
          || not
               (String.for_all
                  (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
                  op)
        then
          fail_with_status 2 "invalid-operation-id"
            "operation IDs are lowercase 64-digit identifiers";
        parse state destination resume (Some op) rest
    | "--checkpoint" :: value :: rest when state = None ->
        parse (Some value) destination resume operation rest
    | ("--to" | "--destination") :: value :: rest when destination = None ->
        parse state (Some value) resume operation rest
    | "--" :: [ value ] when state = None ->
        parse (Some value) destination resume operation []
    | value :: rest
      when state = None && not (String.starts_with ~prefix:"-" value) ->
        parse (Some value) destination resume operation rest
    | _ -> usage ()
  in
  let state, destination, resume, operation =
    parse None None false None remaining
  in
  if resume then (
    if state <> None || destination <> None then
      fail_with_status 2 "invalid-invocation"
        "--resume cannot select another state or destination";
    run_recovery_resume ~flags ~operation)
  else (
    if operation <> None then
      fail_with_status 2 "invalid-invocation" "--operation requires --resume";
    let state = match state with Some value -> value | None -> usage () in
    let checkpoint, direction = restore_state ~root state in
    match destination with
    | Some destination ->
        run_copyout ~flags
          ~base_arguments:[ "restore"; state; "--to"; destination ]
          ~checkpoint ~destination
    | None ->
        run_local_navigation ~flags ~base_arguments:[ "restore"; state ]
          ~direction)

let render_proposal_entry = function
  | None -> "missing"
  | Some Proposal.Directory -> "directory"
  | Some (Proposal.File { mode; content }) ->
      "file " ^ snapshot_mode_name mode ^ " " ^ content

let render_decision_proposal (proposal : Proposal.t) =
  let provenance = proposal.Proposal.provenance in
  Printf.printf "proposal decision %s\n"
    (Model.Decision_id.to_string provenance.Proposal.decision);
  Printf.printf "baseline %s\n"
    (Model.Snapshot_id.to_string provenance.Proposal.current_baseline);
  Printf.printf "left revision %s base %s snapshot %s\n"
    (Model.Revision_id.to_string provenance.Proposal.left_revision)
    (Model.Snapshot_id.to_string provenance.Proposal.left_base)
    (Model.Snapshot_id.to_string provenance.Proposal.left_result);
  Printf.printf "right revision %s base %s snapshot %s\n"
    (Model.Revision_id.to_string provenance.Proposal.right_revision)
    (Model.Snapshot_id.to_string provenance.Proposal.right_base)
    (Model.Snapshot_id.to_string provenance.Proposal.right_result);
  Printf.printf "confidence %s\n"
    (match proposal.Proposal.confidence with
    | Proposal.Exact_source -> "exact-source"
    | Proposal.No_confidence -> "none");
  (match proposal.Proposal.readiness with
  | Proposal.Ready -> Printf.printf "status ready-exact\n"
  | Proposal.Refused refusals ->
      Printf.printf "status refused\n";
      List.iter
        (fun refusal ->
          Printf.printf "refusal %s\n" (Proposal.refusal_to_string refusal))
        refusals);
  List.iter
    (fun path ->
      let outcome =
        match path.Proposal.outcome with
        | Proposal.Select { source; _ } ->
            "select-" ^ Proposal.source_to_string source
        | Proposal.Conflict conflict ->
            "conflict-" ^ Proposal.conflict_to_string conflict
        | Proposal.Unassessed_without_common_base ->
            "unassessed-without-common-base"
      in
      Printf.printf "path %s outcome %s base %s left %s right %s\n"
        (Output.display_value (Model.Path.to_string path.Proposal.path))
        outcome
        (render_proposal_entry path.Proposal.base)
        (render_proposal_entry path.Proposal.left)
        (render_proposal_entry path.Proposal.right))
    proposal.Proposal.paths

let render_range (range : Yeokcham_v1_lsp_sidecar.range) =
  Printf.sprintf "%d:%d-%d:%d" range.start.line range.start.character
    range.end_.line range.end_.character

let render_semantic_advice = function
  | Service.Semantic_not_configured ->
      print_endline "semantic status byte-only-no-matching-enabled-server"
  | Service.Semantic_multiple_servers names ->
      Printf.printf "semantic status select-server %s\n"
        (String.concat "," names)
  | Service.Semantic_report
      (Yeokcham_v1_lsp_sidecar.Unavailable { server; reason }) ->
      Printf.printf "semantic status unavailable server %s reason %s\n" server
        reason
  | Service.Semantic_report (Yeokcham_v1_lsp_sidecar.Available report) ->
      let server = report.Yeokcham_v1_lsp_sidecar.server in
      Printf.printf "semantic status advisory server %s program %s\n"
        server.configured_name server.program;
      Printf.printf "semantic server-info name %s version %s capabilities %s\n"
        (Option.value server.reported_name ~default:"unreported")
        (Option.value server.reported_version ~default:"unreported")
        (String.concat "," server.capabilities);
      List.iter
        (fun (role, snapshot) ->
          Printf.printf "semantic snapshot %s %s\n"
            (Yeokcham_v1_lsp_sidecar.snapshot_role_to_string role)
            snapshot)
        report.snapshots;
      List.iter
        (fun (symbol : Yeokcham_v1_lsp_sidecar.symbol) ->
          Printf.printf
            "semantic symbol snapshot %s snapshot-id %s path %s name %s kind \
             %s range %s definitions %d references %d workspace-matches %d\n"
            (Yeokcham_v1_lsp_sidecar.snapshot_role_to_string symbol.snapshot)
            symbol.snapshot_id symbol.path symbol.name symbol.kind
            (render_range symbol.range)
            (List.length symbol.definitions)
            (List.length symbol.references)
            (List.length symbol.workspace_matches);
          let render_locations kind locations =
            List.iter
              (fun (path, range) ->
                Printf.printf
                  "semantic %s snapshot %s symbol %s path %s range %s\n" kind
                  symbol.snapshot_id symbol.name path (render_range range))
              locations
          in
          render_locations "definition" symbol.definitions;
          render_locations "reference" symbol.references;
          render_locations "workspace-match" symbol.workspace_matches)
        report.symbols;
      List.iter
        (fun (overlap : Yeokcham_v1_lsp_sidecar.possible_overlap) ->
          Printf.printf
            "semantic possible-overlap path %s symbol %s evidence %s left %s \
             right %s\n"
            overlap.path overlap.symbol
            (Yeokcham_v1_lsp_sidecar.overlap_evidence_to_string overlap.evidence)
            overlap.left_snapshot overlap.right_snapshot)
        report.possible_overlaps

let run_decision_propose arguments =
  let root, decision, pair, semantic_server =
    parse_decision_propose arguments
  in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  match pair with
  | None ->
      let pairs =
        Service.proposal_pairs ~root ~decision
        |> require_ok Service.error_to_string
      in
      Printf.printf "decision %s\n" (Model.Decision_id.to_string decision);
      Printf.printf "proposal-pairs %d\n" (List.length pairs);
      List.iter
        (fun (left, right) ->
          Printf.printf "proposal-pair %s %s\n"
            (Model.Revision_id.to_string left)
            (Model.Revision_id.to_string right))
        pairs
  | Some (left, right) ->
      let left =
        parse_identifier "invalid revision identifier"
          Model.Revision_id.of_string left
      in
      let right =
        parse_identifier "invalid revision identifier"
          Model.Revision_id.of_string right
      in
      Service.inspect_decision_proposal ~root ~decision ~left ~right
        ~semantic_server
      |> require_ok Service.error_to_string
      |> fun inspection ->
      render_decision_proposal inspection.Service.exact_proposal;
      render_semantic_advice inspection.semantic_advice

let run_decision_materialize_proposal arguments =
  let root, decision, left, right, destination =
    parse_decision_materialize_proposal arguments
  in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let left =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      left
  in
  let right =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      right
  in
  let materialized =
    Service.materialize_decision_proposal ~root ~decision ~left ~right
      ~destination
    |> require_ok Service.error_to_string
  in
  Printf.printf "proposal-materialized %s\n"
    materialized.Service.proposal_directory;
  print_endline
    "proposal remains unaccepted; inspect it, then resolve explicitly if you \
     choose it"

let run_decision_diff arguments =
  let root, decision, candidate, against = parse_decision_diff arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let candidate =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      candidate
  in
  let against =
    if String.equal against "base" then Service.Baseline
    else
      Service.Candidate
        (parse_identifier "invalid revision identifier"
           Model.Revision_id.of_string against)
  in
  let comparison =
    Service.compare_decision ~root ~decision ~candidate ~against
    |> require_ok Service.error_to_string
  in
  Printf.printf "decision %s\n"
    (Model.Decision_id.to_string
       comparison.Service.compared_decision.Model.decision_id);
  Printf.printf "candidate %s\n"
    (Model.Revision_id.to_string
       comparison.Service.compared_candidate.Model.revision);
  Printf.printf "against %s\n"
    (Model.Snapshot_id.to_string comparison.Service.against);
  List.iter
    (fun difference ->
      Printf.printf "diff %s before %s after %s\n"
        (Output.display_value (Model.Path.to_string difference.Service.path))
        (render_snapshot_entry difference.Service.before)
        (render_snapshot_entry difference.Service.after))
    comparison.Service.differences

let run_decision_materialize arguments =
  let root, decision, destination = parse_decision_materialize arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let candidates =
    Service.materialize_decision ~root ~decision ~destination
    |> require_ok Service.error_to_string
  in
  List.iter
    (fun candidate ->
      let username =
        match candidate.Service.username with
        | Some username -> Model.Username.to_string username
        | None -> "unregistered"
      in
      Printf.printf "materialized %s author %s username %s tree %s\n"
        (Model.Revision_id.to_string candidate.Service.revision)
        (Model.Device_id.to_string candidate.Service.author)
        username candidate.Service.directory)
    candidates

let run_resolve arguments =
  let root, decision, change, revision, tree, authority_epoch =
    parse_resolve arguments
  in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  let signing_capability = local_signing_capability root in
  Service.resolve_signed ~authority_epoch ~root ~decision ~change ~revision
    ~tree ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_deliver arguments =
  let rec loop root id draft title = function
    | [] -> (
        match (id, draft, title) with
        | Some id, Some draft, Some title ->
            (Option.value root ~default:default_root, id, draft, title)
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id draft title rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) draft title rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root id (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root id draft (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_new_draft arguments =
  let root, id, title = parse_new_draft arguments in
  let id =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string id
  in
  Service.new_draft ~root ~id ~title
  |> require_ok Service.error_to_string
  |> render_status

let run_legacy_share arguments =
  let root, change, revision, authority_epoch = parse_share arguments in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  let signing_capability = local_signing_capability root in
  Service.share_signed ~authority_epoch ~root ~change ~revision
    ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_selected_share arguments =
  let rec loop root title update preview paths = function
    | [] ->
        ( Option.value root ~default:default_root,
          title,
          update,
          preview,
          List.rev paths )
    | "--" :: remaining ->
        ( Option.value root ~default:default_root,
          title,
          update,
          preview,
          List.rev paths @ remaining )
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) title update preview paths rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root (Some value) update preview paths rest
    | "--update" :: value :: rest when Option.is_none update ->
        loop root title (Some value) preview paths rest
    | ("--preview" | "--dry-run") :: rest when not preview ->
        loop root title update true paths rest
    | value :: _ when String.starts_with ~prefix:"-" value -> usage ()
    | value :: rest -> loop root title update preview (value :: paths) rest
  in
  let root, title, update, preview, paths =
    loop None None None false [] arguments
  in
  let normalize text =
    if text = "" || not (Filename.is_relative text) then
      fail_with "invalid-share-path"
        "Share paths must be relative to the workspace root.";
    let rec trim_start text =
      if String.starts_with ~prefix:"./" text then
        trim_start (String.sub text 2 (String.length text - 2))
      else text
    in
    let text = trim_start text in
    let text = if text = "" then "." else text in
    let rec trim_end length =
      if length > 0 && text.[length - 1] = '/' then trim_end (length - 1)
      else length
    in
    let text = String.sub text 0 (trim_end (String.length text)) in
    if text = "." then []
    else
      let parts = String.split_on_char '/' text in
      if
        List.exists
          (fun part ->
            part = "" || part = "." || part = ".."
            || String.contains part '\000')
          parts
      then
        fail_with "invalid-share-path"
          "Share paths cannot contain empty, dot, parent, or NUL components.";
      parts
  in
  let paths = List.map normalize paths in
  let paths = if List.mem [] paths then [] else paths in
  let update =
    Option.map
      (fun value ->
        match Core.Change_id.of_hex value with
        | Ok id -> id
        | Error error ->
            fail_with "invalid-change-identity" (Core.error_to_string error))
      update
  in
  (root, title, update, preview, paths)

let run_share arguments =
  if legacy_share_arguments arguments then (
    run_legacy_share arguments;
    true)
  else
    let root, title, update, dry_run, paths = parse_selected_share arguments in
    let signing_capability =
      if dry_run then None
      else
        let identity = Service.identity ~root |> require_local in
        match
          V1_signer.load ~root (Trust.device_id identity.Service.device)
        with
        | Ok capability -> Some capability
        | Error error ->
            fail_with_status 5 "signing-provider-unavailable"
              (V1_signer.error_to_string error)
    in
    let result =
      Service.share_selected ~root ~paths ~update ~title ~dry_run
        ~signing_capability
      |> require_local
    in
    let share = result in
    let module Share = Service.Share in
    let operation_id =
      Option.map
        (fun p -> Core.Operation_id.to_hex p.Local.operation)
        share.Share.publication
    in
    let optional encode =
      Option.fold ~none:`Null ~some:(fun value -> `String (encode value))
    in
    let paths values =
      `List
        (List.map (fun path -> json_byte_path (String.concat "/" path)) values)
    in
    let recorded = Option.is_some share.Share.publication in
    let code, message =
      if dry_run then
        ( "share-preview",
          "Selected public work previewed; no revision or history was \
           published." )
      else if share.Share.repeated then
        ( "share-repeated",
          "The recorded publication was reused; transfer is pending." )
      else if recorded then
        ( "share-recorded",
          "Selected work was recorded locally; transfer is pending." )
      else ("share-unchanged", "No newly selected public changes were recorded.")
    in
    (match requested_format () with
    | Json_format ->
        domain_json ?operation_id
          ~outcome:
            (if (not dry_run) && (share.Share.repeated || not recorded) then
               `Unchanged
             else `Completed)
          ~code ~message
          ~data:
            (`Assoc
               [
                 ("preview", `Bool dry_run);
                 ("repeated", `Bool share.Share.repeated);
                 ("change_id", optional Core.Change_id.to_hex share.Share.change);
                 ( "revision_id",
                   optional Core.Record_id.to_hex share.Share.revision );
                 ("title", `String share.Share.title);
                 ( "workspace_id",
                   `String
                     (Core.Workspace_id.to_hex
                        (Core.History_id.workspace share.Share.source)) );
                 ( "source_sequence",
                   `String
                     (Int64.to_string
                        (Core.History_id.sequence share.Share.source)) );
                 ( "source_provisional",
                   `Bool (dry_run && share.Share.captures_unsaved) );
                 ( "observed_snapshot",
                   `String (Core.Object_id.to_hex share.Share.observed) );
                 ( "base_snapshot",
                   `String (Core.Object_id.to_hex share.Share.base_snapshot) );
                 ( "public_snapshot",
                   `String (Core.Object_id.to_hex share.Share.public_snapshot)
                 );
                 ("contributed_paths", paths share.Share.contributed_paths);
                 ("public_paths", paths share.Share.public_paths);
                 ("captures_unsaved", `Bool share.Share.captures_unsaved);
                 ( "transfer_state",
                   `String (if recorded then "pending" else "none") );
                 ("accepted", `Bool false);
               ])
          ~next_actions:
            [
              action ~root [ "status" ]
                "Inspect local capture and shared-work state.";
            ]
          ()
    | Text_format ->
        print_endline message;
        Printf.printf "title %s\n" (Output.display_value share.Share.title);
        Option.iter
          (fun id -> Printf.printf "change %s\n" (Core.Change_id.to_hex id))
          share.Share.change;
        Option.iter
          (fun id -> Printf.printf "revision %s\n" (Core.Record_id.to_hex id))
          share.Share.revision;
        Option.iter (fun id -> Printf.printf "operation %s\n" id) operation_id;
        List.iter
          (fun path ->
            Printf.printf "selected %s\n"
              (Output.display_value (String.concat "/" path)))
          share.Share.contributed_paths;
        Printf.printf "public-snapshot %s\n"
          (Core.Object_id.to_hex share.Share.public_snapshot);
        if recorded then
          print_endline "transfer pending; shared acceptance is separate");
    (not dry_run) && recorded && not share.Share.repeated

let parse_package_create arguments =
  let rec loop root destination = function
    | [] -> (
        match destination with
        | Some destination ->
            (Option.value root ~default:default_root, destination)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_package_create arguments =
  let root, destination = parse_package_create arguments in
  Service.create_package ~root ~destination
  |> require_ok Service.error_to_string;
  Printf.printf "package %s\n" destination

let parse_receive arguments =
  let rec loop root package review = function
    | [] -> (
        match package with
        | Some package ->
            (Option.value root ~default:default_root, package, review)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package review rest
    | "--from" :: value :: rest when Option.is_none package ->
        loop root (Some value) review rest
    | "--review" :: rest when not review -> loop root package true rest
    | _ -> usage ()
  in
  loop None None false arguments

let run_receive arguments =
  let root, package, review = parse_receive arguments in
  if review then
    Service.review_package ~root ~package
    |> require_ok Service.error_to_string
    |> List.iter (fun candidate ->
        Printf.printf "review %s author %s adoption %s\n"
          (Model.Revision_id.to_string candidate.Service.review_revision)
          (Model.Device_id.to_string candidate.Service.review_author)
          (if candidate.Service.requires_adoption then "required"
           else "not-required"))
  else
    Service.receive_package ~root ~package
    |> require_ok Service.error_to_string
    |> render_status

let parse_package_adopt arguments =
  let rec loop root package revision authority = function
    | [] -> (
        match (package, revision) with
        | Some package, Some revision ->
            ( Option.value root ~default:default_root,
              package,
              revision,
              authority )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package revision authority rest
    | "--from" :: value :: rest when Option.is_none package ->
        loop root (Some value) revision authority rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root package (Some value) authority rest
    | "--authority" :: value :: rest when Option.is_none authority ->
        loop root package revision (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_package_adopt arguments =
  let root, package, revision, authority_epoch =
    parse_package_adopt arguments
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  let signing_capability = local_signing_capability root in
  Service.adopt_package_revision ~authority_epoch ~root ~package ~revision
    ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let require_integration_store ~root = function
  | Ok value -> value
  | Error error -> (
      match Service.inspect_saved_state ~root with
      | Ok (Store.Metadata_only metadata) ->
          render_metadata_status ~root metadata
      | Ok (Store.Verified _) | Error _ ->
          fail_local (Service.Store_error error))

let integration_repository root =
  let repository =
    Yeokcham_v1_store.open_repository ~root |> require_integration_store ~root
  in
  let loaded =
    Yeokcham_v1_store.load repository |> require_integration_store ~root
  in
  let local =
    match loaded.Yeokcham_v1_store.local with
    | Some value -> value
    | None ->
        fail_with_status 5 "integration-state-unavailable"
          "This workspace has no authenticated Core state."
  in
  (repository, loaded, local)

let native_failure_context root () =
  let loaded =
    match Yeokcham_v1_store.open_repository ~root with
    | Error _ -> None
    | Ok repository -> (
        match Yeokcham_v1_store.load repository with
        | Ok loaded -> Some loaded
        | Error _ -> None)
  in
  match Option.bind loaded (fun loaded -> loaded.Yeokcham_v1_store.local) with
  | None -> (`Assoc [ ("integration_state", `String "unavailable") ], [], None)
  | Some local ->
      let pending = Local.pending_operation local in
      ( `Assoc
          [
            ( "operations",
              `List
                (List.map json_integration_operation (Local.operations local))
            );
          ],
        (match pending with
        | None -> []
        | Some operation ->
            [
              action ~root
                [
                  "operation";
                  "show";
                  Core.Operation_id.to_hex operation.Integration_op.token;
                ]
                "Inspect the exact preserved operation before resuming.";
              action ~root
                [
                  "operation";
                  "resume";
                  Core.Operation_id.to_hex operation.Integration_op.token;
                ]
                "Resume the same confirmed integration without another \
                 acceptance.";
              action ~root
                [
                  "operation";
                  "recover";
                  Core.Operation_id.to_hex operation.Integration_op.token;
                  "--preview";
                ]
                "Inspect private recovery choices without publishing \
                 acceptance.";
              action ~root
                [
                  "operation";
                  "recover";
                  Core.Operation_id.to_hex operation.Integration_op.token;
                  "--replan";
                  "--preview";
                ]
                "Prepare a fresh recovery while retaining prior observations.";
            ]),
        Option.map
          (fun operation ->
            Core.Operation_id.to_hex operation.Integration_op.token)
          pending )

let[@warning "-4"] require_integration ~root = function
  | Ok value -> value
  | Error error -> (
      let message = Native_integrate.error_to_string error in
      match error with
      | Native_integrate.Pending_operation _ ->
          fail_with_status 8 "integration-incomplete" message
      | Native_integrate.Pending_restore _ ->
          set_local_failure_context ~root;
          fail_with_status 8 "recovery-pending" message
      | Native_integrate.Metadata _ -> (
          match Service.inspect_saved_state ~root with
          | Ok (Store.Metadata_only metadata) ->
              render_metadata_status ~root metadata
          | Error error -> fail_local error
          | Ok (Store.Verified loaded) when Service.Clone_state.pending loaded
            ->
              let valid = Result.is_ok (Yeokcham_encoding.text root) in
              local_failure_context :=
                Some
                  (fun () ->
                    ( `Assoc [ ("clone_state", `String "incomplete") ],
                      [
                        Cli_data.
                          {
                            arguments =
                              [
                                "yeokcham";
                                "clone";
                                "--resume";
                                (if valid then root else String.escaped root);
                              ];
                            explanation =
                              "Resume the same verified clone; do not capture \
                               a partial workspace.";
                            applicable = valid;
                            confirmation_required = false;
                          };
                      ],
                      None ));
              fail_with_status 8 "clone-incomplete" message
          | Ok (Store.Verified _) ->
              fail_with_status 5 "integration-unavailable" message)
      | Native_integrate.Capture_error error ->
          fail_local (Service.Snapshot_error error)
      | Native_integrate.Plan_error (Integration.Invalid _) ->
          fail_with_status 2 "invalid-integration" message
      | Native_integrate.Plan_error (Integration.Choice _ | Integration.Stale _)
        ->
          fail_with_status 3 "integration-choice-required" message
      | Native_integrate.Plan_error (Integration.Policy _) ->
          fail_with_status 7 "integration-policy-blocked" message
      | Native_integrate.Plan_error
          ( Integration.Integrity _
          | Integration.Content (Yeokcham_v1_composition.Integrity _) ) ->
          fail_with_status 6 "integration-integrity-failure" message
      | Native_integrate.Application_error (Service.Safe_apply.Conflict _) ->
          fail_with_status 8 "integration-paused" message
      | Native_integrate.Application_error (Service.Safe_apply.Invalid_plan _)
        ->
          fail_with_status 6 "integration-physical-integrity" message
      | _ -> fail_with_status 5 "integration-unavailable" message)

let integration_differences ~root plan =
  let workspace = (Integration.request plan).Core.workspace in
  match Integration.readiness plan with
  | Integration.Ready outputs ->
      ( Service.compare_immutable_snapshots ~root
          ~before:workspace.Core.basis_snapshot
          ~after:outputs.Core.accepted_snapshot
        |> require_local,
        Service.compare_immutable_snapshots ~root
          ~before:workspace.Core.observed_snapshot
          ~after:outputs.Core.workspace_snapshot
        |> require_local )
  | Integration.Conflicted _ | Integration.Decision _ -> ([], [])

let integration_plan_json ?(historical = false) ~root plan =
  let accepted_changes, workspace_changes =
    if historical then ([], []) else integration_differences ~root plan
  in
  let request = Integration.request plan in
  let workspace = request.Core.workspace in
  let ids values =
    `List (List.map (fun id -> `String (Core.Record_id.to_hex id)) values)
  in
  let readiness, conflicts, outputs =
    match Integration.readiness plan with
    | Integration.Ready result ->
        ( "ready",
          [],
          [
            ( "accepted_snapshot",
              `String (Core.Object_id.to_hex result.Core.accepted_snapshot) );
            ( "workspace_snapshot",
              `String (Core.Object_id.to_hex result.Core.workspace_snapshot) );
          ] )
    | Integration.Decision reason ->
        ("decision", [], [ ("decision", `String reason) ])
    | Integration.Conflicted conflicts ->
        ( "conflicted",
          List.map
            (fun conflict ->
              `Assoc
                [
                  ("path", json_byte_path (String.concat "/" conflict.Core.path));
                  ("versions", ids conflict.Core.versions);
                  ("private_workspace", `Bool conflict.Core.private_workspace);
                ])
            conflicts,
          [] )
  in
  `Assoc
    ([
       ("plan_id", `String (Core.Plan_id.to_hex (Integration.id plan)));
       ("readiness", `String readiness);
       ( "comparison_state",
         `String (if historical then "not_inspected" else "verified") );
       ("no_op", `Bool (Integration.no_op plan));
       ("branch_id", `String (Core.Branch_id.to_hex request.Core.branch));
       ("event_heads", ids (Integration.event_heads plan));
       ("accepted_heads", ids request.Core.accepted_heads);
       ("exact_revisions", ids request.Core.selected_revisions);
       ("resolution_ids", ids request.Core.resolution_ids);
       ( "workspace_decisions",
         `List
           (List.map
              (fun value ->
                `Assoc
                  [
                    ( "path",
                      json_byte_path
                        (String.concat "/" value.Integration.decision_path) );
                    ( "replacement_snapshot",
                      `String
                        (Core.Object_id.to_hex
                           value.Integration.decision_replacement) );
                  ])
              (Integration.workspace_decisions plan)) );
       ("composition_profile", `String request.Core.composition_profile);
       ("cursor", json_history_identity workspace.Core.cursor);
       ( "working_basis",
         `String (Core.Record_id.to_hex workspace.Core.working_basis) );
       ( "observed_snapshot",
         `String (Core.Object_id.to_hex workspace.Core.observed_snapshot) );
       ("conflicts", `List conflicts);
       ( "accepted_changes",
         if historical then `Null
         else `List (List.map json_display_difference accepted_changes) );
       ( "workspace_changes",
         if historical then `Null
         else `List (List.map json_display_difference workspace_changes) );
     ]
    @ outputs)

let render_integration_plan ?(historical = false) ~root plan =
  let request = Integration.request plan in
  Printf.printf "integration plan %s\n"
    (Core.Plan_id.to_hex (Integration.id plan));
  Printf.printf "branch %s; %d exact revision(s)\n"
    (Core.Branch_id.to_hex request.Core.branch)
    (List.length request.Core.selected_revisions);
  match Integration.readiness plan with
  | Integration.Ready outputs ->
      Printf.printf "accepted result %s\nprivate workspace result %s\n"
        (Core.Object_id.to_hex outputs.Core.accepted_snapshot)
        (Core.Object_id.to_hex outputs.Core.workspace_snapshot);
      if Integration.no_op plan then
        print_endline
          "selected work is already accepted; no history change is needed";
      let accepted, workspace =
        if historical then ([], []) else integration_differences ~root plan
      in
      if historical then
        print_endline "recorded plan; contents were not inspected";
      print_endline "accepted changes:";
      List.iter render_display_difference accepted;
      print_endline "working-file changes:";
      List.iter render_display_difference workspace
  | Integration.Decision detail ->
      Printf.printf "decision required: %s\n" (Output.display_value detail)
  | Integration.Conflicted conflicts ->
      List.iter
        (fun conflict ->
          Printf.printf "conflict %s (%s)\n"
            (Output.display_value (String.concat "/" conflict.Core.path))
            (if conflict.Core.private_workspace then "private workspace"
             else "shared result"))
        conflicts

let integration_selection root ~all selectors =
  let repository, loaded, local = integration_repository root in
  let pool = Local.pool local in
  let selected = Local.selected local in
  let branch =
    Local.branches local
    |> List.find (fun row ->
        Core.Branch_id.equal row.Core.branch_id selected.Local.branch)
  in
  let represented =
    Yeokcham_v1_composition.Graph.represented pool branch.Core.accepted_heads
    |> require_ok Yeokcham_v1_composition.Graph.error_to_string
  in
  let changes =
    Core.records pool
    |> List.filter_map (fun (_, body) ->
        match body.Core.payload with
        | Core.Shared_revision value -> Some value.Core.change
        | Core.Accepted_version _ | Core.Branch_event _
        | Core.Resolution_revision _ ->
            None)
    |> List.sort_uniq Core.Change_id.compare
  in
  let eligible =
    List.filter_map
      (fun change ->
        let heads = Core.change_heads pool change in
        if
          List.for_all
            (fun id -> List.exists (Core.Record_id.equal id) represented)
            heads
        then None
        else Some (change, heads))
      changes
  in
  let resolve text =
    if String.length text = 32 then
      let change =
        Core.Change_id.of_hex text |> require_ok Core.error_to_string
      in
      match Core.change_heads pool change with
      | [ id ] -> id
      | [] ->
          fail_with "unknown-change"
            "Inspect status for known shared change identities."
      | _ ->
          fail_with_status 3 "concurrent-change-versions"
            "This change has incomparable revisions; resolve its exact \
             variants first."
    else
      let id = Core.Record_id.of_hex text |> require_ok Core.error_to_string in
      match Core.find pool id with
      | Some { Core.payload = Core.Shared_revision _; _ } -> id
      | None
      | Some
          {
            Core.payload =
              ( Core.Accepted_version _ | Core.Branch_event _
              | Core.Resolution_revision _ );
            _;
          } ->
          fail_with "invalid-shared-revision"
            "Integration selections must name retained shared revisions."
  in
  if selectors <> [] then
    List.map resolve selectors |> List.sort_uniq Core.Record_id.compare
  else if all || List.length eligible <= 1 then
    List.map
      (fun (change, _) -> resolve (Core.Change_id.to_hex change))
      eligible
    |> List.sort Core.Record_id.compare
  else
    let received_titles =
      match
        Service.Core_receive.public_titles_for_loaded
          ~store:(Yeokcham_v1_store.underlying_store repository)
          ~loaded
      with
      | Ok titles -> titles
      | Error error ->
          record_warning
            ("Shared display labels unavailable; use exact identities: "
            ^ Service.Core_receive.error_to_string error);
          []
    in
    let title change heads =
      match
        List.find_opt
          (fun publication ->
            List.exists (Core.Record_id.equal publication.Local.revision) heads)
          (Local.publications local)
      with
      | Some publication -> publication.Local.title
      | None -> (
          let titles =
            received_titles
            |> List.filter_map (fun label ->
                if
                  List.exists
                    (Core.Record_id.equal label.Service.Core_receive.revision)
                    heads
                then Some label.Service.Core_receive.title
                else None)
            |> List.sort_uniq String.compare
          in
          match titles with
          | [ title ] -> title
          | [] | _ :: _ ->
              "Shared change " ^ String.sub (Core.Change_id.to_hex change) 0 12)
    in
    if requested_format () = Text_format then
      List.iter
        (fun (change, heads) ->
          Printf.printf "eligible %s %s\n"
            (Core.Change_id.to_hex change)
            (Output.display_value (title change heads)))
        eligible;
    selection_choice
      ~data:
        (`Assoc
           [
             ( "choices",
               `List
                 (List.map
                    (fun (change, heads) ->
                      `Assoc
                        [
                          ("change_id", `String (Core.Change_id.to_hex change));
                          ("title", `String (title change heads));
                        ])
                    eligible) );
             ( "eligible_changes",
               `List
                 (List.map
                    (fun (change, _) -> `String (Core.Change_id.to_hex change))
                    eligible) );
           ])
      ~next_actions:
        [
          action ~root
            [ "integrate"; "--all"; "--preview" ]
            "Preview every eligible change before choosing acceptance.";
        ]
      ~message:
        "Several shared changes are eligible. Name changes explicitly or \
         preview --all."
      ()

let run_integrate arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  let root = flags.selection_root in
  local_failure_context := Some (native_failure_context root);
  let rec parse all heads names = function
    | [] -> (all, List.rev heads, List.rev names)
    | "--all" :: rest when not all -> parse true heads names rest
    | "--reconcile" :: id :: rest ->
        let id = Core.Record_id.of_hex id |> require_ok Core.error_to_string in
        parse all (id :: heads) names rest
    | value :: _ when String.starts_with ~prefix:"-" value -> usage ()
    | value :: rest -> parse all heads (value :: names) rest
  in
  let all, heads, names = parse false [] [] remaining in
  if
    (all && names <> [])
    || (flags.selection_plan <> None && (all || heads <> [] || names <> []))
  then
    fail_with "invalid-integration-selection"
      "Use --plan by itself, or select changes with optional --all/--reconcile.";
  let plan =
    match flags.selection_plan with
    | None ->
        Native_integrate.prepare ~root
          ~selected_revisions:(integration_selection root ~all names)
          ~reconcile_heads:(if heads = [] then None else Some heads)
        |> require_integration ~root
    | Some text -> (
        let id = Core.Plan_id.of_hex text |> require_ok Core.error_to_string in
        let repository, loaded, local = integration_repository root in
        let store = Yeokcham_v1_store.underlying_store repository in
        match Local.find_operation local ~plan:id with
        | None ->
            Integration.load ~store ~loaded id
            |> Result.map_error (fun e -> Native_integrate.Plan_error e)
            |> require_integration ~root
        | Some operation ->
            let envelope =
              Yeokcham_store.get
                ~max_bytes:(8 * 1024 * 1024)
                store operation.Integration_op.plan_object
              |> require_ok Yeokcham_store.error_to_string
            in
            Integration.decode ~store ~loaded
              (Yeokcham_envelope.encode envelope)
            |> Result.map_error (fun e -> Native_integrate.Plan_error e)
            |> require_integration ~root)
  in
  let plan_id = Core.Plan_id.to_hex (Integration.id plan) in
  let actions =
    [
      action ~confirmation_required:true ~root
        [ "integrate"; "--plan"; plan_id; "--yes" ]
        "Apply this exact plan after revalidation.";
      action ~root [ "status" ]
        "Inspect capture, accepted heads and pending transfer.";
    ]
  in
  let _, _, current_local = integration_repository root in
  let recorded_operation =
    Local.find_operation current_local ~plan:(Integration.id plan)
  in
  let repeated =
    Option.fold ~none:false
      ~some:(fun operation ->
        operation.Integration_op.phase = Integration_op.Completed)
      recorded_operation
  in
  let historical = Option.is_some recorded_operation in
  let data = integration_plan_json ~historical ~root plan in
  let ready =
    match Integration.readiness plan with
    | Integration.Ready _ -> true
    | Integration.Conflicted _ | Integration.Decision _ -> false
  in
  if (not ready) && not flags.selection_preview then (
    if requested_format () = Json_format then
      Cli_data.domain_failure ~command:(command_name ()) ~plan_id
        ~outcome:`Conflict
        ~error:
          Cli_data.
            {
              code = "integration-conflicts";
              message = "Resolve or defer the named variants before acceptance.";
            }
        ~data ~warnings:[]
        ~next_actions:
          [
            action ~root
              [ "integrate"; "--plan"; plan_id; "--preview" ]
              "Inspect this immutable proposal without changing files.";
          ]
        ()
      |> Cli_data.encode |> print_json
    else render_integration_plan ~historical ~root plan;
    exit 4);
  let cancelled =
    (not flags.selection_yes)
    && (not flags.selection_preview)
    && (not (Integration.no_op plan))
    && not
         (confirm_local_selection ~plan_id ~data ~next_actions:actions
            ~render:(fun () -> render_integration_plan ~historical ~root plan)
            ())
  in
  let result =
    if flags.selection_preview || cancelled then None
    else
      let _, _, local = integration_repository root in
      let request = Integration.request plan in
      let represented =
        Yeokcham_v1_composition.Graph.represented (Local.pool local)
          request.Core.accepted_heads
        |> require_ok Yeokcham_v1_composition.Graph.error_to_string
      in
      let needs_signer =
        Local.find_operation local ~plan:(Integration.id plan) = None
        && (not (Integration.no_op plan))
        && not
             (List.length (Integration.event_heads plan) = 1
             && List.length request.Core.accepted_heads = 1
             && List.for_all
                  (fun id -> List.exists (Core.Record_id.equal id) represented)
                  request.Core.selected_revisions)
      in
      let signing_capability =
        if not needs_signer then None
        else
          let identity = Service.identity ~root |> require_local in
          match
            V1_signer.load ~root (Trust.device_id identity.Service.device)
          with
          | Ok capability -> Some capability
          | Error e ->
              fail_with_status 5 "signing-provider-unavailable"
                (V1_signer.error_to_string e)
      in
      Some
        (Native_integrate.apply ~root ~plan:(Integration.id plan)
           ~signing_capability
        |> require_integration ~root)
  in
  let code, message =
    if cancelled then
      ( "integration-cancelled",
        "Integration cancelled; files and history were preserved." )
    else if flags.selection_preview then
      ( "integration-preview",
        "Exact shared/private proposal prepared; acceptance and files are \
         unchanged." )
    else
      match result with
      | Some outcome when outcome.Native_integrate.no_op ->
          ("integration-unchanged", "Selected work is already accepted.")
      | Some outcome when outcome.Native_integrate.recovered ->
          ( "integration-recovered",
            "This plan was closed through private recovery; prepare a fresh \
             integration to accept shared work." )
      | Some _ when repeated ->
          ( "integration-repeated",
            "The recorded integration was reused; no acceptance or navigation \
             was added." )
      | Some outcome when outcome.Native_integrate.resumed ->
          ( "integration-resumed",
            "The same confirmed operation completed; outbound transfer may \
             remain pending." )
      | Some _ ->
          ( "integration-completed",
            "Integration committed locally; outbound transfer may remain \
             pending." )
      | None -> assert false
  in
  let operation =
    Option.bind result (fun result -> result.Native_integrate.operation)
  in
  let data =
    match data with
    | `Assoc fields ->
        `Assoc
          (fields
          @ [
              ("preview", `Bool flags.selection_preview);
              ("cancelled", `Bool cancelled);
              ("repeated", `Bool repeated);
              ( "recorded_operation",
                json_optional json_integration_operation recorded_operation );
              ("operation", json_optional json_integration_operation operation);
            ])
    | _ -> assert false
  in
  if requested_format () = Json_format then
    domain_json ~plan_id
      ?operation_id:
        (Option.map
           (fun operation ->
             Core.Operation_id.to_hex operation.Integration_op.token)
           operation)
      ~outcome:
        (if
           cancelled
           || (repeated && not flags.selection_preview)
           || Integration.no_op plan
         then `Unchanged
         else if not ready then `Incomplete
         else `Completed)
      ~code ~message ~data ~next_actions:actions ()
  else (
    render_integration_plan ~historical ~root plan;
    print_endline message;
    Option.iter
      (fun operation ->
        Printf.printf "operation %s; %s\n"
          (Core.Operation_id.to_hex operation.Integration_op.token)
          (phase_name operation.Integration_op.phase))
      operation);
  match result with
  | Some result ->
      (not result.Native_integrate.no_op)
      && (not result.Native_integrate.resumed)
      && not result.Native_integrate.recovered
  | None -> false

module Native_conflicts = Service.Conflicts
module Conflict_snapshot = Yeokcham_snapshot

let json_conflict_version (version : Native_conflicts.version) =
  let entry =
    match version.Native_conflicts.entry with
    | None -> `Assoc [ ("kind", `String "absent") ]
    | Some Yeokcham_v1_composition.Directory ->
        `Assoc [ ("kind", `String "directory") ]
    | Some (Yeokcham_v1_composition.File { mode; content }) ->
        `Assoc
          [
            ( "kind",
              `String
                (match mode with
                | Conflict_snapshot.Regular -> "regular"
                | Conflict_snapshot.Executable -> "executable"
                | Conflict_snapshot.Symlink -> "symlink") );
            ( "content_id",
              `String
                (Yeokcham_store.Stored_object_id.to_hex
                   (Conflict_snapshot.Content.stored_object_id content)) );
          ]
  in
  `Assoc
    [
      ("version_id", `String version.Native_conflicts.version_id);
      ("name", `String version.Native_conflicts.name);
      ( "snapshot",
        `String (Core.Object_id.to_hex version.Native_conflicts.snapshot) );
      ("entry", entry);
      ( "preview_escaped",
        json_optional
          (fun s -> `String s)
          version.Native_conflicts.preview_escaped );
      ("preview_truncated", `Bool version.Native_conflicts.preview_truncated);
    ]

let json_native_conflict (conflict : Native_conflicts.conflict) =
  `Assoc
    [
      ( "conflict_id",
        `String (Core.Digest.to_hex conflict.Native_conflicts.conflict_id) );
      ( "plan_id",
        `String (Core.Plan_id.to_hex conflict.Native_conflicts.source_plan) );
      ("path", json_byte_path (String.concat "/" conflict.Native_conflicts.path));
      ("private_workspace", `Bool conflict.Native_conflicts.private_workspace);
      ( "versions",
        `List
          (List.map json_conflict_version conflict.Native_conflicts.versions) );
    ]

let run_conflicts arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  if remaining <> [] || flags.selection_preview || flags.selection_yes then
    usage ();
  let root = flags.selection_root in
  local_failure_context := Some (native_failure_context root);
  let plan =
    Option.map
      (fun text -> Core.Plan_id.of_hex text |> require_ok Core.error_to_string)
      flags.selection_plan
  in
  let inspected =
    Native_conflicts.inspect ~root ~plan |> require_integration ~root
  in
  let actions =
    List.concat_map
      (fun conflict ->
        let conflict_id =
          Core.Digest.to_hex conflict.Native_conflicts.conflict_id
        in
        [
          action ~root
            [ "resolve"; conflict_id; "--defer" ]
            "Keep this conflict and every candidate without accepting work.";
        ])
      inspected.Native_conflicts.conflicts
    @ List.filter_map
        (fun plan ->
          match Integration.readiness plan with
          | Integration.Ready _ ->
              Some
                (action ~root
                   [
                     "integrate";
                     "--plan";
                     Core.Plan_id.to_hex (Integration.id plan);
                     "--preview";
                   ]
                   "Inspect this exact shared/private result before acceptance.")
          | Integration.Conflicted _ | Integration.Decision _ -> None)
        inspected.Native_conflicts.plans
  in
  if requested_format () = Json_format then
    domain_json ~outcome:`Completed ~code:"conflicts-inspected"
      ~message:
        "Exact current plans and named versions inspected; acceptance and \
         files are unchanged."
      ~data:
        (`Assoc
           [
             ( "plans",
               `List
                 (List.map
                    (fun plan -> integration_plan_json ~root plan)
                    inspected.Native_conflicts.plans) );
             ( "conflicts",
               `List
                 (List.map json_native_conflict
                    inspected.Native_conflicts.conflicts) );
           ])
      ~next_actions:actions ()
  else (
    List.iter
      (fun plan -> render_integration_plan ~root plan)
      inspected.Native_conflicts.plans;
    List.iter
      (fun conflict ->
        Printf.printf "conflict %s\nplan %s\npath %s (%s)\n"
          (Core.Digest.to_hex conflict.Native_conflicts.conflict_id)
          (Core.Plan_id.to_hex conflict.Native_conflicts.source_plan)
          (Output.display_value
             (String.concat "/" conflict.Native_conflicts.path))
          (if conflict.Native_conflicts.private_workspace then
             "private workspace"
           else "shared result");
        List.iter
          (fun version ->
            Printf.printf "  version %s; snapshot %s\n"
              (Output.display_value version.Native_conflicts.version_id)
              (Core.Object_id.to_hex version.Native_conflicts.snapshot);
            Option.iter
              (fun text -> Printf.printf "    bytes %s\n" text)
              version.Native_conflicts.preview_escaped;
            if version.Native_conflicts.preview_truncated then
              print_endline
                "    contents exceed the 8192-byte display bound; exact \
                 content identity is retained")
          conflict.Native_conflicts.versions)
      inspected.Native_conflicts.conflicts)

let run_native_resolve arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  if flags.selection_preview || flags.selection_yes then usage ();
  let root = flags.selection_root in
  local_failure_context := Some (native_failure_context root);
  let rec parse choice names = function
    | [] -> (choice, List.rev names)
    | "--use" :: value :: rest when choice = None ->
        parse (Some (Native_conflicts.Use value)) names rest
    | "--file" :: value :: rest when choice = None ->
        parse (Some (Native_conflicts.File value)) names rest
    | "--defer" :: rest when choice = None ->
        parse (Some Native_conflicts.Defer) names rest
    | value :: _ when String.starts_with ~prefix:"-" value -> usage ()
    | value :: rest -> parse choice (value :: names) rest
  in
  let choice, names = parse None [] remaining in
  let choice, identity =
    match (choice, names) with
    | Some choice, [ identity ] -> (choice, identity)
    | _ -> usage ()
  in
  let conflict =
    Core.Digest.of_hex identity |> require_ok Core.error_to_string
  in
  let plan =
    Option.map
      (fun text -> Core.Plan_id.of_hex text |> require_ok Core.error_to_string)
      flags.selection_plan
  in
  let signer () =
    match Service.identity ~root with
    | Error e -> Error (Service.error_to_string e)
    | Ok identity ->
        V1_signer.load ~root (Trust.device_id identity.Service.device)
        |> Result.map_error V1_signer.error_to_string
  in
  let result =
    Native_conflicts.resolve ~root ~plan ~conflict ~choice ~signer
    |> require_integration ~root
  in
  let plan_id =
    Core.Plan_id.to_hex (Integration.id result.Native_conflicts.prepared)
  in
  let actions =
    if not result.Native_conflicts.retained then
      [
        action ~root
          ([
             "resolve";
             identity;
             "--plan";
             Core.Plan_id.to_hex result.Native_conflicts.source;
           ]
          @
          match (result.Native_conflicts.public_resolution, choice) with
          | Some id, _ -> [ "--use"; "resolution:" ^ Core.Record_id.to_hex id ]
          | None, Native_conflicts.Use value -> [ "--use"; value ]
          | None, Native_conflicts.File value -> [ "--file"; value ]
          | None, Native_conflicts.Defer -> [ "--defer" ])
          "The scoped proposal was recorded; retry the same explicit choice to \
           retain its integration plan.";
      ]
    else
      [
        action ~root
          [ "conflicts"; "--plan"; plan_id ]
          "Inspect remaining conflicts and exact named versions.";
        action ~root
          [ "integrate"; "--plan"; plan_id; "--preview" ]
          "Inspect this exact plan before explicit acceptance.";
      ]
  in
  let message =
    if result.Native_conflicts.deferred then
      "Conflict deferred; files, history and shared state are unchanged."
    else if not result.Native_conflicts.retained then
      "Scoped resolution proposal recorded, but its integration plan could not \
       be retained. Retry the exact choice; no acceptance or file replacement \
       occurred."
    else if result.Native_conflicts.public_resolution = None then
      "Private workspace choice retained in a fresh plan; shared contents, \
       files and history are unchanged."
    else
      "Scoped shared resolution proposal recorded and a fresh plan retained; \
       files and accepted history are unchanged."
  in
  let data =
    `Assoc
      [
        ( "source_plan_id",
          `String (Core.Plan_id.to_hex result.Native_conflicts.source) );
        ("conflict_id", `String identity);
        ("deferred", `Bool result.Native_conflicts.deferred);
        ( "public_resolution",
          json_optional
            (fun id -> `String (Core.Record_id.to_hex id))
            result.Native_conflicts.public_resolution );
        ("retained", `Bool result.Native_conflicts.retained);
        ( "retention_error",
          json_optional
            (fun value -> `String value)
            result.Native_conflicts.retention_error );
        ( "plan",
          integration_plan_json
            ~historical:(not result.Native_conflicts.retained)
            ~root result.Native_conflicts.prepared );
      ]
  in
  if requested_format () = Json_format then
    if not result.Native_conflicts.retained then
      Cli_data.domain_failure ~command:(command_name ()) ~plan_id
        ~outcome:`Interrupted
        ~error:Cli_data.{ code = "resolution-plan-incomplete"; message }
        ~data
        ~warnings:(List.rev !public_warnings)
        ~next_actions:actions ()
      |> Cli_data.encode |> print_json
    else
      domain_json ~plan_id
        ~outcome:
          (if result.Native_conflicts.deferred then `Unchanged else `Completed)
        ~code:
          (if result.Native_conflicts.deferred then "conflict-deferred"
           else "resolution-prepared")
        ~message ~data ~next_actions:actions ()
  else (
    print_endline message;
    Option.iter
      (fun id ->
        Printf.printf "shared resolution %s\n" (Core.Record_id.to_hex id))
      result.Native_conflicts.public_resolution;
    render_integration_plan
      ~historical:(not result.Native_conflicts.retained)
      ~root result.Native_conflicts.prepared);
  if not result.Native_conflicts.retained then (
    flush_domain_output ();
    exit 8)

let run_native_operation ~resume arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  let root = flags.selection_root in
  if
    flags.selection_preview || flags.selection_yes
    || flags.selection_plan <> None
  then usage ();
  let text = match remaining with [ text ] -> text | _ -> usage () in
  let token =
    Core.Operation_id.of_hex text |> require_ok Core.error_to_string
  in
  local_failure_context := Some (native_failure_context root);
  let _, _, local = integration_repository root in
  let operation =
    match
      List.find_opt
        (fun operation ->
          Core.Operation_id.equal token operation.Integration_op.token)
        (Local.operations local)
    with
    | Some operation -> operation
    | None ->
        fail_with "unknown-integration-operation"
          "Inspect status for durable integration operation IDs."
  in
  let was_completed =
    operation.Integration_op.phase = Integration_op.Completed
  in
  let operation =
    if resume then
      Native_integrate.resume ~root ~operation:token
      |> require_integration ~root
      |> fun outcome -> Option.get outcome.Native_integrate.operation
    else operation
  in
  let actions =
    if Integration_op.pending operation then
      [
        action ~root
          [ "operation"; "resume"; text ]
          "Resume this exact confirmed operation; external edits remain \
           protected.";
      ]
    else
      [
        action ~root [ "status" ] "Inspect accepted and private working state.";
      ]
  in
  if requested_format () = Json_format then
    domain_json ~operation_id:text
      ~plan_id:(Core.Plan_id.to_hex operation.Integration_op.plan)
      ~outcome:
        (if resume && was_completed then `Unchanged
         else if Integration_op.pending operation then `Incomplete
         else `Completed)
      ~code:(if resume then "operation-resumed" else "operation-inspected")
      ~message:
        (if resume then "The same integration operation was resumed."
         else "Durable integration facts inspected without file changes.")
      ~data:(json_integration_operation operation)
      ~next_actions:actions ()
  else (
    Printf.printf
      "operation %s\nplan %s\nphase %s\naccepted %s\nprivate target %s\n" text
      (Core.Plan_id.to_hex operation.Integration_op.plan)
      (phase_name operation.Integration_op.phase)
      (Core.Record_id.to_hex operation.Integration_op.accepted)
      (Core.Object_id.to_hex operation.Integration_op.target);
    Printf.printf "acceptance %s\n"
      (if Integration_op.committed operation then "committed"
       else "not committed by this operation");
    Option.iter
      (fun recovery ->
        Printf.printf "recovery %s mode:%s retained:%b\n"
          (recovery_progress_name recovery.Integration_op.progress)
          (recovery_mode_name recovery.Integration_op.mode)
          recovery.Integration_op.retained;
        Option.iter
          (fun reason ->
            Printf.printf "recovery paused: %s\n" (Output.display_value reason))
          recovery.Integration_op.pause_reason)
      operation.Integration_op.recovery;
    match operation.Integration_op.phase with
    | Integration_op.Paused (_, reason) ->
        Printf.printf "paused: %s\n" (Output.display_value reason)
    | Integration_op.Prepared | Integration_op.Applying
    | Integration_op.Materialized | Integration_op.Committed
    | Integration_op.Completed ->
        ())

let run_operation_recover ~forget arguments =
  let flags, remaining = parse_local_selection_flags arguments in
  let root = flags.selection_root in
  local_failure_context := Some (native_failure_context root);
  let rec parse mode replan names = function
    | [] -> (mode, replan, List.rev names)
    | "--keep-current" :: rest when mode = None ->
        parse (Some Integration_op.Keep_current) replan names rest
    | "--replan" :: rest when not replan -> parse mode true names rest
    | value :: _ when String.starts_with ~prefix:"-" value -> usage ()
    | value :: rest -> parse mode replan (value :: names) rest
  in
  let mode, replan, names = parse None false [] remaining in
  let token_text = match names with [ text ] -> text | _ -> usage () in
  let token =
    Core.Operation_id.of_hex token_text |> require_ok Core.error_to_string
  in
  let expected =
    Option.map
      (fun text -> Core.Digest.of_hex text |> require_ok Core.error_to_string)
      flags.selection_plan
  in
  if forget && (mode <> None || replan) then usage ();
  let _, _, local = integration_repository root in
  let operation =
    match
      List.find_opt
        (fun operation ->
          Core.Operation_id.equal token operation.Integration_op.token)
        (Local.operations local)
    with
    | Some operation -> operation
    | None ->
        fail_with "unknown-integration-operation"
          "Inspect status for a durable integration operation ID."
  in
  let render_changes before after =
    match Service.compare_immutable_snapshots ~root ~before ~after with
    | Ok differences -> List.iter render_display_difference differences
    | Error error ->
        Printf.printf "contents unavailable: %s\n"
          (Output.display_value (Service.error_to_string error))
  in
  if forget then (
    if not (Integration_op.recovered operation) then
      fail_with_status 3 "recovery-not-completed"
        "Only a completed private recovery can release its extra roots.";
    let recovery = Option.get operation.Integration_op.recovery in
    Option.iter
      (fun expected ->
        if not (Core.Digest.equal expected recovery.Integration_op.plan_id) then
          fail_with_status 3 "stale-recovery-plan"
            "The recovery plan does not match this operation.")
      expected;
    let data = json_integration_operation operation in
    let actions =
      [
        action ~confirmation_required:true ~root
          [ "operation"; "forget"; token_text; "--yes" ]
          "Release extra recovery roots; ordinary history and live files \
           remain.";
      ]
    in
    let render () =
      Printf.printf
        "release recovery roots for %s; live files and history stay in place\n"
        token_text
    in
    let cancelled =
      (not flags.selection_preview)
      && (not flags.selection_yes)
      && not (confirm_local_selection ~data ~next_actions:actions ~render ())
    in
    let result =
      if flags.selection_preview || cancelled then operation
      else
        Native_integrate.forget_recovery_roots ~root ~operation:token
        |> require_integration ~root
    in
    if requested_format () = Json_format then
      domain_json ~operation_id:token_text
        ~outcome:
          (if flags.selection_preview then `Completed
           else if cancelled || result = operation then `Unchanged
           else `Completed)
        ~code:
          (if cancelled then "recovery-release-cancelled"
           else if flags.selection_preview then "recovery-release-preview"
           else "recovery-roots-released")
        ~message:
          "Recovery retention inspected or explicitly released; files and \
           history were not rewritten."
        ~data:(json_integration_operation result)
        ~next_actions:actions ()
    else (
      render ();
      if cancelled then print_endline "Recovery-root release cancelled."
      else if not flags.selection_preview then
        print_endline "Extra recovery roots released."))
  else
    let preview =
      Native_integrate.recover ~root ~operation:token ~dry_run:true ~mode
        ~replan ~expected_plan:expected
      |> require_integration ~root
    in
    let plan_id = Core.Digest.to_hex preview.Native_integrate.recovery_plan in
    let target = preview.Native_integrate.recovery_target in
    let effective_mode =
      match
        ( preview.Native_integrate.recovery_operation.Integration_op.recovery,
          replan,
          mode )
      with
      | Some recovery, false, _ -> recovery.Integration_op.mode
      | _, _, Some mode -> mode
      | _, _, None -> Integration_op.Restore_safety
    in
    let base =
      [ "operation"; "recover"; token_text ]
      @ (if effective_mode = Integration_op.Keep_current then
           [ "--keep-current" ]
         else [])
      @ if replan then [ "--replan" ] else []
    in
    let actions =
      [
        action ~confirmation_required:true ~root
          (base @ [ "--plan"; plan_id; "--yes" ])
          "Apply this exact private recovery; no shared acceptance is \
           published.";
        action ~root
          [ "operation"; "show"; token_text ]
          "Inspect current operation and retained alternatives.";
      ]
    in
    let comparison =
      Service.compare_immutable_snapshots ~root
        ~before:preview.Native_integrate.recovery_observed ~after:target
    in
    let data =
      `Assoc
        [
          ("recovery_plan_id", `String plan_id);
          ( "integration_plan_id",
            `String (Core.Plan_id.to_hex operation.Integration_op.plan) );
          ("mode", `String (recovery_mode_name effective_mode));
          ( "observed_snapshot",
            `String
              (Core.Object_id.to_hex preview.Native_integrate.recovery_observed)
          );
          ("target_snapshot", `String (Core.Object_id.to_hex target));
          ( "changes",
            match comparison with
            | Ok values -> `List (List.map json_display_difference values)
            | Error _ -> `Null );
          ( "comparison_state",
            `String
              (if Result.is_ok comparison then "verified" else "unavailable") );
          ( "operation",
            json_integration_operation
              preview.Native_integrate.recovery_operation );
        ]
    in
    let render () =
      Printf.printf
        "private recovery plan %s\n\
         mode %s\n\
         current observation %s\n\
         chosen result %s\n"
        plan_id
        (recovery_mode_name effective_mode)
        (Core.Object_id.to_hex preview.Native_integrate.recovery_observed)
        (Core.Object_id.to_hex target);
      render_changes preview.Native_integrate.recovery_observed target;
      print_endline
        (match
           preview.Native_integrate.recovery_operation.Integration_op.recovery
         with
        | Some recovery when not recovery.Integration_op.retained ->
            "Extra recovery retention was released; historical contents may be \
             unavailable."
        | Some _ when not replan ->
            "Recovery observations remain retained; shared acceptance is \
             unchanged."
        | None | Some _ ->
            "Applying this plan retains current observations privately; shared \
             acceptance is unchanged.")
    in
    let closed =
      Integration_op.recovered preview.Native_integrate.recovery_operation
    in
    let cancelled =
      (not flags.selection_preview)
      && (not flags.selection_yes) && (not closed)
      && not
           (confirm_local_selection ~plan_id ~data ~next_actions:actions ~render
              ())
    in
    let result =
      if flags.selection_preview || cancelled then preview
      else
        Native_integrate.recover ~root ~operation:token ~dry_run:false ~mode
          ~replan ~expected_plan:(Some preview.Native_integrate.recovery_plan)
        |> require_integration ~root
    in
    let message =
      if cancelled then
        "Private recovery cancelled; files and history are unchanged."
      else if flags.selection_preview then
        "Private recovery preview; no files or history were changed."
      else "Private recovery completed; this operation published no acceptance."
    in
    if requested_format () = Json_format then
      domain_json ~operation_id:token_text ~plan_id
        ~outcome:(if cancelled || closed then `Unchanged else `Completed)
        ~code:
          (if cancelled then "recovery-cancelled"
           else if flags.selection_preview then "recovery-preview"
           else "operation-recovered")
        ~message
        ~data:
          (match data with
          | `Assoc fields ->
              `Assoc
                (List.filter (fun (key, _) -> key <> "operation") fields
                @ [
                    ( "operation",
                      json_integration_operation
                        result.Native_integrate.recovery_operation );
                  ])
          | _ -> assert false)
        ~next_actions:actions ()
    else (
      render ();
      print_endline message)

let run_withdraw arguments =
  let root, change = parse_withdraw arguments in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  Service.withdraw ~root ~change
  |> require_ok Service.error_to_string
  |> render_status

let run_deliver arguments =
  let root, id, draft, title = parse_deliver arguments in
  let id =
    parse_identifier "invalid delivery identifier" Model.Delivery_id.of_string
      id
  in
  let next_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  Service.deliver ~root ~id ~next_draft ~next_title:title
  |> require_ok Service.error_to_string
  |> render_status

let parse_pin arguments =
  let rec loop root checkpoint = function
    | [] -> (
        match checkpoint with
        | Some checkpoint ->
            (Option.value root ~default:default_root, checkpoint)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) checkpoint rest
    | "--checkpoint" :: value :: rest when Option.is_none checkpoint ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_compact arguments =
  let rec loop root keep dry_run explain = function
    | [] -> (Option.value root ~default:default_root, keep, dry_run, explain)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) keep dry_run explain rest
    | "--keep" :: value :: rest when Option.is_none keep -> (
        match int_of_string_opt value with
        | Some parsed when parsed >= 0 ->
            loop root (Some parsed) dry_run explain rest
        | Some _ | None -> usage ())
    | "--dry-run" :: rest when not dry_run -> loop root keep true explain rest
    | "--explain" :: rest when not explain -> loop root keep dry_run true rest
    | _ -> usage ()
  in
  loop None None false false arguments

let run_pin arguments =
  let root, checkpoint = parse_pin arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  Service.pin ~root ~checkpoint
  |> require_ok Service.error_to_string
  |> render_status

let run_unpin arguments =
  let root, checkpoint = parse_pin arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  Service.unpin ~root ~checkpoint
  |> require_ok Service.error_to_string
  |> render_status

let render_compact report explain =
  if explain then (
    List.iter
      (fun keep ->
        Printf.printf "keep %s %s\n"
          (Model.Snapshot_id.to_string keep.Model.snapshot)
          (keep.Model.reasons
          |> List.map Model.protection_reason_to_string
          |> String.concat ","))
      report.Service.kept;
    List.iter
      (fun snapshot ->
        Printf.printf "drop %s\n" (Model.Snapshot_id.to_string snapshot))
      report.Service.dropped;
    List.iter
      (fun operation -> Printf.printf "journal-prune %s\n" operation)
      report.Service.pruned_journals);
  Printf.printf "kept %d\n" (List.length report.Service.kept);
  Printf.printf "dropped %d\n" (List.length report.Service.dropped);
  render_status report.Service.status

let run_compact arguments =
  let root, keep, dry_run, explain = parse_compact arguments in
  let keep_recent = Option.value keep ~default:Model.default_keep_recent in
  Service.compact ~root ~keep_recent ~dry_run
  |> require_ok Service.error_to_string
  |> fun report ->
  render_compact report explain;
  not dry_run

let parse_remote_add arguments =
  let rec loop root values = function
    | [] -> (
        match List.rev values with
        | [ name; url ] -> (Option.value root ~default:default_root, name, url)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) values rest
    | value :: rest -> loop root (value :: values) rest
  in
  loop None [] arguments

let parse_remote_name arguments =
  let rec loop root name = function
    | [] -> (
        match name with
        | Some name -> (Option.value root ~default:default_root, name)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) name rest
    | value :: rest when Option.is_none name -> loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_remote_add arguments =
  let root, name, url = parse_remote_add arguments in
  Transport_config.add ~root ~name ~url
  |> require_ok Transport_config.error_to_string;
  Printf.printf "remote %s %s\n" name url

let run_remote_remove arguments =
  let root, name = parse_remote_name arguments in
  Transport_config.remove ~root ~name
  |> require_ok Transport_config.error_to_string;
  Printf.printf "remote removed %s\n" name

let parse_semantic_overlap = function
  | "same-symbol" -> Semantic_config.Same_symbol
  | "nearby-ranges" -> Semantic_config.Nearby_ranges
  | "references" -> Semantic_config.References
  | _ -> usage ()

let semantic_match_scope mode extensions globs =
  match mode with
  | "extensions" ->
      Semantic_config.Extensions (List.sort_uniq String.compare extensions)
  | "path-globs" ->
      Semantic_config.Path_globs (List.sort_uniq String.compare globs)
  | "all-files" ->
      if extensions <> [] || globs <> [] then usage ()
      else Semantic_config.All_files
  | _ -> usage ()

let parse_semantic_server_add arguments =
  let rec loop root name program arguments mode extensions globs overlap =
    function
    | [] -> (
        match (name, program) with
        | Some name, Some program ->
            ( Option.value root ~default:default_root,
              {
                Semantic_config.name;
                program;
                arguments = List.rev arguments;
                enabled = true;
                match_scope =
                  semantic_match_scope mode (List.rev extensions)
                    (List.rev globs);
                overlap_sensitivity = parse_semantic_overlap overlap;
              } )
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) name program arguments mode extensions globs overlap
          rest
    | "--program" :: value :: rest when Option.is_none program ->
        loop root name (Some value) arguments mode extensions globs overlap rest
    | "--arg" :: value :: rest ->
        loop root name program (value :: arguments) mode extensions globs
          overlap rest
    | "--match" :: value :: rest ->
        loop root name program arguments value extensions globs overlap rest
    | "--extension" :: value :: rest ->
        loop root name program arguments mode (value :: extensions) globs
          overlap rest
    | "--glob" :: value :: rest ->
        loop root name program arguments mode extensions (value :: globs)
          overlap rest
    | "--overlap" :: value :: rest ->
        loop root name program arguments mode extensions globs value rest
    | value :: rest when Option.is_none name ->
        loop root (Some value) program arguments mode extensions globs overlap
          rest
    | _ -> usage ()
  in
  loop None None None [] "extensions" [] [] "same-symbol" arguments

let parse_semantic_server_configure arguments =
  let rec loop root name mode extensions globs overlap = function
    | [] -> (
        match (name, mode, overlap) with
        | Some name, Some mode, Some overlap ->
            ( Option.value root ~default:default_root,
              name,
              semantic_match_scope mode (List.rev extensions) (List.rev globs),
              parse_semantic_overlap overlap )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) name mode extensions globs overlap rest
    | "--match" :: value :: rest when Option.is_none mode ->
        loop root name (Some value) extensions globs overlap rest
    | "--extension" :: value :: rest ->
        loop root name mode (value :: extensions) globs overlap rest
    | "--glob" :: value :: rest ->
        loop root name mode extensions (value :: globs) overlap rest
    | "--overlap" :: value :: rest when Option.is_none overlap ->
        loop root name mode extensions globs (Some value) rest
    | value :: rest when Option.is_none name ->
        loop root (Some value) mode extensions globs overlap rest
    | _ -> usage ()
  in
  loop None None None [] [] None arguments

let render_semantic_server (server : Semantic_config.server) =
  let match_values =
    match server.match_scope with
    | Semantic_config.Extensions values | Semantic_config.Path_globs values ->
        String.concat "," values
    | Semantic_config.All_files -> "*"
  in
  Printf.printf
    "semantic-server %s enabled %b program %s arguments %s match %s values %s \
     overlap %s\n"
    server.name server.enabled server.program
    (String.concat "," server.arguments)
    (Semantic_config.match_scope_to_string server.match_scope)
    match_values
    (Semantic_config.overlap_sensitivity_to_string server.overlap_sensitivity)

let run_semantic_server = function
  | "list" :: arguments ->
      Semantic_config.list ~root:(parse_root arguments)
      |> require_ok Semantic_config.error_to_string
      |> List.iter render_semantic_server
  | "add" :: arguments ->
      let root, server = parse_semantic_server_add arguments in
      Semantic_config.add ~root ~server
      |> require_ok Semantic_config.error_to_string;
      render_semantic_server server
  | "configure" :: arguments ->
      let root, name, match_scope, overlap_sensitivity =
        parse_semantic_server_configure arguments
      in
      Semantic_config.configure ~root ~name ~match_scope ~overlap_sensitivity
      |> require_ok Semantic_config.error_to_string;
      Semantic_config.find ~root ~name
      |> require_ok Semantic_config.error_to_string
      |> render_semantic_server
  | "enable" :: arguments ->
      let root, name = parse_remote_name arguments in
      Semantic_config.set_enabled ~root ~name ~enabled:true
      |> require_ok Semantic_config.error_to_string;
      Printf.printf "semantic-server enabled %s\n" name
  | "disable" :: arguments ->
      let root, name = parse_remote_name arguments in
      Semantic_config.set_enabled ~root ~name ~enabled:false
      |> require_ok Semantic_config.error_to_string;
      Printf.printf "semantic-server disabled %s\n" name
  | "remove" :: arguments ->
      let root, name = parse_remote_name arguments in
      Semantic_config.remove ~root ~name
      |> require_ok Semantic_config.error_to_string;
      Printf.printf "semantic-server removed %s\n" name
  | _ -> usage ()

let read_bearer_token () =
  let attributes =
    try Unix.tcgetattr Unix.stdin
    with Unix.Unix_error _ ->
      fail "remote login requires an interactive terminal"
  in
  let hidden = { attributes with Unix.c_echo = false } in
  print_string "relay access secret: ";
  flush stdout;
  let token =
    Fun.protect
      ~finally:(fun () ->
        (try Unix.tcsetattr Unix.stdin Unix.TCSANOW attributes
         with Unix.Unix_error _ -> ());
        print_newline ())
      (fun () ->
        Unix.tcsetattr Unix.stdin Unix.TCSANOW hidden;
        try Ok (read_line ()) with End_of_file -> Error ())
  in
  match token with
  | Ok token -> token
  | Error () -> fail "no relay access secret was provided"

let run_remote_login arguments =
  let root, name = parse_remote_name arguments in
  let remote =
    Transport_config.find ~root ~name
    |> require_ok Transport_config.error_to_string
  in
  let identity = Service.identity ~root |> require_ok Service.error_to_string in
  let token = read_bearer_token () in
  Transport_credential.save ~remote:name ~token
  |> require_ok Transport_credential.error_to_string;
  Transport_credential.save_for_repository ~url:remote.Transport_config.url
    ~repository:(Trust.Repository_id.to_string identity.Service.repository)
    ~token
  |> require_ok Transport_credential.error_to_string;
  Printf.printf "credential saved for remote %s\n" name

type relay_serve = Config of string | Legacy of string * string

let parse_relay_serve arguments =
  let rec loop config storage listen = function
    | [] -> (
        match (config, storage, listen) with
        | Some path, None, None -> Config path
        | None, Some storage, Some listen -> Legacy (storage, listen)
        | _ -> usage ())
    | "--config" :: path :: rest when Option.is_none config ->
        loop (Some path) storage listen rest
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop config (Some value) listen rest
    | "--listen" :: value :: rest when Option.is_none listen ->
        loop config storage (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let relay_environment () =
  Unix.environment () |> Array.to_list
  |> List.filter_map (fun binding ->
      match String.index_opt binding '=' with
      | None -> None
      | Some index ->
          Some
            ( String.sub binding 0 index,
              String.sub binding (index + 1) (String.length binding - index - 1)
            ))

let run_relay_serve arguments =
  match parse_relay_serve arguments with
  | Legacy (storage, listen) ->
      Relay_http.serve ~root:storage ~listen
      |> require_ok Relay_http.error_to_string
  | Config path ->
      let config =
        Relay_config.load ~path |> require_ok Relay_config.error_to_string
      in
      let config =
        Relay_config.override_environment config (relay_environment ())
        |> require_ok Relay_config.error_to_string
      in
      Relay_http.serve_with_config config
      |> require_ok Relay_http.error_to_string

let relay_now () = Int64.of_float (Unix.gettimeofday ())

let parse_relay_repository value =
  Trust.Repository_id.of_string value
  |> require_ok (fun error -> "invalid relay repository ID: " ^ error)
  |> Trust.Repository_id.to_string

let parse_relay_access_scope value =
  let scopes =
    value |> String.split_on_char ','
    |> List.map (function
      | "read" -> Relay_access.Read
      | "write" -> Relay_access.Write
      | _ -> fail "relay access scope must contain only read and write")
  in
  if scopes = [] then fail "relay access scope must not be empty" else scopes

let parse_relay_access_lifetime = function
  | None -> Relay_access.default_lifetime_seconds
  | Some value -> (
      match Int64.of_string_opt value with
      | Some value
        when Int64.compare value 0L > 0
             && Int64.compare value Relay_access.max_lifetime_seconds <= 0 ->
          value
      | _ ->
          fail
            "relay access lifetime must be a positive number of seconds no \
             greater than one year")

let with_controlling_tty run =
  try
    let descriptor = Unix.openfile "/dev/tty" [ Unix.O_WRONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () -> run descriptor)
  with Unix.Unix_error _ ->
    fail
      "relay access issue and rotate require an interactive controlling \
       terminal"

let write_tty descriptor value =
  let rec loop offset =
    if offset <> String.length value then
      try
        let count =
          Unix.write_substring descriptor value offset
            (String.length value - offset)
        in
        if count = 0 then fail "could not display relay access secret"
        else loop (offset + count)
      with Unix.Unix_error _ -> fail "could not display relay access secret"
  in
  loop 0

let display_relay_access_secret descriptor grant =
  write_tty descriptor
    ("relay access secret (record now; shown once): "
   ^ grant.Relay_access.grant_secret ^ "\n")

let parse_relay_access_issue arguments =
  let rec loop storage repository scope expires_in = function
    | [] -> (
        match (storage, repository, scope) with
        | Some storage, Some repository, Some scope ->
            (storage, repository, scope, parse_relay_access_lifetime expires_in)
        | _ -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) repository scope expires_in rest
    | "--repository" :: value :: rest when Option.is_none repository ->
        loop storage (Some value) scope expires_in rest
    | "--scope" :: value :: rest when Option.is_none scope ->
        loop storage repository (Some value) expires_in rest
    | "--expires-in" :: value :: rest when Option.is_none expires_in ->
        loop storage repository scope (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_relay_access_issue arguments =
  let storage, repository, scope, expires_in =
    parse_relay_access_issue arguments
  in
  let repository = parse_relay_repository repository in
  let scopes = parse_relay_access_scope scope in
  with_controlling_tty (fun tty ->
      let grant =
        Relay_access.update ~root:storage (fun registry ->
            Relay_access.issue ~now:(relay_now ()) ~repository ~scopes
              ~expires_in registry)
        |> require_ok Relay_access.error_to_string
      in
      Printf.printf "credential %s\n" grant.Relay_access.grant_credential_id;
      Printf.printf "expires-at %Ld\n" grant.Relay_access.grant_expires_at;
      display_relay_access_secret tty grant)

let parse_relay_access_rotate arguments =
  let rec loop storage credential_id expires_in = function
    | [] -> (
        match (storage, credential_id) with
        | Some storage, Some credential_id ->
            (storage, credential_id, parse_relay_access_lifetime expires_in)
        | _ -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) credential_id expires_in rest
    | "--id" :: value :: rest when Option.is_none credential_id ->
        loop storage (Some value) expires_in rest
    | "--expires-in" :: value :: rest when Option.is_none expires_in ->
        loop storage credential_id (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_relay_access_rotate arguments =
  let storage, credential_id, expires_in =
    parse_relay_access_rotate arguments
  in
  with_controlling_tty (fun tty ->
      let grant =
        Relay_access.update ~root:storage (fun registry ->
            Relay_access.rotate ~now:(relay_now ()) ~credential_id ~expires_in
              registry)
        |> require_ok Relay_access.error_to_string
      in
      Printf.printf "credential %s\n" grant.Relay_access.grant_credential_id;
      Printf.printf "expires-at %Ld\n" grant.Relay_access.grant_expires_at;
      display_relay_access_secret tty grant)

let parse_relay_access_revoke arguments =
  let rec loop storage credential_id = function
    | [] -> (
        match (storage, credential_id) with
        | Some storage, Some credential_id -> (storage, credential_id)
        | _ -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) credential_id rest
    | "--id" :: value :: rest when Option.is_none credential_id ->
        loop storage (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_relay_access_revoke arguments =
  let storage, credential_id = parse_relay_access_revoke arguments in
  Relay_access.update ~root:storage (fun registry ->
      Relay_access.revoke ~now:(relay_now ()) ~credential_id registry
      |> Result.map (fun registry -> (registry, ())))
  |> require_ok Relay_access.error_to_string;
  Printf.printf "credential revoked %s\n" credential_id

let parse_relay_access_list arguments =
  let rec loop storage repository = function
    | [] -> (
        match storage with
        | Some storage -> (storage, repository)
        | None -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) repository rest
    | "--repository" :: value :: rest when Option.is_none repository ->
        loop storage (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_relay_access_list arguments =
  let storage, repository = parse_relay_access_list arguments in
  let repository = Option.map parse_relay_repository repository in
  Relay_access.load ~root:storage
  |> require_ok Relay_access.error_to_string
  |> Relay_access.credentials
  |> List.filter (fun credential ->
      Option.fold ~none:true
        ~some:(String.equal (Relay_access.credential_repository credential))
        repository)
  |> List.iter (fun credential ->
      let status =
        match Relay_access.credential_status credential with
        | Relay_access.Active -> "active"
        | Relay_access.Revoked -> "revoked"
      in
      Printf.printf "credential %s\n" (Relay_access.credential_id credential);
      Printf.printf "repository %s\n"
        (Relay_access.credential_repository credential);
      Printf.printf "scope %s\n"
        (Relay_access.scopes_to_string
           (Relay_access.credential_scopes credential));
      Printf.printf "issued-at %Ld\n"
        (Relay_access.credential_issued_at credential);
      Printf.printf "expires-at %Ld\n"
        (Relay_access.credential_expires_at credential);
      Printf.printf "status %s\n" status)

let write_staged_package_file path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let channel = Unix.out_channel_of_descr descriptor in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        Out_channel.output_string channel bytes;
        Out_channel.flush channel);
    Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "bootstrap package write %s %s: %s" operation path
         (Unix.error_message error))

let fetch_package_for_manifest client ~project ~destination manifest_id =
  let manifest =
    Transport_http.get client ~project ~kind:Transport_http.Manifest
      ~id:manifest_id
    |> require_ok Transport_http.error_to_string
  in
  let object_ids =
    Package.manifest_object_ids manifest |> require_ok Package.error_to_string
  in
  let* () =
    try
      Unix.mkdir destination 0o700;
      Unix.mkdir (Filename.concat destination "objects") 0o700;
      Ok ()
    with Unix.Unix_error (error, operation, path) ->
      Error
        (Printf.sprintf "bootstrap package staging %s %s: %s" operation path
           (Unix.error_message error))
  in
  let* () =
    write_staged_package_file
      (Filename.concat destination "manifest.cbor")
      manifest
  in
  let rec fetch_objects = function
    | [] -> Ok ()
    | id :: rest ->
        let id_text = Yeokcham_store.Stored_object_id.to_hex id in
        let bytes =
          Transport_http.get client ~project ~kind:Transport_http.Object
            ~id:id_text
          |> require_ok Transport_http.error_to_string
        in
        let* () =
          write_staged_package_file
            (Filename.concat (Filename.concat destination "objects") id_text)
            bytes
        in
        fetch_objects rest
  in
  fetch_objects object_ids

let remove_staged_package destination =
  let objects = Filename.concat destination "objects" in
  (try
     Sys.readdir objects
     |> Array.iter (fun name ->
         try Unix.unlink (Filename.concat objects name)
         with Unix.Unix_error _ -> ());
     Unix.rmdir objects
   with Unix.Unix_error _ | Sys_error _ -> ());
  (try Unix.unlink (Filename.concat destination "manifest.cbor")
   with Unix.Unix_error _ -> ());
  try Unix.rmdir destination with Unix.Unix_error _ -> ()

let with_transport_staging ~root run =
  try
    let staging =
      Filename.temp_file ~temp_dir:root ".yeokcham-v1-transport-receive-" ".tmp"
    in
    Unix.unlink staging;
    Unix.mkdir staging 0o700;
    Fun.protect
      ~finally:(fun () ->
        try
          Sys.readdir staging
          |> Array.iter (fun name ->
              remove_staged_package (Filename.concat staging name));
          Unix.rmdir staging
        with Unix.Unix_error _ | Sys_error _ -> ())
      (fun () -> run staging)
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "transport staging %s %s: %s" operation root
         (Unix.error_message error))

let run_bootstrap_publish arguments =
  let root, remote_name = parse_remote_name arguments in
  let remote =
    Transport_config.find ~root ~name:remote_name
    |> require_ok Transport_config.error_to_string
  in
  let token =
    Transport_credential.load ~remote:remote_name
    |> require_ok Transport_credential.error_to_string
  in
  let client =
    Transport_http.create ~url:remote.Transport_config.url ~token
    |> require_ok Transport_http.error_to_string
  in
  let identity = Service.identity ~root |> require_ok Service.error_to_string in
  let project = Trust.Repository_id.to_string identity.Service.repository in
  let signing_capability = local_signing_capability root in
  let outbound =
    Service.prepare_bootstrap_outbound ~root ~signing_capability
    |> require_ok Service.error_to_string
  in
  Fun.protect
    ~finally:(fun () ->
      Package.dispose_artifact outbound.Service.bootstrap_artifact)
    (fun () ->
      let uploaded = ref 0 in
      Package.iter_artifact_objects outbound.Service.bootstrap_artifact
        ~f:(fun id bytes ->
          let id = Yeokcham_store.Stored_object_id.to_hex id in
          Transport_http.put client ~project ~kind:Transport_http.Object ~id
            ~bytes
          |> require_ok Transport_http.error_to_string;
          incr uploaded;
          Ok ())
      |> require_ok Package.error_to_string;
      let manifest =
        Package.artifact_manifest outbound.Service.bootstrap_artifact
      in
      let manifest_id = Transport.sha256 manifest in
      Transport_http.put client ~project ~kind:Transport_http.Manifest
        ~id:manifest_id ~bytes:manifest
      |> require_ok Transport_http.error_to_string;
      let basis = Bootstrap.encode outbound.Service.bootstrap_basis in
      let basis_id = Bootstrap.id outbound.Service.bootstrap_basis in
      Transport_http.put client ~project ~kind:Transport_http.Bootstrap
        ~id:basis_id ~bytes:basis
      |> require_ok Transport_http.error_to_string;
      Printf.printf "bootstrap basis %s\n" basis_id;
      Printf.printf "uploaded artifacts %d\n" (!uploaded + 2))

let parse_bootstrap arguments =
  let rec loop root remote url repository basis username draft title device
      phrase = function
    | [] -> (
        match
          ( remote,
            url,
            repository,
            basis,
            username,
            draft,
            title,
            device,
            phrase )
        with
        | ( Some remote,
            Some url,
            Some repository,
            Some basis,
            Some username,
            Some draft,
            Some title,
            Some device,
            Some phrase ) ->
            ( Option.value root ~default:default_root,
              remote,
              url,
              repository,
              basis,
              username,
              draft,
              title,
              device,
              phrase )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) remote url repository basis username draft title
          device phrase rest
    | "--remote" :: value :: rest when Option.is_none remote ->
        loop root (Some value) url repository basis username draft title device
          phrase rest
    | "--url" :: value :: rest when Option.is_none url ->
        loop root remote (Some value) repository basis username draft title
          device phrase rest
    | "--repository" :: value :: rest when Option.is_none repository ->
        loop root remote url (Some value) basis username draft title device
          phrase rest
    | "--basis" :: value :: rest when Option.is_none basis ->
        loop root remote url repository (Some value) username draft title device
          phrase rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root remote url repository basis (Some value) draft title device
          phrase rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root remote url repository basis username (Some value) title device
          phrase rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root remote url repository basis username draft (Some value) device
          phrase rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root remote url repository basis username draft title (Some value)
          phrase rest
    | "--verify-phrase" :: value :: rest when Option.is_none phrase ->
        loop root remote url repository basis username draft title device
          (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None None None None None arguments

let run_bootstrap arguments =
  let ( root,
        remote_name,
        url,
        repository,
        basis_id,
        username,
        draft,
        title,
        device,
        phrase ) =
    parse_bootstrap arguments
  in
  let repository =
    Trust.Repository_id.of_string repository
    |> require_ok (fun detail -> "invalid repository identifier: " ^ detail)
  in
  if not (Transport.valid_digest basis_id) then
    fail "invalid bootstrap basis identifier";
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  let initial_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  let device_id =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let signing_capability =
    V1_signer.load_native device_id |> require_ok V1_signer.error_to_string
  in
  let local_device =
    Trust.signing_public_key signing_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal device_id (Trust.device_id local_device)) then
    fail "local signing capability does not match --device";
  let token = read_bearer_token () in
  let client =
    Transport_http.create ~url ~token
    |> require_ok Transport_http.error_to_string
  in
  let project = Trust.Repository_id.to_string repository in
  let basis =
    Transport_http.get client ~project ~kind:Transport_http.Bootstrap
      ~id:basis_id
    |> require_ok Transport_http.error_to_string
  in
  if not (String.equal basis_id (Transport.sha256 basis)) then
    fail "bootstrap basis route ID does not match canonical bytes";
  let decoded_basis =
    Bootstrap.decode basis |> require_ok Bootstrap.error_to_string
  in
  if not (String.equal basis_id (Bootstrap.id decoded_basis)) then
    fail "bootstrap basis ID does not match canonical bytes";
  let status =
    with_transport_staging ~root (fun staging ->
        let package = Filename.concat staging basis_id in
        let* () =
          fetch_package_for_manifest client ~project ~destination:package
            (Bootstrap.manifest decoded_basis)
        in
        let* verified =
          Bootstrap.verify ~repository ~package ~bytes:basis
          |> Result.map_error Bootstrap.error_to_string
        in
        let local_certificate =
          Trust.certificates
            (Trust.authority_membership (Bootstrap.authority verified))
          |> List.find_opt (fun certificate ->
              Model.Device_id.equal
                (Trust.device_id (Trust.certificate_subject certificate))
                device_id)
        in
        let* local_certificate =
          match local_certificate with
          | Some certificate -> Ok (Trust.certificate_id certificate)
          | None ->
              Error "device is not enrolled in the bootstrap authority closure"
        in
        Service.bootstrap_from_package ~root ~repository ~package ~basis
          ~verify_phrase:phrase ~username ~initial_draft ~title
          ~device:local_device ~local_certificate
        |> Result.map_error Service.error_to_string)
    |> require_ok Fun.id
  in
  Transport_config.add ~root ~name:remote_name ~url
  |> require_ok Transport_config.error_to_string;
  Transport_credential.save ~remote:remote_name ~token
  |> require_ok Transport_credential.error_to_string;
  render_status status;
  Printf.printf
    "bootstrap verified %s; no working-tree materialization occurred\n" basis_id

let[@warning "-4"] fail_exchange error =
  let module Native = Sync.Core in
  let status, code =
    match error with
    | Native.Authority_error _ -> (7, "exchange-authority-blocked")
    | Native.Receipt_error
        (Service.Core_receive.Admission_error (Local.Receive_trust _))
    | Native.Package_error
        (Package.Core_model_error (Core.Unsupported_policy _))
    | Native.Receipt_error
        (Service.Core_receive.Package_error
           (Package.Core_model_error (Core.Unsupported_policy _)))
    | Native.Receipt_error (Service.Core_receive.Trust_error _)
    | Native.Package_error (Package.Core_trust_error _ | Package.Trust_error _)
    | Native.Receipt_error
        (Service.Core_receive.Package_error
           (Package.Core_trust_error _ | Package.Trust_error _)) ->
        (7, "exchange-authority-blocked")
    | Native.Http_error (Transport_http.Unexpected_status (401 | 403)) ->
        (7, "exchange-access-blocked")
    | Native.Integrity_error _
    | Native.Http_error
        (Transport_http.Invalid_response _ | Transport_http.Response_too_large)
      ->
        (6, "exchange-integrity-failure")
    | Native.Http_error _ | Native.Invalid _ | Native.Store_error _
    | Native.Raw_error _ ->
        (5, "exchange-unavailable")
    | _ -> (6, "exchange-integrity-failure")
  in
  fail_with_status status code (Native.error_to_string error)

let fail_clone = function
  | Sync.Clone.Exchange_error error -> fail_exchange error
  | Sync.Clone.Blocked message ->
      fail_with_status 7 "clone-authority-blocked" message
  | Sync.Clone.Choice message -> fail_with_status 3 "clone-needs-choice" message
  | Sync.Clone.Invalid message -> fail_with_status 6 "clone-invalid" message
  | Sync.Clone.Store_error error ->
      fail_with_status 5 "clone-store-unavailable"
        (Yeokcham_v1_store.error_to_string error)
  | Sync.Clone.Integration_error error ->
      fail_with_status 8 "clone-application-incomplete"
        (Service.Integrate.error_to_string error)

let read_token_stdin () =
  let buffer = Buffer.create 128 in
  let rec loop () =
    match input_char stdin with
    | '\n' -> ()
    | '\000' | '\r' ->
        fail_with_status 7 "clone-credential-invalid"
          "relay token contains an invalid character"
    | character ->
        if Buffer.length buffer >= 4096 then
          fail_with_status 7 "clone-credential-invalid"
            "relay token exceeds 4096 bytes";
        Buffer.add_char buffer character;
        loop ()
    | exception End_of_file -> ()
  in
  loop ();
  if Buffer.length buffer = 0 then
    fail_with_status 7 "clone-credential-missing" "no relay token was provided";
  Buffer.contents buffer

let run_clone arguments =
  let module Clone = Sync.Clone in
  let failure_context root =
    local_failure_context :=
      Some
        (fun () ->
          let attached = Sys.file_exists (Filename.concat root ".yeokcham") in
          let representable = Result.is_ok (Yeokcham_encoding.text root) in
          ( `Assoc
              [
                ("root", json_byte_path root);
                ("workspace_attached", `Bool attached);
              ],
            [
              Cli_data.
                {
                  arguments =
                    [
                      "yeokcham";
                      "clone";
                      "--resume";
                      (if representable then root else String.escaped root);
                    ];
                  explanation =
                    (if attached then
                       "Resume the frozen local clone without another signer \
                        or network request."
                     else
                       "No workspace is attached; rerun the original clone \
                        command after correcting the reported problem.");
                  applicable = attached && representable;
                  confirmation_required = false;
                };
            ],
            None ))
  in
  let resume = ref None
  and device = ref None
  and phrase = ref None
  and branch = ref None
  and request = ref None
  and preview = ref false
  and token_stdin = ref false in
  let assign field value =
    if Option.is_some !field then usage () else field := Some value
  in
  let rec parse positional = function
    | [] -> List.rev positional
    | "--resume" :: value :: rest ->
        assign resume value;
        parse positional rest
    | "--device" :: value :: rest ->
        assign device value;
        parse positional rest
    | "--verify-phrase" :: value :: rest ->
        assign phrase value;
        parse positional rest
    | "--branch" :: value :: rest ->
        assign branch value;
        parse positional rest
    | "--request" :: value :: rest ->
        assign request value;
        parse positional rest
    | "--preview" :: rest when not !preview ->
        preview := true;
        parse positional rest
    | "--token-stdin" :: rest when not !token_stdin ->
        token_stdin := true;
        parse positional rest
    | value :: rest when not (String.starts_with ~prefix:"-" value) ->
        parse (value :: positional) rest
    | _ -> usage ()
  in
  let positional = parse [] arguments in
  let outcome =
    match !resume with
    | Some root ->
        if
          positional <> [] || !device <> None || !phrase <> None
          || !branch <> None || !request <> None || !preview || !token_stdin
        then usage ();
        failure_context root;
        Clone.resume ~root
    | None ->
        let url, destination =
          match positional with
          | [ url ] -> (url, None)
          | [ url; path ] -> (url, Some path)
          | _ -> usage ()
        in
        let source =
          match Clone.source url with
          | Ok source -> source
          | Error error -> fail_clone error
        in
        let destination =
          Option.value destination ~default:(Clone.default_directory source)
        in
        failure_context destination;
        (match Clone.check_new_destination destination with
        | Ok _ -> ()
        | Error error -> fail_clone error);
        let device =
          match !device with Some device -> device | None -> usage ()
        in
        let verify_phrase =
          match !phrase with Some phrase -> phrase | None -> usage ()
        in
        let device =
          parse_identifier "invalid device identifier" Model.Device_id.of_string
            device
        in
        let signing_capability =
          match V1_signer.load_native device with
          | Ok capability -> capability
          | Error error ->
              fail_with_status 7 "clone-device-unavailable"
                (V1_signer.error_to_string error)
        in
        let actual_device =
          Trust.device_of_public_key
            (Trust.signing_public_key signing_capability)
          |> require_ok Trust.error_to_string
          |> Trust.device_id
        in
        if not (Model.Device_id.equal actual_device device) then
          fail_with_status 7 "clone-device-mismatch"
            "signing capability does not match the requested device";
        let token =
          if !token_stdin then read_token_stdin ()
          else
            match
              Transport_credential.load_for_repository ~url:source.Clone.url
                ~repository:(Core.Repository_id.to_hex source.Clone.repository)
            with
            | Ok token -> token
            | Error _
              when requested_format () = Text_format && Unix.isatty Unix.stdin
              ->
                read_bearer_token ()
            | Error error ->
                fail_with_status 7 "clone-credential-unavailable"
                  (Transport_credential.error_to_string error
                  ^ "; use --token-stdin or provision the scoped credential")
        in
        let expected_request =
          Option.map
            (fun value ->
              Core.Digest.of_hex value |> require_ok Core.error_to_string)
            !request
        in
        Clone.run ~source ~destination
          ~branch:(Option.value !branch ~default:"main")
          ~token ~signing_capability ~verify_phrase ~expected_request
          ~preview:!preview
  in
  let report =
    match outcome with Ok report -> report | Error error -> fail_clone error
  in
  let data =
    `Assoc
      [
        ("root", json_byte_path report.Clone.root);
        ("request_id", `String report.Clone.request);
        ( "repository",
          `String (Core.Repository_id.to_hex report.Clone.repository) );
        ("branch", `String (Core.Branch_id.to_hex report.Clone.branch));
        ("accepted", `String (Core.Record_id.to_hex report.Clone.accepted));
        ("snapshot", `String (Core.Object_id.to_hex report.Clone.snapshot));
        ("records", `Int report.Clone.records);
        ("branches", `Int report.Clone.branches);
        ("preview", `Bool report.Clone.preview);
        ("resumed", `Bool report.Clone.resumed);
        ( "cursor",
          match report.Clone.cursor with
          | None -> `Null
          | Some cursor -> json_history_identity cursor );
        ( "operation",
          match report.Clone.operation with
          | None -> `Null
          | Some op -> `String (Core.Operation_id.to_hex op) );
        ( "uncaptured_work",
          match report.Clone.uncaptured with
          | None -> `Null
          | Some changed -> `Bool changed );
        ( "coverage",
          `Assoc
            [
              ("scope", `String "locally_known_shared_closure");
              ("verified_complete", `Bool true);
              ("remote_disclosure_proven", `Bool false);
              ("managed_downloads", `Bool false);
            ] );
      ]
  in
  match requested_format () with
  | Json_format ->
      domain_json
        ~outcome:(if report.Clone.preview then `Unchanged else `Completed)
        ~code:
          (if report.Clone.preview then "clone-preview" else "workspace-cloned")
        ~message:
          (if report.Clone.preview then
             "Verified source; destination unchanged."
           else "Verified shared workspace selected.")
        ~data
        ~next_actions:
          (if report.Clone.preview then []
           else
             [
               action ~root:report.Clone.root [ "status" ]
                 "Inspect local work and shared coverage.";
             ])
        ()
  | Text_format -> (
      Printf.printf "%s %s\nrepository %s\nbranch %s\naccepted %s\nrequest %s\n"
        (if report.Clone.preview then "clone preview" else "cloned")
        (Output.display_value report.Clone.root)
        (Core.Repository_id.to_hex report.Clone.repository)
        (Core.Branch_id.to_hex report.Clone.branch)
        (Core.Record_id.to_hex report.Clone.accepted)
        report.Clone.request;
      match report.Clone.uncaptured with
      | Some true -> print_endline "private disk edits remain uncaptured"
      | _ -> ())

let run_exchange arguments =
  let module Native = Sync.Core in
  let root, remote = parse_remote_name arguments in
  let report =
    match
      Native.run ~root ~remote ~load_signing_capability:(fun device ->
          V1_signer.load ~root device
          |> Result.map_error V1_signer.error_to_string)
    with
    | Ok report -> report
    | Error error -> fail_exchange error
  in
  let outgoing =
    match report.Native.upload with
    | Native.No_outgoing -> `Assoc [ ("state", `String "none") ]
    | Native.Pending reason ->
        `Assoc
          [
            ("state", `String "pending");
            ("reason", `String (public_error_message reason));
          ]
    | Native.Acknowledged sent ->
        `Assoc
          [
            ("state", `String "acknowledged");
            ("publication_id", `String sent.publication);
            ("manifest_id", `String sent.manifest);
            ("objects_offered", `Int sent.objects_offered);
            ("reused_batch", `Bool sent.reused);
          ]
  in
  let data =
    `Assoc
      [
        ("remote", `String remote);
        ("relay_inventory_publications", `Int report.Native.remote_publications);
        ("received_publications", `Int report.Native.received_publications);
        ("received_records", `Int report.Native.received_records);
        ("received_branches", `Int report.Native.received_branches);
        ( "legacy_received_revisions",
          `Int report.Native.legacy_received_revisions );
        ("known_shared_records", `Int report.Native.local_shared_records);
        ( "selected_branch",
          `String (Core.Branch_id.to_hex report.Native.selected_branch) );
        ( "working_basis",
          `String (Core.Record_id.to_hex report.Native.working_basis) );
        ("cursor", json_history_identity report.Native.cursor);
        ( "coverage",
          `Assoc
            [
              ("scope", `String "locally_known_shared_closure");
              ("verified_complete", `Bool true);
              ("relay_inventory_checked", `Bool true);
              ("remote_disclosure_proven", `Bool false);
              ("managed_downloads", `Bool false);
            ] );
        ("outgoing", outgoing);
      ]
  in
  let next_actions =
    [
      Cli_data.
        {
          arguments = [ "yeokcham"; "exchange"; "--root"; root; remote ];
          explanation = "Retry pending transfers or check for new shared work.";
          applicable = true;
          confirmation_required = false;
        };
    ]
  in
  let pending =
    match report.Native.upload with
    | Native.Pending _ -> true
    | Native.No_outgoing | Native.Acknowledged _ -> false
  in
  (match requested_format () with
  | Json_format ->
      if pending then
        Cli_data.domain_failure ~command:(command_name ()) ~outcome:`Incomplete
          ~error:
            Cli_data.
              {
                code = "exchange-outgoing-pending";
                message =
                  "Receipt completed; outgoing transfer remains pending.";
              }
          ~data ~warnings:[] ~next_actions ()
        |> Cli_data.encode |> print_json
      else
        domain_json ~outcome:`Completed ~code:"shared-work-exchanged"
          ~message:"Shared receipt and foreground transfer completed." ~data
          ~next_actions ()
  | Text_format -> (
      Printf.printf "received publications %d; Core records %d; branches %d\n"
        report.Native.received_publications report.Native.received_records
        report.Native.received_branches;
      Printf.printf
        "verified local shared closure: %d records; relay inventory checked: \
         %d couriers\n"
        report.Native.local_shared_records report.Native.remote_publications;
      match report.Native.upload with
      | Native.No_outgoing -> print_endline "outgoing: none"
      | Native.Pending reason ->
          Printf.printf "outgoing: pending; %s\n" (public_error_message reason)
      | Native.Acknowledged sent ->
          Printf.printf "outgoing: acknowledged %s; manifest %s\n"
            sent.publication sent.manifest));
  if pending then exit 5

let run_sync arguments =
  let root, remote_name = parse_remote_name arguments in
  let report =
    Sync.run ~root ~remote:remote_name ~load_signing_capability:(fun device ->
        V1_signer.load ~root device
        |> Result.map_error V1_signer.error_to_string)
    |> require_ok Sync.error_to_string
  in
  Printf.printf "received publications %d\n" report.Sync.discovered_publications;
  Printf.printf "received revisions %d\n" report.Sync.received_revisions;
  Printf.printf "deferred publications %d\n" report.Sync.deferred_publications;
  Printf.printf "created decisions %d\n" report.Sync.created_decisions;
  match report.Sync.upload with
  | Sync.Uploaded uploaded -> Printf.printf "uploaded artifacts %d\n" uploaded
  | Sync.Pending detail ->
      Printf.printf "upload pending %s\n" detail;
      print_endline "receive completed; rerun sync to retry upload"

let run_watch arguments =
  let root = parse_root arguments in
  V1_watch.run ~root

let parse_daemon_sync arguments =
  let rec loop root remote = function
    | [] -> (
        match remote with
        | Some remote -> (Option.value root ~default:default_root, remote)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) remote rest
    | value :: rest when Option.is_none remote -> loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_daemon = function
  | "start" :: arguments -> Runtime.start ~root:(parse_root arguments)
  | "status" :: arguments -> Runtime.status ~root:(parse_root arguments)
  | "stop" :: arguments -> Runtime.stop ~root:(parse_root arguments)
  | "sync" :: arguments ->
      let root, remote = parse_daemon_sync arguments in
      Runtime.sync ~root ~remote
  | "run" :: arguments -> Runtime.run ~root:(parse_root arguments)
  | _ -> usage ()

let dispatch () =
  match command_arguments () with
  | _ :: "init" :: arguments ->
      observe_after_success [ "init" ] arguments (fun () -> run_init arguments)
  | _ :: "join" :: arguments -> run_join arguments
  | _ :: "save" :: arguments ->
      observe_after_commit [ "save" ] arguments (fun () -> run_save arguments)
  | _ :: "ignore" :: "explain" :: arguments -> run_ignore_explain arguments
  | _ :: "branch" :: "list" :: arguments -> run_branch_list arguments
  | _ :: "branch" :: "create" :: arguments -> run_branch_create arguments
  | _ :: "switch" :: arguments ->
      observe_after_commit [ "switch" ] arguments (fun () ->
          run_switch arguments)
  | _ :: "branch" :: arguments -> run_branch_list arguments
  | _ :: "status" :: arguments -> run_status arguments
  | _ :: "history" :: arguments -> run_history arguments
  | _ :: "diff" :: arguments -> run_diff arguments
  | _ :: "changes" :: arguments -> run_changes arguments
  | _ :: "log" :: arguments -> run_log arguments
  | _ :: "graph" :: arguments -> run_graph arguments
  | _ :: "daemon" :: arguments -> run_daemon arguments
  | _ :: "device" :: "create" :: arguments -> run_device_create arguments
  | _ :: "device" :: "attach" :: arguments -> run_device_attach arguments
  | _ :: "device" :: "custody" :: arguments -> run_device_custody arguments
  | _ :: "device" :: "show" :: arguments -> run_device_show arguments
  | _ :: "device" :: "enroll" :: arguments -> run_device_enroll arguments
  | _ :: "device" :: "revoke" :: arguments -> run_device_revoke arguments
  | _ :: "device" :: "rotate" :: arguments -> run_device_rotate arguments
  | _ :: "authority" :: "heads" :: arguments -> run_authority_heads arguments
  | _ :: "authority" :: "reconcile" :: arguments ->
      run_authority_reconcile arguments
  | _ :: "recovery" :: "use" :: arguments -> run_recovery_use arguments
  | _ :: "recovery" :: "refresh" :: arguments -> run_recovery_refresh arguments
  | _ :: "user" :: "register" :: arguments -> run_user_register arguments
  | _ :: "undo-tree" :: arguments -> run_undo_tree arguments
  | _ :: (("undo" | "redo") as command) :: arguments ->
      ignore (run_history_navigation command arguments)
  | _ :: "timeline" :: arguments -> run_timeline arguments
  | _ :: "restore" :: "proofs" :: arguments -> run_restore_proofs arguments
  | _ :: "restore" :: "retain" :: arguments ->
      observe_after_success [ "restore"; "retain" ] arguments (fun () ->
          run_restore_retain arguments)
  | _ :: "restore" :: "forget" :: arguments ->
      observe_after_success [ "restore"; "forget" ] arguments (fun () ->
          run_restore_forget arguments)
  | _ :: "restore" :: arguments ->
      observe_after_commit [ "restore" ] arguments (fun () ->
          run_restore arguments)
  | _ :: "workspace" :: "activate" :: arguments ->
      observe_after_success [ "workspace"; "activate" ] arguments (fun () ->
          run_workspace_activate arguments)
  | _ :: "workspace" :: "update" :: arguments ->
      observe_after_commit [ "workspace"; "update" ] arguments (fun () ->
          run_workspace_update arguments)
  | _ :: "draft" :: "new" :: arguments ->
      observe_after_success [ "draft"; "new" ] arguments (fun () ->
          run_new_draft arguments)
  | _ :: "integrate" :: arguments ->
      observe_after_commit [ "integrate" ] arguments (fun () ->
          run_integrate arguments)
  | _ :: "operation" :: "recover" :: arguments ->
      run_operation_recover ~forget:false arguments
  | _ :: "operation" :: "forget" :: arguments ->
      run_operation_recover ~forget:true arguments
  | _ :: "operation" :: "show" :: arguments ->
      run_native_operation ~resume:false arguments
  | _ :: "operation" :: "resume" :: arguments ->
      run_native_operation ~resume:true arguments
  | _ :: "share" :: arguments ->
      observe_after_commit [ "share" ] arguments (fun () -> run_share arguments)
  | _ :: "withdraw" :: arguments ->
      observe_after_success [ "withdraw" ] arguments (fun () ->
          run_withdraw arguments)
  | _ :: "resolve" :: arguments ->
      if legacy_resolve_arguments arguments then
        observe_after_success [ "resolve" ] arguments (fun () ->
            run_resolve arguments)
      else run_native_resolve arguments
  | _ :: "conflicts" :: arguments -> run_conflicts arguments
  | _ :: "decision" :: "show" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "inspect" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "diff" :: arguments -> run_decision_diff arguments
  | _ :: "decision" :: "propose" :: arguments -> run_decision_propose arguments
  | _ :: "decision" :: "materialize-proposal" :: arguments ->
      run_decision_materialize_proposal arguments
  | _ :: "decision" :: "materialize" :: arguments ->
      run_decision_materialize arguments
  | _ :: "package" :: "create" :: arguments -> run_package_create arguments
  | _ :: "package" :: "adopt" :: arguments -> run_package_adopt arguments
  | _ :: "receive" :: arguments -> run_receive arguments
  | _ :: "bootstrap" :: "publish" :: arguments ->
      run_bootstrap_publish arguments
  | _ :: "bootstrap" :: arguments -> run_bootstrap arguments
  | _ :: "remote" :: "add" :: arguments -> run_remote_add arguments
  | _ :: "remote" :: "remove" :: arguments -> run_remote_remove arguments
  | _ :: "remote" :: "login" :: arguments -> run_remote_login arguments
  | _ :: "semantic" :: "server" :: arguments -> run_semantic_server arguments
  | _ :: "sync" :: arguments -> run_sync arguments
  | _ :: "exchange" :: arguments -> run_exchange arguments
  | _ :: "clone" :: arguments -> run_clone arguments
  | _ :: "relay" :: "access" :: "issue" :: arguments ->
      run_relay_access_issue arguments
  | _ :: "relay" :: "access" :: "rotate" :: arguments ->
      run_relay_access_rotate arguments
  | _ :: "relay" :: "access" :: "revoke" :: arguments ->
      run_relay_access_revoke arguments
  | _ :: "relay" :: "access" :: "list" :: arguments ->
      run_relay_access_list arguments
  | _ :: "relay" :: "serve" :: arguments -> run_relay_serve arguments
  | _ :: "deliver" :: arguments ->
      observe_after_success [ "deliver" ] arguments (fun () ->
          run_deliver arguments)
  | _ :: "pin" :: arguments ->
      observe_after_success [ "pin" ] arguments (fun () -> run_pin arguments)
  | _ :: "unpin" :: arguments ->
      observe_after_success [ "unpin" ] arguments (fun () ->
          run_unpin arguments)
  | _ :: "compact" :: arguments ->
      observe_after_commit [ "compact" ] arguments (fun () ->
          run_compact arguments)
  | _ :: "storage" :: "gc" :: arguments -> run_storage_gc arguments
  | _ :: "storage" :: "roots" :: arguments -> run_storage_roots arguments
  | _ :: "completion" :: arguments -> run_completion arguments
  | _ :: "hook" :: arguments -> run_hook arguments
  | _ :: "verify" :: arguments -> run_verify arguments
  | _ :: "repair" :: "plan" :: arguments -> run_repair_plan arguments
  | _ :: "repair" :: "apply" :: arguments -> run_repair_apply arguments
  | _ :: "repair" :: "defer" :: arguments -> run_repair_defer arguments
  | _ :: "watch" :: arguments -> run_watch arguments
  | _ -> usage ()

let () =
  (match requested_color () with
  | Ok mode ->
      Output.configure ~mode ~machine_output:(requested_format () = Json_format)
  | Error message -> fail_with "invalid-invocation" message);
  if snd (detail_arguments ()) > 1 then fail_with "invalid-invocation" "--details may be specified only once";
  match command_arguments () with
  | _ :: [ "--version" ] -> print_endline version_text
  | _ :: [ "--help" ] | _ :: [ "-h" ] -> print_help []
  | _ :: "help" :: path -> print_help path
  | _ :: arguments -> (
      match List.rev arguments with
      | "--help" :: reversed_path | "-h" :: reversed_path ->
          print_help (List.rev reversed_path)
      | _ ->
          let command = command_name () in
          if
            requested_format () = Json_format
            && not (native_json_command command)
          then run_generic_json command dispatch
          else (
            dispatch ();
            flush_domain_output ()))
  | [] -> usage ()
