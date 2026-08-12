module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Custody = Yeokcham_v2_keychain_custody
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Store = Yeokcham_store

let default_seed = 20_260_813

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let state_for name =
  let seed = ref base_seed in
  String.iter
    (fun character ->
      seed := !seed * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !seed |]

let require = function Ok value -> value | Error _ -> assert false

let capability =
  let encryption = String.make 32 'e' |> Envelope.key_of_bytes |> require in
  let address = String.make 32 'a' |> Address.key_of_bytes |> require in
  let signing =
    String.make 32 's' |> Mirage_crypto_ec.Ed25519.priv_of_octets |> require
  in
  Bootstrap.make_capability ~encryption_key:encryption ~address_key:address
    ~signing_key:signing
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

let with_root run =
  let root = Filename.temp_file "yeokcham-v2-keychain-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let service stored =
  Custody.service
    ~backend:
      {
        Custody.lookup =
          (fun _ ->
            match !stored with
            | None -> Custody.Missing
            | Some value -> Custody.Found value);
        Custody.store =
          (fun _ value ->
            match !stored with
            | None ->
                stored := Some value;
                Custody.Stored
            | Some _ -> Custody.Already_present);
        Custody.remove =
          (fun _ ->
            match !stored with
            | None -> Custody.Remove_missing
            | Some _ ->
                stored := None;
                Custody.Removed);
      }

let raw_identity = QCheck2.Gen.string_size (QCheck2.Gen.return 32)

let enrollment_reopens =
  QCheck2.Test.make ~count:120
    ~name:
      "generated bootstrap IDs and Keychain handles reopen one matching \
       capability" (QCheck2.Gen.triple raw_identity raw_identity raw_identity)
    (fun (repository_bytes, device_bytes, handle_bytes) ->
      match
        ( Model.Repository_id.of_bytes repository_bytes,
          Model.Device_id.of_bytes device_bytes,
          Custody.key_handle_of_bytes handle_bytes )
      with
      | Ok repository_id, Ok device_id, Ok key_handle ->
          with_root (fun root ->
              match Store.init ~root with
              | Error _ -> false
              | Ok _ -> (
                  let stored = ref None in
                  let first_service = service stored in
                  match
                    Custody.enroll ~service:first_service ~root ~repository_id
                      ~device_id ~key_handle ~capability
                  with
                  | Error _ -> false
                  | Ok _ ->
                      Result.is_ok
                        (Custody.open_repository ~service:(service stored) ~root)
                  ))
      | Error _, _, _ | _, Error _, _ | _, _, Error _ -> false)

let () =
  Alcotest.run "V2 macOS Keychain custody core properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "keychain-custody-enrollment")
            enrollment_reopens;
        ] );
    ]
