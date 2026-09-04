module Hook = Yeokcham_v4_hook
module Store = Yeokcham_v4_hook_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

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

let with_root run =
  let root = Filename.temp_file "v4-hook-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".yeokcham") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let hook () =
  Hook.make ~event:Hook.Save ~argv:[ "/usr/bin/true" ]
  |> require_ok Hook.error_to_string

let local_registry_round_trips_atomically () =
  with_root (fun root ->
      let registry =
        Hook.add Hook.empty (hook ()) |> require_ok Hook.error_to_string
      in
      Store.save ~root registry |> require_ok Store.error_to_string;
      let loaded = Store.load ~root |> require_ok Store.error_to_string in
      Alcotest.(check string)
        "stored canonical hook registry" (Hook.encode registry)
        (Hook.encode loaded);
      let target = Store.path ~root in
      Alcotest.(check bool)
        "registry is private" true
        (Int.equal (Unix.stat target).Unix.st_perm 0o600))

let corrupt_registry_refuses_without_source_effect () =
  with_root (fun root ->
      let registry =
        Hook.add Hook.empty (hook ()) |> require_ok Hook.error_to_string
      in
      Store.save ~root registry |> require_ok Store.error_to_string;
      let target = Store.path ~root in
      Out_channel.with_open_bin target (fun output ->
          Out_channel.output_string output "corrupt hooks");
      Alcotest.(check bool)
        "corrupt local hook registry refuses" true
        (Result.is_error (Store.load ~root));
      let retained = In_channel.with_open_bin target In_channel.input_all in
      Alcotest.(check string)
        "corrupt local registry remains inspectable" "corrupt hooks" retained)

let () =
  Alcotest.run "V4 hook store"
    [
      ( "persistence",
        [
          Alcotest.test_case "local registry round trips atomically" `Quick
            local_registry_round_trips_atomically;
          Alcotest.test_case "corrupt local registry refuses" `Quick
            corrupt_registry_refuses_without_source_effect;
        ] );
    ]
