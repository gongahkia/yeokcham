module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Capsule_store = Yeokcham_v2_capsule_store
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_model
module Retention = Yeokcham_v2_retention
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model

let default_seed = 20_260_810

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
let () = Printf.printf "v2 capsule-store property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository_id =
  V2_model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok V2_model.identity_error_to_string

let device_id =
  V2_model.Device_id.of_bytes (String.make 32 'd')
  |> require_ok V2_model.identity_error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let signing_key =
  Mirage_crypto_ec.Ed25519.priv_of_octets
    (String.init 32 (fun index -> Char.chr (index + 1)))
  |> require_ok (fun error ->
      Format.asprintf "%a" Mirage_crypto_ec.pp_error error)

let capability =
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> require_ok Bootstrap.error_to_string

let key_handle =
  Bootstrap.Key_handle.of_bytes (String.make 32 'h')
  |> require_ok V2_model.identity_error_to_string

let bootstrap =
  Bootstrap.make ~repository_id ~device_id ~key_handle ~capability
    ~mandatory_features:0L
  |> require_ok Bootstrap.error_to_string

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let file ?(mode = Model.Regular) components content =
  Model.File_path (path components, { Model.mode; content })

let directory components = Model.Directory_path (path components)

let snapshot entries =
  Model.Snapshot.of_entries entries
  |> require_ok Model.construction_error_to_string

let source_snapshot content = snapshot [ file [ "change" ] content ]

let target_snapshot content =
  snapshot
    [
      file ~mode:Model.Executable [ "change" ] content;
      directory [ "empty" ];
      directory [ "new" ];
      file [ "new"; "child" ] "exact child";
    ]

let nonce character =
  Envelope.nonce_of_bytes (String.make 12 character)
  |> require_ok Envelope.error_to_string

let nonces () =
  {
    Capsule_store.capsule_nonce = nonce 'a';
    selected_result_nonce = nonce 'b';
    revision_nonce = nonce 'c';
    source_protection_nonce = nonce 'd';
    source_protection_ledger_nonce = nonce 'e';
    target_protection_nonce = nonce 'f';
    target_protection_ledger_nonce = nonce 'g';
    binding_ledger_nonce = nonce 'h';
  }

let capsule_id =
  V2_model.Capsule_id.of_bytes (String.make 32 'c')
  |> require_ok V2_model.identity_error_to_string

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
  let root = Filename.temp_file "yeokcham-v2-capsule-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      ignore
        (Bootstrap_store.initialize ~root bootstrap
        |> require_ok Bootstrap_store.error_to_string);
      let bootstrap_repository =
        Bootstrap_store.open_repository ~root ~capability
        |> require_ok Bootstrap_store.error_to_string
      in
      let scratch =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      let capsules =
        Capsule_store.open_repository ~root ~bootstrap_repository
        |> require_ok Capsule_store.error_to_string
      in
      run scratch capsules)

let published_checkpoint = function
  | Scratch.Published checkpoint | Scratch.Unchanged checkpoint -> checkpoint

let publish scratch snapshot snapshot_nonce ledger_nonce =
  Scratch.publish scratch ~snapshot ~snapshot_nonce:(nonce snapshot_nonce)
    ~ledger_nonce:(nonce ledger_nonce)
  |> require_ok Scratch.error_to_string
  |> published_checkpoint

let full_selection source target =
  Capsule.propose ~from:source ~to_:target
  |> require_ok Capsule.proposal_error_to_string
  |> Capsule.proposal_operations
  |> List.mapi (fun index _ -> index)

let create scratch capsules ~source ~target ?fault () =
  let source_checkpoint = publish scratch source 'i' 'j' in
  let target_checkpoint = publish scratch target 'k' 'l' in
  Capsule_store.create ?fault capsules ~id:capsule_id ~title:"exact change"
    ~description:"selected byte transitions" ~created_at:17L
    ~source_event:source_checkpoint.Scratch.event_id
    ~target_event:target_checkpoint.Scratch.event_id
    ~selected_indices:(full_selection source target)
    ~nonces:(nonces ())

let durable_creation_pins_boundaries_across_compaction () =
  with_repository (fun scratch capsules ->
      let source = source_snapshot "before" in
      let target = target_snapshot "after" in
      let publication =
        create scratch capsules ~source ~target ()
        |> require_ok Capsule_store.error_to_string
      in
      let resolved =
        match publication with
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "first capsule creation was already published"
      in
      Alcotest.(check bool)
        "published revision replays target" true
        (Model.Snapshot.equal target resolved.Capsule_store.expected_result);
      let policy =
        Retention.make_policy ~recent_count:0 ~storage_budget_bytes:(Some 0L)
        |> require_ok Retention.error_to_string
      in
      let compaction =
        Scratch.plan_compaction scratch ~policy
          ~nonces:
            {
              Scratch.compact_ledger_nonces = [ nonce 'm'; nonce 'n' ];
              generation_manifest_nonce = nonce 'o';
              generation_ledger_nonce = nonce 'p';
            }
        |> require_ok Scratch.error_to_string
      in
      ignore
        (Scratch.publish_compaction_plan scratch compaction
        |> require_ok Scratch.error_to_string);
      let reopened =
        Capsule_store.resolve capsules ~id:capsule_id
        |> require_ok Capsule_store.error_to_string
        |> Option.get
      in
      let boundary =
        Capsule.revision_source_boundary reopened.Capsule_store.revision
      in
      Alcotest.(check bool)
        "retained source boundary remains exact after compaction" true
        (Yeokcham_id.Snapshot_id.equal
           boundary.Capsule.source_snapshot.Capsule.snapshot_id
           (Model.Snapshot.id source));
      Alcotest.(check bool)
        "reopened capsule still replays after compaction" true
        (Model.Snapshot.equal target reopened.Capsule_store.expected_result))

let interrupted_creation_stays_unbound_and_retries () =
  with_repository (fun scratch capsules ->
      let source = source_snapshot "before" in
      let target = target_snapshot "after" in
      ((match
          create scratch capsules ~source ~target
            ~fault:
              (Capsule_store.Fault.at Capsule_store.Fault.After_revision_object)
            ()
        with
      | Error
          (Capsule_store.Fault_injected
             Capsule_store.Fault.After_revision_object) ->
          ()
      | Error error ->
          Alcotest.fail
            ("wrong injected interruption: "
            ^ Capsule_store.error_to_string error)
      | Ok _ ->
          Alcotest.fail "injected pre-binding failure unexpectedly published")
      [@warning "-4"]);
      Alcotest.(check bool)
        "pre-binding interruption exposes no capsule" true
        (Option.is_none
           (Capsule_store.resolve capsules ~id:capsule_id
           |> require_ok Capsule_store.error_to_string));
      let publication =
        create scratch capsules ~source ~target ()
        |> require_ok Capsule_store.error_to_string
      in
      match publication with
      | Capsule_store.Published _ -> ()
      | Capsule_store.Already_published _ ->
          Alcotest.fail "retry should publish the previously unbound capsule")

let generated_create_and_reopen =
  QCheck2.Test.make ~count:48
    ~name:"V2 persisted exact capsules reopen with generated bytes"
    QCheck2.Gen.(
      pair (string_size (int_range 0 4096)) (string_size (int_range 0 4096)))
    (fun (before, after) ->
      with_repository (fun scratch capsules ->
          let source = source_snapshot before in
          let target = target_snapshot after in
          match create scratch capsules ~source ~target () with
          | Error _ -> false
          | Ok _ -> (
              match Capsule_store.resolve capsules ~id:capsule_id with
              | Ok (Some resolved) ->
                  Model.Snapshot.equal target
                    resolved.Capsule_store.expected_result
              | Ok None | Error _ -> false)))

let () =
  Alcotest.run "V2 durable exact capsule curation"
    [
      ( "unit",
        [
          Alcotest.test_case
            "durable creation pins source boundaries across compaction" `Quick
            durable_creation_pins_boundaries_across_compaction;
          Alcotest.test_case "interrupted creation remains unbound and retries"
            `Quick interrupted_creation_stays_unbound_and_retries;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "persisted-create-reopen")
            generated_create_and_reopen;
        ] );
    ]
