module Bundle = Paengi_bundle
module Directory = Paengi_bundle_directory
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Exchange = Paengi_exchange
module Exchange_store = Paengi_exchange_store
module Store = Paengi_store

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_bundle result = require Bundle.error_to_string result
let require_directory result = require Directory.error_to_string result
let require_envelope result = require Envelope.creation_error_to_string result
let require_exchange result = require Exchange_store.error_to_string result
let require_store result = require Store.error_to_string result

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let key =
  Bundle.key_of_bytes (String.init 32 (fun index -> Char.chr (index + 1)))
  |> require_bundle

let session =
  Exchange.session_id_of_bytes "decentral-sync-1"
  |> require Exchange.error_to_string

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
  let root = Filename.temp_file "paengi-decentralised-sync-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  let shared = Filename.concat root "shared" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Unix.mkdir shared 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require_store in
      let destination = Store.init ~root:destination_root |> require_store in
      run source destination shared)

let set_ref repository content =
  Store.put repository content |> require_store |> fun target ->
  Store.compare_and_swap_ref repository ~name:"scratch-head" ~expected:None
    ~target:(Some target)
  |> require_store

let assert_ref repository expected label =
  Alcotest.(check bool)
    label true
    (Store.read_ref repository ~name:"scratch-head"
    |> require_store
    |> Option.exists (Store.Mutable_ref.equal expected))

let assert_envelope repository object_id expected label =
  Alcotest.(check string)
    label (Envelope.encode expected)
    (Store.get repository object_id |> require_store |> Envelope.encode)

let direct_and_offline_transfer_preserve_refs () =
  with_repositories (fun source destination shared ->
      let source_ref = set_ref source (content "source-head") in
      let destination_ref = set_ref destination (content "destination-head") in
      let direct = content "direct-object" in
      let direct_id = Store.put source direct |> require_store in
      let direct_outcome =
        Exchange_store.transfer ~source ~destination ~session_id:session
          ~object_ids:[ direct_id ] ()
        |> require_exchange
      in
      Alcotest.(check int)
        "one direct object transfers" 1
        (List.length direct_outcome.Exchange_store.transferred);
      assert_envelope destination direct_id direct "direct bytes are exact";
      assert_ref source source_ref "source ref survives direct exchange";
      assert_ref destination destination_ref
        "destination ref survives direct exchange";
      let offline = content "offline-object" in
      let offline_id = Store.put source offline |> require_store in
      let complete =
        Directory.export ~directory:shared ~repository:source ~key
          ~object_ids:[ offline_id ]
        |> require_directory
      in
      let inspection = Directory.inspect ~key complete |> require_directory in
      Alcotest.(check int)
        "one object is inspected before import" 1
        (List.length (Directory.inspection_object_ids inspection));
      let imported =
        Directory.import ~repository:destination ~key complete
        |> require_directory
      in
      Alcotest.(check int) "one offline object imports" 1 (List.length imported);
      assert_envelope destination offline_id offline "offline bytes are exact";
      assert_ref source source_ref "source ref survives bundle export";
      assert_ref destination destination_ref
        "destination ref survives bundle import")

let () =
  Alcotest.run "decentralised local synchronisation"
    [
      ( "fixture",
        [
          Alcotest.test_case "direct and offline transfer preserve refs" `Quick
            direct_and_offline_transfer_preserve_refs;
        ] );
    ]
