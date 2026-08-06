module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Exchange = Paengi_exchange
module Exchange_store = Paengi_exchange_store
module Store = Paengi_store

let default_seed = 20_260_807

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
let () = Printf.printf "two-device property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "two-device property setup failed"

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
  let root = Filename.temp_file "paengi-two-device-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let left_root = Filename.concat root "left" in
  let right_root = Filename.concat root "right" in
  Unix.mkdir left_root 0o700;
  Unix.mkdir right_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let left = Store.init ~root:left_root |> require in
      let right = Store.init ~root:right_root |> require in
      run left right)

let session = Exchange.session_id_of_bytes "two-device-prop!" |> require

let unchanged_ref repository expected =
  Store.read_ref repository ~name:"scratch-head"
  |> require
  |> Option.exists (Store.Mutable_ref.equal expected)

let two_device_restart_and_failure =
  let generator =
    QCheck2.Gen.quad
      (QCheck2.Gen.list_size
         (QCheck2.Gen.int_range 1 12)
         (QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 256)))
      (QCheck2.Gen.int_range 0 12)
      QCheck2.Gen.bool QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:
      "two-device missing-object restart duplicate and corruption preservation"
    generator (fun (payloads, interruption, duplicate_input, corrupt) ->
      with_repositories (fun left right ->
          let objects =
            List.map
              (fun payload -> Store.put left (content payload) |> require)
              payloads
            |> List.sort_uniq Store.Stored_object_id.compare
          in
          let retained =
            Store.put right (content "right-retained") |> require
          in
          let reference =
            Store.compare_and_swap_ref right ~name:"scratch-head" ~expected:None
              ~target:(Some retained)
            |> require
          in
          let input =
            if duplicate_input then List.hd objects :: objects else objects
          in
          let duplicate_rejected =
            (not duplicate_input)
            || Result.is_error
                 (Exchange_store.transfer ~source:left ~destination:right
                    ~session_id:session ~object_ids:input ())
          in
          if (not duplicate_rejected) || not (unchanged_ref right reference)
          then false
          else if corrupt then (
            let corrupted = List.hd objects in
            let output = open_out_bin (Store.object_path left corrupted) in
            Fun.protect
              ~finally:(fun () -> close_out_noerr output)
              (fun () -> output_string output "corrupt");
            Result.is_error
              (Exchange_store.transfer ~source:left ~destination:right
                 ~session_id:session ~object_ids:objects ())
            && Result.is_error (Store.get right corrupted)
            && unchanged_ref right reference)
          else
            let first =
              Exchange_store.transfer ~interrupt_after:interruption ~source:left
                ~destination:right ~session_id:session ~object_ids:objects ()
            in
            let expected_first =
              if interruption < List.length objects then Result.is_error first
              else Result.is_ok first
            in
            expected_first
            && unchanged_ref right reference
            &&
            let right =
              Store.open_repository ~root:(Store.root right) |> require
            in
            match
              Exchange_store.transfer ~source:left ~destination:right
                ~session_id:session ~object_ids:objects ()
            with
            | Error _ -> false
            | Ok _ ->
                List.for_all
                  (fun object_id -> Result.is_ok (Store.get right object_id))
                  objects
                && unchanged_ref right reference))

let () =
  Alcotest.run "two-device synchronisation properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "restart-and-failure")
            two_device_restart_and_failure;
        ] );
    ]
