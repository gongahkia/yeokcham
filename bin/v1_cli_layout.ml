module Output = V1_cli_output
module Diff = Yeokcham_v1_local_service.Text_diff

type graph_row = {
  prefix : string;
  node_column : int;
  rails : string;
  connectors : string list;
}

let history_graph nodes =
  let lanes = ref [] in
  let locate id = List.find_index (fun value -> value = Some id) !lanes in
  let set index value =
    lanes :=
      List.mapi (fun i previous -> if i = index then value else previous) !lanes
  in
  let prefix ?node () =
    let buffer = Bytes.make (2 * List.length !lanes) ' ' in
    List.iteri
      (fun i value -> if value <> None then Bytes.set buffer (2 * i) '|')
      !lanes;
    Option.iter (fun index -> Bytes.set buffer (2 * index) 'o') node;
    Bytes.to_string buffer
  in
  let rows =
    List.map
      (fun (id, parent) ->
        let index =
          match locate id with
          | Some index -> index
          | None -> (
              match List.find_index Option.is_none !lanes with
              | Some index ->
                  set index (Some id);
                  index
              | None ->
                  let index = List.length !lanes in
                  lanes := !lanes @ [ Some id ];
                  index)
        in
        let node_prefix = prefix ~node:index () in
        let connectors =
          match parent with
          | None ->
              set index None;
              []
          | Some parent -> (
              match locate parent with
              | None ->
                  set index (Some parent);
                  []
              | Some target when target = index -> []
              | Some target ->
                  set index None;
                  let step = if target < index then -1 else 1 in
                  let rec connect position acc =
                    if position = 2 * target then List.rev acc
                    else
                      let row = Bytes.of_string (prefix ()) in
                      Bytes.set row position
                        (if Bytes.get row position = '|' then 'X'
                         else if step < 0 then '/'
                         else '\\');
                      connect (position + step) (Bytes.to_string row :: acc)
                  in
                  connect ((2 * index) + step) [])
        in
        let rails = prefix () in
        (* keep occupied lanes fixed: collapsing a hole would invent an edge. *)
        lanes := List.rev !lanes |> List.drop_while Option.is_none |> List.rev;
        { prefix = node_prefix; node_column = 2 * index; rails; connectors })
      nodes
  in
  let continuations =
    List.mapi
      (fun index id ->
        Option.map
          (fun id ->
            let row = Bytes.of_string (prefix ()) in
            Bytes.set row (2 * index) ':';
            (Bytes.to_string row, id))
          id)
      !lanes
    |> List.filter_map Fun.id
  in
  (rows, continuations)

let marker = function
  | Diff.Context -> " "
  | Diff.Removed -> "-"
  | Diff.Added -> "+"

let tone = function
  | Diff.Context -> Output.Plain
  | Diff.Removed -> Output.Bad
  | Diff.Added -> Output.Good

let diff_hunks ~columns ~escape hunks =
  let wide = columns >= 100 in
  List.concat_map
    (fun hunk ->
      let digits =
        max
          (String.length
             (string_of_int (hunk.Diff.old_start + hunk.Diff.old_count)))
          (String.length
             (string_of_int (hunk.Diff.new_start + hunk.Diff.new_count)))
      in
      let number = function
        | None -> String.make digits ' '
        | Some n -> Printf.sprintf "%*d" digits n
      in
      let old = ref hunk.Diff.old_start and fresh = ref hunk.Diff.new_start in
      let numbered =
        List.map
          (fun line ->
            let before =
              if line.Diff.kind = Diff.Added then None else Some !old
            in
            let after =
              if line.Diff.kind = Diff.Removed then None else Some !fresh
            in
            if before <> None then incr old;
            if after <> None then incr fresh;
            (line, before, after))
          hunk.Diff.lines
      in
      let heading =
        Printf.sprintf "@@ -%d,%d +%d,%d @@" hunk.Diff.old_start
          hunk.Diff.old_count hunk.Diff.new_start hunk.Diff.new_count
      in
      if not wide then
        heading
        :: List.concat_map
             (fun (line, before, after) ->
               let prefix =
                 number before ^ " " ^ number after ^ " "
                 ^ marker line.Diff.kind
               in
               let continuation =
                 String.make (String.length prefix - 1) ' ' ^ ">"
               in
               let rows =
                 Output.wrap
                   ~max_columns:(max 2 (columns - String.length prefix))
                   (escape line.Diff.text)
               in
               List.mapi
                 (fun index text ->
                   Output.paint (tone line.Diff.kind)
                     ((if index = 0 then prefix else continuation) ^ text))
                 rows
               @
               if line.Diff.newline then []
               else
                 Output.wrap ~max_columns:columns "\\ No newline at end of file")
             numbered
      else
        let left_width = (columns - 3) / 2 in
        let right_width = columns - 3 - left_width in
        let join left right =
          Output.pad_right ~columns:left_width left ^ " | " ^ right
        in
        let cell width = function
          | None -> []
          | Some (line, n) ->
              let prefix = number (Some n) ^ " " ^ marker line.Diff.kind in
              let continuation = String.make (digits + 1) ' ' ^ ">" in
              Output.wrap
                ~max_columns:(max 2 (width - String.length prefix))
                (escape line.Diff.text)
              |> List.mapi (fun i text ->
                  Output.paint (tone line.Diff.kind)
                    ((if i = 0 then prefix else continuation) ^ text))
              |> fun rows ->
              rows
              @
              if line.Diff.newline then []
              else Output.wrap ~max_columns:width "\\ No newline at end of file"
        in
        let rec pair left right =
          match (left, right) with
          | [], [] -> []
          | l :: ls, [] -> join l "" :: pair ls []
          | [], r :: rs -> join "" r :: pair [] rs
          | l :: ls, r :: rs -> join l r :: pair ls rs
        in
        let rec rows = function
          | [] -> []
          | (line, before, after) :: rest when line.Diff.kind = Diff.Context ->
              pair
                (cell left_width (Option.map (fun n -> (line, n)) before))
                (cell right_width (Option.map (fun n -> (line, n)) after))
              @ rows rest
          | remaining ->
              let is_change (line, _, _) = line.Diff.kind <> Diff.Context in
              let changes = List.take_while is_change remaining in
              let rest = List.drop_while is_change remaining in
              let removed =
                List.filter_map
                  (fun (line, before, _) ->
                    Option.map (fun n -> (line, n)) before)
                  changes
              in
              let added =
                List.filter_map
                  (fun (line, _, after) ->
                    Option.map (fun n -> (line, n)) after)
                  changes
              in
              let rec changed left right =
                match (left, right) with
                | [], [] -> []
                | l :: ls, [] ->
                    pair (cell left_width (Some l)) [] @ changed ls []
                | [], r :: rs ->
                    pair [] (cell right_width (Some r)) @ changed [] rs
                | l :: ls, r :: rs ->
                    pair (cell left_width (Some l)) (cell right_width (Some r))
                    @ changed ls rs
              in
              changed removed added @ rows rest
        in
        heading :: join "Before" "After" :: rows numbered)
    hunks
