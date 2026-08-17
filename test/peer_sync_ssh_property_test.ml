module Peer_sync = Yeokcham_peer_sync
module Ssh = Yeokcham_peer_sync_ssh

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

let identity byte =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 byte)
    |> Result.get_ok
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  (Peer_sync.make_identity ~public_key |> Result.get_ok, private_key)

let source, source_private_key = identity 'a'
let destination, _ = identity 'b'

let source_contact =
  Peer_sync.make_contact ~name:"source" ~identity:source
    ~endpoints:[ Peer_sync.Ssh { target = "fixture"; root = "/var/tmp/peer" } ]
  |> Result.get_ok

let protocol_values =
  QCheck2.Gen.pair
    (QCheck2.Gen.int_range 0 999_999)
    (QCheck2.Gen.int_range 0 999_999)

let request_roundtrip_and_replay_boundary (head_seed, nonce_seed) =
  let head =
    Bytes.init 32 (fun offset -> Char.chr ((head_seed + offset) land 0xff))
    |> Bytes.unsafe_to_string |> Yeokcham_id.Peer_sync_node_id.of_bytes
    |> Result.get_ok
  in
  let nonce =
    Bytes.init Peer_sync.nonce_bytes (fun offset ->
        Char.chr ((nonce_seed + offset) land 0xff))
    |> Bytes.unsafe_to_string
  in
  let tracking_name = "head-" ^ string_of_int (head_seed mod 10_000) in
  match
    Ssh.make_request ~remote_root:"/var/tmp/peer"
      ~source:(Peer_sync.peer_id source) ~destination ~nonce ~tracking_name
      ~head
  with
  | Error _ -> false
  | Ok request -> (
      match Ssh.request_payload request with
      | Error _ -> false
      | Ok payload -> (
          match Ssh.decode_request_payload payload with
          | Error _ -> false
          | Ok reopened -> (
              let transcript =
                Peer_sync.ssh_transcript ~tracking_name ~head |> Result.get_ok
              in
              let proof =
                match
                  Peer_sync.make_unsigned_session
                    ~repository_format:Yeokcham_store.repository_format
                    ~initiator:source ~responder:destination ~nonce ~transcript
                with
                | Error error -> Error error
                | Ok unsigned ->
                    Peer_sync.sign_session unsigned
                      ~private_key:source_private_key
              in
              match proof with
              | Error _ -> false
              | Ok proof ->
                  Peer_sync.verify_session
                    ~repository_format:Yeokcham_store.repository_format
                    ~expected_signer:source_contact
                    ~expected_initiator:(Peer_sync.peer_id source)
                    ~expected_responder:(Peer_sync.peer_id destination)
                    ~expected_nonce:(Ssh.request_nonce reopened)
                    ~expected_transcript:transcript proof
                  |> Result.is_ok
                  && Peer_sync.verify_session
                       ~repository_format:Yeokcham_store.repository_format
                       ~expected_signer:source_contact
                       ~expected_initiator:(Peer_sync.peer_id source)
                       ~expected_responder:(Peer_sync.peer_id destination)
                       ~expected_nonce:(String.make Peer_sync.nonce_bytes 'r')
                       ~expected_transcript:transcript proof
                     |> Result.is_error)))

let generated_requests =
  QCheck2.Test.make ~count:100
    ~name:
      "SSH peer-sync request inverse encoding and challenge replay boundary \
       hold for generated heads"
    protocol_values request_roundtrip_and_replay_boundary

let () =
  Printf.printf "SSH peer-sync property base seed: %d\n%!" base_seed;
  Alcotest.run "SSH peer-sync properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "request-roundtrip")
            generated_requests;
        ] );
    ]
