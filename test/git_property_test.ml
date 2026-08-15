module Git = Yeokcham_git
module Capsule_store = Yeokcham_capsule_store
module Id = Yeokcham_id
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Workspace_store = Yeokcham_workspace_store

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

let direct_capture_with_environment executable environment arguments =
  let reader, writer = Unix.pipe () in
  let child =
    Unix.create_process_env executable
      (Array.of_list (executable :: arguments))
      environment Unix.stdin writer Unix.stderr
  in
  Unix.close writer;
  let channel = Unix.in_channel_of_descr reader in
  let output = In_channel.input_all channel in
  In_channel.close channel;
  match Unix.waitpid [] child with
  | _, Unix.WEXITED 0 -> Some (String.trim output)
  | _, Unix.WEXITED _ | _, Unix.WSIGNALED _ | _, Unix.WSTOPPED _ -> None

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

let export_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let export_capsule_id seed =
  Id.Capsule_id.of_bytes (export_id seed) |> Result.get_ok

let export_workspace_id seed =
  Id.Workspace_id.of_bytes (export_id seed) |> Result.get_ok

let export_checkpoint scratch snapshot time =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:time ~created_at:time
  |> Result.get_ok
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let detached_adoption_checkpoints store ~source ~target =
  match
    ( Scratch.Checkpoint.store store
        (Scratch.Checkpoint.create_initial ~snapshot:source ~created_at:0L),
      Snapshot.Snapshot.load store source,
      Snapshot.Snapshot.load store target )
  with
  | Ok source_checkpoint, Ok source_snapshot, Ok target_snapshot -> (
      match
        ( Scratch.State.of_snapshot store source_snapshot,
          Scratch.State.of_snapshot store target_snapshot )
      with
      | Ok source_state, Ok target_state -> (
          let operations =
            Scratch.State.diff ~from:source_state ~to_:target_state
          in
          match Scratch.State.apply source_state operations with
          | Error _ -> None
          | Ok replayed when not (Scratch.State.equal replayed target_state) ->
              None
          | Ok _ -> (
              let event =
                Scratch.Event.create ~parent:source_checkpoint ~base:source
                  ~resulting:target ~operations ~source:Scratch.Explicit
                  ~observed_at:0L
              in
              match Scratch.Event.store store event with
              | Error _ -> None
              | Ok event ->
                  Scratch.Checkpoint.create ~parent:source_checkpoint ~event
                    ~snapshot:target ~created_at:0L
                  |> Scratch.Checkpoint.store store
                  |> Result.to_option
                  |> Option.map (fun target -> (source_checkpoint, target))))
      | Error _, _ | _, Error _ -> None)
  | Error _, _, _ | _, Error _, _ | _, _, Error _ -> None

let import_replays_generated_file (bytes, executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-property-" (fun root ->
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

let export_replays_generated_release ?metadata (bytes, executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-export-property-" (fun root ->
          let worktree = Filename.concat root "worktree" in
          let destination = Filename.concat root "destination" in
          Unix.mkdir worktree 0o700;
          Unix.mkdir destination 0o700;
          write_file (Filename.concat worktree "base") "base\n";
          match Store.init ~root:worktree with
          | Error _ -> false
          | Ok store -> (
              let scratch = Scratch.open_repository store in
              match Snapshot.scan ~root:worktree ~store with
              | Error _ -> false
              | Ok (base, _) -> (
                  match
                    Scratch.create_initial scratch ~snapshot:base ~created_at:0L
                  with
                  | Error _ -> false
                  | Ok initial -> (
                      Unix.unlink (Filename.concat worktree "base");
                      write_file (Filename.concat worktree "generated") bytes;
                      if executable then
                        Unix.chmod (Filename.concat worktree "generated") 0o755;
                      match Snapshot.scan ~root:worktree ~store with
                      | Error _ -> false
                      | Ok (target, _) -> (
                          let initial = Scratch.Checkpoint.id initial in
                          let target_checkpoint =
                            export_checkpoint scratch target 1L
                          in
                          let capsule = export_capsule_id 90 in
                          match
                            Capsule_store.Durable.create_from_checkpoints ~store
                              ~scratch ~id:capsule ~title:"export"
                              ~description:"property" ~dependencies:[]
                              ~evidence:[] ~from:initial
                              ~target:target_checkpoint ~created_at:2L
                              ~changed_at:2L ()
                          with
                          | Error _ -> false
                          | Ok _ -> (
                              let workspace = export_workspace_id 120 in
                              match
                                Workspace_store.Durable.create ~store
                                  ~id:workspace ~base ~name:None
                                  ~description:None ~created_at:3L
                              with
                              | Error _ -> false
                              | Ok _ -> (
                                  match
                                    Workspace_store.Durable
                                    .enable_current_capsule ~store ~workspace
                                      ~capsule ~expected_generation:None
                                      ~created_at:4L
                                  with
                                  | Error _ -> false
                                  | Ok _ -> (
                                      match
                                        Workspace_store.Durable.materialise
                                          ~store ~scratch ~root:worktree
                                          ~workspace ~observed_at:5L
                                          ~created_at:5L ~dry_run:false ()
                                      with
                                      | Error _ -> false
                                      | Ok materialised
                                        when materialised
                                               .Workspace_store.Durable.partial
                                        ->
                                          false
                                      | Ok _ -> (
                                          match
                                            Release.Durable.create ~store
                                              ~workspace ~parents:[]
                                              ~commands:[]
                                              ~message:(Some "property\n")
                                              ~observed_at:6L ~created_at:7L ()
                                          with
                                          | Error _ -> false
                                          | Ok release -> (
                                              if
                                                not
                                                  (direct_process git
                                                     [
                                                       "init"; "-q"; destination;
                                                     ])
                                              then false
                                              else
                                                match
                                                  ( Git.export_release ?metadata
                                                      Git.default_configuration
                                                      ~store
                                                      ~repository:destination
                                                      ~release:
                                                        (Release.release_id
                                                           release),
                                                    Git.export_release ?metadata
                                                      Git.default_configuration
                                                      ~store
                                                      ~repository:destination
                                                      ~release:
                                                        (Release.release_id
                                                           release) )
                                                with
                                                | Ok first, Ok second -> (
                                                    let commit =
                                                      Git.object_id_to_hex
                                                        first.Git.export_commit
                                                    in
                                                    direct_process git
                                                      [
                                                        "-C";
                                                        destination;
                                                        "checkout";
                                                        "-q";
                                                        commit;
                                                      ]
                                                    && String.equal bytes
                                                         (read_file
                                                            (Filename.concat
                                                               destination
                                                               "generated"))
                                                    && Bool.equal executable
                                                         ((Unix.stat
                                                             (Filename.concat
                                                                destination
                                                                "generated"))
                                                            .Unix.st_perm
                                                          land 0o111
                                                         <> 0)
                                                    && Id.Git_mapping_id.equal
                                                         (Git.mapping_id
                                                            first
                                                              .Git
                                                               .export_mapping)
                                                         (Git.mapping_id
                                                            second
                                                              .Git
                                                               .export_mapping)
                                                    &&
                                                    match metadata with
                                                    | None -> true
                                                    | Some metadata -> (
                                                        match
                                                          direct_capture git
                                                            [
                                                              "-C";
                                                              destination;
                                                              "show";
                                                              "-s";
                                                              "--format=%an \
                                                               <%ae> %at \
                                                               %aI%x00%cn \
                                                               <%ce> %ct \
                                                               %cI%x00%B";
                                                              commit;
                                                            ]
                                                        with
                                                        | Some actual ->
                                                            String.equal actual
                                                              (metadata
                                                                 .Git
                                                                  .release_export_author
                                                                 .Git
                                                                  .git_identity_name
                                                             ^ " <"
                                                             ^ metadata
                                                                 .Git
                                                                  .release_export_author
                                                                 .Git
                                                                  .git_identity_email
                                                             ^ "> 7 \
                                                                1970-01-01T00:00:07Z\000"
                                                             ^ metadata
                                                                 .Git
                                                                  .release_export_committer
                                                                 .Git
                                                                  .git_identity_name
                                                             ^ " <"
                                                             ^ metadata
                                                                 .Git
                                                                  .release_export_committer
                                                                 .Git
                                                                  .git_identity_email
                                                             ^ "> 7 \
                                                                1970-01-01T00:00:07Z\000"
                                                             ^ metadata
                                                                 .Git
                                                                  .release_export_message
                                                              )
                                                            && String.contains
                                                                 first
                                                                   .Git
                                                                    .export_target_ref
                                                                 '-'
                                                        | None -> false))
                                                | Error _, _ | _, Error _ ->
                                                    false))))))))))

let generated_release_exports =
  QCheck2.Test.make ~count:10
    ~name:"Git release export checkout matches generated bytes and mode"
    QCheck2.Gen.(pair (string_size (int_range 0 4096)) bool)
    (fun input -> export_replays_generated_release input)

let export_replays_generated_revision_sequence
    ((first_bytes, second_bytes), executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-revision-export-property-" (fun root ->
          let worktree = Filename.concat root "worktree" in
          let destination = Filename.concat root "destination" in
          Unix.mkdir worktree 0o700;
          Unix.mkdir destination 0o700;
          write_file (Filename.concat worktree "base") "base\n";
          match Store.init ~root:worktree with
          | Error _ -> false
          | Ok store -> (
              let scratch = Scratch.open_repository store in
              match Snapshot.scan ~root:worktree ~store with
              | Error _ -> false
              | Ok (base, _) -> (
                  match
                    Scratch.create_initial scratch ~snapshot:base ~created_at:0L
                  with
                  | Error _ -> false
                  | Ok initial -> (
                      Unix.unlink (Filename.concat worktree "base");
                      write_file (Filename.concat worktree "first") first_bytes;
                      if executable then
                        Unix.chmod (Filename.concat worktree "first") 0o755;
                      match Snapshot.scan ~root:worktree ~store with
                      | Error _ -> false
                      | Ok (first_snapshot, _) -> (
                          let initial = Scratch.Checkpoint.id initial in
                          let first_checkpoint =
                            export_checkpoint scratch first_snapshot 1L
                          in
                          let first_capsule = export_capsule_id 140 in
                          match
                            Capsule_store.Durable.create_from_checkpoints ~store
                              ~scratch ~id:first_capsule ~title:"first"
                              ~description:"property" ~dependencies:[]
                              ~evidence:[] ~from:initial
                              ~target:first_checkpoint ~created_at:2L
                              ~changed_at:2L ()
                          with
                          | Error _ -> false
                          | Ok first -> (
                              write_file
                                (Filename.concat worktree "second")
                                second_bytes;
                              match Snapshot.scan ~root:worktree ~store with
                              | Error _ -> false
                              | Ok (second_snapshot, _) -> (
                                  let second_checkpoint =
                                    export_checkpoint scratch second_snapshot 3L
                                  in
                                  let second_capsule = export_capsule_id 141 in
                                  match
                                    Capsule_store.Durable
                                    .create_from_checkpoints ~store ~scratch
                                      ~id:second_capsule ~title:"second"
                                      ~description:"property" ~dependencies:[]
                                      ~evidence:[] ~from:first_checkpoint
                                      ~target:second_checkpoint ~created_at:4L
                                      ~changed_at:4L ()
                                  with
                                  | Error _ -> false
                                  | Ok second -> (
                                      let source resolved =
                                        let revision =
                                          Capsule_store.Durable
                                          .resolved_revision resolved
                                        in
                                        Capsule_store.make_revision_link
                                          ~capsule:
                                            (Capsule_store.revision_capsule
                                               revision)
                                          ~revision:
                                            (Capsule_store.revision_id revision)
                                          ~object_id:
                                            (Capsule_store.Durable
                                             .resolved_revision_object resolved)
                                      in
                                      let revisions =
                                        [ source first; source second ]
                                      in
                                      if
                                        not
                                          (direct_process git
                                             [ "init"; "-q"; destination ])
                                      then false
                                      else
                                        match
                                          ( Git.export_revisions
                                              Git.default_configuration ~store
                                              ~repository:destination ~revisions,
                                            Git.export_revisions
                                              Git.default_configuration ~store
                                              ~repository:destination ~revisions
                                          )
                                        with
                                        | Ok once, Ok repeated -> (
                                            match
                                              ( once.Git.revision_exports,
                                                repeated.Git.revision_exports )
                                            with
                                            | ( [ first_export; second_export ],
                                                [
                                                  repeated_first;
                                                  repeated_second;
                                                ] ) ->
                                                let first_commit =
                                                  Git.object_id_to_hex
                                                    first_export
                                                      .Git
                                                       .revision_export_commit
                                                in
                                                let second_commit =
                                                  Git.object_id_to_hex
                                                    second_export
                                                      .Git
                                                       .revision_export_commit
                                                in
                                                direct_process git
                                                  [
                                                    "-C";
                                                    destination;
                                                    "checkout";
                                                    "-q";
                                                    first_commit;
                                                  ]
                                                && String.equal first_bytes
                                                     (read_file
                                                        (Filename.concat
                                                           destination "first"))
                                                && Bool.equal executable
                                                     ((Unix.stat
                                                         (Filename.concat
                                                            destination "first"))
                                                        .Unix.st_perm land 0o111
                                                     <> 0)
                                                && (not
                                                      (Sys.file_exists
                                                         (Filename.concat
                                                            destination "second")))
                                                && direct_process git
                                                     [
                                                       "-C";
                                                       destination;
                                                       "checkout";
                                                       "-q";
                                                       second_commit;
                                                     ]
                                                && String.equal second_bytes
                                                     (read_file
                                                        (Filename.concat
                                                           destination "second"))
                                                && Option.equal String.equal
                                                     (Some first_commit)
                                                     (direct_capture git
                                                        [
                                                          "-C";
                                                          destination;
                                                          "show";
                                                          "-s";
                                                          "--format=%P";
                                                          second_commit;
                                                        ])
                                                && String.equal
                                                     once
                                                       .Git
                                                        .revision_export_target_ref
                                                     repeated
                                                       .Git
                                                        .revision_export_target_ref
                                                && Id.Git_mapping_id.equal
                                                     (Git.mapping_id
                                                        first_export
                                                          .Git
                                                           .revision_export_mapping)
                                                     (Git.mapping_id
                                                        repeated_first
                                                          .Git
                                                           .revision_export_mapping)
                                                && Id.Git_mapping_id.equal
                                                     (Git.mapping_id
                                                        second_export
                                                          .Git
                                                           .revision_export_mapping)
                                                     (Git.mapping_id
                                                        repeated_second
                                                          .Git
                                                           .revision_export_mapping)
                                                && direct_process git
                                                     [
                                                       "-C";
                                                       destination;
                                                       "fsck";
                                                       "--full";
                                                     ]
                                            | _ -> false)
                                        | Error _, _ | _, Error _ -> false))))))
              ))

let generated_revision_exports =
  QCheck2.Test.make ~count:10
    ~name:"Git revision export preserves generated linear checkout and retry"
    QCheck2.Gen.(
      pair
        (pair (string_size (int_range 0 2048)) (string_size (int_range 0 2048)))
        bool)
    export_replays_generated_revision_sequence

let option_of_result = function Ok value -> Some value | Error _ -> None

let import_replays_generated_commit (bytes, executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-commit-property-" (fun root ->
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
                 [ "-C"; repository; "config"; "user.name"; "Yeokcham Test" ])
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
              if not (direct_process git [ "-C"; repository; "add"; "--all" ])
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
                                let transition =
                                  first.Git.imported_transition
                                in
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
                                             (Git.mapping_id
                                                first.Git.commit_mapping)
                                             (Git.mapping_id
                                                second.Git.commit_mapping)))
                            | Error _, _ | _, Error _ -> false)))
                | _ -> false)))

let generated_commits =
  QCheck2.Test.make ~count:15
    ~name:"Git commit import preserves generated snapshot and ordered parent"
    QCheck2.Gen.(pair (string_size (int_range 0 4096)) bool)
    import_replays_generated_commit

let generated_metadata_text =
  QCheck2.Gen.(
    list_size (int_range 1 96)
      (oneof_list
         [
           'a';
           'b';
           'c';
           'd';
           'e';
           'f';
           'g';
           'h';
           'i';
           'j';
           '0';
           '1';
           '2';
           '3';
           '-';
           '_';
         ])
    |> map (fun characters -> String.of_seq (List.to_seq characters)))

let metadata_environment author committer =
  let overridden =
    [
      "GIT_AUTHOR_NAME=";
      "GIT_AUTHOR_EMAIL=";
      "GIT_AUTHOR_DATE=";
      "GIT_COMMITTER_NAME=";
      "GIT_COMMITTER_EMAIL=";
      "GIT_COMMITTER_DATE=";
    ]
  in
  Unix.environment () |> Array.to_list
  |> List.filter (fun value ->
      not
        (List.exists
           (fun prefix -> String.starts_with ~prefix value)
           overridden))
  |> List.rev_append
       [
         "GIT_AUTHOR_NAME=" ^ author;
         "GIT_AUTHOR_EMAIL=author@example.invalid";
         "GIT_AUTHOR_DATE=1700000000 +0530";
         "GIT_COMMITTER_NAME=" ^ committer;
         "GIT_COMMITTER_EMAIL=committer@example.invalid";
         "GIT_COMMITTER_DATE=1700000123 -0700";
       ]
  |> Array.of_list

let import_replays_generated_metadata
    (author_suffix, (committer_suffix, message)) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-metadata-property-" (fun root ->
          let repository = Filename.concat root "repository" in
          let store_root = Filename.concat root "store" in
          Unix.mkdir repository 0o700;
          Unix.mkdir store_root 0o700;
          let author = "Generated Author " ^ author_suffix in
          let committer = "Generated Committer " ^ committer_suffix in
          if not (direct_process git [ "init"; "-q"; repository ]) then false
          else (
            write_file (Filename.concat repository "metadata") "metadata\n";
            if not (direct_process git [ "-C"; repository; "add"; "--all" ])
            then false
            else
              match
                ( direct_capture git [ "-C"; repository; "write-tree" ],
                  Store.init ~root:store_root |> option_of_result )
              with
              | Some tree, Some store -> (
                  match
                    direct_capture_with_environment git
                      (metadata_environment author committer)
                      [ "-C"; repository; "commit-tree"; tree; "-m"; message ]
                  with
                  | None -> false
                  | Some commit_hex -> (
                      match
                        Git.object_id_of_hex Git.Sha1 commit_hex
                        |> option_of_result
                      with
                      | None -> false
                      | Some commit -> (
                          match
                            ( Git.import_commit Git.default_configuration ~store
                                ~repository ~commit,
                              Git.import_commit Git.default_configuration ~store
                                ~repository ~commit )
                          with
                          | Ok first, Ok second -> (
                              let transition = first.Git.imported_transition in
                              let expected_author =
                                author
                                ^ " <author@example.invalid> 1700000000 +0530"
                              in
                              let expected_committer =
                                committer
                                ^ " <committer@example.invalid> 1700000123 \
                                   -0700"
                              in
                              match
                                ( Git.imported_transition_author transition,
                                  Git.imported_transition_committer transition,
                                  Git.imported_transition_message transition )
                              with
                              | ( Some actual_author,
                                  Some actual_committer,
                                  Some content ) ->
                                  let message_matches =
                                    match
                                      Snapshot.Content.load store content
                                    with
                                    | Error _ -> false
                                    | Ok actual ->
                                        String.equal (message ^ "\n") actual
                                  in
                                  String.equal expected_author actual_author
                                  && String.equal expected_committer
                                       actual_committer
                                  && message_matches
                                  && Id.Imported_transition_id.equal
                                       (Git.imported_transition_id transition)
                                       (Git.imported_transition_id
                                          second.Git.imported_transition)
                              | None, _, _ | _, None, _ | _, _, None -> false)
                          | Error _, _ | _, Error _ -> false)))
              | _ -> false))

let generated_metadata =
  QCheck2.Test.make ~count:10
    ~name:"Git commit metadata retains generated bounded raw provenance"
    QCheck2.Gen.(
      pair generated_metadata_text
        (pair generated_metadata_text generated_metadata_text))
    import_replays_generated_metadata

let export_replays_generated_release_metadata
    ((bytes, executable), (author_suffix, (committer_suffix, message))) =
  let metadata =
    {
      Git.release_export_author =
        {
          Git.git_identity_name = "Generated Author " ^ author_suffix;
          git_identity_email = author_suffix ^ "@author.invalid";
        };
      release_export_committer =
        {
          Git.git_identity_name = "Generated Committer " ^ committer_suffix;
          git_identity_email = committer_suffix ^ "@committer.invalid";
        };
      release_export_message = message;
    }
  in
  export_replays_generated_release ~metadata (bytes, executable)

let generated_release_export_metadata =
  QCheck2.Test.make ~count:10
    ~name:"Git release export preserves generated configured metadata"
    QCheck2.Gen.(
      pair
        (pair (string_size (int_range 0 4096)) bool)
        (pair generated_metadata_text
           (pair generated_metadata_text generated_metadata_text)))
    export_replays_generated_release_metadata

let generated_tag_name =
  QCheck2.Gen.(
    list_size (int_range 1 32)
      (oneof_list
         [
           'a';
           'b';
           'c';
           'd';
           'e';
           'f';
           'g';
           'h';
           'i';
           'j';
           '0';
           '1';
           '2';
           '3';
           '-';
         ])
    |> map (fun suffix -> "tag-" ^ String.of_seq (List.to_seq suffix)))

let import_replays_generated_tag (name, annotated) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-tag-property-" (fun root ->
          let repository = Filename.concat root "repository" in
          let store_root = Filename.concat root "store" in
          Unix.mkdir repository 0o700;
          Unix.mkdir store_root 0o700;
          if not (direct_process git [ "init"; "-q"; repository ]) then false
          else if
            not
              (direct_process git
                 [ "-C"; repository; "config"; "user.name"; "Yeokcham Test" ])
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
            write_file
              (Filename.concat repository "generated")
              "tagged\000bytes";
            if not (direct_process git [ "-C"; repository; "add"; "--all" ])
            then false
            else if
              not
                (direct_process git
                   [ "-C"; repository; "commit"; "-q"; "-m"; "tagged" ])
            then false
            else
              let imported =
                match
                  ( direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ],
                    Store.init ~root:store_root |> option_of_result )
                with
                | Some commit_hex, Some store ->
                    let tag_command =
                      if annotated then
                        [
                          "-C";
                          repository;
                          "tag";
                          "-a";
                          name;
                          "-m";
                          "generated annotation";
                          commit_hex;
                        ]
                      else [ "-C"; repository; "tag"; name; commit_hex ]
                    in
                    if not (direct_process git tag_command) then None
                    else
                      Some
                        ( commit_hex,
                          Git.import_tag Git.default_configuration ~store
                            ~repository ~tag:name,
                          Git.import_tag Git.default_configuration ~store
                            ~repository ~tag:name )
                | _ -> None
              in
              match imported with
              | Some (commit_hex, Ok first, Ok second) ->
                  let tag = first.Git.imported_tag in
                  String.equal name (Git.imported_tag_name tag)
                  && String.equal commit_hex
                       (Git.imported_tag_target tag |> Git.object_id_to_hex)
                  && Bool.equal annotated
                       (Option.is_some (Git.imported_tag_annotation tag))
                  && Id.Imported_tag_id.equal (Git.imported_tag_id tag)
                       (Git.imported_tag_id second.Git.imported_tag)
                  && Id.Git_mapping_id.equal
                       (Git.mapping_id first.Git.tag_mapping)
                       (Git.mapping_id second.Git.tag_mapping)
              | Some (_, Error _, _) | Some (_, _, Error _) | None -> false))

let generated_tags =
  QCheck2.Test.make ~count:15
    ~name:"Git tag import preserves generated opaque provenance"
    QCheck2.Gen.(pair generated_tag_name bool)
    import_replays_generated_tag

let archive_exits_generated_file (bytes, executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-archive-property-" (fun root ->
          let repository = Filename.concat root "repository" in
          let store_root = Filename.concat root "store" in
          let exit_repository = Filename.concat root "exit.git" in
          let checkout = Filename.concat root "checkout" in
          Unix.mkdir repository 0o700;
          Unix.mkdir store_root 0o700;
          write_file (Filename.concat repository "generated") bytes;
          if executable then
            Unix.chmod (Filename.concat repository "generated") 0o755;
          if not (direct_process git [ "init"; "-q"; repository ]) then false
          else if
            not
              (direct_process git
                 [ "-C"; repository; "config"; "user.name"; "Yeokcham Test" ])
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
          else if not (direct_process git [ "-C"; repository; "add"; "--all" ])
          then false
          else if
            not
              (direct_process git
                 [ "-C"; repository; "commit"; "-q"; "-m"; "generated" ])
          then false
          else
            match Store.init ~root:store_root with
            | Error _ -> false
            | Ok store -> (
                match
                  ( Git.archive_repository Git.default_configuration ~store
                      ~repository,
                    Git.archive_repository Git.default_configuration ~store
                      ~repository )
                with
                | Ok first, Ok second
                  when Id.Git_archive_id.equal (Git.archive_id first)
                         (Git.archive_id second) -> (
                    match
                      Git.exit_archive Git.default_configuration ~store
                        ~archive:(Git.archive_id first)
                        ~destination:exit_repository
                    with
                    | Error _ -> false
                    | Ok _ ->
                        direct_process git
                          [ "-C"; exit_repository; "fsck"; "--full" ]
                        && direct_process git
                             [ "clone"; "-q"; exit_repository; checkout ]
                        && String.equal bytes
                             (read_file (Filename.concat checkout "generated"))
                        && Bool.equal executable
                             ((Unix.stat (Filename.concat checkout "generated"))
                                .Unix.st_perm land 0o111
                             <> 0))
                | Ok _, Ok _ | Error _, _ | _, Error _ -> false))

let generated_archives =
  QCheck2.Test.make ~count:12
    ~name:
      "Git archive preserves generated bytes and executable mode through exit"
    QCheck2.Gen.(pair (string_size (int_range 0 4096)) bool)
    archive_exits_generated_file

let archive_materializes_generated_topology branch_count =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-lineage-property-" (fun root ->
          let repository = Filename.concat root "repository" in
          let store_root = Filename.concat root "store" in
          Unix.mkdir repository 0o700;
          Unix.mkdir store_root 0o700;
          let run arguments = direct_process git arguments in
          let evaluate_merge merge parents store =
            match
              Git.inspect Git.default_configuration ~repository
              |> Result.map Git.inspection_object_format
            with
            | Error _ -> false
            | Ok format -> (
                match
                  ( Git.object_id_of_hex format merge,
                    Git.archive_repository Git.default_configuration ~store
                      ~repository )
                with
                | Error _, _ | _, Error _ -> false
                | Ok merge, Ok archive -> (
                    match
                      Git.materialize_archive_lineage Git.default_configuration
                        ~store ~archive:(Git.archive_id archive)
                    with
                    | Error _ -> false
                    | Ok materialized -> (
                        match
                          List.find_opt
                            (fun node ->
                              String.equal
                                (Git.object_id_to_hex
                                   (Git.lineage_node_commit node))
                                (Git.object_id_to_hex merge))
                            materialized.Git.lineage_nodes
                        with
                        | None -> false
                        | Some node ->
                            let actual_parents =
                              Git.lineage_node_parents node
                              |> List.map (fun identity ->
                                  Git.load_lineage_node store identity
                                  |> Result.map Git.lineage_node_commit
                                  |> Result.map Git.object_id_to_hex)
                            in
                            List.for_all Result.is_ok actual_parents
                            && List.map Result.get_ok actual_parents
                               = String.split_on_char ' ' parents
                            && List.length materialized.Git.lineage_nodes
                               = branch_count + 3)))
          in
          if not (run [ "init"; "-q"; repository ]) then false
          else if
            not
              (run [ "-C"; repository; "config"; "user.name"; "Yeokcham Test" ])
          then false
          else if
            not
              (run
                 [
                   "-C";
                   repository;
                   "config";
                   "user.email";
                   "test@example.invalid";
                 ])
          then false
          else
            let setup_base () =
              write_file (Filename.concat repository "base") "base";
              run [ "-C"; repository; "add"; "--all" ]
              && run [ "-C"; repository; "commit"; "-q"; "-m"; "base" ]
            in
            if not (setup_base ()) then false
            else
              match
                ( direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ],
                  direct_capture git
                    [ "-C"; repository; "branch"; "--show-current" ] )
              with
              | None, _ | _, None -> false
              | Some base, Some main_branch ->
                  let sides =
                    List.init branch_count (fun index ->
                        Printf.sprintf "side-%d" index)
                  in
                  let rec create_sides index =
                    if index = branch_count then true
                    else
                      let side = List.nth sides index in
                      if
                        not
                          (run
                             [
                               "-C";
                               repository;
                               "checkout";
                               "-q";
                               "-b";
                               side;
                               base;
                             ])
                      then false
                      else (
                        write_file
                          (Filename.concat repository
                             (Printf.sprintf "side-%d" index))
                          (Printf.sprintf "side-%d" index);
                        run [ "-C"; repository; "add"; "--all" ]
                        && run [ "-C"; repository; "commit"; "-q"; "-m"; side ]
                        && create_sides (index + 1))
                  in
                  if not (create_sides 0) then false
                  else if
                    not
                      (run [ "-C"; repository; "checkout"; "-q"; main_branch ])
                  then false
                  else (
                    write_file (Filename.concat repository "main") "main";
                    if not (run [ "-C"; repository; "add"; "--all" ]) then false
                    else if
                      not
                        (run [ "-C"; repository; "commit"; "-q"; "-m"; "main" ])
                    then false
                    else if
                      not
                        (run
                           ([
                              "-C";
                              repository;
                              "merge";
                              "--no-ff";
                              "-q";
                              "-m";
                              "octopus";
                            ]
                           @ sides))
                    then false
                    else
                      match
                        ( direct_capture git
                            [ "-C"; repository; "rev-parse"; "HEAD" ],
                          direct_capture git
                            [
                              "-C";
                              repository;
                              "show";
                              "-s";
                              "--format=%P";
                              "HEAD";
                            ],
                          Store.init ~root:store_root )
                      with
                      | Some merge, Some parents, Ok store ->
                          evaluate_merge merge parents store
                      | Some _, Some _, Error _ | Some _, None, _ | None, _, _
                        ->
                          false))

let generated_lineages =
  QCheck2.Test.make ~count:12
    ~name:
      "Git archive lineage preserves generated octopus merge topology and \
       parent order"
    QCheck2.Gen.(int_range 2 4)
    archive_materializes_generated_topology

let archive_adopts_generated_file (bytes, executable) =
  match git_path () with
  | None -> false
  | Some git ->
      with_directory "yeokcham-git-adoption-property-" (fun root ->
          let repository = Filename.concat root "repository" in
          let store_root = Filename.concat root "store" in
          Unix.mkdir repository 0o700;
          Unix.mkdir store_root 0o700;
          write_file (Filename.concat repository "generated") "base";
          if not (direct_process git [ "init"; "-q"; repository ]) then false
          else if
            not
              (direct_process git
                 [ "-C"; repository; "config"; "user.name"; "Yeokcham Test" ])
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
          else if not (direct_process git [ "-C"; repository; "add"; "--all" ])
          then false
          else if
            not
              (direct_process git
                 [ "-C"; repository; "commit"; "-q"; "-m"; "base" ])
          then false
          else
            match
              direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ]
            with
            | None -> false
            | Some parent -> (
                write_file (Filename.concat repository "generated") bytes;
                if executable then
                  Unix.chmod (Filename.concat repository "generated") 0o755;
                if not (direct_process git [ "-C"; repository; "add"; "--all" ])
                then false
                else if
                  not
                    (direct_process git
                       [ "-C"; repository; "commit"; "-q"; "-m"; "generated" ])
                then false
                else
                  match
                    ( direct_capture git
                        [ "-C"; repository; "rev-parse"; "HEAD" ],
                      Store.init ~root:store_root )
                  with
                  | Some commit, Ok store -> (
                      match
                        Git.inspect Git.default_configuration ~repository
                        |> Result.map Git.inspection_object_format
                      with
                      | Error _ -> false
                      | Ok format -> (
                          match
                            ( Git.object_id_of_hex format commit,
                              Git.object_id_of_hex format parent )
                          with
                          | Ok commit, Ok parent -> (
                              match
                                Git.archive_repository Git.default_configuration
                                  ~store ~repository
                              with
                              | Error _ -> false
                              | Ok archive -> (
                                  match
                                    ( Git.import_archive_commit
                                        Git.default_configuration ~store
                                        ~archive:(Git.archive_id archive)
                                        ~commit,
                                      Git.import_archive_commit
                                        Git.default_configuration ~store
                                        ~archive:(Git.archive_id archive)
                                        ~commit:parent )
                                  with
                                  | Ok imported, Ok imported_parent -> (
                                      match
                                        detached_adoption_checkpoints store
                                          ~source:
                                            (Git.imported_transition_snapshot
                                               imported_parent
                                                 .Git.imported_transition)
                                          ~target:
                                            (Git.imported_transition_snapshot
                                               imported.Git.imported_transition)
                                      with
                                      | None -> false
                                      | Some (source, target) -> (
                                          let capsule = export_capsule_id 93 in
                                          let scratch =
                                            Scratch.open_repository store
                                          in
                                          match
                                            Capsule_store.Durable
                                            .create_from_checkpoints ~store
                                              ~scratch ~id:capsule
                                              ~title:"generated adoption"
                                              ~description:"generated delta"
                                              ~dependencies:[] ~evidence:[]
                                              ~from:source ~target
                                              ~created_at:0L ~changed_at:0L ()
                                          with
                                          | Error _ -> false
                                          | Ok resolved -> (
                                              let revision =
                                                Capsule_store.Durable
                                                .resolved_revision resolved
                                                |> Capsule_store.revision_id
                                              in
                                              match
                                                Git.record_archive_adoption
                                                  store
                                                  ~archive:
                                                    (Git.archive_id archive)
                                                  ~commit ~parent:(Some parent)
                                                  ~transition:
                                                    imported
                                                      .Git.imported_transition
                                                  ~mapping:
                                                    imported.Git.commit_mapping
                                                  ~parent_transition:
                                                    (Some
                                                       imported_parent
                                                         .Git
                                                          .imported_transition)
                                                  ~parent_mapping:
                                                    (Some
                                                       imported_parent
                                                         .Git.commit_mapping)
                                                  ~capsule ~revision ~source
                                                  ~target
                                              with
                                              | Error _ -> false
                                              | Ok adoption -> (
                                                  match
                                                    Git.load_adoption store
                                                      (Git.adoption_id adoption)
                                                  with
                                                  | Error _ -> false
                                                  | Ok reopened ->
                                                      String.equal
                                                        (Git.object_id_to_hex
                                                           commit)
                                                        (Git.object_id_to_hex
                                                           (Git.adoption_commit
                                                              reopened))))))
                                  | Ok _, Error _ | Error _, _ -> false))
                          | Ok _, Error _ | Error _, _ -> false))
                  | Some _, Error _ | None, _ -> false))

let generated_adoptions =
  QCheck2.Test.make ~count:8
    ~name:
      "Git archive adoption replays generated bytes and executable mode into a \
       capsule"
    QCheck2.Gen.(pair (string_size (int_range 0 4096)) bool)
    archive_adopts_generated_file

let () =
  Alcotest.run "Git properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-files")
            generated_files;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-release-exports")
            generated_release_exports;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-release-export-metadata")
            generated_release_export_metadata;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-revision-exports")
            generated_revision_exports;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-commits")
            generated_commits;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-metadata")
            generated_metadata;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-tags")
            generated_tags;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-archives")
            generated_archives;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-lineages")
            generated_lineages;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-adoptions")
            generated_adoptions;
        ] );
    ]
