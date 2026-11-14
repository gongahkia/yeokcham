module S = Yeokcham_v1_store
module L = S.Local
module M = Yeokcham_v1_model
module C = M.Core
module T = Yeokcham_v1_trust
module Raw = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module H = Yeokcham_v1_undo
module R = Yeokcham_v1_record.Core

[@@@warning "-42"]

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)
let trust r = ok T.error_to_string r
let reject label = function Error _ -> () | Ok _ -> Alcotest.fail label
let snapshot text = M.Snapshot_id.of_string text |> ok M.error_to_string
let draft = M.Draft_id.of_string "work" |> ok M.error_to_string
let model r = ok C.error_to_string r

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_root f =
  let root = Filename.temp_file "yeokcham-local-core-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let fixture () =
  let repo = T.Repository_id.of_string (String.make 64 'a') |> ok Fun.id in
  let capability =
    T.signing_capability_of_private_key (String.make 32 'k') |> trust
  in
  let device =
    T.device_of_public_key (T.signing_public_key capability) |> trust
  in
  let certificate =
    T.root_certificate ~repository:repo ~device capability |> trust
  in
  let membership =
    T.verify_membership ~repository:repo [ certificate ] |> trust
  in
  let recovery_capability =
    T.signing_capability_of_private_key (String.make 32 'r') |> trust
  in
  let recovery_device =
    T.device_of_public_key (T.signing_public_key recovery_capability) |> trust
  in
  let epoch =
    T.root_epoch ~membership
      ~root_certificate:(T.certificate_id certificate)
      ~recovery_device capability
    |> trust
  in
  let authority = T.verify_authority ~membership [ epoch ] |> trust in
  let collaboration =
    S.collaboration_with_authority ~authority ~revisions:[]
      ~local_certificate:(T.certificate_id certificate)
      ~authorizations:[] ~adoptions:[]
    |> ok S.error_to_string
  in
  (capability, device, T.certificate_id certificate, authority, collaboration)

let initialize root =
  Out_channel.with_open_bin (Filename.concat root "private.bin") (fun ch ->
      Out_channel.output_string ch "private\000bytes\255");
  let capability, device, certificate, authority, collaboration = fixture () in
  let repository =
    S.init_local_collaborative_with ~root ~bootstrap:(fun store ->
        let local =
          L.initialize ~store ~authority ~certificate
            ~signing_capability:capability ~cursor:0L
          |> ok Fun.id
        in
        let empty = snapshot (C.Object_id.to_hex (L.empty_snapshot local)) in
        let captured, _ =
          Snapshot.scan ~root ~store |> ok Snapshot.error_to_string
        in
        let private_capture =
          Snapshot.Snapshot.stored_object_id captured
          |> Raw.Stored_object_id.to_hex |> snapshot
        in
        let project =
          M.init ~creator:(T.device_id device)
            ~username:(M.Username.of_string "alice" |> ok M.error_to_string)
            ~initial_snapshot:empty ~initial_draft:draft ~title:"private"
          |> fun p -> M.checkpoint p ~snapshot:private_capture
        in
        Ok (project, collaboration, local))
    |> ok S.error_to_string
  in
  (repository, capability, certificate, authority, collaboration)

let load repository = S.load repository |> ok S.error_to_string
let local loaded = loaded.S.local |> Option.get

let private_initialization () =
  with_root (fun root ->
      let repository, _, _, authority, _ = initialize root in
      let loaded = load repository in
      let local = local loaded in
      let empty = C.Object_id.to_hex (L.empty_snapshot local) in
      Alcotest.(check string)
        "V1 baseline is empty, not initial private files" empty
        (M.Snapshot_id.to_string (M.export loaded.S.project).M.state_baseline);
      Alcotest.(check bool)
        "initial private capture differs from acceptance" false
        (M.Snapshot_id.to_string
           (M.active_draft loaded.S.project).M.latest_checkpoint
        = empty);
      let branches = L.branches local in
      Alcotest.(check int) "one actual shared branch" 1 (List.length branches);
      Alcotest.(check (list string))
        "useful generated default name" [ "main" ]
        (List.hd branches).C.display_names;
      let store = S.underlying_store repository in
      let objects = Raw.list_objects store |> ok Raw.error_to_string in
      let records =
        List.filter
          (fun (o : Raw.object_info) ->
            let code = Yeokcham_envelope.object_type_code o.Raw.object_type in
            code >= 41 && code <= 43)
          objects
      in
      Alcotest.(check int)
        "accepted genesis and branch event" 2 (List.length records);
      List.iter
        (fun (o : Raw.object_info) ->
          let bytes =
            Raw.get store o.Raw.id |> ok Raw.error_to_string
            |> Yeokcham_envelope.encode
          in
          let repository =
            C.Repository_id.of_hex (String.make 64 'a') |> model
          in
          let signed = R.decode ~repository bytes |> ok R.error_to_string in
          T.Core.verify authority signed |> ok T.Core.error_to_string;
          match (R.body signed).C.payload with
          | C.Accepted_version accepted ->
              Alcotest.(check string)
                "signed accepted result is empty" empty
                (C.Object_id.to_hex accepted.C.result_snapshot);
              Alcotest.(check int)
                "initial private work is not chosen" 0
                (List.length accepted.C.chosen_revisions)
          | C.Branch_event _ -> ()
          | C.Shared_revision _ ->
              Alcotest.fail "initialization published private work")
        records;
      let encoded = L.encode local |> ok Fun.id in
      let reopened = L.decode ~store ~authority encoded |> ok Fun.id in
      Alcotest.(check string)
        "canonical local branch round trip" encoded
        (L.encode reopened |> ok Fun.id))

let create_and_select_across_restart () =
  with_root (fun root ->
      let repository, capability, certificate, authority, collaboration =
        initialize root
      in
      let before = load repository in
      let local0 = local before in
      let original = (L.selected local0).L.branch in
      let created =
        L.create_branch
          ~store:(S.underlying_store repository)
          ~authority ~certificate ~signing_capability:capability
          ~name:"experiment" ~cursor:0L local0
        |> ok Fun.id
      in
      let saved =
        S.save_collaborative ~local:created repository ~expected:before.S.head
          ~project:before.S.project ~collaboration
        |> ok S.error_to_string
      in
      Alcotest.(check bool)
        "creating does not silently select" true
        (C.Branch_id.equal original (L.selected (local saved)).L.branch);
      reject "duplicate name retargeted"
        (L.create_branch
           ~store:(S.underlying_store repository)
           ~authority ~certificate ~signing_capability:capability
           ~name:"experiment" ~cursor:0L (local saved));
      let child = Unix.fork () in
      (if child = 0 then
         try
           let repository = S.open_repository ~root |> ok S.error_to_string in
           let current = load repository in
           let position = L.lookup (local current) "experiment" |> ok Fun.id in
           let selected =
             L.select (local current) position.L.branch |> ok Fun.id
           in
           S.save_collaborative ~local:selected repository
             ~expected:current.S.head ~project:current.S.project ~collaboration
           |> ok S.error_to_string |> ignore;
           Unix._exit 0
         with _ -> Unix._exit 1);
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "fresh writer selected metadata" true (status = Unix.WEXITED 0);
      let reopened = S.open_repository ~root |> ok S.error_to_string |> load in
      let branch = L.lookup (local reopened) "experiment" |> ok Fun.id in
      Alcotest.(check bool)
        "selection survived process restart" true
        (C.Branch_id.equal (L.selected (local reopened)).L.branch
           branch.L.branch);
      Alcotest.(check int)
        "branch records are distinct from undo nodes" 1
        (List.length (H.nodes reopened.S.history));
      reject "old branch state erased new branch"
        (S.save_collaborative ~local:local0 repository ~expected:reopened.S.head
           ~project:reopened.S.project ~collaboration);
      reject "unknown branch invented" (L.lookup (local reopened) "missing"))

let incomplete_records_and_invalid_positions () =
  with_root (fun root ->
      let repository, capability, certificate, authority, collaboration =
        initialize root
      in
      let loaded = load repository in
      let local0 = local loaded in
      let invalid = L.remember local0 ~cursor:99L |> ok Fun.id in
      (* store publishes the actual history cursor, rather than trusting a caller's
     stale selector; an unselected nonexistent position is rejected below *)
      let generated =
        L.create_branch
          ~store:(S.underlying_store repository)
          ~authority ~certificate ~signing_capability:capability
          ~name:"invalid-position" ~cursor:99L invalid
        |> ok Fun.id
      in
      reject "nonexistent branch cursor published"
        (S.save_collaborative ~local:generated repository
           ~expected:loaded.S.head ~project:loaded.S.project ~collaboration);
      Alcotest.(check bool)
        "invalid metadata preserved root" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head);
      let core_object =
        Raw.list_objects (S.underlying_store repository)
        |> ok Raw.error_to_string
        |> List.find (fun (o : Raw.object_info) ->
            o.Raw.object_type = Yeokcham_envelope.Core_branch_event
            &&
            let envelope =
              Raw.get (S.underlying_store repository) o.Raw.id
              |> ok Raw.error_to_string
            in
            let repository =
              C.Repository_id.of_hex (String.make 64 'a') |> model
            in
            let signed =
              R.decode ~repository (Yeokcham_envelope.encode envelope)
              |> ok R.error_to_string
            in
            let id = R.id signed |> ok R.error_to_string in
            List.exists (C.Record_id.equal id)
              (List.hd (L.branches local0)).C.event_heads)
      in
      let object_path =
        Raw.object_path (S.underlying_store repository) core_object.Raw.id
      in
      Unix.unlink object_path;
      reject "missing branch record accepted"
        (L.decode
           ~store:(S.underlying_store repository)
           ~authority
           (L.encode local0 |> ok Fun.id)))

let branch_collision_and_entropy () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let initial = load repository in
      let local0 = local initial in
      let store = S.underlying_store repository in
      let count () =
        Raw.list_objects store |> ok Raw.error_to_string |> List.length
      in
      let before = count () in
      let calls = ref 0 in
      let random_bytes _ =
        incr calls;
        Ok (C.Branch_id.to_raw (L.selected local0).L.branch)
      in
      reject "colliding branch identity reused"
        (L.For_test.create_branch ~random_bytes ~store ~authority ~certificate
           ~signing_capability:capability ~name:"collision" ~cursor:0L local0);
      Alcotest.(check int) "collision retries bounded" 3 !calls;
      reject "entropy failure hidden"
        (L.For_test.create_branch
           ~random_bytes:(fun _ -> Error "unavailable")
           ~store ~authority ~certificate ~signing_capability:capability
           ~name:"no-entropy" ~cursor:0L local0);
      Alcotest.(check int) "failure before record staging" before (count ());
      Alcotest.(check bool)
        "failures retained atomic root" true
        (Raw.Mutable_ref.equal initial.S.head (load repository).S.head))

let[@warning "-4"] invalid_mappings_signatures_and_acceptance () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let state = load repository |> local in
      let store = S.underlying_store repository in
      let encoded = L.encode state |> ok Fun.id in
      let fields =
        Yeokcham_encoding.decode encoded
        |> ok Yeokcham_encoding.decode_error_to_string
      in
      let array v =
        Yeokcham_encoding.array v
        |> ok Yeokcham_encoding.construction_error_to_string
      in
      let append_record signed =
        let bytes = R.encode signed |> ok R.error_to_string in
        let envelope =
          Yeokcham_envelope.decode bytes
          |> ok Yeokcham_envelope.decode_error_to_string
        in
        let stored = Raw.put store envelope |> ok Raw.error_to_string in
        let id = R.id signed |> ok R.error_to_string in
        let mapping =
          array
            [
              Yeokcham_encoding.bytes (C.Record_id.to_raw id);
              Yeokcham_encoding.bytes (Raw.Stored_object_id.to_raw_bytes stored);
            ]
        in
        match fields with
        | Yeokcham_encoding.Array
            [
              version;
              empty;
              selected;
              Yeokcham_encoding.Array records;
              positions;
            ] ->
            array
              [
                version; empty; selected; array (mapping :: records); positions;
              ]
            |> Yeokcham_encoding.encode
        | _ -> Alcotest.fail "unexpected local core fields"
      in
      let context =
        C.make_context
          ~repository:(C.Repository_id.of_hex (String.make 64 'a') |> model)
          ~author_certificate:(C.Digest.of_hex certificate |> model)
          ~authority_heads:
            (List.map
               (fun id -> C.Digest.of_hex id |> model)
               (T.authority_heads authority))
          ~display_time:None
        |> model
      in
      let branch = C.Branch_id.of_raw (String.make 16 'x') |> model in
      let payload =
        C.make_accepted_version ~branch ~accepted_parents:[]
          ~chosen_revisions:[] ~resolutions:[]
          ~result_snapshot:(C.Object_id.of_raw (String.make 32 'x') |> model)
          ~composition_profile:"line-hunks-v1" ~policy_heads:[]
          ~review_evidence:[]
        |> model
        |> fun v -> C.Accepted_version v
      in
      let body = C.make_body ~context ~payload in
      let signed =
        T.Core.sign authority capability body |> ok T.Core.error_to_string
      in
      reject "nonempty result treated as verified acceptance"
        (L.decode ~store ~authority (append_record signed));
      let invalid =
        R.attach_signature body ~signature:(String.make 64 '\000')
        |> ok R.error_to_string
      in
      reject "bad signature accepted"
        (L.decode ~store ~authority (append_record invalid));
      let swapped =
        match fields with
        | Yeokcham_encoding.Array
            [
              version;
              empty;
              selected;
              Yeokcham_encoding.Array
                [
                  Yeokcham_encoding.Array [ a; physical_a ];
                  Yeokcham_encoding.Array [ b; physical_b ];
                ];
              positions;
            ] ->
            array
              [
                version;
                empty;
                selected;
                array [ array [ a; physical_b ]; array [ b; physical_a ] ];
                positions;
              ]
            |> Yeokcham_encoding.encode
        | _ -> Alcotest.fail "unexpected genesis reference pairs"
      in
      reject "logical/physical mapping mismatch accepted"
        (L.decode ~store ~authority swapped))

let historical_load_and_current_admission () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let before = load repository |> local in
      let store = S.underlying_store repository in
      let candidate =
        L.create_branch ~store ~authority ~certificate
          ~signing_capability:capability ~name:"arrived-late" ~cursor:0L before
        |> ok Fun.id
      in
      let heads = T.authority_heads authority in
      let epoch = T.authority_epoch authority (List.hd heads) |> trust in
      let membership = T.authority_membership authority in
      let root_cert =
        T.certificates membership
        |> List.find (fun c -> T.certificate_id c = certificate)
      in
      let revoked =
        T.successor_epoch authority ~parents:heads
          ~certificates:(T.certificates membership)
          ~revoked:[ T.device_id (T.certificate_subject root_cert) ]
          ~frontier:[]
          ~recovery_device:(T.epoch_recovery_device epoch)
          ~issuer:certificate capability
        |> trust
      in
      let current = T.extend_authority authority [ revoked ] |> trust in
      L.decode ~store ~authority:current (L.encode candidate |> ok Fun.id)
      |> ok Fun.id |> ignore;
      L.admit_update ~store ~authority:current ~previous:(Some before) before
      |> ok Fun.id;
      reject "historically signed late branch bypassed admission"
        (L.admit_update ~store ~authority:current ~previous:(Some before)
           candidate))

let branch_work_is_a_retention_root () =
  with_root (fun root ->
      let repository, capability, certificate, authority, collaboration =
        initialize root
      in
      let save bytes =
        Out_channel.with_open_bin (Filename.concat root "private.bin")
          (fun ch -> Out_channel.output_string ch bytes);
        Yeokcham_v1_local_service.save ~root
        |> ok Yeokcham_v1_local_service.error_to_string
        |> ignore
      in
      save "B";
      let before = load repository in
      let branch_snapshot =
        (M.active_draft before.S.project).M.latest_checkpoint
      in
      let created =
        L.create_branch
          ~store:(S.underlying_store repository)
          ~authority ~certificate ~signing_capability:capability
          ~name:"saved-alternative" ~cursor:(H.current before.S.history).H.id
          (local before)
        |> ok Fun.id
      in
      S.save_collaborative ~local:created repository ~expected:before.S.head
        ~project:before.S.project ~collaboration
      |> ok S.error_to_string |> ignore;
      save "C";
      let current = load repository in
      let alternate =
        L.lookup (local current) "saved-alternative" |> ok Fun.id
      in
      let selected = L.select (local current) alternate.L.branch |> ok Fun.id in
      reject "selection retargeted a branch to another cursor"
        (S.save_collaborative ~local:selected repository
           ~expected:current.S.head ~project:current.S.project ~collaboration);
      Alcotest.(check int64)
        "rejected selection preserves alternate cursor" alternate.L.cursor
        (L.lookup (local (load repository)) "saved-alternative" |> ok Fun.id)
          .L.cursor;
      let unsafe =
        M.compact current.S.project ~keep_recent:0 ~journal_snapshots:[]
          ~proof_snapshots:[]
        |> ok M.error_to_string
      in
      reject "store allowed dropping unselected private branch work"
        (S.save_collaborative repository ~expected:current.S.head
           ~project:unsafe.M.project ~collaboration);
      let compacted =
        Yeokcham_v1_local_service.compact ~root ~keep_recent:0 ~dry_run:false
        |> ok Yeokcham_v1_local_service.error_to_string
      in
      let kept =
        List.find
          (fun keep -> M.Snapshot_id.equal keep.M.snapshot branch_snapshot)
          compacted.Yeokcham_v1_local_service.kept
      in
      Alcotest.(check bool)
        "compaction reports actual branch protection" true
        (List.mem M.Local_branch kept.M.reasons);
      let plan =
        Yeokcham_v1_gc.plan ~root |> ok Yeokcham_v1_gc.error_to_string
      in
      let snapshot_id =
        Raw.Stored_object_id.of_hex (M.Snapshot_id.to_string branch_snapshot)
        |> ok Raw.Stored_object_id.parse_error_to_string
      in
      let object_ =
        List.find
          (fun object_ ->
            Raw.Stored_object_id.equal object_.Yeokcham_v1_gc.object_id
              snapshot_id)
          plan.Yeokcham_v1_gc.objects
      in
      match object_.Yeokcham_v1_gc.disposition with
      | Yeokcham_v1_gc.Retain _ -> ()
      | Yeokcham_v1_gc.Collect ->
          Alcotest.fail "GC planned to collect branch working contents")

module Service = Yeokcham_v1_local_service

let service r = ok Service.error_to_string r

let write_private root bytes =
  Out_channel.with_open_bin (Filename.concat root "private.bin") (fun out ->
      output_string out bytes)

let read_private root =
  In_channel.with_open_bin
    (Filename.concat root "private.bin")
    In_channel.input_all

let switch root name =
  Service.branch_switch ~root ~name ~dry_run:false |> service

let make_topic root capability =
  Service.branch_create ~root ~name:"topic" ~signing_capability:capability
  |> service |> ignore

let selected_name repository =
  let local = local (load repository) in
  let selected = (L.selected local).L.branch in
  List.find
    (fun row -> C.Branch_id.equal row.C.branch_id selected)
    (L.branches local)
  |> fun row -> row.C.display_names

let private_switch_journey () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      let original = read_private root in
      make_topic root capability;
      write_private root "B unsaved\000";
      let before = load repository in
      let preview =
        Service.branch_switch ~root ~name:"topic" ~dry_run:true |> service
      in
      Alcotest.(check bool)
        "preview explains preservation" true
        preview.Service.switch_captures_unsaved;
      Alcotest.(check bool)
        "preview has real differences" true
        (preview.Service.switch_changes <> []);
      Alcotest.(check bool)
        "preview does not publish a root" true
        (Raw.Stored_object_id.equal before.S.object_id
           (load repository).S.object_id);
      Alcotest.(check bool)
        "preview does not stage files" false
        (Sys.file_exists (Filename.concat root ".yeokcham/restore-staging"));
      Alcotest.(check string)
        "preview leaves working bytes" "B unsaved\000" (read_private root);
      ignore (switch root "topic");
      Alcotest.(check string)
        "target private contents" original (read_private root);
      write_private root "C topic\255";
      ignore (switch root "main");
      Alcotest.(check string)
        "source unsaved private work recovered" "B unsaved\000"
        (read_private root);
      let child = Unix.fork () in
      (if child = 0 then
         try
           ignore (switch root "topic");
           Unix._exit 0
         with _ -> Unix._exit 1);
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "fresh process switched" true (status = Unix.WEXITED 0);
      Alcotest.(check string)
        "topic private alternative survived restart" "C topic\255"
        (read_private root);
      Alcotest.(check (list string))
        "selection persisted" [ "topic" ] (selected_name repository);
      let current = load repository in
      Alcotest.(check int)
        "three actual local states" 3
        (List.length (H.nodes current.S.history));
      Alcotest.(check int)
        "two shared branches distinct from local alternatives" 2
        (List.length (L.branches (local current)));
      Alcotest.(check (list int64))
        "alternate continuations retained" [ 1L; 2L ]
        (H.children current.S.history 0L |> List.map (fun node -> node.H.id)))

let equal_content_switch_keeps_positions () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      write_private root "B";
      Service.save ~root |> service |> ignore;
      make_topic root capability;
      write_private root "C";
      Service.save ~root |> service |> ignore;
      write_private root "B";
      let inode =
        (Unix.lstat (Filename.concat root "private.bin")).Unix.st_ino
      in
      ignore (switch root "topic");
      let current = load repository in
      Alcotest.(check int64)
        "select exact existing target position" 1L
        (H.current current.S.history).H.id;
      Alcotest.(check int64)
        "source identical contents retained at another position" 3L
        (L.lookup (local current) "main" |> ok Fun.id).L.cursor;
      Alcotest.(check int)
        "equal bytes need no file replacement" inode
        (Unix.lstat (Filename.concat root "private.bin")).Unix.st_ino;
      ignore (switch root "main");
      let current = load repository in
      Alcotest.(check int64)
        "same contents different node selected" 3L
        (H.current current.S.history).H.id;
      Alcotest.(check int)
        "no duplicate observation" 4
        (List.length (H.nodes current.S.history)))

let switch_same_branch_is_noop () =
  with_root (fun root ->
      let repository, _, _, _, _ = initialize root in
      write_private root "unsaved";
      let before = load repository in
      let result = switch root "main" in
      Alcotest.(check bool) "no-op reported" false result.Service.switch_applied;
      Alcotest.(check string)
        "unsaved bytes unchanged" "unsaved" (read_private root);
      Alcotest.(check bool)
        "no root publication" true
        (Raw.Stored_object_id.equal before.S.object_id
           (load repository).S.object_id))

let switch_unavailable_target () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      make_topic root capability;
      let raw = S.underlying_store repository in
      let captured, _ =
        Snapshot.scan ~root ~store:raw |> ok Snapshot.error_to_string
      in
      let target =
        Snapshot.Snapshot.load raw captured |> ok Snapshot.error_to_string
      in
      let tree =
        Snapshot.Tree.load raw (Snapshot.Snapshot.root target)
        |> ok Snapshot.error_to_string
      in
      let content =
        match List.assoc "private.bin" (Snapshot.Tree.entries tree) with
        | Snapshot.Tree.File file -> file.content
        | Snapshot.Tree.Directory _ -> Alcotest.fail "expected file"
      in
      write_private root "new source";
      Service.save ~root |> service |> ignore;
      let before = load repository in
      Unix.unlink
        (Raw.object_path raw (Snapshot.Content.stored_object_id content));
      reject "switched to missing contents"
        (Service.branch_switch ~root ~name:"topic" ~dry_run:false);
      Alcotest.(check string)
        "source bytes unchanged" "new source" (read_private root);
      Alcotest.(check bool)
        "root unchanged" true
        (Raw.Stored_object_id.equal before.S.object_id
           (load repository).S.object_id);
      Alcotest.(check bool)
        "no journal" true
        (Option.is_none
           (Yeokcham_v1_restore_journal.latest_pending ~root
           |> ok Yeokcham_v1_restore_journal.error_to_string)))

let switch_ignored_obstruction () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (Filename.concat root ".yeokchamignore")
        (fun out -> output_string out "*.private\n");
      Out_channel.with_open_bin (Filename.concat root "node") (fun out ->
          output_string out "target file");
      Service.save ~root |> service |> ignore;
      make_topic root capability;
      Unix.unlink (Filename.concat root "node");
      Unix.mkdir (Filename.concat root "node") 0o700;
      Out_channel.with_open_bin (Filename.concat root "node/secret.private")
        (fun out -> output_string out "ignored secret");
      let before = load repository in
      reject "replaced ignored directory obstruction"
        (Service.branch_switch ~root ~name:"topic" ~dry_run:false);
      Alcotest.(check string)
        "ignored secret preserved" "ignored secret"
        (In_channel.with_open_bin
           (Filename.concat root "node/secret.private")
           In_channel.input_all);
      Alcotest.(check bool)
        "refusal did not publish metadata" true
        (Raw.Stored_object_id.equal before.S.object_id
           (load repository).S.object_id))

let interrupted_switch_keeps_exact_target () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          let repository, capability, _, _, _ = initialize root in
          let target = read_private root in
          make_topic root capability;
          write_private root "private main edits";
          let child = Unix.fork () in
          if child = 0 then (
            let observe seen = if seen = boundary then Unix._exit 73 in
            ignore
              (Service.For_test.branch_switch ~observe ~root ~name:"topic"
                 ~dry_run:false);
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "stopped at actual switch boundary" true (status = Unix.WEXITED 73);
          ignore (switch root "topic");
          let current = load repository in
          Alcotest.(check string)
            "original exact target restored" target (read_private root);
          Alcotest.(check (list string))
            "target branch selected" [ "topic" ] (selected_name repository);
          Alcotest.(check int64)
            "exact target cursor" 0L (H.current current.S.history).H.id;
          Alcotest.(check int)
            "source captured only once" 2
            (List.length (H.nodes current.S.history));
          Alcotest.(check int64)
            "source private cursor retained" 1L
            (L.lookup (local current) "main" |> ok Fun.id).L.cursor;
          ignore (switch root "main");
          Alcotest.(check string)
            "source edits recoverable" "private main edits" (read_private root)))
    [
      Service.Before_safety_publish;
      Service.After_safety_publish;
      Service.Prepared_journal;
      Service.Applying_journal;
      Service.Filesystem_mutation
        (Service.Safe_apply.After_mutation, [ "private.bin" ]);
      Service.Materialized_journal;
      Service.Before_metadata_publish;
      Service.After_metadata_publish;
      Service.Published_journal;
    ]

let external_edit_after_materialized_switch () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      make_topic root capability;
      write_private root "source private";
      let child = Unix.fork () in
      if child = 0 then (
        ignore
          (Service.For_test.branch_switch
             ~observe:(fun stage ->
               if stage = Service.Materialized_journal then Unix._exit 73)
             ~root ~name:"topic" ~dry_run:false);
        Unix._exit 74);
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "materialized phase reached" true (status = Unix.WEXITED 73);
      write_private root "later external edit";
      ignore (switch root "topic");
      Alcotest.(check string)
        "later external bytes survive publication" "later external edit"
        (read_private root);
      Alcotest.(check int)
        "later edits were not captured as partial application" 2
        (List.length (H.nodes (load repository).S.history));
      Alcotest.(check bool)
        "later edits reported honestly" true
        (Service.status ~root |> service).Service.uncaptured)

module J = Yeokcham_v1_restore_journal

let with_copy_destination root run =
  let destination = root ^ "-copy" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists destination then remove destination)
    (fun () -> run destination)

let initial_snapshot repository =
  (M.active_draft (load repository).S.project).M.latest_checkpoint

let copy root snapshot destination expected_plan =
  Service.copy_out ~root ~checkpoint:snapshot ~destination ~expected_plan
  |> service

let copyout_keeps_source_private_state () =
  with_root (fun root ->
      with_copy_destination root (fun destination ->
          let repository, _, _, _, _ = initialize root in
          let target = initial_snapshot repository
          and original = read_private root in
          write_private root "source unsaved bytes";
          let before = load repository in
          let preview =
            Service.preview_copy_out ~root ~checkpoint:target ~destination
            |> service
          in
          Alcotest.(check bool)
            "preview does not apply" false preview.Service.copy_applied;
          Alcotest.(check int)
            "stable semantic plan" 64
            (String.length preview.Service.copy_plan);
          Alcotest.(check bool)
            "preview does not create output" false
            (Sys.file_exists destination);
          Alcotest.(check bool)
            "preview does not stage" false
            (Sys.file_exists (root ^ "/.yeokcham/restore-staging"));
          let result =
            copy root target destination (Some preview.Service.copy_plan)
          in
          Alcotest.(check string)
            "saved target copied" original
            (In_channel.with_open_bin
               (destination ^ "/private.bin")
               In_channel.input_all);
          Alcotest.(check string)
            "unsaved source untouched" "source unsaved bytes"
            (read_private root);
          let current = load repository in
          Alcotest.(check bool)
            "one authoritative head unchanged" true
            (Raw.Mutable_ref.equal before.S.head current.S.head);
          Alcotest.(check string)
            "namespace/counter/cursor unchanged"
            (H.encode before.S.history |> ok Fun.id)
            (H.encode current.S.history |> ok Fun.id);
          Alcotest.(check string)
            "branch selection/private position unchanged"
            (L.encode (local before) |> ok Fun.id)
            (L.encode (local current) |> ok Fun.id);
          let operation = Option.get result.Service.copy_operation in
          let pending = J.latest_pending ~root |> ok J.error_to_string in
          Alcotest.(check bool) "copy journal completed" true (pending = None);
          let resume =
            Service.recover_operation ~root ~operation:(Some operation)
            |> service |> Option.get
          in
          Alcotest.(check bool)
            "explicit identical operation retry acknowledged" true
            resume.Service.already_completed;
          Alcotest.(check bool)
            "no source restore proof invented" true
            (Service.restore_proofs ~root |> service = [])))

let[@warning "-4"] copyout_recovers_actual_journal_boundaries () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          with_copy_destination root (fun destination ->
              let repository, _, _, _, _ = initialize root in
              let target = initial_snapshot repository
              and original = read_private root in
              write_private root "unsaved source";
              let before = load repository in
              let child = Unix.fork () in
              if child = 0 then (
                let observe stage =
                  if
                    stage = boundary
                    ||
                    match (boundary, stage) with
                    | ( Service.Filesystem_mutation (expected, _),
                        Service.Filesystem_mutation (actual, _) ) ->
                        expected = actual
                    | _ -> false
                  then Unix._exit 73
                in
                ignore
                  (Service.For_test.copy_out ~observe ~root ~checkpoint:target
                     ~destination ~dry_run:false ~expected_plan:None);
                Unix._exit 74);
              let _, status = Unix.waitpid [] child in
              Alcotest.(check bool)
                "terminated at actual copy-out boundary" true
                (status = Unix.WEXITED 73);
              let journals = J.scan ~root |> ok J.error_to_string in
              let operation = J.operation_id (List.hd journals) in
              Service.recover_operation ~root ~operation:(Some operation)
              |> service |> ignore;
              Alcotest.(check string)
                "exact target after process restart" original
                (In_channel.with_open_bin
                   (destination ^ "/private.bin")
                   In_channel.input_all);
              let after = load repository in
              Alcotest.(check bool)
                "copy-out never publishes source head" true
                (Raw.Mutable_ref.equal before.S.head after.S.head);
              Alcotest.(check int)
                "no partial-tree history" 1
                (List.length (H.nodes after.S.history));
              Alcotest.(check string)
                "source unsaved bytes survive" "unsaved source"
                (read_private root))))
    [
      Service.Prepared_journal;
      Service.Applying_journal;
      Service.Filesystem_mutation (Service.Safe_apply.Before_mutation, []);
      Service.Filesystem_mutation (Service.Safe_apply.After_mutation, []);
      Service.Filesystem_mutation (Service.Safe_apply.After_sync, []);
      Service.Materialized_journal;
      Service.Published_journal;
    ]

let copyout_later_destination_edits_survive_materialized () =
  with_root (fun root ->
      with_copy_destination root (fun destination ->
          let repository, _, _, _, _ = initialize root in
          let target = initial_snapshot repository in
          let before = load repository in
          let child = Unix.fork () in
          if child = 0 then (
            ignore
              (Service.For_test.copy_out
                 ~observe:(fun stage ->
                   if stage = Service.Materialized_journal then Unix._exit 73)
                 ~root ~checkpoint:target ~destination ~dry_run:false
                 ~expected_plan:None);
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "copy was fully materialized" true (status = Unix.WEXITED 73);
          Out_channel.with_open_bin (destination ^ "/private.bin") (fun out ->
              output_string out "later destination edits");
          let result = copy root target destination None in
          Alcotest.(check bool)
            "resumed original copy" true result.Service.copy_resumed;
          Alcotest.(check string)
            "later destination bytes preserved" "later destination edits"
            (In_channel.with_open_bin
               (destination ^ "/private.bin")
               In_channel.input_all);
          Alcotest.(check bool)
            "source metadata unchanged" true
            (Raw.Mutable_ref.equal before.S.head (load repository).S.head)))

let[@warning "-4"] copyout_stale_plan_and_obstructions () =
  with_root (fun root ->
      with_copy_destination root (fun destination ->
          let repository, _, _, _, _ = initialize root in
          let target = initial_snapshot repository in
          let preview =
            Service.preview_copy_out ~root ~checkpoint:target ~destination
            |> service
          in
          Unix.mkdir destination 0o700;
          Out_channel.with_open_bin (destination ^ "/external") (fun out ->
              output_string out "keep");
          let before = load repository in
          (match
             Service.copy_out ~root ~checkpoint:target ~destination
               ~expected_plan:(Some preview.Service.copy_plan)
           with
          | Error (Service.History_error message) ->
              Alcotest.(check bool)
                "stale plan explained" true
                (String.starts_with ~prefix:"local selection plan is stale"
                   message)
          | Error error -> Alcotest.fail (Service.error_to_string error)
          | Ok _ -> Alcotest.fail "applied stale destination plan");
          Alcotest.(check string)
            "external obstruction unchanged" "keep"
            (In_channel.with_open_bin
               (destination ^ "/external")
               In_channel.input_all);
          Alcotest.(check bool)
            "metadata unchanged" true
            (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
          Alcotest.(check bool)
            "no journal reservation" true
            (J.pending ~root |> ok J.error_to_string = [])))

let[@warning "-4"] copyout_can_recover_safety_while_source_conflicts () =
  with_root (fun root ->
      with_copy_destination root (fun destination ->
          let repository, capability, _, _, _ = initialize root in
          make_topic root capability;
          write_private root "source safety B";
          let child = Unix.fork () in
          if child = 0 then (
            let observe = function
              | Service.Filesystem_mutation (Service.Safe_apply.After_sync, _)
                ->
                  Unix._exit 73
              | _ -> ()
            in
            ignore
              (Service.For_test.branch_switch ~observe ~root ~name:"topic"
                 ~dry_run:false);
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "original selection interrupted" true (status = Unix.WEXITED 73);
          write_private root "unexplained external edit";
          reject "replayed over external edit"
            (Service.branch_switch ~root ~name:"topic" ~dry_run:false);
          let pending =
            J.latest_pending ~root |> ok J.error_to_string |> Option.get
          in
          let before = load repository in
          ignore (copy root (J.safety pending) destination None);
          Alcotest.(check string)
            "saved safety available through supported recovery export"
            "source safety B"
            (In_channel.with_open_bin
               (destination ^ "/private.bin")
               In_channel.input_all);
          Alcotest.(check string)
            "conflicting live bytes preserved" "unexplained external edit"
            (read_private root);
          Alcotest.(check bool)
            "source metadata and partial-tree capture untouched" true
            (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
          Alcotest.(check string)
            "original incomplete operation preserved" (J.operation_id pending)
            (J.latest_pending ~root |> ok J.error_to_string |> Option.get
           |> J.operation_id)))

let completed_copyout_has_no_permanent_source_root () =
  with_root (fun root ->
      with_copy_destination root (fun destination ->
          let repository, _, _, _, _ = initialize root in
          let target = initial_snapshot repository in
          write_private root "later B";
          Service.save ~root |> service |> ignore;
          let result = copy root target destination None in
          let compacted =
            Service.compact ~root ~keep_recent:0 ~dry_run:false |> service
          in
          Alcotest.(check bool)
            "completed export does not pin source contents forever" true
            (List.exists (M.Snapshot_id.equal target) compacted.Service.dropped);
          Alcotest.(check bool)
            "completed copy journal pruned without source proof" true
            (List.mem
               (Option.get result.Service.copy_operation)
               compacted.Service.pruned_journals);
          Alcotest.(check int)
            "source history topology preserved" 2
            (List.length (H.nodes (load repository).S.history));
          Alcotest.(check bool)
            "copied directory remains" true
            (Sys.file_exists (destination ^ "/private.bin"))))

let () =
  Alcotest.run "Local authenticated branch state"
    [
      ( "state",
        [
          Alcotest.test_case
            "copy-out preserves source private state and previews" `Quick
            copyout_keeps_source_private_state;
          Alcotest.test_case
            "copy-out recovers actual journal and mutation boundaries" `Quick
            copyout_recovers_actual_journal_boundaries;
          Alcotest.test_case
            "copy-out Materialized retry preserves later destination edits"
            `Quick copyout_later_destination_edits_survive_materialized;
          Alcotest.test_case "stale copy plan preserves obstructions" `Quick
            copyout_stale_plan_and_obstructions;
          Alcotest.test_case
            "recovery export available while source selection conflicts" `Quick
            copyout_can_recover_safety_while_source_conflicts;
          Alcotest.test_case
            "completed export does not permanently pin source history" `Quick
            completed_copyout_has_no_permanent_source_root;
          Alcotest.test_case "private switching across fresh processes" `Quick
            private_switch_journey;
          Alcotest.test_case "equal contents keep exact branch positions" `Quick
            equal_content_switch_keeps_positions;
          Alcotest.test_case
            "same branch preserves unsaved work without capture" `Quick
            switch_same_branch_is_noop;
          Alcotest.test_case
            "unavailable branch target fails before replacement" `Quick
            switch_unavailable_target;
          Alcotest.test_case "ignored obstruction refuses before metadata"
            `Quick switch_ignored_obstruction;
          Alcotest.test_case
            "switch resumes exact target across mutation and metadata exits"
            `Quick interrupted_switch_keeps_exact_target;
          Alcotest.test_case "later external edit survives Materialized retry"
            `Quick external_edit_after_materialized_switch;
          Alcotest.test_case
            "private initialization and signed empty acceptance" `Quick
            private_initialization;
          Alcotest.test_case "creation, duplicate refusal and process restart"
            `Quick create_and_select_across_restart;
          Alcotest.test_case "invalid positions and missing records retain root"
            `Quick incomplete_records_and_invalid_positions;
          Alcotest.test_case "bounded collision and entropy refusal" `Quick
            branch_collision_and_entropy;
          Alcotest.test_case
            "logical mapping, signature and acceptance validation" `Quick
            invalid_mappings_signatures_and_acceptance;
          Alcotest.test_case
            "historical verification differs from new admission" `Quick
            historical_load_and_current_admission;
          Alcotest.test_case "unselected branch work survives compaction and GC"
            `Quick branch_work_is_a_retention_root;
        ] );
    ]
