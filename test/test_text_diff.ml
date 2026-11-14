module D = Yeokcham_v1_local_service.Text_diff
let text = function D.Text hunks -> hunks | D.Opaque message -> Alcotest.fail message
let compare before after = D.compare ~before ~after
let bytes (line:D.line) = line.D.text ^ if line.D.newline then "\n" else ""

let exact_lines string =
  let pieces = String.split_on_char '\n' string in
  let rec loop = function [] | [""] -> [] | [last] -> [last] | line::rest -> (line ^ "\n")::loop rest in
  Array.of_list (loop pieces)

let apply before hunks =
  let original = exact_lines before in
  let cursor = ref 0 and output = Buffer.create (String.length before) in
  List.iter (fun (hunk:D.hunk) ->
    let start = hunk.D.old_start - if hunk.D.old_count=0 then 0 else 1 in
    if start < !cursor then Alcotest.fail "overlapping display hunks";
    for i= !cursor to start-1 do Buffer.add_string output original.(i) done;
    cursor:=start;
    let old_count = ref 0 and new_count = ref 0 in
    List.iter (fun (line:D.line) ->
      let value = bytes line in
      (match line.D.kind with
      | D.Context | D.Removed ->
          Alcotest.(check string) "hunk matches original line" original.(!cursor) value;
          incr cursor;incr old_count
      | D.Added -> ());
      (match line.D.kind with
      | D.Context | D.Added -> Buffer.add_string output value;incr new_count
      | D.Removed -> ())) hunk.D.lines;
    Alcotest.(check int) "old line count" hunk.D.old_count !old_count;
    Alcotest.(check int) "new line count" hunk.D.new_count !new_count) hunks;
  for i= !cursor to Array.length original-1 do Buffer.add_string output original.(i) done;
  Buffer.contents output

let repeated_lines_and_ties () =
  let hunks = compare "a\nb\na\n" "a\na\nb\n" |> text in
  let operations = List.concat_map (fun (h:D.hunk) -> h.D.lines) hunks |> List.map (fun (l:D.line) ->
    (match l.D.kind with D.Context -> " " | D.Removed -> "-" | D.Added -> "+") ^ l.D.text) in
  Alcotest.(check (list string)) "deletion-first LCS tie" [" a";"-b";" a";"+b"] operations

let byte_fidelity () =
  List.iter (fun (before,after) ->
    let hunks = compare before after |> text in
    Alcotest.(check string) "exact byte result" after (apply before hunks))
    ["","a";"a","";"a\n","a";"a","a\n";"a\r\n","a\n";
      "\n\n","\n";"a\r\nb\r\n","a\r\nc\r\n";"hello\n","héllo\n"]

let context_and_ranges () =
  let before = List.init 40 (fun i -> string_of_int i ^ "\n") |> String.concat "" in
  let make changes = List.init 40 (fun i -> (if List.mem i changes then "changed" else string_of_int i)^"\n") |> String.concat "" in
  List.iter (fun (changes,count) ->
    let after = make changes in
    let hunks = compare before after |> text in
    Alcotest.(check int) "hunk count" count (List.length hunks);
    Alcotest.(check string) "context reconstructs exact target" after (apply before hunks)) [[5;30],2;[5;8],1];
  let first = List.hd (compare before (make [5]) |> text) in
  Alcotest.(check int) "three context lines before edit" 3 first.D.old_start

let display_limits () =
  let opaque before after = match compare before after with
    | D.Opaque _ -> () | D.Text _ -> Alcotest.fail "unbounded or opaque input treated as text" in
  opaque "a\000b" "changed";
  opaque "\255" "changed";
  opaque "" (String.make (D.max_bytes+1) 'a');
  let numbered prefix = List.init 3000 (fun i -> prefix ^ string_of_int i ^ "\n") |> String.concat "" in
  opaque (numbered "old") (numbered "new")

let property =
  let open QCheck.Gen in
  let input = map (fun (lines,final_newline) -> String.concat "\n" lines ^
    if final_newline && lines<>[] then "\n" else "")
    (pair (list_size (int_bound 20) (oneof_list ["a";"b";"c";"";"héllo";"line\r"])) bool) in
  QCheck.Test.make ~count:400 ~name:"display hunks preserve exact before/after bytes"
    (QCheck.make (pair input input)) (fun (before,after) ->
      let hunks = compare before after |> text in apply before hunks = after)

let () = Alcotest.run "Local text differences" ["display",[
  Alcotest.test_case "repeated lines and deterministic ties" `Quick repeated_lines_and_ties;
  Alcotest.test_case "CRLF, Unicode and final newline" `Quick byte_fidelity;
  Alcotest.test_case "context and separate hunk ranges" `Quick context_and_ranges;
  Alcotest.test_case "opaque and bounded fallback" `Quick display_limits;
  QCheck_alcotest.to_alcotest property;
]]
