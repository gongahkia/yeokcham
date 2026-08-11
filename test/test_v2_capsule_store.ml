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

let revision_nonces () =
  {
    Capsule_store.fold_selected_result_nonce = nonce 'q';
    fold_revision_nonce = nonce 'r';
    fold_source_protection_nonce = nonce 's';
    fold_source_protection_ledger_nonce = nonce 't';
    fold_target_protection_nonce = nonce 'u';
    fold_target_protection_ledger_nonce = nonce 'v';
    fold_binding_ledger_nonce = nonce 'w';
  }

let protection_nonces first second =
  {
    Capsule_store.protection_nonce = nonce first;
    protection_ledger_nonce = nonce second;
  }

let split_nonces () =
  {
    Capsule_store.split_left_capsule_nonce = nonce 'B';
    split_right_capsule_nonce = nonce 'C';
    split_left_result_nonce = nonce 'D';
    split_left_revision_nonce = nonce 'E';
    split_right_revision_nonce = nonce 'F';
    split_left_binding_nonce = nonce 'G';
    split_right_binding_nonce = nonce 'H';
    split_left_protections = [ protection_nonces 'I' 'J'; protection_nonces 'K' 'L' ];
    split_right_protections = [ protection_nonces 'M' 'N'; protection_nonces 'O' 'P' ];
  }

let combine_nonces () =
  {
    Capsule_store.combine_capsule_nonce = nonce 'Q';
    combine_revision_nonce = nonce 'R';
    combine_binding_nonce = nonce 'S';
    combine_protections = [ protection_nonces 'T' 'U'; protection_nonces 'V' 'W' ];
  }

let capsule_id =
  V2_model.Capsule_id.of_bytes (String.make 32 'c')
  |> require_ok V2_model.identity_error_to_string

let capsule_id_with character =
  V2_model.Capsule_id.of_bytes (String.make 32 character)
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
      run root scratch capsules)

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

let fold capsules ~current ~source_event ~target_event ~source ~target ?fault ()
    =
  Capsule_store.fold ?fault capsules ~id:capsule_id
    ~expected_revision:(Capsule.revision_id current.Capsule_store.revision)
    ~expected_binding:current.Capsule_store.binding_event_id ~source_event
    ~target_event
    ~selected_indices:(full_selection source target)
    ~created_at:18L ~nonces:(revision_nonces ())

let durable_creation_pins_boundaries_across_compaction () =
  with_repository (fun _root scratch capsules ->
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
  with_repository (fun _root scratch capsules ->
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

let split_and_combine_plans_do_not_publish () =
  with_repository (fun _root scratch capsules ->
      let source = source_snapshot "before" in
      let target = target_snapshot "after" in
      let current =
        create scratch capsules ~source ~target ()
        |> require_ok Capsule_store.error_to_string
        |> function
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "unexpected existing capsule"
      in
      ignore
        (Capsule_store.plan_split capsules ~source:capsule_id
           ~left_indices:[ 0 ]
        |> require_ok Capsule_store.error_to_string);
      ignore
        (Capsule_store.plan_combine capsules ~sources:[ capsule_id ]
        |> require_ok Capsule_store.error_to_string);
      let after =
        Capsule_store.resolve capsules ~id:capsule_id
        |> require_ok Capsule_store.error_to_string
        |> Option.get
      in
      Alcotest.(check bool)
        "read-only plans leave the signed current binding unchanged" true
        (V2_model.Opaque_object_ref.equal current.Capsule_store.revision_ref
           after.Capsule_store.revision_ref))

let confirmed_split_and_combine_publish_exact_provenance () =
  with_repository (fun root scratch capsules ->
      let source = source_snapshot "before" in
      let target = target_snapshot "after" in
      let source_current =
        create scratch capsules ~source ~target ()
        |> require_ok Capsule_store.error_to_string
        |> function
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "unexpected existing source capsule"
      in
      let left_id = capsule_id_with 'l' in
      let right_id = capsule_id_with 'r' in
      (match
         Capsule_store.split capsules ~source:capsule_id ~left_id
           ~left_title:"left" ~left_description:"left exact partition"
           ~right_id ~right_title:"right"
           ~right_description:"right exact partition" ~left_indices:[ 0 ]
           ~created_at:19L ~confirmed:false ~nonces:(split_nonces ())
       with
      | Error (Capsule_store.Confirmation_required "split") -> ()
      | Error error ->
          Alcotest.fail
            ("unconfirmed split returned the wrong error: "
            ^ Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "unconfirmed split published output")
      [@warning "-4"];
      let left, right =
        Capsule_store.split capsules ~source:capsule_id ~left_id
          ~left_title:"left" ~left_description:"left exact partition"
          ~right_id ~right_title:"right"
          ~right_description:"right exact partition" ~left_indices:[ 0 ]
          ~created_at:19L ~confirmed:true ~nonces:(split_nonces ())
        |> require_ok Capsule_store.error_to_string
      in
      let left =
        match left with
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "first split left output was already published"
      in
      let right =
        match right with
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "first split right output was already published"
      in
      let source_link =
        Capsule.make_revision_link ~capsule_id
          ~revision_id:(Capsule.revision_id source_current.Capsule_store.revision)
          ~revision_ref:source_current.Capsule_store.revision_ref
      in
      let has_source_provenance revision =
        match Capsule.revision_provenance revision with
        | Capsule.Split_from [ link ] ->
            V2_model.Capsule_id.equal
              (Capsule.revision_link_capsule_id link)
              (Capsule.revision_link_capsule_id source_link)
            && V2_model.Capsule_revision_id.equal
                 (Capsule.revision_link_revision_id link)
                 (Capsule.revision_link_revision_id source_link)
        | Capsule.Created | Capsule.Folded _ | Capsule.Split_from _
        | Capsule.Combined_from _ -> false
      in
      Alcotest.(check bool) "left records split source provenance" true
        (has_source_provenance left.Capsule_store.revision);
      Alcotest.(check bool) "right records split source provenance" true
        (has_source_provenance right.Capsule_store.revision);
      Capsule.apply_revision ~base:left.Capsule_store.declared_base
        left.Capsule_store.revision
      |> require_ok Model.replay_error_to_string
      |> fun actual ->
      Alcotest.(check bool) "left directly replays" true
        (Model.Snapshot.equal actual left.Capsule_store.expected_result);
      Capsule.apply_revision ~base:right.Capsule_store.declared_base
        right.Capsule_store.revision
      |> require_ok Model.replay_error_to_string
      |> fun actual ->
      Alcotest.(check bool) "right directly replays" true
        (Model.Snapshot.equal actual right.Capsule_store.expected_result);
      Alcotest.(check bool) "split composes to the original result" true
        (Model.Snapshot.equal target right.Capsule_store.expected_result);
      let combined_id = capsule_id_with 'm' in
      (match
         Capsule_store.combine capsules ~id:combined_id ~title:"combined"
           ~description:"caller ordered exact outputs" ~sources:[ left_id; right_id ]
           ~created_at:20L ~confirmed:false ~nonces:(combine_nonces ())
       with
      | Error (Capsule_store.Confirmation_required "combine") -> ()
      | Error error ->
          Alcotest.fail
            ("unconfirmed combine returned the wrong error: "
            ^ Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "unconfirmed combine published output")
      [@warning "-4"];
      let combined =
        Capsule_store.combine capsules ~id:combined_id ~title:"combined"
          ~description:"caller ordered exact outputs" ~sources:[ left_id; right_id ]
          ~created_at:20L ~confirmed:true ~nonces:(combine_nonces ())
        |> require_ok Capsule_store.error_to_string
        |> function
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "first combined output was already published"
      in
      Alcotest.(check bool) "combine records caller source order" true
        (match Capsule.revision_provenance combined.Capsule_store.revision with
        | Capsule.Combined_from [ first; second ] ->
            V2_model.Capsule_id.equal
              (Capsule.revision_link_capsule_id first) left_id
            && V2_model.Capsule_id.equal
                 (Capsule.revision_link_capsule_id second) right_id
        | Capsule.Created | Capsule.Folded _ | Capsule.Split_from _
        | Capsule.Combined_from _ -> false);
      Capsule.apply_revision ~base:combined.Capsule_store.declared_base
        combined.Capsule_store.revision
      |> require_ok Model.replay_error_to_string
      |> fun actual ->
      Alcotest.(check bool) "combined revision directly replays" true
        (Model.Snapshot.equal actual combined.Capsule_store.expected_result);
      Alcotest.(check bool) "combined result remains exact" true
        (Model.Snapshot.equal target combined.Capsule_store.expected_result);
      let reopened_bootstrap =
        Bootstrap_store.open_repository ~root ~capability
        |> require_ok Bootstrap_store.error_to_string
      in
      let reopened =
        Capsule_store.open_repository ~root ~bootstrap_repository:reopened_bootstrap
        |> require_ok Capsule_store.error_to_string
      in
      let reopened_combined =
        Capsule_store.resolve reopened ~id:combined_id
        |> require_ok Capsule_store.error_to_string
        |> Option.get
      in
      Alcotest.(check bool) "combined revision survives reopen" true
        (V2_model.Capsule_revision_id.equal
           (Capsule.revision_id combined.Capsule_store.revision)
           (Capsule.revision_id reopened_combined.Capsule_store.revision)))

let interrupted_confirmed_split_stays_unbound_and_retries () =
  with_repository (fun _root scratch capsules ->
      let source = source_snapshot "before" in
      let target = target_snapshot "after" in
      ignore
        (create scratch capsules ~source ~target ()
        |> require_ok Capsule_store.error_to_string);
      let left_id = capsule_id_with 'l' in
      let right_id = capsule_id_with 'r' in
      (match
         Capsule_store.split capsules ~source:capsule_id ~left_id
           ~left_title:"left" ~left_description:"left exact partition"
           ~right_id ~right_title:"right"
           ~right_description:"right exact partition" ~left_indices:[ 0 ]
           ~created_at:19L ~confirmed:true ~nonces:(split_nonces ())
           ~fault:(Capsule_store.Fault.at Capsule_store.Fault.After_revision_object)
       with
      | Error
          (Capsule_store.Fault_injected
             Capsule_store.Fault.After_revision_object) -> ()
      | Error error ->
          Alcotest.fail
            ("split interruption returned the wrong error: "
            ^ Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "interrupted split unexpectedly published output")
      [@warning "-4"];
      Alcotest.(check bool) "interrupted left output remains unbound" true
        (Option.is_none
           (Capsule_store.resolve capsules ~id:left_id
           |> require_ok Capsule_store.error_to_string));
      Alcotest.(check bool) "interrupted right output remains unbound" true
        (Option.is_none
           (Capsule_store.resolve capsules ~id:right_id
           |> require_ok Capsule_store.error_to_string));
      match
        Capsule_store.split capsules ~source:capsule_id ~left_id
          ~left_title:"left" ~left_description:"left exact partition"
          ~right_id ~right_title:"right"
          ~right_description:"right exact partition" ~left_indices:[ 0 ]
          ~created_at:19L ~confirmed:true ~nonces:(split_nonces ())
        |> require_ok Capsule_store.error_to_string
      with
      | Capsule_store.Published _, Capsule_store.Published _ -> ()
      | Capsule_store.Published _, Capsule_store.Already_published _
      | Capsule_store.Already_published _, Capsule_store.Published _
      | Capsule_store.Already_published _, Capsule_store.Already_published _ ->
          Alcotest.fail "split retry should bind both previously unreachable outputs")

let immutable_fold_reopens_and_stale_update_rejects () =
  with_repository (fun _root scratch capsules ->
      let source = source_snapshot "before" in
      let target = target_snapshot "after" in
      let initial =
        create scratch capsules ~source ~target ()
        |> require_ok Capsule_store.error_to_string
        |> function
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "unexpected existing capsule"
      in
      let source_checkpoint = publish scratch target 'x' 'y' in
      let later = target_snapshot "later" in
      let target_checkpoint = publish scratch later 'z' 'A' in
      let publication =
        fold capsules ~current:initial
          ~source_event:source_checkpoint.Scratch.event_id
          ~target_event:target_checkpoint.Scratch.event_id ~source:target
          ~target:later ()
        |> require_ok Capsule_store.error_to_string
      in
      let child =
        match publication with
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "first fold was already bound"
      in
      Alcotest.(check bool)
        "folded child directly replays its complete result" true
        (Model.Snapshot.equal later child.Capsule_store.expected_result);
      Alcotest.(check bool)
        "folded child preserves its parent link" true
        (match Capsule.revision_parent child.Capsule_store.revision with
        | Some parent ->
            V2_model.Capsule_revision_id.equal
              (Capsule.revision_link_revision_id parent)
              (Capsule.revision_id initial.Capsule_store.revision)
        | None -> false);
      let reopened =
        Capsule_store.resolve capsules ~id:capsule_id
        |> require_ok Capsule_store.error_to_string
        |> Option.get
      in
      Alcotest.(check bool)
        "folded revision survives durable resolution" true
        (V2_model.Capsule_revision_id.equal
           (Capsule.revision_id child.Capsule_store.revision)
           (Capsule.revision_id reopened.Capsule_store.revision));
      (match
         fold capsules ~current:initial
           ~source_event:source_checkpoint.Scratch.event_id
           ~target_event:target_checkpoint.Scratch.event_id ~source:target
           ~target:later ()
       with
      | Error (Capsule_store.Concurrent_current_update _) -> ()
      | Error error ->
          Alcotest.fail
            ("stale fold returned the wrong error: "
            ^ Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stale fold unexpectedly advanced the current ref")
      [@warning "-4"])

let interrupted_fold_stays_on_prior_revision_and_retries () =
  with_repository (fun _root scratch capsules ->
      let source = source_snapshot "before" in
      let target = target_snapshot "after" in
      let initial =
        create scratch capsules ~source ~target ()
        |> require_ok Capsule_store.error_to_string
        |> function
        | Capsule_store.Published resolved -> resolved
        | Capsule_store.Already_published _ ->
            Alcotest.fail "unexpected existing capsule"
      in
      let source_checkpoint = publish scratch target 'x' 'y' in
      let later = target_snapshot "later" in
      let target_checkpoint = publish scratch later 'z' 'A' in
      ((match
          fold capsules ~current:initial
            ~source_event:source_checkpoint.Scratch.event_id
            ~target_event:target_checkpoint.Scratch.event_id ~source:target
            ~target:later
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
            ("fold interruption returned the wrong error: "
            ^ Capsule_store.error_to_string error)
      | Ok _ ->
          Alcotest.fail "interrupted fold unexpectedly advanced the current ref")
      [@warning "-4"]);
      let prior =
        Capsule_store.resolve capsules ~id:capsule_id
        |> require_ok Capsule_store.error_to_string
        |> Option.get
      in
      Alcotest.(check bool)
        "interruption leaves old revision visible" true
        (V2_model.Capsule_revision_id.equal
           (Capsule.revision_id prior.Capsule_store.revision)
           (Capsule.revision_id initial.Capsule_store.revision));
      match
        fold capsules ~current:initial
          ~source_event:source_checkpoint.Scratch.event_id
          ~target_event:target_checkpoint.Scratch.event_id ~source:target
          ~target:later ()
        |> require_ok Capsule_store.error_to_string
      with
      | Capsule_store.Published _ -> ()
      | Capsule_store.Already_published _ ->
          Alcotest.fail
            "fold retry should bind the previously unreachable child")

let generated_create_and_reopen =
  QCheck2.Test.make ~count:48
    ~name:"V2 persisted exact capsules reopen with generated bytes"
    QCheck2.Gen.(
      pair (string_size (int_range 0 4096)) (string_size (int_range 0 4096)))
    (fun (before, after) ->
      with_repository (fun _root scratch capsules ->
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

let generated_confirmed_split_replays =
  QCheck2.Test.make ~count:48
    ~name:"V2 confirmed split directly replays generated byte results"
    QCheck2.Gen.
      (pair (string_size (int_range 0 4096)) (string_size (int_range 0 4096)))
    (fun (before, after) ->
      try
        with_repository (fun _root scratch capsules ->
            let source = source_snapshot before in
            let target = target_snapshot after in
            let _ = create scratch capsules ~source ~target () |> Result.get_ok in
            let left_id = capsule_id_with 'l' in
            let right_id = capsule_id_with 'r' in
            match
              Capsule_store.split capsules ~source:capsule_id ~left_id
                ~left_title:"left" ~left_description:"generated partition"
                ~right_id ~right_title:"right"
                ~right_description:"generated partition" ~left_indices:[ 0 ]
                ~created_at:19L ~confirmed:true ~nonces:(split_nonces ())
            with
            | Ok (left, right) ->
                let resolved = function
                  | Capsule_store.Published resolved
                  | Capsule_store.Already_published resolved ->
                      resolved
                in
                let left = resolved left in
                let right = resolved right in
                (match
                   Capsule.apply_revision ~base:left.Capsule_store.declared_base
                     left.Capsule_store.revision
                 with
                | Error _ -> false
                | Ok actual ->
                    Model.Snapshot.equal actual left.Capsule_store.expected_result
                    && Model.Snapshot.equal target
                         right.Capsule_store.expected_result)
            | Error _ -> false)
      with _ -> false)

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
          Alcotest.test_case "split and combine plans do not publish" `Quick
            split_and_combine_plans_do_not_publish;
          Alcotest.test_case
            "confirmed split and combine publish exact provenance" `Quick
            confirmed_split_and_combine_publish_exact_provenance;
          Alcotest.test_case
            "interrupted confirmed split stays unbound and retries" `Quick
            interrupted_confirmed_split_stays_unbound_and_retries;
          Alcotest.test_case "immutable fold reopens and stale update rejects"
            `Quick immutable_fold_reopens_and_stale_update_rejects;
          Alcotest.test_case
            "interrupted fold stays on prior revision and retries" `Quick
            interrupted_fold_stays_on_prior_revision_and_retries;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "persisted-create-reopen")
            generated_create_and_reopen;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "confirmed-split-replay")
            generated_confirmed_split_replays;
        ] );
    ]
