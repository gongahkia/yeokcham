type color_mode = Auto | Always | Never
type tone = Plain | Muted | Accent | Good | Caution | Bad
type stream = Stdout | Stderr

let mode = ref Auto
let machine_output = ref false
let reset = "\027[0m"
let bold = "\027[1m"
let cyan = "\027[36m"
let green = "\027[32m"
let yellow = "\027[33m"
let red = "\027[31m"

let display_value value =
  if
    String.is_empty value
    || Result.is_error (Yeokcham_encoding.text value)
    || String.exists
         (function '\000' .. ' ' | '\127' | '"' | '\\' -> true | _ -> false)
         value
  then Printf.sprintf "%S" value
  else value

let configure ~mode:requested_mode ~machine_output:requested_machine_output =
  mode := requested_mode;
  machine_output := requested_machine_output

let no_color_requested () =
  match Sys.getenv_opt "NO_COLOR" with
  | Some value -> String.length value > 0
  | None -> false

let usable_terminal descriptor =
  let terminal =
    match Sys.getenv_opt "TERM" with
    | Some "dumb" -> false
    | Some _ | None -> true
  in
  terminal && try Unix.isatty descriptor with Unix.Unix_error _ -> false

let color_enabled stream =
  if !machine_output then false
  else
    match !mode with
    | Never -> false
    | Always -> true
    | Auto ->
        (not (no_color_requested ()))
        && usable_terminal
             (match stream with Stdout -> Unix.stdout | Stderr -> Unix.stderr)

let styled code value = code ^ value ^ reset

let paint tone value =
  if not (color_enabled Stdout) then value
  else
    match tone with
    | Plain -> value
    | Muted -> styled "\027[90m" value
    | Accent -> styled (bold ^ cyan) value
    | Good -> styled green value
    | Caution -> styled yellow value
    | Bad -> styled red value

let line ?(tone = Plain) value = Stdlib.print_endline (paint tone value)

let symbol ~ascii ~unicode =
  let locale =
    [ "LC_ALL"; "LC_CTYPE"; "LANG" ]
    |> List.find_map (fun name ->
        match Sys.getenv_opt name with
        | Some value when value <> "" -> Some value
        | Some _ | None -> None)
    |> Option.value ~default:"C" |> String.lowercase_ascii
  in
  let utf8 =
    String.ends_with ~suffix:"utf-8" locale
    || String.ends_with ~suffix:"utf8" locale
  in
  if utf8 && usable_terminal Unix.stdout then unicode else ascii

let terminal_width () =
  Option.bind (Sys.getenv_opt "COLUMNS") int_of_string_opt
  |> Option.fold ~none:80 ~some:(fun columns -> max 24 (min 240 columns))

let ellipsize ~max_columns value =
  let limit = max 4 max_columns in
  let rec stop offset columns =
    if offset >= String.length value then None
    else if columns >= limit - 3 then Some offset
    else
      let byte = Char.code value.[offset] in
      let length =
        if byte < 0x80 then 1
        else if byte < 0xe0 then 2
        else if byte < 0xf0 then 3
        else 4
      in
      stop
        (min (String.length value) (offset + length))
        (columns + if byte < 0x80 then 1 else 2)
  in
  match stop 0 0 with
  | None -> value
  | Some offset -> String.sub value 0 offset ^ "..."

let starts_with_any prefixes value =
  List.exists (fun prefix -> String.starts_with ~prefix value) prefixes

let first_token_end value =
  match String.index_opt value ' ' with
  | Some index -> index
  | None -> String.length value

let style_line value =
  if String.length value = 0 then value
  else if String.starts_with ~prefix:"usage:" value then
    styled (bold ^ cyan) value
  else
    let token_end = first_token_end value in
    let token = String.sub value 0 token_end in
    let rest = String.sub value token_end (String.length value - token_end) in
    let color =
      if
        starts_with_any
          [
            "save ";
            "saved ";
            "restored ";
            "verify clean";
            "workspace ";
            "runtime started";
            "received ";
            "uploaded ";
            "materialized ";
            "proposal-materialized ";
            "repair applied";
            "hook test passed";
            "gc-restored ";
            "gc-purged ";
            "credential saved";
          ]
          value
      then green
      else if
        starts_with_any
          [
            "needs-decision ";
            "availability unavailable";
            "upload pending";
            "warning:";
            "refusal ";
          ]
          value
      then yellow
      else cyan
    in
    styled (bold ^ color) token ^ rest

let style_text value =
  value |> String.split_on_char '\n' |> List.map style_line
  |> String.concat "\n"

let print_raw_string value = Stdlib.print_string value
let print_raw_endline value = Stdlib.print_endline value

let print_string value =
  if color_enabled Stdout then print_raw_string (style_text value)
  else print_raw_string value

let print_endline value = print_string (value ^ "\n")

let print_error value =
  if color_enabled Stderr then prerr_string (styled (bold ^ red) value ^ "\n")
  else prerr_endline value

let print_warning value =
  if color_enabled Stderr then prerr_string (styled (bold ^ yellow) value ^ "\n")
  else prerr_endline value
