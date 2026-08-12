module Bootstrap = Yeokcham_v2_bootstrap
module Keychain = Yeokcham_v2_macos_keychain
module Model = Yeokcham_v2_model
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> failwith (render error)

let repository_id =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let device_id =
  Model.Device_id.of_bytes (String.make 32 'd')
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
  let root = Filename.temp_file "yeokcham-v2-macos-keychain-native-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let contains ~needle haystack =
  let length = String.length needle in
  let rec search offset =
    offset + length <= String.length haystack
    && (String.equal (String.sub haystack offset length) needle
       || search (offset + 1))
  in
  length > 0 && search 0

let expect_missing = function
  | Ok _ -> failwith "native macOS Keychain test item remained after removal"
  | Error error ->
      if
        String.equal
          (Keychain.error_to_string Keychain.Keychain_item_missing)
          (Keychain.error_to_string error)
      then ()
      else
        failwith
          ("expected missing macOS Keychain item after removal: "
          ^ Keychain.error_to_string error)

let run () =
  if Sys.getenv_opt "YEOKCHAM_RUN_KEYCHAIN_INTEGRATION" <> Some "1" then
    failwith
      "set YEOKCHAM_RUN_KEYCHAIN_INTEGRATION=1 to permit the native macOS \
       Keychain integration check";
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let service = Keychain.default_service () in
      let capability =
        Keychain.generate_capability () |> require_ok Keychain.error_to_string
      in
      let key_handle =
        Keychain.generate_key_handle () |> require_ok Keychain.error_to_string
      in
      let created = ref false in
      Fun.protect
        ~finally:(fun () ->
          if !created then ignore (Keychain.remove_enrollment ~service ~root))
        (fun () ->
          let enrollment =
            Keychain.enroll ~service ~root ~repository_id ~device_id ~key_handle
              ~capability
            |> require_ok Keychain.error_to_string
          in
          (match enrollment.Keychain.initialization with
          | Keychain.Initialized -> created := true
          | Keychain.Already_initialized ->
              failwith "random native macOS Keychain handle was occupied");
          let bootstrap_bytes =
            In_channel.with_open_bin
              (Filename.concat root
                 ".yeokcham/bootstrap/local-bootstrap-v2.cbor")
              In_channel.input_all
          in
          let encryption_key, address_key, signing_key =
            Bootstrap.secret_material capability
          in
          List.iter
            (fun secret ->
              if contains ~needle:secret bootstrap_bytes then
                failwith
                  "native macOS Keychain integration wrote private capability \
                   material to the bootstrap")
            [ encryption_key; address_key; signing_key ];
          ignore
            (Keychain.open_repository ~service ~root
            |> require_ok Keychain.error_to_string);
          Keychain.remove_enrollment ~service ~root
          |> require_ok Keychain.error_to_string;
          created := false;
          Keychain.open_repository ~service ~root |> expect_missing))

let () = run ()
