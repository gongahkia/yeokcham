module S = Yeokcham_snapshot
module Store = Yeokcham_store

let ok render = function
  | Ok value -> value
  | Error e -> Alcotest.fail (render e)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_directory f =
  let root = Filename.temp_file "yeokcham-capture-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let write root path bytes =
  Out_channel.with_open_bin (Filename.concat root path) (fun out ->
      Out_channel.output_string out bytes)

let capture ?(observe = fun _ _ -> ()) root store =
  S.For_test.scan ~observe ~root ~store |> ok S.error_to_string

let entries store snapshot =
  S.Tree.load store (S.Snapshot.root snapshot)
  |> ok S.error_to_string |> S.Tree.entries

let file store snapshot name =
  match List.assoc name (entries store snapshot) with
  | S.Tree.File { mode; content } ->
      (mode, S.Content.load store content |> ok S.error_to_string)
  | S.Tree.Directory _ -> Alcotest.failf "%s is a directory" name

let once f =
  let done_ = ref false in
  fun stage path -> if (not !done_) && f stage path then done_ := true

let same_size_write () =
  with_directory (fun root ->
      let store = Store.init ~root |> ok Store.error_to_string in
      write root "notes" "old\n";
      let reads = ref 0 in
      let observe stage path =
        if stage = S.For_test.After_read && path = [ "notes" ] then (
          incr reads;
          if !reads = 1 then write root "notes" "new\n")
      in
      let _, snapshot = capture ~observe root store in
      Alcotest.(check string)
        "updated bytes after retry" "new\n"
        (snd (file store snapshot "notes"));
      Alcotest.(check int) "retried whole observation" 2 !reads)

let[@warning "-4"] bounded_instability () =
  with_directory (fun root ->
      let store = Store.init ~root |> ok Store.error_to_string in
      write root "notes" "stable";
      let saved, _ = capture root store in
      let expected =
        Store.compare_and_swap_ref store ~name:"test-current" ~expected:None
          ~target:(Some (S.Snapshot.stored_object_id saved))
        |> ok Store.error_to_string
      in
      let reads = ref 0 in
      let observe stage path =
        if stage = S.For_test.After_read && path = [ "notes" ] then (
          incr reads;
          write root "notes" (string_of_int !reads))
      in
      (match S.For_test.scan ~observe ~root ~store with
      | Error (S.Capture_unstable path) ->
          Alcotest.(check bool)
            "actionable path" true
            (String.ends_with ~suffix:"notes" path)
      | Error e -> Alcotest.fail (S.error_to_string e)
      | Ok _ -> Alcotest.fail "published an unstable capture");
      Alcotest.(check int) "three bounded attempts" 3 !reads;
      let actual =
        Store.read_ref store ~name:"test-current"
        |> ok Store.error_to_string |> Option.get
      in
      Alcotest.(check bool)
        "previous root unchanged" true
        (Store.Mutable_ref.equal expected actual))

let entry_set_change () =
  List.iter
    (fun mutate ->
      with_directory (fun root ->
          let store = Store.init ~root |> ok Store.error_to_string in
          write root "a" "same";
          write root "z" "removed";
          let observe =
            once (fun stage path ->
                if stage = S.For_test.After_read && path = [ "a" ] then (
                  mutate root;
                  true)
                else false)
          in
          let id, _ = capture ~observe root store in
          let current, _ = capture root store in
          Alcotest.(check bool)
            "whole directory observed again" true
            (S.Snapshot.equal_id id current)))
    [
      (fun root -> write root "new" "added");
      (fun root -> Unix.unlink (Filename.concat root "z"));
    ]

let before_publish_changes () =
  List.iter
    (fun ignored_config ->
      with_directory (fun root ->
          let store = Store.init ~root |> ok Store.error_to_string in
          write root "keep" "old";
          write root "drop" "sensitive";
          if ignored_config then
            write root ".yeokchamignore" ".yeokchamignore\n";
          let observe =
            once (fun stage _ ->
                if stage = S.For_test.Before_publish then (
                  write root "keep" "new";
                  write root ".yeokchamignore" ".yeokchamignore\ndrop\n";
                  true)
                else false)
          in
          let id, snapshot = capture ~observe root store in
          Alcotest.(check string)
            "leaf rechecked before publication" "new"
            (snd (file store snapshot "keep"));
          Alcotest.(check (list string))
            "new or ignored config is rechecked" [ "keep" ]
            (List.map fst (entries store snapshot));
          let current, _ = capture root store in
          Alcotest.(check bool)
            "retry matches settled tree" true
            (S.Snapshot.equal_id id current)))
    [ false; true ]

let symlink_races () =
  List.iter
    (fun directory ->
      with_directory (fun root ->
          with_directory (fun outside ->
              let store = Store.init ~root |> ok Store.error_to_string in
              write outside "secret" "do not capture outside bytes";
              let child = Filename.concat root "entry" in
              if directory then (
                Unix.mkdir child 0o700;
                write root "entry/local" "inside")
              else write root "entry" "inside";
              let target =
                if directory then outside else Filename.concat outside "secret"
              in
              let observe =
                once (fun stage path ->
                    if stage = S.For_test.Before_open && path = [ "entry" ] then (
                      remove_tree child;
                      Unix.symlink target child;
                      true)
                    else false)
              in
              let _, snapshot = capture ~observe root store in
              let mode, bytes = file store snapshot "entry" in
              Alcotest.(check bool)
                "replacement captured as symlink" true (mode = S.Symlink);
              Alcotest.(check string)
                "target bytes, without traversing link" target bytes;
              let outside_store =
                Store.init ~root:outside |> ok Store.error_to_string
              in
              let outside_id =
                S.Content.store outside_store "do not capture outside bytes"
                |> ok S.error_to_string
              in
              Alcotest.(check bool)
                "outside content never stored" false
                (List.exists
                   (fun (object_ : Store.object_info) ->
                     Store.Stored_object_id.equal object_.Store.id
                       (S.Content.stored_object_id outside_id))
                   (Store.list_objects store |> ok Store.error_to_string)))))
    [ false; true ]

let[@warning "-4"] root_replacement () =
  with_directory (fun container ->
      let root = Filename.concat container "root" in
      Unix.mkdir root 0o700;
      let store = Store.init ~root |> ok Store.error_to_string in
      write root "a" "old root";
      let observe =
        once (fun stage _ ->
            if stage = S.For_test.Before_publish then (
              Unix.rename root (Filename.concat container "displaced");
              Unix.mkdir root 0o700;
              write root "a" "new root";
              true)
            else false)
      in
      match S.For_test.scan ~observe ~root ~store with
      | Error (S.Capture_unstable _) -> ()
      | Error e -> Alcotest.fail (S.error_to_string e)
      | Ok _ -> Alcotest.fail "followed a replaced capture root")

let fidelity_and_special_file () =
  with_directory (fun root ->
      let store = Store.init ~root |> ok Store.error_to_string in
      let bytes =
        String.init ((256 * 1024) + 17) (fun i -> Char.chr (i * 17 mod 256))
      in
      write root "large" bytes;
      write root "run" "#!/bin/sh\n";
      Unix.chmod (Filename.concat root "run") 0o751;
      Unix.mkdir (Filename.concat root "empty") 0o700;
      Unix.symlink "missing/target" (Filename.concat root "link");
      let _, snapshot = capture root store in
      Alcotest.(check string)
        "streamed opaque bytes" bytes
        (snd (file store snapshot "large"));
      Alcotest.(check bool)
        "executable distinction" true
        (fst (file store snapshot "run") = S.Executable);
      Alcotest.(check string)
        "dangling symlink target" "missing/target"
        (snd (file store snapshot "link"));
      (match List.assoc "empty" (entries store snapshot) with
      | S.Tree.Directory tree ->
          Alcotest.(check int)
            "empty directory retained" 0
            (List.length
               (S.Tree.entries (S.Tree.load store tree |> ok S.error_to_string)))
      | S.Tree.File _ -> Alcotest.fail "empty directory became a file");
      Unix.mkfifo (Filename.concat root "pipe") 0o600;
      match S.scan ~root ~store with
      | Error e ->
          Alcotest.(check bool)
            "unsupported path in error" true
            (String.ends_with ~suffix:"pipe" (S.error_to_string e))
      | Ok _ -> Alcotest.fail "captured a FIFO")

let () =
  Alcotest.run "Capture consistency"
    [
      ( "filesystem",
        [
          Alcotest.test_case "same-size write is retried" `Quick same_size_write;
          Alcotest.test_case "continuous instability is bounded" `Quick
            bounded_instability;
          Alcotest.test_case "entry additions and removals" `Quick
            entry_set_change;
          Alcotest.test_case "late leaf and ignore changes" `Quick
            before_publish_changes;
          Alcotest.test_case "file and directory symlink races" `Quick
            symlink_races;
          Alcotest.test_case "root replacement refuses publication" `Quick
            root_replacement;
          Alcotest.test_case "stream fidelity and special files" `Quick
            fidelity_and_special_file;
        ] );
    ]
