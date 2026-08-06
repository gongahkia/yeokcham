module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
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
let () = Printf.printf "exchange property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "exchange property setup failed"

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
  let root = Filename.temp_file "yeokcham-exchange-property-" "" in
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

let session byte = Exchange.session_id_of_bytes (String.make 16 byte) |> require
let unique_sorted ids = List.sort_uniq Store.Stored_object_id.compare ids

let transfer_preserves_objects_and_refs =
  let generator =
    QCheck2.Gen.triple
      (QCheck2.Gen.list_size
         (QCheck2.Gen.int_range 0 12)
         (QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 128)))
      (QCheck2.Gen.int_range 0 12)
      QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:"exchange restart, duplicate input, and interruption preserve refs"
    generator (fun (payloads, interruption, duplicate_input) ->
      with_repositories (fun source destination ->
          let object_ids =
            List.map
              (fun payload -> Store.put source (content payload) |> require)
              payloads
            |> unique_sorted
          in
          let local =
            Store.put destination (content "destination-local") |> require
          in
          let initial_ref =
            Store.compare_and_swap_ref destination ~name:"scratch-head"
              ~expected:None ~target:(Some local)
            |> require
          in
          let input =
            if duplicate_input && object_ids <> [] then
              List.hd object_ids :: object_ids
            else object_ids
          in
          let input =
            if duplicate_input && object_ids <> [] then
              List.sort Store.Stored_object_id.compare input
            else input
          in
          let first =
            Exchange_store.transfer ~interrupt_after:interruption ~source
              ~destination ~session_id:(session 'a') ~object_ids:input ()
          in
          let ref_after_first =
            Store.read_ref destination ~name:"scratch-head" |> require
          in
          if
            not
              (Option.exists
                 (Store.Mutable_ref.equal initial_ref)
                 ref_after_first)
          then false
          else
            let first_is_expected =
              if duplicate_input && object_ids <> [] then Result.is_error first
              else if interruption < List.length object_ids then
                Result.is_error first
              else Result.is_ok first
            in
            first_is_expected
            &&
            match
              Exchange_store.transfer ~source ~destination
                ~session_id:(session 'b') ~object_ids ()
            with
            | Error _ -> false
            | Ok _ ->
                let ref_after_restart =
                  Store.read_ref destination ~name:"scratch-head" |> require
                in
                Option.exists
                  (Store.Mutable_ref.equal initial_ref)
                  ref_after_restart
                && List.for_all
                     (fun object_id ->
                       Result.is_ok (Store.get destination object_id))
                     object_ids))

let () =
  Alcotest.run "exchange properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "restart-and-interruption")
            transfer_preserves_objects_and_refs;
        ] );
    ]
