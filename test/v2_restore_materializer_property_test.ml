module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Materializer = Yeokcham_v2_restore_materializer
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
  Printf.printf "V2 restore-materializer property base seed: %d\n%!" base_seed

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
    Filename.temp_file "yeokcham-v2-restore-materializer-property-" ""
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

let generated_exact_materialisation_reaches_the_authenticated_target =
  QCheck2.Test.make ~count:60
    ~name:"V2 restore materialiser reaches generated exact targets"
    QCheck2.Gen.(
      map
        (fun ((target, observed), executable) -> (target, observed, executable))
        (pair (pair string string) bool))
    (fun (target_bytes, observed_bytes, executable) ->
      if String.equal target_bytes observed_bytes then true
      else
        with_repository (fun root bootstrap_repository scratch ->
            let work = Filename.concat root "work" in
            write_file work target_bytes;
            if executable then Unix.chmod work 0o755;
            match Scanner.scan ~root with
            | Error _ -> false
            | Ok target_snapshot -> (
                match
                  Scratch.publish scratch ~snapshot:target_snapshot
                    ~snapshot_nonce:(nonce '1') ~ledger_nonce:(nonce '2')
                with
                | Error _ | Ok (Scratch.Unchanged _) -> false
                | Ok (Scratch.Published target_checkpoint) -> (
                    write_file work observed_bytes;
                    Unix.chmod work 0o644;
                    match
                      Preparation.prepare ~root ~bootstrap_repository
                        ~target_event_id:target_checkpoint.Scratch.event_id
                        ~operation_id ~safety_snapshot_nonce:(nonce '3')
                        ~safety_ledger_nonce:(nonce '4')
                    with
                    | Error _ | Ok (Preparation.Noop _) -> false
                    | Ok (Preparation.Prepared prepared) -> (
                        let journal_store =
                          Yeokcham_v2_restore_journal_store.open_repository
                            ~root ~repository_id
                        in
                        match journal_store with
                        | Error _ -> false
                        | Ok journal_store -> (
                            match
                              Materializer.materialize ~root ~journal_store
                                ~plan:(Preparation.plan prepared)
                                ~journal:(Preparation.journal prepared)
                                ()
                            with
                            | Error _ -> false
                            | Ok _ -> (
                                match Scanner.scan ~root with
                                | Error _ -> false
                                | Ok actual ->
                                    Model.Snapshot.equal actual
                                      target_checkpoint.Scratch.snapshot)))))))

let generated_post_write_interruptions_reconcile_one_exact_prefix =
  QCheck2.Test.make ~count:60
    ~name:
      "V2 restore materialiser reconciles generated post-write interruptions"
    QCheck2.Gen.(pair string string)
    (fun (target_bytes, observed_bytes) ->
      if String.equal target_bytes observed_bytes then true
      else
        with_repository (fun root bootstrap_repository scratch ->
            let work = Filename.concat root "work" in
            write_file work target_bytes;
            match Scanner.scan ~root with
            | Error _ -> false
            | Ok target_snapshot -> (
                match
                  Scratch.publish scratch ~snapshot:target_snapshot
                    ~snapshot_nonce:(nonce '1') ~ledger_nonce:(nonce '2')
                with
                | Error _ | Ok (Scratch.Unchanged _) -> false
                | Ok (Scratch.Published target_checkpoint) -> (
                    write_file work observed_bytes;
                    match
                      Preparation.prepare ~root ~bootstrap_repository
                        ~target_event_id:target_checkpoint.Scratch.event_id
                        ~operation_id ~safety_snapshot_nonce:(nonce '3')
                        ~safety_ledger_nonce:(nonce '4')
                    with
                    | Error _ | Ok (Preparation.Noop _) -> false
                    | Ok (Preparation.Prepared prepared) -> (
                        match
                          Yeokcham_v2_restore_journal_store.open_repository
                            ~root ~repository_id
                        with
                        | Error _ -> false
                        | Ok journal_store -> (
                            match
                              Materializer.materialize
                                ~fault:
                                  (Materializer.Fault.interrupt_after_action 1)
                                ~root ~journal_store
                                ~plan:(Preparation.plan prepared)
                                ~journal:(Preparation.journal prepared)
                                ()
                            with
                            | Error
                                (Materializer.Injected_interruption
                                   { completed_actions = 1 }) -> (
                                match
                                  Materializer.materialize ~root ~journal_store
                                    ~plan:(Preparation.plan prepared)
                                    ~journal:(Preparation.journal prepared)
                                    ()
                                with
                                | Error _ -> false
                                | Ok _ -> (
                                    match Scanner.scan ~root with
                                    | Error _ -> false
                                    | Ok actual ->
                                        Model.Snapshot.equal actual
                                          target_checkpoint.Scratch.snapshot))
                            | Error _ | Ok _ -> false)))))) [@warning "-4"]

let () =
  Alcotest.run "V2 restore materializer properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "exact-materialisation")
            generated_exact_materialisation_reaches_the_authenticated_target;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "interruption-reconciliation")
            generated_post_write_interruptions_reconcile_one_exact_prefix;
        ] );
    ]
