module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository_id =
  V2_model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok V2_model.identity_error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let snapshot content =
  Model.Snapshot.of_entries
    [ Model.File_path (path [ "a" ], { Model.mode = Model.Regular; content }) ]
  |> require_ok Model.construction_error_to_string

let envelope ?(nonce_offset = 0) object_ =
  let nonce =
    Envelope.nonce_of_bytes
      (String.init 12 (fun index -> Char.chr (index + nonce_offset + 32)))
    |> require_ok Envelope.error_to_string
  in
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
    (Object.encode object_)
  |> require_ok Envelope.error_to_string

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

let with_v2_repository run =
  let root = Filename.temp_file "yeokcham-v2-object-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      run root repository)

let snapshot_publication_is_create_only_and_reopens () =
  with_v2_repository (fun root repository ->
      let original = snapshot "exact bytes\000and a symlink-free tree" in
      let candidate = envelope (Object.scratch_snapshot original) in
      let object_ref =
        match Object_store.publish repository ~envelope:candidate with
        | Ok (Object_store.Published object_ref) -> object_ref
        | Ok (Object_store.Already_published _) ->
            Alcotest.fail "first snapshot publication was already present"
        | Error error -> Alcotest.fail (Object_store.error_to_string error)
      in
      (match Object_store.publish repository ~envelope:candidate with
      | Ok (Object_store.Already_published repeated) ->
          Alcotest.(check bool)
            "exact retry keeps address" true
            (V2_model.Opaque_object_ref.equal object_ref repeated)
      | Ok (Object_store.Published _) ->
          Alcotest.fail "snapshot retry wrote a second object"
      | Error error -> Alcotest.fail (Object_store.error_to_string error));
      let reopened =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      let loaded =
        Object_store.load reopened ~object_ref
        |> require_ok Object_store.error_to_string
      in
      match Object.snapshot loaded with
      | Some restored ->
          Alcotest.(check bool)
            "reopened object preserves exact snapshot" true
            (Model.Snapshot.equal original restored)
      | None -> Alcotest.fail "snapshot object reopened with the wrong kind")

let malformed_plaintext_does_not_publish () =
  with_v2_repository (fun _ repository ->
      let nonce =
        Envelope.nonce_of_bytes (String.make 12 'n')
        |> require_ok Envelope.error_to_string
      in
      let invalid =
        Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
          "not a V2 object frame"
        |> require_ok Envelope.error_to_string
      in
      let object_ref =
        Address.derive ~repository_id ~key:address_key ~envelope:invalid
      in
      Alcotest.(check bool)
        "malformed frame rejects before publication" true
        (Result.is_error (Object_store.publish repository ~envelope:invalid));
      Alcotest.(check bool)
        "rejected frame has no immutable object" false
        (Sys.file_exists (Object_store.object_path repository object_ref)))

let () =
  Alcotest.run "V2 typed encrypted object storage"
    [
      ( "unit",
        [
          Alcotest.test_case "snapshot publication is create-only and reopens"
            `Quick snapshot_publication_is_create_only_and_reopens;
          Alcotest.test_case "malformed plaintext does not publish" `Quick
            malformed_plaintext_does_not_publish;
        ] );
    ]
