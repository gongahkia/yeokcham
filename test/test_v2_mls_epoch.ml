module Address = Yeokcham_v2_address
module Authority = Yeokcham_v2_authority
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Epoch = Yeokcham_v2_mls_epoch
module Epoch_store = Yeokcham_v2_mls_epoch_store
module Golden = Yeokcham_testkit.Golden_fixture
module Group = Yeokcham_v2_mls_group
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository byte =
  Model.Repository_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let device byte =
  Model.Device_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let nonce byte =
  Envelope.nonce_of_bytes (String.make 12 byte) |> require_ok Envelope.error_to_string

let key byte =
  Envelope.key_of_bytes (String.make 32 byte) |> require_ok Envelope.error_to_string

let root seed =
  String.init 32 (fun index -> Char.chr ((seed + index) land 255))
  |> Authority.root_signing_capability_of_private_key
  |> require_ok Authority.error_to_string

let authority repository_id root =
  Authority.make_repository_authority ~repository_id ~root ~mandatory_features:0L
  |> require_ok Authority.error_to_string

let capability () =
  let encryption_key = key 'e' in
  let address_key =
    Address.key_of_bytes (String.make 32 'a') |> require_ok Address.error_to_string
  in
  let signing_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 's')
    |> require_ok (fun error -> Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> require_ok Bootstrap.error_to_string

let bootstrap ~repository_id ~device_id capability =
  let handle =
    Bootstrap.Key_handle.of_bytes (String.make 32 'h')
    |> require_ok Model.identity_error_to_string
  in
  Bootstrap.make ~repository_id ~device_id ~key_handle:handle ~capability
    ~mandatory_features:0L
  |> require_ok Bootstrap.error_to_string

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK -> Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root run =
  let path = Filename.temp_file "yeokcham-v2-mls-epoch-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

type sequence = {
  runtime : Runtime.configuration;
  authority : Authority.repository_authority;
  initial : Group.t;
  last : Epoch.transition_result;
  records : Epoch.transition list;
  state_key : Envelope.key;
}

let sequence () =
  let repository_id = repository 'r' in
  let runtime = Runtime.default_configuration in
  let root = root 7 in
  let authority = authority repository_id root in
  let state_key = key 'k' in
  let initial =
    Group.create ~runtime ~repository_id ~device_id:(device 'a')
    |> require_ok Group.error_to_string
  in
  let added_b =
    Epoch.advance_add ~runtime ~authority ~root ~parent_id:None ~issuer_state:initial
      ~recipient_device_id:(device 'b') ~state_key ~state_nonce:(nonce 'b')
    |> require_ok Epoch.error_to_string
  in
  let added_c =
    Epoch.advance_add ~runtime ~authority ~root
      ~parent_id:(Some (Epoch.id added_b.Epoch.transition_result_record))
      ~issuer_state:added_b.Epoch.transition_result_successor_state
      ~recipient_device_id:(device 'c') ~state_key ~state_nonce:(nonce 'c')
    |> require_ok Epoch.error_to_string
  in
  let removed_c =
    Epoch.advance_removal ~runtime ~authority ~root
      ~parent_id:(Some (Epoch.id added_c.Epoch.transition_result_record))
      ~issuer_state:added_c.Epoch.transition_result_successor_state
      ~removed_device_id:(device 'c') ~state_key ~state_nonce:(nonce 'd')
    |> require_ok Epoch.error_to_string
  in
  { runtime; authority; initial; last = removed_c;
    records =
      [
        added_b.Epoch.transition_result_record;
        added_c.Epoch.transition_result_record;
        removed_c.Epoch.transition_result_record;
      ];
    state_key }

let read_golden name =
  let local = Filename.concat "golden" name in
  let path = if Sys.file_exists local then local else Filename.concat "test" local in
  Golden.read_lower_hex_file path |> require_ok Fun.id

let canonical_fixture_is_strict () =
  let repository_id = repository 'r' in
  let root = root 7 in
  let authority = authority repository_id root in
  let state =
    Group.decode (read_golden "v2-mls-group-state-v1.cbor.hex")
    |> require_ok Group.error_to_string
  in
  let expected =
    Epoch.create ~authority ~root ~parent_id:None ~change:Epoch.Member_added
      ~changed_device_id:(device 'b') ~predecessor_state:state
      ~successor_state:state ~commit:"fixed-MLS-commit-vector" ~previous_epoch:0L
      ~next_epoch:1L ~state_key:(key 'k') ~state_nonce:(nonce 'n')
    |> require_ok Epoch.error_to_string
  in
  let debug_envelope =
    Group.seal_state ~key:(key 'k') ~nonce:(nonce 'n') state
    |> require_ok Group.error_to_string
  in
  Printf.printf "envelope=%s\n%!" (String.concat ""
    (List.init (String.length (Envelope.encode debug_envelope)) (fun index ->
      Printf.sprintf "%02x" (Char.code (Envelope.encode debug_envelope).[index]))));
  Printf.printf "epoch-fixture=%s\n%!" (String.concat ""
    (List.init (String.length (Epoch.encode expected)) (fun index ->
      Printf.sprintf "%02x" (Char.code (Epoch.encode expected).[index]))));
  let bytes = read_golden "v2-mls-epoch-transition-v1.cbor.hex" in
  let decoded = Epoch.decode ~authority bytes |> require_ok Epoch.error_to_string in
  Alcotest.(check string) "canonical epoch fixture re-encodes exactly" bytes
    (Epoch.encode decoded);
  Alcotest.(check string) "fixture is the fixed signed transition"
    (Epoch.encode expected) bytes

let signed_encrypted_chain_replays_one_successor_per_epoch () =
  let sequence = sequence () in
  let decoded =
    List.map
      (fun record ->
        Epoch.decode ~authority:sequence.authority (Epoch.encode record)
        |> require_ok Epoch.error_to_string)
      sequence.records
  in
  let current =
    Epoch.verify_chain ~runtime:sequence.runtime ~authority:sequence.authority
      ~state_key:sequence.state_key ~initial_state:sequence.initial decoded
    |> require_ok Epoch.error_to_string
  in
  Alcotest.(check int64) "three transitions reach epoch three" 3L
    (Epoch.next_epoch sequence.last.Epoch.transition_result_record);
  Alcotest.(check string) "replayed successor is the removed issuer state"
    (Group.encode sequence.last.Epoch.transition_result_successor_state)
    (Group.encode current);
  let durable = Epoch.encode sequence.last.Epoch.transition_result_record in
  Alcotest.(check bool) "record contains no plaintext successor state" false
    (let plaintext =
       Group.encode sequence.last.Epoch.transition_result_successor_state
     in
     let rec contains offset =
       offset + String.length plaintext <= String.length durable
       && (String.equal (String.sub durable offset (String.length plaintext)) plaintext
          || contains (offset + 1))
     in
     contains 0)

let persistent_exact_retry_ignores_interruption_and_refuses_divergence () =
  with_root (fun root_path ->
      ignore (Store.init ~root:root_path |> require_ok Store.error_to_string);
      let sequence = sequence () in
      let bootstrap_capability = capability () in
      let bootstrap =
        bootstrap ~repository_id:(repository 'r') ~device_id:(device 'a')
          bootstrap_capability
      in
      ignore
        (Bootstrap_store.initialize ~root:root_path bootstrap
        |> require_ok Bootstrap_store.error_to_string);
      let first = List.hd sequence.records in
      let staged_directory = Epoch_store.directory ~root:root_path in
      Unix.mkdir staged_directory 0o700;
      let stage =
        Filename.concat staged_directory
          ("." ^ Model.Mls_epoch_id.to_hex (Epoch.id first) ^ ".cbor.stage-42-0")
      in
      let descriptor = Unix.openfile stage [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
      Unix.close descriptor;
      List.iter
        (fun record ->
          ignore
            (Epoch_store.write ~root:root_path ~authority:sequence.authority record
            |> require_ok Epoch_store.error_to_string))
        sequence.records;
      Alcotest.(check bool) "exact durable retry is idempotent" true
        (Epoch_store.write ~root:root_path ~authority:sequence.authority first
        |> require_ok Epoch_store.error_to_string
        = Epoch_store.Already_published);
      let current =
        Epoch_store.load_current ~runtime:sequence.runtime ~root:root_path
          ~authority:sequence.authority ~state_key:sequence.state_key
          ~initial_state:sequence.initial
        |> require_ok Epoch_store.error_to_string
      in
      Alcotest.(check string) "durable chain reaches expected successor"
        (Group.encode sequence.last.Epoch.transition_result_successor_state)
        (Group.encode current);
      let other_root = root 29 in
      let competing =
        Epoch.advance_add ~runtime:sequence.runtime ~authority:sequence.authority
          ~root:other_root ~parent_id:None ~issuer_state:sequence.initial
          ~recipient_device_id:(device 'x') ~state_key:sequence.state_key
          ~state_nonce:(nonce 'x')
      in
      Alcotest.(check bool) "foreign root cannot create a transition" true
        (Result.is_error competing);
      let unknown = Filename.concat staged_directory "unexpected" in
      let descriptor = Unix.openfile unknown [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
      Unix.close descriptor;
      Alcotest.(check bool) "unknown durable entry fails closed" true
        (Result.is_error (Epoch_store.read_all ~root:root_path ~authority:sequence.authority)))

let () =
  Alcotest.run "V2 MLS epochs"
    [
      ( "unit",
        [
          Alcotest.test_case "signed encrypted epoch chain replays uniquely" `Slow
            signed_encrypted_chain_replays_one_successor_per_epoch;
          Alcotest.test_case "canonical epoch fixture is strict" `Quick
            canonical_fixture_is_strict;
          Alcotest.test_case
            "durable exact retry ignores interruption and fails closed" `Slow
            persistent_exact_retry_ignores_interruption_and_refuses_divergence;
        ] );
    ]
