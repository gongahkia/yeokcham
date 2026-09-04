type value_kind =
  | Flag
  | Path
  | Identifier
  | Integer
  | Url
  | Choice of string list
  | Free_argument

type option_spec = {
  option_name : string;
  option_value : value_kind;
  option_repeatable : bool;
}

type command_spec = {
  command_path : string list;
  command_options : option_spec list;
  command_hook_eligible : bool;
}

type shell = Bash | Zsh | Fish

let option ?(repeatable = false) option_name option_value =
  { option_name; option_value; option_repeatable = repeatable }

let root = option "--root" Path
let format = option "--format" (Choice [ "text"; "json" ])
let identifier name = option name Identifier
let path name = option name Path
let flag name = option name Flag
let integer name = option name Integer
let url name = option name Url
let choice name values = option name (Choice values)
let repeated name value = option ~repeatable:true name value

let command ?(options = [ root ]) ?(hook = false) command_path =
  { command_path; command_options = options; command_hook_eligible = hook }

let commands =
  [
    command ~hook:true [ "init" ]
      ~options:
        [
          root;
          option "--username" Free_argument;
          identifier "--draft";
          option "--title" Free_argument;
        ];
    command [ "join" ]
      ~options:
        [
          root;
          option "--username" Free_argument;
          identifier "--draft";
          option "--title" Free_argument;
          identifier "--device";
          path "--from";
          option "--verify-phrase" Free_argument;
        ];
    command ~hook:true [ "save" ];
    command [ "status" ];
    command [ "changes" ];
    command [ "log" ];
    command [ "graph" ] ~options:[ root; flag "--authority" ];
    command [ "timeline" ];
    command ~hook:true [ "restore" ]
      ~options:[ root; identifier "--checkpoint"; path "--destination" ];
    command [ "restore"; "proofs" ];
    command ~hook:true [ "restore"; "retain" ]
      ~options:[ root; identifier "--operation" ];
    command ~hook:true [ "restore"; "forget" ]
      ~options:[ root; identifier "--operation" ];
    command ~hook:true [ "workspace"; "activate" ];
    command ~hook:true [ "workspace"; "update" ]
      ~options:[ root; flag "--replace" ];
    command ~hook:true [ "draft"; "new" ]
      ~options:[ root; identifier "--id"; option "--title" Free_argument ];
    command ~hook:true [ "share" ]
      ~options:
        [
          root;
          identifier "--change";
          identifier "--revision";
          identifier "--authority";
        ];
    command ~hook:true [ "withdraw" ] ~options:[ root; identifier "--change" ];
    command ~hook:true [ "resolve" ]
      ~options:
        [
          root;
          identifier "--decision";
          identifier "--change";
          identifier "--revision";
          path "--tree";
          identifier "--authority";
        ];
    command [ "decision"; "show" ] ~options:[ root; identifier "--decision" ];
    command [ "decision"; "inspect" ] ~options:[ root; identifier "--decision" ];
    command [ "decision"; "diff" ]
      ~options:
        [
          root;
          identifier "--decision";
          identifier "--candidate";
          option "--against" Free_argument;
        ];
    command [ "decision"; "propose" ]
      ~options:
        [
          root;
          identifier "--decision";
          identifier "--left";
          identifier "--right";
          option "--semantic-server" Free_argument;
        ];
    command
      [ "decision"; "materialize-proposal" ]
      ~options:
        [
          root;
          identifier "--decision";
          identifier "--left";
          identifier "--right";
          path "--destination";
        ];
    command
      [ "decision"; "materialize" ]
      ~options:[ root; identifier "--decision"; path "--destination" ];
    command ~hook:true [ "package"; "create" ]
      ~options:[ root; path "--destination" ];
    command ~hook:true [ "package"; "adopt" ]
      ~options:
        [
          root; path "--from"; identifier "--revision"; identifier "--authority";
        ];
    command [ "receive" ] ~options:[ root; path "--from"; flag "--review" ];
    command ~hook:true [ "bootstrap"; "publish" ];
    command [ "bootstrap" ]
      ~options:
        [
          root;
          option "--remote" Free_argument;
          url "--url";
          identifier "--repository";
          identifier "--basis";
          option "--username" Free_argument;
          identifier "--draft";
          option "--title" Free_argument;
          identifier "--device";
          option "--verify-phrase" Free_argument;
        ];
    command ~hook:true [ "remote"; "add" ];
    command ~hook:true [ "remote"; "remove" ];
    command [ "remote"; "login" ];
    command ~hook:true
      [ "semantic"; "server"; "add" ]
      ~options:
        [
          root;
          path "--program";
          repeated "--arg" Free_argument;
          choice "--match" [ "extensions"; "path-globs"; "all-files" ];
          repeated "--extension" Free_argument;
          repeated "--glob" Free_argument;
          choice "--overlap" [ "same-symbol"; "nearby-ranges"; "references" ];
        ];
    command [ "semantic"; "server"; "list" ];
    command ~hook:true
      [ "semantic"; "server"; "configure" ]
      ~options:
        [
          root;
          choice "--match" [ "extensions"; "path-globs"; "all-files" ];
          repeated "--extension" Free_argument;
          repeated "--glob" Free_argument;
          choice "--overlap" [ "same-symbol"; "nearby-ranges"; "references" ];
        ];
    command ~hook:true [ "semantic"; "server"; "enable" ];
    command ~hook:true [ "semantic"; "server"; "disable" ];
    command ~hook:true [ "semantic"; "server"; "remove" ];
    command [ "sync" ];
    command [ "relay"; "serve" ]
      ~options:
        [ path "--config"; path "--storage"; option "--listen" Free_argument ];
    command
      [ "relay"; "access"; "issue" ]
      ~options:
        [
          path "--storage";
          identifier "--repository";
          choice "--scope" [ "read"; "write" ];
          integer "--expires-in";
        ];
    command
      [ "relay"; "access"; "rotate" ]
      ~options:[ path "--storage"; identifier "--id"; integer "--expires-in" ];
    command
      [ "relay"; "access"; "revoke" ]
      ~options:[ path "--storage"; identifier "--id" ];
    command
      [ "relay"; "access"; "list" ]
      ~options:[ path "--storage"; identifier "--repository" ];
    command ~hook:true [ "device"; "create" ]
      ~options:
        [
          root;
          choice "--provider" [ "native"; "pkcs11" ];
          path "--module";
          option "--token-label" Free_argument;
          option "--key-label" Free_argument;
          identifier "--key-id";
        ];
    command ~hook:true [ "device"; "attach" ]
      ~options:
        [
          root;
          choice "--provider" [ "ssh-agent"; "pkcs11" ];
          path "--public-key";
          path "--module";
          option "--token-label" Free_argument;
          identifier "--key-id";
        ];
    command [ "device"; "custody" ] ~options:[ root; identifier "--device" ];
    command [ "device"; "show" ];
    command ~hook:true [ "device"; "enroll" ]
      ~options:
        [
          root;
          identifier "--device";
          identifier "--public-key";
          option "--username" Free_argument;
          flag "--administrator";
          identifier "--parent";
        ];
    command ~hook:true [ "device"; "revoke" ]
      ~options:[ root; identifier "--device"; identifier "--parent" ];
    command ~hook:true [ "device"; "rotate" ]
      ~options:
        [
          root;
          identifier "--device";
          identifier "--public-key";
          identifier "--parent";
        ];
    command [ "authority"; "heads" ];
    command ~hook:true
      [ "authority"; "reconcile" ]
      ~options:[ root; option "--parents" Free_argument ];
    command ~hook:true [ "recovery"; "use" ]
      ~options:
        [
          root;
          path "--package";
          option "--mnemonic" Free_argument;
          identifier "--replacement";
          identifier "--replaced";
          path "--output";
        ];
    command ~hook:true [ "recovery"; "refresh" ]
      ~options:
        [
          root;
          path "--package";
          option "--mnemonic" Free_argument;
          path "--output";
        ];
    command ~hook:true [ "user"; "register" ]
      ~options:
        [ root; identifier "--device"; option "--username" Free_argument ];
    command [ "daemon"; "start" ];
    command [ "daemon"; "status" ];
    command [ "daemon"; "stop" ];
    command [ "daemon"; "sync" ];
    command ~hook:true [ "deliver" ]
      ~options:
        [
          root;
          identifier "--id";
          identifier "--draft";
          option "--title" Free_argument;
        ];
    command ~hook:true [ "pin" ] ~options:[ root; identifier "--checkpoint" ];
    command ~hook:true [ "unpin" ] ~options:[ root; identifier "--checkpoint" ];
    command ~hook:true [ "compact" ]
      ~options:[ root; integer "--keep"; flag "--dry-run"; flag "--explain" ];
    command [ "storage"; "roots" ];
    command ~hook:true [ "storage"; "gc" ]
      ~options:[ root; flag "--dry-run"; flag "--explain"; flag "--apply" ];
    command [ "storage"; "gc"; "status" ];
    command ~hook:true
      [ "storage"; "gc"; "resume" ]
      ~options:[ root; identifier "--id" ];
    command ~hook:true
      [ "storage"; "gc"; "restore" ]
      ~options:[ root; identifier "--id" ];
    command ~hook:true
      [ "storage"; "gc"; "purge" ]
      ~options:[ root; identifier "--id" ];
    command [ "verify" ] ~options:[ root; format ];
    command [ "repair"; "plan" ]
      ~options:[ root; option "--from" Free_argument; format ];
    command [ "repair"; "apply" ]
      ~options:
        [
          root;
          identifier "--plan";
          identifier "--select";
          identifier "--approve";
          format;
        ];
    command [ "repair"; "defer" ] ~options:[ root; format ];
    command [ "watch" ];
    command [ "completion" ] ~options:[];
    command [ "hook"; "add" ]
      ~options:
        [
          root;
          option "--event"
            (Choice
               [
                 "init";
                 "save";
                 "restore";
                 "workspace-activate";
                 "workspace-update";
                 "draft-new";
                 "share";
                 "withdraw";
                 "resolve";
                 "deliver";
                 "pin";
                 "unpin";
                 "compact";
               ]);
        ];
    command [ "hook"; "list" ] ~options:[ root; format ];
    command [ "hook"; "remove" ] ~options:[ root; identifier "--id" ];
    command [ "hook"; "test" ] ~options:[ root; identifier "--id" ];
  ]

let command_paths () = List.map (fun command -> command.command_path) commands
let unique values = List.sort_uniq String.compare values

let command_words () =
  commands |> List.concat_map (fun command -> command.command_path) |> unique

let option_specs () =
  commands
  |> List.concat_map (fun command -> command.command_options)
  |> List.sort_uniq (fun left right ->
      String.compare left.option_name right.option_name)

let find path =
  List.find_opt (fun command -> command.command_path = path) commands

let valid_word value =
  String.length value > 0
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       value

let valid_option option =
  String.length option.option_name > 2
  && String.starts_with ~prefix:"--" option.option_name
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       (String.sub option.option_name 2 (String.length option.option_name - 2))

let validate specifications =
  let paths =
    List.map
      (fun command -> String.concat " " command.command_path)
      specifications
  in
  if List.length paths <> List.length (unique paths) then
    Error "CLI command specification has duplicate paths"
  else
    match
      List.find_opt
        (fun command ->
          command.command_path = []
          || (not (List.for_all valid_word command.command_path))
          || not (List.for_all valid_option command.command_options))
        specifications
    with
    | Some _ ->
        Error "CLI command specification has an invalid command or option"
    | None -> Ok ()

let shell_words values = String.concat " " values

let render_bash () =
  let words =
    shell_words
      (command_words ()
      @ (option_specs () |> List.map (fun option -> option.option_name)))
  in
  "# bash completion for yeokcham; generated from Yeokcham_v4_cli_spec\n\
   _yeokcham() {\n\
   local current=\"${COMP_WORDS[COMP_CWORD]}\"\n\
   COMPREPLY=( $(compgen -W '" ^ words
  ^ "' -- \"$current\") )\n}\ncomplete -F _yeokcham yeokcham\n"

let render_zsh () =
  let words =
    command_words ()
    @ (option_specs () |> List.map (fun option -> option.option_name))
  in
  let entries =
    words |> List.map (fun word -> "    '" ^ word ^ "'") |> String.concat "\n"
  in
  "#compdef yeokcham\n\
   # zsh completion for yeokcham; generated from Yeokcham_v4_cli_spec\n\
   _yeokcham() {\n\
   local -a candidates\n\
   candidates=(\n" ^ entries
  ^ "\n  )\n_describe -t commands 'yeokcham command or option' candidates\n}\n"

let render_fish () =
  let words =
    command_words ()
    @ (option_specs () |> List.map (fun option -> option.option_name))
  in
  let entries =
    words
    |> List.map (fun word -> "complete -c yeokcham -f -a '" ^ word ^ "'")
    |> String.concat "\n"
  in
  "# fish completion for yeokcham; generated from Yeokcham_v4_cli_spec\n\
   complete -c yeokcham -f\n" ^ entries ^ "\n"

let render_completion = function
  | Bash -> render_bash ()
  | Zsh -> render_zsh ()
  | Fish -> render_fish ()
