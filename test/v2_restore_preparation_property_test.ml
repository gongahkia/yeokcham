module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Model = Yeokcham_model
module Preparation = Yeokcham_v2_restore_preparation
module Scanner = Yeokcham_v2_scanner
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let state_for name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !value |]

let () =
  Printf.printf "V2 restore-preparation property base seed: %d\n%!" base_seed

let identity of_bytes character =
  of_bytes (String.make 32 character) |> Result.get_ok

let repository_id = identity V2_model.Repository_id.of_bytes 'r'
let device_id = identity V2_model.Device_id.of_bytes 'd'
let encryption_key = Envelope.key_of_bytes (String.make 32 'e') |> Result.get_ok
let address_key = Address.key_of_bytes (String.make 32 'a') |> Result.get_ok

let signing_key =
  Mirage_crypto_ec.Ed25519.priv_of_octets
    (String.init 32 (fun index -> Char.chr (index + 1)))
  |> Result.get_ok

let capability =
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> Result.get_ok

let key_handle = identity Bootstrap.Key_handle.of_bytes 'h'

let bootstrap =
  Bootstrap.make ~repository_id ~device_id ~key_handle ~capability
    ~mandatory_features:0L
  |> Result.get_ok

let nonce character =
  Envelope.nonce_of_bytes (String.make 12 character) |> Result.get_ok

let operation_id = identity V2_model.Transaction_id.of_bytes 'o'

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
  let root =
    Filename.temp_file "yeokcham-v2-restore-preparation-property-" ""
  in
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
                  | Ok scratch -> run root bootstrap_repository scratch))))

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let generated_changed_trees_checkpoint_before_pre_action_journal =
  QCheck2.Test.make ~count:60
    ~name:
      "V2 restore preparation checkpoints generated changed trees before \
       journaling"
    QCheck2.Gen.(int_range 1 4096)
    (fun size ->
      with_repository (fun root bootstrap_repository scratch ->
          let work = Filename.concat root "work" in
          let target = String.make size 't' in
          let observed = String.make size 'o' in
          write_file work target;
          match Scanner.scan ~root with
          | Error _ -> false
          | Ok target_snapshot -> (
              match
                Scratch.publish scratch ~snapshot:target_snapshot
                  ~snapshot_nonce:(nonce '1') ~ledger_nonce:(nonce '2')
              with
              | Error _ | Ok (Scratch.Unchanged _) -> false
              | Ok (Scratch.Published target_checkpoint) -> (
                  write_file work observed;
                  match
                    Preparation.prepare ~root ~bootstrap_repository
                      ~target_event_id:target_checkpoint.Scratch.event_id
                      ~operation_id ~safety_snapshot_nonce:(nonce '3')
                      ~safety_ledger_nonce:(nonce '4')
                  with
                  | Error _ | Ok (Preparation.Noop _) -> false
                  | Ok (Preparation.Prepared prepared) -> (
                      match Scanner.scan ~root with
                      | Error _ -> false
                      | Ok scanned ->
                          let safety = Preparation.safety_checkpoint prepared in
                          Model.Snapshot.equal scanned safety.Scratch.snapshot
                          && Journal.generation (Preparation.journal prepared)
                             = 1L
                          && Journal.phase (Preparation.journal prepared)
                             = Journal.Applying 0)))))

let () =
  Alcotest.run "V2 guarded restore preparation properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "changed-tree-safety")
            generated_changed_trees_checkpoint_before_pre_action_journal;
        ] );
    ]
