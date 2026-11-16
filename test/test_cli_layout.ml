module L = V1_cli_layout
module O = V1_cli_output
module D = Yeokcham_v1_local_service.Text_diff

let graph_shapes () =
  let rows, remaining =
    L.history_graph [ (3L, Some 1L); (2L, Some 1L); (1L, Some 0L); (0L, None) ]
  in
  Alcotest.(check (list string))
    "fork joins at its actual parent"
    [ "o "; "| o "; "|/  "; "o "; "o " ]
    (List.concat_map (fun row -> row.L.prefix :: row.L.connectors) rows);
  Alcotest.(check int)
    "no fabricated ancestor below root" 0 (List.length remaining);
  let _, remaining = L.history_graph [ (3L, Some 1L); (2L, Some 1L) ] in
  Alcotest.(check (list (pair string int64)))
    "page continues to exact parent"
    [ (": ", 1L) ]
    remaining;
  let rows, _ =
    L.history_graph
      [ (8L, Some 6L); (7L, Some 5L); (6L, Some 5L); (5L, None); (0L, None) ]
  in
  Alcotest.(check (list string))
    "right join and independent root"
    [ "o "; "| o "; "o | "; " \\| "; "  o "; "o " ]
    (List.concat_map (fun row -> row.L.prefix :: row.L.connectors) rows)

(* follow the rendered edges, independently of the layout's lane allocation. *)
let graph_topology nodes =
  let rows, remaining = L.history_graph nodes in
  let rendered =
    List.map2
      (fun (id, _) row ->
        (row.L.prefix, Some id, false)
        :: List.map (fun text -> (text, None, false)) row.L.connectors)
      nodes rows
    |> List.concat
    |> fun rows ->
    rows @ List.map (fun (prefix, id) -> (prefix, Some id, true)) remaining
    |> Array.of_list
  in
  let char text position =
    if position < 0 || position >= String.length text then ' '
    else text.[position]
  in
  let rec trace index position direction =
    if index >= Array.length rendered then None
    else
      let text, id, continuation = rendered.(index) in
      let at = if direction = 0 then position else position + direction in
      match char text at with
      | 'o' when not continuation -> id
      | ':' when continuation -> id
      | '|' -> trace (index + 1) at 0
      | 'X' -> trace (index + 1) at direction
      | '/' -> trace (index + 1) at (-1)
      | '\\' -> trace (index + 1) at 1
      | _ when direction = 0 && char text (position - 1) = '/' ->
          trace (index + 1) (position - 1) (-1)
      | _ when direction = 0 && char text (position + 1) = '\\' ->
          trace (index + 1) (position + 1) 1
      | _ -> None
  in
  List.for_all
    (fun (id, parent) ->
      match parent with
      | None -> true
      | Some parent ->
          let index =
            Array.find_index
              (fun (_, row_id, continuation) ->
                row_id = Some id && not continuation)
              rendered
            |> Option.get
          in
          let text, _, _ = rendered.(index) in
          let column = String.index text 'o' in
          trace (index + 1) column 0 = Some parent)
    nodes

let forest =
  QCheck.make
    ~print:(fun nodes ->
      String.concat ";"
        (List.map
           (fun (id, p) ->
             Printf.sprintf "%Ld->%s" id
               (Option.fold ~none:"root" ~some:Int64.to_string p))
           nodes))
    QCheck.Gen.(
      map
        (fun choices ->
          List.mapi
            (fun i choice ->
              ( Int64.of_int (i + 1),
                if choice mod 7 = 0 then None
                else Some (Int64.of_int (choice mod (i + 1))) ))
            choices
          |> List.rev)
        (list_size (int_range 1 200) nat))

let text_hunks before after =
  match D.compare ~before ~after with
  | D.Text hunks -> hunks
  | D.Opaque reason -> Alcotest.fail reason

let split_diff () =
  let rows =
    L.diff_hunks ~columns:100 ~escape:Fun.id
      (text_hunks "stay\nold\ntail\n" "stay\nnew\nextra\ntail\n")
  in
  let join left right = O.pad_right ~columns:48 left ^ " | " ^ right in
  Alcotest.(check (list string))
    "paired replacements, insertions, context and numbers"
    [
      "@@ -1,3 +1,4 @@";
      join "Before" "After";
      join "1  stay" "1  stay";
      join "2 -old" "2 +new";
      join "" "3 +extra";
      join "3  tail" "4  tail";
    ]
    rows;
  List.iter
    (fun text ->
      Alcotest.(check bool)
        "within actual width" true
        (O.display_width text <= 100))
    rows

let widths () =
  Alcotest.(check int) "CJK width" 4 (O.display_width "你好");
  Alcotest.(check int) "accent and combining mark" 2 (O.display_width "éé");
  Alcotest.(check int)
    "ANSI is zero width" 3
    (O.display_width "\027[31mred\027[0m");
  Alcotest.(check string)
    "a fitting label is intact" "abcde"
    (O.ellipsize ~max_columns:5 "abcde");
  Alcotest.(check string)
    "truncation remains within cell" "你..."
    (O.ellipsize ~max_columns:5 "你好你好");
  Alcotest.(check (list string))
    "wide characters stay whole" [ "你好"; "世界" ]
    (O.wrap ~max_columns:4 "你好世界");
  Alcotest.(check (list string))
    "tabs at boundary are retained" [ "abcd"; "    "; "x" ]
    (O.wrap ~max_columns:4 "abcd\tx");
  Alcotest.(check (list string))
    "a tab crossing the wrap retains all indentation" [ "abcde "; "  f" ]
    (O.wrap ~max_columns:6 "abcde\tf")

let long_diff () =
  let before = String.make 139 'x' ^ "end-old"
  and after = String.make 156 'y' ^ "end-new" in
  let hunks = text_hunks before after in
  List.iter
    (fun columns ->
      let rows = L.diff_hunks ~columns ~escape:Fun.id hunks in
      List.iter
        (fun text ->
          Alcotest.(check bool)
            "long rows stay within width" true
            (O.display_width text <= columns))
        rows;
      let contents = String.concat "\n" rows in
      Alcotest.(check bool) "no truncation" false (String.contains contents '.');
      Alcotest.(check bool)
        "nonterminated lines identified" true
        (String.contains contents '\\'))
    [ 24; 40; 80; 99; 100; 120; 200 ]

let tab_wrapping =
  let input =
    QCheck.(
      pair (int_range 2 100)
        (string_of (Gen.oneof_list [ 'a'; ' '; '\t'; 'b'; 'c' ])))
  in
  QCheck.Test.make ~name:"hard wrapping preserves all expanded tab spaces"
    ~count:500 input (fun (columns, source) ->
      let expected = Buffer.create (String.length source) in
      String.iter
        (fun c ->
          if c = '\t' then
            Buffer.add_string expected
              (String.make (4 - (Buffer.length expected mod 4)) ' ')
          else Buffer.add_char expected c)
        source;
      String.concat "" (O.wrap ~max_columns:columns source)
      = Buffer.contents expected)

let () =
  O.configure ~mode:O.Never ~machine_output:false;
  Alcotest.run "CLI layout"
    [
      ( "rendering",
        [
          Alcotest.test_case "history graph shapes" `Quick graph_shapes;
          Alcotest.test_case "numbered split diff" `Quick split_diff;
          Alcotest.test_case "display widths and wrapping" `Quick widths;
          Alcotest.test_case "long diff at layout boundaries" `Quick long_diff;
        ] );
      ( "properties",
        [
          QCheck_alcotest.to_alcotest
            (QCheck.Test.make ~name:"every drawn edge reaches its real parent"
               ~count:500 forest graph_topology);
          QCheck_alcotest.to_alcotest tab_wrapping;
        ] );
    ]
