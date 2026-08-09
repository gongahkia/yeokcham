module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Snapshot_model = Yeokcham_model
module Store = Yeokcham_store
module Transaction_store = Yeokcham_v2_transaction_store
module Verification = Yeokcham_v2_verification

let default_seed = 20_260_729

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
let () = Printf.printf "v2 verification property base seed: %d\n%!" base_seed

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Ledger.Signer_key_id.t;
}

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let signer () =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr (index + 1)))
    |> require_ok (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let key_id =
    Ledger.signer_key_id_of_public_key public_key
    |> require_ok Ledger.error_to_string
  in
  { private_key; public_key; key_id }

let signer = signer ()

let repository_id =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let public_keys =
  Ledger.make_public_key_registry [ (signer.key_id, signer.public_key) ]
  |> require_ok Ledger.error_to_string

let main_ref = Ledger.Ref_name.of_string "main" |> require_ok Fun.id

let target character =
  Model.Opaque_object_ref.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string
  |> Ledger.Ref_target.of_opaque_object_ref

let transaction_id character =
  Model.Transaction_id.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let signed_event ?(repository = repository_id) ?(ref_name = main_ref)
    ?(predecessor = None) ?(target_value = Some (target 't'))
    ?(signature_mutation = false) () =
  let unsigned =
    Ledger.make_unsigned ~repository_id:repository ~ref_name
      ~signer_key_id:signer.key_id ~predecessor ~target:target_value
      ~mandatory_features:0L
    |> require_ok Ledger.error_to_string
  in
  let signature =
    Ledger.signing_bytes unsigned
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  let signature =
    if signature_mutation then (
      let bytes = Bytes.of_string signature in
      Bytes.set bytes 0 (Char.chr (Char.code (Bytes.get bytes 0) lxor 1));
      Bytes.unsafe_to_string bytes)
    else signature
  in
  Ledger.make ~unsigned ~algorithm:Ledger.algorithm ~signature
  |> require_ok Ledger.error_to_string

let envelope ?(nonce_offset = 0) event =
  let nonce =
    Envelope.nonce_of_bytes
      (String.init 12 (fun index -> Char.chr (index + nonce_offset + 32)))
    |> require_ok Envelope.error_to_string
  in
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
    (Object.ledger_event event |> Object.encode)
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

let with_v2_root run =
  let root = Filename.temp_file "yeokcham-v2-verification-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let ledger =
        Ledger_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key ~public_keys
        |> require_ok Ledger_store.error_to_string
      in
      let transactions =
        Transaction_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key ~public_keys
        |> require_ok Transaction_store.error_to_string
      in
      run root ledger transactions)

let verifier root =
  Verification.open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys
  |> require_ok Verification.error_to_string

let rec filesystem_image path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path |> Array.to_list |> List.sort String.compare
      |> List.map (fun name ->
          name ^ "=" ^ filesystem_image (Filename.concat path name))
      |> String.concat ";"
      |> fun contents -> "D[" ^ contents ^ "]"
  | Unix.S_REG ->
      In_channel.with_open_bin path In_channel.input_all |> fun bytes ->
      "F[" ^ bytes ^ "]"
  | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
      Alcotest.fail "test root contains an unsupported filesystem node"

let publish ledger candidate =
  Ledger_store.publish ledger ~envelope:candidate
  |> require_ok Ledger_store.error_to_string

let snapshot_path components =
  Snapshot_model.Path.of_components components
  |> require_ok Snapshot_model.Path.error_to_string

let exact_snapshot content =
  Snapshot_model.Snapshot.of_entries
    [
      Snapshot_model.File_path
        ( snapshot_path [ "file" ],
          { Snapshot_model.mode = Snapshot_model.Regular; content } );
    ]
  |> require_ok Snapshot_model.construction_error_to_string

let report_fields report =
  let {
    Verification.verified_objects;
    verified_events;
    verified_refs;
    causal_heads;
    unresolved_divergences;
    prepared_transactions;
    committed_transactions;
  } =
    report
  in
  ( verified_objects,
    verified_events,
    verified_refs,
    causal_heads,
    unresolved_divergences,
    prepared_transactions,
    committed_transactions )

let read_only_verification_reports_ledger_and_journal_state () =
  with_v2_root (fun root ledger transactions ->
      let root_event = signed_event ~target_value:(Some (target '0')) () in
      let root_id = Ledger.event_id root_event in
      let left =
        signed_event ~predecessor:(Some root_id)
          ~target_value:(Some (target '1'))
          ()
      in
      let right =
        signed_event ~predecessor:(Some root_id)
          ~target_value:(Some (target '2'))
          ()
      in
      List.iteri
        (fun index event ->
          ignore (publish ledger (envelope ~nonce_offset:index event)))
        [ root_event; left; right ];
      let prepared = envelope ~nonce_offset:8 root_event in
      let committed = envelope ~nonce_offset:9 root_event in
      ignore
        (Transaction_store.prepare transactions
           ~transaction_id:(transaction_id 'p') ~envelopes:[ prepared ]
        |> require_ok Transaction_store.error_to_string);
      ignore
        (Transaction_store.prepare transactions
           ~transaction_id:(transaction_id 'c') ~envelopes:[ committed ]
        |> require_ok Transaction_store.error_to_string);
      ignore
        (Transaction_store.commit transactions
           ~transaction_id:(transaction_id 'c')
        |> require_ok Transaction_store.error_to_string);
      let before = filesystem_image (Filename.concat root ".yeokcham") in
      let actual =
        Verification.verify (verifier root)
        |> require_ok Verification.error_to_string
      in
      let after = filesystem_image (Filename.concat root ".yeokcham") in
      Alcotest.(check string) "verification is read-only" before after;
      let ( verified_objects,
            verified_events,
            verified_refs,
            causal_heads,
            unresolved_divergences,
            prepared_transactions,
            committed_transactions ) =
        report_fields actual
      in
      Alcotest.(check int) "verified objects" 3 verified_objects;
      Alcotest.(check int) "verified events" 3 verified_events;
      Alcotest.(check int) "verified refs" 1 verified_refs;
      Alcotest.(check int) "causal heads" 2 causal_heads;
      Alcotest.(check int) "unresolved divergences" 1 unresolved_divergences;
      Alcotest.(check int) "prepared transactions" 1 prepared_transactions;
      Alcotest.(check int) "committed transactions" 1 committed_transactions)

let verification_accepts_typed_scratch_snapshots_without_treating_them_as_events
    () =
  with_v2_root (fun root _ _ ->
      let nonce =
        Envelope.nonce_of_bytes (String.make 12 's')
        |> require_ok Envelope.error_to_string
      in
      let envelope =
        Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
          (Object.scratch_snapshot (exact_snapshot "exact") |> Object.encode)
        |> require_ok Envelope.error_to_string
      in
      let objects =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      ignore
        (Object_store.publish objects ~envelope
        |> require_ok Object_store.error_to_string);
      let report =
        Verification.verify (verifier root)
        |> require_ok Verification.error_to_string
      in
      let ( verified_objects,
            verified_events,
            verified_refs,
            causal_heads,
            unresolved_divergences,
            prepared_transactions,
            committed_transactions ) =
        report_fields report
      in
      Alcotest.(check int)
        "typed snapshot counts as verified object" 1 verified_objects;
      Alcotest.(check int)
        "typed snapshot is not a ledger event" 0 verified_events;
      Alcotest.(check int)
        "typed snapshot creates no ledger ref" 0 verified_refs;
      Alcotest.(check int)
        "typed snapshot creates no causal head" 0 causal_heads;
      Alcotest.(check int)
        "typed snapshot creates no divergence" 0 unresolved_divergences;
      Alcotest.(check int)
        "typed snapshot creates no prepare" 0 prepared_transactions;
      Alcotest.(check int)
        "typed snapshot creates no commit" 0 committed_transactions)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let make_object_path ledger candidate =
  let object_ref =
    Address.derive ~repository_id ~key:address_key ~envelope:candidate
  in
  let path = Ledger_store.object_path ledger object_ref in
  let first = Filename.dirname (Filename.dirname path) in
  let second = Filename.dirname path in
  Unix.mkdir first 0o700;
  Unix.mkdir second 0o700;
  write_file path (Envelope.encode candidate);
  (object_ref, path)

let invalid_object_and_causal_contexts_are_typed () =
  with_v2_root (fun root ledger _ ->
      let invalid = envelope (signed_event ~signature_mutation:true ()) in
      let invalid_ref, invalid_path = make_object_path ledger invalid in
      (match Verification.verify (verifier root) with
      | Error (Verification.Object_error { object_ref; path; _ }) ->
          Alcotest.(check bool)
            "invalid object ID context" true
            (Model.Opaque_object_ref.equal invalid_ref object_ref);
          Alcotest.(check string)
            "invalid object path context" invalid_path path
      | Error error ->
          Alcotest.failf "invalid object returned the wrong error: %s"
            (Verification.error_to_string error)
      | Ok _ -> Alcotest.fail "invalid signature unexpectedly verified");
      Unix.unlink invalid_path;
      Unix.rmdir (Filename.dirname invalid_path);
      Unix.rmdir (Filename.dirname (Filename.dirname invalid_path));
      let missing =
        Model.Ref_event_id.of_bytes (String.make 32 'm')
        |> require_ok Model.identity_error_to_string
      in
      ignore
        (publish ledger
           (envelope ~nonce_offset:15
              (signed_event ~predecessor:(Some missing) ())));
      match Verification.verify (verifier root) with
      | Error
          (Verification.Causal_error
             { ref_name; error = Ledger.Missing_predecessor _ }) ->
          Alcotest.(check string)
            "causal ref context" "main"
            (Ledger.Ref_name.to_string ref_name)
      | Error error ->
          Alcotest.failf "missing predecessor returned the wrong error: %s"
            (Verification.error_to_string error)
      | Ok _ -> Alcotest.fail "missing predecessor unexpectedly verified")
  [@warning "-4"]

let generated_chain_lengths = QCheck2.Gen.int_range 1 16

let generated_verified_chains_leave_state_unchanged =
  QCheck2.Test.make ~count:75
    ~name:"generated valid V2 causal chains verify without mutation"
    generated_chain_lengths (fun length ->
      with_v2_root (fun root ledger _ ->
          let rec build previous index result =
            if Int.equal index length then List.rev result
            else
              let event =
                signed_event ~predecessor:previous
                  ~target_value:(Some (target (Char.chr (index + 48))))
                  ()
              in
              build (Some (Ledger.event_id event)) (index + 1) (event :: result)
          in
          build None 0 []
          |> List.iteri (fun index event ->
              ignore (publish ledger (envelope ~nonce_offset:index event)));
          let before = filesystem_image (Filename.concat root ".yeokcham") in
          match Verification.verify (verifier root) with
          | Error _ -> false
          | Ok report ->
              let after = filesystem_image (Filename.concat root ".yeokcham") in
              let ( verified_objects,
                    verified_events,
                    verified_refs,
                    causal_heads,
                    unresolved_divergences,
                    prepared_transactions,
                    committed_transactions ) =
                report_fields report
              in
              String.equal before after
              && Int.equal verified_objects length
              && Int.equal verified_events length
              && Int.equal verified_refs 1 && Int.equal causal_heads 1
              && Int.equal unresolved_divergences 0
              && Int.equal prepared_transactions 0
              && Int.equal committed_transactions 0))

let () =
  Alcotest.run "V2 repository verification"
    [
      ( "unit",
        [
          Alcotest.test_case "read-only report covers ledger and journal state"
            `Quick read_only_verification_reports_ledger_and_journal_state;
          Alcotest.test_case "typed snapshots are not ledger events" `Quick
            verification_accepts_typed_scratch_snapshots_without_treating_them_as_events;
          Alcotest.test_case "invalid objects and causal context are typed"
            `Quick invalid_object_and_causal_contexts_are_typed;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-chains")
            generated_verified_chains_leave_state_unchanged;
        ] );
    ]
