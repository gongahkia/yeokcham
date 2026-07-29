module Model = Paengi_model
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

let scenario values =
  let directories = [ source; archive; nested ] in
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
          let parent = if value land 1 = 0 then source else nested in
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
                require_path [ "archive"; Printf.sprintf "moved-%d" index ]
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
  build 0 [] [] values

let valid_operation_sequences =
  QCheck2.Gen.list_size
    (QCheck2.Gen.int_range 1 40)
    (QCheck2.Gen.int_range 0 1_000_000)

let replay_property =
  QCheck2.Test.make ~count:500 ~name:"valid scratch operations replay exactly"
    valid_operation_sequences (fun values ->
      let initial, operations, expected = scenario values in
      match Snapshot.apply_operations initial operations with
      | Error _ -> false
      | Ok replayed ->
          Snapshot.equal replayed expected
          && Paengi_id.Snapshot_id.equal (Snapshot.id replayed)
               (Snapshot.id expected))

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
        ] );
      ("property", [ property_case "scratch-replay" replay_property ]);
    ]
