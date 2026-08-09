module Linux_watcher = Yeokcham_linux_watcher
module Watcher = Yeokcham_watcher

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Linux_watcher.error_to_string error)

let rec remove_tree path =
  try
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root run =
  let root = Filename.temp_file "yeokcham-linux-watcher-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let rec poll_until watcher remaining =
  if remaining = 0 then Alcotest.fail "watcher did not receive an event"
  else
    match Linux_watcher.poll watcher ~timeout:0.1 with
    | Error error -> Alcotest.fail (Linux_watcher.error_to_string error)
    | Ok None -> poll_until watcher (remaining - 1)
    | Ok (Some request) -> request

let created_subdirectories_become_watched () =
  with_root (fun root ->
      let watcher = Linux_watcher.start ~root |> require_ok in
      Fun.protect
        ~finally:(fun () -> Linux_watcher.close watcher)
        (fun () ->
          let directory = Filename.concat root "nested" in
          Unix.mkdir directory 0o700;
          ignore (poll_until watcher 20);
          let file = Filename.concat directory "tracked" in
          write_file file "contents";
          let request = poll_until watcher 20 in
          Alcotest.(check bool)
            "nested file event is normalized" true
            (request
            = {
                Watcher.reason = Watcher.Path_change;
                target = Watcher.Paths [ [ "nested"; "tracked" ] ];
              })))

let in_tree_renames_are_paired () =
  with_root (fun root ->
      let watcher = Linux_watcher.start ~root |> require_ok in
      Fun.protect
        ~finally:(fun () -> Linux_watcher.close watcher)
        (fun () ->
          let source = Filename.concat root "before" in
          write_file source "contents";
          ignore (poll_until watcher 20);
          Unix.rename source (Filename.concat root "after");
          let request = poll_until watcher 20 in
          Alcotest.(check bool)
            "rename keeps both paths" true
            (request
            = {
                Watcher.reason = Watcher.Rename;
                target = Watcher.Paths [ [ "after" ]; [ "before" ] ];
              })))

let removed_directories_do_not_drop_remaining_coverage () =
  with_root (fun root ->
      let watcher = Linux_watcher.start ~root |> require_ok in
      Fun.protect
        ~finally:(fun () -> Linux_watcher.close watcher)
        (fun () ->
          let removed = Filename.concat root "removed" in
          Unix.mkdir removed 0o700;
          ignore (poll_until watcher 20);
          Unix.rmdir removed;
          ignore (poll_until watcher 20);
          let kept = Filename.concat root "kept" in
          write_file kept "contents";
          let request = poll_until watcher 20 in
          Alcotest.(check bool)
            "remaining root coverage stays active" true
            (request
            = {
                Watcher.reason = Watcher.Path_change;
                target = Watcher.Paths [ [ "kept" ] ];
              })))

let symlink_roots_are_rejected () =
  with_root (fun root ->
      let target = Filename.concat root "target" in
      let link = Filename.concat root "link" in
      Unix.mkdir target 0o700;
      Unix.symlink target link;
      Alcotest.(check bool)
        "symlink root rejects" true
        (Result.is_error (Linux_watcher.start ~root:link)))

let invalid_poll_timeouts_are_rejected () =
  with_root (fun root ->
      let watcher = Linux_watcher.start ~root |> require_ok in
      Fun.protect
        ~finally:(fun () -> Linux_watcher.close watcher)
        (fun () ->
          Alcotest.(check bool)
            "negative timeout rejects" true
            (Result.is_error (Linux_watcher.poll watcher ~timeout:(-0.1)))))

let repository_metadata_is_not_observed () =
  with_root (fun root ->
      let metadata = Filename.concat root ".yeokcham" in
      Unix.mkdir metadata 0o700;
      let watcher = Linux_watcher.start ~root |> require_ok in
      Fun.protect
        ~finally:(fun () -> Linux_watcher.close watcher)
        (fun () ->
          write_file (Filename.concat metadata "object") "opaque bytes";
          let request = Linux_watcher.poll watcher ~timeout:0.1 |> require_ok in
          Alcotest.(check (option bool))
            "metadata writes do not request a scan" None
            (Option.map (fun _ -> true) request)))

let () =
  Alcotest.run "Linux watcher"
    [
      ( "source",
        [
          Alcotest.test_case "new directories are recursively watched" `Quick
            created_subdirectories_become_watched;
          Alcotest.test_case "in-tree renames are paired" `Quick
            in_tree_renames_are_paired;
          Alcotest.test_case "removed directories preserve root coverage" `Quick
            removed_directories_do_not_drop_remaining_coverage;
          Alcotest.test_case "symlink roots reject" `Quick
            symlink_roots_are_rejected;
          Alcotest.test_case "invalid poll timeout rejects" `Quick
            invalid_poll_timeouts_are_rejected;
          Alcotest.test_case "repository metadata is excluded" `Quick
            repository_metadata_is_not_observed;
        ] );
    ]
