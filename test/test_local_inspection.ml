module S = Yeokcham_v1_local_service
module T = Yeokcham_v1_trust
module M = Yeokcham_v1_model
module C = M.Core
module H = Yeokcham_v1_undo
module Store = Yeokcham_v1_store
module Raw = Yeokcham_store
module D = S.Text_diff
module J = Yeokcham_v1_restore_journal

[@@@warning "-42"]

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)
let service r = ok S.error_to_string r
let reject name = function Error _ -> () | Ok _ -> Alcotest.fail name

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_root f =
  let root = Filename.temp_file "yeokcham-inspection-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let write root path bytes =
  Out_channel.with_open_bin (Filename.concat root path) (fun ch ->
      Out_channel.output_string ch bytes)

let read root path =
  In_channel.with_open_bin (Filename.concat root path) In_channel.input_all

let load root =
  Store.open_repository ~root
  |> ok Store.error_to_string |> Store.load |> ok Store.error_to_string

let raw root =
  Store.open_repository ~root
  |> ok Store.error_to_string |> Store.underlying_store

let initialize root =
  let cap =
    T.signing_capability_of_private_key (String.make 32 'a')
    |> ok T.error_to_string
  in
  let recovery =
    T.signing_capability_of_private_key (String.make 32 'r')
    |> ok T.error_to_string
  in
  let device cap =
    T.device_of_public_key (T.signing_public_key cap) |> ok T.error_to_string
  in
  S.init_local_signed_with_recovery ~root
    ~username:(M.Username.of_string "alice" |> ok M.error_to_string)
    ~initial_draft:(M.Draft_id.of_string "work" |> ok M.error_to_string)
    ~title:"local work"
    ~repository:(T.Repository_id.generate () |> ok Fun.id)
    ~device:(device cap) ~signing_capability:cap
    ~recovery_device:(device recovery) ~recovery_capability:recovery
  |> service |> ignore;
  cap

let save root value =
  write root "notes" value;
  S.save ~root |> service |> ignore

let same_head before root =
  Alcotest.(check bool)
    "inspection leaves metadata root unchanged" true
    (Raw.Mutable_ref.equal before.Store.head (load root).Store.head)

let compare root before after =
  S.compare_local_states ~root ~before ~after |> service

let differences comparison = comparison.S.display_differences

let difference comparison path =
  List.find
    (fun d -> M.Path.to_string d.S.entry_difference.S.path = path)
    (differences comparison)

let mixed_status_and_working_diff () =
  with_root (fun root ->
      write root "notes" "alpha\n";
      write root "opaque" "\000old";
      write root "run" "#!/bin/sh\n";
      write root "kind" "file";
      Unix.mkdir (Filename.concat root "empty") 0o700;
      Unix.symlink "missing" (Filename.concat root "link");
      initialize root |> ignore;
      let before = load root in
      write root "notes" "beta\n";
      write root "opaque" "\000new";
      Unix.chmod (Filename.concat root "run") 0o751;
      Unix.unlink (Filename.concat root "link");
      Unix.symlink "elsewhere" (Filename.concat root "link");
      Unix.unlink (Filename.concat root "kind");
      Unix.mkdir (Filename.concat root "kind") 0o700;
      write root "kind/child" "new";
      Unix.rmdir (Filename.concat root "empty");
      let status = S.inspect_local_status ~root |> service in
      let observation = status.S.capture_observation |> ok Fun.id in
      Alcotest.(check (list string))
        "actual changed paths"
        [ "empty"; "kind"; "kind/child"; "link"; "notes"; "opaque"; "run" ]
        (List.map
           (fun d -> M.Path.to_string d.S.path)
           observation.S.differences);
      Alcotest.(check bool)
        "uncaptured is explicit" true status.S.saved_metadata.S.uncaptured;
      let comparison = compare root S.Current_saved S.Working_tree in
      (match (difference comparison "notes").S.text_difference with
      | Some (D.Text [ _ ]) -> ()
      | Some (D.Text ([] | _ :: _ :: _) | D.Opaque _) | None ->
          Alcotest.fail "text edit has no readable hunk");
      (match (difference comparison "opaque").S.text_difference with
      | Some (D.Opaque _) -> ()
      | Some (D.Text _) | None -> Alcotest.fail "opaque edit treated as text");
      Alcotest.(check bool)
        "mode-only change does not invent byte diff" true
        (Option.is_none (difference comparison "run").S.text_difference);
      same_head before root;
      Alcotest.(check string)
        "inspection did not rewrite work" "beta\n" (read root "notes"))

let exact_history_and_pagination () =
  with_root (fun root ->
      write root "notes" "A\n";
      initialize root |> ignore;
      save root "B\n";
      save root "C\n";
      S.navigate_history ~root ~direction:S.Undo ~dry_run:false
      |> service |> ignore;
      save root "D\n";
      let before = load root in
      let page =
        S.inspect_local_history ~root ~before:None ~limit:2 |> service
      in
      Alcotest.(check (list int64))
        "first page newest first" [ 3L; 2L ]
        (List.map (fun row -> row.S.history_node.H.id) page.S.entries);
      Alcotest.(check (option int64))
        "explicit continuation" (Some 2L) page.S.next_before;
      let next =
        S.inspect_local_history ~root ~before:page.S.next_before ~limit:2
        |> service
      in
      Alcotest.(check (list int64))
        "second page has no duplicate" [ 1L; 0L ]
        (List.map (fun row -> row.S.history_node.H.id) next.S.entries);
      let b = List.hd next.S.entries in
      Alcotest.(check (list int64))
        "alternate continuations visible" [ 2L; 3L ] b.S.history_children;
      Alcotest.(check string)
        "saved title" "local work"
        (Option.get b.S.history_title);
      Alcotest.(check (list string))
        "paths from recorded parent" [ "notes" ]
        (b.S.history_paths |> ok Fun.id |> List.map M.Path.to_string);
      let b_id = Option.get b.S.history_identity in
      let compared = compare root (S.Exact_history b_id) (S.History_node 2L) in
      Alcotest.(check bool)
        "exact saved text compared" true
        (List.length (differences compared) = 1);
      let wrong =
        C.History_id.make
          ~workspace:
            (C.Workspace_id.of_raw (String.make 16 'z') |> ok C.error_to_string)
          ~sequence:1L
        |> ok C.error_to_string
      in
      reject "foreign workspace sequence silently retargeted"
        (S.compare_local_states ~root ~before:(S.Exact_history wrong)
           ~after:S.Current_saved);
      same_head before root;
      Alcotest.(check string)
        "saved-state diff leaves disk D" "D\n" (read root "notes"))

let equal_contents_keep_distinct_positions () =
  with_root (fun root ->
      write root "notes" "A";
      initialize root |> ignore;
      save root "B";
      save root "A";
      let comparison = compare root (S.History_node 0L) (S.History_node 2L) in
      Alcotest.(check int)
        "equal contents have no byte differences" 0
        (List.length (differences comparison));
      Alcotest.(check bool)
        "history identity survives equal contents" false
        (comparison.S.before_state.S.state_name
       = comparison.S.after_state.S.state_name);
      Alcotest.(check bool)
        "content identity remains shared" true
        (M.Snapshot_id.equal comparison.S.before_state.S.state_snapshot
           comparison.S.after_state.S.state_snapshot))

let malformed_capture_is_not_clean () =
  with_root (fun root ->
      write root "notes" "A";
      initialize root |> ignore;
      let before = load root in
      write root ".yeokchamignore" "[malformed\n";
      let status = S.inspect_local_status ~root |> service in
      (match status.S.capture_observation with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "malformed capture labelled complete");
      let page =
        S.inspect_local_history ~root ~before:None ~limit:50 |> service
      in
      Alcotest.(check int)
        "saved metadata still inspectable" 1
        (List.length page.S.entries);
      reject "working diff ignored malformed rules"
        (S.compare_local_states ~root ~before:S.Current_saved
           ~after:S.Working_tree);
      compare root (S.History_node 0L) (S.History_node 0L) |> ignore;
      same_head before root;
      Unix.unlink (Filename.concat root ".yeokchamignore");
      Unix.mkfifo (Filename.concat root "pipe") 0o600;
      let status = S.inspect_local_status ~root |> service in
      (match status.S.capture_observation with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "special file labelled complete");
      S.inspect_local_history ~root ~before:None ~limit:50 |> service |> ignore;
      same_head before root)

let[@warning "-4"] unavailable_and_unretained_are_explicit () =
  with_root (fun root ->
      write root "notes" "A";
      initialize root |> ignore;
      save root "B";
      let b = (H.current (load root).Store.history).H.snapshot in
      save root "C";
      let before = load root in
      let id =
        Raw.Stored_object_id.of_hex (M.Snapshot_id.to_string b)
        |> ok Raw.Stored_object_id.parse_error_to_string
      in
      Unix.unlink (Raw.object_path (raw root) id);
      let page =
        S.inspect_local_history ~root ~before:None ~limit:50 |> service
      in
      let row =
        List.find (fun row -> row.S.history_node.H.id = 1L) page.S.entries
      in
      (match row.S.availability with
      | S.Unavailable _ -> ()
      | _ -> Alcotest.fail "missing snapshot marked available");
      reject "missing comparison target accepted"
        (S.compare_local_states ~root ~before:(S.History_node 1L)
           ~after:S.Current_saved);
      same_head before root;
      S.compact ~root ~keep_recent:0 ~dry_run:false |> service |> ignore;
      let page =
        S.inspect_local_history ~root ~before:None ~limit:50 |> service
      in
      let row =
        List.find (fun row -> row.S.history_node.H.id = 1L) page.S.entries
      in
      Alcotest.(check bool)
        "unretained differs from missing" true
        (row.S.availability = S.Not_retained);
      Alcotest.(check string)
        "inspection never replaced disk" "C" (read root "notes"))

let pending_recovery_blocks_partial_capture () =
  with_root (fun root ->
      write root "notes" "A";
      initialize root |> ignore;
      let initial = (H.current (load root).Store.history).H.snapshot in
      save root "B";
      let before = load root in
      let safety = (H.current before.Store.history).H.snapshot in
      let journal =
        J.make_prepared ~operation_id:(String.make 64 'a') ~safety
          ~target:initial
        |> ok J.error_to_string
      in
      J.append ~root journal |> ok J.error_to_string;
      J.advance journal J.Applying
      |> ok J.error_to_string |> J.append ~root |> ok J.error_to_string;
      write root "notes" "partial application";
      let count () =
        Raw.list_objects (raw root) |> ok Raw.error_to_string |> List.length
      in
      let objects_before = count () in
      let status = S.inspect_local_status ~root |> service in
      Alcotest.(check bool)
        "pending operation identified" true
        (Option.is_some status.S.pending_local_recovery);
      (match status.S.capture_observation with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "partial application captured");
      reject "working diff captured partial application"
        (S.compare_local_states ~root ~before:S.Current_saved
           ~after:S.Working_tree);
      compare root (S.History_node 0L) (S.History_node 1L) |> ignore;
      Alcotest.(check int) "no partial scan objects" objects_before (count ());
      same_head before root;
      Alcotest.(check string)
        "inspection preserves interrupted tree" "partial application"
        (read root "notes"))

let () =
  Alcotest.run "Local inspection"
    [
      ( "domain",
        [
          Alcotest.test_case "mixed status and exact working diff" `Quick
            mixed_status_and_working_diff;
          Alcotest.test_case
            "exact history, alternatives, namespaces and pagination" `Quick
            exact_history_and_pagination;
          Alcotest.test_case "equal contents retain distinct state identities"
            `Quick equal_contents_keep_distinct_positions;
          Alcotest.test_case "malformed and special-file capture is incomplete"
            `Quick malformed_capture_is_not_clean;
          Alcotest.test_case "unavailable and unretained states are explicit"
            `Quick unavailable_and_unretained_are_explicit;
          Alcotest.test_case "pending recovery never captures partial files"
            `Quick pending_recovery_blocks_partial_capture;
        ] );
    ]
