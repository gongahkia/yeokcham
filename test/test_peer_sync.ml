module Peer_sync = Yeokcham_peer_sync
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

let identity byte =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 byte)
    |> require_ok (Format.asprintf "%a" Mirage_crypto_ec.pp_error)
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let identity =
    Peer_sync.make_identity ~public_key |> require_ok Peer_sync.error_to_string
  in
  (identity, private_key)

let snapshot store entries =
  let contents =
    List.map
      (fun (name, bytes) ->
        let content =
          Snapshot.Content.store store bytes
          |> require_ok Snapshot.error_to_string
        in
        (name, Snapshot.Tree.File { mode = Snapshot.Regular; content }))
      entries
  in
  let tree =
    Snapshot.Tree.create contents |> require_ok Snapshot.error_to_string
  in
  let root =
    Snapshot.Tree.store store tree |> require_ok Snapshot.error_to_string
  in
  Snapshot.Snapshot.create ~root
  |> Snapshot.Snapshot.store store
  |> require_ok Snapshot.error_to_string

let store_identity store identity =
  ignore
    (Peer_sync.store_identity store identity
    |> require_ok Peer_sync.error_to_string)

let store_node store ~author ~private_key ~snapshot ~parents =
  let node =
    Peer_sync.make_sync_node ~author ~private_key ~snapshot ~parents
    |> require_ok Peer_sync.error_to_string
  in
  ignore
    (Peer_sync.store_sync_node store node
    |> require_ok Peer_sync.error_to_string);
  node

let identity_contact_and_session () =
  with_directory "yeokcham-peer-sync-session-" (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let alice, alice_private = identity 'a' in
      let bob, _ = identity 'b' in
      store_identity store alice;
      let contact =
        Peer_sync.make_contact ~name:"alice" ~identity:alice
          ~endpoints:[ Peer_sync.Local_path root ]
        |> require_ok Peer_sync.error_to_string
      in
      ignore
        (Peer_sync.store_contact store contact
        |> require_ok Peer_sync.error_to_string);
      let nonce = String.make Peer_sync.nonce_bytes 'n' in
      let unsigned =
        Peer_sync.make_unsigned_session
          ~repository_format:Store.repository_format ~initiator:alice
          ~responder:bob ~nonce ~transcript:"sync:heads"
        |> require_ok Peer_sync.error_to_string
      in
      let proof =
        Peer_sync.sign_session unsigned ~private_key:alice_private
        |> require_ok Peer_sync.error_to_string
      in
      Peer_sync.verify_session ~repository_format:Store.repository_format
        ~expected_signer:contact ~expected_initiator:(Peer_sync.peer_id alice)
        ~expected_responder:(Peer_sync.peer_id bob) ~expected_nonce:nonce
        ~expected_transcript:"sync:heads" proof
      |> require_ok Peer_sync.error_to_string;
      let replay =
        Peer_sync.verify_session ~repository_format:"wrong-format"
          ~expected_signer:contact ~expected_initiator:(Peer_sync.peer_id alice)
          ~expected_responder:(Peer_sync.peer_id bob) ~expected_nonce:nonce
          ~expected_transcript:"sync:heads" proof
      in
      Alcotest.(check bool)
        "format-bound proof rejects replay" true (Result.is_error replay))

let merges_disjoint_paths () =
  with_directory "yeokcham-peer-sync-merge-" (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let alice, alice_private = identity 'a' in
      let bob, bob_private = identity 'b' in
      store_identity store alice;
      store_identity store bob;
      let base_snapshot = snapshot store [ ("base", "base\n") ] in
      let base =
        store_node store ~author:alice ~private_key:alice_private
          ~snapshot:base_snapshot ~parents:[]
      in
      let local_snapshot =
        snapshot store [ ("base", "base\n"); ("local", "left\n") ]
      in
      let local =
        store_node store ~author:alice ~private_key:alice_private
          ~snapshot:local_snapshot
          ~parents:[ Peer_sync.sync_node_id base ]
      in
      let remote_snapshot =
        snapshot store [ ("base", "base\n"); ("remote", "right\n") ]
      in
      let remote =
        store_node store ~author:bob ~private_key:bob_private
          ~snapshot:remote_snapshot
          ~parents:[ Peer_sync.sync_node_id base ]
      in
      match
        Peer_sync.reconcile store ~author:alice ~private_key:alice_private
          ~local:(Peer_sync.sync_node_id local)
          ~remote:(Peer_sync.sync_node_id remote)
        |> require_ok Peer_sync.error_to_string
      with
      | Peer_sync.Merged node ->
          Alcotest.(check int)
            "merge has ordered causal parents" 2
            (List.length (Peer_sync.sync_node_parents node));
          ignore
            (Peer_sync.load_sync_node store (Peer_sync.sync_node_id node)
            |> require_ok Peer_sync.error_to_string)
      | Peer_sync.Fast_forward _ | Peer_sync.Already_current _
      | Peer_sync.Conflict _ ->
          Alcotest.fail "disjoint edits must create a merge sync node")

let persists_conflict_and_protects_tracking () =
  with_directory "yeokcham-peer-sync-conflict-" (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let alice, alice_private = identity 'a' in
      let bob, bob_private = identity 'b' in
      store_identity store alice;
      store_identity store bob;
      let contact =
        Peer_sync.make_contact ~name:"bob" ~identity:bob
          ~endpoints:[ Peer_sync.Local_path root ]
        |> require_ok Peer_sync.error_to_string
      in
      ignore
        (Peer_sync.store_contact store contact
        |> require_ok Peer_sync.error_to_string);
      let base_snapshot = snapshot store [ ("same", "base\n") ] in
      let base =
        store_node store ~author:alice ~private_key:alice_private
          ~snapshot:base_snapshot ~parents:[]
      in
      let local =
        store_node store ~author:alice ~private_key:alice_private
          ~snapshot:(snapshot store [ ("same", "left\n") ])
          ~parents:[ Peer_sync.sync_node_id base ]
      in
      let remote =
        store_node store ~author:bob ~private_key:bob_private
          ~snapshot:(snapshot store [ ("same", "right\n") ])
          ~parents:[ Peer_sync.sync_node_id base ]
      in
      Peer_sync.update_tracking_head store ~contact ~name:"main" ~expected:None
        (Peer_sync.sync_node_id remote)
      |> require_ok Peer_sync.error_to_string;
      Alcotest.(check bool)
        "tracking ref never accepts local author" true
        (Result.is_error
           (Peer_sync.update_tracking_head store ~contact ~name:"main"
              ~expected:(Some (Peer_sync.sync_node_id remote))
              (Peer_sync.sync_node_id local)));
      match
        Peer_sync.reconcile store ~author:alice ~private_key:alice_private
          ~local:(Peer_sync.sync_node_id local)
          ~remote:(Peer_sync.sync_node_id remote)
        |> require_ok Peer_sync.error_to_string
      with
      | Peer_sync.Conflict conflict ->
          Alcotest.(check int)
            "one exact conflicting path" 1
            (List.length (Peer_sync.conflict_paths conflict))
      | Peer_sync.Fast_forward _ | Peer_sync.Already_current _
      | Peer_sync.Merged _ ->
          Alcotest.fail "incompatible same-path bytes must persist a conflict")

let direct_sync_transfers_verified_closure_and_advances_tracking () =
  with_directory "yeokcham-peer-sync-source-" (fun source_root ->
      with_directory "yeokcham-peer-sync-destination-" (fun destination_root ->
          let source =
            Store.init ~root:source_root |> require_ok Store.error_to_string
          in
          let destination =
            Store.init ~root:destination_root
            |> require_ok Store.error_to_string
          in
          let alice, alice_private = identity 'a' in
          let bob, _ = identity 'b' in
          store_identity source alice;
          store_identity destination bob;
          let contact =
            Peer_sync.make_contact ~name:"alice" ~identity:alice
              ~endpoints:[ Peer_sync.Local_path source_root ]
            |> require_ok Peer_sync.error_to_string
          in
          ignore
            (Peer_sync.store_contact destination contact
            |> require_ok Peer_sync.error_to_string);
          let head =
            store_node source ~author:alice ~private_key:alice_private
              ~snapshot:(snapshot source [ ("tracked", "peer sync\n") ])
              ~parents:[]
          in
          let outcome, decision =
            Peer_sync.sync_local ~source ~destination ~contact
              ~destination_identity:bob ~source_private_key:alice_private
              ~nonce:(String.make Peer_sync.nonce_bytes 'n')
              ~transcript:"peer-sync:main" ~tracking_name:"main"
              ~head:(Peer_sync.sync_node_id head)
              ()
            |> require_ok Peer_sync.error_to_string
          in
          Alcotest.(check bool)
            "sync transfers an immutable closure" true
            (outcome.Yeokcham_exchange_store.transferred <> []);
          (match decision with
          | Peer_sync.Tracking_advanced received ->
              Alcotest.(check string)
                "received tracking head"
                (Yeokcham_id.Peer_sync_node_id.to_hex
                   (Peer_sync.sync_node_id head))
                (Yeokcham_id.Peer_sync_node_id.to_hex
                   (Peer_sync.sync_node_id received))
          | Peer_sync.Tracking_already_current _ | Peer_sync.Tracking_diverged _
            ->
              Alcotest.fail
                "new remote head must advance its empty tracking ref");
          Alcotest.(check bool)
            "received node verifies" true
            (Result.is_ok
               (Peer_sync.load_sync_node destination
                  (Peer_sync.sync_node_id head)));
          Alcotest.(check (option string))
            "tracking ref records remote head"
            (Some
               (Yeokcham_id.Peer_sync_node_id.to_hex
                  (Peer_sync.sync_node_id head)))
            (Peer_sync.tracking_head destination ~contact ~name:"main"
            |> require_ok Peer_sync.error_to_string
            |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex)))

let interrupted_direct_sync_does_not_advance_tracking () =
  with_directory "yeokcham-peer-sync-interrupted-source-" (fun source_root ->
      with_directory "yeokcham-peer-sync-interrupted-destination-"
        (fun destination_root ->
          let source =
            Store.init ~root:source_root |> require_ok Store.error_to_string
          in
          let destination =
            Store.init ~root:destination_root
            |> require_ok Store.error_to_string
          in
          let alice, alice_private = identity 'a' in
          let bob, _ = identity 'b' in
          store_identity source alice;
          store_identity destination bob;
          let contact =
            Peer_sync.make_contact ~name:"alice" ~identity:alice
              ~endpoints:[ Peer_sync.Local_path source_root ]
            |> require_ok Peer_sync.error_to_string
          in
          ignore
            (Peer_sync.store_contact destination contact
            |> require_ok Peer_sync.error_to_string);
          let head =
            store_node source ~author:alice ~private_key:alice_private
              ~snapshot:(snapshot source [ ("tracked", "peer sync\n") ])
              ~parents:[]
          in
          Alcotest.(check bool)
            "interrupted transfer refuses before tracking" true
            (Result.is_error
               (Peer_sync.sync_local ~interrupt_after:0 ~source ~destination
                  ~contact ~destination_identity:bob
                  ~source_private_key:alice_private
                  ~nonce:(String.make Peer_sync.nonce_bytes 'n')
                  ~transcript:"peer-sync:main" ~tracking_name:"main"
                  ~head:(Peer_sync.sync_node_id head)
                  ()));
          Alcotest.(check (option string))
            "tracking ref stays absent" None
            (Peer_sync.tracking_head destination ~contact ~name:"main"
            |> require_ok Peer_sync.error_to_string
            |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex)))

let () =
  Alcotest.run "yeokcham_peer_sync"
    [
      ( "identity-and-session",
        [
          Alcotest.test_case "durable pinned contact and replay boundary" `Quick
            identity_contact_and_session;
        ] );
      ( "sync-graph",
        [
          Alcotest.test_case "disjoint exact changes merge" `Quick
            merges_disjoint_paths;
          Alcotest.test_case "conflicts and tracking isolation" `Quick
            persists_conflict_and_protects_tracking;
          Alcotest.test_case
            "direct sync transfers a verified closure and advances tracking"
            `Quick direct_sync_transfers_verified_closure_and_advances_tracking;
          Alcotest.test_case "interrupted direct sync preserves tracking" `Quick
            interrupted_direct_sync_does_not_advance_tracking;
        ] );
    ]
