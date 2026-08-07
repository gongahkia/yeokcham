module Store = Yeokcham_store

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "v2 root property base seed: %d\n%!" base_seed

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

let with_empty_root run =
  let root = Filename.temp_file "yeokcham-v2-root-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let metadata_path root = Filename.concat root ".yeokcham"

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let required_directories = [ "objects"; "refs"; "locks"; "journal" ]

let write_layout root ~mask ~format =
  let metadata = metadata_path root in
  Unix.mkdir metadata 0o700;
  List.iteri
    (fun index name ->
      if mask land (1 lsl index) <> 0 then
        Unix.mkdir (Filename.concat metadata name) 0o700)
    required_directories;
  write_file (Filename.concat metadata "format") format

let missing_layout_is_never_repaired =
  QCheck2.Test.make ~count:100
    ~name:"v2 root opening never repairs a generated incomplete layout"
    (QCheck2.Gen.int_range 0 14) (fun mask ->
      with_empty_root (fun root ->
          write_layout root ~mask ~format:Store.root_format;
          match Store.open_repository ~root with
          | Ok _ -> false
          | Error _ ->
              required_directories
              |> List.mapi (fun index name ->
                  mask land (1 lsl index) <> 0
                  || not
                       (Sys.file_exists
                          (Filename.concat (metadata_path root) name)))
              |> List.for_all Fun.id))

let malformed_format_is_never_accepted =
  QCheck2.Test.make ~count:100
    ~name:"v2 root opening rejects generated noncanonical format bytes"
    QCheck2.Gen.(string_size (0 -- 1024))
    (fun suffix ->
      with_empty_root (fun root ->
          write_layout root ~mask:15 ~format:(Store.root_format ^ suffix ^ "x");
          match Store.open_repository ~root with
          | Error _ -> true
          | Ok _ -> false))

let () =
  Alcotest.run "v2 repository root properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "missing-layout")
            missing_layout_is_never_repaired;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "malformed-format")
            malformed_format_is_never_accepted;
        ] );
    ]
