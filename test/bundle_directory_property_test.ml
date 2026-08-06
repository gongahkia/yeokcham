module Bundle = Yeokcham_bundle
module Directory = Yeokcham_bundle_directory
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Store = Yeokcham_store

let default_seed = 20_260_808

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
let () = Printf.printf "bundle directory property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "bundle directory property setup failed"

let key =
  Bundle.key_of_bytes (String.init 32 (fun index -> Char.chr (index + 33)))
  |> require

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require

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

let with_repositories run =
  let root = Filename.temp_file "yeokcham-bundle-directory-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  let shared = Filename.concat root "shared" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Unix.mkdir shared 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require in
      let destination = Store.init ~root:destination_root |> require in
      run source destination shared)

let write_file path bytes =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output bytes)

let ref_is_unchanged repository reference =
  Store.read_ref repository ~name:"scratch-head"
  |> require
  |> Option.exists (Store.Mutable_ref.equal reference)

let directory_export_import_retry =
  let generator =
    QCheck2.Gen.triple
      (QCheck2.Gen.list_size
         (QCheck2.Gen.int_range 0 20)
         (QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 256)))
      QCheck2.Gen.bool QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:"directory bundle retry duplicate input and corruption preserve refs"
    generator (fun (payloads, duplicate_input, corrupt) ->
      with_repositories (fun source destination shared ->
          let object_ids =
            List.map
              (fun payload -> Store.put source (content payload) |> require)
              payloads
            |> List.sort_uniq Store.Stored_object_id.compare
          in
          let retained =
            Store.put destination (content "destination") |> require
          in
          let reference =
            Store.compare_and_swap_ref destination ~name:"scratch-head"
              ~expected:None ~target:(Some retained)
            |> require
          in
          let input =
            if duplicate_input && object_ids <> [] then
              List.hd object_ids :: object_ids
            else List.rev object_ids
          in
          match
            Directory.export ~directory:shared ~repository:source ~key
              ~object_ids:input
          with
          | Error _ ->
              duplicate_input && object_ids <> []
              && ref_is_unchanged destination reference
              && Directory.list ~directory:shared |> require |> List.is_empty
          | Ok complete -> (
              if corrupt then (
                write_file (Directory.complete_path complete) "corrupt";
                Result.is_error
                  (Directory.import ~repository:destination ~key complete)
                && List.for_all
                     (fun object_id ->
                       Result.is_error (Store.get destination object_id))
                     object_ids
                && ref_is_unchanged destination reference)
              else
                match
                  Directory.import ~repository:destination ~key complete
                with
                | Error _ -> false
                | Ok imported -> (
                    List.length imported = List.length object_ids
                    && ref_is_unchanged destination reference
                    &&
                    let destination =
                      Store.open_repository ~root:(Store.root destination)
                      |> require
                    in
                    match
                      Directory.import ~repository:destination ~key complete
                    with
                    | Error _ -> false
                    | Ok retried ->
                        List.length retried = List.length imported
                        && ref_is_unchanged destination reference))))

let () =
  Alcotest.run "shared-directory bundle properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "retry-and-corruption")
            directory_export_import_retry;
        ] );
    ]
