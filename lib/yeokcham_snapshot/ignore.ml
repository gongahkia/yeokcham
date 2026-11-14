type error = { source : string; line : int; pattern : string; message : string }

let error_to_string e =
  Printf.sprintf "%S:%d: invalid ignore rule %S: %s" e.source e.line e.pattern
    e.message

type token = Literal of char | Star | Any | Class of bool * (char * char) list
type component = Glob of token array | Recursive

type rule = {
  rule_source : string;
  rule_line : int;
  rule_pattern : string;
  base : string list;
  includes : bool;
  basename : bool;
  directory_only : bool;
  components : component array;
}

type t = rule list

let empty = []
let source (r : rule) = r.rule_source
let line (r : rule) = r.rule_line
let pattern (r : rule) = r.rule_pattern
let includes r = r.includes
let ( let* ) = Result.bind

let trim_trailing_spaces value =
  let rec backslashes i n =
    if i >= 0 && value.[i] = '\\' then backslashes (i - 1) (n + 1) else n
  in
  let rec finish n =
    if n > 0 && value.[n - 1] = ' ' && backslashes (n - 2) 0 mod 2 = 0 then
      finish (n - 1)
    else n
  in
  String.sub value 0 (finish (String.length value))

let component value =
  if value = "**" then Ok Recursive
  else
    let length = String.length value in
    let char_at i =
      if i >= length then Error "dangling escape"
      else if value.[i] = '\\' then
        if i + 1 >= length then Error "dangling escape"
        else Ok (value.[i + 1], true, i + 2)
      else Ok (value.[i], false, i + 1)
    in
    let bracket start =
      let negated =
        start < length && (value.[start] = '!' || value.[start] = '^')
      in
      let start = if negated then start + 1 else start in
      let rec collect i reversed =
        if i >= length then Error "unclosed bracket class"
        else if value.[i] = ']' && reversed <> [] then
          let chars = List.rev reversed in
          let rec ranges reversed = function
            | (a, _) :: ('-', false) :: (b, _) :: rest ->
                if a > b then Error "descending bracket range"
                else ranges ((a, b) :: reversed) rest
            | (a, _) :: rest -> ranges ((a, a) :: reversed) rest
            | [] -> Ok (List.rev reversed)
          in
          let* ranges = ranges [] chars in
          Ok (Class (negated, ranges), i + 1)
        else
          let* c, quoted, next = char_at i in
          collect next ((c, quoted) :: reversed)
      in
      collect start []
    in
    let rec parse i reversed =
      if i = length then Ok (Glob (Array.of_list (List.rev reversed)))
      else
        match value.[i] with
        | '\\' ->
            let* c, _, next = char_at i in
            parse next (Literal c :: reversed)
        | '*' -> parse (i + 1) (Star :: reversed)
        | '?' -> parse (i + 1) (Any :: reversed)
        | '[' ->
            let* token, next = bracket (i + 1) in
            parse next (token :: reversed)
        | c -> parse (i + 1) (Literal c :: reversed)
    in
    parse 0 []

let parse ~source ~base ~line original =
  let fail message = Error { source; line; pattern = original; message } in
  let raw =
    if String.ends_with ~suffix:"\r" original then
      String.sub original 0 (String.length original - 1)
    else original
  in
  let raw = trim_trailing_spaces raw in
  if raw = "" || raw.[0] = '#' then Ok None
  else if String.length raw > 4096 then fail "rule exceeds 4096 bytes"
  else if String.contains raw '\000' then fail "NUL byte"
  else
    let includes = raw.[0] = '!' in
    let raw =
      if includes then String.sub raw 1 (String.length raw - 1) else raw
    in
    if raw = "" then fail "missing pattern after !"
    else
      let anchored = raw.[0] = '/' in
      let raw =
        if anchored then String.sub raw 1 (String.length raw - 1) else raw
      in
      let directory_only = String.ends_with ~suffix:"/" raw in
      let raw =
        if directory_only then String.sub raw 0 (String.length raw - 1) else raw
      in
      let parts = String.split_on_char '/' raw in
      if List.exists (fun p -> p = "" || p = "." || p = "..") parts then
        fail "empty or traversing path component"
      else
        let rec compile reversed = function
          | [] -> Ok (Array.of_list (List.rev reversed))
          | part :: rest -> (
              match component part with
              | Error message -> fail message
              | Ok c -> compile (c :: reversed) rest)
        in
        let* components = compile [] parts in
        Ok
          (Some
             {
               rule_source = source;
               rule_line = line;
               rule_pattern = original;
               base;
               includes;
               basename = (not anchored) && List.length parts = 1;
               directory_only;
               components;
             })

let extend inherited ~source ~base contents =
  let rec loop line reversed = function
    | [] -> Ok (inherited @ List.rev reversed)
    | original :: rest ->
        let* parsed = parse ~source ~base ~line original in
        loop (line + 1)
          (match parsed with None -> reversed | Some r -> r :: reversed)
          rest
  in
  loop 1 [] (String.split_on_char '\n' contents)

let match_component tokens name =
  let length = String.length name in
  let previous = ref (Array.make (length + 1) false) in
  !previous.(0) <- true;
  Array.iter
    (fun token ->
      let current = Array.make (length + 1) false in
      for j = 0 to length do
        current.(j) <-
          (match token with
          | Star -> !previous.(j) || (j > 0 && current.(j - 1))
          | Literal c -> j > 0 && !previous.(j - 1) && name.[j - 1] = c
          | Any -> j > 0 && !previous.(j - 1)
          | Class (negated, ranges) ->
              j > 0
              && !previous.(j - 1)
              && List.exists
                   (fun (a, b) -> a <= name.[j - 1] && name.[j - 1] <= b)
                   ranges
                 <> negated)
      done;
      previous := current)
    tokens;
  !previous.(length)

let rec relative base path =
  match (base, path) with
  | [], path -> Some path
  | b :: bs, p :: ps when b = p -> relative bs ps
  | _ -> None

let matches rule path directory =
  if rule.directory_only && not directory then false
  else
    match relative rule.base path with
    | None | Some [] -> false
    | Some names ->
        if rule.basename then
          match rule.components.(0) with
          | Glob tokens -> match_component tokens (List.hd (List.rev names))
          | Recursive -> true
        else
          let names = Array.of_list names in
          let previous = ref (Array.make (Array.length names + 1) false) in
          !previous.(0) <- true;
          Array.iter
            (fun component ->
              let current = Array.make (Array.length names + 1) false in
              for j = 0 to Array.length names do
                current.(j) <-
                  (match component with
                  | Recursive -> !previous.(j) || (j > 0 && current.(j - 1))
                  | Glob tokens ->
                      j > 0
                      && !previous.(j - 1)
                      && match_component tokens names.(j - 1))
              done;
              previous := current)
            rule.components;
          !previous.(Array.length names)

type decision = { ignored : bool; rule : rule option; blocked_by_parent : bool }

let evaluate rules ~path ~directory =
  let direct path directory =
    List.fold_left
      (fun decision rule ->
        if matches rule path directory then
          {
            ignored = not rule.includes;
            rule = Some rule;
            blocked_by_parent = false;
          }
        else decision)
      { ignored = false; rule = None; blocked_by_parent = false }
      rules
  in
  let rec ancestors prefix = function
    | [] -> direct prefix directory
    | [ name ] -> direct (prefix @ [ name ]) directory
    | name :: rest ->
        let prefix = prefix @ [ name ] in
        let decision = direct prefix true in
        if decision.ignored then { decision with blocked_by_parent = true }
        else ancestors prefix rest
  in
  ancestors [] path
