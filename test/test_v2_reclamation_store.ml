module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Reclamation = Yeokcham_v2_reclamation
module Reclamation_store = Yeokcham_v2_reclamation_store
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model

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

let snapshot content =
  Model.Snapshot.of_entries
    [
      Model.File_path
        (path [ "detached" ], { Model.mode = Model.Regular; content });
    ]
  |> require_ok Model.construction_error_to_string

let nonce byte =
  Envelope.nonce_of_bytes (String.make 12 byte)
  |> require_ok Envelope.error_to_string

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
  let root = Filename.temp_file "yeokcham-v2-reclamation-store-" "" in
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
      let objects =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      let reclamation =
        Reclamation_store.open_repository ~root ~bootstrap_repository
        |> require_ok Reclamation_store.error_to_string
      in
      run root bootstrap_repository objects reclamation)

let publish_unbound objects content =
  let envelope =
    Envelope.seal ~key:encryption_key ~nonce:(nonce 'n') ~mandatory_features:0L
      (Object.scratch_snapshot (snapshot content) |> Object.encode)
    |> require_ok Envelope.error_to_string
  in
  Object_store.publish objects ~envelope
  |> require_ok Object_store.error_to_string
  |> function
  | Object_store.Published object_ref
  | Object_store.Already_published object_ref ->
      object_ref

let candidate_contains plan object_ref =
  Reclamation.candidates plan
  |> List.exists (fun candidate ->
      V2_model.Opaque_object_ref.equal
        (Reclamation.candidate_object_ref candidate)
        object_ref)

let active_and_pinned_roots_are_never_candidates () =
  with_repository (fun root bootstrap_repository objects reclamation ->
      let detached = publish_unbound objects "eligible detached snapshot" in
      let scratch =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      let checkpoint =
        Scratch.publish scratch
          ~snapshot:(snapshot "active snapshot")
          ~snapshot_nonce:(nonce 'a') ~ledger_nonce:(nonce 'b')
        |> require_ok Scratch.error_to_string
        |> function
        | Scratch.Published checkpoint | Scratch.Unchanged checkpoint ->
            checkpoint
      in
      let protection =
        Scratch.plan_protection scratch ~event_id:checkpoint.Scratch.event_id
          ~action:Yeokcham_v2_retention.Protect
          ~reason:Yeokcham_v2_retention.User_pin ~protection_nonce:(nonce 'c')
          ~ledger_nonce:(nonce 'd')
        |> require_ok Scratch.error_to_string
      in
      ignore
        (Scratch.publish_protection_plan scratch protection
        |> require_ok Scratch.error_to_string);
      let unconstrained =
        Reclamation_store.plan reclamation ~cache_budget_bytes:Int64.max_int
        |> require_ok Reclamation_store.error_to_string
      in
      let detached_bytes =
        Object_store.stored_bytes objects ~object_ref:detached
        |> require_ok Object_store.error_to_string
      in
      let plan =
        Reclamation_store.plan reclamation
          ~cache_budget_bytes:
            (Int64.sub (Reclamation.total_bytes unconstrained) detached_bytes)
        |> require_ok Reclamation_store.error_to_string
      in
      Alcotest.(check bool)
        "detached object remains eligible" true
        (candidate_contains plan detached);
      Alcotest.(check bool)
        "active scratch snapshot is retained" false
        (candidate_contains plan checkpoint.Scratch.snapshot_ref);
      Alcotest.(check bool)
        "pin record is retained" false
        (candidate_contains plan protection.Scratch.protection_object_ref))

let manifest_quarantine_prune_and_retry () =
  with_repository (fun root _bootstrap_repository objects reclamation ->
      let object_ref = publish_unbound objects "unbound exact snapshot" in
      let plan =
        Reclamation_store.plan reclamation ~cache_budget_bytes:0L
        |> require_ok Reclamation_store.error_to_string
      in
      Alcotest.(check int)
        "unbound encrypted object is a candidate" 1
        (List.length (Reclamation.candidates plan));
      let plan_id = Reclamation.plan_id plan in
      let manifest =
        Reclamation_store.publish_manifest reclamation plan
        |> require_ok Reclamation_store.error_to_string
      in
      (match manifest with
      | Reclamation_store.Manifest_published -> ()
      | Reclamation_store.Manifest_already_published ->
          Alcotest.fail "first manifest publication was already present");
      let manifest_path =
        Reclamation_store.manifest_path reclamation ~plan_id
        |> require_ok Reclamation_store.error_to_string
      in
      Alcotest.(check bool)
        "manifest is durable" true
        (Sys.file_exists manifest_path);
      let interrupted =
        Reclamation_store.resume_quarantine reclamation ~plan_id
          ~fault:(Reclamation_store.Fault.after_candidate 0)
      in
      Alcotest.(check bool)
        "after-move fault is explicit" true
        (Result.is_error interrupted);
      Alcotest.(check bool)
        "candidate left live namespace" false
        (Sys.file_exists (Object_store.object_path objects object_ref));
      let resumed =
        Reclamation_store.resume_quarantine reclamation ~plan_id
        |> require_ok Reclamation_store.error_to_string
      in
      Alcotest.(check int)
        "retry identifies quarantined candidate" 1
        resumed.Reclamation_store.already_quarantined_objects;
      let pruned =
        Reclamation_store.prune_quarantine reclamation ~plan_id
        |> require_ok Reclamation_store.error_to_string
      in
      Alcotest.(check int)
        "explicit prune deletes quarantined candidate" 1
        pruned.Reclamation_store.pruned_objects;
      Alcotest.(check bool)
        "strict V2 root remains valid after reclamation" true
        (Yeokcham_cutover.detect ~root
        |> Result.fold
             ~ok:(fun classification ->
               String.equal
                 (Yeokcham_cutover.classification_to_string classification)
                 "v2")
             ~error:(fun _ -> false)))

let stale_manifest_rejects_new_root_state () =
  with_repository (fun root bootstrap_repository objects reclamation ->
      let _candidate = publish_unbound objects "first unbound snapshot" in
      let plan =
        Reclamation_store.plan reclamation ~cache_budget_bytes:0L
        |> require_ok Reclamation_store.error_to_string
      in
      let plan_id = Reclamation.plan_id plan in
      ignore
        (Reclamation_store.publish_manifest reclamation plan
        |> require_ok Reclamation_store.error_to_string);
      let scratch =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      ignore
        (Scratch.publish scratch
           ~snapshot:(snapshot "new active root")
           ~snapshot_nonce:(nonce 's') ~ledger_nonce:(nonce 't')
        |> require_ok Scratch.error_to_string);
      match Reclamation_store.resume_quarantine reclamation ~plan_id with
      | Ok _ ->
          Alcotest.fail "changed root state was accepted under old manifest"
      | Error error ->
          Alcotest.(check bool)
            "root digest change is explicit" true
            (String.starts_with ~prefix:"V2 reclamation root digest changed:"
               (Reclamation_store.error_to_string error)))

let () =
  Alcotest.run "V2 durable cache reclamation"
    [
      ( "unit",
        [
          Alcotest.test_case "manifest, quarantine, prune, and retry" `Quick
            manifest_quarantine_prune_and_retry;
          Alcotest.test_case "active and pinned roots are never candidates"
            `Quick active_and_pinned_roots_are_never_candidates;
          Alcotest.test_case "stale manifest rejects changed root state" `Quick
            stale_manifest_rejects_new_root_state;
        ] );
    ]
