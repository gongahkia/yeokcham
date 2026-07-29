module Model = Paengi_model
module Id = Paengi_id
open Model

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> (
      match int_of_string_opt value with
      | Some seed -> seed
      | None -> invalid_arg "PROPERTY_TEST_SEED must be an integer")

let stable_seed name =
  let mask = 0x3fff_ffffL in
  let hash =
    String.fold_left
      (fun state character ->
        Int64.(
          logand
            (add (mul state 16_777_619L) (of_int (Char.code character)))
            mask))
      (Int64.of_int base_seed) name
  in
  Int64.to_int hash

let state_for name =
  let seed = stable_seed name in
  Printf.printf "model property seed [%s]: %d\n%!" name seed;
  Random.State.make [| base_seed; seed |]

let () = Printf.printf "model property base seed: %d\n%!" base_seed

let require_path components =
  match Path.of_components components with
  | Ok path -> path
  | Error error -> failwith (Path.error_to_string error)

let require_snapshot entries =
  match Snapshot.of_entries entries with
  | Ok snapshot -> snapshot
  | Error error -> failwith (Model.construction_error_to_string error)

let file ?(mode = Model.Regular) content = { mode; content }

let find_entry snapshot path =
  match Snapshot.find snapshot path with
  | Some entry -> entry
  | None -> Alcotest.failf "missing fixture entry: %s" (Path.to_string path)

let source = require_path [ "source" ]
let archive = require_path [ "archive" ]
let nested = require_path [ "source"; "nested" ]

let initial_snapshot () =
  require_snapshot
    [
      Model.Directory_path source;
      Model.Directory_path archive;
      Model.Directory_path nested;
    ]

let operations_apply_exact_bytes_and_modes () =
  let original = initial_snapshot () in
  let draft = require_path [ "source"; "draft" ] in
  let moved = require_path [ "archive"; "released" ] in
  let initial = "first\000line" in
  let replacement = "second\255line" in
  let operations =
    [
      Model.Create_file
        { path = draft; content = initial; mode = Model.Regular };
      Model.Modify_file
        {
          path = draft;
          expected_content = initial;
          replacement_content = replacement;
        };
      Model.Change_mode
        {
          path = draft;
          expected_mode = Model.Regular;
          replacement_mode = Model.Executable;
        };
      Model.Move_path
        {
          source = draft;
          destination = moved;
          prior = Model.File (file ~mode:Model.Executable replacement);
        };
      Model.Delete_path
        {
          path = moved;
          prior = Model.File (file ~mode:Model.Executable replacement);
        };
    ]
  in
  match Snapshot.apply_operations original operations with
  | Error error -> Alcotest.fail (Model.replay_error_to_string error)
  | Ok restored ->
      Alcotest.(check bool)
        "operations return to the original snapshot" true
        (Snapshot.equal original restored)

let directory_moves_preserve_descendants () =
  let source_file = require_path [ "source"; "nested"; "value" ] in
  let original =
    require_snapshot
      [
        Model.Directory_path source;
        Model.Directory_path archive;
        Model.Directory_path nested;
        Model.File_path (source_file, file "value");
      ]
  in
  let destination = require_path [ "archive"; "source" ] in
  let prior = find_entry original source in
  match
    Snapshot.apply_operation original
      (Model.Move_path { source; destination; prior })
  with
  | Error error -> Alcotest.fail (Model.transition_error_to_string error)
  | Ok moved ->
      let expected_file =
        require_path [ "archive"; "source"; "nested"; "value" ]
      in
      Alcotest.(check bool)
        "source no longer exists" true
        (Option.is_none (Snapshot.find moved source));
      Alcotest.(check bool)
        "descendant bytes preserved" true
        (match Snapshot.find moved expected_file with
        | Some (Model.File entry) -> String.equal entry.content "value"
        | Some (Model.Directory _) | None -> false)

let preconditions_fail_without_mutating_snapshot () =
  let path = require_path [ "source"; "value" ] in
  let original =
    require_snapshot
      [
        Model.Directory_path source;
        Model.Directory_path archive;
        Model.Directory_path nested;
        Model.File_path (path, file "actual");
      ]
  in
  let operations =
    [
      Model.Create_file
        {
          path = require_path [ "source"; "new" ];
          content = "new";
          mode = Model.Regular;
        };
      Model.Modify_file
        {
          path;
          expected_content = "wrong";
          replacement_content = "replacement";
        };
    ]
  in
  (match Snapshot.apply_operations original operations with
  | Error error ->
      Alcotest.(check string)
        "precondition failure"
        "operation 1: content precondition failed: source/value"
        (Model.replay_error_to_string error)
  | Ok _ -> Alcotest.fail "invalid operation sequence applied");
  Alcotest.(check bool)
    "original remains unchanged" true
    (Option.is_none (Snapshot.find original (require_path [ "source"; "new" ])));
  Alcotest.(check bool)
    "original bytes remain unchanged" true
    (match Snapshot.find original path with
    | Some (Model.File entry) -> String.equal entry.content "actual"
    | Some (Model.Directory _) | None -> false)

let paths_reject_unsafe_components () =
  let cases =
    [
      ([], Path.Empty_path);
      ([ "" ], Path.Empty_component 0);
      ([ "." ], Path.Dot_component 0);
      ([ ".." ], Path.Dot_dot_component 0);
      ([ "a/b" ], Path.Separator_in_component 0);
      ([ "a\000b" ], Path.Nul_in_component 0);
    ]
  in
  List.iter
    (fun (components, expected) ->
      match Path.of_components components with
      | Ok _ -> Alcotest.fail "unsafe path accepted"
      | Error actual ->
          Alcotest.(check bool) "path rejection" true (actual = expected))
    cases

let snapshot_identity_is_canonical () =
  let alpha = require_path [ "source"; "alpha" ] in
  let beta = require_path [ "archive"; "beta" ] in
  let entries =
    [
      Model.Directory_path source;
      Model.Directory_path archive;
      Model.Directory_path nested;
      Model.File_path (alpha, file "alpha");
      Model.File_path (beta, file ~mode:Model.Symlink "target");
    ]
  in
  let reordered = List.rev entries in
  let left = require_snapshot entries in
  let right = require_snapshot reordered in
  Alcotest.(check bool)
    "insertion order does not change the tree" true
    (Snapshot.equal left right);
  Alcotest.(check string)
    "canonical bytes"
    (Snapshot.canonical_bytes left)
    (Snapshot.canonical_bytes right);
  Alcotest.(check string)
    "snapshot identity"
    (Paengi_id.Snapshot_id.to_hex (Snapshot.id left))
    (Paengi_id.Snapshot_id.to_hex (Snapshot.id right))

type reference_file = { path : Path.t; entry : Model.file_entry }

let mode_from value =
  match value mod 3 with
  | 0 -> Model.Regular
  | 1 -> Model.Executable
  | _ -> Model.Symlink

let generated_content index value =
  String.init 6 (fun offset ->
      Char.chr ((value + (index * 29) + (offset * 71)) land 0xff))

let nth values index = List.nth values (index mod List.length values)

let replace_file files target replacement =
  List.map
    (fun file -> if Path.equal file.path target then replacement else file)
    files

let remove_file files target =
  List.filter (fun file -> not (Path.equal file.path target)) files

let generated_directories values =
  let count = 1 + (List.hd values mod 4) in
  List.init count (fun index ->
      let root = require_path [ Printf.sprintf "tree-%d" index ] in
      let nested = require_path [ Printf.sprintf "tree-%d" index; "nested" ] in
      [ root; nested ])
  |> List.concat

let scenario_with_directories values =
  let directories = generated_directories values in
  let initial =
    List.map (fun path -> Model.Directory_path path) directories
    |> require_snapshot
  in
  let rec build index files operations = function
    | [] ->
        let expected_entries =
          List.map (fun path -> Model.Directory_path path) directories
          @ List.map
              (fun { path; entry } -> Model.File_path (path, entry))
              files
        in
        (initial, List.rev operations, require_snapshot expected_entries)
    | value :: rest -> (
        let create () =
          let parent = nth directories (value + index) in
          let path =
            Path.to_components parent @ [ Printf.sprintf "created-%d" index ]
            |> require_path
          in
          let entry =
            file ~mode:(mode_from value) (generated_content index value)
          in
          let operation =
            Model.Create_file
              { path; content = entry.content; mode = entry.mode }
          in
          build (index + 1) ({ path; entry } :: files) (operation :: operations)
            rest
        in
        if files = [] || value mod 5 = 0 then create ()
        else
          let selected = nth files value in
          match value mod 5 with
          | 1 ->
              let replacement =
                file ~mode:selected.entry.mode (generated_content index value)
              in
              let operation =
                Model.Modify_file
                  {
                    path = selected.path;
                    expected_content = selected.entry.content;
                    replacement_content = replacement.content;
                  }
              in
              build (index + 1)
                (replace_file files selected.path
                   { selected with entry = replacement })
                (operation :: operations) rest
          | 2 ->
              let replacement =
                { selected.entry with mode = mode_from value }
              in
              let operation =
                Model.Change_mode
                  {
                    path = selected.path;
                    expected_mode = selected.entry.mode;
                    replacement_mode = replacement.mode;
                  }
              in
              build (index + 1)
                (replace_file files selected.path
                   { selected with entry = replacement })
                (operation :: operations) rest
          | 3 ->
              let operation =
                Model.Delete_path
                  { path = selected.path; prior = Model.File selected.entry }
              in
              build (index + 1)
                (remove_file files selected.path)
                (operation :: operations) rest
          | _ ->
              let destination =
                Path.to_components (nth directories (value + index))
                @ [ Printf.sprintf "moved-%d" index ]
                |> require_path
              in
              let operation =
                Model.Move_path
                  {
                    source = selected.path;
                    destination;
                    prior = Model.File selected.entry;
                  }
              in
              let moved = { selected with path = destination } in
              build (index + 1)
                (replace_file files selected.path moved)
                (operation :: operations) rest)
  in
  let initial, operations, expected = build 0 [] [] values in
  (directories, initial, operations, expected)

let scenario values =
  let _, initial, operations, expected = scenario_with_directories values in
  (initial, operations, expected)

let valid_operation_sequences =
  QCheck2.Gen.list_size
    (QCheck2.Gen.int_range 1 40)
    (QCheck2.Gen.int_range 0 1_000_000)

let initial_checkpoint snapshot =
  Checkpoint.initial ~snapshot ~created_at:0L ~retention:[]

let run_event_sequence initial operations =
  let rec apply index checkpoint applied = function
    | [] -> Ok (checkpoint, List.rev applied)
    | operation :: rest -> (
        let event =
          Scratch_event.create ~parent:(Checkpoint.id checkpoint)
            ~operations:[ operation ]
            ~observed_at:(Int64.of_int (index + 1))
            ~source:(if index land 1 = 0 then Explicit else Scan)
        in
        let retention =
          if index land 1 = 0 then [ Recent_window ] else [ Periodic_retention ]
        in
        match
          Scratch.apply_event ~parent:checkpoint
            ~created_at:(Int64.of_int (index + 101))
            ~retention event
        with
        | Error error -> Error error
        | Ok child -> apply (index + 1) child ((event, child) :: applied) rest)
  in
  apply 0 initial [] operations

let event_replay_property =
  QCheck2.Test.make ~count:500 ~name:"valid scratch events replay exactly"
    valid_operation_sequences (fun values ->
      let initial, operations, expected = scenario values in
      match run_event_sequence (initial_checkpoint initial) operations with
      | Error _ -> false
      | Ok (checkpoint, _) ->
          Snapshot.equal (Checkpoint.snapshot checkpoint) expected
          && Paengi_id.Snapshot_id.equal
               (Snapshot.id (Checkpoint.snapshot checkpoint))
               (Snapshot.id expected))

let deterministic_replay_property =
  QCheck2.Test.make ~count:500 ~name:"scratch event replay is deterministic"
    valid_operation_sequences (fun values ->
      let initial, operations, _ = scenario values in
      let parent = initial_checkpoint initial in
      match
        ( run_event_sequence parent operations,
          run_event_sequence parent operations )
      with
      | Ok (left, _), Ok (right, _) ->
          Id.Checkpoint_id.equal (Checkpoint.id left) (Checkpoint.id right)
          && Snapshot.equal (Checkpoint.snapshot left)
               (Checkpoint.snapshot right)
      | Error _, _ | _, Error _ -> false)

let parent_chains_are_coherent_property =
  QCheck2.Test.make ~count:500 ~name:"checkpoint parent chains are coherent"
    valid_operation_sequences (fun values ->
      let initial, operations, _ = scenario values in
      let parent = initial_checkpoint initial in
      match run_event_sequence parent operations with
      | Error _ -> false
      | Ok (_, applied) ->
          let rec coherent previous = function
            | [] -> true
            | (event, checkpoint) :: rest ->
                Option.equal Id.Checkpoint_id.equal
                  (Checkpoint.parent checkpoint)
                  (Some (Checkpoint.id previous))
                && Option.equal Id.Operation_id.equal
                     (Checkpoint.event checkpoint)
                     (Some (Scratch_event.id event))
                && Id.Checkpoint_id.equal
                     (Scratch_event.parent event)
                     (Checkpoint.id previous)
                && coherent checkpoint rest
          in
          coherent parent applied)

let invalid_operations_return_errors_property =
  QCheck2.Test.make ~count:500 ~name:"invalid scratch events return errors"
    valid_operation_sequences (fun values ->
      let directories, initial, _, _ = scenario_with_directories values in
      let parent = initial_checkpoint initial in
      let parent_snapshot_id = Snapshot.id (Checkpoint.snapshot parent) in
      let missing =
        Path.to_components (List.hd directories)
        @ [ Printf.sprintf "missing-%d" (List.length values) ]
        |> require_path
      in
      let event =
        Scratch_event.create ~parent:(Checkpoint.id parent)
          ~operations:
            [
              Modify_file
                {
                  path = missing;
                  expected_content = "before";
                  replacement_content = "after";
                };
            ]
          ~observed_at:1L ~source:Explicit
      in
      match Scratch.apply_event ~parent ~created_at:2L ~retention:[] event with
      | Error (Event_operation_rejected error) ->
          error.operation_index = 0
          && Id.Snapshot_id.equal parent_snapshot_id
               (Snapshot.id (Checkpoint.snapshot parent))
      | Error (Event_parent_mismatch _) | Ok _ -> false)

let metadata_does_not_change_snapshot_id_property =
  QCheck2.Test.make ~count:500
    ~name:"timestamps and retention do not change snapshot IDs"
    valid_operation_sequences (fun values ->
      let initial, operations, expected = scenario values in
      let parent = initial_checkpoint initial in
      let early =
        Scratch_event.create ~parent:(Checkpoint.id parent) ~operations
          ~observed_at:1L ~source:Explicit
      in
      let late =
        Scratch_event.create ~parent:(Checkpoint.id parent) ~operations
          ~observed_at:9_999L ~source:Scan
      in
      match
        ( Scratch.apply_event ~parent ~created_at:2L
            ~retention:[ Recent_window ] early,
          Scratch.apply_event ~parent ~created_at:8_888L
            ~retention:[ User_pinned; Periodic_retention; User_pinned ]
            late )
      with
      | Ok early_checkpoint, Ok late_checkpoint ->
          Paengi_id.Snapshot_id.equal
            (Snapshot.id (Checkpoint.snapshot early_checkpoint))
            (Snapshot.id (Checkpoint.snapshot late_checkpoint))
          && Paengi_id.Snapshot_id.equal
               (Snapshot.id (Checkpoint.snapshot early_checkpoint))
               (Snapshot.id expected)
      | Error _, _ | _, Error _ -> false)

let event_parent_mismatch_is_explicit () =
  let event_parent = initial_checkpoint (initial_snapshot ()) in
  let event =
    Scratch_event.create
      ~parent:(Checkpoint.id event_parent)
      ~operations:[] ~observed_at:1L ~source:Explicit
  in
  let other_parent =
    Checkpoint.initial ~snapshot:Snapshot.empty ~created_at:0L ~retention:[]
  in
  match
    Scratch.apply_event ~parent:other_parent ~created_at:2L ~retention:[] event
  with
  | Error (Event_parent_mismatch { expected_parent; actual_parent }) ->
      Alcotest.(check bool)
        "applying parent retained" true
        (Id.Checkpoint_id.equal expected_parent (Checkpoint.id other_parent));
      Alcotest.(check bool)
        "event parent retained" true
        (Id.Checkpoint_id.equal actual_parent (Checkpoint.id event_parent))
  | Error (Event_operation_rejected error) ->
      Alcotest.fail
        (event_transition_error_to_string (Event_operation_rejected error))
  | Ok _ -> Alcotest.fail "mismatched parent accepted"

let retention_is_normalised () =
  let checkpoint =
    Checkpoint.initial ~snapshot:(initial_snapshot ()) ~created_at:0L
      ~retention:[ Recent_window; User_pinned; Recent_window ]
  in
  Alcotest.(check (list string))
    "retention reasons are sorted and deduplicated"
    [ "user pinned"; "recent window" ]
    (List.map retention_reason_to_string (Checkpoint.retention checkpoint))

let checkpoint_records_event_metadata () =
  let parent = initial_checkpoint (initial_snapshot ()) in
  let event =
    Scratch_event.create ~parent:(Checkpoint.id parent) ~operations:[]
      ~observed_at:41L ~source:Scan
  in
  match
    Scratch.apply_event ~parent ~created_at:42L
      ~retention:[ Recent_window; User_pinned ]
      event
  with
  | Error error -> Alcotest.fail (event_transition_error_to_string error)
  | Ok checkpoint ->
      Alcotest.(check int64)
        "checkpoint timestamp" 42L
        (Checkpoint.created_at checkpoint);
      Alcotest.(check int64)
        "event timestamp" 41L
        (Scratch_event.observed_at event);
      Alcotest.(check bool)
        "event source" true
        (Scratch_event.source event = Scan);
      Alcotest.(check bool)
        "parent reference" true
        (Option.equal Id.Checkpoint_id.equal
           (Checkpoint.parent checkpoint)
           (Some (Checkpoint.id parent)));
      Alcotest.(check bool)
        "event reference" true
        (Option.equal Id.Operation_id.equal
           (Checkpoint.event checkpoint)
           (Some (Scratch_event.id event)));
      Alcotest.(check string)
        "snapshot identity"
        (Id.Snapshot_id.to_hex (Snapshot.id (Checkpoint.snapshot parent)))
        (Id.Snapshot_id.to_hex (Snapshot.id (Checkpoint.snapshot checkpoint)))

type history_error =
  | History_event_error of event_transition_error
  | History_repository_error of repository_error

let root_repository snapshot =
  let checkpoint = initial_checkpoint snapshot in
  match Repository.add_snapshot Repository.empty snapshot with
  | Error error -> Error (History_repository_error error)
  | Ok repository -> (
      match Repository.add_checkpoint repository checkpoint with
      | Error error -> Error (History_repository_error error)
      | Ok repository -> Ok (repository, checkpoint))

let add_transition ~event_first repository event checkpoint =
  let add_snapshot repository =
    Repository.add_snapshot repository (Checkpoint.snapshot checkpoint)
  in
  let add_event repository = Repository.add_event repository event in
  let add_checkpoint repository =
    Repository.add_checkpoint repository checkpoint
  in
  if event_first then
    match add_event repository with
    | Error error -> Error error
    | Ok repository -> (
        match add_snapshot repository with
        | Error error -> Error error
        | Ok repository -> add_checkpoint repository)
  else
    match add_snapshot repository with
    | Error error -> Error error
    | Ok repository -> (
        match add_event repository with
        | Error error -> Error error
        | Ok repository -> add_checkpoint repository)

let repository_history ?(event_first = false) initial operations =
  match root_repository initial with
  | Error error -> Error error
  | Ok (repository, root) ->
      let rec add index repository parent applied = function
        | [] -> Ok (repository, root, parent, List.rev applied)
        | operation :: rest -> (
            let event =
              Scratch_event.create ~parent:(Checkpoint.id parent)
                ~operations:[ operation ]
                ~observed_at:(Int64.of_int (index + 1))
                ~source:(if index land 1 = 0 then Explicit else Scan)
            in
            let retention =
              if index land 1 = 0 then [ Recent_window ]
              else [ Periodic_retention ]
            in
            match
              Scratch.apply_event ~parent
                ~created_at:(Int64.of_int (index + 101))
                ~retention event
            with
            | Error error -> Error (History_event_error error)
            | Ok checkpoint -> (
                match
                  add_transition ~event_first repository event checkpoint
                with
                | Error error -> Error (History_repository_error error)
                | Ok repository ->
                    add (index + 1) repository checkpoint
                      ((event, checkpoint) :: applied)
                      rest))
      in
      add 0 repository root [] operations

let has_repository_error expected = function
  | Error error -> String.equal (repository_error_to_string error) expected
  | Ok _ -> false

let repository_lookup_property =
  QCheck2.Test.make ~count:500
    ~name:"repository insertion and lookup preserve immutable values"
    valid_operation_sequences (fun values ->
      let initial, operations, expected = scenario values in
      match repository_history initial operations with
      | Error _ -> false
      | Ok (repository, root, target, (event, _) :: _) -> (
          match
            ( Repository.find_snapshot repository (Snapshot.id initial),
              Repository.find_snapshot repository (Snapshot.id expected),
              Repository.find_event repository (Scratch_event.id event),
              Repository.find_checkpoint repository (Checkpoint.id target) )
          with
          | ( Some stored_initial,
              Some stored_expected,
              Some stored_event,
              Some stored_checkpoint ) ->
              Snapshot.equal stored_initial initial
              && Snapshot.equal stored_expected expected
              && Id.Operation_id.equal
                   (Scratch_event.id stored_event)
                   (Scratch_event.id event)
              && Id.Checkpoint_id.equal
                   (Checkpoint.id stored_checkpoint)
                   (Checkpoint.id target)
              && Snapshot.equal
                   (Checkpoint.snapshot stored_checkpoint)
                   (Checkpoint.snapshot target)
              && Id.Checkpoint_id.equal (Checkpoint.id root)
                   (Scratch_event.parent stored_event)
          | None, _, _, _ | _, None, _, _ | _, _, None, _ | _, _, _, None ->
              false)
      | Ok (_, _, _, []) -> false)

let repository_replay_property =
  QCheck2.Test.make ~count:500
    ~name:"repository replay reaches the target snapshot"
    valid_operation_sequences (fun values ->
      let initial, operations, expected = scenario values in
      match repository_history initial operations with
      | Error _ -> false
      | Ok (repository, root, target, _) -> (
          match
            Repository.replay repository ~ancestor:(Checkpoint.id root)
              ~target:(Checkpoint.id target)
          with
          | Ok replayed -> Snapshot.equal replayed expected
          | Error _ -> false))

let repository_insertion_order_property =
  QCheck2.Test.make ~count:500
    ~name:"repository insertion order preserves identities and replay"
    valid_operation_sequences (fun values ->
      let initial, operations, expected = scenario values in
      match
        ( repository_history ~event_first:false initial operations,
          repository_history ~event_first:true initial operations )
      with
      | ( Ok (left_repository, left_root, left_target, _),
          Ok (right_repository, right_root, right_target, _) ) -> (
          match
            ( Repository.replay left_repository
                ~ancestor:(Checkpoint.id left_root)
                ~target:(Checkpoint.id left_target),
              Repository.replay right_repository
                ~ancestor:(Checkpoint.id right_root)
                ~target:(Checkpoint.id right_target) )
          with
          | Ok left, Ok right ->
              Id.Checkpoint_id.equal
                (Checkpoint.id left_target)
                (Checkpoint.id right_target)
              && Option.equal Id.Checkpoint_id.equal
                   (Repository.scratch_head left_repository)
                   (Repository.scratch_head right_repository)
              && Snapshot.equal left right
              && Snapshot.equal left expected
          | Error _, _ | _, Error _ -> false)
      | Error _, _ | _, Error _ -> false)

let repository_duplicate_property =
  QCheck2.Test.make ~count:500
    ~name:"identical repository insertion is idempotent"
    valid_operation_sequences (fun values ->
      let initial, operations, expected = scenario values in
      match repository_history initial operations with
      | Error _ -> false
      | Ok (repository, root, target, (event, _) :: _) -> (
          match
            ( Repository.add_snapshot repository initial,
              Repository.add_event repository event,
              Repository.add_checkpoint repository target )
          with
          | Ok after_snapshot, Ok after_event, Ok after_checkpoint -> (
              match
                Repository.replay after_checkpoint
                  ~ancestor:(Checkpoint.id root) ~target:(Checkpoint.id target)
              with
              | Ok replayed ->
                  Option.equal Id.Checkpoint_id.equal
                    (Repository.scratch_head repository)
                    (Repository.scratch_head after_snapshot)
                  && Option.equal Id.Checkpoint_id.equal
                       (Repository.scratch_head repository)
                       (Repository.scratch_head after_event)
                  && Option.equal Id.Checkpoint_id.equal
                       (Repository.scratch_head repository)
                       (Repository.scratch_head after_checkpoint)
                  && Snapshot.equal replayed expected
              | Error _ -> false)
          | Error _, _, _ | _, Error _, _ | _, _, Error _ -> false)
      | Ok (_, _, _, []) -> false)

let repository_conflicting_duplicate_property =
  QCheck2.Test.make ~count:500
    ~name:"conflicting duplicate repository IDs are rejected"
    valid_operation_sequences (fun values ->
      let initial, operations, _ = scenario values in
      match repository_history initial operations with
      | Error _ -> false
      | Ok (repository, _, target, (event, _) :: _) ->
          let conflicting_event =
            Scratch_event.create
              ~parent:(Scratch_event.parent event)
              ~operations:[] ~observed_at:999L ~source:Scan
          in
          let conflicting_checkpoint =
            Checkpoint.initial ~snapshot:Snapshot.empty ~created_at:999L
              ~retention:[]
          in
          let snapshot_conflict =
            Repository.insert_snapshot repository ~id:(Snapshot.id initial)
              Snapshot.empty
            |> has_repository_error
                 (Printf.sprintf "conflicting snapshot: %s"
                    (Id.Snapshot_id.short_hex (Snapshot.id initial)))
          in
          let event_conflict =
            Repository.insert_event repository ~id:(Scratch_event.id event)
              conflicting_event
            |> has_repository_error
                 (Printf.sprintf "conflicting event: %s"
                    (Id.Operation_id.short_hex (Scratch_event.id event)))
          in
          let checkpoint_conflict =
            Repository.insert_checkpoint repository ~id:(Checkpoint.id target)
              conflicting_checkpoint
            |> has_repository_error
                 (Printf.sprintf "conflicting checkpoint: %s"
                    (Id.Checkpoint_id.short_hex (Checkpoint.id target)))
          in
          snapshot_conflict && event_conflict && checkpoint_conflict
      | Ok (_, _, _, []) -> false)

let repository_rejection_property =
  QCheck2.Test.make ~count:500
    ~name:"missing and incoherent references reject without mutation"
    valid_operation_sequences (fun values ->
      let _, initial, operations, _ = scenario_with_directories values in
      match (root_repository initial, operations) with
      | Ok (repository, root), operation :: _ ->
          let valid_event =
            Scratch_event.create ~parent:(Checkpoint.id root)
              ~operations:[ operation ] ~observed_at:1L ~source:Explicit
          in
          let child =
            match
              Scratch.apply_event ~parent:root ~created_at:2L ~retention:[]
                valid_event
            with
            | Ok checkpoint -> checkpoint
            | Error _ -> assert false
          in
          let missing_parent =
            Checkpoint.initial ~snapshot:Snapshot.empty ~created_at:3L
              ~retention:[]
          in
          let missing_parent_event =
            Scratch_event.create
              ~parent:(Checkpoint.id missing_parent)
              ~operations:[] ~observed_at:4L ~source:Scan
          in
          let missing_event =
            match
              Repository.add_snapshot repository (Checkpoint.snapshot child)
            with
            | Error _ -> false
            | Ok repository_with_snapshot ->
                Repository.add_checkpoint repository_with_snapshot child
                |> fun result ->
                has_repository_error
                  (Printf.sprintf "missing event: %s"
                     (Id.Operation_id.short_hex (Scratch_event.id valid_event)))
                  result
                && Option.equal Id.Checkpoint_id.equal
                     (Repository.scratch_head repository_with_snapshot)
                     (Some (Checkpoint.id root))
          in
          let incoherent_checkpoint =
            Checkpoint.create
              ~parent:(Some (Checkpoint.id root))
              ~snapshot:(Checkpoint.snapshot root)
              ~event:(Some (Scratch_event.id valid_event))
              ~created_at:5L ~retention:[]
          in
          let missing_parent_rejected =
            Repository.add_event repository missing_parent_event
            |> has_repository_error
                 (Printf.sprintf "event parent missing: %s"
                    (Id.Checkpoint_id.short_hex (Checkpoint.id missing_parent)))
          in
          let incoherent_rejected =
            match Repository.add_event repository valid_event with
            | Error _ -> false
            | Ok repository_with_event ->
                Repository.add_checkpoint repository_with_event
                  incoherent_checkpoint
                |> fun result ->
                has_repository_error
                  (Printf.sprintf "incoherent checkpoint: %s"
                     (Id.Checkpoint_id.short_hex
                        (Checkpoint.id incoherent_checkpoint)))
                  result
                && Option.equal Id.Checkpoint_id.equal
                     (Repository.scratch_head repository_with_event)
                     (Some (Checkpoint.id root))
          in
          missing_event && missing_parent_rejected && incoherent_rejected
      | Error _, _ | _, [] -> false)

let complete_history_property =
  QCheck2.Test.make ~count:500
    ~name:"generated directory histories preserve all scratch operation states"
    valid_operation_sequences (fun values ->
      let directories = generated_directories values in
      let initial =
        List.map (fun path -> Directory_path path) directories
        |> require_snapshot
      in
      let source = List.hd directories in
      let destination_parent = List.hd (List.rev directories) in
      let draft =
        Path.to_components source @ [ "all-operations" ] |> require_path
      in
      let moved =
        Path.to_components destination_parent @ [ "all-operations-moved" ]
        |> require_path
      in
      let operations =
        [
          Create_file { path = draft; content = "one"; mode = Regular };
          Modify_file
            {
              path = draft;
              expected_content = "one";
              replacement_content = "two";
            };
          Change_mode
            {
              path = draft;
              expected_mode = Regular;
              replacement_mode = Executable;
            };
          Move_path
            {
              source = draft;
              destination = moved;
              prior = File { mode = Executable; content = "two" };
            };
          Delete_path
            {
              path = moved;
              prior = File { mode = Executable; content = "two" };
            };
        ]
      in
      match repository_history initial operations with
      | Error _ -> false
      | Ok (repository, root, target, _) -> (
          match
            Repository.replay repository ~ancestor:(Checkpoint.id root)
              ~target:(Checkpoint.id target)
          with
          | Ok replayed -> Snapshot.equal replayed initial
          | Error _ -> false))

let property_case name test =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick ~rand:(state_for name) test

let () =
  Alcotest.run "in-memory snapshot model"
    [
      ( "unit",
        [
          Alcotest.test_case "operations preserve exact bytes and modes" `Quick
            operations_apply_exact_bytes_and_modes;
          Alcotest.test_case "directory moves preserve descendants" `Quick
            directory_moves_preserve_descendants;
          Alcotest.test_case "preconditions fail without mutation" `Quick
            preconditions_fail_without_mutating_snapshot;
          Alcotest.test_case "paths reject unsafe components" `Quick
            paths_reject_unsafe_components;
          Alcotest.test_case "snapshot identity is canonical" `Quick
            snapshot_identity_is_canonical;
          Alcotest.test_case "event parent mismatch is explicit" `Quick
            event_parent_mismatch_is_explicit;
          Alcotest.test_case "retention is normalised" `Quick
            retention_is_normalised;
          Alcotest.test_case "checkpoint records event metadata" `Quick
            checkpoint_records_event_metadata;
        ] );
      ( "property",
        [
          property_case "event-replay" event_replay_property;
          property_case "event-determinism" deterministic_replay_property;
          property_case "checkpoint-parent-chain"
            parent_chains_are_coherent_property;
          property_case "invalid-event"
            invalid_operations_return_errors_property;
          property_case "snapshot-metadata"
            metadata_does_not_change_snapshot_id_property;
          property_case "repository-lookup" repository_lookup_property;
          property_case "repository-replay" repository_replay_property;
          property_case "repository-insertion-order"
            repository_insertion_order_property;
          property_case "repository-duplicate" repository_duplicate_property;
          property_case "repository-conflict"
            repository_conflicting_duplicate_property;
          property_case "repository-rejection" repository_rejection_property;
          property_case "complete-history" complete_history_property;
        ] );
    ]
