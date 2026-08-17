module Peer_sync = Yeokcham_peer_sync
module Relay = Yeokcham_peer_sync_relay
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let default_seed = 20_260_817

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let state_for name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !value |]

let require = function
  | Ok value -> value
  | Error _ -> failwith "relay property setup failed"

let identity byte =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 byte) |> require
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  (Peer_sync.make_identity ~public_key |> require, private_key)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
  | Unix.S_SOCK ->
      Unix.unlink path

let with_store run =
  let root = Filename.temp_file "yeokcham-peer-relay-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () -> run (Store.init ~root |> require))

let snapshot store =
  let content = Snapshot.Content.store store "property relay\n" |> require in
  let tree =
    Snapshot.Tree.create
      [ ("tracked", Snapshot.Tree.File { mode = Snapshot.Regular; content }) ]
    |> require
  in
  let root = Snapshot.Tree.store store tree |> require in
  Snapshot.Snapshot.create ~root |> Snapshot.Snapshot.store store |> require

let generated_values =
  QCheck2.Gen.pair
    (QCheck2.Gen.int_range 0 999_999)
    (QCheck2.Gen.int_range 0 999_999)

let package_and_advertisement_roundtrip (tracking_seed, nonce_seed) =
  with_store (fun source ->
      let alice, alice_private = identity 'a' in
      let bob, _ = identity 'b' in
      ignore (Peer_sync.store_identity source alice |> require);
      let head =
        Peer_sync.make_sync_node ~author:alice ~private_key:alice_private
          ~snapshot:(snapshot source) ~parents:[]
        |> require
      in
      ignore (Peer_sync.store_sync_node source head |> require);
      let nonce =
        Bytes.init Peer_sync.nonce_bytes (fun offset ->
            Char.chr ((nonce_seed + offset) land 0xff))
        |> Bytes.unsafe_to_string
      in
      let tracking_name = "head-" ^ string_of_int tracking_seed in
      match
        Relay.make_package ~source ~source_identity:alice
          ~source_private_key:alice_private ~destination:bob ~tracking_name
          ~head:(Peer_sync.sync_node_id head)
          ~issued_at:1_700_000_000L ~expires_at:1_700_000_600L ~nonce
      with
      | Error _ -> false
      | Ok package -> (
          match Relay.make_advertisement package ~private_key:alice_private with
          | Error _ -> false
          | Ok advertisement -> (
              match
                ( Relay.package_payload package,
                  Relay.advertisement_payload advertisement )
              with
              | Ok package_value, Ok advertisement_value -> (
                  match
                    ( Relay.decode_package_payload package_value,
                      Relay.decode_advertisement_payload advertisement_value )
                  with
                  | Ok reopened_package, Ok reopened_advertisement ->
                      String.equal (Relay.package_id package)
                        (Relay.package_id reopened_package)
                      && String.equal
                           (Relay.advertisement_id advertisement)
                           (Relay.advertisement_id reopened_advertisement)
                      && String.equal tracking_name
                           (Relay.package_tracking_name reopened_package)
                  | Error _, _ | _, Error _ -> false)
              | Error _, _ | _, Error _ -> false)))

let generated_roundtrips =
  QCheck2.Test.make ~count:100
    ~name:
      "relay package and advertisement canonical inverse encoding holds for \
       generated nonces and tracking names"
    generated_values package_and_advertisement_roundtrip

let () =
  Printf.printf "relay peer-sync property base seed: %d\n%!" base_seed;
  Alcotest.run "relay peer-sync properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "relay-roundtrip")
            generated_roundtrips;
        ] );
    ]
