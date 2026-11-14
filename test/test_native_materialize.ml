module S = Yeokcham_snapshot
module F = S.Filesystem
module Store = Yeokcham_store

let ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter
        (fun name -> remove (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_directory f =
  let root = Filename.temp_file "yeokcham-native-materialize-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () ->
      let descriptor = F.open_at None root true in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () -> f root descriptor))

let write descriptor name bytes =
  let output = F.create_at descriptor name in
  Fun.protect
    ~finally:(fun () -> Unix.close output)
    (fun () ->
      let rec loop offset =
        if offset = String.length bytes then ()
        else
          let count =
            Unix.write_substring output bytes offset
              (String.length bytes - offset)
          in
          if count = 0 then Alcotest.fail "short write"
          else loop (offset + count)
      in
      loop 0;
      Unix.fsync output)

let read root name =
  In_channel.with_open_bin (Filename.concat root name) In_channel.input_all

let identity descriptor name = F.inspect_at descriptor name |> snd |> F.identity

let[@warning "-4"] exclusive_move_does_not_replace () =
  with_directory (fun root fd ->
      write fd "source" "source bytes";
      write fd "destination" "external bytes";
      let before = (identity fd "source", identity fd "destination") in
      (try
         F.rename_at fd "source" fd "destination" false;
         Alcotest.fail "exclusive move replaced destination"
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      Alcotest.(check string)
        "external bytes retained" "external bytes" (read root "destination");
      Alcotest.(check bool)
        "both identities retained" true
        (before = (identity fd "source", identity fd "destination"));
      F.rename_at fd "source" fd "new" false;
      Alcotest.(check string)
        "move to absent destination" "source bytes" (read root "new"))

let atomic_exchange_preserves_both_nodes () =
  with_directory (fun root fd ->
      write fd "old" "original bytes";
      write fd "staged" "target bytes";
      let old = identity fd "old" and staged = identity fd "staged" in
      F.rename_at fd "old" fd "staged" true;
      Alcotest.(check string)
        "target installed" "target bytes" (read root "old");
      Alcotest.(check string)
        "original remains accessible" "original bytes" (read root "staged");
      Alcotest.(check string)
        "target ownership follows rename" staged (identity fd "old");
      Alcotest.(check string)
        "original identity retained" old (identity fd "staged");
      F.mkdir_at fd "directory";
      let dir = F.open_at (Some fd) "directory" true in
      Fun.protect
        ~finally:(fun () -> Unix.close dir)
        (fun () -> write dir "child" "child bytes");
      F.rename_at fd "old" fd "directory" true;
      Alcotest.(check string)
        "directory/file exchange retains subtree" "child bytes"
        (read root "old/child");
      Alcotest.(check string)
        "file retained after mixed exchange" "target bytes"
        (read root "directory"))

let no_follow_and_exclusive_creation () =
  with_directory (fun root fd ->
      with_directory (fun outside _ ->
          F.symlink_at fd "link" outside;
          (try
             let opened = F.open_at (Some fd) "link" true in
             Unix.close opened;
             Alcotest.fail "followed symlink directory"
           with Unix.Unix_error _ -> ());
          (try
             let opened = F.create_at fd "link" in
             Unix.close opened;
             Alcotest.fail "created over symlink"
           with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          Alcotest.(check int)
            "outside directory untouched" 0
            (Array.length (Sys.readdir outside));
          Alcotest.(check string)
            "symlink bytes preserved" outside
            (Unix.readlink (Filename.concat root "link"))))

let streaming_private_output () =
  with_directory (fun root fd ->
      let store = Store.init ~root |> ok Store.error_to_string in
      let bytes =
        String.init ((2 * 1024 * 1024) + 3) (fun i -> Char.chr (i * 13 mod 256))
      in
      let id = S.Content.store store bytes |> ok S.error_to_string in
      let output = F.create_at fd "staged" in
      Fun.protect
        ~finally:(fun () -> Unix.close output)
        (fun () ->
          S.Content.stream_to_fd store id output |> ok S.error_to_string;
          Unix.fsync output);
      Alcotest.(check string)
        "streamed target is exact" bytes (read root "staged"))

let complete_observation_has_native_read_set () =
  with_directory (fun root fd ->
      let store = Store.init ~root |> ok Store.error_to_string in
      write fd ".yeokchamignore" "ignored\n";
      write fd "kept" "yes";
      write fd "ignored" "private";
      F.mkdir_at fd "child";
      let _, _, observed =
        S.Observation.scan ~root ~store |> ok S.error_to_string
      in
      let entries = S.Observation.entries observed in
      Alcotest.(check bool)
        "included file identity" true
        (List.mem_assoc [ "kept" ] entries);
      Alcotest.(check bool)
        "ignored bytes not observed" false
        (List.mem_assoc [ "ignored" ] entries);
      let rules = S.Observation.rules observed in
      Alcotest.(check bool)
        "root rule fingerprint retained" true
        (Option.is_some (List.assoc [ ".yeokchamignore" ] rules));
      Alcotest.(check bool)
        "nested absent rule is observed" true
        (List.assoc [ "child"; ".yeokchamignore" ] rules = None);
      let _, stamp, names =
        S.Observation.directories observed
        |> List.find (fun (path, _, _) -> path = [])
      in
      Alcotest.(check string)
        "root directory identity"
        (F.identity (F.fingerprint fd))
        (F.identity stamp);
      Alcotest.(check bool)
        "ignored names are known without reading contents" true
        (List.mem "ignored" names))

let () =
  Alcotest.run "Native safe materialization prerequisites"
    [
      ( "filesystem",
        [
          Alcotest.test_case "exclusive moves preserve obstructions" `Quick
            exclusive_move_does_not_replace;
          Alcotest.test_case "atomic exchange retains original nodes" `Quick
            atomic_exchange_preserves_both_nodes;
          Alcotest.test_case "no-follow and exclusive creation" `Quick
            no_follow_and_exclusive_creation;
          Alcotest.test_case "bounded staged output" `Quick
            streaming_private_output;
          Alcotest.test_case "completed observation read set" `Quick
            complete_observation_has_native_read_set;
        ] );
    ]
