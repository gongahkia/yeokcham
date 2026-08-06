module Snapshot_store = Yeokcham_snapshot
module Store = Yeokcham_store

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> (
      match int_of_string_opt value with
      | Some seed -> seed
      | None -> default_seed)

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
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
  let root = Filename.temp_file "yeokcham-snapshot-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> check root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let deterministic_bytes seed length =
  let state = ref (Int64.of_int seed) in
  let bytes = Bytes.create length in
  for index = 0 to length - 1 do
    state := Int64.add (Int64.mul !state 2862933555777941757L) 3037000493L;
    Bytes.set bytes index
      (Char.chr Int64.(to_int (logand (shift_right_logical !state 32) 255L)))
  done;
  Bytes.unsafe_to_string bytes

let write_byte path offset value =
  let descriptor = Unix.openfile path [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () ->
      try Unix.close descriptor with Unix.Unix_error _ -> ())
    (fun () ->
      ignore (Unix.lseek descriptor offset Unix.SEEK_SET);
      ignore (Unix.write descriptor (Bytes.make 1 value) 0 1))

let small_bytes_generator =
  QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 512)

let bytes_generator = small_bytes_generator

let scan_determinism =
  QCheck2.Test.make ~count:100
    ~name:"same filesystem scan has one snapshot identity"
    QCheck2.Gen.(triple bytes_generator bytes_generator bool)
    (fun (left, right, executable) ->
      with_directory (fun root ->
          Unix.mkdir (Filename.concat root "nested") 0o700;
          write_file (Filename.concat root "left") left;
          write_file (Filename.concat root "right") left;
          write_file
            (Filename.concat (Filename.concat root "nested") "right")
            right;
          if executable then Unix.chmod (Filename.concat root "right") 0o755;
          Unix.symlink "left" (Filename.concat root "link");
          match Store.init ~root with
          | Error _ -> false
          | Ok store -> (
              match Snapshot_store.scan ~root ~store with
              | Error _ -> false
              | Ok (first, _) -> (
                  match Snapshot_store.scan ~root ~store with
                  | Ok (second, _) ->
                      Snapshot_store.Snapshot.equal_id first second
                  | Error _ -> false))))

let materialise_round_trip =
  QCheck2.Test.make ~count:80
    ~name:"scan then materialise preserves snapshot identity"
    QCheck2.Gen.(triple bytes_generator bytes_generator bool)
    (fun (left, right, executable) ->
      with_directory (fun source ->
          with_directory (fun store_root ->
              with_directory (fun destination ->
                  Unix.mkdir (Filename.concat source "nested") 0o700;
                  write_file (Filename.concat source "left") left;
                  write_file (Filename.concat source "right") right;
                  write_file
                    (Filename.concat (Filename.concat source "nested") "again")
                    left;
                  if executable then
                    Unix.chmod (Filename.concat source "right") 0o755;
                  Unix.symlink "left" (Filename.concat source "link");
                  match Store.init ~root:store_root with
                  | Error _ -> false
                  | Ok store -> (
                      match Snapshot_store.scan ~root:source ~store with
                      | Error _ -> false
                      | Ok (source_id, snapshot) -> (
                          match
                            Snapshot_store.Materialize.write ~destination store
                              snapshot
                          with
                          | Error _ -> false
                          | Ok () -> (
                              match
                                Snapshot_store.scan ~root:destination ~store
                              with
                              | Ok (destination_id, _) ->
                                  Snapshot_store.Snapshot.equal_id source_id
                                    destination_id
                              | Error _ -> false)))))))

let file_content_at repository snapshot path =
  let rec find identity = function
    | [] -> None
    | [ name ] -> (
        match Snapshot_store.Tree.load repository identity with
        | Ok tree -> (
            match List.assoc_opt name (Snapshot_store.Tree.entries tree) with
            | Some (Snapshot_store.Tree.File { content; _ }) -> Some content
            | Some (Snapshot_store.Tree.Directory _) | None -> None)
        | Error _ -> None)
    | directory :: rest -> (
        match Snapshot_store.Tree.load repository identity with
        | Ok tree -> (
            match
              List.assoc_opt directory (Snapshot_store.Tree.entries tree)
            with
            | Some (Snapshot_store.Tree.Directory child) -> find child rest
            | Some (Snapshot_store.Tree.File _) | None -> None)
        | Error _ -> None)
  in
  find (Snapshot_store.Snapshot.root snapshot) path

let manifest_chunks repository content =
  Snapshot_store.Manifest.load repository
    (Snapshot_store.Manifest.of_stored_object_id
       (Snapshot_store.Content.stored_object_id content))
  |> Result.to_option
  |> Option.map Snapshot_store.Manifest.chunks

let has_shared_chunk left right =
  List.exists
    (fun (left, _) ->
      List.exists
        (fun (right, _) -> Snapshot_store.Chunk.equal_id left right)
        right)
    left

let generated_filesystem_history =
  QCheck2.Test.make ~count:6
    ~name:"generated filesystem histories preserve exact snapshots"
    (QCheck2.Gen.int_range 1 1_000_000) (fun seed ->
      with_directory (fun source ->
          with_directory (fun store_root ->
              with_directory (fun destination ->
                  let nested = Filename.concat source "nested" in
                  let deep = Filename.concat nested "deep" in
                  let wide = Filename.concat source "wide" in
                  Unix.mkdir nested 0o700;
                  Unix.mkdir deep 0o700;
                  Unix.mkdir wide 0o700;
                  Unix.mkdir (Filename.concat source "empty-directory") 0o700;
                  write_file (Filename.concat source "empty-file") "";
                  write_file
                    (Filename.concat source "binary")
                    ("\000\255" ^ deterministic_bytes seed 4096);
                  write_file
                    (Filename.concat source "threshold-minus")
                    (deterministic_bytes (seed + 1)
                       (Snapshot_store.inline_file_limit - 1));
                  write_file
                    (Filename.concat source "threshold-at")
                    (deterministic_bytes (seed + 2)
                       Snapshot_store.inline_file_limit);
                  write_file
                    (Filename.concat source "threshold-plus")
                    (deterministic_bytes (seed + 3)
                       (Snapshot_store.inline_file_limit + 1));
                  let large_path = Filename.concat deep "large.bin" in
                  let large =
                    deterministic_bytes (seed + 4) ((3 * 131_072) + 17)
                  in
                  write_file large_path large;
                  write_file
                    (Filename.concat source "run")
                    "#!/bin/sh\nexit 0\n";
                  Unix.chmod (Filename.concat source "run") 0o755;
                  write_file (Filename.concat source "rename-source") "history";
                  Unix.symlink "nested/deep/large.bin"
                    (Filename.concat source "large-link");
                  write_file
                    (Filename.concat source "café-雪")
                    (deterministic_bytes (seed + 5) 19);
                  for index = 0 to 11 do
                    write_file
                      (Filename.concat wide (Printf.sprintf "file-%02d" index))
                      (deterministic_bytes (seed + 100 + index) (index + 1))
                  done;
                  match Store.init ~root:store_root with
                  | Error _ -> false
                  | Ok store -> (
                      match Snapshot_store.scan ~root:source ~store with
                      | Error _ -> false
                      | Ok (base_id, base_snapshot) -> (
                          match
                            Snapshot_store.Materialize.write ~destination store
                              base_snapshot
                          with
                          | Error _ -> false
                          | Ok () -> (
                              match
                                Snapshot_store.scan ~root:destination ~store
                              with
                              | Error _ -> false
                              | Ok (destination_id, _) ->
                                  let materialized_metadata_is_exact =
                                    Unix.readlink
                                      (Filename.concat destination "large-link")
                                    = "nested/deep/large.bin"
                                    && (Unix.stat
                                          (Filename.concat destination "run"))
                                         .Unix.st_perm land 0o111
                                       <> 0
                                    && (Unix.lstat
                                          (Filename.concat destination
                                             "empty-directory"))
                                         .Unix.st_kind = Unix.S_DIR
                                  in
                                  if
                                    (not materialized_metadata_is_exact)
                                    || not
                                         (Snapshot_store.Snapshot.equal_id
                                            base_id destination_id)
                                  then false
                                  else (
                                    Unix.rename
                                      (Filename.concat source "rename-source")
                                      (Filename.concat source "renamed");
                                    match
                                      Snapshot_store.scan ~root:source ~store
                                    with
                                    | Error _ -> false
                                    | Ok (renamed_id, _) ->
                                        if
                                          Snapshot_store.Snapshot.equal_id
                                            base_id renamed_id
                                        then false
                                        else (
                                          Unix.unlink
                                            (Filename.concat source "renamed");
                                          write_file
                                            (Filename.concat source
                                               "rename-source")
                                            "history";
                                          match
                                            Snapshot_store.scan ~root:source
                                              ~store
                                          with
                                          | Error _ -> false
                                          | Ok (recreated_id, _) -> (
                                              if
                                                not
                                                  (Snapshot_store.Snapshot
                                                   .equal_id base_id
                                                     recreated_id)
                                              then false
                                              else
                                                let replacement =
                                                  if large.[200_000] = '\000'
                                                  then '\001'
                                                  else '\000'
                                                in
                                                write_byte large_path 200_000
                                                  replacement;
                                                match
                                                  Snapshot_store.scan
                                                    ~root:source ~store
                                                with
                                                | Error _ -> false
                                                | Ok
                                                    ( changed_id,
                                                      changed_snapshot ) -> (
                                                    if
                                                      Snapshot_store.Snapshot
                                                      .equal_id base_id
                                                        changed_id
                                                    then false
                                                    else
                                                      match
                                                        ( file_content_at store
                                                            base_snapshot
                                                            [
                                                              "nested";
                                                              "deep";
                                                              "large.bin";
                                                            ],
                                                          file_content_at store
                                                            changed_snapshot
                                                            [
                                                              "nested";
                                                              "deep";
                                                              "large.bin";
                                                            ] )
                                                      with
                                                      | Some base, Some changed
                                                        -> (
                                                          match
                                                            ( manifest_chunks
                                                                store base,
                                                              manifest_chunks
                                                                store changed )
                                                          with
                                                          | ( Some base,
                                                              Some changed ) ->
                                                              has_shared_chunk
                                                                base changed
                                                          | None, _ | _, None ->
                                                              false)
                                                      | None, _ | _, None ->
                                                          false)))))))))))

let () =
  Alcotest.run "persisted snapshot properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "scan-determinism")
            scan_determinism;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "materialise-round-trip")
            materialise_round_trip;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-filesystem-history")
            generated_filesystem_history;
        ] );
    ]
