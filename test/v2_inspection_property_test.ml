module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Inspection = Yeokcham_v2_inspection
module Model = Yeokcham_model
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

let () = Printf.printf "V2 inspection property base seed: %d\n%!" base_seed

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
  let root = Filename.temp_file "yeokcham-v2-inspection-property-" "" in
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

let snapshot content =
  let path = Model.Path.of_components [ "work" ] |> Result.get_ok in
  Model.Snapshot.of_entries
    [ Model.File_path (path, { Model.mode = Model.Regular; content }) ]
  |> Result.get_ok

let inspection_rederives_every_generated_checkpoint =
  QCheck2.Test.make ~count:80
    ~name:
      "V2 inspection re-derives generated scratch checkpoints without an index"
    QCheck2.Gen.(string_size (int_range 0 4096))
    (fun content ->
      with_repository (fun root bootstrap_repository scratch ->
          match
            Scratch.publish scratch ~snapshot:(snapshot content)
              ~snapshot_nonce:(nonce '1') ~ledger_nonce:(nonce '2')
          with
          | Error _ | Ok (Scratch.Unchanged _) -> false
          | Ok (Scratch.Published expected) -> (
              match
                ( Inspection.status ~root ~bootstrap_repository,
                  Inspection.storage ~root ~bootstrap_repository,
                  Inspection.verify ~root ~bootstrap_repository )
              with
              | Ok status, Ok storage, Ok report -> (
                  match status.Inspection.scratch with
                  | Inspection.Checkpoint actual ->
                      V2_model.Opaque_object_ref.equal
                        actual.Inspection.snapshot_ref
                        expected.Scratch.snapshot_ref
                      && Yeokcham_id.Snapshot_id.equal
                           actual.Inspection.snapshot_id
                           (Model.Snapshot.id expected.Scratch.snapshot)
                      && actual.Inspection.entry_count = 1
                      && storage.Inspection.encrypted_objects = 2
                      && storage.Inspection.ledger_frames = 1
                      && storage.Inspection.scratch_snapshot_frames = 1
                      && report.Inspection.Verification.verified_objects = 2
                      && report.Inspection.Verification.verified_events = 1
                  | Inspection.No_checkpoint | Inspection.Divergent _ -> false)
              | Error _, _, _ | _, Error _, _ | _, _, Error _ -> false)))

let () =
  Alcotest.run "V2 read-only inspection properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "rederive-checkpoint")
            inspection_rederives_every_generated_checkpoint;
        ] );
    ]
