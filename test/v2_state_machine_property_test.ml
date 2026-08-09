module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Store = Yeokcham_store
module Transaction_store = Yeokcham_v2_transaction_store
module Verification = Yeokcham_v2_verification

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
let () = Printf.printf "v2 state-machine property base seed: %d\n%!" base_seed

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Ledger.Signer_key_id.t;
}

let result_or_false = function Ok value -> Some value | Error _ -> None

let signer () =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr (index + 1)))
    |> result_or_false
  in
  match private_key with
  | None -> failwith "fixed V2 state-machine private key is invalid"
  | Some private_key -> (
      let public_key =
        Mirage_crypto_ec.Ed25519.pub_of_priv private_key
        |> Mirage_crypto_ec.Ed25519.pub_to_octets
      in
      let key_id =
        Ledger.signer_key_id_of_public_key public_key |> result_or_false
      in
      match key_id with
      | Some key_id -> { private_key; public_key; key_id }
      | None -> failwith "fixed V2 state-machine public key is invalid")

let signer = signer ()

let repository_id =
  Model.Repository_id.of_bytes (String.make 32 'r') |> Result.get_ok

let address_key = Address.key_of_bytes (String.make 32 'a') |> Result.get_ok
let encryption_key = Envelope.key_of_bytes (String.make 32 'e') |> Result.get_ok

let public_keys =
  Ledger.make_public_key_registry [ (signer.key_id, signer.public_key) ]
  |> Result.get_ok

let main_ref = Ledger.Ref_name.of_string "main" |> Result.get_ok

let target value =
  Model.Opaque_object_ref.of_bytes (String.make 32 value)
  |> Result.get_ok |> Ledger.Ref_target.of_opaque_object_ref

let transaction_id value =
  Model.Transaction_id.of_bytes (String.make 32 value) |> Result.get_ok

let event ?(predecessor = None) target_value =
  let unsigned =
    Ledger.make_unsigned ~repository_id ~ref_name:main_ref
      ~signer_key_id:signer.key_id ~predecessor ~target:(Some target_value)
      ~mandatory_features:0L
    |> Result.get_ok
  in
  let signature =
    Ledger.signing_bytes unsigned
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Ledger.make ~unsigned ~algorithm:Ledger.algorithm ~signature |> Result.get_ok

let envelope ~nonce_offset value =
  let nonce =
    Envelope.nonce_of_bytes
      (String.init 12 (fun index -> Char.chr (index + nonce_offset + 32)))
    |> Result.get_ok
  in
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
    (Object.ledger_event value |> Object.encode)
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

let with_root check =
  let root = Filename.temp_file "yeokcham-v2-state-machine-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      match Store.init ~root with Error _ -> false | Ok _ -> check root)

let open_ledger root =
  Ledger_store.open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys

let open_transactions root =
  Transaction_store.open_repository ~root ~repository_id ~address_key
    ~encryption_key ~public_keys

let open_verifier root =
  Verification.open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys

let fork_result action =
  match Unix.fork () with
  | 0 -> (
      try if action () then Unix._exit 0 else Unix._exit 1
      with _ -> Unix._exit 2)
  | child -> child

let wait_success child =
  match Unix.waitpid [] child with
  | _, Unix.WEXITED 0 -> true
  | _, (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) -> false

let wait_all children = List.map wait_success children |> List.for_all Fun.id

let failed stage =
  Printf.eprintf "v2 state-machine failure: %s\n%!" stage;
  false

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
      "unsupported"

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

let scenarios = QCheck2.Gen.(pair (int_range 2 4) (int_range 0 24))

let concurrent_interruption_and_reopen_state_machine =
  QCheck2.Test.make ~count:40
    ~print:(fun (forks, offset) ->
      Printf.sprintf "forks=%d offset=%d" forks offset)
    ~name:
      "multi-process prepare/fork/interruption/reopen preserves immutable V2 \
       state"
    scenarios
    (fun (forks, offset) ->
      with_root (fun root ->
          let root_event = event (target '0') in
          let root_id = Ledger.event_id root_event in
          let ledger = open_ledger root |> result_or_false in
          match ledger with
          | None -> failed "open initial ledger"
          | Some ledger -> (
              let root_envelope = envelope ~nonce_offset:offset root_event in
              let root_published =
                Ledger_store.publish ledger ~envelope:root_envelope
                |> Result.is_ok
              in
              if not root_published then failed "publish root"
              else
                let fork_events =
                  List.init forks (fun index ->
                      event ~predecessor:(Some root_id)
                        (target (Char.chr (Char.code 'A' + index))))
                in
                let fork_children =
                  List.mapi
                    (fun index candidate ->
                      let candidate =
                        envelope ~nonce_offset:(offset + index + 1) candidate
                      in
                      fork_result (fun () ->
                          match open_ledger root with
                          | Error error ->
                              prerr_endline
                                ("V2 concurrent ledger open: "
                                ^ Ledger_store.error_to_string error);
                              false
                          | Ok child_ledger -> (
                              match
                                Ledger_store.publish child_ledger
                                  ~envelope:candidate
                              with
                              | Ok _ -> true
                              | Error error ->
                                  prerr_endline
                                    ("V2 concurrent ledger publish: "
                                    ^ Ledger_store.error_to_string error);
                                  false)))
                    fork_events
                in
                let prepared_event =
                  event ~predecessor:(Some root_id) (target 'p')
                in
                let prepared_envelope =
                  envelope ~nonce_offset:(offset + 10) prepared_event
                in
                let prepared_id = transaction_id 'p' in
                let prepared_children =
                  List.init 2 (fun _ ->
                      fork_result (fun () ->
                          match open_transactions root with
                          | Error _ -> false
                          | Ok transactions -> (
                              match
                                Transaction_store.prepare transactions
                                  ~transaction_id:prepared_id
                                  ~envelopes:[ prepared_envelope ]
                              with
                              | Ok _ -> true
                              | Error error ->
                                  prerr_endline
                                    ("V2 concurrent prepare: "
                                    ^ Transaction_store.error_to_string error);
                                  false)))
                in
                if not (wait_all fork_children) then
                  failed "concurrent fork child"
                else if not (wait_all prepared_children) then
                  failed "concurrent prepare child"
                else
                  let committed_event =
                    event ~predecessor:(Some root_id) (target 'c')
                  in
                  let committed_envelope =
                    envelope ~nonce_offset:(offset + 20) committed_event
                  in
                  let committed_id = transaction_id 'c' in
                  let committed_child =
                    fork_result (fun () ->
                        match open_transactions root with
                        | Error _ -> false
                        | Ok transactions -> (
                            match
                              Transaction_store.prepare transactions
                                ~transaction_id:committed_id
                                ~envelopes:[ committed_envelope ]
                            with
                            | Error _ -> false
                            | Ok
                                ( Transaction_store.Prepared _
                                | Transaction_store.Already_prepared _ ) ->
                                Result.is_ok
                                  (Transaction_store.commit transactions
                                     ~transaction_id:committed_id)))
                  in
                  if not (wait_success committed_child) then
                    failed "committed interruption child"
                  else
                    let before =
                      filesystem_image (Filename.concat root ".yeokcham")
                    in
                    let pre_recovery =
                      open_verifier root |> fun result ->
                      Result.bind result Verification.verify
                    in
                    let unchanged =
                      String.equal before
                        (filesystem_image (Filename.concat root ".yeokcham"))
                    in
                    let recovered =
                      match open_transactions root with
                      | Error _ -> Error ()
                      | Ok transactions ->
                          Transaction_store.recover transactions
                          |> Result.map_error (fun _ -> ())
                    in
                    let post_recovery =
                      open_verifier root |> fun result ->
                      Result.bind result Verification.verify
                    in
                    match (pre_recovery, recovered, post_recovery) with
                    | Ok pre, Ok recovery, Ok post ->
                        let ( pre_objects,
                              pre_events,
                              pre_refs,
                              pre_heads,
                              pre_divergences,
                              pre_prepared,
                              pre_committed ) =
                          report_fields pre
                        in
                        let ( post_objects,
                              post_events,
                              post_refs,
                              post_heads,
                              post_divergences,
                              post_prepared,
                              post_committed ) =
                          report_fields post
                        in
                        let valid =
                          List.length
                            recovery.Transaction_store.discarded_prepares
                          = 1
                          && List.length
                               recovery.Transaction_store.completed_transactions
                             = 1
                          && unchanged
                          && pre_objects = forks + 1
                          && pre_events = forks + 1
                          && pre_refs = 1 && pre_heads = forks
                          && pre_divergences = 1 && pre_prepared = 1
                          && pre_committed = 1
                          && post_objects = forks + 2
                          && post_events = forks + 2
                          && post_refs = 1
                          && post_heads = forks + 1
                          && post_divergences = 1 && post_prepared = 0
                          && post_committed = 0
                        in
                        if valid then true
                        else (
                          Printf.eprintf
                            "v2 state-machine counts forks=%d \
                             pre=%d/%d/%d/%d/%d/%d/%d \
                             post=%d/%d/%d/%d/%d/%d/%d discard=%d complete=%d \
                             unchanged=%b\n\
                             %!"
                            forks pre_objects pre_events pre_refs pre_heads
                            pre_divergences pre_prepared pre_committed
                            post_objects post_events post_refs post_heads
                            post_divergences post_prepared post_committed
                            (List.length
                               recovery.Transaction_store.discarded_prepares)
                            (List.length
                               recovery.Transaction_store.completed_transactions)
                            unchanged;
                          false)
                    | Error _, _, _ | Ok _, Error _, _ | Ok _, Ok _, Error _ ->
                        failed
                          "pre verification, recovery, or post verification")))

let () =
  Alcotest.run "V2 multi-process state machine"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "concurrent-interruption-reopen")
            concurrent_interruption_and_reopen_state_machine;
        ] );
    ]
