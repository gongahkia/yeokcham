module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Retention = Yeokcham_v2_retention
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

let get = function Ok value -> value | Error _ -> raise Exit

let published_ref = function
  | Object_store.Published object_ref
  | Object_store.Already_published object_ref ->
      object_ref

let publish_frame root ~frame ~nonce_value =
  let envelope =
    Envelope.seal ~key:encryption_key ~nonce:nonce_value ~mandatory_features:0L
      (Object.encode frame)
    |> get
  in
  let objects =
    Object_store.open_repository ~root ~repository_id ~address_key
      ~encryption_key
    |> get
  in
  Object_store.publish objects ~envelope |> get |> published_ref

let publish_ledger_event root ~ref_name ~predecessor ~target ~nonce_value =
  let unsigned =
    Ledger.make_unsigned ~repository_id ~ref_name
      ~signer_key_id:(Bootstrap.capability_signer_key_id capability)
      ~predecessor
      ~target:(Some (Ledger.Ref_target.of_opaque_object_ref target))
      ~mandatory_features:0L
    |> get
  in
  let event =
    Ledger.make ~unsigned ~algorithm:Ledger.algorithm
      ~signature:(Bootstrap.sign_ledger capability unsigned)
    |> get
  in
  let envelope =
    Envelope.seal ~key:encryption_key ~nonce:nonce_value ~mandatory_features:0L
      (Object.ledger_event event |> Object.encode)
    |> get
  in
  let public_keys = Bootstrap.public_key_registry capability |> get in
  let ledger =
    Ledger_store.open_repository ~root ~repository_id ~address_key
      ~encryption_key ~public_keys
    |> get
  in
  ignore (Ledger_store.publish ledger ~envelope |> get);
  Ledger.event_id event

let activate_final_checkpoint root scratch source =
  let source_ref = Scratch.scratch_ref_name scratch in
  let active_ref =
    Scratch.compact_ref_name scratch ~source_head:source.Scratch.event_id |> get
  in
  let active_anchor =
    publish_ledger_event root ~ref_name:active_ref ~predecessor:None
      ~target:source.Scratch.snapshot_ref ~nonce_value:(nonce 230)
  in
  let generation =
    Retention.make_generation ~source_ref ~source_head:source.Scratch.event_id
      ~active_ref ~active_anchor ~retired_refs:[ source_ref ]
      ~cleanup_candidates:[]
    |> get
  in
  let manifest_ref =
    publish_frame root
      ~frame:(Object.scratch_generation generation)
      ~nonce_value:(nonce 231)
  in
  ignore
    (publish_ledger_event root
       ~ref_name:(Scratch.generation_ref_name scratch)
       ~predecessor:None ~target:manifest_ref ~nonce_value:(nonce 232));
  active_anchor

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

let generation_activation_reopens_generated_final_snapshot =
  QCheck2.Test.make ~count:50
    ~name:
      "V2 generation activation reopens generated exact final scratch snapshots"
    QCheck2.Gen.(list_size (int_range 1 12) (string_size (int_range 0 2048)))
    (fun contents ->
      try
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
              match Scratch.inspect scratch with
              | Ok (Scratch.Checkpoint source) -> (
                  let active_anchor =
                    activate_final_checkpoint root scratch source
                  in
                  match Scratch.open_repository ~root ~bootstrap_repository with
                  | Ok reopened -> (
                      match Scratch.inspect reopened with
                      | Ok (Scratch.Checkpoint checkpoint) ->
                          Ledger.Event_id.equal active_anchor
                            checkpoint.Scratch.event_id
                          && Model.Snapshot.equal source.Scratch.snapshot
                               checkpoint.Scratch.snapshot
                      | Ok
                          ( Scratch.No_checkpoint
                          | Scratch.Divergent_checkpoints _ )
                      | Error _ ->
                          false)
                  | Error _ -> false)
              | Ok (Scratch.No_checkpoint | Scratch.Divergent_checkpoints _)
              | Error _ ->
                  false)
      with Exit -> false)

let () =
  Alcotest.run "V2 local scratch publication properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "snapshot-sequences")
            snapshot_sequences_reopen_exactly;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generation-activation")
            generation_activation_reopens_generated_final_snapshot;
        ] );
    ]
