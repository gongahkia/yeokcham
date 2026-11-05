module History = Yeokcham_v1_undo
module Model = Yeokcham_v1_model
module Service = Yeokcham_v1_local_service
module Store = Yeokcham_v1_store
module Journal = Yeokcham_v1_restore_journal
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Raw = Yeokcham_store
module Record = Yeokcham_v1_record

let ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let id parser text = parser text |> Result.get_ok
let snapshot = id Model.Snapshot_id.of_string
let draft = id Model.Draft_id.of_string "local-task"
let check_id name expected actual = Alcotest.(check int64) name expected actual
let reject name = function Ok _ -> Alcotest.fail name | Error _ -> ()

let rec remove path =
  match Unix.lstat path with
  | stats when stats.Unix.st_kind = Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path
  | _ -> Unix.unlink path

let with_root run =
  let root = Filename.temp_file "yeokcham-undo-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

let write root text =
  Out_channel.with_open_bin (Filename.concat root "note.txt") (fun channel ->
      Out_channel.output_string channel text)

let read root =
  In_channel.with_open_bin
    (Filename.concat root "note.txt")
    In_channel.input_all

let initialize root =
  write root "A";
  Service.init ~root
    ~creator:(id Model.Device_id.of_string "alice-device")
    ~username:(id Model.Username.of_string "alice")
    ~initial_draft:draft ~title:"local work"
  |> ok Service.error_to_string |> ignore

let save root text =
  write root text;
  Service.save ~root |> ok Service.error_to_string |> ignore

let loaded root =
  Store.open_repository ~root
  |> ok Store.error_to_string |> Store.load |> ok Store.error_to_string

let tree root =
  (Service.local_history ~root |> ok Service.error_to_string).Service.undo_tree

let cursor root = (History.current (tree root)).History.id

let move ?(dry_run = false) root direction =
  Service.navigate_history ~root ~direction ~dry_run
  |> ok Service.error_to_string

let repeated_contents_preserve_distinct_history () =
  let history = History.seed ~snapshot:(snapshot "A") ~draft in
  let record history value =
    History.record history ~snapshot:(snapshot value) ~draft ~created_at:1L
    |> ok Fun.id
  in
  let history = record (record history "B") "A" in
  check_id "returning to A creates node 2" 2L
    (History.current history).History.id;
  let again = record history "A" in
  Alcotest.(check int)
    "unchanged save is a no-op" 3
    (List.length (History.nodes again));
  let history =
    History.select history 0L |> ok Fun.id |> fun history -> record history "D"
  in
  Alcotest.(check (list int64))
    "both continuations survive" [ 1L; 3L ]
    (History.children history 0L |> List.map (fun node -> node.History.id));
  let bytes = History.encode history |> ok Fun.id in
  let reopened = History.decode bytes |> ok Fun.id in
  Alcotest.(check string)
    "canonical round trip" bytes
    (History.encode reopened |> ok Fun.id)

let malformed_history_is_rejected () =
  let text value = Encoding.text value |> Result.get_ok in
  let array values = Encoding.array values |> Result.get_ok in
  let node n parent =
    array
      [ Encoding.integer n; parent; text "A"; text "task"; Encoding.integer 0L ]
  in
  let encoded cursor entries =
    array [ Encoding.integer 1L; Encoding.integer cursor; array entries ]
    |> Encoding.encode
  in
  reject "self-parent accepted"
    (History.decode (encoded 0L [ node 0L (Encoding.integer 0L) ]));
  reject "missing cursor accepted"
    (History.decode (encoded 1L [ node 0L Encoding.null ]));
  reject "nonconsecutive IDs accepted"
    (History.decode
       (encoded 2L [ node 0L Encoding.null; node 2L (Encoding.integer 0L) ]));
  reject "empty history accepted" (History.decode (encoded 0L []))

let branches_survive_reopen_and_require_selection () =
  with_root (fun root ->
      initialize root;
      save root "B";
      save root "C";
      move root Service.Undo |> ignore;
      Alcotest.(check string) "undo restored B" "B" (read root);
      save root "D";
      check_id "D is a new child" 3L (cursor root);
      move root Service.Undo |> ignore;
      reject "ambiguous redo was accepted"
        (Service.navigate_history ~root ~direction:(Service.Redo None)
           ~dry_run:false);
      check_id "refusal kept cursor" 1L (cursor root);
      move root (Service.Redo (Some 2L)) |> ignore;
      Alcotest.(check string) "selected C" "C" (read root);
      let reopened = loaded root in
      check_id "cursor survives reopening" 2L
        (History.current reopened.Store.history).History.id;
      move root (Service.Go_to 3L) |> ignore;
      Alcotest.(check string) "D is still available" "D" (read root);
      Alcotest.(check int)
        "navigation creates no content nodes" 4
        (List.length (History.nodes (tree root))))

let dirty_undo_is_recoverable_and_redo_refuses_dirty_files () =
  with_root (fun root ->
      initialize root;
      save root "B";
      write root "unsaved";
      let result = move root Service.Undo in
      Alcotest.(check bool)
        "unsaved work was captured" true result.Service.captures_unsaved;
      Alcotest.(check string) "undo returns to saved B" "B" (read root);
      move root (Service.Redo None) |> ignore;
      Alcotest.(check string)
        "redo recovers unsaved bytes" "unsaved" (read root);
      move root Service.Undo |> ignore;
      write root "new unsaved";
      reject "dirty redo accepted"
        (Service.navigate_history ~root ~direction:(Service.Redo None)
           ~dry_run:false);
      Alcotest.(check string)
        "dirty refusal preserved bytes" "new unsaved" (read root))

let previews_and_inspection_do_not_advance_history () =
  with_root (fun root ->
      initialize root;
      save root "B";
      write root "unsaved";
      let before = loaded root in
      let result = move ~dry_run:true root Service.Undo in
      check_id "preview points to saved B" 1L
        result.Service.target_node.History.id;
      Alcotest.(check bool)
        "preview did not apply" false result.Service.history_applied;
      let after = loaded root in
      Alcotest.(check bool)
        "preview kept state head" true
        (Raw.Mutable_ref.equal before.Store.head after.Store.head);
      Alcotest.(check string)
        "preview kept ordinary files" "unsaved" (read root);
      Unix.mkfifo (Filename.concat root "unscannable") 0o600;
      let objects_before =
        Raw.list_objects
          (Store.open_repository ~root
          |> ok Store.error_to_string |> Store.underlying_store)
        |> ok Raw.error_to_string
      in
      tree root |> ignore;
      let objects_after =
        Raw.list_objects
          (Store.open_repository ~root
          |> ok Store.error_to_string |> Store.underlying_store)
        |> ok Raw.error_to_string
      in
      Alcotest.(check int)
        "inspection never scans"
        (List.length objects_before)
        (List.length objects_after))

let equal_contents_can_select_a_different_node () =
  with_root (fun root ->
      initialize root;
      save root "B";
      save root "A";
      check_id "new A node" 2L (cursor root);
      let result = move root (Service.Go_to 0L) in
      check_id "selected original A" 0L (cursor root);
      Alcotest.(check bool)
        "no replacement needed" true
        (Option.is_none result.Service.history_restore);
      move root (Service.Go_to 1L) |> ignore;
      write root "A";
      move root (Service.Go_to 0L) |> ignore;
      Alcotest.(check int)
        "equal-byte navigation retained unsaved observation" 4
        (List.length (History.nodes (tree root)));
      move root (Service.Go_to 3L) |> ignore;
      check_id "unsaved A remains navigable" 3L (cursor root))

let ordinary_restore_changes_the_branch_position () =
  with_root (fun root ->
      initialize root;
      save root "B";
      let checkpoint =
        (loaded root).Store.project |> Model.active_draft |> fun active ->
        active.Model.latest_checkpoint
      in
      save root "C";
      Service.restore_in_place ~root ~checkpoint
      |> ok Service.error_to_string |> ignore;
      check_id "restore selected B" 1L (cursor root);
      save root "D";
      Alcotest.(check (list int64))
        "restore followed by edit branches" [ 2L; 3L ]
        (History.children (tree root) 1L
        |> List.map (fun node -> node.History.id)))

let interrupted_navigation_resumes_the_exact_node () =
  with_root (fun root ->
      initialize root;
      save root "B";
      save root "C";
      save root "B";
      save root "D";
      let current = History.current (tree root) in
      let target = History.find (tree root) 1L |> ok Fun.id in
      let prepared =
        Journal.make_prepared ~operation_id:(String.make 64 'f')
          ~safety:current.History.snapshot ~target:target.History.snapshot
        |> ok Journal.error_to_string
        |> fun journal ->
        Journal.with_history_node journal 1L |> ok Journal.error_to_string
      in
      let bytes = Journal.encode prepared |> ok Journal.error_to_string in
      let reopened = Journal.decode bytes |> ok Journal.error_to_string in
      Alcotest.(check (option int64))
        "journal retained exact target node" (Some 1L)
        (Journal.history_node reopened);
      Journal.append ~root prepared |> ok Journal.error_to_string;
      Journal.advance prepared Journal.Applying
      |> ok Journal.error_to_string |> Journal.append ~root
      |> ok Journal.error_to_string;
      write root "partial replacement";
      reject "watcher save accepted during pending replacement"
        (Service.save ~root);
      let result = move root Service.Undo in
      check_id "resumed original target, without another undo" 1L (cursor root);
      Alcotest.(check string) "resumed exact bytes" "B" (read root);
      Alcotest.(check bool)
        "reports resumed operation" true
        (Option.fold ~none:false
           ~some:(fun restored -> restored.Service.resumed)
           result.Service.history_restore);
      move root Service.Undo |> ignore;
      check_id "subsequent undo takes one new step" 0L (cursor root))

let compaction_expires_contents_without_fabricating_ancestry () =
  with_root (fun root ->
      initialize root;
      save root "B";
      save root "C";
      move root Service.Undo |> ignore;
      save root "D";
      (* First prune completed journals while their recovery proofs still exist. *)
      Service.compact ~root ~keep_recent:0 ~dry_run:false
      |> ok Service.error_to_string |> ignore;
      Service.restore_proofs ~root
      |> ok Service.error_to_string
      |> List.iter (fun proof ->
          Service.forget_restore_proof ~root
            ~operation:proof.Service.proof_operation
          |> ok Service.error_to_string);
      Service.compact ~root ~keep_recent:0 ~dry_run:false
      |> ok Service.error_to_string |> ignore;
      Alcotest.(check int)
        "topology retained" 4
        (List.length (History.nodes (tree root)));
      reject "expired node was restored"
        (Service.navigate_history ~root ~direction:(Service.Go_to 2L)
           ~dry_run:false);
      Alcotest.(check string) "refusal kept D" "D" (read root);
      check_id "refusal kept cursor" 3L (cursor root))

let legacy_state_starts_at_a_known_root () =
  with_root (fun root ->
      initialize root;
      save root "B";
      let repository =
        Store.open_repository ~root |> ok Store.error_to_string
      in
      let before = Store.load repository |> ok Store.error_to_string in
      let raw = Store.underlying_store repository in
      let payload =
        Record.encode_project before.Store.project
        |> ok Record.error_to_string |> Encoding.decode
        |> ok Encoding.decode_error_to_string
      in
      let object_ =
        Envelope.create ~object_type:Envelope.V1_project_state
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
        |> ok Envelope.creation_error_to_string
      in
      let target = Raw.put raw object_ |> ok Raw.error_to_string in
      Raw.compare_and_swap_ref raw ~name:Store.state_head_name
        ~expected:(Some before.Store.head) ~target:(Some target)
      |> ok Raw.error_to_string |> ignore;
      Alcotest.(check int)
        "no old ancestry invented" 1
        (List.length (History.nodes (tree root)));
      reject "legacy root has no parent"
        (Service.navigate_history ~root ~direction:Service.Undo ~dry_run:false);
      save root "C";
      check_id "first new observation extends root" 1L (cursor root);
      let initial =
        (Model.export (loaded root).Store.project).Model.state_baseline
      in
      Service.restore_in_place ~root ~checkpoint:initial
      |> ok Service.error_to_string |> ignore;
      Alcotest.(check (option int64))
        "legacy restore starts a separate root" None
        (History.current (tree root)).History.parent)

let workspace_lock_is_released_when_its_owner_dies () =
  with_root (fun root ->
      initialize root;
      write root "B";
      let reader, writer = Unix.pipe ~cloexec:true () in
      let child = Unix.fork () in
      if child = 0 then (
        Unix.close reader;
        let lock =
          Filename.concat
            (Filename.concat root ".yeokcham")
            "local-worktree.lock"
        in
        let fd = Unix.openfile lock [ Unix.O_RDWR ] 0 in
        Unix.lockf fd Unix.F_TLOCK 0;
        ignore (Unix.write_substring writer "ready" 0 5);
        Unix.pause ();
        Unix._exit 1);
      Unix.close writer;
      Fun.protect
        ~finally:(fun () ->
          Unix.close reader;
          (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
          try ignore (Unix.waitpid [] child) with Unix.Unix_error _ -> ())
        (fun () ->
          let ready = Bytes.create 5 in
          Alcotest.(check int)
            "other process acquired lock" 5
            (Unix.read reader ready 0 5);
          reject "save bypassed another workspace operation"
            (Service.save ~root);
          Unix.kill child Sys.sigkill;
          ignore (Unix.waitpid [] child);
          Service.save ~root |> ok Service.error_to_string |> ignore;
          check_id "save succeeds after owner dies" 1L (cursor root)))

let navigation_restores_exact_project_entries () =
  with_root (fun root ->
      initialize root;
      let script = Filename.concat root "script" in
      let directory = Filename.concat root "empty" in
      let link = Filename.concat root "link" in
      Out_channel.with_open_bin script (fun channel ->
          Out_channel.output_string channel "binary\000bytes");
      Unix.chmod script 0o700;
      Unix.mkdir directory 0o700;
      Unix.symlink "note.txt" link;
      Service.save ~root |> ok Service.error_to_string |> ignore;
      Unix.unlink (Filename.concat root "note.txt");
      Unix.chmod script 0o600;
      Out_channel.with_open_bin script (fun channel ->
          Out_channel.output_string channel "changed");
      Unix.rmdir directory;
      Unix.unlink link;
      Service.save ~root |> ok Service.error_to_string |> ignore;
      move root Service.Undo |> ignore;
      Alcotest.(check string) "deleted file recovered" "A" (read root);
      Alcotest.(check string)
        "binary bytes recovered" "binary\000bytes"
        (In_channel.with_open_bin script In_channel.input_all);
      Alcotest.(check bool)
        "executable mode recovered" true
        ((Unix.stat script).Unix.st_perm land 0o100 <> 0);
      Alcotest.(check bool)
        "empty directory recovered" true
        (Sys.is_directory directory);
      Alcotest.(check string)
        "symlink target recovered" "note.txt" (Unix.readlink link);
      move root (Service.Redo None) |> ignore;
      Alcotest.(check bool)
        "redo removes the file" false
        (Sys.file_exists (Filename.concat root "note.txt"));
      Alcotest.(check bool)
        "redo removes the directory" false
        (Sys.file_exists directory);
      Alcotest.(check bool)
        "redo restores ordinary mode" true
        ((Unix.stat script).Unix.st_perm land 0o100 = 0))

let mismatched_journal_node_is_refused_before_file_writes () =
  with_root (fun root ->
      initialize root;
      save root "B";
      save root "C";
      let history = tree root in
      let target = History.find history 0L |> ok Fun.id in
      let current = History.current history in
      let journal =
        Journal.make_prepared ~operation_id:(String.make 64 'e')
          ~safety:current.History.snapshot ~target:target.History.snapshot
        |> ok Journal.error_to_string
        |> fun journal ->
        Journal.with_history_node journal 1L |> ok Journal.error_to_string
      in
      Journal.append ~root journal |> ok Journal.error_to_string;
      reject "mismatched target node accepted"
        (Service.navigate_history ~root ~direction:Service.Undo ~dry_run:false);
      Alcotest.(check string) "validation kept files" "C" (read root);
      check_id "validation kept cursor" 2L (cursor root))

let navigation_keeps_the_active_task () =
  with_root (fun root ->
      initialize root;
      save root "B";
      let second = id Model.Draft_id.of_string "second-task" in
      Service.new_draft ~root ~id:second ~title:"second task"
      |> ok Service.error_to_string |> ignore;
      Alcotest.(check int)
        "task change creates no content node" 2
        (List.length (History.nodes (tree root)));
      save root "C";
      move root (Service.Go_to 0L) |> ignore;
      let active = Model.active_draft (loaded root).Store.project in
      Alcotest.(check string)
        "navigation does not reopen an old task" "second-task"
        (Model.Draft_id.to_string active.Model.draft_id);
      save root "D";
      let node = History.current (tree root) in
      Alcotest.(check string)
        "new work records the current task" "second-task"
        (Model.Draft_id.to_string node.History.draft);
      Alcotest.(check (option int64))
        "new task work follows selected local position" (Some 0L)
        node.History.parent)

let () =
  Alcotest.run "V1 local undo tree"
    [
      ( "history",
        [
          Alcotest.test_case "equal snapshots retain distinct branching history"
            `Quick repeated_contents_preserve_distinct_history;
          Alcotest.test_case "invalid topology and cursors are rejected" `Quick
            malformed_history_is_rejected;
          Alcotest.test_case
            "branches survive restart and require redo selection" `Quick
            branches_survive_reopen_and_require_selection;
          Alcotest.test_case "dirty undo preserves work and dirty redo refuses"
            `Quick dirty_undo_is_recoverable_and_redo_refuses_dirty_files;
          Alcotest.test_case "preview and inspection preserve the state head"
            `Quick previews_and_inspection_do_not_advance_history;
          Alcotest.test_case "equal-byte navigation preserves node identity"
            `Quick equal_contents_can_select_a_different_node;
          Alcotest.test_case "restore followed by editing branches" `Quick
            ordinary_restore_changes_the_branch_position;
          Alcotest.test_case "interrupted navigation resumes the exact node"
            `Quick interrupted_navigation_resumes_the_exact_node;
          Alcotest.test_case "compaction expires bytes and preserves topology"
            `Quick compaction_expires_contents_without_fabricating_ancestry;
          Alcotest.test_case "legacy history starts without invented parents"
            `Quick legacy_state_starts_at_a_known_root;
          Alcotest.test_case
            "mismatched journal nodes are rejected before writes" `Quick
            mismatched_journal_node_is_refused_before_file_writes;
          Alcotest.test_case "navigation restores exact project entries" `Quick
            navigation_restores_exact_project_entries;
          Alcotest.test_case "navigation keeps the active task" `Quick
            navigation_keeps_the_active_task;
          Alcotest.test_case
            "workspace lock survives neither process exit nor crash" `Quick
            workspace_lock_is_released_when_its_owner_dies;
        ] );
    ]
