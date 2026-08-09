module Model = Yeokcham_model
module Restore = Yeokcham_v2_restore_plan

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "V2 restore-plan property base seed: %d\n%!" base_seed
let entry_path = Model.Path.of_components [ "entry" ] |> Result.get_ok
let directory_path = Model.Path.of_components [ "directory" ] |> Result.get_ok

let child_path =
  Model.Path.of_components [ "directory"; "child" ] |> Result.get_ok

let snapshot (directory, child, entry) =
  let directory = directory || Option.is_some child in
  let child_entries =
    match child with
    | None -> []
    | Some (mode, content) ->
        [ Model.File_path (child_path, { Model.mode; content }) ]
  in
  let entry_entries =
    match entry with
    | None -> []
    | Some (mode, content) ->
        [ Model.File_path (entry_path, { Model.mode; content }) ]
  in
  let entries =
    (if directory then [ Model.Directory_path directory_path ] else [])
    @ child_entries @ entry_entries
  in
  Model.Snapshot.of_entries entries |> Result.get_ok

let generated_file =
  QCheck2.Gen.(
    pair
      (oneof_list [ Model.Regular; Model.Executable; Model.Symlink ])
      (string_size (int_range 0 4096)))

let generated_snapshot =
  QCheck2.Gen.(triple bool (option generated_file) (option generated_file))

let plans_replay_generated_exact_snapshots =
  QCheck2.Test.make ~count:180
    ~name:"V2 restore plans replay generated exact snapshot pairs"
    QCheck2.Gen.(pair generated_snapshot generated_snapshot)
    (fun (observed, target) ->
      let observed = snapshot observed and target = snapshot target in
      let plan = Restore.build ~observed ~target in
      match Restore.replay plan with
      | Error _ -> false
      | Ok replayed ->
          let equal = Model.Snapshot.equal observed target in
          Model.Snapshot.equal replayed target
          && Bool.equal (Restore.is_noop plan) equal
          && Bool.equal (Option.is_none (Restore.safety_snapshot plan)) equal
          && List.equal String.equal
               (List.map Restore.action_to_string (Restore.actions plan))
               (List.map Restore.action_to_string
                  (Restore.actions (Restore.build ~observed ~target))))

let () =
  Alcotest.run "V2 exact restore planning properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-snapshot-pairs")
            plans_replay_generated_exact_snapshots;
        ] );
    ]
