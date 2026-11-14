module S = Yeokcham_snapshot
module Store = Yeokcham_store
module A = Yeokcham_v1_local_service.Safe_apply

let ok render = function Ok x -> x | Error e -> Alcotest.fail (render e)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_root f =
  let root = Filename.temp_file "yeokcham-safe-apply-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () -> f root (Store.init ~root |> ok Store.error_to_string))

let write path bytes =
  Out_channel.with_open_bin path (fun out -> output_string out bytes)

let read path = In_channel.with_open_bin path In_channel.input_all
let capture root store = S.scan ~root ~store |> ok S.error_to_string |> fst
let observe root store = S.Observation.scan ~root ~store |> ok S.error_to_string
let operation = String.make 64 'a'

let prepare root store safety target observation =
  A.prepare ~root ~store ~operation ~safety ~target observation
  |> ok A.error_to_string

let load root plan safety target =
  A.load ~root ~operation ~digest:(A.digest plan) ~safety ~target
  |> ok A.error_to_string

let assert_refused name = function Error _ -> () | Ok _ -> Alcotest.fail name

let fixture root store =
  write (root ^ "/a") "original A";
  write (root ^ "/z") "original Z";
  let safety = capture root store in
  write (root ^ "/a") "target A";
  Unix.unlink (root ^ "/z");
  Unix.mkdir (root ^ "/new") 0o700;
  write (root ^ "/new/blob") "\000\255\001";
  Unix.symlink "../a" (root ^ "/new/link");
  Unix.mkdir (root ^ "/new/empty") 0o700;
  let target = capture root store in
  write (root ^ "/a") "original A";
  write (root ^ "/z") "original Z";
  remove (root ^ "/new");
  let actual, _, observation = observe root store in
  Alcotest.(check bool)
    "same safety contents" true
    (S.Snapshot.equal_id safety actual);
  (safety, target, observation)

let exact_apply_and_retry () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      A.apply ~root ~store plan |> ok A.error_to_string;
      Alcotest.(check bool)
        "exact mixed target" true
        (S.Snapshot.equal_id target (capture root store));
      let plan = load root plan safety target in
      A.apply ~root ~store plan |> ok A.error_to_string;
      Alcotest.(check string)
        "original bytes retained" "original A"
        (read (A.retained_directory ~root ~operation ^ "/0"));
      Alcotest.(check bool)
        "empty dir retained" true
        (Sys.is_directory (root ^ "/new/empty"));
      Alcotest.(check string)
        "symlink bytes" "../a"
        (Unix.readlink (root ^ "/new/link")))

let crash_boundaries () =
  List.iter
    (fun boundary ->
      List.iter
        (fun number ->
          with_root (fun root store ->
              let safety, target, observation = fixture root store in
              let plan = prepare root store safety target observation in
              let child = Unix.fork () in
              (if child = 0 then
                 let count = ref 0 in
                 let observe stage _ =
                   if stage = boundary then (
                     incr count;
                     if !count = number then Unix._exit 73)
                 in
                 match A.For_test.apply ~observe ~root ~store plan with
                 | Ok () -> Unix._exit 0
                 | Error _ -> Unix._exit 74);
              let _, status = Unix.waitpid [] child in
              Alcotest.(check bool)
                "crashed at actual boundary" true (status = Unix.WEXITED 73);
              let plan = load root plan safety target in
              A.apply ~root ~store plan |> ok A.error_to_string;
              Alcotest.(check bool)
                "exact target after restart" true
                (S.Snapshot.equal_id target (capture root store))))
        [ 1; 2; 3 ])
    [ A.Before_mutation; A.After_mutation; A.After_sync ]

let external_edits_are_preserved () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      write (root ^ "/z") "unexpected external edit";
      assert_refused "overwrote external edit" (A.apply ~root ~store plan);
      Alcotest.(check string)
        "unmodified first path" "original A"
        (read (root ^ "/a"));
      Alcotest.(check string)
        "external bytes" "unexpected external edit"
        (read (root ^ "/z")))

let concurrent_old_descriptor_edit () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      let fd = Unix.openfile (root ^ "/a") [ Unix.O_WRONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () ->
          let once = ref false in
          let observe boundary _ =
            if boundary = A.After_mutation && not !once then (
              once := true;
              Unix.ftruncate fd 0;
              ignore (Unix.write_substring fd "external through open fd" 0 24);
              Unix.fsync fd)
          in
          assert_refused "accepted changed displaced node"
            (A.For_test.apply ~observe ~root ~store plan);
          Alcotest.(check string)
            "installed target retained" "target A"
            (read (root ^ "/a"));
          Alcotest.(check string)
            "external bytes retained with original inode"
            "external through open fd"
            (read (A.retained_directory ~root ~operation ^ "/0"))))

let edit_after_interruption () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      let child = Unix.fork () in
      if child = 0 then (
        ignore
          (A.For_test.apply
             ~observe:(fun stage _ ->
               if stage = A.After_sync then Unix._exit 73)
             ~root ~store plan);
        Unix._exit 74);
      ignore (Unix.waitpid [] child);
      write (root ^ "/a") "edit after crash";
      assert_refused "replayed over changed installed target"
        (A.apply ~root ~store (load root plan safety target));
      Alcotest.(check string)
        "later external edit" "edit after crash"
        (read (root ^ "/a"));
      Alcotest.(check string)
        "unapplied original remains" "original Z"
        (read (root ^ "/z")))

let ignored_paths () =
  with_root (fun root store ->
      write (root ^ "/.yeokchamignore") "cache\n*.private\n";
      Unix.mkdir (root ^ "/dir") 0o700;
      write (root ^ "/dir/kept") "old";
      let target = capture root store in
      Unix.unlink (root ^ "/dir/kept");
      Unix.rmdir (root ^ "/dir");
      write (root ^ "/a") "source";
      Unix.mkdir (root ^ "/cache") 0o700;
      write (root ^ "/cache/data") "ignored bytes";
      let safety, _, observation = observe root store in
      let plan = prepare root store safety target observation in
      A.apply ~root ~store plan |> ok A.error_to_string;
      Alcotest.(check string)
        "noncolliding ignored bytes retained" "ignored bytes"
        (read (root ^ "/cache/data"));
      Alcotest.(check string) "target exists" "old" (read (root ^ "/dir/kept")))

let ignored_directory_obstruction () =
  with_root (fun root store ->
      write (root ^ "/.yeokchamignore") "*.private\n";
      write (root ^ "/dir") "target file";
      let target = capture root store in
      Unix.unlink (root ^ "/dir");
      Unix.mkdir (root ^ "/dir") 0o700;
      write (root ^ "/dir/visible") "owned";
      write (root ^ "/dir/ignored.private") "unread private";
      let safety, _, observation = observe root store in
      assert_refused "replaced directory containing ignored paths"
        (A.prepare ~root ~store ~operation ~safety ~target observation);
      Alcotest.(check string)
        "ignored bytes unchanged" "unread private"
        (read (root ^ "/dir/ignored.private")))

let ignored_directory_kept_on_delete () =
  with_root (fun root store ->
      write (root ^ "/.yeokchamignore") "*.private\n";
      let target = capture root store in
      Unix.mkdir (root ^ "/dir") 0o700;
      write (root ^ "/dir/visible") "owned";
      write (root ^ "/dir/ignored.private") "private";
      let safety, _, observation = observe root store in
      let plan = prepare root store safety target observation in
      A.apply ~root ~store plan |> ok A.error_to_string;
      Alcotest.(check bool)
        "managed child removed" false
        (Sys.file_exists (root ^ "/dir/visible"));
      Alcotest.(check string)
        "ignored child retained in containing directory" "private"
        (read (root ^ "/dir/ignored.private")))

let tampered_plan () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      write (A.retained_directory ~root ~operation ^ "/plan.cbor") "wrong plan";
      assert_refused "accepted corrupted plan"
        (A.load ~root ~operation ~digest:(A.digest plan) ~safety ~target);
      Alcotest.(check string) "no replacement" "original A" (read (root ^ "/a")))

let destination_preflight () =
  with_root (fun root store ->
      write (root ^ "/a") "target first path";
      let content =
        S.Content.store store "unrepresentable name" |> ok S.error_to_string
      in
      let original_tree =
        S.Tree.create
          [
            ("a", S.Tree.File { mode = S.Regular; content });
            (String.make 300 'z', S.Tree.File { mode = S.Regular; content });
          ]
        |> ok S.error_to_string
      in
      let tree = S.Tree.store store original_tree |> ok S.error_to_string in
      let target =
        S.Snapshot.store store (S.Snapshot.create ~root:tree)
        |> ok S.error_to_string
      in
      write (root ^ "/a") "unchanged source";
      let safety, _, observation = observe root store in
      assert_refused "accepted an unrepresentable later path"
        (A.prepare ~root ~store ~operation ~safety ~target observation);
      Alcotest.(check string)
        "earlier valid target was not installed" "unchanged source"
        (read (root ^ "/a")))

let missing_target_preflight () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let target_tree =
        S.Snapshot.load store target
        |> ok S.error_to_string |> S.Snapshot.root |> S.Tree.load store
        |> ok S.error_to_string
      in
      let content =
        match List.assoc "a" (S.Tree.entries target_tree) with
        | S.Tree.File file -> file.content
        | S.Tree.Directory _ -> Alcotest.fail "expected file"
      in
      Unix.unlink (Store.object_path store (S.Content.stored_object_id content));
      assert_refused "accepted missing target bytes"
        (A.prepare ~root ~store ~operation ~safety ~target observation);
      Alcotest.(check string)
        "source unchanged" "original A"
        (read (root ^ "/a")))

let parent_replacement () =
  with_root (fun root store ->
      Unix.mkdir (root ^ "/dir") 0o700;
      write (root ^ "/dir/file") "target";
      let target = capture root store in
      write (root ^ "/dir/file") "source";
      let safety, _, observation = observe root store in
      let plan = prepare root store safety target observation in
      Unix.rename (root ^ "/dir") (root ^ "/original-dir");
      Unix.mkdir (root ^ "/dir") 0o700;
      write (root ^ "/dir/file") "external directory";
      assert_refused "applied through a replaced parent"
        (A.apply ~root ~store plan);
      Alcotest.(check string)
        "replacement parent retained" "external directory"
        (read (root ^ "/dir/file"));
      Alcotest.(check string)
        "original parent retained" "source"
        (read (root ^ "/original-dir/file")))

let repeated_mixed_transitions () =
  let random = Random.State.make [| 0x502; 0x71 |] in
  for iteration = 0 to 39 do
    with_root (fun root store ->
        let write_state variant =
          write (root ^ "/text")
            (Printf.sprintf "state %d/%d\nline two\n" iteration variant);
          write (root ^ "/binary")
            (String.init (31 + iteration) (fun _ ->
                 Char.chr (Random.State.int random 256)));
          Unix.chmod (root ^ "/binary") (if variant = 0 then 0o644 else 0o755);
          if variant = 0 then (
            Unix.mkdir (root ^ "/mixed") 0o700;
            write (root ^ "/mixed/child") "child")
          else write (root ^ "/mixed") "file replacing a directory"
        in
        write_state 0;
        let source_bytes = read (root ^ "/binary") in
        let safety = capture root store in
        remove (root ^ "/mixed");
        write_state 1;
        let target = capture root store in
        remove (root ^ "/mixed");
        write_state 0;
        write (root ^ "/binary") source_bytes;
        let actual, _, observation = observe root store in
        Alcotest.(check bool)
          "source fixture" true
          (S.Snapshot.equal_id actual safety);
        let plan = prepare root store safety target observation in
        A.apply ~root ~store plan |> ok A.error_to_string;
        Alcotest.(check bool)
          "mixed transition exact snapshot" true
          (S.Snapshot.equal_id target (capture root store));
        A.apply ~root ~store (load root plan safety target)
        |> ok A.error_to_string)
  done

let root_path_replacement () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      let moved = root ^ "-externally-moved" in
      Fun.protect
        ~finally:(fun () -> if Sys.file_exists moved then remove moved)
        (fun () ->
          let once = ref false in
          let observe stage _ =
            if stage = A.Before_mutation && not !once then (
              once := true;
              Unix.rename root moved;
              Unix.mkdir root 0o700)
          in
          assert_refused "continued applying through a stale root descriptor"
            (A.For_test.apply ~observe ~root ~store plan);
          Alcotest.(check int)
            "replacement root untouched" 0
            (Array.length (Sys.readdir root));
          Alcotest.(check string)
            "moved original root untouched" "original A"
            (read (moved ^ "/a"))))

let with_export root run =
  let destination = root ^ "-export" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists destination then remove destination)
    (fun () -> run destination)

let copyout_whole_tree () =
  List.iter
    (fun existing ->
      with_root (fun root store ->
          with_export root (fun destination ->
              let safety, target, _ = fixture root store in
              if existing then Unix.mkdir destination 0o700;
              let prior =
                if existing then Some (Unix.lstat destination).Unix.st_ino
                else None
              in
              let canonical, token =
                A.check_copyout ~root ~store ~target ~destination
                |> ok A.error_to_string
              in
              Alcotest.(check string)
                "canonical destination" destination canonical;
              Alcotest.(check int)
                "native preview token" 32 (String.length token);
              Alcotest.(check bool)
                "copy preview has no staging writes" false
                (Sys.file_exists (root ^ "/.yeokcham/restore-staging"));
              let plan =
                A.prepare_copyout ~root ~store ~operation ~target ~destination
                |> ok A.error_to_string
              in
              Alcotest.(check (option string))
                "plan output scope" (Some destination) (A.destination plan);
              A.apply ~root ~store plan |> ok A.error_to_string;
              Alcotest.(check bool)
                "source unchanged" true
                (S.Snapshot.equal_id safety (capture root store));
              Alcotest.(check bool)
                "whole exact target output" true
                (S.Snapshot.equal_id target (capture destination store));
              Option.iter
                (fun inode ->
                  Alcotest.(check int)
                    "original empty directory retained" inode
                    (Unix.lstat (A.retained_directory ~root ~operation ^ "/0"))
                      .Unix.st_ino)
                prior;
              let loaded =
                A.load ~root ~operation ~digest:(A.digest plan) ~safety:target
                  ~target
                |> ok A.error_to_string
              in
              A.apply ~root ~store loaded |> ok A.error_to_string)))
    [ false; true ]

let copyout_interruptions () =
  List.iter
    (fun boundary ->
      List.iter
        (fun existing ->
          with_root (fun root store ->
              with_export root (fun destination ->
                  let safety, target, _ = fixture root store in
                  if existing then Unix.mkdir destination 0o700;
                  let plan =
                    A.prepare_copyout ~root ~store ~operation ~target
                      ~destination
                    |> ok A.error_to_string
                  in
                  let child = Unix.fork () in
                  if child = 0 then (
                    ignore
                      (A.For_test.apply
                         ~observe:(fun stage _ ->
                           if stage = boundary then Unix._exit 73)
                         ~root ~store plan);
                    Unix._exit 74);
                  let _, status = Unix.waitpid [] child in
                  Alcotest.(check bool)
                    "stopped at actual copy mutation boundary" true
                    (status = Unix.WEXITED 73);
                  let loaded =
                    A.load ~root ~operation ~digest:(A.digest plan)
                      ~safety:target ~target
                    |> ok A.error_to_string
                  in
                  A.apply ~root ~store loaded |> ok A.error_to_string;
                  Alcotest.(check bool)
                    "exact output after restart" true
                    (S.Snapshot.equal_id target (capture destination store));
                  Alcotest.(check bool)
                    "source remains complete original" true
                    (S.Snapshot.equal_id safety (capture root store)))))
        [ false; true ])
    [ A.Before_mutation; A.After_mutation; A.After_sync ]

let copyout_external_obstruction () =
  with_root (fun root store ->
      with_export root (fun destination ->
          let _, target, _ = fixture root store in
          Unix.mkdir destination 0o700;
          let plan =
            A.prepare_copyout ~root ~store ~operation ~target ~destination
            |> ok A.error_to_string
          in
          write (destination ^ "/unexpected") "external data";
          assert_refused "overwrote a newly occupied copy destination"
            (A.apply ~root ~store plan);
          Alcotest.(check string)
            "external bytes retained" "external data"
            (read (destination ^ "/unexpected"))))

let copyout_open_directory_writer () =
  with_root (fun root store ->
      with_export root (fun destination ->
          let _, target, _ = fixture root store in
          Unix.mkdir destination 0o700;
          let plan =
            A.prepare_copyout ~root ~store ~operation ~target ~destination
            |> ok A.error_to_string
          in
          let fd = S.Filesystem.open_at None destination true in
          Fun.protect
            ~finally:(fun () -> Unix.close fd)
            (fun () ->
              let once = ref false in
              let observe stage _ =
                if stage = A.After_mutation && not !once then (
                  once := true;
                  let out = S.Filesystem.create_at fd "external" in
                  Fun.protect
                    ~finally:(fun () -> Unix.close out)
                    (fun () ->
                      ignore (Unix.write_substring out "retained" 0 8);
                      Unix.fsync out))
              in
              assert_refused "accepted unexplained external directory writes"
                (A.For_test.apply ~observe ~root ~store plan);
              Alcotest.(check string)
                "external directory write retained with original inode"
                "retained"
                (read (A.retained_directory ~root ~operation ^ "/0/external"));
              Alcotest.(check bool)
                "installed target remains complete" true
                (S.Snapshot.equal_id target (capture destination store)))))

let copyout_refuses_unsafe_destination () =
  with_root (fun root store ->
      with_export root (fun destination ->
          let _, target, _ = fixture root store in
          Unix.mkdir destination 0o700;
          write (destination ^ "/keep") "private";
          List.iter
            (fun destination ->
              assert_refused "unsafe copy destination accepted"
                (A.check_copyout ~root ~store ~target ~destination))
            [
              destination;
              root;
              Filename.dirname root;
              root ^ "/.yeokcham/export";
            ];
          let link = destination ^ "-link" in
          Unix.symlink destination link;
          Fun.protect
            ~finally:(fun () -> Unix.unlink link)
            (fun () ->
              assert_refused "followed destination symlink"
                (A.check_copyout ~root ~store ~target ~destination:link));
          Alcotest.(check string)
            "unrelated destination data unchanged" "private"
            (read (destination ^ "/keep"))))

let mutate_preserving_mtime path =
  let argv =
    [|
      "python3";
      "-c";
      "import os,sys; p=sys.argv[1]; st=os.stat(p); f=open(p,'r+b'); \
       f.write(b'X'*st.st_size); f.close(); \
       os.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns))";
      path;
    |]
  in
  let pid =
    Unix.create_process "python3" argv Unix.stdin Unix.stdout Unix.stderr
  in
  let _, status = Unix.waitpid [] pid in
  Alcotest.(check bool)
    "mtime-preserving external writer" true (status = Unix.WEXITED 0)

let byte_verification_rejects_preserved_mtime_edit () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      let child = Unix.fork () in
      if child = 0 then (
        ignore
          (A.For_test.apply
             ~observe:(fun stage _ ->
               if stage = A.After_sync then Unix._exit 73)
             ~root ~store plan);
        Unix._exit 74);
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "target installed before interruption" true (status = Unix.WEXITED 73);
      mutate_preserving_mtime (root ^ "/a");
      assert_refused "accepted changed bytes at same owned inode/size/mtime"
        (A.apply ~root ~store (load root plan safety target));
      Alcotest.(check string)
        "changed bytes preserved"
        (String.make (String.length "target A") 'X')
        (read (root ^ "/a"));
      Alcotest.(check string)
        "unapplied path unchanged" "original Z"
        (read (root ^ "/z")))

let[@warning "-4"] corrupt_staging_refuses_before_replacement () =
  with_root (fun root store ->
      let safety, target, observation = fixture root store in
      let plan = prepare root store safety target observation in
      write (A.retained_directory ~root ~operation ^ "/0") "corrupt target";
      (match A.apply ~root ~store plan with
      | Error (A.Invalid_plan _) -> ()
      | Error error -> Alcotest.fail (A.error_to_string error)
      | Ok () -> Alcotest.fail "installed a corrupt staged target");
      Alcotest.(check string)
        "original remains" "original A"
        (read (root ^ "/a")))

let large_binary_verification () =
  with_root (fun root store ->
      let bytes =
        String.init
          ((2 * 1024 * 1024) + 3)
          (fun index -> Char.chr (index * 13 mod 256))
      in
      write (root ^ "/large") bytes;
      Unix.chmod (root ^ "/large") 0o755;
      let target = capture root store in
      Unix.unlink (root ^ "/large");
      let safety, _, observation = observe root store in
      let plan = prepare root store safety target observation in
      A.apply ~root ~store plan |> ok A.error_to_string;
      Alcotest.(check string)
        "large binary exact bytes" bytes
        (read (root ^ "/large"));
      Alcotest.(check bool)
        "executable distinction" true
        ((Unix.stat (root ^ "/large")).Unix.st_perm land 0o111 <> 0);
      A.apply ~root ~store (load root plan safety target)
      |> ok A.error_to_string;
      mutate_preserving_mtime (root ^ "/large");
      assert_refused "manifest verifier accepted altered binary chunks"
        (A.apply ~root ~store (load root plan safety target)))

let () =
  Alcotest.run "Safe local file application"
    [
      ( "application",
        List.map
          (fun (name, f) -> Alcotest.test_case name `Quick f)
          [
            ("exact mixed target and identical retry", exact_apply_and_retry);
            ("whole copy-out into new/empty destinations", copyout_whole_tree);
            ( "bounded large-binary verification and corruption refusal",
              large_binary_verification );
            ("copy-out resumes all mutation boundaries", copyout_interruptions);
            ( "copy-out preserves new destination obstructions",
              copyout_external_obstruction );
            ( "copy-out retains writes through displaced directory descriptors",
              copyout_open_directory_writer );
            ( "copy-out rejects unsafe destinations",
              copyout_refuses_unsafe_destination );
            ( "byte verification rejects edits preserving inode/size/mtime",
              byte_verification_rejects_preserved_mtime_edit );
            ( "corrupt staging refuses before replacement",
              corrupt_staging_refuses_before_replacement );
            ("root path replacement during application", root_path_replacement);
            ("forked interruption at all mutation boundaries", crash_boundaries);
            ("external edit before application", external_edits_are_preserved);
            ( "external writer holds original descriptor",
              concurrent_old_descriptor_edit );
            ("external edit after interruption", edit_after_interruption);
            ("noncolliding ignored paths", ignored_paths);
            ( "ignored directory replacement obstruction",
              ignored_directory_obstruction );
            ( "ignored directory survives managed deletion",
              ignored_directory_kept_on_delete );
            ("corrupted plan refuses before mutation", tampered_plan);
            ( "later unrepresentable target refuses before application",
              destination_preflight );
            ( "missing target refuses before application",
              missing_target_preflight );
            ("replaced parent directory", parent_replacement);
            ( "forty mixed content/type/mode transitions",
              repeated_mixed_transitions );
          ] );
    ]
