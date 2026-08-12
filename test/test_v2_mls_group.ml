module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Group = Yeokcham_v2_mls_group
module Group_store = Yeokcham_v2_mls_group_store
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
  Envelope.nonce_of_bytes (String.make 12 byte)
  |> require_ok Envelope.error_to_string

let capability () =
  let encryption_key =
    Envelope.key_of_bytes (String.make 32 'e')
    |> require_ok Envelope.error_to_string
  in
  let address_key =
    Address.key_of_bytes (String.make 32 'a')
    |> require_ok Address.error_to_string
  in
  let signing_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 's')
    |> require_ok (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
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
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root run =
  let root = Filename.temp_file "yeokcham-v2-mls-group-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let open_repository ~root bootstrap capability =
  ignore
    (Bootstrap_store.initialize ~root bootstrap
    |> require_ok Bootstrap_store.error_to_string);
  Bootstrap_store.open_repository ~root ~capability
  |> require_ok Bootstrap_store.error_to_string

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let contains ~needle haystack =
  let needle_length = String.length needle in
  let rec search offset =
    offset + needle_length <= String.length haystack
    &&
    if String.equal (String.sub haystack offset needle_length) needle then true
    else search (offset + 1)
  in
  search 0

let replace_once ~needle ~replacement value =
  let needle_length = String.length needle in
  let rec find offset =
    if offset + needle_length > String.length value then None
    else if String.equal (String.sub value offset needle_length) needle then
      Some offset
    else find (offset + 1)
  in
  match find 0 with
  | None -> None
  | Some offset ->
      Some
        (String.sub value 0 offset ^ replacement
        ^ String.sub value (offset + needle_length)
            (String.length value - offset - needle_length))

let canonical_fixture_is_strict_but_runtime_unverified () =
  let bytes = read_golden "v2-mls-group-state-v1.cbor.hex" in
  let state = Group.decode bytes |> require_ok Group.error_to_string in
  Alcotest.(check string)
    "canonical MLS state fixture re-encodes exactly" bytes (Group.encode state);
  Alcotest.(check bool)
    "fixture has a deterministic repository group ID" true
    (Model.Mls_group_id.equal (Group.group_id state)
       (Group.group_id_for_repository (repository 'r')))

let bootstrap_persists_one_verified_member_and_metadata () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository_id = repository 'r' in
      let device_id = device 'd' in
      let capability = capability () in
      let bootstrap = bootstrap ~repository_id ~device_id capability in
      let local = open_repository ~root bootstrap capability in
      let runtime = Runtime.default_configuration in
      let state =
        Group.create ~runtime ~repository_id ~device_id
        |> require_ok Group.error_to_string
      in
      let initial =
        Group_store.initialize ~runtime ~root ~bootstrap:local state
        |> require_ok Group_store.error_to_string
      in
      Alcotest.(check bool)
        "first state publication succeeds" true
        (initial = Group_store.Initialized);
      let retry =
        Group_store.initialize ~runtime ~root ~bootstrap:local state
        |> require_ok Group_store.error_to_string
      in
      Alcotest.(check bool)
        "exact state retry is idempotent" true
        (retry = Group_store.Already_initialized);
      let reopened =
        Group_store.read ~runtime ~root ~bootstrap:local
        |> require_ok Group_store.error_to_string
      in
      Alcotest.(check string)
        "reopened state retains canonical binding" (Group.encode state)
        (Group.encode reopened);
      let encrypted =
        Group.encrypt_metadata ~runtime ~state:reopened ~nonce:(nonce 'n')
          "repository metadata"
        |> require_ok Group.error_to_string
      in
      Alcotest.(check string)
        "MLS exporter metadata decrypts" "repository metadata"
        (Group.decrypt_metadata ~runtime ~state:reopened encrypted
        |> require_ok Group.error_to_string);
      let durable =
        let descriptor =
          Unix.openfile (Group_store.group_path ~root) [ Unix.O_RDONLY ] 0
        in
        Fun.protect
          ~finally:(fun () -> Unix.close descriptor)
          (fun () ->
            let size = (Unix.fstat descriptor).Unix.st_size in
            let bytes = Bytes.create size in
            ignore (Unix.read descriptor bytes 0 size);
            Bytes.unsafe_to_string bytes)
      in
      Alcotest.(check bool)
        "durable envelope contains no plaintext state" false
        (contains ~needle:(Group.encode state) durable))

let wrong_repository_device_group_and_persistence_fail_closed () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository_id = repository 'r' in
      let device_id = device 'd' in
      let capability = capability () in
      let bootstrap = bootstrap ~repository_id ~device_id capability in
      let local = open_repository ~root bootstrap capability in
      let runtime = Runtime.default_configuration in
      let state =
        Group.create ~runtime ~repository_id ~device_id
        |> require_ok Group.error_to_string
      in
      let foreign =
        Group.create ~runtime ~repository_id:(repository 'x') ~device_id
        |> require_ok Group.error_to_string
      in
      Alcotest.(check bool)
        "foreign repository group cannot initialize" true
        (Result.is_error
           (Group_store.initialize ~runtime ~root ~bootstrap:local foreign));
      let wrong_group_bytes =
        replace_once
          ~needle:(Model.Mls_group_id.to_bytes (Group.group_id state))
          ~replacement:(String.make 32 'x') (Group.encode state)
        |> Option.get
      in
      Alcotest.(check bool)
        "repository-derived group binding rejects tampering" true
        (Result.is_error (Group.decode wrong_group_bytes));
      let wrong_device_state =
        replace_once
          ~needle:(Model.Device_id.to_bytes device_id)
          ~replacement:(Model.Device_id.to_bytes (device 'x'))
          (Group.encode state)
        |> Option.get |> Group.decode
        |> require_ok Group.error_to_string
      in
      Alcotest.(check bool)
        "runtime rejects state with wrong initial device" true
        (Result.is_error (Group.verify ~runtime wrong_device_state));
      ignore
        (Group_store.initialize ~runtime ~root ~bootstrap:local state
        |> require_ok Group_store.error_to_string);
      let path = Group_store.group_path ~root in
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          ignore (Unix.write descriptor (Bytes.of_string "corrupt") 0 7));
      Alcotest.(check bool)
        "corrupt encrypted state refuses opening" true
        (Result.is_error (Group_store.read ~runtime ~root ~bootstrap:local));
      Alcotest.(check bool)
        "corrupt state is never overwritten" true
        (Result.is_error
           (Group_store.initialize ~runtime ~root ~bootstrap:local state)))

let interrupted_bootstrap_has_no_visible_membership () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository_id = repository 'r' in
      let device_id = device 'd' in
      let capability = capability () in
      let bootstrap = bootstrap ~repository_id ~device_id capability in
      let local = open_repository ~root bootstrap capability in
      let runtime = Runtime.default_configuration in
      let state =
        Group.create ~runtime ~repository_id ~device_id
        |> require_ok Group.error_to_string
      in
      let directory = Filename.dirname (Group_store.group_path ~root) in
      Unix.mkdir directory 0o700;
      let staging =
        Filename.concat directory
          (Printf.sprintf ".%s.bootstrap-42-0" Group_store.filename)
      in
      let descriptor =
        Unix.openfile staging [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "staging alone has no readable membership" true
        (Result.is_error (Group_store.read ~runtime ~root ~bootstrap:local));
      let initialized =
        Group_store.initialize ~runtime ~root ~bootstrap:local state
        |> require_ok Group_store.error_to_string
      in
      Alcotest.(check bool)
        "later bootstrap publishes one complete state" true
        (initialized = Group_store.Initialized))

let () =
  Alcotest.run "V2 MLS group bootstrap"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical plaintext fixture is strict" `Quick
            canonical_fixture_is_strict_but_runtime_unverified;
          Alcotest.test_case
            "initial member persists encrypted state and metadata round-trips"
            `Slow bootstrap_persists_one_verified_member_and_metadata;
          Alcotest.test_case
            "foreign and corrupt state fail closed without replacement" `Slow
            wrong_repository_device_group_and_persistence_fail_closed;
          Alcotest.test_case "interrupted bootstrap has no visible membership"
            `Slow interrupted_bootstrap_has_no_visible_membership;
        ] );
    ]
