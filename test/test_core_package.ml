module Package = Yeokcham_v1_package
module P = Package.Core
module S = Yeokcham_v1_store
module L = S.Local
module C = Yeokcham_v1_model.Core
module M = Yeokcham_v1_model
module T = Yeokcham_v1_trust
module R = Yeokcham_v1_record.Core
module Raw = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module Service = Yeokcham_v1_local_service
module Composition = Yeokcham_v1_composition
module Pages = Yeokcham_v1_pages
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Transport = Yeokcham_v1_transport
module Outbox = Transport.Core_outbox
module Outbound = Service.Core_outbound

[@@@warning "-42"]

let ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let package result = ok Package.error_to_string result
let model result = ok C.error_to_string result
let service result = ok Service.error_to_string result

let reject = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "accepted invalid public package"

let read path = In_channel.with_open_bin path In_channel.input_all

let write path bytes =
  Out_channel.with_open_bin path (fun out -> output_string out bytes)

let contains bytes part =
  let rec loop i =
    i + String.length part <= String.length bytes
    && (String.sub bytes i (String.length part) = part || loop (i + 1))
  in
  loop 0

let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
    Array.iter
      (fun name -> remove (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path

let temporary f =
  let parent = Filename.temp_file "yeokcham-core-package-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  Fun.protect ~finally:(fun () -> remove parent) (fun () -> f parent)

let initialize root key =
  Unix.mkdir root 0o700;
  write (root ^ "/private.txt") "PRIVATE SENTINEL DO NOT EXPORT\000\255";
  write (root ^ "/note.txt") "initial private note\n";
  let capability =
    T.signing_capability_of_private_key (String.make 32 key)
    |> ok T.error_to_string
  in
  let device =
    T.device_of_public_key (T.signing_public_key capability)
    |> ok T.error_to_string
  in
  let repo = T.Repository_id.of_string (String.make 64 'a') |> ok Fun.id in
  let certificate =
    T.root_certificate ~repository:repo ~device capability
    |> ok T.error_to_string
  in
  let membership =
    T.verify_membership ~repository:repo [ certificate ] |> ok T.error_to_string
  in
  let recovery =
    T.signing_capability_of_private_key (String.make 32 'r')
    |> ok T.error_to_string
  in
  let recovery_device =
    T.device_of_public_key (T.signing_public_key recovery)
    |> ok T.error_to_string
  in
  let epoch =
    T.root_epoch ~membership
      ~root_certificate:(T.certificate_id certificate)
      ~recovery_device capability
    |> ok T.error_to_string
  in
  let authority =
    T.verify_authority ~membership [ epoch ] |> ok T.error_to_string
  in
  let collaboration =
    S.collaboration_with_authority ~authority ~revisions:[]
      ~local_certificate:(T.certificate_id certificate)
      ~authorizations:[] ~adoptions:[]
    |> ok S.error_to_string
  in
  let repository =
    S.init_local_collaborative_with ~root ~bootstrap:(fun store ->
        let local =
          L.initialize ~store ~authority
            ~certificate:(T.certificate_id certificate)
            ~signing_capability:capability ~cursor:0L
          |> ok Fun.id
        in
        let snapshot text =
          M.Snapshot_id.of_string text |> ok M.error_to_string
        in
        let captured, _ =
          Snapshot.scan ~root ~store |> ok Snapshot.error_to_string
        in
        let captured =
          Snapshot.Snapshot.stored_object_id captured
          |> Raw.Stored_object_id.to_hex |> snapshot
        in
        let project =
          M.init ~creator:(T.device_id device)
            ~username:(M.Username.of_string "alice" |> ok M.error_to_string)
            ~initial_snapshot:
              (snapshot (C.Object_id.to_hex (L.empty_snapshot local)))
            ~initial_draft:(M.Draft_id.of_string "work" |> ok M.error_to_string)
            ~title:"private"
        in
        Ok (M.checkpoint project ~snapshot:captured, collaboration, local))
    |> ok S.error_to_string
  in
  (repository, capability, authority)

let load repository = S.load repository |> ok S.error_to_string
let local loaded = Option.get loaded.S.local

let share root capability paths =
  Service.share_selected ~root ~paths ~update:None
    ~title:(Some "Public selected D") ~dry_run:false
    ~signing_capability:(Some capability)
  |> service

let create repository authority destination =
  let loaded = load repository in
  let local = local loaded in
  P.create
    ~source:(S.underlying_store repository)
    ~destination ~authority ~records:(L.record_objects local)
    ~selected_branch:(L.selected local).L.branch
    ~titles:
      (List.map
         (fun receipt -> (receipt.L.revision, receipt.L.title))
         (L.publications local))
  |> package

let copy_object source destination id =
  let bytes = Raw.get source id |> ok Raw.error_to_string |> Envelope.encode in
  write (destination ^ "/objects/" ^ Raw.Stored_object_id.to_hex id) bytes

let[@warning "-4"] public_closure_preserves_d_e_and_mixed_fidelity () =
  temporary (fun parent ->
      let root = parent ^ "/alice" in
      let repository, capability, authority = initialize root 'k' in
      write (root ^ "/note.txt") "shared D\r\n";
      write (root ^ "/opaque.bin")
        (String.init ((2 * 1024 * 1024) + 731) (fun i -> Char.chr (i mod 256)));
      write (root ^ "/run") "#!/bin/sh\nexit 0\n";
      Unix.chmod (root ^ "/run") 0o755;
      Unix.mkdir (root ^ "/empty") 0o700;
      Unix.symlink "note.txt" (root ^ "/link");
      let shared =
        share root capability
          [
            [ "note.txt" ]; [ "opaque.bin" ]; [ "run" ]; [ "empty" ]; [ "link" ];
          ]
      in
      write (root ^ "/note.txt") "shared D\r\nprivate later E\n";
      let plan =
        Service.Integrate.prepare ~root
          ~selected_revisions:[ Option.get shared.Service.Share.revision ]
          ~reconcile_heads:None
        |> ok Service.Integrate.error_to_string
      in
      let applied =
        Service.Integrate.apply ~root
          ~plan:(Yeokcham_v1_integration.id plan)
          ~signing_capability:(Some capability)
        |> ok Service.Integrate.error_to_string
      in
      let operation = Option.get applied.Service.Integrate.operation in
      let before = load repository in
      let destination = parent ^ "/public-package" in
      let artifact = create repository authority destination in
      Alcotest.(check bool)
        "export does not move any state/history root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "later private E remains live" "shared D\r\nprivate later E\n"
        (read (root ^ "/note.txt"));
      let ids = ref [] in
      Package.iter_artifact_objects artifact ~f:(fun id bytes ->
          ids := id :: !ids;
          Alcotest.(check bool)
            "private sentinel absent from every exported object" false
            (contains bytes "PRIVATE SENTINEL DO NOT EXPORT");
          Alcotest.(check bool)
            "private E absent from every exported object" false
            (contains bytes "private later E");
          Ok ())
      |> package;
      let private_ids =
        operation.L.Operation.plan_object
        :: List.map
             (fun receipt -> receipt.L.witness_root)
             (L.publications (local before))
      in
      List.iter
        (fun id ->
          Alcotest.(check bool)
            "private plans/correspondence pages excluded" false
            (List.exists (Raw.Stored_object_id.equal id) !ids))
        private_ids;
      let scope = C.pool_repository (L.pool (local before)) in
      let prepared =
        P.prepare ~package:destination ~repository:scope
          ~known_authority:(Some authority)
        |> package
      in
      Alcotest.(check int)
        "all public records included, not private operation rows"
        (List.length (L.record_objects (local before)))
        (List.length (P.prepared_records prepared));
      Alcotest.(check (list string))
        "public courier title survives" [ "Public selected D" ]
        (List.map snd (P.prepared_titles prepared));
      let target = parent ^ "/bob-objects" in
      Unix.mkdir target 0o700;
      write (target ^ "/unsaved.txt") "BOB PRIVATE WORK";
      let store = Raw.init ~root:target |> ok Raw.error_to_string in
      P.import_prepared ~destination:store prepared |> package;
      Alcotest.(check string)
        "immutable receipt never edits ordinary files" "BOB PRIVATE WORK"
        (read (target ^ "/unsaved.txt"));
      Alcotest.(check bool)
        "immutable receipt does not create a project head" false
        (Sys.file_exists (target ^ "/.yeokcham/refs/v1-project-state"));
      let accepted =
        Composition.Graph.accepted (P.prepared_pool prepared)
          operation.L.Operation.accepted
        |> ok Composition.Graph.error_to_string
      in
      let tree =
        Composition.load store accepted.C.result_snapshot
        |> ok Composition.error_to_string
      in
      let entries = Composition.entries tree in
      let content name =
        match List.assoc [ name ] entries with
        | Composition.File { content; _ } ->
            Snapshot.Content.load store content |> ok Snapshot.error_to_string
        | Composition.Directory -> Alcotest.fail "expected file"
      in
      Alcotest.(check string)
        "accepted public result is exact D" "shared D\r\n" (content "note.txt");
      Alcotest.(check string)
        "opaque bytes retained"
        (read (root ^ "/opaque.bin"))
        (content "opaque.bin");
      Alcotest.(check bool)
        "empty directory retained" true
        (List.assoc [ "empty" ] entries = Composition.Directory);
      Alcotest.(check bool)
        "executable distinction retained" true
        (match List.assoc [ "run" ] entries with
        | Composition.File { mode = Snapshot.Executable; _ } -> true
        | _ -> false);
      Alcotest.(check bool)
        "symlink target/mode retained" true
        (match List.assoc [ "link" ] entries with
        | Composition.File { mode = Snapshot.Symlink; _ } ->
            content "link" = "note.txt"
        | _ -> false))

let[@warning "-4"] reject_extra_private_object_even_in_canonical_inventory () =
  temporary (fun parent ->
      let root = parent ^ "/alice" in
      let repository, capability, authority = initialize root 'k' in
      write (root ^ "/note.txt") "shared D\n";
      share root capability [ [ "note.txt" ] ] |> ignore;
      let directory = parent ^ "/package" in
      let artifact = create repository authority directory in
      let loaded = load repository in
      let state = local loaded in
      let store = S.underlying_store repository in
      let repository_id = C.pool_repository (L.pool state) in
      let manifest =
        P.decode_manifest ~repository:repository_id
          (Package.artifact_manifest artifact)
        |> package
      in
      let namespace, old_inventory =
        List.hd (List.rev (P.metadata_roots manifest))
      in
      let snapshot =
        (Yeokcham_v1_undo.current loaded.S.history).Yeokcham_v1_undo.snapshot
      in
      let tree =
        Composition.load store
          (C.Object_id.of_hex (M.Snapshot_id.to_string snapshot) |> model)
        |> ok Composition.error_to_string
      in
      let private_id =
        match List.assoc [ "private.txt" ] (Composition.entries tree) with
        | Composition.File { content; _ } ->
            Snapshot.Content.stored_object_id content
        | Composition.Directory -> assert false
      in
      let private_bytes =
        Raw.get store private_id |> ok Raw.error_to_string |> Envelope.encode
      in
      let inventory = P.inventory store manifest |> package in
      let rows =
        List.map
          (fun (id, size) ->
            ( Raw.Stored_object_id.to_raw_bytes id,
              E.encode (E.integer (Int64.of_int size)) ))
          ((private_id, String.length private_bytes) :: inventory)
      in
      let new_inventory =
        Pages.store store ~namespace rows |> ok Pages.error_to_string
      in
      Pages.closure store ~namespace old_inventory
      |> ok Pages.error_to_string
      |> List.iter (fun id ->
          Unix.unlink (directory ^ "/objects/" ^ Raw.Stored_object_id.to_hex id));
      Pages.closure store ~namespace new_inventory
      |> ok Pages.error_to_string
      |> List.iter (copy_object store directory);
      copy_object store directory private_id;
      let fields =
        E.decode (Package.artifact_manifest artifact)
        |> ok E.decode_error_to_string
        |> function
        | E.Array fields -> fields
        | _ -> assert false
      in
      let altered =
        E.array
          (List.mapi
             (fun index value ->
               if index = 6 then
                 E.bytes (Raw.Stored_object_id.to_raw_bytes new_inventory)
               else value)
             fields)
        |> ok E.construction_error_to_string
        |> E.encode
      in
      write (directory ^ "/manifest.cbor") altered;
      match
        P.prepare ~package:directory ~repository:repository_id
          ~known_authority:(Some authority)
      with
      | Error (Package.Invalid_package detail) ->
          Alcotest.(check bool)
            "rejects semantic extra closure after structural verification" true
            (contains detail "exact public dependency closure")
      | Error error -> Alcotest.fail (Package.error_to_string error)
      | Ok _ -> Alcotest.fail "private blob accepted as public inventory")

let signed_false_result_and_foreign_authority_refuse () =
  temporary (fun parent ->
      let root = parent ^ "/alice" in
      let repository, capability, authority = initialize root 'k' in
      let shared = share root capability [ [ "note.txt" ] ] in
      let loaded = load repository in
      let local = local loaded in
      let store = S.underlying_store repository in
      let certificate =
        T.certificate_id
          (List.hd (T.certificates (T.authority_membership authority)))
      in
      let digest text = C.Digest.of_hex text |> model in
      let context =
        C.make_context
          ~repository:(C.pool_repository (L.pool local))
          ~author_certificate:(digest certificate)
          ~authority_heads:(List.map digest (T.authority_heads authority))
          ~display_time:None
        |> model
      in
      let result =
        (Yeokcham_v1_undo.current loaded.S.history).Yeokcham_v1_undo.snapshot
        |> M.Snapshot_id.to_string |> C.Object_id.of_hex |> model
      in
      let version =
        C.make_accepted_version ~branch:(L.selected local).L.branch
          ~accepted_parents:[ (L.selected local).L.basis ]
          ~chosen_revisions:[ Option.get shared.Service.Share.revision ]
          ~resolutions:[] ~result_snapshot:result
          ~composition_profile:"line-hunks-v1" ~policy_heads:[]
          ~review_evidence:[]
        |> model
      in
      let signed =
        T.Core.sign authority capability
          (C.make_body ~context ~payload:(C.Accepted_version version))
        |> ok T.Core.error_to_string
      in
      let id = R.id signed |> ok R.error_to_string in
      let object_id =
        R.encode signed |> ok R.error_to_string |> Envelope.decode
        |> ok Envelope.decode_error_to_string
        |> Raw.put store |> ok Raw.error_to_string
      in
      let destination = parent ^ "/invalid" in
      reject
        (P.create ~source:store ~destination ~authority
           ~records:((id, object_id) :: L.record_objects local)
           ~selected_branch:(L.selected local).L.branch ~titles:[]);
      Alcotest.(check bool)
        "false accepted result never creates artifact" false
        (Sys.file_exists destination);
      let other_repository, _, other_authority =
        initialize (parent ^ "/other-root") 'b'
      in
      let other_dir = parent ^ "/other-package" in
      create other_repository other_authority other_dir |> ignore;
      reject
        (P.prepare ~package:other_dir
           ~repository:(C.pool_repository (L.pool local))
           ~known_authority:(Some authority)))

let[@warning "-4"] malformed_controls_and_missing_objects_refuse () =
  temporary (fun parent ->
      let root = parent ^ "/alice" in
      let repository, _, authority = initialize root 'k' in
      let directory = parent ^ "/package" in
      let artifact = create repository authority directory in
      let scope = C.pool_repository (L.pool (local (load repository))) in
      reject
        (P.decode_manifest
           ~repository:(C.Repository_id.of_raw (String.make 32 'b') |> model)
           (Package.artifact_manifest artifact));
      let fields =
        E.decode (Package.artifact_manifest artifact)
        |> ok E.decode_error_to_string
        |> function
        | E.Array fields -> fields
        | _ -> assert false
      in
      List.iter
        (fun (index, value) ->
          let bytes =
            E.array
              (List.mapi
                 (fun at old -> if at = index then value else old)
                 fields)
            |> ok E.construction_error_to_string
            |> E.encode
          in
          reject (P.decode_manifest ~repository:scope bytes))
        [ (0, E.integer 99L); (2, E.bytes "short"); (3, E.bytes "short") ];
      reject
        (P.decode_manifest ~repository:scope
           (String.make (P.max_manifest_bytes + 1) 'x'));
      let object_file = Array.get (Sys.readdir (directory ^ "/objects")) 0 in
      Unix.unlink (directory ^ "/objects/" ^ object_file);
      reject
        (P.prepare ~package:directory ~repository:scope
           ~known_authority:(Some authority)))

let independent_manifest_vector () =
  let golden name =
    let path = "golden/core-package/" ^ name in
    read (if Sys.file_exists path then path else "test/" ^ path) |> String.trim
  in
  let expected = golden "manifest.hex" in
  let bytes =
    String.init
      (String.length expected / 2)
      (fun i -> Char.chr (int_of_string ("0x" ^ String.sub expected (i * 2) 2)))
  in
  let scope = C.Repository_id.of_raw (String.make 32 'a') |> model in
  let manifest = P.decode_manifest ~repository:scope bytes |> package in
  let hex bytes =
    String.init
      (String.length bytes * 2)
      (fun i ->
        let code = Char.code bytes.[i / 2] in
        "0123456789abcdef".[if i mod 2 = 0 then code lsr 4 else code land 15])
  in
  Alcotest.(check string)
    "independent exact ordered manifest" expected
    (P.encode_manifest manifest |> package |> hex);
  Alcotest.(check string)
    "independent plain courier manifest SHA-256"
    (golden "courier-manifest-id.hex")
    (Yeokcham_hash.Sha256.digest_string bytes
    |> Yeokcham_hash.Sha256.to_raw_string |> hex)

let receipt_fixture parent =
  let root = parent ^ "/receiver" in
  let repository, capability, authority = initialize root 'k' in
  let before = load repository in
  let store = S.underlying_store repository in
  let certificate = S.local_certificate (Option.get before.S.collaboration) in
  let make name state =
    L.create_branch ~store ~authority ~certificate
      ~signing_capability:capability ~name ~cursor:0L state
    |> ok Fun.id
  in
  let private_branch = make "local-work" (local before) in
  S.save_collaborative ~local:private_branch repository ~expected:before.S.head
    ~project:before.S.project
    ~collaboration:(Option.get before.S.collaboration)
  |> ok S.error_to_string |> ignore;
  let before = load repository in
  let remote = make "received-shared" (local before) in
  let directory = parent ^ "/incoming" in
  P.create ~source:store ~destination:directory ~authority
    ~records:(L.record_objects remote)
    ~selected_branch:(L.selected remote).L.branch ~titles:[]
  |> package |> ignore;
  write (root ^ "/private.txt") "UNSAVED RECEIVER PRIVATE WORK";
  (root, repository, capability, authority, before, directory, remote)

let cli root arguments =
  let binary =
    List.find Sys.file_exists
      [ "../bin/yeokcham_v1.exe"; "_build/default/bin/yeokcham_v1.exe" ]
  in
  let path = Filename.temp_file "yeokcham-core-receipt-cli-" "" in
  let errors = Filename.temp_file "yeokcham-core-receipt-cli-errors-" "" in
  Fun.protect
    ~finally:(fun () ->
      Unix.unlink path;
      Unix.unlink errors)
    (fun () ->
      let output = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let error_output =
        Unix.openfile errors [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      let child =
        Unix.create_process binary
          (Array.of_list ((binary :: arguments) @ [ "--root"; root ]))
          Unix.stdin output error_output
      in
      Unix.close output;
      Unix.close error_output;
      let _, status = Unix.waitpid [] child in
      (status, read path))

let[@warning "-4"] native_receipt_preserves_history_files_and_private_positions
    () =
  temporary (fun parent ->
      let root, repository, _, _, before, directory, remote =
        receipt_fixture parent
      in
      let received =
        Service.Core_receive.receive ~root ~package:directory
        |> ok Service.Core_receive.error_to_string
      in
      Alcotest.(check int)
        "two new signed records, no navigation" 2
        received.Service.Core_receive.records_added;
      Alcotest.(check int)
        "one newly known shared branch" 1
        received.Service.Core_receive.branches_added;
      let after = load repository in
      Alcotest.(check string)
        "complete private history and allocation unchanged"
        (Yeokcham_v1_undo.encode before.S.history |> ok Fun.id)
        (Yeokcham_v1_undo.encode after.S.history |> ok Fun.id);
      Alcotest.(check bool)
        "existing exact private working positions retained" true
        (L.positions (local before) = L.positions (local after));
      Alcotest.(check int)
        "shared discovery does not fabricate a private position" 2
        (List.length (L.positions (local after)));
      Alcotest.(check int)
        "all shared branches now visible" 3
        (List.length (L.branches (local after)));
      Alcotest.(check string)
        "unsaved bytes were not captured or replaced"
        "UNSAVED RECEIVER PRIVATE WORK"
        (read (root ^ "/private.txt"));
      Alcotest.(check bool)
        "public receipt matches exact declared records" true
        (L.record_objects (local after) = L.record_objects remote);
      let encoded = L.encode (local after) |> ok Fun.id in
      let version =
        E.decode encoded |> ok E.decode_error_to_string |> function
        | E.Array (E.Integer version :: _) -> version
        | _ -> assert false
      in
      Alcotest.(check int64)
        "known-only branches select explicit schema 4" 4L version;
      let listing = Service.branch_list ~root |> service in
      Alcotest.(check int)
        "branch listing distinguishes missing private position" 2
        (List.length listing.Service.private_positions);
      let status, json = cli root [ "branch"; "list"; "--format"; "json" ] in
      Alcotest.(check bool)
        "fresh branch CLI reads received state" true (status = Unix.WEXITED 0);
      let open Yojson.Safe.Util in
      let body = Yojson.Safe.from_string json in
      let branch =
        body |> member "data" |> member "branches" |> to_list
        |> List.find (fun branch ->
            branch |> member "names" |> to_list
            |> List.mem (`String "received-shared"))
      in
      Alcotest.(check bool)
        "JSON distinguishes known shared from private saved" true
        (member "local_state" branch = `String "known_shared"
        && member "private_position" branch = `Null);
      let status, plain = cli root [ "branch"; "list" ] in
      Alcotest.(check bool)
        "plain branch CLI identifies known-only work" true
        (status = Unix.WEXITED 0 && contains plain "local:known-shared");
      let status, json =
        cli root [ "switch"; "received-shared"; "--yes"; "--format"; "json" ]
      in
      Alcotest.(check bool)
        "unmaterialized branch choice refuses before files" true
        (status = Unix.WEXITED 3);
      Alcotest.(check bool)
        "choice has actionable domain error" true
        (Yojson.Safe.from_string json
        |> member "error" |> member "code"
        = `String "shared-branch-not-materialized");
      reject
        (Service.branch_switch ~root ~name:"received-shared" ~dry_run:false);
      let repeated =
        Service.Core_receive.receive ~root ~package:directory
        |> ok Service.Core_receive.error_to_string
      in
      Alcotest.(check bool)
        "identical receipt reports no-op" true
        repeated.Service.Core_receive.unchanged;
      Alcotest.(check bool)
        "retry publishes no additional root" true
        (Raw.Mutable_ref.equal after.S.head (load repository).S.head))

let[@warning "-4"] native_receipt_cannot_erase_working_positions_or_bypass_admission
    () =
  temporary (fun parent ->
      let root, repository, capability, authority, before, directory, _ =
        receipt_fixture parent
      in
      Service.Core_receive.receive ~root ~package:directory
      |> ok Service.Core_receive.error_to_string
      |> ignore;
      let loaded = load repository in
      let state = local loaded in
      let store = S.underlying_store repository in
      let selected = (L.selected state).L.branch in
      let fields =
        L.encode state |> ok Fun.id |> E.decode |> ok E.decode_error_to_string
        |> function
        | E.Array fields -> fields
        | _ -> assert false
      in
      let positions =
        match List.nth fields 4 with
        | E.Array positions -> positions
        | _ -> assert false
      in
      let kept =
        List.filter
          (function
            | E.Array (E.Bytes raw :: _) -> raw = C.Branch_id.to_raw selected
            | _ -> assert false)
          positions
      in
      let altered =
        E.array
          (List.mapi
             (fun index value ->
               if index = 4 then
                 E.array kept |> ok E.construction_error_to_string
               else value)
             fields)
        |> ok E.construction_error_to_string
        |> E.encode
      in
      let candidate = L.decode ~store ~authority altered |> ok Fun.id in
      reject (L.validate_update ~previous:state candidate);
      reject
        (S.save_collaborative ~local:candidate repository
           ~expected:loaded.S.head ~project:loaded.S.project
           ~collaboration:(Option.get loaded.S.collaboration));
      let legacy =
        E.array
          (E.integer 1L
          :: List.tl (List.filteri (fun index _ -> index < 5) fields))
        |> ok E.construction_error_to_string
        |> E.encode
      in
      reject (L.decode ~store ~authority legacy);
      let first = List.hd (L.record_objects state)
      and second = List.nth (L.record_objects state) 1 in
      reject
        (L.receive_records ~store ~authority
           ~records:[ (fst first, snd second) ]
           state);
      let digest text = C.Digest.of_hex text |> model in
      let certificate =
        S.local_certificate (Option.get loaded.S.collaboration)
      in
      let context =
        C.make_context
          ~repository:(C.pool_repository (L.pool state))
          ~author_certificate:(digest certificate)
          ~authority_heads:(List.map digest (T.authority_heads authority))
          ~display_time:None
        |> model
      in
      let version =
        C.make_accepted_version ~branch:selected
          ~accepted_parents:[ (L.selected state).L.basis ]
          ~chosen_revisions:[] ~resolutions:[]
          ~result_snapshot:(L.empty_snapshot state)
          ~composition_profile:"line-hunks-v1"
          ~policy_heads:[ C.Digest.of_raw (String.make 32 'p') |> model ]
          ~review_evidence:[]
        |> model
      in
      let signed =
        T.Core.sign authority capability
          (C.make_body ~context ~payload:(C.Accepted_version version))
        |> ok T.Core.error_to_string
      in
      let id = R.id signed |> ok R.error_to_string in
      let object_id =
        R.encode signed |> ok R.error_to_string |> Envelope.decode
        |> ok Envelope.decode_error_to_string
        |> Raw.put store |> ok Raw.error_to_string
      in
      (match
         L.receive_records ~store ~authority ~records:[ (id, object_id) ] state
       with
      | Error (L.Receive_trust (T.Core.Model_error (C.Unsupported_policy _))) ->
          ()
      | Error error -> Alcotest.fail (L.receive_error_to_string error)
      | Ok _ -> Alcotest.fail "required unsupported policy admitted");
      Alcotest.(check bool)
        "failed admission never changes saved private cursor" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head);
      Alcotest.(check bool)
        "pre-receipt local positions still retained" true
        (L.positions (local before) = L.positions (local (load repository))))

let native_receipt_root_faults_retry_exactly_once () =
  List.iter
    (fun boundary ->
      temporary (fun parent ->
          let root, repository, _, _, before, directory, _ =
            receipt_fixture parent
          in
          let child = Unix.fork () in
          if child = 0 then (
            Service.Core_receive.For_test.receive ~root ~package:directory
              ~observe:(fun current -> if current = boundary then Unix._exit 73)
            |> ignore;
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "interrupted at actual receipt root publication" true
            (status = Unix.WEXITED 73);
          let saved = load repository in
          Alcotest.(check int)
            "only atomic old/new record sets visible"
            (if boundary = Service.Core_receive.Before_metadata_publish then 4
             else 6)
            (List.length (L.record_objects (local saved)));
          let retried =
            Service.Core_receive.receive ~root ~package:directory
            |> ok Service.Core_receive.error_to_string
          in
          let after = load repository in
          Alcotest.(check bool)
            "lost acknowledgement retries recorded metadata"
            (boundary = Service.Core_receive.After_metadata_publish)
            retried.Service.Core_receive.unchanged;
          Alcotest.(check string)
            "interrupted receipt never captures partial work"
            (Yeokcham_v1_undo.encode before.S.history |> ok Fun.id)
            (Yeokcham_v1_undo.encode after.S.history |> ok Fun.id);
          Alcotest.(check string)
            "external unsaved bytes remain" "UNSAVED RECEIVER PRIVATE WORK"
            (read (root ^ "/private.txt"));
          Service.Core_receive.receive ~root ~package:directory
          |> ok Service.Core_receive.error_to_string
          |> ignore;
          Alcotest.(check bool)
            "second retry does not move the root" true
            (Raw.Mutable_ref.equal after.S.head (load repository).S.head)))
    [
      Service.Core_receive.Before_metadata_publish;
      Service.Core_receive.After_metadata_publish;
    ]

let native_receipt_during_integration_preserves_the_operation_and_new_records ()
    =
  temporary (fun parent ->
      let root, repository, capability, _, _, directory, _ =
        receipt_fixture parent
      in
      let shared = share root capability [ [ "note.txt" ] ] in
      let plan =
        Service.Integrate.prepare ~root
          ~selected_revisions:[ Option.get shared.Service.Share.revision ]
          ~reconcile_heads:None
        |> ok Service.Integrate.error_to_string
      in
      let child = Unix.fork () in
      if child = 0 then (
        Service.Integrate.For_test.apply ~root
          ~plan:(Yeokcham_v1_integration.id plan)
          ~signing_capability:(Some capability) ~observe:(fun boundary ->
            if boundary = Service.Integrate.Prepared_root then Unix._exit 73)
        |> ignore;
        Unix._exit 74);
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "integration intent really exists before receipt" true
        (status = Unix.WEXITED 73);
      let before = load repository in
      let operation = Option.get (L.pending_operation (local before)) in
      let received =
        Service.Core_receive.receive ~root ~package:directory
        |> ok Service.Core_receive.error_to_string
      in
      Alcotest.(check int)
        "independent incoming branch retained during pending operation" 2
        received.Service.Core_receive.records_added;
      let after = load repository in
      Alcotest.(check string)
        "receipt does not capture the pending tree"
        (Yeokcham_v1_undo.encode before.S.history |> ok Fun.id)
        (Yeokcham_v1_undo.encode after.S.history |> ok Fun.id);
      Alcotest.(check bool)
        "exact operation survives the unrelated receipt" true
        (L.pending_operation (local after) = Some operation);
      Service.Integrate.resume ~root ~operation:operation.L.Operation.token
      |> ok Service.Integrate.error_to_string
      |> ignore;
      let finished = load repository in
      Alcotest.(check int)
        "integration commit does not erase received branch" 3
        (List.length (L.branches (local finished)));
      Alcotest.(check bool)
        "unrelated receipt does not stale exact plan" true
        ((List.hd (L.operations (local finished))).L.Operation.phase
       = L.Operation.Completed);
      Alcotest.(check string)
        "private unsaved bytes remain private" "UNSAVED RECEIVER PRIVATE WORK"
        (read (root ^ "/private.txt")))

let native_hash_stream_offsets_and_context_forks () =
  let module Hash = Yeokcham_hash.Sha256 in
  let hex digest =
    Hash.to_raw_string digest |> fun bytes ->
    String.init
      (String.length bytes * 2)
      (fun i ->
        let byte = Char.code bytes.[i / 2] in
        "0123456789abcdef".[if i mod 2 = 0 then byte lsr 4 else byte land 15])
  in
  let path = "golden/core-package/hash-stream-id.hex" in
  let expected =
    read (if Sys.file_exists path then path else "test/" ^ path) |> String.trim
  in
  let input = String.init ((1024 * 1024) + 7) (fun i -> Char.chr (i mod 251)) in
  let padded = Bytes.of_string ("pad" ^ input ^ "unused suffix") in
  let rec stream context offset =
    if offset = String.length input then context
    else
      let length = min 8191 (String.length input - offset) in
      stream
        (Hash.feed_bytes context ~off:(offset + 3) ~len:length padded)
        (offset + length)
  in
  Alcotest.(check string)
    "independent SHA-256 over bounded offset byte feeds" expected
    (stream Hash.empty 0 |> Hash.get |> hex);
  Alcotest.(check string)
    "one-shot native digest matches independent stream" expected
    (Hash.digest_string input |> hex);
  let prefix = Hash.feed_string Hash.empty "abc" in
  Hash.feed_string prefix "def" |> Hash.get |> ignore;
  Alcotest.(check string)
    "forking a C-backed context preserves the old prefix"
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    (Hash.get prefix |> hex);
  Alcotest.(check string)
    "streaming never mutates the reusable empty context"
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    (Hash.get Hash.empty |> hex)

let endpoint = Transport.sha256 "https://relay.invalid"
let outbound result = ok Outbound.error_to_string result

let native_courier_receipt_keeps_provenance_atomic_and_monotonic () =
  List.iter
    (fun boundary ->
      temporary (fun parent ->
          let root, repository, capability, authority, before, directory, _ =
            receipt_fixture parent
          in
          let publisher =
            T.device_of_public_key (T.signing_public_key capability)
            |> ok T.error_to_string
          in
          let manifest = read (directory ^ "/manifest.cbor") in
          let courier =
            Transport.create_publication
              ~repository:(T.repository (T.authority_membership authority))
              ~publisher
              ~certificate:
                (S.local_certificate (Option.get before.S.collaboration))
              ~parents:[]
              ~manifest:(Transport.sha256 manifest)
              ~signing_capability:capability
            |> ok Transport.error_to_string
          in
          let receive () =
            Service.Core_receive.receive_publication ~root ~remote:"origin"
              ~endpoint ~cursor:None ~publication:courier ~package:directory
            |> ok Service.Core_receive.error_to_string
          in
          let child = Unix.fork () in
          if child = 0 then (
            Service.Core_receive.For_test.receive_publication ~root
              ~remote:"origin" ~endpoint ~cursor:None ~publication:courier
              ~package:directory ~observe:(fun event ->
                if event = boundary then Unix._exit 73)
            |> ignore;
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "interrupted at actual receipt/root boundary" true
            (status = Unix.WEXITED 73);
          let partial = load repository in
          let incoming loaded =
            Transport.Core_inbox.receipts
              (S.transport (Option.get loaded.S.collaboration))
          in
          let after = boundary = Service.Core_receive.After_metadata_publish in
          Alcotest.(check int)
            "courier evidence and public records publish together"
            (if after then 1 else 0)
            (List.length (incoming partial));
          Alcotest.(check int)
            "one complete record set at each side of CAS"
            (if after then 6 else 4)
            (List.length (L.record_objects (local partial)));
          receive () |> ignore;
          let completed = load repository in
          let receipt = List.hd (incoming completed) in
          Alcotest.(check string)
            "exact public manifest provenance retained" manifest
            (Transport.Core_inbox.manifest receipt);
          Alcotest.(check string)
            "exact verified courier retained"
            (Transport.publication_id courier)
            (Transport.publication_id
               (Transport.Core_inbox.publication receipt));
          Alcotest.(check bool)
            "identical full receipt reports unchanged" true
            (receive ()).Service.Core_receive.unchanged;
          Alcotest.(check bool)
            "identical receipt publishes no additional root" true
            (Raw.Mutable_ref.equal completed.S.head (load repository).S.head);
          let collaboration = Option.get completed.S.collaboration in
          let erased =
            S.collaboration_with_authority_transport ~authority
              ~transport:Transport.empty_local_state
              ~revisions:(S.signed_revisions collaboration)
              ~local_certificate:(S.local_certificate collaboration)
              ~authorizations:(S.authorizations collaboration)
              ~adoptions:(S.adoptions collaboration)
            |> ok S.error_to_string
          in
          reject
            (S.save_collaborative ~local:(local completed) repository
               ~expected:completed.S.head ~project:completed.S.project
               ~collaboration:erased);
          reject
            (Service.Core_receive.receive_publication ~root ~remote:"origin"
               ~endpoint:(Transport.sha256 "different endpoint")
               ~cursor:None ~publication:courier ~package:directory);
          Alcotest.(check bool)
            "invalid updates preserve committed receipt" true
            (Raw.Mutable_ref.equal completed.S.head (load repository).S.head);
          Alcotest.(check string)
            "receipt never captures/navigation private history"
            (Yeokcham_v1_undo.encode before.S.history |> ok Fun.id)
            (Yeokcham_v1_undo.encode completed.S.history |> ok Fun.id);
          Alcotest.(check string)
            "receipt preserves unsaved private bytes"
            "UNSAVED RECEIVER PRIVATE WORK"
            (read (root ^ "/private.txt"))))
    [
      Service.Core_receive.Before_metadata_publish;
      Service.Core_receive.After_metadata_publish;
    ]

let frozen repository =
  let loaded = load repository in
  Outbox.find
    (S.transport (Option.get loaded.S.collaboration))
    ~remote:"origin" ~endpoint
  |> ok Transport.error_to_string

let prepare_outbound root capability =
  Outbound.prepare ~root ~remote:"origin" ~endpoint
    ~signing_capability:capability
  |> outbound

let acknowledge_outbound root batch =
  Outbound.acknowledge ~root ~remote:"origin" ~endpoint
    ~publication:(Transport.publication_id (Outbox.publication batch))
  |> outbound

let[@warning "-4"] native_outbound_freezes_retries_and_preserves_later_work () =
  temporary (fun parent ->
      let root = parent ^ "/alice" in
      let repository, capability, _ = initialize root 'k' in
      let shared = share root capability [ [ "note.txt" ] ] in
      let before = load repository in
      let first = prepare_outbound root (Some capability) |> Option.get in
      Fun.protect
        ~finally:(fun () -> Package.dispose_artifact first.Outbound.artifact)
        (fun () ->
          let id =
            Transport.publication_id (Outbox.publication first.Outbound.batch)
          in
          let snapshot = Outbox.manifest first.Outbound.batch in
          let after_freeze = load repository in
          Alcotest.(check bool)
            "freeze is durable before a relay request" true
            (Option.is_some (frozen repository));
          Alcotest.(check string)
            "freeze does not allocate or navigate history"
            (Yeokcham_v1_undo.encode before.S.history |> ok Fun.id)
            (Yeokcham_v1_undo.encode after_freeze.S.history |> ok Fun.id);
          let head = after_freeze.S.head in
          let second = prepare_outbound root None |> Option.get in
          Alcotest.(check bool)
            "retry requires no signer" true second.Outbound.reused;
          Alcotest.(check string)
            "same signed courier after retry" id
            (Transport.publication_id
               (Outbox.publication second.Outbound.batch));
          Alcotest.(check bool)
            "retry publishes no root" true
            (Raw.Mutable_ref.equal head (load repository).S.head);
          Package.dispose_artifact second.Outbound.artifact;
          let manifest =
            P.decode_manifest
              ~repository:(C.pool_repository (L.pool (local before)))
              snapshot
            |> package
          in
          let first_records =
            P.record_inventory (S.underlying_store repository) manifest
            |> package
          in
          Alcotest.(check bool)
            "frozen inventory contains the original exact revision" true
            (List.exists
               (fun (id, _) ->
                 C.Record_id.equal id (Option.get shared.Service.Share.revision))
               first_records);
          write (root ^ "/note.txt") "later explicit public update\n";
          let later =
            Service.share_selected ~root ~paths:[ [ "note.txt" ] ]
              ~update:shared.Service.Share.change ~title:(Some "later work")
              ~dry_run:false ~signing_capability:(Some capability)
            |> service
          in
          let later_id = Option.get later.Service.Share.revision in
          write (root ^ "/private.txt") "UNSAVED LATER PRIVATE EDIT";
          let history =
            (load repository).S.history |> Yeokcham_v1_undo.encode |> ok Fun.id
          in
          let third = prepare_outbound root None |> Option.get in
          Alcotest.(check string)
            "new work cannot retarget frozen manifest" snapshot
            (Package.artifact_manifest third.Outbound.artifact);
          Package.dispose_artifact third.Outbound.artifact;
          Yeokcham_v1_gc.apply ~root
          |> ok Yeokcham_v1_gc.error_to_string
          |> ignore;
          let retry = prepare_outbound root None |> Option.get in
          Alcotest.(check string)
            "actual GC retains frozen public closure" snapshot
            (Package.artifact_manifest retry.Outbound.artifact);
          Package.dispose_artifact retry.Outbound.artifact;
          acknowledge_outbound root first.Outbound.batch;
          let acked = load repository in
          Alcotest.(check string)
            "acknowledgement preserves later history" history
            (Yeokcham_v1_undo.encode acked.S.history |> ok Fun.id);
          Alcotest.(check string)
            "acknowledgement does not scan private edits"
            "UNSAVED LATER PRIVATE EDIT"
            (read (root ^ "/private.txt"));
          Alcotest.(check bool)
            "relay acknowledgement is durable" true
            (Outbox.acknowledged (Option.get (frozen repository)));
          acknowledge_outbound root first.Outbound.batch;
          Alcotest.(check bool)
            "ack retry publishes no root" true
            (Raw.Mutable_ref.equal acked.S.head (load repository).S.head);
          let next = prepare_outbound root (Some capability) |> Option.get in
          let status, json = cli root [ "status"; "--format"; "json" ] in
          Alcotest.(check bool)
            "status inspects retained acknowledgement coverage" true
            (status = Unix.WEXITED 0);
          let open Yojson.Safe.Util in
          let rows =
            Yojson.Safe.from_string json
            |> member "data"
            |> member "local_publications"
            |> to_list
          in
          let transfer revision =
            List.find
              (fun row ->
                member "revision_id" row = `String (C.Record_id.to_hex revision))
              rows
          in
          Alcotest.(check bool)
            "preparing new work retains earlier transfer acknowledgement" true
            (member "transfer_state"
               (transfer (Option.get shared.Service.Share.revision))
            = `String "acknowledged");
          Alcotest.(check bool)
            "status exposes the acknowledging remote" true
            (member "acknowledged_remotes"
               (transfer (Option.get shared.Service.Share.revision))
            = `List [ `String "origin" ]);
          Alcotest.(check bool)
            "new revision remains pending while its batch is frozen" true
            (member "transfer_state" (transfer later_id) = `String "pending");
          Alcotest.(check bool)
            "later public work creates a different batch" true
            (Outbox.manifest next.Outbound.batch <> snapshot);
          let next_manifest =
            P.decode_manifest
              ~repository:(C.pool_repository (L.pool (local acked)))
              (Outbox.manifest next.Outbound.batch)
            |> package
          in
          let next_records =
            P.record_inventory (S.underlying_store repository) next_manifest
            |> package
          in
          Alcotest.(check bool)
            "later revision remains outgoing" true
            (List.exists
               (fun (id, _) -> C.Record_id.equal id later_id)
               next_records);
          Alcotest.(check (list string))
            "next courier names its exact acknowledged predecessor" [ id ]
            (Transport.publication_parents
               (Outbox.publication next.Outbound.batch));
          Package.dispose_artifact next.Outbound.artifact;
          acknowledge_outbound root next.Outbound.batch;
          Alcotest.(check bool)
            "unchanged full public state has no outgoing batch" true
            (Option.is_none (prepare_outbound root None))))

let native_outbound_root_faults_retry_exact_batches () =
  List.iter
    (fun boundary ->
      temporary (fun parent ->
          let root = parent ^ "/alice" in
          let repository, capability, _ = initialize root 'k' in
          share root capability [ [ "note.txt" ] ] |> ignore;
          let child = Unix.fork () in
          if child = 0 then (
            let observe event = if event = boundary then Unix._exit 73 in
            (match boundary with
            | Outbound.Freeze_before | Outbound.Freeze_after ->
                Outbound.For_test.prepare ~observe ~root ~remote:"origin"
                  ~endpoint ~signing_capability:(Some capability)
                |> ignore
            | Outbound.Acknowledge_before | Outbound.Acknowledge_after ->
                let first =
                  prepare_outbound root (Some capability) |> Option.get
                in
                let id =
                  Transport.publication_id
                    (Outbox.publication first.Outbound.batch)
                in
                Outbound.For_test.acknowledge ~observe ~root ~remote:"origin"
                  ~endpoint ~publication:id
                |> ignore);
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "stopped at actual durable boundary" true (status = Unix.WEXITED 73);
          let batch = frozen repository in
          (match boundary with
          | Outbound.Freeze_before ->
              Alcotest.(check bool)
                "no prematurely frozen intent" true (batch = None)
          | Outbound.Freeze_after | Outbound.Acknowledge_before ->
              Alcotest.(check bool)
                "pending exact batch survived restart" false
                (Outbox.acknowledged (Option.get batch))
          | Outbound.Acknowledge_after ->
              Alcotest.(check bool)
                "lost acknowledgement response is already durable" true
                (Outbox.acknowledged (Option.get batch)));
          match boundary with
          | Outbound.Acknowledge_after ->
              acknowledge_outbound root (Option.get batch);
              Alcotest.(check bool)
                "acknowledged batch is not resent" true
                (Option.is_none (prepare_outbound root None))
          | Outbound.Freeze_before | Outbound.Freeze_after
          | Outbound.Acknowledge_before ->
              let retry =
                prepare_outbound root
                  (if boundary = Outbound.Freeze_before then Some capability
                   else None)
                |> Option.get
              in
              Option.iter
                (fun old ->
                  Alcotest.(check string)
                    "same identity after interrupted root"
                    (Transport.publication_id (Outbox.publication old))
                    (Transport.publication_id
                       (Outbox.publication retry.Outbound.batch)))
                batch;
              Package.dispose_artifact retry.Outbound.artifact;
              acknowledge_outbound root retry.Outbound.batch))
    [
      Outbound.Freeze_before;
      Outbound.Freeze_after;
      Outbound.Acknowledge_before;
      Outbound.Acknowledge_after;
    ]

let native_outbound_signer_is_unlocked_and_state_cannot_discard_pending () =
  temporary (fun parent ->
      let root = parent ^ "/alice" in
      let repository, capability, authority = initialize root 'k' in
      share root capability [ [ "note.txt" ] ] |> ignore;
      let calls = ref 0 in
      let signer =
        T.signing_capability_of_external_signer
          ~public_key:(T.signing_public_key capability)
          ~sign:(fun ~domain bytes ->
            incr calls;
            let child = Unix.fork () in
            (if child = 0 then
               let fd =
                 Unix.openfile
                   (root ^ "/.yeokcham/local-worktree.lock")
                   [ Unix.O_RDWR ] 0
               in
               try
                 Unix.lockf fd Unix.F_TLOCK 0;
                 Unix.close fd;
                 Unix._exit 0
               with Unix.Unix_error _ -> Unix._exit 1);
            let _, status = Unix.waitpid [] child in
            Alcotest.(check bool)
              "courier provider holds no writer lock" true
              (status = Unix.WEXITED 0);
            write (root ^ "/private.txt") "PROVIDER-TIME PRIVATE EDIT";
            T.sign_detached capability ~domain bytes
            |> Result.map_error T.error_to_string)
        |> ok T.error_to_string
      in
      let first = prepare_outbound root (Some signer) |> Option.get in
      Package.dispose_artifact first.Outbound.artifact;
      Alcotest.(check int) "one courier provider call" 1 !calls;
      let before = load repository in
      let old = Option.get before.S.collaboration in
      let candidate =
        S.collaboration_with_authority_transport
          ~transport:Transport.empty_local_state ~authority
          ~revisions:(S.signed_revisions old)
          ~local_certificate:(S.local_certificate old)
          ~authorizations:(S.authorizations old) ~adoptions:(S.adoptions old)
        |> ok S.error_to_string
      in
      reject
        (S.save_collaborative ~local:(local before) repository
           ~expected:before.S.head ~project:before.S.project
           ~collaboration:candidate);
      reject
        (Outbound.prepare ~root ~remote:"origin"
           ~endpoint:(Transport.sha256 "https://different.invalid")
           ~signing_capability:(Some capability));
      reject
        (Outbound.acknowledge ~root ~remote:"origin" ~endpoint
           ~publication:(String.make 64 'f'));
      Alcotest.(check bool)
        "invalid updates cannot erase a durable batch" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "provider-time private edits survive" "PROVIDER-TIME PRIVATE EDIT"
        (read (root ^ "/private.txt")))

let native_outbound_acknowledges_only_exact_committed_records () =
  temporary (fun parent ->
      let root = parent ^ "/alice" in
      let repository, capability, _ = initialize root 'k' in
      let integrate revision =
        let plan =
          Service.Integrate.prepare ~root ~selected_revisions:[ revision ]
            ~reconcile_heads:None
          |> ok Service.Integrate.error_to_string
        in
        Service.Integrate.apply ~root
          ~plan:(Yeokcham_v1_integration.id plan)
          ~signing_capability:(Some capability)
        |> ok Service.Integrate.error_to_string
        |> fun result -> Option.get result.Service.Integrate.operation
      in
      let first = share root capability [ [ "note.txt" ] ] in
      let first_operation =
        integrate (Option.get first.Service.Share.revision)
      in
      let outgoing = prepare_outbound root (Some capability) |> Option.get in
      Package.dispose_artifact outgoing.Outbound.artifact;
      write (root ^ "/note.txt") "new accepted work after frozen courier\n";
      let second = share root capability [ [ "note.txt" ] ] in
      let second_operation =
        integrate (Option.get second.Service.Share.revision)
      in
      let before = load repository in
      acknowledge_outbound root outgoing.Outbound.batch;
      let after = load repository in
      let operation token =
        List.find
          (fun op -> C.Operation_id.equal op.L.Operation.token token)
          (L.operations (local after))
      in
      Alcotest.(check bool)
        "exact transferred acceptance is acknowledged" true
        (operation first_operation.L.Operation.token).L.Operation.acknowledged;
      Alcotest.(check bool)
        "later acceptance remains outbound" false
        (operation second_operation.L.Operation.token).L.Operation.acknowledged;
      Alcotest.(check string)
        "acknowledgement allocates no history"
        (Yeokcham_v1_undo.encode before.S.history |> ok Fun.id)
        (Yeokcham_v1_undo.encode after.S.history |> ok Fun.id);
      let current = prepare_outbound root (Some capability) |> Option.get in
      Package.dispose_artifact current.Outbound.artifact;
      acknowledge_outbound root current.Outbound.batch;
      Alcotest.(check bool)
        "second exact transfer acknowledges its own acceptance" true
        (List.find
           (fun op ->
             C.Operation_id.equal op.L.Operation.token
               second_operation.L.Operation.token)
           (L.operations (local (load repository))))
          .L.Operation.acknowledged)

let () =
  Alcotest.run "Core public package"
    [
      ( "public",
        [
          Alcotest.test_case
            "native courier receipt publishes provenance atomically" `Quick
            native_courier_receipt_keeps_provenance_atomic_and_monotonic;
          Alcotest.test_case
            "outbound exact retries preserve later private/public work" `Quick
            native_outbound_freezes_retries_and_preserves_later_work;
          Alcotest.test_case
            "outbound and acknowledgement stop at actual root boundaries" `Quick
            native_outbound_root_faults_retry_exact_batches;
          Alcotest.test_case
            "outbound provider is unlocked and pending batches cannot be erased"
            `Quick
            native_outbound_signer_is_unlocked_and_state_cannot_discard_pending;
          Alcotest.test_case
            "outbound acknowledges only its exact committed acceptances" `Quick
            native_outbound_acknowledges_only_exact_committed_records;
          Alcotest.test_case
            "native receipt preserves private state and known-only branches"
            `Quick native_receipt_preserves_history_files_and_private_positions;
          Alcotest.test_case
            "native receipt guards private positions and required policy" `Quick
            native_receipt_cannot_erase_working_positions_or_bypass_admission;
          Alcotest.test_case
            "native receipt retries before/after actual root publication" `Quick
            native_receipt_root_faults_retry_exactly_once;
          Alcotest.test_case
            "native receipt composes with an already prepared integration"
            `Quick
            native_receipt_during_integration_preserves_the_operation_and_new_records;
          Alcotest.test_case "independent manifest and courier identity" `Quick
            independent_manifest_vector;
          Alcotest.test_case "native hash streams preserve offsets and contexts"
            `Quick native_hash_stream_offsets_and_context_forks;
          Alcotest.test_case
            "public closure preserves D/E privacy and mixed fidelity" `Quick
            public_closure_preserves_d_e_and_mixed_fidelity;
          Alcotest.test_case "canonical inventory cannot smuggle a private blob"
            `Quick reject_extra_private_object_even_in_canonical_inventory;
          Alcotest.test_case "signed false results and foreign roots refuse"
            `Quick signed_false_result_and_foreign_authority_refuse;
          Alcotest.test_case "malformed controls and missing closure refuse"
            `Quick malformed_controls_and_missing_objects_refuse;
        ] );
    ]
