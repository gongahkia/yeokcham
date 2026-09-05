module Golden = Yeokcham_testkit.Golden_fixture
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Model = Yeokcham_v1_model
module Store = Yeokcham_store
module V1_store = Yeokcham_v1_store
module Trust = Yeokcham_v1_trust

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> require_ok Fun.id

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
    ~username:(id Model.Username.of_string "alice")
    ~initial_snapshot:(id Model.Snapshot_id.of_string "snapshot-base")
    ~initial_draft:(id Model.Draft_id.of_string "draft-one")
    ~title:"fixture"

let snapshot value = id Model.Snapshot_id.of_string value

let capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let collaborative_project () =
  let repository =
    Trust.Repository_id.of_string
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> Result.get_ok
  in
  let signing_capability = capability 'a' in
  let device =
    signing_capability |> Trust.signing_public_key |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let certificate =
    Trust.root_certificate ~repository ~device signing_capability
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.verify_membership ~repository [ certificate ]
    |> require_ok Trust.error_to_string
  in
  let recovery_capability = capability 'r' in
  let recovery_device =
    recovery_capability |> Trust.signing_public_key
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id certificate)
      ~recovery_device signing_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.verify_authority ~membership [ epoch ]
    |> require_ok Trust.error_to_string
  in
  let project =
    Model.init ~creator:(Trust.device_id device)
      ~username:(id Model.Username.of_string "alice")
      ~initial_snapshot:(snapshot "snapshot-base")
      ~initial_draft:(id Model.Draft_id.of_string "draft-one")
      ~title:"fixture"
  in
  let collaboration =
    V1_store.collaboration_with_authority ~authority ~revisions:[]
      ~local_certificate:(Trust.certificate_id certificate)
      ~authorizations:[] ~adoptions:[]
    |> require_ok V1_store.error_to_string
  in
  (project, collaboration)

let initialization_writes_and_reopens_an_immutable_state () =
  with_directory "yeokcham-v1-store-" (fun root ->
      let repository =
        V1_store.init ~root ~project:(project ())
        |> require_ok V1_store.error_to_string
      in
      let loaded =
        V1_store.load repository |> require_ok V1_store.error_to_string
      in
      Alcotest.(check bool)
        "loaded project equals initialized project" true
        (Model.export loaded.V1_store.project = Model.export (project ()));
      let reopened =
        V1_store.open_repository ~root |> require_ok V1_store.error_to_string
      in
      let reopened =
        V1_store.load reopened |> require_ok V1_store.error_to_string
      in
      Alcotest.(check bool)
        "reopened object identity is retained" true
        (Store.Stored_object_id.equal loaded.V1_store.object_id
           reopened.V1_store.object_id))

let stale_state_heads_cannot_overwrite_newer_state () =
  with_directory "yeokcham-v1-stale-" (fun root ->
      let repository =
        V1_store.init ~root ~project:(project ())
        |> require_ok V1_store.error_to_string
      in
      let first =
        V1_store.load repository |> require_ok V1_store.error_to_string
      in
      let stale =
        V1_store.load repository |> require_ok V1_store.error_to_string
      in
      let first_project =
        Model.checkpoint first.V1_store.project
          ~snapshot:(snapshot "snapshot-one")
      in
      let saved =
        V1_store.save repository ~expected:first.V1_store.head
          ~project:first_project
        |> require_ok V1_store.error_to_string
      in
      Alcotest.(check bool)
        "save advances the mutable head" false
        (Store.Mutable_ref.equal first.V1_store.head saved.V1_store.head);
      let stale_project =
        Model.checkpoint stale.V1_store.project
          ~snapshot:(snapshot "snapshot-two")
      in
      match
        V1_store.save repository ~expected:stale.V1_store.head
          ~project:stale_project
      with
      | Error error ->
          Alcotest.(check bool)
            "stale writer receives compare-and-swap failure" true
            (String.starts_with
               ~prefix:"mutable ref v1-project-state changed concurrently"
               (V1_store.error_to_string error))
      | Ok _ -> Alcotest.fail "stale writer replaced the current head")

let wrong_object_type_is_rejected_at_the_state_head () =
  with_directory "yeokcham-v1-wrong-type-" (fun root ->
      let repository =
        V1_store.init ~root ~project:(project ())
        |> require_ok V1_store.error_to_string
      in
      let current =
        V1_store.load repository |> require_ok V1_store.error_to_string
      in
      let envelope =
        Envelope.create ~object_type:Envelope.Content
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features
          ~payload:(Encoding.bytes "not a V1 state")
          ()
        |> require_ok Envelope.creation_error_to_string
      in
      let wrong_object =
        Store.put (V1_store.underlying_store repository) envelope
        |> require_ok Store.error_to_string
      in
      Store.compare_and_swap_ref
        (V1_store.underlying_store repository)
        ~name:V1_store.state_head_name ~expected:(Some current.V1_store.head)
        ~target:(Some wrong_object)
      |> require_ok Store.error_to_string
      |> ignore;
      match V1_store.load repository with
      | Error error ->
          Alcotest.(check bool)
            "wrong type identifies its envelope code" true
            (String.ends_with ~suffix:"object type 1"
               (V1_store.error_to_string error))
      | Ok _ -> Alcotest.fail "accepted a non-V1 state object")

let initialization_refuses_existing_repositories () =
  with_directory "yeokcham-v1-existing-" (fun root ->
      Store.init ~root |> require_ok Store.error_to_string |> ignore;
      match V1_store.init ~root ~project:(project ()) with
      | Error error ->
          Alcotest.(check bool)
            "existing metadata is refused" true
            (String.starts_with
               ~prefix:"refusing to initialize V1 over an existing repository:"
               (V1_store.error_to_string error))
      | Ok _ -> Alcotest.fail "initialized V1 over an existing repository")

let interrupted_object_staging_never_publishes_a_partial_object () =
  with_directory "yeokcham-v1-store-interrupted-put-" (fun root ->
      let repository = Store.init ~root |> require_ok Store.error_to_string in
      let envelope =
        Envelope.create ~object_type:Envelope.Content
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features
          ~payload:(Encoding.bytes "interrupted repair staging")
          ()
        |> require_ok Envelope.creation_error_to_string
      in
      let object_id = Store.id_of_envelope envelope in
      (try
         ignore
           (Store.put ~after_staging:(fun () -> raise Exit) repository envelope);
         Alcotest.fail "interrupted staging returned a publication result"
       with Exit -> ());
      Alcotest.(check bool)
        "interrupted staging has no visible immutable object" false
        (Sys.file_exists (Store.object_path repository object_id));
      let directory =
        Filename.dirname (Store.object_path repository object_id)
      in
      let temporary_prefix =
        "."
        ^ Filename.basename (Store.object_path repository object_id)
        ^ ".tmp-"
      in
      Alcotest.(check bool)
        "interrupted staging retains inspectable temporary evidence" true
        (Sys.readdir directory
        |> Array.exists (String.starts_with ~prefix:temporary_prefix)))

let collaborative_state_cannot_be_downgraded_to_a_bare_record () =
  with_directory "yeokcham-v1-collaboration-save-" (fun root ->
      let project, collaboration = collaborative_project () in
      let repository =
        V1_store.init_collaborative ~root ~project ~collaboration
        |> require_ok V1_store.error_to_string
      in
      let loaded =
        V1_store.load repository |> require_ok V1_store.error_to_string
      in
      Alcotest.(check bool)
        "collaboration is present" true
        (Option.is_some loaded.V1_store.collaboration);
      let state_bytes =
        Store.get
          (V1_store.underlying_store repository)
          loaded.V1_store.object_id
        |> require_ok Store.error_to_string
        |> Envelope.payload |> Encoding.encode
      in
      Alcotest.(check string)
        "collaboration wrapper bytes retain their golden encoding"
        (Golden.refresh_lower_hex_file
           (golden_path "v1/collaboration-state-v1.cbor.hex")
           state_bytes
        |> require_ok Fun.id)
        state_bytes;
      match
        V1_store.save repository ~expected:loaded.V1_store.head
          ~project:loaded.V1_store.project
      with
      | Error error ->
          Alcotest.(check string)
            "bare save is rejected"
            "a signed V1 collaboration state must be saved with its verified \
             collaboration records"
            (V1_store.error_to_string error)
      | Ok _ -> Alcotest.fail "bare save discarded signed collaboration state")

let () =
  Alcotest.run "V1 store"
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
          Alcotest.test_case
            "interrupted object staging never publishes a partial object" `Quick
            interrupted_object_staging_never_publishes_a_partial_object;
          Alcotest.test_case
            "collaborative state requires collaboration-aware save" `Quick
            collaborative_state_cannot_be_downgraded_to_a_bare_record;
        ] );
    ]
