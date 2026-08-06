module Divergence = Yeokcham_divergence
module Divergence_store = Yeokcham_divergence_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Event = Yeokcham_ref_event
module Event_store = Yeokcham_ref_event_store
module Store = Yeokcham_store

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Event.signer_key_id;
}

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
let () = Printf.printf "divergence property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "divergence property setup failed"

let signer =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr (index + 1)))
    |> require
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let key_id = Event.signer_key_id_of_public_key public_key |> require in
  { private_key; public_key; key_id }

let object_id index =
  let bytes = Bytes.make 32 '\000' in
  Bytes.set bytes 0 (Char.chr (index lsr 8));
  Bytes.set bytes 1 (Char.chr (index land 255));
  Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string bytes)
  |> Option.get

let state generation target =
  Event.make_ref_state ~generation ~target |> require

let event index =
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format
      ~ref_name:"scratch-head" ~signer_key_id:signer.key_id ~signer_sequence:0L
      ~previous:None ~observed:(state 0L None)
      ~proposed:(state 1L (Some (object_id index)))
      ~mandatory_features:0L
    |> require
  in
  let signature =
    Event.signing_bytes unsigned
    |> require
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require

let trusted_keys =
  [ { Event.key_id = signer.key_id; public_key = signer.public_key } ]

let verify event =
  match
    Event.verify_for_device ~repository_format:Store.repository_format
      ~trusted_keys event
    |> require
  with
  | Some verified -> verified
  | None -> failwith "trusted generated event was untrusted"

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

let with_repository run =
  let root = Filename.temp_file "yeokcham-divergence-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> Store.init ~root |> require |> run)

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require

let delivery_restart_corruption =
  let generator =
    QCheck2.Gen.triple
      (QCheck2.Gen.list_size
         (QCheck2.Gen.int_range 1 30)
         (QCheck2.Gen.int_range 1 12))
      (QCheck2.Gen.list_size (QCheck2.Gen.int_range 1 30) QCheck2.Gen.bool)
      QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:
      "divergence union survives delivery order duplicates restart and \
       corruption" generator (fun (deliveries, restarts, corrupt) ->
      with_repository (fun repository ->
          let retained = Store.put repository (content "retained") |> require in
          let reference =
            Store.compare_and_swap_ref repository ~name:"scratch-head"
              ~expected:None ~target:(Some retained)
            |> require
          in
          let entries =
            Array.init 13 (fun index ->
                let event = event index in
                let object_id =
                  Event_store.store_event repository event |> require
                in
                Divergence.entry_of_verified ~object_id (verify event))
          in
          let repository, expected =
            List.fold_left
              (fun (repository, expected) index ->
                let published =
                  Divergence_store.publish repository ~trusted_keys
                    [ entries.(0); entries.(index) ]
                in
                match published with
                | Error _ -> failwith "valid divergence publication failed"
                | Ok _ ->
                    let repository =
                      if List.nth restarts ((index - 1) mod List.length restarts)
                      then
                        Store.open_repository ~root:(Store.root repository)
                        |> require
                      else repository
                    in
                    (repository, index :: expected))
              (repository, [ 0 ]) deliveries
          in
          let expected = List.sort_uniq Int.compare expected in
          let actual =
            Divergence_store.load_published repository ~trusted_keys
              ~ref_name:"scratch-head"
            |> require |> Option.get
          in
          let ref_unchanged =
            Store.read_ref repository ~name:"scratch-head"
            |> require
            |> Option.exists (Store.Mutable_ref.equal reference)
          in
          let corruption_rejected =
            (not corrupt)
            || Result.is_error (Divergence_store.decode_binding "corrupt")
          in
          List.length (Divergence.entries actual) = List.length expected
          && ref_unchanged && corruption_rejected))

let () =
  Alcotest.run "divergence properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "delivery-restart-corruption")
            delivery_restart_corruption;
        ] );
    ]
