module Health = Yeokcham_v4_health
module Repository = Yeokcham_v4_health_repository
module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service
module Store = Yeokcham_store
module V4_store = Yeokcham_v4_store

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
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file root contents =
  Out_channel.with_open_bin (Filename.concat root "main.ml") (fun output ->
      Out_channel.output_string output contents)

let initialize root =
  Service.init ~root
    ~creator:(Model.Device_id.of_string "device-alice" |> Result.get_ok)
    ~username:(Model.Username.of_string "alice" |> Result.get_ok)
    ~initial_draft:(Model.Draft_id.of_string "draft-one" |> Result.get_ok)
    ~title:"health property"
  |> Result.get_ok

let tree_fingerprint root =
  let rec entries base relative =
    Sys.readdir base |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun name ->
        let path = Filename.concat base name in
        let next = Filename.concat relative name in
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_DIR -> (next ^ "/") :: entries path next
        | Unix.S_REG ->
            [ next ^ ":" ^ In_channel.with_open_bin path In_channel.input_all ]
        | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
            [ next ])
  in
  entries root ""

let missing_closure_verification_is_no_write =
  let generator =
    QCheck2.Gen.(pair bool (string_size ~gen:char (int_range 0 96)))
  in
  QCheck2.Test.make ~count:40
    ~name:"generated clean and missing closures are diagnosed without writes"
    generator (fun (missing, contents) ->
      with_directory "v4-health-property-" (fun root ->
          write_file root contents;
          let status = initialize root in
          (if missing then
             let repository = V4_store.open_repository ~root |> Result.get_ok in
             let store = V4_store.underlying_store repository in
             let snapshot =
               Model.Snapshot_id.to_string status.Service.checkpoint
               |> Store.Stored_object_id.of_hex |> Result.get_ok
             in
             Unix.unlink (Store.object_path store snapshot));
          let before = tree_fingerprint root in
          let report = Repository.verify ~root in
          let has_missing =
            Health.report_damages report
            |> List.exists (fun damage ->
                Health.damage_code damage = Health.Missing_object)
          in
          has_missing = missing && before = tree_fingerprint root))

let () =
  Alcotest.run "V4 health repository properties"
    [
      ( "verification",
        [ QCheck_alcotest.to_alcotest missing_closure_verification_is_no_write ]
      );
    ]
