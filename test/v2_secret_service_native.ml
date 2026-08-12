module Bootstrap = Yeokcham_v2_bootstrap
module Model = Yeokcham_v2_model
module Secret_service = Yeokcham_v2_secret_service
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
  let root = Filename.temp_file "yeokcham-v2-secret-service-native-" "" in
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

let secret_tool = "/usr/bin/secret-tool"

let clear_item key_handle =
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close null)
    (fun () ->
      let arguments =
        [
          secret_tool;
          "clear";
          "application";
          "io.github.gongahkia.yeokcham";
          "schema";
          "v2-local-capability-1";
          "key-handle";
          Bootstrap.Key_handle.to_hex key_handle;
        ]
      in
      let process =
        Unix.create_process secret_tool (Array.of_list arguments) null null null
      in
      match Unix.waitpid [] process with
      | _, Unix.WEXITED 0 -> ()
      | _, Unix.WEXITED code ->
          failwith
            (Printf.sprintf
               "failed to clear the native Secret Service test item (exit %d)"
               code)
      | _, Unix.WSIGNALED signal | _, Unix.WSTOPPED signal ->
          failwith
            (Printf.sprintf "native Secret Service cleanup ended by signal %d"
               signal))

let expect_secret_missing = function
  | Ok _ -> failwith "native Secret Service test item remained after clear"
  | Error error ->
      if
        String.equal
          (Secret_service.error_to_string Secret_service.Secret_missing)
          (Secret_service.error_to_string error)
      then ()
      else
        failwith
          ("expected missing Secret Service test item after clear: "
          ^ Secret_service.error_to_string error)

let run () =
  if Sys.getenv_opt "YEOKCHAM_RUN_SECRET_SERVICE_INTEGRATION" <> Some "1" then
    failwith
      "set YEOKCHAM_RUN_SECRET_SERVICE_INTEGRATION=1 to permit the native \
       Secret Service integration check";
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let service = Secret_service.default_service () in
      let capability =
        Secret_service.generate_capability ()
        |> require_ok Secret_service.error_to_string
      in
      let key_handle =
        Secret_service.generate_key_handle ()
        |> require_ok Secret_service.error_to_string
      in
      let created = ref false in
      Fun.protect
        ~finally:(fun () -> if !created then clear_item key_handle)
        (fun () ->
          let enrollment =
            Secret_service.enroll ~service ~root ~repository_id ~device_id
              ~key_handle ~capability
            |> require_ok Secret_service.error_to_string
          in
          let { Secret_service.initialization; repository = _ } = enrollment in
          (match initialization with
          | Secret_service.Initialized -> created := true
          | Secret_service.Already_initialized ->
              failwith "random native Secret Service key handle was occupied");
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
                  "native Secret Service integration wrote private capability \
                   material to the bootstrap")
            [ encryption_key; address_key; signing_key ];
          ignore
            (Secret_service.open_repository ~service ~root
            |> require_ok Secret_service.error_to_string);
          clear_item key_handle;
          created := false;
          Secret_service.open_repository ~service ~root |> expect_secret_missing))

let () = run ()
