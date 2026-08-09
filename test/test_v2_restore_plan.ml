module Model = Yeokcham_model
module Restore = Yeokcham_v2_restore_plan

[@@@warning "-4"]

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let snapshot entries =
  Model.Snapshot.of_entries entries
  |> require_ok Model.construction_error_to_string

let file components ~mode content =
  Model.File_path (path components, { Model.mode; content })

let directory components = Model.Directory_path (path components)

let assert_replays plan =
  Restore.replay plan |> require_ok Restore.replay_error_to_string
  |> fun replayed ->
  Alcotest.(check bool)
    "restore-plan replay reaches exact target" true
    (Model.Snapshot.equal replayed (Restore.target plan))

let exact_entries_replay_in_safe_order () =
  let observed = snapshot [] in
  let target =
    snapshot
      [
        directory [ "nested" ];
        file [ "nested"; "bytes" ] ~mode:Model.Regular "a\000b";
        file [ "tool" ] ~mode:Model.Executable "#!/bin/sh\n";
        file [ "link" ] ~mode:Model.Symlink "../target\000raw";
      ]
  in
  let plan = Restore.build ~observed ~target in
  Alcotest.(check bool)
    "changed restore is not a no-op" false (Restore.is_noop plan);
  (match Restore.safety_snapshot plan with
  | Some safety ->
      Alcotest.(check bool)
        "changed restore requires exact safety snapshot" true
        (Model.Snapshot.equal observed safety)
  | None -> Alcotest.fail "changed restore omitted safety snapshot");
  (match Restore.actions plan with
  | [
   Restore.Ensure_directory nested;
   Restore.Create_symlink { path = link; target = link_target };
   Restore.Write_file { path = bytes; content; mode = Model.Regular };
   Restore.Write_file
     { path = tool; content = tool_content; mode = Model.Executable };
  ] ->
      Alcotest.(check string)
        "directory is made before children" "nested"
        (Model.Path.to_string nested);
      Alcotest.(check string) "symlink path" "link" (Model.Path.to_string link);
      Alcotest.(check string)
        "raw symlink target remains exact" "../target\000raw" link_target;
      Alcotest.(check string)
        "regular path" "nested/bytes"
        (Model.Path.to_string bytes);
      Alcotest.(check string) "regular bytes remain exact" "a\000b" content;
      Alcotest.(check string)
        "executable path" "tool"
        (Model.Path.to_string tool);
      Alcotest.(check string)
        "executable bytes remain exact" "#!/bin/sh\n" tool_content
  | actions ->
      Alcotest.failf "unexpected action order: %s"
        (String.concat ", " (List.map Restore.action_to_string actions)));
  assert_replays plan

let replacement_removes_children_before_parent () =
  let observed =
    snapshot
      [
        directory [ "old" ];
        file [ "old"; "child" ] ~mode:Model.Regular "old";
        file [ "kind" ] ~mode:Model.Regular "file";
        file [ "link" ] ~mode:Model.Symlink "before";
      ]
  in
  let target =
    snapshot
      [
        file [ "old" ] ~mode:Model.Symlink "after";
        directory [ "kind" ];
        file [ "kind"; "child" ] ~mode:Model.Executable "new";
        file [ "link" ] ~mode:Model.Regular "regular";
      ]
  in
  let plan = Restore.build ~observed ~target in
  (match Restore.actions plan with
  | [
   Restore.Remove_file old_child;
   Restore.Remove_file kind;
   Restore.Remove_file link;
   Restore.Remove_directory old;
   Restore.Ensure_directory ensured_kind;
   Restore.Write_file { path = written_kind_child; _ };
   Restore.Write_file { path = written_link; _ };
   Restore.Create_symlink { path = created_old; target };
  ] ->
      Alcotest.(check string)
        "child is deleted first" "old/child"
        (Model.Path.to_string old_child);
      Alcotest.(check string)
        "file is removed before directory replacement" "kind"
        (Model.Path.to_string kind);
      Alcotest.(check string)
        "symlink is removed before regular replacement" "link"
        (Model.Path.to_string link);
      Alcotest.(check string)
        "empty old directory is deleted" "old" (Model.Path.to_string old);
      Alcotest.(check string)
        "target directory is then created" "kind"
        (Model.Path.to_string ensured_kind);
      Alcotest.(check string)
        "directory child follows parent" "kind/child"
        (Model.Path.to_string written_kind_child);
      Alcotest.(check string)
        "regular replacement is explicit" "link"
        (Model.Path.to_string written_link);
      Alcotest.(check string) "replacement symlink target" "after" target;
      Alcotest.(check string)
        "replacement symlink path" "old"
        (Model.Path.to_string created_old)
  | actions ->
      Alcotest.failf "unexpected replacement plan: %s"
        (String.concat ", " (List.map Restore.action_to_string actions)));
  assert_replays plan

let exact_target_is_a_noop () =
  let exact =
    snapshot
      [
        directory [ "dir" ];
        file [ "dir"; "same" ] ~mode:Model.Regular "same\000bytes";
      ]
  in
  let plan = Restore.build ~observed:exact ~target:exact in
  Alcotest.(check bool) "equal snapshots are no-op" true (Restore.is_noop plan);
  Alcotest.(check int)
    "equal snapshots have no actions" 0
    (List.length (Restore.actions plan));
  Alcotest.(check bool)
    "equal snapshots need no safety checkpoint" true
    (Option.is_none (Restore.safety_snapshot plan));
  assert_replays plan

let mode_only_change_is_not_a_content_rewrite () =
  let observed = snapshot [ file [ "tool" ] ~mode:Model.Regular "same" ] in
  let target = snapshot [ file [ "tool" ] ~mode:Model.Executable "same" ] in
  let plan = Restore.build ~observed ~target in
  (match Restore.actions plan with
  | [ Restore.Set_file_mode { path; mode = Model.Executable } ] ->
      Alcotest.(check string)
        "mode change path" "tool"
        (Model.Path.to_string path)
  | actions ->
      Alcotest.failf "expected only a mode action, got: %s"
        (String.concat ", " (List.map Restore.action_to_string actions)));
  assert_replays plan

let () =
  Alcotest.run "V2 exact restore planning"
    [
      ( "unit",
        [
          Alcotest.test_case "exact entries replay in safe order" `Quick
            exact_entries_replay_in_safe_order;
          Alcotest.test_case "replacement removes children before parent" `Quick
            replacement_removes_children_before_parent;
          Alcotest.test_case "exact target is a no-op" `Quick
            exact_target_is_a_noop;
          Alcotest.test_case "mode-only change avoids content rewrite" `Quick
            mode_only_change_is_not_a_content_rewrite;
        ] );
    ]
