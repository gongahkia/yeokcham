module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Custody = Yeokcham_v2_keychain_custody
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let private_key byte =
  Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 byte)
  |> require_ok (fun error ->
      Format.asprintf "%a" Mirage_crypto_ec.pp_error error)

let capability ?(encryption = 'e') ?(address = 'a') ?(signing = 's') () =
  let encryption_key =
    Envelope.key_of_bytes (String.make 32 encryption)
    |> require_ok Envelope.error_to_string
  in
  let address_key =
    Address.key_of_bytes (String.make 32 address)
    |> require_ok Address.error_to_string
  in
  Bootstrap.make_capability ~encryption_key ~address_key
    ~signing_key:(private_key signing)
  |> require_ok Bootstrap.error_to_string

let repository byte =
  Model.Repository_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let device byte =
  Model.Device_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let key_handle byte =
  Custody.key_handle_of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

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
  let root = Filename.temp_file "yeokcham-v2-keychain-custody-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

type availability =
  | Available
  | Locked
  | Unavailable
  | Non_exportable
  | Unsupported

type memory = {
  availability : availability;
  mutable stored : string option;
  mutable items : Custody.item list;
  mutable store_calls : int;
  mutable remove_calls : int;
}

let new_memory ?(stored = None) availability =
  { availability; stored; items = []; store_calls = 0; remove_calls = 0 }

let backend memory : Custody.backend =
  let remember item = memory.items <- item :: memory.items in
  {
    Custody.lookup =
      (fun item ->
        remember item;
        match memory.availability with
        | Available -> (
            match memory.stored with
            | Some value -> Custody.Found value
            | None -> Custody.Missing)
        | Locked -> Custody.Locked
        | Unavailable -> Custody.Unavailable
        | Non_exportable -> Custody.Non_exportable_key
        | Unsupported -> Custody.Unsupported_key_item);
    Custody.store =
      (fun item value ->
        remember item;
        memory.store_calls <- memory.store_calls + 1;
        match memory.availability with
        | Available -> (
            match memory.stored with
            | None ->
                memory.stored <- Some value;
                Custody.Stored
            | Some _ -> Custody.Already_present)
        | Locked -> Custody.Store_locked
        | Unavailable | Non_exportable | Unsupported ->
            Custody.Store_unavailable);
    Custody.remove =
      (fun item ->
        remember item;
        memory.remove_calls <- memory.remove_calls + 1;
        match memory.availability with
        | Available -> (
            match memory.stored with
            | None -> Custody.Remove_missing
            | Some _ ->
                memory.stored <- None;
                Custody.Removed)
        | Locked -> Custody.Remove_locked
        | Unavailable | Non_exportable | Unsupported ->
            Custody.Remove_unavailable);
  }

let service memory = Custody.service ~backend:(backend memory)

let has_error expected = function
  | Ok _ -> false
  | Error error ->
      String.equal
        (Custody.error_to_string expected)
        (Custody.error_to_string error)

let contains ~needle haystack =
  let length = String.length needle in
  let rec search offset =
    offset + length <= String.length haystack
    && (String.equal (String.sub haystack offset length) needle
       || search (offset + 1))
  in
  length > 0 && search 0

let local_bootstrap_path root =
  Filename.concat root ".yeokcham/bootstrap/local-bootstrap-v2.cbor"

let read_file path = In_channel.with_open_bin path In_channel.input_all

let account_vector_is_canonical () =
  let expected =
    In_channel.with_open_bin "golden/v2-macos-keychain-account-v1.txt"
      In_channel.input_all
    |> String.trim
  in
  Alcotest.(check string)
    "account has a fixed schema and lowercase handle encoding" expected
    (Custody.account_of_key_handle (key_handle 'h'));
  let item = Custody.item_of_key_handle (key_handle 'h') in
  Alcotest.(check string)
    "fixed Keychain service namespace"
    "io.github.gongahkia.yeokcham.v2.local-capability" item.Custody.service_name;
  Alcotest.(check bool)
    "legacy key probe remains namespaced" true
    (String.starts_with ~prefix:"io.github.gongahkia.yeokcham/"
       item.Custody.legacy_key_tag)

let enrollment_reopens_without_repository_private_material () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let memory = new_memory Available in
      let authority = capability () in
      let enrolled =
        Custody.enroll ~service:(service memory) ~root
          ~repository_id:(repository 'r') ~device_id:(device 'd')
          ~key_handle:(key_handle 'h') ~capability:authority
        |> require_ok Custody.error_to_string
      in
      Alcotest.(check bool)
        "first local enrollment initializes" true
        (enrolled.Custody.initialization = Custody.Initialized);
      let bootstrap_bytes = read_file (local_bootstrap_path root) in
      let encryption_key, address_key, signing_key =
        Bootstrap.secret_material authority
      in
      List.iter
        (fun secret ->
          Alcotest.(check bool)
            "raw private material is absent from public repository bytes" false
            (contains ~needle:secret bootstrap_bytes))
        [ encryption_key; address_key; signing_key ];
      List.iter
        (fun item ->
          Alcotest.(check bool)
            "public Keychain locator omits private capability material" false
            (List.exists
               (fun secret ->
                 contains ~needle:secret item.Custody.service_name
                 || contains ~needle:secret item.Custody.account
                 || contains ~needle:secret item.Custody.legacy_key_tag)
               [ encryption_key; address_key; signing_key ]))
        memory.items;
      let retried =
        Custody.enroll ~service:(service memory) ~root
          ~repository_id:(repository 'r') ~device_id:(device 'd')
          ~key_handle:(key_handle 'h') ~capability:authority
        |> require_ok Custody.error_to_string
      in
      Alcotest.(check bool)
        "exact enrollment retry is idempotent" true
        (retried.Custody.initialization = Custody.Already_initialized);
      let reopened =
        Custody.open_repository ~service:(service memory) ~root
        |> require_ok Custody.error_to_string
      in
      Alcotest.(check string)
        "reopened bootstrap retains enrolled signer"
        (Bootstrap.capability_signer_public_key authority)
        (Bootstrap.signer_public_key
           (Yeokcham_v2_bootstrap_store.bootstrap reopened)))

let locked_unavailable_and_non_exportable_states_fail_closed () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let enroll availability =
        Custody.enroll
          ~service:(service (new_memory availability))
          ~root ~repository_id:(repository 'r') ~device_id:(device 'd')
          ~key_handle:(key_handle 'h') ~capability:(capability ())
      in
      Alcotest.(check bool)
        "locked Keychain rejects enrollment" true
        (has_error Custody.Keychain_locked (enroll Locked));
      Alcotest.(check bool)
        "unavailable Keychain rejects enrollment" true
        (has_error Custody.Keychain_unavailable (enroll Unavailable));
      Alcotest.(check bool)
        "non-exportable key does not fall back to plaintext" true
        (has_error Custody.Keychain_non_exportable_key (enroll Non_exportable));
      Alcotest.(check bool)
        "unsupported exportable key rejects enrollment" true
        (has_error Custody.Keychain_unsupported_key_item (enroll Unsupported)))

let malformed_mismatched_and_occupied_items_refuse_overwrite () =
  with_root (fun first_root ->
      with_root (fun second_root ->
          ignore
            (Store.init ~root:first_root |> require_ok Store.error_to_string);
          ignore
            (Store.init ~root:second_root |> require_ok Store.error_to_string);
          let memory = new_memory Available in
          let original = capability () in
          ignore
            (Custody.enroll ~service:(service memory) ~root:first_root
               ~repository_id:(repository 'r') ~device_id:(device 'd')
               ~key_handle:(key_handle 'h') ~capability:original
            |> require_ok Custody.error_to_string);
          memory.stored <- Some "malformed Keychain capability";
          Alcotest.(check bool)
            "malformed Keychain material refuses opening" true
            (has_error Custody.Invalid_keychain_material
               (Custody.open_repository ~service:(service memory)
                  ~root:first_root));
          let other_memory = new_memory Available in
          let other = capability ~encryption:'x' ~address:'y' ~signing:'z' () in
          ignore
            (Custody.enroll ~service:(service other_memory) ~root:second_root
               ~repository_id:(repository 's') ~device_id:(device 'e')
               ~key_handle:(key_handle 'j') ~capability:other
            |> require_ok Custody.error_to_string);
          memory.stored <- other_memory.stored;
          Alcotest.(check bool)
            "bootstrap-mismatched Keychain material refuses opening" true
            (Result.is_error
               (Custody.open_repository ~service:(service memory)
                  ~root:first_root));
          memory.stored <- other_memory.stored;
          memory.store_calls <- 0;
          let occupied =
            Custody.enroll ~service:(service memory) ~root:first_root
              ~repository_id:(repository 'r') ~device_id:(device 'd')
              ~key_handle:(key_handle 'h') ~capability:original
          in
          Alcotest.(check bool)
            "different existing capability rejects before Keychain store" true
            (has_error Custody.Keychain_handle_in_use occupied);
          Alcotest.(check int)
            "occupied item is never overwritten" 0 memory.store_calls))

let concurrent_create_race_rechecks_existing_keychain_item () =
  with_root (fun root ->
      with_root (fun other_root ->
          ignore (Store.init ~root |> require_ok Store.error_to_string);
          ignore
            (Store.init ~root:other_root |> require_ok Store.error_to_string);
          let other_memory = new_memory Available in
          let other = capability ~encryption:'x' ~address:'y' ~signing:'z' () in
          ignore
            (Custody.enroll ~service:(service other_memory) ~root:other_root
               ~repository_id:(repository 's') ~device_id:(device 'e')
               ~key_handle:(key_handle 'j') ~capability:other
            |> require_ok Custody.error_to_string);
          let raced_value = ref None in
          let store_calls = ref 0 in
          let racing_service =
            Custody.service
              ~backend:
                {
                  Custody.lookup =
                    (fun _ ->
                      match !raced_value with
                      | None -> Custody.Missing
                      | Some value -> Custody.Found value);
                  Custody.store =
                    (fun _ _ ->
                      incr store_calls;
                      raced_value := other_memory.stored;
                      Custody.Already_present);
                  Custody.remove = (fun _ -> Custody.Remove_missing);
                }
          in
          let result =
            Custody.enroll ~service:racing_service ~root
              ~repository_id:(repository 'r') ~device_id:(device 'd')
              ~key_handle:(key_handle 'h') ~capability:(capability ())
          in
          Alcotest.(check bool)
            "create race rechecks rather than accepting another capability" true
            (has_error Custody.Keychain_handle_in_use result);
          Alcotest.(check int) "race causes one attempted create" 1 !store_calls))

let removal_changes_only_local_keychain_state () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let memory = new_memory Available in
      let authority = capability () in
      ignore
        (Custody.enroll ~service:(service memory) ~root
           ~repository_id:(repository 'r') ~device_id:(device 'd')
           ~key_handle:(key_handle 'h') ~capability:authority
        |> require_ok Custody.error_to_string);
      let before = read_file (local_bootstrap_path root) in
      Custody.remove_enrollment ~service:(service memory) ~root
      |> require_ok Custody.error_to_string;
      Alcotest.(check int)
        "one local Keychain item is removed" 1 memory.remove_calls;
      Alcotest.(check string)
        "removal leaves signed bootstrap byte-for-byte" before
        (read_file (local_bootstrap_path root));
      Alcotest.(check bool)
        "opening after local removal reports missing item" true
        (has_error Custody.Keychain_item_missing
           (Custody.open_repository ~service:(service memory) ~root)))

let () =
  Alcotest.run "V2 macOS Keychain custody core"
    [
      ( "unit",
        [
          Alcotest.test_case "public Keychain account vector is canonical"
            `Quick account_vector_is_canonical;
          Alcotest.test_case
            "enrollment reopens without repository private material" `Quick
            enrollment_reopens_without_repository_private_material;
          Alcotest.test_case
            "locked unavailable and non-exportable states fail closed" `Quick
            locked_unavailable_and_non_exportable_states_fail_closed;
          Alcotest.test_case
            "malformed mismatched and occupied items refuse overwrite" `Quick
            malformed_mismatched_and_occupied_items_refuse_overwrite;
          Alcotest.test_case
            "concurrent create race rechecks the existing Keychain item" `Quick
            concurrent_create_race_rechecks_existing_keychain_item;
          Alcotest.test_case "removal changes only local Keychain state" `Quick
            removal_changes_only_local_keychain_state;
        ] );
    ]
