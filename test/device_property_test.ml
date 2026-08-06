module Device = Paengi_device
module Device_store = Paengi_device_store
module Encoding = Paengi_encoding
module Event = Paengi_ref_event
module Store = Paengi_store

type signer = {
  identity : Device.t;
  private_key : Mirage_crypto_ec.Ed25519.priv;
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
let () = Printf.printf "device property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "device property setup failed"

let device_id seed =
  String.init 32 (fun index -> Char.chr ((seed + index) land 255))
  |> Device.device_id_of_bytes |> require

let signer seed =
  let private_key =
    String.init 32 (fun index -> Char.chr ((seed + index + 1) land 255))
    |> Mirage_crypto_ec.Ed25519.priv_of_octets |> require
  in
  let generated =
    Device.make_generated ~device_id:(device_id seed) ~private_key
      ~mandatory_features:0L
    |> require
  in
  { identity = Device.generated_identity generated; private_key }

let signed_event signer =
  let observed = Event.make_ref_state ~generation:0L ~target:None |> require in
  let target =
    Store.Stored_object_id.of_raw_bytes (String.make 32 '\001') |> Option.get
  in
  let proposed =
    Event.make_ref_state ~generation:1L ~target:(Some target) |> require
  in
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format
      ~ref_name:"scratch-head"
      ~signer_key_id:(Device.signer_key_id signer.identity)
      ~signer_sequence:0L ~previous:None ~observed ~proposed
      ~mandatory_features:0L
    |> require
  in
  let signature =
    Event.signing_bytes unsigned
    |> require
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require

let verified_event signer =
  let trusted_keys =
    [
      {
        Event.key_id = Device.signer_key_id signer.identity;
        public_key = Device.public_key signer.identity;
      };
    ]
  in
  match
    Event.verify_for_device ~repository_format:Store.repository_format
      ~trusted_keys (signed_event signer)
    |> require
  with
  | Some event -> event
  | None -> failwith "trusted generated event was unmapped"

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
  let root = Filename.temp_file "paengi-device-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> Store.init ~root |> require |> run)

let resolution_is_resolved registry signer =
  Device.resolve_verified registry (verified_event signer)
  |> Device.resolution_to_string
  |> String.starts_with ~prefix:"device-resolved:"

let restart_and_corruption =
  let generator =
    QCheck2.Gen.pair (QCheck2.Gen.int_range 1 24) QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:"device declarations survive restart and reject corruption" generator
    (fun (count, corrupt) ->
      let signers = List.init count (fun index -> signer (index + 1)) in
      let canonical =
        List.for_all
          (fun signer ->
            Result.bind
              (Device.identity_payload signer.identity)
              Device.decode_identity_payload
            |> Result.fold ~ok:(Device.identity_equal signer.identity)
                 ~error:(fun _ -> false))
          signers
      in
      let durable =
        with_repository (fun repository ->
            let object_ids =
              List.map
                (fun signer ->
                  Device_store.store_identity repository signer.identity
                  |> require)
                signers
            in
            let repeated =
              List.map2
                (fun signer object_id ->
                  Device_store.store_identity repository signer.identity
                  |> Result.fold ~ok:(Store.Stored_object_id.equal object_id)
                       ~error:(fun _ -> false))
                signers object_ids
            in
            let reopened =
              Store.open_repository ~root:(Store.root repository) |> require
            in
            let registry =
              Device_store.registry_of_objects reopened object_ids |> require
            in
            List.for_all Fun.id repeated
            && List.for_all (resolution_is_resolved registry) signers)
      in
      let corruption =
        (not corrupt)
        || Result.is_error (Device.decode_identity_payload Encoding.null)
      in
      canonical && durable && corruption)

let () =
  Alcotest.run "device properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "restart-corruption")
            restart_and_corruption;
        ] );
    ]
