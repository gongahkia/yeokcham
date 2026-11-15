module C = Yeokcham_v1_composition
module L = C.Line_hunks
module S = Yeokcham_snapshot
module Raw = Yeokcham_store
module Core = Yeokcham_v1_model.Core
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope

let ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let composed value = ok C.error_to_string value
let lines value = ok Fun.id value
let rejected label = function Error _ -> () | Ok _ -> Alcotest.fail label

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter
        (fun name -> remove (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_store f =
  let root = Filename.temp_file "yeokcham-composition-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () -> f root (Raw.init ~root |> ok Raw.error_to_string))

let file store ?(mode = S.Regular) bytes =
  let content = S.Content.store store bytes |> ok S.error_to_string in
  C.File { mode; content }

let tree values = C.tree values |> composed

let bytes store path value =
  match List.assoc path (C.entries value) with
  | C.File { content; _ } ->
      S.Content.load store content |> ok S.error_to_string
  | C.Directory -> Alcotest.fail "expected a file"

let golden_hunks () =
  let hunks = L.diff ~base:"a\nb\na\n" ~result:"a\na\nb\n" |> lines in
  Alcotest.(check (list (pair int int)))
    "deletion-first tie"
    [ (1, 2); (3, 3) ]
    (List.map (fun h -> (h.L.first, h.L.last)) hunks);
  Alcotest.(check (list (list string)))
    "exact replacements" [ []; [ "b\n" ] ]
    (List.map (fun h -> h.L.replacement) hunks);
  List.iter
    (fun (base, result) ->
      let hunks = L.diff ~base ~result |> lines in
      Alcotest.(check string)
        "byte-exact final newline/CRLF" result
        (L.apply ~base hunks |> lines))
    [
      ("", "x");
      ("x", "");
      ("a\r\nb\r\n", "a\r\nB\r\n");
      ("a\n", "a");
      ("a", "a\n");
      ("\n\n", "\n");
      ("héllo\n", "hallo\n");
    ]

let set_composition () =
  let base = "a\nb\nc\nd\n"
  and left = "A\nb\nc\nd\n"
  and right = "a\nb\nc\nD\n" in
  List.iter
    (fun variants ->
      Alcotest.(check string)
        "set order does not choose contents" "A\nb\nc\nD\n"
        (L.merge ~base ~variants |> lines))
    [ [ left; right ]; [ right; left ]; [ left; base; right; left ] ];
  rejected "different boundary insertions combined"
    (L.merge ~base:"a\nb\n" ~variants:[ "a\nx\nb\n"; "a\ny\nb\n" ]);
  rejected "insertion touching replacement was guessed"
    (L.merge ~base:"a\nb\n" ~variants:[ "a\nx\nb\n"; "a\nB\n" ]);
  Alcotest.(check string)
    "adjacent replacements combine" "A\nB\n"
    (L.merge ~base:"a\nb\n" ~variants:[ "A\nb\n"; "a\nB\n" ] |> lines);
  Alcotest.(check string)
    "identical insertions coalesce" "a\nx\nb\n"
    (L.merge ~base:"a\nb\n" ~variants:[ "a\nx\nb\n"; "a\nx\nb\n" ] |> lines)

let bounds () =
  rejected "opaque NUL used as text" (L.diff ~base:"\000" ~result:"x");
  rejected "invalid UTF8 used as text" (L.diff ~base:"\255" ~result:"x");
  rejected "oversize text alignment"
    (L.diff ~base:(String.make (L.max_bytes + 1) 'a') ~result:"x");
  let many line = String.concat "" (List.init 2100 (fun _ -> line)) in
  rejected "cell bound bypassed"
    (L.diff ~base:(many "x\n") ~result:(many "y\n"));
  Alcotest.(check string)
    "one changed opaque side uses whole-path rule" "\000large"
    (L.merge ~base:"\000base" ~variants:[ "\000base"; "\000large" ] |> lines)

let exact_tree_merge () =
  with_store (fun _ store ->
      let make note mode binary =
        tree
          [
            ([ "dir" ], C.Directory);
            ([ "dir"; "note" ], file store ~mode note);
            ([ "blob" ], file store binary);
            ([ "empty" ], C.Directory);
            ([ "link" ], file store ~mode:S.Symlink "../dir/note");
          ]
      in
      let base = make "a\nb\nc\n" S.Regular "\000old" in
      let left = make "A\nb\nc\n" S.Executable "\000old"
      and right = make "a\nb\nC\n" S.Regular "\000new" in
      let merged = C.merge store ~base ~variants:[ left; right ] |> composed in
      Alcotest.(check string)
        "independent text edits" "A\nb\nC\n"
        (bytes store [ "dir"; "note" ] merged);
      Alcotest.(check string)
        "opaque whole-path change" "\000new"
        (bytes store [ "blob" ] merged);
      (match List.assoc [ "dir"; "note" ] (C.entries merged) with
      | C.File { mode; _ } ->
          Alcotest.(check bool)
            "executable change retained" true (mode = S.Executable)
      | C.Directory -> Alcotest.fail "executable change lost");
      let id = C.store store merged |> composed in
      let loaded = C.load store id |> composed in
      Alcotest.(check (list (list string)))
        "empty dirs and symlink survive"
        (List.map fst (C.entries merged))
        (List.map fst (C.entries loaded));
      Alcotest.(check string)
        "exact stored bytes" "A\nb\nC\n"
        (bytes store [ "dir"; "note" ] loaded);
      let conflict = make "Z\nb\nc\n" S.Regular "\000other" in
      rejected "text/opaque conflicts were ordered into a winner"
        (C.merge store ~base ~variants:[ left; conflict ]))

let structural_conflicts () =
  with_store (fun _ store ->
      let base =
        tree [ ([ "d" ], C.Directory); ([ "d"; "a" ], file store "A") ]
      in
      let removed = tree []
      and edited =
        tree [ ([ "d" ], C.Directory); ([ "d"; "a" ], file store "B") ]
      in
      rejected "delete versus descendant edit"
        (C.merge store ~base ~variants:[ removed; edited ]);
      let replaced = tree [ ([ "d" ], file store "new file") ] in
      rejected "file versus edited descendant"
        (C.merge store ~base ~variants:[ replaced; edited ]);
      let actual =
        C.merge store ~base ~variants:[ replaced; base ] |> composed
      in
      Alcotest.(check string)
        "unchanged other side permits a type change" "new file"
        (bytes store [ "d" ] actual);
      rejected "missing ancestor accepted"
        (C.tree [ ([ "d"; "child" ], file store "x") ]);
      rejected "metadata path accepted"
        (C.tree [ ([ ".yeokcham" ], C.Directory) ]);
      rejected "nested metadata path accepted"
        (C.tree [ ([ "d" ], C.Directory); ([ "d"; ".yeokcham" ], C.Directory) ]))

let selected_scope () =
  with_store (fun _ store ->
      let base =
        tree
          [
            ([ "public" ], file store "base");
            ([ "ignored" ], file store "old ignored");
            ([ "gone" ], file store "delete");
          ]
      in
      let observed =
        tree
          [
            ([ "public" ], file store "new");
            ([ "private" ], file store "SENTINEL");
            ([ "folder" ], C.Directory);
            ([ "folder"; "chosen" ], file store "chosen");
            ([ "folder"; "private" ], file store "SENTINEL");
          ]
      in
      let selected =
        C.select ~base ~observed
          ~paths:[ [ "public" ]; [ "gone" ]; [ "folder"; "chosen" ] ]
          ~excluded:[]
        |> composed
      in
      Alcotest.(check (list (list string)))
        "only declared changes and needed directories"
        [ [ "folder" ]; [ "folder"; "chosen" ]; [ "gone" ]; [ "public" ] ]
        (C.differences base selected);
      Alcotest.(check bool)
        "unselected private bytes absent" false
        (List.mem_assoc [ "private" ] (C.entries selected)
        || List.mem_assoc [ "folder"; "private" ] (C.entries selected));
      rejected "unknown path selection silently succeeded"
        (C.select ~base ~observed ~paths:[ [ "typo" ] ] ~excluded:[]);
      let all =
        C.select ~base ~observed ~paths:[] ~excluded:[ [ "ignored" ] ]
        |> composed
      in
      Alcotest.(check string)
        "excluded formerly public path not implicitly deleted" "old ignored"
        (bytes store [ "ignored" ] all);
      let base_id = C.store store base |> composed
      and result_id = C.store store selected |> composed in
      let changes = C.differences base selected in
      let scope = C.Scope.store store changes |> composed in
      let change =
        Core.Change_id.of_raw (String.make 16 'c') |> ok Core.error_to_string
      in
      let revision =
        Core.make_shared_revision ~change ~previous_revisions:[]
          ~base_snapshot:base_id ~result_snapshot:result_id
          ~edit_scope_root:scope ~dependencies:[]
        |> ok Core.error_to_string
      in
      C.validate_revision store revision |> composed;
      let dishonest_scope = C.Scope.store store [ [ "public" ] ] |> composed in
      let dishonest =
        Core.make_shared_revision ~change ~previous_revisions:[]
          ~base_snapshot:base_id ~result_snapshot:result_id
          ~edit_scope_root:dishonest_scope ~dependencies:[]
        |> ok Core.error_to_string
      in
      rejected "undeclared paths exported as selected work"
        (C.validate_revision store dishonest))

let scope_pages () =
  with_store (fun _ store ->
      let paths = List.init 17000 (fun i -> [ Printf.sprintf "p%06d" i ]) in
      let id = C.Scope.store store paths |> composed in
      Alcotest.(check (list (list string)))
        "paged scope exact" paths
        (C.Scope.load store id |> composed);
      let closure = C.Scope.closure store id |> composed in
      Alcotest.(check bool)
        "leaf and index pages used" true
        (List.length closure > 130);
      List.iter
        (fun id ->
          let bytes =
            In_channel.with_open_bin (Raw.object_path store id)
              In_channel.input_all
          in
          Alcotest.(check bool)
            "page bounded" true
            (String.length bytes <= C.Scope.max_page_bytes))
        closure;
      let again = C.Scope.store store (List.rev paths) |> composed in
      Alcotest.(check bool)
        "path set canonical independent of input order" true
        (Core.Object_id.equal id again))

let scope_golden () =
  with_store (fun _ store ->
      let id =
        C.Scope.store store [ [ "a"; "b" ]; [ "bad-\255" ]; [ "z" ] ]
        |> composed
      in
      let read name =
        let path = "golden/composition/" ^ name in
        let path = if Sys.file_exists path then path else "test/" ^ path in
        In_channel.with_open_bin path In_channel.input_all |> String.trim
      in
      Alcotest.(check string)
        "independent scoped identity" (read "edit-scope-id.hex")
        (Core.Object_id.to_hex id);
      let object_id =
        Raw.Stored_object_id.of_hex (Core.Object_id.to_hex id)
        |> ok Raw.Stored_object_id.parse_error_to_string
      in
      let envelope = Raw.get store object_id |> ok Raw.error_to_string in
      let hex bytes =
        String.to_seq bytes
        |> Seq.map (fun ch -> Printf.sprintf "%02x" (Char.code ch))
        |> List.of_seq |> String.concat ""
      in
      Alcotest.(check string)
        "independent scoped envelope bytes"
        (read "edit-scope-envelope.hex")
        (hex (Envelope.encode envelope)))

let malformed_scopes () =
  with_store (fun _ store ->
      let array values = E.array values |> ok E.construction_error_to_string in
      let stored kind payload =
        let envelope =
          Envelope.create ~object_type:kind ~object_format_version:1
            ~mandatory_features:0L ~payload ()
          |> ok Envelope.creation_error_to_string
        in
        Raw.put store envelope |> ok Raw.error_to_string
        |> Raw.Stored_object_id.to_raw_bytes |> Core.Object_id.of_raw
        |> ok Core.error_to_string
      in
      let path name = array [ E.bytes name ] in
      List.iter
        (fun payload ->
          let id = stored Envelope.Core_edit_scope payload in
          rejected "malformed/noncanonical scope accepted"
            (C.Scope.load store id))
        [
          array [ E.integer 2L; E.integer 0L; array [] ];
          array [ E.integer 1L; E.integer 0L; array [ path "b"; path "a" ] ];
          array [ E.integer 1L; E.integer 0L; array [ path "a"; path "a" ] ];
          array [ E.integer 1L; E.integer 1L; array [ E.bytes "short" ] ];
          array [ E.integer 1L; E.integer 0L; array [ path ".." ] ];
        ];
      let id = stored Envelope.Core_branch_event (array []) in
      rejected "wrong scope object type accepted" (C.Scope.load store id))

let typed_missing_data () =
  with_store (fun _ store ->
      let missing =
        Core.Object_id.of_raw (String.make 32 '\000') |> ok Core.error_to_string
      in
      (match C.load store missing with
      | Error (C.Unavailable _) -> ()
      | Ok _ | Error (C.Invalid_input _ | C.Integrity _ | C.Conflicts _) ->
          Alcotest.fail "missing snapshot must be unavailable");
      let value =
        E.array [ E.bytes (String.make (C.Scope.max_page_bytes + 1) 'x') ]
        |> ok E.construction_error_to_string
      in
      let envelope =
        Envelope.create ~object_type:Envelope.Core_edit_scope
          ~object_format_version:1 ~mandatory_features:0L ~payload:value ()
        |> ok Envelope.creation_error_to_string
      in
      let id =
        Raw.put store envelope |> ok Raw.error_to_string
        |> Raw.Stored_object_id.to_raw_bytes |> Core.Object_id.of_raw
        |> ok Core.error_to_string
      in
      match C.Scope.load store id with
      | Error (C.Integrity _) -> ()
      | Ok _ | Error (C.Invalid_input _ | C.Unavailable _ | C.Conflicts _) ->
          Alcotest.fail "oversized scope must be an integrity refusal")

let randomized_hunks =
  let generator =
    QCheck.(
      list_size (Gen.int_bound 30)
        (oneof_list [ "a\n"; "b\r\n"; "repeat\n"; "\n"; "終\n" ]))
  in
  QCheck.Test.make ~count:400 ~name:"line hunks preserve exact bytes"
    QCheck.(pair generator generator)
    (fun (before, after) ->
      let base = String.concat "" before and result = String.concat "" after in
      match L.diff ~base ~result with
      | Error _ -> false
      | Ok hunks ->
          let source = Array.of_list before in
          let cursor = ref 0 and output = Buffer.create 100 in
          List.iter
            (fun h ->
              for i = !cursor to h.L.first - 1 do
                Buffer.add_string output source.(i)
              done;
              List.iter (Buffer.add_string output) h.L.replacement;
              cursor := h.L.last)
            hunks;
          for i = !cursor to Array.length source - 1 do
            Buffer.add_string output source.(i)
          done;
          Buffer.contents output = result)

let () =
  Alcotest.run "Core composition"
    [
      ( "profile",
        [
          Alcotest.test_case "canonical LCS and exact line bytes" `Quick
            golden_hunks;
          Alcotest.test_case "set composition and insertion boundaries" `Quick
            set_composition;
          Alcotest.test_case "deterministic text limits and opaque equality"
            `Quick bounds;
          Alcotest.test_case "mixed tree byte/mode/directory composition" `Quick
            exact_tree_merge;
          Alcotest.test_case
            "structural/deletion conflicts preserve alternatives" `Quick
            structural_conflicts;
          Alcotest.test_case "selected publication and exact scope validation"
            `Quick selected_scope;
          Alcotest.test_case "bounded paged edit-scope collection" `Quick
            scope_pages;
          Alcotest.test_case "independent scope golden envelope and identity"
            `Quick scope_golden;
          Alcotest.test_case "malformed and noncanonical scope rejection" `Quick
            malformed_scopes;
          Alcotest.test_case
            "bounded scope reading and unavailable snapshot classification"
            `Quick typed_missing_data;
          QCheck_alcotest.to_alcotest randomized_hunks;
        ] );
    ]
