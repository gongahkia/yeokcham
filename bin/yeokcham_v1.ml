module Journal = Yeokcham_v1_restore_journal
module History = Yeokcham_v1_undo
module Model = Yeokcham_v1_model
module Core = Model.Core
module Local = Yeokcham_v1_store.Local
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

let rec legacy_share_arguments = function
  | [] | "--" :: _ -> false
  | ("--change" | "--revision") :: _ -> true
  | ("--root" | "--title" | "--update" | "--authority" | "--format" | "--color")
    :: _ :: rest ->
      legacy_share_arguments rest
  | _ :: rest -> legacy_share_arguments rest

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
  loop true [] (raw_arguments ())

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
  || List.mem command
       [
         "status";
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
  || List.mem command
       [
         "status";
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
    when String.starts_with ~prefix:"branch has divergent" message
         || String.starts_with ~prefix:"branch name " message
            && String.ends_with ~suffix:"explicitly" message ->
      fail_with_status 3 "branch-choice-required" message
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
       ^ "This checkout is development source. Git interchange and general "
       ^ "clone are not supported.\n\n"
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
         exact target."
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
  | [ "withdraw" ] ->
      Some
        "usage: yeokcham withdraw [--root PATH] --change ID\n\n\
         Withdraw an eligible local shared change through the V1 model."
  | [ "resolve" ] ->
      Some
        "usage: yeokcham resolve [--root PATH] --decision ID --change ID \
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
  render_status status;
  print_endline "branch main (initial files remain private)";
  print_endline "automatic-capture not configured; run save or foreground watch";
  print_endline "private-backup not configured";
  print_endline "root-verification-phrase (compare during device join)";
  Printf.printf "%s\n" (Recovery.verification_phrase root_certificate);
  Printf.printf "recovery-package %s\n"
    (Output.display_value (Service.recovery_package_path root));
  print_endline "recovery-mnemonic (record offline; it is shown only now)";
  Printf.printf "%s\n" ceremony.Yeokcham_v1_recovery.mnemonic

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
      print_endline (if changed then "save recorded" else "save unchanged");
      render_status status);
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
    | Trust.Administrator -> "administrator")

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
          Printf.printf "%s %s branch:%s accepted:%s\n"
            (if Core.Branch_id.equal selected row.Core.branch_id then "*"
             else " ")
            (String.concat ", "
               (List.map Output.display_value row.Core.display_names))
            (Core.Branch_id.to_hex row.Core.branch_id)
            (String.concat ","
               (List.map Core.Record_id.to_hex row.Core.accepted_heads)))
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
           [ action ~root [ "status" ] "Inspect local work after selection." ])
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

let render_display_difference difference =
  let entry = difference.Service.entry_difference in
  Printf.printf "diff %s\n"
    (Output.display_value (Model.Path.to_string entry.Service.path));
  Printf.printf "  before %s\n  after  %s\n"
    (render_snapshot_entry entry.Service.before)
    (render_snapshot_entry entry.Service.after);
  match difference.Service.text_difference with
  | None -> ()
  | Some (Text_diff.Opaque reason) -> Printf.printf "  %s\n" reason
  | Some (Text_diff.Text hunks) ->
      List.iter
        (fun hunk ->
          Printf.printf "@@ -%d,%d +%d,%d @@\n" hunk.Text_diff.old_start
            hunk.Text_diff.old_count hunk.Text_diff.new_start
            hunk.Text_diff.new_count;
          List.iter
            (fun line ->
              Printf.printf "%s%s\n"
                (match line.Text_diff.kind with
                | Text_diff.Context -> " "
                | Text_diff.Removed -> "-"
                | Text_diff.Added -> "+")
                (display_line line.Text_diff.text);
              if not line.Text_diff.newline then
                print_endline "\\ No newline at end of file")
            hunk.Text_diff.lines)
        hunks

let run_status arguments =
  let root = parse_root arguments in
  let status = Service.inspect_local_status ~root |> require_local in
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
                 `Assoc
                   [
                     ( "operation_id",
                       `String (Core.Operation_id.to_hex p.Local.operation) );
                     ( "revision_id",
                       `String (Core.Record_id.to_hex p.Local.revision) );
                     ("title", `String p.Local.title);
                     ("transfer_state", `String "pending");
                   ])
               status.Service.status_publications) );
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
        (fun p ->
          Printf.printf "publication %s revision:%s transfer:pending title:%s\n"
            (Core.Operation_id.to_hex p.Local.operation)
            (Core.Record_id.to_hex p.Local.revision)
            (Output.display_value p.Local.title))
        status.Service.status_publications;
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
      Printf.printf "before %s snapshot %s\nafter %s snapshot %s\n"
        comparison.Service.before_state.Service.state_name
        (Model.Snapshot_id.to_string
           comparison.Service.before_state.Service.state_snapshot)
        comparison.Service.after_state.Service.state_name
        (Model.Snapshot_id.to_string
           comparison.Service.after_state.Service.state_snapshot);
      if not changed then print_endline "diff unchanged"
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
          | Service.Available ->
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
          | Service.Not_retained | Service.Unavailable _ -> None)
        page.Service.entries
  in
  match requested_format () with
  | Json_format ->
      domain_json ~outcome:`Completed ~code:"history-inspected"
        ~message:"Saved local history inspected."
        ~data:
          (`Assoc
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
             ])
        ~next_actions ()
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
        "archive not configured; availability describes local retained contents"

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

let render_navigation_text ~preview result =
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
  let _ =
    Transport_config.find ~root ~name
    |> require_ok Transport_config.error_to_string
  in
  let token = read_bearer_token () in
  Transport_credential.save ~remote:name ~token
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
  | _ :: "share" :: arguments ->
      observe_after_commit [ "share" ] arguments (fun () -> run_share arguments)
  | _ :: "withdraw" :: arguments ->
      observe_after_success [ "withdraw" ] arguments (fun () ->
          run_withdraw arguments)
  | _ :: "resolve" :: arguments ->
      observe_after_success [ "resolve" ] arguments (fun () ->
          run_resolve arguments)
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
