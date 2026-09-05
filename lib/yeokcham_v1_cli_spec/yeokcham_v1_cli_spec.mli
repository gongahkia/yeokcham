(** Static, side-effect-free V1 command metadata and shell completion rendering.
    This module never invokes the client, reads a repository, or reads a
    credential provider. *)

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

val commands : command_spec list
val command_paths : unit -> string list list
val command_words : unit -> string list
val option_specs : unit -> option_spec list
val find : string list -> command_spec option
val validate : command_spec list -> (unit, string) result
val render_completion : shell -> string
