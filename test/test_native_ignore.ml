module S = Yeokcham_snapshot
module I = S.Ignore
module Store = Yeokcham_store

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)

let rules text =
  I.extend I.empty ~source:".yeokchamignore" ~base:[] text
  |> ok I.error_to_string

let ignored ?(directory = false) rules path =
  (I.evaluate rules ~path:(String.split_on_char '/' path) ~directory).I.ignored

let matching () =
  let cases =
    [
      ("*.tmp", "a/b.tmp", false, true);
      ("*.tmp", "a/b.tmp/c", false, true);
      ("/root", "other/root", false, false);
      ("/root", "root/child", false, true);
      ("src/*.ml", "src/deep/a.ml", false, false);
      ("src/**/x?.[ch]", "src/x1.c", false, true);
      ("src/**/x?.[ch]", "src/a/b/x2.h", false, true);
      ("src/**/x?.[ch]", "other/src/x1.c", false, false);
      ("cache/", "cache", false, false);
      ("cache/", "cache", true, true);
      ("cache/", "x/cache/a", false, true);
      ("[!a-c]*", "d.txt", false, true);
      ("[!a-c]*", "a.txt", false, false);
      ("file[0-9]", "file7", false, true);
      ("\\#note", "#note", false, true);
      ("\\!important", "!important", false, true);
      ("literal\\*", "literal*", false, true);
      ("literal\\*", "literal-x", false, false);
      ("space\\ ", "space ", false, true);
      ("space   ", "space", false, true);
      ("[]]", "]", false, true);
      ("[[]", "[", false, true);
      ("a\\?", "a?", false, true);
      ("*.bin\n!important.bin", "important.bin", false, false);
      ("*.bin\n!important.bin\nimportant.*", "important.bin", false, true);
      ("# comment\r\n\n*.tmp\r\n", "a.tmp", false, true);
    ]
  in
  List.iter
    (fun (pattern, path, directory, expected) ->
      Alcotest.(check bool)
        (Printf.sprintf "%S at %S" pattern path)
        expected
        (ignored ~directory (rules pattern) path))
    cases

let ancestry_and_sources () =
  let parent = rules "cache/\n!cache/keep.txt" in
  let decision =
    I.evaluate parent ~path:[ "cache"; "keep.txt" ] ~directory:false
  in
  Alcotest.(check bool)
    "excluded parent blocks descendant negation" true decision.I.ignored;
  Alcotest.(check bool)
    "explain blocked parent" true decision.I.blocked_by_parent;
  let rule = Option.get decision.I.rule in
  Alcotest.(check int) "effective parent rule line" 1 (I.line rule);
  let reopened = rules "cache/\n!cache/\ncache/*\n!cache/keep.txt" in
  Alcotest.(check bool)
    "reopen parent then child" false
    (ignored reopened "cache/keep.txt");
  Alcotest.(check bool)
    "other children remain excluded" true
    (ignored reopened "cache/drop.txt");
  let nested =
    I.extend (rules "*.tmp") ~source:"src/.yeokchamignore" ~base:[ "src" ]
      "!keep.tmp\n/root-only"
    |> ok I.error_to_string
  in
  Alcotest.(check bool)
    "nested precedence" false
    (ignored nested "src/sub/keep.tmp");
  Alcotest.(check bool)
    "nested scope does not escape" true
    (ignored nested "else/keep.tmp");
  Alcotest.(check bool)
    "nested anchored match" true
    (ignored nested "src/root-only");
  Alcotest.(check bool)
    "nested anchoring" false
    (ignored nested "src/sub/root-only");
  let decision =
    I.evaluate nested ~path:[ "src"; "sub"; "keep.tmp" ] ~directory:false
  in
  let rule = Option.get decision.I.rule in
  Alcotest.(check string)
    "source retained" "src/.yeokchamignore" (I.source rule);
  Alcotest.(check bool) "inclusion remains explainable" true (I.includes rule)

let malformed () =
  List.iter
    (fun pattern ->
      match
        I.extend I.empty ~source:"src/.yeokchamignore" ~base:[ "src" ]
          ("# heading\n" ^ pattern)
      with
      | Error e ->
          Alcotest.(check int) "line retained" 2 e.I.line;
          Alcotest.(check string)
            "file retained" "src/.yeokchamignore" e.I.source
      | Ok _ -> Alcotest.failf "accepted malformed %S" pattern)
    [
      "!";
      "/";
      "a//b";
      "../x";
      "a\\";
      "[abc";
      "[z-a]";
      "a\000b";
      String.make 4097 'x';
    ]

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter
        (fun n -> remove_tree (Filename.concat path n))
        (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
  | Unix.S_SOCK ->
      Unix.unlink path

let with_directory f =
  let root = Filename.temp_file "yeokcham-native-ignore-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let write root path contents =
  Out_channel.with_open_bin (Filename.concat root path) (fun out ->
      Out_channel.output_string out contents)

let snapshot_paths store snapshot =
  let rec walk prefix id =
    S.Tree.load store id |> ok S.error_to_string |> S.Tree.entries
    |> List.concat_map (fun (name, entry) ->
        let path = prefix @ [ name ] in
        match entry with
        | S.Tree.File _ -> [ String.concat "/" path ]
        | S.Tree.Directory id -> String.concat "/" path :: walk path id)
  in
  walk [] (S.Snapshot.root snapshot)

let[@warning "-4"] actual_capture () =
  with_directory (fun root ->
      let store = Store.init ~root |> ok Store.error_to_string in
      List.iter
        (fun path -> Unix.mkdir (Filename.concat root path) 0o700)
        [ "src"; "src/.yeokcham"; "cache"; ".git" ];
      write root ".yeokchamignore"
        "*.tmp\n\
         cache/\n\
         !cache/\n\
         cache/*\n\
         !cache/keep.txt\n\
         !.git/\n\
         !src/.yeokcham/\n";
      write root ".gitignore" "visible.txt\n";
      write root "visible.txt" "kept despite Git rules";
      write root "root.tmp" "excluded";
      write root "cache/drop.txt" "excluded";
      write root "cache/keep.txt" "kept";
      write root "src/.yeokchamignore" "!keep.tmp\n";
      write root "src/keep.tmp" "kept";
      write root "src/drop.tmp" "excluded";
      write root "src/.yeokcham/private" "must not be captured";
      write root ".git/private" "must not be captured";
      let _, snapshot = S.scan ~root ~store |> ok S.error_to_string in
      Alcotest.(check (list string))
        "capture scope"
        [
          ".gitignore";
          ".yeokchamignore";
          "cache";
          "cache/keep.txt";
          "src";
          "src/.yeokchamignore";
          "src/keep.tmp";
          "visible.txt";
        ]
        (snapshot_paths store snapshot);
      let explanation =
        S.explain_ignore ~root [ "src"; "keep.tmp" ] |> ok S.error_to_string
      in
      (match explanation.S.reason with
      | S.Native_rule rule ->
          Alcotest.(check string)
            "native source" "src/.yeokchamignore" (I.source rule)
      | S.Mandatory_exclusion | S.No_rule -> Alcotest.fail "lost rule source");
      let explanation =
        S.explain_ignore ~root [ ".git"; "private" ] |> ok S.error_to_string
      in
      Alcotest.(check bool)
        "metadata cannot be re-included" true explanation.S.ignored;
      write root "src/.yeokchamignore" "[broken";
      match S.scan ~root ~store with
      | Error (S.Invalid_ignore_rule e) ->
          Alcotest.(check string)
            "actionable malformed nested file" "src/.yeokchamignore" e.I.source
      | Error e -> Alcotest.fail (S.error_to_string e)
      | Ok _ -> Alcotest.fail "captured malformed rules")

let excluded_subtrees_are_not_read () =
  with_directory (fun root ->
      let store = Store.init ~root |> ok Store.error_to_string in
      Unix.mkdir (Filename.concat root "cache") 0o700;
      write root ".yeokchamignore" "cache/\n";
      Unix.symlink "/does-not-exist"
        (Filename.concat root "cache/.yeokchamignore");
      let _, snapshot = S.scan ~root ~store |> ok S.error_to_string in
      Alcotest.(check (list string))
        "excluded contents are not inspected" [ ".yeokchamignore" ]
        (snapshot_paths store snapshot);
      let explanation =
        S.explain_ignore ~root [ "cache"; ".yeokchamignore" ]
        |> ok S.error_to_string
      in
      Alcotest.(check bool)
        "explanation stops at excluded parent" true
        explanation.S.blocked_by_parent)

let () =
  Alcotest.run "Native ignore"
    [
      ( "patterns",
        [
          Alcotest.test_case "native glob and exact byte rules" `Quick matching;
          Alcotest.test_case "ancestry, nested scope and winning source" `Quick
            ancestry_and_sources;
          Alcotest.test_case "malformed rules carry file and line" `Quick
            malformed;
        ] );
      ( "capture",
        [
          Alcotest.test_case "real scanner honors native rules only" `Quick
            actual_capture;
          Alcotest.test_case "excluded subtree is opaque" `Quick
            excluded_subtrees_are_not_read;
        ] );
    ]
