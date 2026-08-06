module Bundle = Paengi_bundle
module Bundle_store = Paengi_bundle_store
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Store = Paengi_store

let default_seed = 20_260_806

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
let () = Printf.printf "bundle property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "bundle property setup failed"

let key =
  Bundle.key_of_bytes (String.init 32 (fun index -> Char.chr (index + 1)))
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
  let root = Filename.temp_file "paengi-bundle-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require in
      let destination = Store.init ~root:destination_root |> require in
      run source destination)

let object_ids_equal left right =
  List.length left = List.length right
  && List.for_all2 Store.Stored_object_id.equal left right

let bundle_restart_and_rejection =
  let generator =
    QCheck2.Gen.triple
      (QCheck2.Gen.list_size
         (QCheck2.Gen.int_range 0 24)
         (QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 256)))
      QCheck2.Gen.bool QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:
      "bundle export/import restart, duplicate input, and rejection preserve \
       refs" generator (fun (payloads, duplicate_input, corrupt) ->
      with_repositories (fun source destination ->
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
          match Bundle_store.export source ~key ~object_ids:input with
          | Error _ ->
              duplicate_input && object_ids <> []
              && Option.exists
                   (Store.Mutable_ref.equal reference)
                   (Store.read_ref destination ~name:"scratch-head" |> require)
          | Ok exported -> (
              let delivered = if corrupt then exported ^ "\000" else exported in
              let first = Bundle_store.import destination ~key delivered in
              let ref_after_first =
                Store.read_ref destination ~name:"scratch-head" |> require
              in
              if
                not
                  (Option.exists
                     (Store.Mutable_ref.equal reference)
                     ref_after_first)
              then false
              else if corrupt then
                Result.is_error first
                && List.for_all
                     (fun object_id ->
                       Result.is_error (Store.get destination object_id))
                     object_ids
              else
                match first with
                | Error _ -> false
                | Ok imported -> (
                    object_ids_equal
                      (List.sort Store.Stored_object_id.compare object_ids)
                      imported
                    &&
                    let reopened =
                      Store.open_repository ~root:(Store.root destination)
                      |> require
                    in
                    match Bundle_store.import reopened ~key exported with
                    | Error _ -> false
                    | Ok retried ->
                        object_ids_equal imported retried
                        && Option.exists
                             (Store.Mutable_ref.equal reference)
                             (Store.read_ref reopened ~name:"scratch-head"
                             |> require)))))

let () =
  Alcotest.run "bundle properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "restart-and-rejection")
            bundle_restart_and_rejection;
        ] );
    ]
