module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Model = Yeokcham_v4_model
module Store = Yeokcham_store
module V4_store = Yeokcham_v4_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

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

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let id parser value = parser value |> Result.get_ok

let project () =
  Model.init
    ~creator:(id Model.Device_id.of_string "device-alice")
    ~initial_snapshot:(id Model.Snapshot_id.of_string "snapshot-base")
    ~initial_draft:(id Model.Draft_id.of_string "draft-one")
    ~title:"fixture"

let snapshot value = id Model.Snapshot_id.of_string value

let initialization_writes_and_reopens_an_immutable_state () =
  with_directory "yeokcham-v4-store-" (fun root ->
      let repository =
        V4_store.init ~root ~project:(project ())
        |> require_ok V4_store.error_to_string
      in
      let loaded =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      Alcotest.(check bool)
        "loaded project equals initialized project" true
        (Model.export loaded.V4_store.project = Model.export (project ()));
      let reopened =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let reopened =
        V4_store.load reopened |> require_ok V4_store.error_to_string
      in
      Alcotest.(check bool)
        "reopened object identity is retained" true
        (Store.Stored_object_id.equal loaded.V4_store.object_id
           reopened.V4_store.object_id))

let stale_state_heads_cannot_overwrite_newer_state () =
  with_directory "yeokcham-v4-stale-" (fun root ->
      let repository =
        V4_store.init ~root ~project:(project ())
        |> require_ok V4_store.error_to_string
      in
      let first =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      let stale =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      let first_project =
        Model.checkpoint first.V4_store.project
          ~snapshot:(snapshot "snapshot-one")
      in
      let saved =
        V4_store.save repository ~expected:first.V4_store.head
          ~project:first_project
        |> require_ok V4_store.error_to_string
      in
      Alcotest.(check bool)
        "save advances the mutable head" false
        (Store.Mutable_ref.equal first.V4_store.head saved.V4_store.head);
      let stale_project =
        Model.checkpoint stale.V4_store.project
          ~snapshot:(snapshot "snapshot-two")
      in
      match
        V4_store.save repository ~expected:stale.V4_store.head
          ~project:stale_project
      with
      | Error error ->
          Alcotest.(check bool)
            "stale writer receives compare-and-swap failure" true
            (String.starts_with
               ~prefix:"mutable ref v4-project-state changed concurrently"
               (V4_store.error_to_string error))
      | Ok _ -> Alcotest.fail "stale writer replaced the current head")

let wrong_object_type_is_rejected_at_the_state_head () =
  with_directory "yeokcham-v4-wrong-type-" (fun root ->
      let repository =
        V4_store.init ~root ~project:(project ())
        |> require_ok V4_store.error_to_string
      in
      let current =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      let envelope =
        Envelope.create ~object_type:Envelope.Content
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features
          ~payload:(Encoding.bytes "not a V4 state")
          ()
        |> require_ok Envelope.creation_error_to_string
      in
      let wrong_object =
        Store.put (V4_store.underlying_store repository) envelope
        |> require_ok Store.error_to_string
      in
      Store.compare_and_swap_ref
        (V4_store.underlying_store repository)
        ~name:V4_store.state_head_name ~expected:(Some current.V4_store.head)
        ~target:(Some wrong_object)
      |> require_ok Store.error_to_string
      |> ignore;
      match V4_store.load repository with
      | Error error ->
          Alcotest.(check bool)
            "wrong type identifies its envelope code" true
            (String.ends_with ~suffix:"object type 1"
               (V4_store.error_to_string error))
      | Ok _ -> Alcotest.fail "accepted a non-V4 state object")

let initialization_refuses_existing_repositories () =
  with_directory "yeokcham-v4-existing-" (fun root ->
      Store.init ~root |> require_ok Store.error_to_string |> ignore;
      match V4_store.init ~root ~project:(project ()) with
      | Error error ->
          Alcotest.(check bool)
            "existing metadata is refused" true
            (String.starts_with
               ~prefix:"refusing to initialize V4 over an existing repository:"
               (V4_store.error_to_string error))
      | Ok _ -> Alcotest.fail "initialized V4 over an existing repository")

let () =
  Alcotest.run "V4 store"
    [
      ( "state head",
        [
          Alcotest.test_case "initialization writes and reopens state" `Quick
            initialization_writes_and_reopens_an_immutable_state;
          Alcotest.test_case "stale state heads cannot overwrite" `Quick
            stale_state_heads_cannot_overwrite_newer_state;
          Alcotest.test_case "wrong state-head type is rejected" `Quick
            wrong_object_type_is_rejected_at_the_state_head;
          Alcotest.test_case "initialization refuses an existing repository"
            `Quick initialization_refuses_existing_repositories;
        ] );
    ]
