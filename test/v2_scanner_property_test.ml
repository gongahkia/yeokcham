module Model = Yeokcham_model
module Scanner = Yeokcham_v2_scanner

let default_seed = 20_260_809

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
let () = Printf.printf "v2 scanner property base seed: %d\n%!" base_seed
let path = Model.Path.of_components [ "file" ] |> Result.get_ok

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

let scans_generated_exact_regular_bytes =
  QCheck2.Test.make ~count:100
    ~name:"V2 scanner preserves generated exact regular-file bytes"
    QCheck2.Gen.(string_size (int_range 0 4096))
    (fun content ->
      let root = Filename.temp_file "yeokcham-v2-scanner-property-" "" in
      Unix.unlink root;
      Unix.mkdir root 0o700;
      Fun.protect
        ~finally:(fun () -> remove_tree root)
        (fun () ->
          let file = Filename.concat root "file" in
          Out_channel.with_open_bin file (fun channel ->
              Out_channel.output_string channel content);
          let expected =
            Model.Snapshot.of_entries
              [
                Model.File_path (path, { Model.mode = Model.Regular; content });
              ]
            |> Result.get_ok
          in
          match Scanner.scan ~root with
          | Ok actual -> Model.Snapshot.equal expected actual
          | Error _ -> false))

let () =
  Alcotest.run "V2 exact working-tree scanner properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-exact-bytes")
            scans_generated_exact_regular_bytes;
        ] );
    ]
