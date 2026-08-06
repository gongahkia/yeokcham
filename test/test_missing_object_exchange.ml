module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Exchange = Paengi_exchange
module Exchange_store = Paengi_exchange_store
module Store = Paengi_store

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_envelope result = require Envelope.creation_error_to_string result
let require_exchange result = require Exchange_store.error_to_string result
let require_store result = require Store.error_to_string result

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

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

let with_repositories run =
  let root = Filename.temp_file "paengi-missing-object-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require_store in
      let destination = Store.init ~root:destination_root |> require_store in
      run source destination)

let session =
  Exchange.session_id_of_bytes "missing-objectv1"
  |> require Exchange.error_to_string

let transfer source destination object_ids =
  Exchange_store.transfer ~source ~destination ~session_id:session
    ~object_ids:(List.sort Store.Stored_object_id.compare object_ids)
    ()
  |> require_exchange

let missing_only_exchange_is_restart_safe () =
  with_repositories (fun source destination ->
      let common = Store.put source (content "common") |> require_store in
      let missing = Store.put source (content "missing") |> require_store in
      let copied = Store.put destination (content "common") |> require_store in
      Alcotest.(check bool)
        "common object has the same identity" true
        (Store.Stored_object_id.equal common copied);
      let before = Unix.stat (Store.object_path destination common) in
      let retained =
        Store.put destination (content "retained") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let outcome = transfer source destination [ common; missing ] in
      Alcotest.(check int)
        "only missing object requested" 1 outcome.Exchange_store.requested;
      Alcotest.(check int)
        "only missing object transferred" 1
        (List.length outcome.Exchange_store.transferred);
      let after = Unix.stat (Store.object_path destination common) in
      Alcotest.(check int)
        "existing object inode is unchanged" before.Unix.st_ino
        after.Unix.st_ino;
      let destination =
        Store.open_repository ~root:(Store.root destination) |> require_store
      in
      let retry = transfer source destination [ common; missing ] in
      Alcotest.(check int)
        "retry requests nothing" 0 retry.Exchange_store.requested;
      Alcotest.(check int)
        "retry transfers nothing" 0
        (List.length retry.Exchange_store.transferred);
      Alcotest.(check bool)
        "application ref is unchanged" true
        (Store.read_ref destination ~name:"scratch-head"
        |> require_store
        |> Option.exists (Store.Mutable_ref.equal reference)))

let corrupt_source_rejects_without_destination_write () =
  with_repositories (fun source destination ->
      let object_id = Store.put source (content "source") |> require_store in
      let retained =
        Store.put destination (content "retained") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let output = open_out_bin (Store.object_path source object_id) in
      Fun.protect
        ~finally:(fun () -> close_out_noerr output)
        (fun () -> output_string output "corrupt");
      Alcotest.(check bool)
        "corruption is structured" true
        (Result.is_error
           (Exchange_store.transfer ~source ~destination ~session_id:session
              ~object_ids:[ object_id ] ()));
      Alcotest.(check bool)
        "corrupt object is absent" true
        (Result.is_error (Store.get destination object_id));
      Alcotest.(check bool)
        "ref is unchanged" true
        (Store.read_ref destination ~name:"scratch-head"
        |> require_store
        |> Option.exists (Store.Mutable_ref.equal reference)))

let () =
  Alcotest.run "missing immutable object exchange"
    [
      ( "exchange",
        [
          Alcotest.test_case "missing-only restart and no rewrite" `Quick
            missing_only_exchange_is_restart_safe;
          Alcotest.test_case "corrupt source rejects without destination write"
            `Quick corrupt_source_rejects_without_destination_write;
        ] );
    ]
