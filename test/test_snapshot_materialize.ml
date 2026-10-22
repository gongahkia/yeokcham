module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
  | Unix.S_SOCK ->
      Unix.unlink path

let with_directory run =
  let path = Filename.temp_file "yeokcham-materialize-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun output ->
      Out_channel.output_string output contents)

let snapshot store entries =
  let root =
    Snapshot.Tree.create entries
    |> require_ok Snapshot.error_to_string
    |> Snapshot.Tree.store store
    |> require_ok Snapshot.error_to_string
  in
  Snapshot.Snapshot.create ~root

let file store mode bytes =
  let content =
    Snapshot.Content.store store bytes |> require_ok Snapshot.error_to_string
  in
  Snapshot.Tree.File { mode; content }

let[@warning "-4"] invalid_symlink_is_rejected_before_output () =
  List.iter
    (fun invalid_target ->
      with_directory (fun root ->
          let store = Store.init ~root |> require_ok Store.error_to_string in
          let target =
            snapshot store
              [
                ("a.txt", file store Snapshot.Regular "valid");
                ("z-link", file store Snapshot.Symlink invalid_target);
              ]
          in
          let expect_invalid = function
            | Error (Snapshot.Materialize.Invalid_symlink_target [ "z-link" ])
              ->
                ()
            | Error error ->
                Alcotest.fail (Snapshot.Materialize.error_to_string error)
            | Ok () -> Alcotest.fail "materialized an invalid symlink"
          in
          with_directory (fun destination ->
              Snapshot.Materialize.write ~destination store target
              |> expect_invalid;
              Alcotest.(check int)
                "no partial output" 0
                (Array.length (Sys.readdir destination));
              write_file destination "keep.txt" "unsaved";
              Snapshot.Materialize.write_replacing ~destination
                ~preserved_root_names:[] store target
              |> expect_invalid;
              Alcotest.(check string)
                "invalid replacement preserves bytes" "unsaved"
                (In_channel.with_open_bin
                   (Filename.concat destination "keep.txt")
                   In_channel.input_all))))
    [ "invalid\000target"; "" ]

let[@warning "-4"] replacement_refuses_preserved_names_and_symlink_roots () =
  with_directory (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      with_directory (fun destination ->
          write_file destination "keep.txt" "unsaved";
          let target =
            snapshot store [ (".git", file store Snapshot.Regular "overwrite") ]
          in
          (match
             Snapshot.Materialize.write_replacing ~destination
               ~preserved_root_names:[ ".git" ] store target
           with
          | Error (Snapshot.Materialize.Unsafe_destination_path [ ".git" ]) ->
              ()
          | Error error ->
              Alcotest.fail (Snapshot.Materialize.error_to_string error)
          | Ok () -> Alcotest.fail "replacement wrote preserved metadata");
          let link = Filename.concat root "destination-link" in
          Unix.symlink destination link;
          (match
             Snapshot.Materialize.write_replacing ~destination:link
               ~preserved_root_names:[] store (snapshot store [])
           with
          | Error (Snapshot.Materialize.Destination_not_directory _) -> ()
          | Error error ->
              Alcotest.fail (Snapshot.Materialize.error_to_string error)
          | Ok () -> Alcotest.fail "replacement followed a symlink root");
          Alcotest.(check string)
            "ordinary file survives both refusals" "unsaved"
            (In_channel.with_open_bin
               (Filename.concat destination "keep.txt")
               In_channel.input_all)))

let ignored_path_check_does_not_follow_symlink_ancestors () =
  with_directory (fun root ->
      with_directory (fun outside ->
          write_file outside "secret" "outside";
          Unix.symlink outside (Filename.concat root "link");
          Unix.mkdir (Filename.concat root ".git") 0o700;
          write_file root ".yeokchamignore" "link/secret\n.git\nabsent\n";
          Snapshot.require_no_ignored_paths ~excluded_root_names:[ ".git" ]
            ~root
          |> require_ok Snapshot.error_to_string))

let () =
  Alcotest.run "Snapshot materialisation"
    [
      ( "preflight",
        [
          Alcotest.test_case "invalid symlink has no partial output" `Quick
            invalid_symlink_is_rejected_before_output;
          Alcotest.test_case "replacement protects metadata and symlink roots"
            `Quick replacement_refuses_preserved_names_and_symlink_roots;
          Alcotest.test_case "ignore check respects filesystem boundaries"
            `Quick ignored_path_check_does_not_follow_symlink_ancestors;
        ] );
    ]
