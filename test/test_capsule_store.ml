module Capsule = Paengi_capsule
module Capsule_store = Paengi_capsule_store
module Envelope = Paengi_envelope
module Golden = Paengi_testkit.Golden_fixture
module Id = Paengi_id
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

[@@@warning "-4"]

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let stored_id seed = Store.Stored_object_id.of_raw_bytes (raw_id seed) |> Option.get
let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok
let revision_id seed = Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok
let snapshot_id seed = Snapshot.Snapshot.of_stored_object_id (stored_id seed)
let content_id seed = Snapshot.Content.of_stored_object_id (stored_id seed)
let checkpoint_id seed = Scratch.Checkpoint_id.of_stored_object_id (stored_id seed)

let fixture () =
  let capsule =
    Capsule_store.create_capsule ~id:(capsule_id 1) ~title:"initial title"
      ~description:"initial description" ~created_at:11L
    |> require_ok Capsule_store.error_to_string
  in
  let transition : Capsule.exact_file_transition =
    {
      Capsule.transition_path = [ "src"; "main" ];
      expected_entry = None;
      replacement_entry =
        Some
          (Scratch.File
             { mode = Snapshot.Executable; content = content_id 40 });
    }
  in
  let parent : Capsule_store.parent_link =
    { Capsule_store.revision = revision_id 2; object_id = stored_id 3 }
  in
  let dependency =
    Capsule.Requires_capsule
      { capsule = capsule_id 8; revision = Some (revision_id 9) }
  in
  let evidence : Capsule.validation_evidence =
    {
      Capsule.command = [ "dune"; "runtest" ];
      environment_fingerprint = Some "host-a";
      snapshot = snapshot_id 6;
      status = Capsule.Passed;
      stdout_digest = Some (content_id 7);
      stderr_digest = None;
      started_at = 12L;
      duration_ms = 13L;
    }
  in
  let revision =
    Capsule_store.create_revision ~capsule ~parent:(Some parent)
      ~declared_base:(snapshot_id 4) ~expected_result:(snapshot_id 5)
      ~operations:[ Capsule.Exact_file_transition transition ] ~dependencies:[ dependency ]
      ~evidence:[ evidence ]
      ~boundaries:[ { Capsule_store.source = checkpoint_id 10; target = checkpoint_id 11 } ]
      ~provenance:Capsule_store.Folded ~created_at:14L
    |> require_ok Capsule_store.error_to_string
  in
  let current =
    Capsule_store.make_current_ref ~generation:3L ~capsule:(Capsule_store.capsule_id capsule)
      ~capsule_object:(stored_id 12) ~revision:(Capsule_store.revision_id revision)
      ~revision_object:(stored_id 13)
    |> require_ok Capsule_store.error_to_string
  in
  (capsule, revision, current)

let golden name =
  let candidates = [ Filename.concat "golden" name; Filename.concat "test/golden" name ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> Golden.read_lower_hex_file path |> require_ok Fun.id
  | None -> Alcotest.fail ("missing golden fixture: " ^ name)

let with_store run =
  let root = Filename.temp_file "paengi-capsule-store-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
        Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      run store)

let schemas_have_canonical_goldens_and_inverse_decoders () =
  with_store (fun store ->
      let capsule, revision, current = fixture () in
      let capsule_object =
        Capsule_store.store_capsule store capsule
        |> require_ok Capsule_store.error_to_string
      in
      let revision_object =
        Capsule_store.store_revision store revision
        |> require_ok Capsule_store.error_to_string
      in
      let envelope object_id =
        Store.get store object_id |> require_ok Store.error_to_string |> Envelope.encode
      in
      Alcotest.(check string)
        "capsule golden" (golden "capsule-v1.peng.hex") (envelope capsule_object);
      Alcotest.(check string)
        "revision golden" (golden "capsule-revision-v1.peng.hex")
        (envelope revision_object);
      Alcotest.(check string)
        "current ref golden" (golden "capsule-current-v1.ref.hex")
        (Capsule_store.encode_current_ref current);
      let loaded_capsule =
        Capsule_store.load_capsule store capsule_object
        |> require_ok Capsule_store.error_to_string
      in
      let loaded_revision =
        Capsule_store.load_revision store revision_object
        |> require_ok Capsule_store.error_to_string
      in
      let decoded_current =
        Capsule_store.decode_current_ref (Capsule_store.encode_current_ref current)
        |> require_ok Capsule_store.error_to_string
      in
      Alcotest.(check bool)
        "capsule inverse ID" true
        (Id.Capsule_id.equal (Capsule_store.capsule_id capsule)
           (Capsule_store.capsule_id loaded_capsule));
      Alcotest.(check bool)
        "revision inverse logical ID" true
        (Id.Capsule_revision_id.equal (Capsule_store.revision_id revision)
           (Capsule_store.revision_id loaded_revision));
      Alcotest.(check bool)
        "current inverse logical ID" true
        (Id.Capsule_revision_id.equal (Capsule_store.current_revision current)
           (Capsule_store.current_revision decoded_current)))

let decoders_reject_noncanonical_and_wrong_types () =
  with_store (fun store ->
      let capsule, revision, current = fixture () in
      let capsule_object =
        Capsule_store.store_capsule store capsule
        |> require_ok Capsule_store.error_to_string
      in
      (match Capsule_store.load_revision store capsule_object with
      | Error (Capsule_store.Unexpected_object_type _) -> ()
      | Error error -> Alcotest.fail (Capsule_store.error_to_string error)
      | Ok _ -> Alcotest.fail "capsule object decoded as revision");
      let body = Capsule_store.encode_current_ref current in
      let malformed = body ^ "\000" in
      (match Capsule_store.decode_current_ref malformed with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "noncanonical ref bytes decoded");
      ignore revision)

let () =
  Alcotest.run "capsule persistent schemas"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical goldens and inverse decoders" `Quick
            schemas_have_canonical_goldens_and_inverse_decoders;
          Alcotest.test_case "wrong types and malformed bytes reject" `Quick
            decoders_reject_noncanonical_and_wrong_types;
        ] );
    ]
