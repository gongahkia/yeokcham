module Git = Paengi_git
module Id = Paengi_id
module Snapshot = Paengi_snapshot
module Store = Paengi_store

let default_seed = 20_260_805

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let stable_seed name =
  String.fold_left
    (fun state character -> state * 65599 lxor Char.code character land max_int)
    base_seed name

let () = Printf.printf "Git property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_directory prefix run =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let direct_process executable arguments =
  let child =
    Unix.create_process executable
      (Array.of_list (executable :: arguments))
      Unix.stdin Unix.stdout Unix.stderr
  in
  match Unix.waitpid [] child with
  | _, Unix.WEXITED 0 -> true
  | _, Unix.WEXITED _ | _, Unix.WSIGNALED _ | _, Unix.WSTOPPED _ -> false

let direct_capture executable arguments =
  let channel =
    Unix.open_process_args_in executable
      (Array.of_list (executable :: arguments))
  in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> Some (String.trim output)
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None

let git_path () =
  [ "/opt/homebrew/bin/git"; "/usr/local/bin/git"; "/usr/bin/git" ]
  |> List.find_opt (fun candidate ->
      try
        Unix.access candidate [ Unix.X_OK ];
        true
      with Unix.Unix_error _ -> false)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let import_replays_generated_file (bytes, executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "paengi-git-property-" (fun root ->
          let repository = Filename.concat root "repository" in
          let store_root = Filename.concat root "store" in
          let destination = Filename.concat root "destination" in
          Unix.mkdir repository 0o700;
          Unix.mkdir store_root 0o700;
          Unix.mkdir destination 0o700;
          write_file (Filename.concat repository "generated") bytes;
          if executable then
            Unix.chmod (Filename.concat repository "generated") 0o755;
          if not (direct_process git [ "init"; "-q"; repository ]) then false
          else if not (direct_process git [ "-C"; repository; "add"; "--all" ])
          then false
          else
            match direct_capture git [ "-C"; repository; "write-tree" ] with
            | None -> false
            | Some tree_hex -> (
                match Store.init ~root:store_root with
                | Error _ -> false
                | Ok store -> (
                    match Git.inspect Git.default_configuration ~repository with
                    | Error _ -> false
                    | Ok inspection -> (
                        match
                          Git.object_id_of_hex
                            (Git.inspection_object_format inspection)
                            tree_hex
                        with
                        | Error _ -> false
                        | Ok tree -> (
                            match
                              ( Git.import_tree Git.default_configuration ~store
                                  ~repository ~tree,
                                Git.import_tree Git.default_configuration ~store
                                  ~repository ~tree )
                            with
                            | Ok first, Ok second -> (
                                match
                                  Snapshot.Snapshot.load store
                                    first.Git.snapshot
                                with
                                | Error _ -> false
                                | Ok snapshot -> (
                                    match
                                      Snapshot.Materialize.write ~destination
                                        store snapshot
                                    with
                                    | Error _ -> false
                                    | Ok () ->
                                        String.equal bytes
                                          (read_file
                                             (Filename.concat destination
                                                "generated"))
                                        && Bool.equal executable
                                             ((Unix.stat
                                                 (Filename.concat destination
                                                    "generated"))
                                                .Unix.st_perm land 0o111
                                             <> 0)
                                        && Snapshot.Snapshot.equal_id
                                             first.Git.snapshot
                                             second.Git.snapshot
                                        && Id.Git_mapping_id.equal
                                             (Git.mapping_id first.Git.mapping)
                                             (Git.mapping_id second.Git.mapping)
                                    ))
                            | Error _, _ | _, Error _ -> false)))))

let generated_files =
  QCheck2.Test.make ~count:25
    ~name:"Git tree import materialises generated bytes and mode exactly"
    QCheck2.Gen.(pair (string_size (int_range 0 4096)) bool)
    import_replays_generated_file

let option_of_result = function Ok value -> Some value | Error _ -> None

let import_replays_generated_commit (bytes, executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "paengi-git-commit-property-" (fun root ->
          let repository = Filename.concat root "repository" in
          let store_root = Filename.concat root "store" in
          let destination = Filename.concat root "destination" in
          Unix.mkdir repository 0o700;
          Unix.mkdir store_root 0o700;
          Unix.mkdir destination 0o700;
          if not (direct_process git [ "init"; "-q"; repository ]) then false
          else if
            not
              (direct_process git
                 [ "-C"; repository; "config"; "user.name"; "Paengi Test" ])
          then false
          else if
            not
              (direct_process git
                 [
                   "-C";
                   repository;
                   "config";
                   "user.email";
                   "test@example.invalid";
                 ])
          then false
          else (
            write_file (Filename.concat repository "base") "base\n";
            if not (direct_process git [ "-C"; repository; "add"; "--all" ])
            then false
            else if
              not
                (direct_process git
                   [ "-C"; repository; "commit"; "-q"; "-m"; "base" ])
            then false
            else (
              write_file (Filename.concat repository "generated") bytes;
              if executable then
                Unix.chmod (Filename.concat repository "generated") 0o755;
              if
                not (direct_process git [ "-C"; repository; "add"; "--all" ])
              then false
              else if
                not
                  (direct_process git
                     [ "-C"; repository; "commit"; "-q"; "-m"; "generated" ])
              then false
              else
                match
                  ( direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ],
                    direct_capture git
                      [ "-C"; repository; "rev-parse"; "HEAD^" ],
                    Store.init ~root:store_root |> option_of_result )
                with
                | Some commit_hex, Some parent_hex, Some store -> (
                    match
                      Git.inspect Git.default_configuration ~repository
                      |> option_of_result
                    with
                    | None -> false
                    | Some inspection -> (
                        match
                          Git.object_id_of_hex
                            (Git.inspection_object_format inspection)
                            commit_hex
                          |> option_of_result
                        with
                        | None -> false
                        | Some commit -> (
                            match
                              ( Git.import_commit Git.default_configuration
                                  ~store ~repository ~commit,
                                Git.import_commit Git.default_configuration
                                  ~store ~repository ~commit )
                            with
                            | Ok first, Ok second -> (
                                let transition = first.Git.imported_transition in
                                match
                                  Snapshot.Snapshot.load store
                                    (Git.imported_transition_snapshot transition)
                                with
                                | Error _ -> false
                                | Ok snapshot -> (
                                    match
                                      Snapshot.Materialize.write ~destination
                                        store snapshot
                                    with
                                    | Error _ -> false
                                    | Ok () ->
                                        String.equal bytes
                                          (read_file
                                             (Filename.concat destination
                                                "generated"))
                                        && Bool.equal executable
                                             ((Unix.stat
                                                 (Filename.concat destination
                                                    "generated"))
                                                .Unix.st_perm land 0o111
                                             <> 0)
                                        && List.map Git.object_id_to_hex
                                             (Git.imported_transition_parents
                                                transition)
                                           = [ parent_hex ]
                                        && Id.Imported_transition_id.equal
                                             (Git.imported_transition_id
                                                first.Git.imported_transition)
                                             (Git.imported_transition_id
                                                second.Git.imported_transition)
                                        && Id.Git_mapping_id.equal
                                             (Git.mapping_id first.Git.commit_mapping)
                                             (Git.mapping_id second.Git.commit_mapping)
                                    ))
                            | Error _, _ | _, Error _ -> false)))
                | _ -> false)))

let generated_commits =
  QCheck2.Test.make ~count:15
    ~name:"Git commit import preserves generated snapshot and ordered parent"
    QCheck2.Gen.(pair (string_size (int_range 0 4096)) bool)
    import_replays_generated_commit

let () =
  Alcotest.run "Git properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-files")
            generated_files;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-commits")
            generated_commits;
        ] );
    ]
