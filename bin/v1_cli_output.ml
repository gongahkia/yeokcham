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
    | Muted -> value
    | Accent -> styled (bold ^ cyan) value
    | Good -> styled green value
    | Caution -> styled yellow value
    | Bad -> styled red value

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

external native_terminal_width : unit -> int = "yeokcham_cli_terminal_width"
external character_width : int -> int = "yeokcham_cli_character_width"

let terminal_width () =
  let native = native_terminal_width () in
  if native > 0 then native
  else
    Option.bind (Sys.getenv_opt "COLUMNS") int_of_string_opt
    |> Option.fold ~none:80 ~some:(fun columns ->
        if columns > 0 then min 1000 columns else 80)

(* only renderer-owned SGR sequences are accepted here; user controls are escaped
   before layout. Keep the sequences together so wrapping cannot split ANSI. *)
let atoms value =
  let rec scan offset acc =
    if offset >= String.length value then List.rev acc
    else if value.[offset] = '\027' then
      match String.index_from_opt value offset 'm' with
      | Some finish ->
          scan (finish + 1)
            ((String.sub value offset (finish - offset + 1), 0) :: acc)
      | None -> scan (offset + 1) (("?", 1) :: acc)
    else
      let decoded = String.get_utf_8_uchar value offset in
      let length = Uchar.utf_decode_length decoded in
      let character = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
      let text = String.sub value offset length in
      let width = if character < 128 then 1 else character_width character in
      scan (offset + length) ((text, width) :: acc)
  in
  scan 0 []

let display_width value =
  List.fold_left (fun total (_, width) -> total + width) 0 (atoms value)

let wrap ?(words = false) ~max_columns value =
  let limit = max 2 max_columns in
  let buffer = Buffer.create (String.length value) in
  let rows = ref [] and columns = ref 0 in
  let source_columns = ref 0 in
  let flush () =
    rows := Buffer.contents buffer :: !rows;
    Buffer.clear buffer;
    columns := 0
  in
  let emit (text, width) =
    (if width > 0 && !columns + width > limit then
       let previous = Buffer.contents buffer in
       match if words then String.rindex_opt previous ' ' else None with
       | Some index when index > 0 ->
           let tail =
             String.sub previous (index + 1) (String.length previous - index - 1)
           in
           Buffer.truncate buffer index;
           flush ();
           Buffer.add_string buffer tail;
           columns := display_width tail
       | Some _ | None -> flush ());
    if width > 0 && !columns + width > limit then flush ();
    Buffer.add_string buffer text;
    columns := !columns + width
  in
  List.iter
    (fun (text, width) ->
      if text = "\n" then (
        flush ();
        source_columns := 0)
      else if text = "\t" then (
        let spaces = 4 - (!source_columns mod 4) in
        for _ = 1 to spaces do
          emit (" ", 1)
        done;
        source_columns := !source_columns + spaces)
      else (
        emit (text, width);
        source_columns := !source_columns + width))
    (atoms value);
  flush ();
  List.rev !rows

let pad_right ~columns value =
  value ^ String.make (max 0 (columns - display_width value)) ' '

let line ?(tone = Plain) value =
  let width = terminal_width () in
  wrap ~words:true ~max_columns:width value
  |> List.iter (fun row -> Stdlib.print_endline (paint tone row))

let ellipsize ~max_columns value =
  let limit = max 4 max_columns in
  if display_width value <= limit then value
  else
    let rec take columns = function
      | [] -> ""
      | (text, width) :: rest ->
          if columns + width > limit - 3 then "..."
          else text ^ take (columns + width) rest
    in
    take 0 (atoms value)

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
