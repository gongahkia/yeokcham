module Snapshot_store = Paengi_snapshot
module Store = Paengi_store

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> (
      match int_of_string_opt value with Some seed -> seed | None -> default_seed)

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character -> value := ((!value * 65599) lxor Char.code character) land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "snapshot property base seed: %d\n%!" base_seed

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

let with_directory check =
  let root = Filename.temp_file "paengi-snapshot-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> check root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel bytes)

let bytes_generator = QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 512)

let scan_determinism =
  QCheck2.Test.make ~count:100 ~name:"same filesystem scan has one snapshot identity"
    QCheck2.Gen.(triple bytes_generator bytes_generator bool)
    (fun (left, right, executable) ->
      with_directory (fun root ->
          Unix.mkdir (Filename.concat root "nested") 0o700;
          write_file (Filename.concat root "left") left;
          write_file (Filename.concat root "right") left;
          write_file (Filename.concat (Filename.concat root "nested") "right") right;
          if executable then Unix.chmod (Filename.concat root "right") 0o755;
          Unix.symlink "left" (Filename.concat root "link");
          match Store.init ~root with
          | Error _ -> false
          | Ok store -> (
              match Snapshot_store.scan ~root ~store with
              | Error _ -> false
              | Ok (first, _) -> (
                  match Snapshot_store.scan ~root ~store with
                  | Ok (second, _) -> Snapshot_store.Snapshot.equal_id first second
                  | Error _ -> false))))

let materialise_round_trip =
  QCheck2.Test.make ~count:80 ~name:"scan then materialise preserves snapshot identity"
    QCheck2.Gen.(triple bytes_generator bytes_generator bool)
    (fun (left, right, executable) ->
      with_directory (fun source ->
          with_directory (fun store_root ->
              with_directory (fun destination ->
                  Unix.mkdir (Filename.concat source "nested") 0o700;
                  write_file (Filename.concat source "left") left;
                  write_file (Filename.concat source "right") right;
                  write_file (Filename.concat (Filename.concat source "nested") "again") left;
                  if executable then Unix.chmod (Filename.concat source "right") 0o755;
                  Unix.symlink "left" (Filename.concat source "link");
                  match Store.init ~root:store_root with
                  | Error _ -> false
                  | Ok store -> (
                      match Snapshot_store.scan ~root:source ~store with
                      | Error _ -> false
                      | Ok (source_id, snapshot) -> (
                          match
                            Snapshot_store.Materialize.write ~destination store snapshot
                          with
                          | Error _ -> false
                          | Ok () -> (
                              match Snapshot_store.scan ~root:destination ~store with
                              | Ok (destination_id, _) ->
                                  Snapshot_store.Snapshot.equal_id source_id destination_id
                              | Error _ -> false)))))))

let () =
  Alcotest.run "persisted snapshot properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "scan-determinism") scan_determinism;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "materialise-round-trip") materialise_round_trip;
        ] );
    ]
