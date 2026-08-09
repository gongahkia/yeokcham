module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_model
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model

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
let () = Printf.printf "v2 scratch-store property base seed: %d\n%!" base_seed

let repository_id =
  V2_model.Repository_id.of_bytes (String.make 32 'r') |> Result.get_ok

let device_id =
  V2_model.Device_id.of_bytes (String.make 32 'd') |> Result.get_ok

let encryption_key = Envelope.key_of_bytes (String.make 32 'e') |> Result.get_ok
let address_key = Address.key_of_bytes (String.make 32 'a') |> Result.get_ok

let signing_key =
  Mirage_crypto_ec.Ed25519.priv_of_octets
    (String.init 32 (fun index -> Char.chr (index + 1)))
  |> Result.get_ok

let capability =
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> Result.get_ok

let key_handle =
  Bootstrap.Key_handle.of_bytes (String.make 32 'h') |> Result.get_ok

let bootstrap =
  Bootstrap.make ~repository_id ~device_id ~key_handle ~capability
    ~mandatory_features:0L
  |> Result.get_ok

let path = Model.Path.of_components [ "file" ] |> Result.get_ok

let snapshot content =
  Model.Snapshot.of_entries
    [ Model.File_path (path, { Model.mode = Model.Regular; content }) ]
  |> Result.get_ok

let nonce index =
  Envelope.nonce_of_bytes
    (String.init 12 (fun offset -> Char.chr ((index + offset) land 0xff)))
  |> Result.get_ok

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

let with_repository check =
  let root = Filename.temp_file "yeokcham-v2-scratch-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      match Store.init ~root with
      | Error _ -> false
      | Ok _ -> (
          match Bootstrap_store.initialize ~root bootstrap with
          | Error _ -> false
          | Ok _ -> (
              match Bootstrap_store.open_repository ~root ~capability with
              | Error _ -> false
              | Ok bootstrap_repository -> (
                  match Scratch.open_repository ~root ~bootstrap_repository with
                  | Error _ -> false
                  | Ok scratch -> check root bootstrap_repository scratch))))

let snapshot_sequences_reopen_exactly =
  QCheck2.Test.make ~count:80
    ~name:"V2 scratch snapshot sequences reopen to their exact final bytes"
    QCheck2.Gen.(list_size (int_range 1 12) (string_size (int_range 0 2048)))
    (fun contents ->
      with_repository (fun root bootstrap_repository scratch ->
          let published =
            List.mapi
              (fun index content ->
                Scratch.publish scratch ~snapshot:(snapshot content)
                  ~snapshot_nonce:(nonce ((index * 2) + 1))
                  ~ledger_nonce:(nonce ((index * 2) + 2)))
              contents
          in
          if List.exists Result.is_error published then false
          else
            match
              ( Scratch.open_repository ~root ~bootstrap_repository,
                List.rev contents )
            with
            | Ok reopened, expected :: _ -> (
                match Scratch.inspect reopened with
                | Ok (Scratch.Checkpoint checkpoint) ->
                    Model.Snapshot.equal (snapshot expected)
                      checkpoint.Scratch.snapshot
                | Ok (Scratch.No_checkpoint | Scratch.Divergent_checkpoints _)
                | Error _ ->
                    false)
            | Ok _, [] | Error _, _ -> false))

let () =
  Alcotest.run "V2 local scratch publication properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "snapshot-sequences")
            snapshot_sequences_reopen_exactly;
        ] );
    ]
