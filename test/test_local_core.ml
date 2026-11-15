module S = Yeokcham_v1_store
module L = S.Local
module M = Yeokcham_v1_model
module C = M.Core
module T = Yeokcham_v1_trust
module Raw = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module H = Yeokcham_v1_undo
module R = Yeokcham_v1_record.Core
module Composition = Yeokcham_v1_composition
module Encoding = Yeokcham_encoding
module Pages = Yeokcham_v1_pages

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

let cli root arguments =
  let binary =
    List.find Sys.file_exists
      [ "../bin/yeokcham_v1.exe"; "_build/default/bin/yeokcham_v1.exe" ]
  in
  let output = Filename.temp_file "yeokcham-local-core-cli-" "" in
  let errors = Filename.temp_file "yeokcham-local-core-cli-errors-" "" in
  Fun.protect
    ~finally:(fun () ->
      Unix.unlink output;
      Unix.unlink errors)
    (fun () ->
      let stdout = Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let stderr = Unix.openfile errors [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let child =
        Unix.create_process binary
          (Array.of_list ((binary :: arguments) @ [ "--root"; root ]))
          Unix.stdin stdout stderr
      in
      Unix.close stdout;
      Unix.close stderr;
      let _, status = Unix.waitpid [] child in
      let read path = In_channel.with_open_bin path In_channel.input_all in
      (status, read output, read errors))

let failed_inspection_cli root command exit_code code =
  let status, output, errors = cli root [ command; "--format"; "json" ] in
  Alcotest.(check bool)
    (command ^ " inspection exit: " ^ errors)
    true
    (status = Unix.WEXITED exit_code);
  let json = Yojson.Safe.from_string output in
  let open Yojson.Safe.Util in
  Alcotest.(check int)
    "domain JSON schema" 2
    (json |> member "schema_version" |> to_int);
  Alcotest.(check string)
    "actionable inspection code" code
    (json |> member "code" |> to_string);
  Alcotest.(check bool)
    "failure preserves domain result" true
    (json |> member "data" <> `Null);
  List.iter
    (fun action ->
      let arguments =
        action |> member "arguments" |> to_list |> List.map to_string
      in
      Alcotest.(check bool)
        "unverified state suggests no write/recovery action" true
        (List.for_all
           (fun argument ->
             not (List.mem argument [ "undo"; "restore"; "integrate"; "save" ]))
           arguments))
    (json |> member "next_actions" |> to_list);
  json |> member "data"

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
          | C.Shared_revision _ | C.Resolution_revision _ ->
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
           (L.encode local0 |> ok Fun.id));
      reject "metadata fabricated a missing signed record"
        (S.inspect_repository ~root))

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
      reject "metadata trusted a bad signature"
        (L.Metadata.decode ~store ~authority (append_record invalid));
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
        (L.decode ~store ~authority swapped);
      reject "metadata trusted a swapped logical/physical mapping"
        (L.Metadata.decode ~store ~authority swapped);
      reject "metadata ignored its control size bound"
        (L.Metadata.decode ~store ~authority
           (String.make ((8 * 1024 * 1024) + 1) 'x'));
      (match fields with
      | Encoding.Array (_ :: rest) ->
          reject "metadata accepted an unsupported mandatory control version"
            (L.Metadata.decode ~store ~authority
               (array (Encoding.integer 99L :: rest) |> Encoding.encode))
      | _ -> Alcotest.fail "expected canonical control fields");
      match fields with
      | Encoding.Array
          [
            version;
            empty;
            selected;
            Encoding.Array (first :: records);
            positions;
          ] ->
          reject "metadata accepted duplicate canonical record references"
            (L.Metadata.decode ~store ~authority
               (array
                  [
                    version;
                    empty;
                    selected;
                    array (first :: first :: records);
                    positions;
                  ]
               |> Encoding.encode))
      | _ -> Alcotest.fail "expected canonical record references")

let[@warning "-4"] divergent_names_are_retained_and_refused () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let original = load repository |> local in
      let row = List.hd (L.branches original) in
      let store = S.underlying_store repository in
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
      let array values =
        Yeokcham_encoding.array values
        |> ok Yeokcham_encoding.construction_error_to_string
      in
      let mappings =
        [ "left"; "right" ]
        |> List.map (fun name ->
            let payload =
              C.make_branch_event ~branch:row.C.branch_id
                ~previous_events:row.C.event_heads ~action:C.Rename ~targets:[]
                ~display_name:(Some name)
              |> model
            in
            let body = C.make_body ~context ~payload:(C.Branch_event payload) in
            let signed =
              T.Core.sign authority capability body |> ok T.Core.error_to_string
            in
            let id = R.id signed |> ok R.error_to_string in
            let envelope =
              R.encode signed |> ok R.error_to_string
              |> Yeokcham_envelope.decode
              |> ok Yeokcham_envelope.decode_error_to_string
            in
            let stored = Raw.put store envelope |> ok Raw.error_to_string in
            array
              [
                Yeokcham_encoding.bytes (C.Record_id.to_raw id);
                Yeokcham_encoding.bytes
                  (Raw.Stored_object_id.to_raw_bytes stored);
              ])
      in
      let encoded =
        L.encode original |> ok Fun.id |> Yeokcham_encoding.decode
        |> ok Yeokcham_encoding.decode_error_to_string
      in
      let encoded =
        match encoded with
        | Yeokcham_encoding.Array
            [
              version;
              empty;
              selected;
              Yeokcham_encoding.Array records;
              positions;
            ] ->
            let records =
              List.sort
                (fun a b ->
                  String.compare
                    (Yeokcham_encoding.encode a)
                    (Yeokcham_encoding.encode b))
                (mappings @ records)
            in
            array [ version; empty; selected; array records; positions ]
            |> Yeokcham_encoding.encode
        | _ -> Alcotest.fail "unexpected local core schema"
      in
      let state = L.decode ~store ~authority encoded |> ok Fun.id in
      let row = List.hd (L.branches state) in
      Alcotest.(check (list string))
        "concurrent names retained" [ "left"; "right" ] row.C.display_names;
      Alcotest.(check int)
        "concurrent event heads retained" 2
        (List.length row.C.event_heads);
      reject "lookup selected a divergent causal head" (L.lookup state "left");
      reject "selection silently chose a divergent head"
        (L.select state row.C.branch_id);
      Alcotest.(check bool)
        "published state untouched" true
        (L.encode original = L.encode (load repository |> local)))

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

let snapshot_selection_reserves_provisional_target_atomically () =
  with_root (fun root ->
      let repository, _, _, _, _ = initialize root in
      let before = load repository in
      let local = local before in
      let empty = snapshot (C.Object_id.to_hex (L.empty_snapshot local)) in
      let preview =
        Service.navigate_history ~root
          ~direction:(Service.Restore_snapshot empty) ~dry_run:true
        |> service
      in
      Alcotest.(check bool)
        "new separate root is provisional" true
        preview.Service.target_provisional;
      Alcotest.(check int)
        "preview has no durable reservation" 1
        (List.length (H.nodes (load repository).S.history));
      let result =
        Service.navigate_history_plan ~root
          ~direction:(Service.Restore_snapshot empty) ~dry_run:false
          ~expected_plan:preview.Service.selection_plan
        |> service
      in
      Alcotest.(check bool)
        "published node no longer provisional" false
        result.Service.target_provisional;
      Alcotest.(check (option int64))
        "no invented local ancestry" None result.Service.target_node.H.parent;
      Alcotest.(check int64)
        "reserved node published once" 1L result.Service.target_node.H.id;
      Alcotest.(check (option int64))
        "counter advances with target" (Some 2L)
        (H.next_sequence (load repository).S.history);
      Alcotest.(check bool)
        "exact empty version selected" false
        (Sys.file_exists (Filename.concat root "private.bin"));
      Service.navigate_history ~root ~direction:(Service.Go_to 0L)
        ~dry_run:false
      |> service |> ignore;
      Alcotest.(check string)
        "initial private files still recoverable" "private\000bytes\255"
        (read_private root))

let branch_plan_rejects_changed_inputs () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      make_topic root capability;
      write_private root "B";
      let preview =
        Service.branch_switch ~root ~name:"topic" ~dry_run:true |> service
      in
      write_private root "changed after preview";
      let before = load repository in
      reject "stale named selection applied"
        (Service.branch_switch_plan ~root ~name:"topic" ~dry_run:false
           ~expected_plan:preview.Service.switch_plan);
      Alcotest.(check bool)
        "stale plan preserves head" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "stale plan preserves bytes" "changed after preview" (read_private root))

let verified_shared_records_and_nonempty_fork () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let before = load repository in
      let store = S.underlying_store repository in
      let local_before = local before in
      let base = L.empty_snapshot local_before in
      let content =
        Snapshot.Content.store store "D shared\n" |> ok Snapshot.error_to_string
      in
      let result =
        Composition.tree
          [
            ( [ "note.txt" ],
              Composition.File { mode = Snapshot.Regular; content } );
          ]
        |> ok Composition.error_to_string
      in
      let result =
        Composition.store store result |> ok Composition.error_to_string
      in
      let scope =
        Composition.Scope.store store [ [ "note.txt" ] ]
        |> ok Composition.error_to_string
      in
      let staged, revision =
        L.prepare_revision ~store ~authority ~certificate
          ~signing_capability:capability ~change:None ~previous_revisions:[]
          ~base_snapshot:base ~result_snapshot:result ~edit_scope_root:scope
          ~dependencies:[] local_before
        |> ok Fun.id
      in
      Alcotest.(check bool)
        "signed staging has no root publication" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      let published =
        S.save_collaborative repository ~expected:before.S.head
          ~project:before.S.project
          ~collaboration:(Option.get before.S.collaboration)
          ~local:staged
        |> ok S.error_to_string
      in
      let revision_body =
        C.find (L.pool (local published)) revision |> Option.get
      in
      let change =
        match revision_body.C.payload with
        | C.Shared_revision value -> value.C.change
        | C.Accepted_version _ | C.Branch_event _ | C.Resolution_revision _ ->
            Alcotest.fail "missing staged shared revision"
      in
      let calls = ref 0 in
      reject "change identity collision created another root"
        (L.For_test.fresh_change
           ~random_bytes:(fun n ->
             incr calls;
             Alcotest.(check int) "128-bit change ID" 16 n;
             Ok (C.Change_id.to_raw change))
           (local published));
      Alcotest.(check int) "change collision attempts bounded" 3 !calls;
      Out_channel.with_open_bin (Filename.concat root "note.txt") (fun output ->
          Out_channel.output_string output "D shared\n");
      Service.save ~root |> service |> ignore;
      let captured = load repository in
      let selected_local = captured.S.local |> Option.get in
      let accepted, accepted_id =
        L.prepare_acceptance ~store ~authority ~certificate
          ~signing_capability:capability
          ~parents:(List.hd (L.branches selected_local)).C.accepted_heads
          ~chosen_revisions:[ revision ] ~result_snapshot:result
          ~cursor:(H.current captured.S.history).H.id selected_local
        |> ok Fun.id
      in
      Alcotest.(check bool)
        "metadata staging did not publish acceptance" true
        (Raw.Mutable_ref.equal captured.S.head (load repository).S.head);
      let committed =
        S.save_collaborative repository ~expected:captured.S.head
          ~project:captured.S.project
          ~collaboration:(Option.get captured.S.collaboration)
          ~local:accepted
        |> ok S.error_to_string
      in
      let loaded = load repository in
      Alcotest.(check bool)
        "verified nonempty acceptance survives reload" true
        (C.Record_id.equal (L.selected (local loaded)).L.basis accepted_id);
      Alcotest.(check string)
        "private captured bytes remain private working files"
        "private\000bytes\255" (read_private root);
      let public_tree =
        Composition.load store result |> ok Composition.error_to_string
      in
      Alcotest.(check bool)
        "accepted result excludes private file" false
        (List.mem_assoc [ "private.bin" ] (Composition.entries public_tree));
      let plan =
        Yeokcham_v1_gc.plan ~root |> ok Yeokcham_v1_gc.error_to_string
      in
      let snapshot_id =
        Raw.Stored_object_id.of_hex (C.Object_id.to_hex result)
        |> ok Raw.Stored_object_id.parse_error_to_string
      in
      let protected =
        List.find
          (fun entry ->
            Raw.Stored_object_id.equal entry.Yeokcham_v1_gc.object_id
              snapshot_id)
          plan.Yeokcham_v1_gc.objects
      in
      (match protected.Yeokcham_v1_gc.disposition with
      | Yeokcham_v1_gc.Retain reasons ->
          Alcotest.(check bool)
            "derived public snapshot has a shared-history root" true
            (List.exists
               (fun reason ->
                 String.starts_with ~prefix:"shared-history "
                   (Yeokcham_v1_gc.root_reason_to_string reason))
               reasons)
      | Yeokcham_v1_gc.Collect ->
          Alcotest.fail "collection would lose a derived selected public result");
      ignore (Yeokcham_v1_gc.apply ~root |> ok Yeokcham_v1_gc.error_to_string);
      Composition.load store result |> ok Composition.error_to_string |> ignore;
      ignore (load repository);
      let fork =
        L.create_branch ~store ~authority ~certificate
          ~signing_capability:capability ~name:"nonempty-fork"
          ~cursor:(H.current committed.S.history).H.id (local committed)
        |> ok Fun.id
      in
      let position = L.lookup fork "nonempty-fork" |> ok Fun.id in
      let version =
        Composition.Graph.accepted (L.pool fork) position.L.basis
        |> ok Composition.Graph.error_to_string
      in
      Alcotest.(check bool)
        "fork carries verified nonempty accepted result" true
        (C.Object_id.equal version.C.result_snapshot result);
      ignore
        (S.save_collaborative repository ~expected:committed.S.head
           ~project:committed.S.project
           ~collaboration:(Option.get committed.S.collaboration)
           ~local:fork
        |> ok S.error_to_string);
      Alcotest.(check int)
        "both shared branches persist" 2
        (List.length (L.branches (local (load repository)))))

let[@warning "-4"] signed_false_acceptance_cannot_enter_local_state () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let before = load repository in
      let local = local before in
      let store = S.underlying_store repository in
      let selected = L.selected local in
      let private_snapshot =
        M.active_draft before.S.project |> fun draft ->
        draft.M.latest_checkpoint |> M.Snapshot_id.to_string
        |> C.Object_id.of_hex |> model
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
      let payload =
        C.make_accepted_version ~branch:selected.L.branch
          ~accepted_parents:[ selected.L.basis ] ~chosen_revisions:[]
          ~resolutions:[] ~result_snapshot:private_snapshot
          ~composition_profile:"line-hunks-v1" ~policy_heads:[]
          ~review_evidence:[]
        |> model
      in
      let signed =
        T.Core.sign authority capability
          (C.make_body ~context ~payload:(C.Accepted_version payload))
        |> ok T.Core.error_to_string
      in
      T.Core.verify authority signed |> ok T.Core.error_to_string;
      let id = R.id signed |> ok R.error_to_string in
      let envelope =
        R.encode signed |> ok R.error_to_string |> Yeokcham_envelope.decode
        |> ok Yeokcham_envelope.decode_error_to_string
      in
      let stored = Raw.put store envelope |> ok Raw.error_to_string in
      let array values =
        Yeokcham_encoding.array values
        |> ok Yeokcham_encoding.construction_error_to_string
      in
      let pair =
        array
          [
            Yeokcham_encoding.bytes (C.Record_id.to_raw id);
            Yeokcham_encoding.bytes (Raw.Stored_object_id.to_raw_bytes stored);
          ]
      in
      let encoded =
        L.encode local |> ok Fun.id |> Yeokcham_encoding.decode
        |> ok Yeokcham_encoding.decode_error_to_string
      in
      let encoded =
        match encoded with
        | Yeokcham_encoding.Array
            [
              version;
              empty;
              selected;
              Yeokcham_encoding.Array references;
              positions;
            ] ->
            let references =
              List.sort
                (fun a b ->
                  String.compare
                    (Yeokcham_encoding.encode a)
                    (Yeokcham_encoding.encode b))
                (pair :: references)
            in
            array [ version; empty; selected; array references; positions ]
            |> Yeokcham_encoding.encode
        | _ -> Alcotest.fail "unexpected local core schema"
      in
      (match L.decode ~store ~authority encoded with
      | Error message ->
          Alcotest.(check bool)
            "refused actual composition mismatch after valid signature" true
            (String.starts_with
               ~prefix:"invalid shared graph: accepted snapshot" message)
      | Ok _ ->
          Alcotest.fail
            "a valid signature replaced accepted contents with private bytes");
      let metadata = L.Metadata.decode ~store ~authority encoded |> ok Fun.id in
      Alcotest.(check bool)
        "metadata inspection does not prove a signed false result" true
        (match L.Metadata.verify_contents ~store metadata with
        | Error (Composition.Graph.Invalid_graph _) -> true
        | _ -> false);
      Alcotest.(check bool)
        "refusal retains root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      let envelope =
        Raw.get store before.S.object_id |> ok Raw.error_to_string
      in
      let payload =
        match Yeokcham_envelope.payload envelope with
        | Encoding.Array [ tag; version; inner; history; _ ] ->
            array [ tag; version; inner; history; Encoding.bytes encoded ]
        | _ -> Alcotest.fail "expected current local wrapper"
      in
      let target =
        Yeokcham_envelope.create ~object_type:Yeokcham_envelope.V1_project_state
          ~object_format_version:Yeokcham_envelope.current_object_format_version
          ~mandatory_features:Yeokcham_envelope.supported_mandatory_features
          ~payload ()
        |> ok Yeokcham_envelope.creation_error_to_string
        |> Raw.put store |> ok Raw.error_to_string
      in
      let forged_head =
        Raw.compare_and_swap_ref store ~name:S.state_head_name
          ~expected:(Some before.S.head) ~target:(Some target)
        |> ok Raw.error_to_string
      in
      reject "live false accepted claim passed strict load" (S.load repository);
      (match S.inspect repository |> ok S.error_to_string with
      | S.Verified _ ->
          Alcotest.fail "signed false result authorized writable state"
      | S.Metadata_only metadata ->
          Alcotest.(check bool)
            "live metadata retains explicit invalid proof" true
            (match metadata.S.metadata_contents with
            | Some (Error (Composition.Graph.Invalid_graph _)) -> true
            | _ -> false));
      let open Yojson.Safe.Util in
      let status =
        failed_inspection_cli root "status" 6 "saved-state-unverified"
      in
      Alcotest.(check string)
        "signatures are distinct from result proof" "verified"
        (status |> member "record_signatures" |> to_string);
      Alcotest.(check string)
        "false result state is unverified" "unverified"
        (status |> member "state_validation" |> member "state" |> to_string);
      let history =
        failed_inspection_cli root "history" 6 "saved-state-unverified"
      in
      Alcotest.(check int)
        "invalid proof still exposes real private history"
        (List.length (H.nodes before.S.history))
        (history |> member "entries" |> to_list |> List.length);
      let exit_status, _, errors = cli root [ "save"; "--format"; "json" ] in
      Alcotest.(check bool)
        ("false proof refuses CLI save: " ^ errors)
        true
        (exit_status = Unix.WEXITED 6);
      Alcotest.(check bool)
        "all false-proof inspection/refusal preserves root" true
        (Raw.Mutable_ref.equal forged_head
           (Option.get
              (Raw.read_ref store ~name:S.state_head_name
              |> ok Raw.error_to_string))))

let stage_publication root =
  let repository, capability, certificate, authority, _ = initialize root in
  Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
      output_string out "selected D\n");
  Service.save ~root |> service |> ignore;
  let before = load repository in
  let store = S.underlying_store repository in
  let content =
    Snapshot.Content.store store "selected D\n" |> ok Snapshot.error_to_string
  in
  let result =
    Composition.tree
      [
        ([ "note.txt" ], Composition.File { mode = Snapshot.Regular; content });
      ]
    |> ok Composition.error_to_string
    |> Composition.store store
    |> ok Composition.error_to_string
  in
  let scope =
    Composition.Scope.store store [ [ "note.txt" ] ]
    |> ok Composition.error_to_string
  in
  let staged, revision =
    L.prepare_revision ~store ~authority ~certificate
      ~signing_capability:capability ~change:None ~previous_revisions:[]
      ~base_snapshot:(L.empty_snapshot (local before))
      ~result_snapshot:result ~edit_scope_root:scope ~dependencies:[]
      (local before)
    |> ok Fun.id
  in
  let source =
    H.identity before.S.history (H.current before.S.history) |> ok Fun.id
  in
  let observed =
    C.Object_id.of_hex
      (M.Snapshot_id.to_string (H.current before.S.history).H.snapshot)
    |> model
  in
  let intent = C.Digest.of_raw (String.make 32 'i') |> model in
  (repository, before, staged, revision, source, observed, scope, intent)

let publication_receipts_are_atomic_and_retryable () =
  with_root (fun root ->
      let ( repository,
            before,
            staged,
            revision,
            source,
            observed,
            contributed_scope,
            intent ) =
        stage_publication root
      in
      let store = S.underlying_store repository in
      let publication_state, receipt =
        L.record_publication ~store ~intent ~revision ~source ~observed
          ~contributed_scope ~title:"Selected note" staged
        |> ok Fun.id
      in
      Alcotest.(check bool)
        "staging does not publish root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      let retry, repeated =
        L.For_test.record_publication
          ~random_bytes:(fun _ -> Alcotest.fail "retry requested entropy")
          ~store ~intent ~revision ~source ~observed ~contributed_scope
          ~title:"Selected note" publication_state
        |> ok Fun.id
      in
      Alcotest.(check bool)
        "same recorded operation" true
        (C.Operation_id.equal receipt.L.operation repeated.L.operation);
      Alcotest.(check string)
        "identical receipt state"
        (L.encode publication_state |> ok Fun.id)
        (L.encode retry |> ok Fun.id);
      reject "same intent retitled"
        (L.record_publication ~store ~intent ~revision ~source ~observed
           ~contributed_scope ~title:"different" publication_state);
      let attempts = ref 0 in
      reject "operation collision reused identity for different intent"
        (L.For_test.record_publication
           ~random_bytes:(fun n ->
             incr attempts;
             Alcotest.(check int) "128-bit operation" 16 n;
             Ok (C.Operation_id.to_raw receipt.L.operation))
           ~store
           ~intent:(C.Digest.of_raw (String.make 32 'j') |> model)
           ~revision ~source ~observed ~contributed_scope ~title:"Selected note"
           publication_state);
      Alcotest.(check int) "bounded operation collisions" 3 !attempts;
      let committed =
        S.save_collaborative ~local:publication_state repository
          ~expected:before.S.head ~project:before.S.project
          ~collaboration:(Option.get before.S.collaboration)
        |> ok S.error_to_string
      in
      Alcotest.(check bool)
        "receipt and record share one root" true
        (Option.is_some (C.find (L.pool (local committed)) revision));
      reject "receipt erased by later update"
        (L.validate_update ~previous:(local committed) staged);
      let child = Unix.fork () in
      if child = 0 then (
        let fresh = S.open_repository ~root |> ok S.error_to_string |> load in
        let durable = L.find_publication (local fresh) ~intent |> Option.get in
        if not (C.Operation_id.equal durable.L.operation receipt.L.operation)
        then Unix._exit 72;
        Unix._exit 0);
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "fresh process retains exact publication/outbound identity" true
        (status = Unix.WEXITED 0))

let publication_rejects_unwitnessed_or_foreign_sources () =
  with_root (fun root ->
      let ( repository,
            before,
            staged,
            revision,
            source,
            observed,
            contributed_scope,
            intent ) =
        stage_publication root
      in
      let store = S.underlying_store repository in
      let wrong_observation =
        C.Object_id.of_hex
          (M.Snapshot_id.to_string
             (List.hd (H.nodes before.S.history)).H.snapshot)
        |> model
      in
      reject "unobserved public path accepted"
        (L.record_publication ~store ~intent ~revision ~source
           ~observed:wrong_observation ~contributed_scope ~title:"note" staged);
      let wrong_scope =
        Composition.Scope.store store [ [ "note.txt" ]; [ "private.bin" ] ]
        |> ok Composition.error_to_string
      in
      reject "unselected private scope used as correspondence"
        (L.record_publication ~store ~intent ~revision ~source ~observed
           ~contributed_scope:wrong_scope ~title:"note" staged);
      let source =
        C.History_id.make
          ~workspace:(C.Workspace_id.of_raw (String.make 16 'z') |> model)
          ~sequence:(C.History_id.sequence source)
        |> model
      in
      let foreign, _ =
        L.record_publication ~store ~intent ~revision ~source ~observed
          ~contributed_scope ~title:"note" staged
        |> ok Fun.id
      in
      reject "foreign history source committed"
        (S.save_collaborative ~local:foreign repository ~expected:before.S.head
           ~project:before.S.project
           ~collaboration:(Option.get before.S.collaboration));
      Alcotest.(check bool)
        "invalid correspondence leaves root unchanged" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head))

let publication_witness_survives_private_content_collection () =
  with_root (fun root ->
      let ( repository,
            before,
            staged,
            revision,
            source,
            observed,
            contributed_scope,
            intent ) =
        stage_publication root
      in
      let store = S.underlying_store repository in
      let state, receipt =
        L.record_publication ~store ~intent ~revision ~source ~observed
          ~contributed_scope ~title:"note" staged
        |> ok Fun.id
      in
      S.save_collaborative ~local:state repository ~expected:before.S.head
        ~project:before.S.project
        ~collaboration:(Option.get before.S.collaboration)
      |> ok S.error_to_string |> ignore;
      let original =
        Composition.load store observed
        |> ok Composition.error_to_string
        |> Composition.entries
      in
      let private_content =
        match List.assoc [ "private.bin" ] original with
        | Composition.File file ->
            Snapshot.Content.stored_object_id file.content
        | Composition.Directory -> Alcotest.fail "private file expected"
      in
      write_private root "later unselected private contents";
      Service.save ~root |> service |> ignore;
      Service.compact ~root ~keep_recent:0 ~dry_run:false |> service |> ignore;
      let plan =
        Yeokcham_v1_gc.plan ~root |> ok Yeokcham_v1_gc.error_to_string
      in
      let private_entry =
        List.find
          (fun entry ->
            Raw.Stored_object_id.equal entry.Yeokcham_v1_gc.object_id
              private_content)
          plan.Yeokcham_v1_gc.objects
      in
      Alcotest.(check bool)
        "old unselected blob is collectible" true
        (private_entry.Yeokcham_v1_gc.disposition = Yeokcham_v1_gc.Collect);
      List.iter
        (fun id ->
          let entry =
            List.find
              (fun entry ->
                Raw.Stored_object_id.equal entry.Yeokcham_v1_gc.object_id id)
              plan.Yeokcham_v1_gc.objects
          in
          Alcotest.(check bool)
            "exact witness retained" true
            (entry.Yeokcham_v1_gc.disposition <> Yeokcham_v1_gc.Collect))
        receipt.L.witnesses;
      Yeokcham_v1_gc.apply ~root |> ok Yeokcham_v1_gc.error_to_string |> ignore;
      List.iter
        (fun id -> Raw.get store id |> ok Raw.error_to_string |> ignore)
        receipt.L.witnesses;
      let revision =
        match C.find (L.pool state) revision with
        | Some { C.payload = C.Shared_revision revision; _ } -> revision
        | None
        | Some
            {
              C.payload =
                ( C.Accepted_version _ | C.Branch_event _
                | C.Resolution_revision _ );
              _;
            } ->
            Alcotest.fail "expected shared revision"
      in
      Composition.load store revision.C.base_snapshot
      |> ok Composition.error_to_string
      |> ignore;
      Composition.load store revision.C.result_snapshot
      |> ok Composition.error_to_string
      |> ignore;
      reject "old private capture unexpectedly complete after collection"
        (Composition.load store observed);
      let fresh = load repository in
      let durable = L.find_publication (local fresh) ~intent |> Option.get in
      Alcotest.(check bool)
        "selected correspondence survives unrelated blob collection" true
        (C.Operation_id.equal receipt.L.operation durable.L.operation);
      Alcotest.(check string)
        "later working bytes intact" "later unselected private contents"
        (read_private root))

let publication_update_witnesses_only_newly_selected_edits () =
  with_root (fun root ->
      let repository, before, _, _, source, observed, contributed_scope, intent
          =
        stage_publication root
      in
      let capability, _, certificate, authority, _ = fixture () in
      let store = S.underlying_store repository in
      let file text =
        let content =
          Snapshot.Content.store store text |> ok Snapshot.error_to_string
        in
        Composition.File { mode = Snapshot.Regular; content }
      in
      let previous_tree =
        Composition.tree
          [
            ([ "note.txt" ], file "old remote note\n");
            ([ "remote.txt" ], file "remote carried work\n");
          ]
        |> ok Composition.error_to_string
      in
      let previous_result =
        Composition.store store previous_tree |> ok Composition.error_to_string
      in
      let whole_scope =
        Composition.Scope.store store [ [ "note.txt" ]; [ "remote.txt" ] ]
        |> ok Composition.error_to_string
      in
      let staged, previous =
        L.prepare_revision ~store ~authority ~certificate
          ~signing_capability:capability ~change:None ~previous_revisions:[]
          ~base_snapshot:(L.empty_snapshot (local before))
          ~result_snapshot:previous_result ~edit_scope_root:whole_scope
          ~dependencies:[] (local before)
        |> ok Fun.id
      in
      let change =
        match C.find (L.pool staged) previous with
        | Some { C.payload = C.Shared_revision value; _ } -> value.C.change
        | None
        | Some
            {
              C.payload =
                ( C.Accepted_version _ | C.Branch_event _
                | C.Resolution_revision _ );
              _;
            } ->
            Alcotest.fail "expected revision"
      in
      let updated =
        Composition.tree
          [
            ([ "note.txt" ], file "selected D\n");
            ([ "remote.txt" ], file "remote carried work\n");
          ]
        |> ok Composition.error_to_string
        |> Composition.store store
        |> ok Composition.error_to_string
      in
      let staged, revision =
        L.prepare_revision ~store ~authority ~certificate
          ~signing_capability:capability ~change:(Some change)
          ~previous_revisions:[ previous ]
          ~base_snapshot:(L.empty_snapshot staged) ~result_snapshot:updated
          ~edit_scope_root:whole_scope ~dependencies:[] staged
        |> ok Fun.id
      in
      reject "carried remote path claimed as locally observed"
        (L.record_publication ~store ~intent ~revision ~source ~observed
           ~contributed_scope:whole_scope ~title:"Update note" staged);
      let state, receipt =
        L.record_publication ~store ~intent ~revision ~source ~observed
          ~contributed_scope ~title:"Update note" staged
        |> ok Fun.id
      in
      let committed =
        S.save_collaborative ~local:state repository ~expected:before.S.head
          ~project:before.S.project
          ~collaboration:(Option.get before.S.collaboration)
        |> ok S.error_to_string
      in
      let reloaded =
        L.find_publication (local committed) ~intent |> Option.get
      in
      Alcotest.(check bool)
        "carried remote fields are not local correspondence" true
        (C.Object_id.equal reloaded.L.contributed_scope
           receipt.L.contributed_scope);
      Alcotest.(check bool)
        "private source never contained carried remote file" false
        (Sys.file_exists (root ^ "/remote.txt")))

let selected_share root capability ?update paths =
  Service.share_selected ~root ~paths ~update ~title:None ~dry_run:false
    ~signing_capability:(Some capability)
  |> service

let native_share_captures_only_selected_public_work () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "unsaved selected D\n");
      let before = load repository in
      let preview =
        Service.share_selected ~root ~paths:[ [ "note.txt" ] ] ~update:None
          ~title:None ~dry_run:true ~signing_capability:None
        |> service
      in
      Alcotest.(check bool)
        "preview generates no change identity" true
        (preview.Service.Share.change = None);
      Alcotest.(check bool)
        "preview preserves authoritative root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let receipt = shared.Service.Share.publication |> Option.get in
      let after = load repository in
      Alcotest.(check int)
        "capture and publication in one history step" 2
        (List.length (H.nodes after.S.history));
      Alcotest.(check int)
        "one durable outbound receipt" 1
        (List.length (L.publications (local after)));
      Alcotest.(check bool)
        "publication source is exact captured history" true
        (C.History_id.equal receipt.L.source
           (H.identity after.S.history (H.current after.S.history) |> ok Fun.id));
      let public =
        Composition.load
          (S.underlying_store repository)
          shared.Service.Share.public_snapshot
        |> ok Composition.error_to_string
        |> Composition.entries
      in
      Alcotest.(check (list (list string)))
        "public tree contains selected path" [ [ "note.txt" ] ]
        (List.map fst public);
      Alcotest.(check bool)
        "sharing does not advance accepted basis" true
        (C.Record_id.equal (L.selected (local before)).L.basis
           (L.selected (local after)).L.basis);
      let again = selected_share root capability [ [ "note.txt" ] ] in
      Alcotest.(check bool) "retry reported" true again.Service.Share.repeated;
      Alcotest.(check bool)
        "recorded revision identity reused" true
        (Option.equal C.Record_id.equal shared.Service.Share.revision
           again.Service.Share.revision);
      Alcotest.(check bool)
        "retry does not republish root" true
        (Raw.Mutable_ref.equal after.S.head (load repository).S.head);
      Alcotest.(check string)
        "unselected bytes remain private" "private\000bytes\255"
        (read_private root))

let native_share_updates_are_explicit_and_immutable () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "first\n");
      let first = selected_share root capability [ [ "note.txt" ] ] in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "second\n");
      write_private root "private E\000";
      let second =
        selected_share root capability
          ~update:(Option.get first.Service.Share.change)
          [ [ "note.txt" ] ]
      in
      Alcotest.(check bool)
        "same change identity" true
        (Option.equal C.Change_id.equal first.Service.Share.change
           second.Service.Share.change);
      Alcotest.(check bool)
        "new immutable revision" false
        (Option.equal C.Record_id.equal first.Service.Share.revision
           second.Service.Share.revision);
      let loaded = load repository in
      let body =
        C.find
          (L.pool (local loaded))
          (Option.get second.Service.Share.revision)
        |> Option.get
      in
      (match body.C.payload with
      | C.Shared_revision version ->
          Alcotest.(check bool)
            "exact predecessor" true
            (version.C.previous_revisions
            = [ Option.get first.Service.Share.revision ])
      | C.Accepted_version _ | C.Branch_event _ | C.Resolution_revision _ ->
          Alcotest.fail "expected revision");
      Alcotest.(check int)
        "both publications durable" 2
        (List.length (L.publications (local loaded)));
      Alcotest.(check string)
        "private E never overwritten" "private E\000" (read_private root);
      let unchanged =
        selected_share root capability
          ~update:(Option.get first.Service.Share.change)
          [ [ "note.txt" ] ]
      in
      Alcotest.(check bool)
        "unchanged update reuses recorded publication" true
        unchanged.Service.Share.repeated;
      Alcotest.(check bool)
        "unchanged update has same revision" true
        (Option.equal C.Record_id.equal unchanged.Service.Share.revision
           second.Service.Share.revision);
      Alcotest.(check bool)
        "no-op retains root" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head))

let native_share_recovers_atomic_root_and_lost_ack () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          let repository, capability, _, _, _ = initialize root in
          Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
              output_string out "selected before interruption\n");
          let before = load repository in
          let child = Unix.fork () in
          if child = 0 then (
            ignore
              (Service.For_test.share_selected
                 ~observe:(fun stage -> if stage = boundary then Unix._exit 73)
                 ~root ~paths:[ [ "note.txt" ] ] ~update:None ~title:None
                 ~dry_run:false ~signing_capability:(Some capability));
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "stopped at actual root boundary" true (status = Unix.WEXITED 73);
          let interrupted = load repository in
          let committed = boundary = Service.After_metadata_publish in
          Alcotest.(check int)
            "history and outbound state commit together"
            (if committed then 1 else 0)
            (List.length (L.publications (local interrupted)));
          Alcotest.(check int)
            "capture never published separately"
            (if committed then 2 else 1)
            (List.length (H.nodes interrupted.S.history));
          if not committed then
            Alcotest.(check bool)
              "uncommitted root unchanged" true
              (Raw.Mutable_ref.equal before.S.head interrupted.S.head);
          let result = selected_share root capability [ [ "note.txt" ] ] in
          let after = load repository in
          Alcotest.(check bool)
            "recorded retry reuses identity" committed
            result.Service.Share.repeated;
          Alcotest.(check int)
            "one captured node after restart" 2
            (List.length (H.nodes after.S.history));
          Alcotest.(check int)
            "one revision after restart" 3
            (List.length (L.record_objects (local after)));
          Alcotest.(check int)
            "one outbound receipt after restart" 1
            (List.length (L.publications (local after)));
          if committed then
            Alcotest.(check bool)
              "lost response adds no root update" true
              (Raw.Mutable_ref.equal interrupted.S.head after.S.head)))
    [ Service.Before_metadata_publish; Service.After_metadata_publish ]

let native_share_refuses_excluded_paths_and_incomplete_capture () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/.yeokchamignore") (fun out ->
          output_string out "private.bin\n");
      let before = load repository in
      reject "ignored path explicitly published"
        (Service.share_selected ~root ~paths:[ [ "private.bin" ] ] ~update:None
           ~title:None ~dry_run:false ~signing_capability:(Some capability));
      Alcotest.(check bool)
        "ignored selection leaves root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Out_channel.with_open_bin (root ^ "/.yeokchamignore") (fun out ->
          output_string out "[bad\n");
      reject "malformed ignore capture published"
        (Service.share_selected ~root ~paths:[] ~update:None ~title:None
           ~dry_run:false ~signing_capability:(Some capability));
      Alcotest.(check bool)
        "incomplete capture leaves last complete state" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head))

let native_share_uses_observed_rules_for_missing_public_paths () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "accepted note\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let loaded = load repository in
      let store = S.underlying_store repository in
      let accepted, _ =
        L.prepare_acceptance ~store ~authority ~certificate
          ~signing_capability:capability
          ~parents:[ (L.selected (local loaded)).L.basis ]
          ~chosen_revisions:[ Option.get shared.Service.Share.revision ]
          ~result_snapshot:shared.Service.Share.public_snapshot
          ~cursor:(H.current loaded.S.history).H.id (local loaded)
        |> ok Fun.id
      in
      let loaded =
        S.save_collaborative ~local:accepted repository ~expected:loaded.S.head
          ~project:loaded.S.project
          ~collaboration:(Option.get loaded.S.collaboration)
        |> ok S.error_to_string
      in
      Out_channel.with_open_bin (root ^ "/.yeokchamignore") (fun out ->
          output_string out "note.txt\nprivate.bin\n");
      let identity, _, observation =
        Snapshot.Observation.scan ~root ~store |> ok Snapshot.error_to_string
      in
      Out_channel.with_open_bin (root ^ "/.yeokchamignore") (fun out ->
          output_string out "!note.txt\n");
      Alcotest.(check bool)
        "capture retains its own rule decision" true
        (Snapshot.Observation.ignored observation ~path:[ "note.txt" ]
           ~directory:false);
      let observed =
        Snapshot.Snapshot.stored_object_id identity
        |> Raw.Stored_object_id.to_hex |> snapshot
      in
      let prepared =
        Service.Share.prepare ~store ~loaded ~observed ~observation ~paths:[]
          ~update:None ~title:None
        |> ok Service.Share.error_to_string
      in
      let result = Service.Share.preview prepared in
      Alcotest.(check bool)
        "ignored public file is not a deletion" false
        (List.mem [ "note.txt" ] result.Service.Share.contributed_paths);
      let public =
        Composition.load store result.Service.Share.public_snapshot
        |> ok Composition.error_to_string
      in
      Alcotest.(check bool)
        "previous public ignored path preserved" true
        (List.mem_assoc [ "note.txt" ] (Composition.entries public)))

let shared_plan_inputs root repository revisions =
  let loaded = load repository in
  let store = S.underlying_store repository in
  let parents = (List.hd (L.branches (local loaded))).C.accepted_heads in
  let accepted =
    Composition.Graph.compose store (L.pool (local loaded)) ~parents ~revisions
    |> ok Composition.Graph.error_to_string
  in
  let inherited =
    Composition.Graph.represented (L.pool (local loaded)) parents
    |> ok Composition.Graph.error_to_string
  in
  let selected =
    Composition.Graph.represented_revisions (L.pool (local loaded)) revisions
    |> ok Composition.Graph.error_to_string
  in
  let identity, _ = Snapshot.scan ~root ~store |> ok Snapshot.error_to_string in
  let observed =
    C.Object_id.of_hex
      (Raw.Stored_object_id.to_hex
         (Snapshot.Snapshot.stored_object_id identity))
    |> model
  in
  ( store,
    loaded,
    accepted,
    List.sort_uniq C.Record_id.compare (inherited @ selected),
    observed )

let preserved_entry store snapshot path =
  let tree =
    Composition.load store snapshot |> ok Composition.error_to_string
  in
  match List.assoc path (Composition.entries tree) with
  | Composition.File file ->
      Snapshot.Content.load store file.content |> ok Snapshot.error_to_string
  | Composition.Directory -> Alcotest.fail "expected file"

let preservation_accepts_D_and_keeps_private_E_and_X () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\nprivate E\n");
      write_private root "unselected private X\000";
      let store, loaded, accepted, represented, observed =
        shared_plan_inputs root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let prepared =
        Service.Preservation.prepare ~store ~loaded ~represented ~accepted
          ~observed
        |> ok Service.Preservation.error_to_string
      in
      Alcotest.(check string)
        "known shared D exactly once" "shared D\n"
        (preserved_entry store prepared.Service.Preservation.known_present
           [ "note.txt" ]);
      let known =
        Composition.load store prepared.Service.Preservation.known_present
        |> ok Composition.error_to_string
      in
      Alcotest.(check bool)
        "private X is not a shared preservation base" false
        (List.mem_assoc [ "private.bin" ] (Composition.entries known));
      Alcotest.(check string)
        "workspace retains private continuation E" "shared D\nprivate E\n"
        (preserved_entry store prepared.Service.Preservation.workspace_result
           [ "note.txt" ]);
      Alcotest.(check string)
        "unselected X remains in workspace" "unselected private X\000"
        (preserved_entry store prepared.Service.Preservation.workspace_result
           [ "private.bin" ]);
      Alcotest.(check bool)
        "accepted result excludes private X" false
        (List.mem_assoc [ "private.bin" ] (Composition.entries accepted));
      Alcotest.(check bool)
        "planning does not publish history/root" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head);
      Alcotest.(check string)
        "planning never materializes files" "shared D\nprivate E\n"
        (In_channel.with_open_bin (root ^ "/note.txt") In_channel.input_all))

let[@warning "-4"] preservation_rejects_missing_lineage_and_overlap () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      Service.navigate_history ~root ~direction:(Service.Go_to 0L)
        ~dry_run:false
      |> service |> ignore;
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\nprivate E\n");
      let store, loaded, accepted, represented, observed =
        shared_plan_inputs root repository
          [ Option.get shared.Service.Share.revision ]
      in
      (match
         Service.Preservation.prepare ~store ~loaded ~represented ~accepted
           ~observed
       with
      | Error (Service.Preservation.Content (Composition.Conflicts paths)) ->
          Alcotest.(check bool)
            "nonancestor source requires a workspace decision" true
            (List.mem [ "note.txt" ] paths)
      | Error error ->
          Alcotest.fail (Service.Preservation.error_to_string error)
      | Ok _ ->
          Alcotest.fail
            "inferred publication correspondence from equal-looking contents");
      Alcotest.(check bool)
        "conflict preserves root" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head);
      Alcotest.(check string)
        "conflicting private bytes stay live" "shared D\nprivate E\n"
        (In_channel.with_open_bin (root ^ "/note.txt") In_channel.input_all))

let preservation_does_not_backdate_already_accepted_work () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "old shared D1\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let loaded = load repository in
      let store = S.underlying_store repository in
      let content =
        Snapshot.Content.store store "accepted D2\n"
        |> ok Snapshot.error_to_string
      in
      let result =
        Composition.tree
          [
            ( [ "note.txt" ],
              Composition.File { mode = Snapshot.Regular; content } );
          ]
        |> ok Composition.error_to_string
        |> Composition.store store
        |> ok Composition.error_to_string
      in
      let scope =
        Composition.Scope.store store [ [ "note.txt" ] ]
        |> ok Composition.error_to_string
      in
      let local, revision =
        L.prepare_revision ~store ~authority ~certificate
          ~signing_capability:capability ~change:shared.Service.Share.change
          ~previous_revisions:[ Option.get shared.Service.Share.revision ]
          ~base_snapshot:(L.empty_snapshot (local loaded))
          ~result_snapshot:result ~edit_scope_root:scope ~dependencies:[]
          (local loaded)
        |> ok Fun.id
      in
      let local, _ =
        L.prepare_acceptance ~store ~authority ~certificate
          ~signing_capability:capability
          ~parents:[ (L.selected local).L.basis ]
          ~chosen_revisions:[ revision ] ~result_snapshot:result
          ~cursor:(H.current loaded.S.history).H.id local
        |> ok Fun.id
      in
      S.save_collaborative ~local repository ~expected:loaded.S.head
        ~project:loaded.S.project
        ~collaboration:(Option.get loaded.S.collaboration)
      |> ok S.error_to_string |> ignore;
      let store, loaded, accepted, represented, observed =
        shared_plan_inputs root repository []
      in
      let prepared =
        Service.Preservation.prepare ~store ~loaded ~represented ~accepted
          ~observed
        |> ok Service.Preservation.error_to_string
      in
      Alcotest.(check int)
        "old already-accepted source is not overlaid" 0
        (List.length prepared.Service.Preservation.contributions);
      Alcotest.(check bool)
        "known shared base stays D2" true
        (C.Object_id.equal result prepared.Service.Preservation.known_present);
      Alcotest.(check string)
        "private return to D1 is preserved" "old shared D1\n"
        (preserved_entry store prepared.Service.Preservation.workspace_result
           [ "note.txt" ]))

module I = Service.Integration

let prepare_integration root repository revisions =
  let loaded = load repository in
  let store = S.underlying_store repository in
  let identity, _, observation =
    Snapshot.Observation.scan ~root ~store |> ok Snapshot.error_to_string
  in
  let observed =
    Snapshot.Snapshot.stored_object_id identity
    |> Raw.Stored_object_id.to_hex |> snapshot
  in
  I.prepare ~store ~loaded ~observed ~observation ~selected_revisions:revisions
    ~reconcile_heads:None
  |> ok I.error_to_string

let integration_plan_binds_two_outputs_without_publication () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\nprivate E\n");
      let before = load repository in
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let outputs =
        match I.readiness plan with
        | I.Ready outputs -> outputs
        | I.Conflicted _ | I.Decision _ ->
            Alcotest.fail "expected a ready D/E plan"
      in
      let store = S.underlying_store repository in
      Alcotest.(check bool)
        "accepted result is exact public D" true
        (C.Object_id.equal outputs.C.accepted_snapshot
           shared.Service.Share.public_snapshot);
      Alcotest.(check string)
        "planned workspace retains E" "shared D\nprivate E\n"
        (preserved_entry store outputs.C.workspace_snapshot [ "note.txt" ]);
      Alcotest.(check bool)
        "two outputs remain distinct" false
        (C.Object_id.equal outputs.C.accepted_snapshot
           outputs.C.workspace_snapshot);
      Alcotest.(check bool)
        "unaccepted selection needs a commit" false (I.no_op plan);
      let again =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      Alcotest.(check bool)
        "same exact observed inputs have stable plan identity" true
        (C.Plan_id.equal (I.id plan) (I.id again));
      Alcotest.(check bool)
        "no accepted/history/outbound root publication" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      let envelope =
        Raw.get store (I.stored_id plan) |> ok Raw.error_to_string
      in
      Alcotest.(check bool)
        "one registered private plan envelope" true
        (Yeokcham_envelope.object_type envelope
        = Yeokcham_envelope.Core_integration_plan);
      Alcotest.(check string)
        "stored canonical plan is the prepared control" (I.encode plan)
        (Yeokcham_envelope.encode envelope))

let integration_plan_ignores_unrelated_receipt_and_binds_selected_heads () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let chosen = [ Option.get shared.Service.Share.revision ] in
      let initial = prepare_integration root repository chosen in
      let add_record ~change ~previous name bytes =
        let loaded = load repository in
        let store = S.underlying_store repository in
        let content =
          Snapshot.Content.store store bytes |> ok Snapshot.error_to_string
        in
        let result =
          Composition.tree
            [
              ([ name ], Composition.File { mode = Snapshot.Regular; content });
            ]
          |> ok Composition.error_to_string
          |> Composition.store store
          |> ok Composition.error_to_string
        in
        let scope =
          Composition.Scope.store store [ [ name ] ]
          |> ok Composition.error_to_string
        in
        let next, _ =
          L.prepare_revision ~store ~authority ~certificate
            ~signing_capability:capability ~change ~previous_revisions:previous
            ~base_snapshot:(L.empty_snapshot (local loaded))
            ~result_snapshot:result ~edit_scope_root:scope ~dependencies:[]
            (local loaded)
          |> ok Fun.id
        in
        S.save_collaborative ~local:next repository ~expected:loaded.S.head
          ~project:loaded.S.project
          ~collaboration:(Option.get loaded.S.collaboration)
        |> ok S.error_to_string |> ignore
      in
      add_record ~change:None ~previous:[] "other.txt"
        "independent received work\n";
      let independent = prepare_integration root repository chosen in
      Alcotest.(check bool)
        "unrelated received record does not invalidate exact plan" true
        (C.Plan_id.equal (I.id initial) (I.id independent));
      add_record ~change:shared.Service.Share.change ~previous:chosen "note.txt"
        "new selected change head\n";
      let selected_update = prepare_integration root repository chosen in
      Alcotest.(check bool)
        "selected floating head update changes exact identity" false
        (C.Plan_id.equal (I.id initial) (I.id selected_update)))

let integration_plan_exposes_workspace_conflict_without_files_or_history () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "shared D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      Service.navigate_history ~root ~direction:(Service.Go_to 0L)
        ~dry_run:false
      |> service |> ignore;
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "private incompatible version\n");
      let before = load repository in
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      (match I.readiness plan with
      | I.Conflicted conflicts ->
          Alcotest.(check bool)
            "named private workspace conflict" true
            (List.exists
               (fun conflict ->
                 conflict.C.private_workspace
                 && conflict.C.path = [ "note.txt" ])
               conflicts)
      | I.Ready _ | I.Decision _ ->
          Alcotest.fail "expected an explicit workspace conflict");
      Alcotest.(check bool)
        "accepted proposal remains separately available" true
        (Option.is_some (I.accepted_snapshot plan));
      Alcotest.(check bool)
        "conflict planning leaves root unchanged" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "conflicting private bytes preserved" "private incompatible version\n"
        (In_channel.with_open_bin (root ^ "/note.txt") In_channel.input_all))

module PE = Yeokcham_encoding
module Plan_envelope = Yeokcham_envelope

let plan_observation root repository =
  let store = S.underlying_store repository in
  let identity, _, observation =
    Snapshot.Observation.scan ~root ~store |> ok Snapshot.error_to_string
  in
  let observed =
    Snapshot.Snapshot.stored_object_id identity
    |> Raw.Stored_object_id.to_hex |> snapshot
  in
  (store, load repository, observed, observation)

let plan_array values = PE.array values |> ok PE.construction_error_to_string

let[@warning "-4"] plan_payload plan =
  match
    Plan_envelope.decode (I.encode plan)
    |> ok Plan_envelope.decode_error_to_string
    |> Plan_envelope.payload
  with
  | PE.Array fields -> fields
  | _ -> Alcotest.fail "expected plan array"

let alter_field index f values =
  List.mapi (fun i value -> if i = index then f value else value) values

let altered_plan ?(object_type = Plan_envelope.Core_integration_plan) plan f =
  Plan_envelope.create ~object_type ~object_format_version:1
    ~mandatory_features:0L
    ~payload:(plan_array (f (plan_payload plan)))
    ()
  |> ok Plan_envelope.creation_error_to_string
  |> Plan_envelope.encode

let[@warning "-4"] alter_request f fields =
  alter_field 1
    (function
      | PE.Array values -> plan_array (f values)
      | _ -> Alcotest.fail "expected request array")
    fields

let[@warning "-4"] integration_plan_decode_and_current_revalidation () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let store, loaded, observed, observation =
        plan_observation root repository
      in
      let before =
        Raw.list_objects store |> ok Raw.error_to_string |> List.length
      in
      let decoded =
        I.decode ~store ~loaded (I.encode plan) |> ok I.error_to_string
      in
      Alcotest.(check bool)
        "typed canonical plan identity survives decoding" true
        (C.Plan_id.equal (I.id plan) (I.id decoded));
      Alcotest.(check int)
        "decode writes no immutable objects" before
        (Raw.list_objects store |> ok Raw.error_to_string |> List.length);
      I.revalidate ~store ~loaded ~observed ~observation decoded
      |> ok I.error_to_string |> ignore;
      let before_save = I.id plan in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\nprivate E\n");
      let changed =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let store, loaded, observed, observation =
        plan_observation root repository
      in
      (match I.revalidate ~store ~loaded ~observed ~observation decoded with
      | Error (I.Stale _) -> ()
      | Error error -> Alcotest.fail (I.error_to_string error)
      | Ok _ -> Alcotest.fail "changed disk observation accepted under old plan");
      Alcotest.(check bool)
        "changed observation changes plan identity" false
        (C.Plan_id.equal before_save (I.id changed));
      Service.save ~root |> service |> ignore;
      let cursor_changed =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      Alcotest.(check bool)
        "equal bytes at another cursor still change plan" false
        (C.Plan_id.equal (I.id changed) (I.id cursor_changed)))

let[@warning "-4"] integration_plan_rejects_malformed_control_and_scope () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let store, loaded, _, _ = plan_observation root repository in
      let malformed =
        [
          altered_plan ~object_type:Plan_envelope.Core_metadata_page plan Fun.id;
          altered_plan plan (alter_field 0 (fun _ -> PE.integer 2L));
          altered_plan plan
            (alter_request
               (alter_field 0 (fun _ -> PE.bytes (String.make 32 'z'))));
          altered_plan plan
            (alter_request
               (alter_field 4 (fun _ -> plan_array [ PE.bytes "short" ])));
          altered_plan plan
            (alter_request
               (alter_field 4 (function
                 | PE.Array (id :: _) -> plan_array [ id; id ]
                 | _ -> assert false)));
          altered_plan plan
            (alter_request
               (alter_field 9 (function
                 | PE.Array values ->
                     plan_array
                       (alter_field 0
                          (fun _ -> PE.bytes (String.make 16 'z'))
                          values)
                 | _ -> assert false)));
          altered_plan plan
            (alter_request
               (alter_field 10 (fun _ ->
                    PE.text "unknown-profile"
                    |> ok PE.construction_error_to_string)));
          String.make ((8 * 1024 * 1024) + 1) 'x';
        ]
      in
      List.iter
        (fun bytes ->
          match I.decode ~store ~loaded bytes with
          | Error (I.Integrity _) -> ()
          | Error error -> Alcotest.fail (I.error_to_string error)
          | Ok _ -> Alcotest.fail "malformed plan accepted")
        malformed;
      let required =
        altered_plan plan
          (alter_request
             (alter_field 7 (fun _ ->
                  plan_array [ PE.bytes (String.make 32 'p') ])))
      in
      (match I.decode ~store ~loaded required with
      | Error (I.Policy _) -> ()
      | Error error -> Alcotest.fail (I.error_to_string error)
      | Ok _ -> Alcotest.fail "unsupported required policy silently accepted");
      let unknown_authority =
        altered_plan plan
          (alter_request
             (alter_field 6 (fun _ ->
                  plan_array [ PE.bytes (String.make 32 'u') ])))
      in
      (match I.decode ~store ~loaded unknown_authority with
      | Error (I.Policy _) -> ()
      | Error error -> Alcotest.fail (I.error_to_string error)
      | Ok _ -> Alcotest.fail "unknown authority silently accepted");
      let unsupported offset byte =
        let data = Bytes.of_string (I.encode plan) in
        Bytes.set data offset byte;
        let prefix = Bytes.sub_string data 0 25 in
        let payload =
          Bytes.sub_string data Plan_envelope.header_size
            (Bytes.length data - Plan_envelope.header_size)
        in
        let digest =
          Yeokcham_hash.Sha256.digest_string (prefix ^ payload)
          |> Yeokcham_hash.Sha256.to_raw_string
        in
        Bytes.blit_string digest 0 data 25 32;
        Bytes.to_string data
      in
      List.iter
        (fun bytes ->
          match I.decode ~store ~loaded bytes with
          | Error (I.Integrity _) -> ()
          | Error error -> Alcotest.fail (I.error_to_string error)
          | Ok _ -> Alcotest.fail "unsupported version/features accepted")
        [ unsupported 7 '\002'; unsupported 15 '\001' ])

let[@warning "-4"] integration_plan_rejects_false_outputs_after_reference_decode
    () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let store, loaded, observed, observation =
        plan_observation root repository
      in
      let private_snapshot =
        PE.bytes
          (C.Object_id.of_hex (M.Snapshot_id.to_string observed)
          |> model |> C.Object_id.to_raw)
      in
      let false_plan =
        altered_plan plan (fun fields ->
            fields
            |> alter_field 5 (fun _ -> private_snapshot)
            |> alter_field 6 (function
              | PE.Array values ->
                  plan_array (alter_field 1 (fun _ -> private_snapshot) values)
              | _ -> Alcotest.fail "expected ready outputs"))
      in
      let decoded =
        I.decode ~store ~loaded false_plan |> ok I.error_to_string
      in
      (match I.revalidate ~store ~loaded ~observed ~observation decoded with
      | Error (I.Integrity _) -> ()
      | Error error -> Alcotest.fail (I.error_to_string error)
      | Ok _ ->
          Alcotest.fail
            "canonical referenced private snapshot became accepted output");
      Alcotest.(check bool)
        "refused plan leaves root" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head))

let integration_proposal_survives_restart_and_gc_until_release () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\nprivate unsaved E\n");
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let store, loaded, observed, observation =
        plan_observation root repository
      in
      I.retain ~store plan |> ok I.error_to_string;
      I.retain ~store plan |> ok I.error_to_string;
      let reloaded =
        I.load ~store ~loaded (I.id plan) |> ok I.error_to_string
      in
      I.revalidate ~store ~loaded ~observed ~observation reloaded
      |> ok I.error_to_string |> ignore;
      Alcotest.(check int)
        "one immutable retained proposal" 1
        (I.scan ~store ~loaded |> ok I.error_to_string |> List.length);
      Alcotest.(check bool)
        "retaining proposal does not commit history/head" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head);
      let child = Unix.fork () in
      (if child = 0 then
         let repository = S.open_repository ~root |> ok S.error_to_string in
         let loaded = load repository in
         let fresh =
           I.load ~store:(S.underlying_store repository) ~loaded (I.id plan)
           |> ok I.error_to_string
         in
         Unix._exit (if C.Plan_id.equal (I.id plan) (I.id fresh) then 0 else 72));
      let _, status = Unix.waitpid [] child in
      Alcotest.(check bool)
        "exact plan survives a fresh process" true (status = Unix.WEXITED 0);
      Snapshot.Content.store store "unrooted collection fixture"
      |> ok Snapshot.error_to_string
      |> ignore;
      let gc = Yeokcham_v1_gc.plan ~root |> ok Yeokcham_v1_gc.error_to_string in
      let observed_id =
        Raw.Stored_object_id.of_hex (M.Snapshot_id.to_string observed)
        |> ok Raw.Stored_object_id.parse_error_to_string
      in
      let entry =
        List.find
          (fun entry ->
            Raw.Stored_object_id.equal entry.Yeokcham_v1_gc.object_id
              observed_id)
          gc.Yeokcham_v1_gc.objects
      in
      (match entry.Yeokcham_v1_gc.disposition with
      | Yeokcham_v1_gc.Retain reasons ->
          Alcotest.(check bool)
            "proposal is an explicit private recovery root" true
            (List.exists
               (fun reason ->
                 String.starts_with ~prefix:"integration-proposal "
                   (Yeokcham_v1_gc.root_reason_to_string reason))
               reasons)
      | Yeokcham_v1_gc.Collect ->
          Alcotest.fail "GC would lose the exact proposed workspace");
      Yeokcham_v1_gc.apply ~root |> ok Yeokcham_v1_gc.error_to_string |> ignore;
      let fresh =
        I.load ~store ~loaded:(load repository) (I.id plan)
        |> ok I.error_to_string
      in
      let outputs =
        match I.readiness fresh with
        | I.Ready value -> value
        | I.Conflicted _ | I.Decision _ -> Alcotest.fail "ready expected"
      in
      Alcotest.(check string)
        "private proposed E survives actual collection" "D\nprivate unsaved E\n"
        (preserved_entry store outputs.C.workspace_snapshot [ "note.txt" ]);
      I.forget ~store (I.id plan) |> ok I.error_to_string;
      I.forget ~store (I.id plan) |> ok I.error_to_string;
      let gc = Yeokcham_v1_gc.plan ~root |> ok Yeokcham_v1_gc.error_to_string in
      let entry =
        List.find
          (fun entry ->
            Raw.Stored_object_id.equal entry.Yeokcham_v1_gc.object_id
              observed_id)
          gc.Yeokcham_v1_gc.objects
      in
      Alcotest.(check bool)
        "releasing proposal removes its extra retention root" true
        (entry.Yeokcham_v1_gc.disposition = Yeokcham_v1_gc.Collect);
      Alcotest.(check string)
        "release never changes private live bytes" "D\nprivate unsaved E\n"
        (In_channel.with_open_bin (root ^ "/note.txt") In_channel.input_all))

let integration_proposal_rejects_missing_contents_before_retention () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "private unsaved target\n");
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let store, loaded, observed, _ = plan_observation root repository in
      let source =
        C.Object_id.of_hex (M.Snapshot_id.to_string observed) |> model
      in
      let tree =
        Composition.load store source |> ok Composition.error_to_string
      in
      let content =
        match List.assoc [ "note.txt" ] (Composition.entries tree) with
        | Composition.File file ->
            Snapshot.Content.stored_object_id file.content
        | Composition.Directory -> Alcotest.fail "file expected"
      in
      Unix.unlink (Raw.object_path store content);
      reject "retained plan with missing complete target" (I.retain ~store plan);
      Alcotest.(check bool)
        "failed preflight creates no proposal alias" false
        (Sys.file_exists (root ^ "/.yeokcham/integration-plans"));
      Alcotest.(check bool)
        "failed preflight preserves root" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head);
      Alcotest.(check string)
        "missing immutable object never rewrites live file"
        "private unsaved target\n"
        (In_channel.with_open_bin (root ^ "/note.txt") In_channel.input_all))

let integration_proposal_corruption_blocks_gc_without_replacement () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "D\n");
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let plan =
        prepare_integration root repository
          [ Option.get shared.Service.Share.revision ]
      in
      let store = S.underlying_store repository in
      I.retain ~store plan |> ok I.error_to_string;
      let path =
        root ^ "/.yeokcham/integration-plans/"
        ^ C.Plan_id.to_hex (I.id plan)
        ^ ".plan"
      in
      Out_channel.with_open_bin path (fun out ->
          output_string out "corrupt proposal");
      reject "overwrote corrupt conflicting retained plan"
        (I.retain ~store plan);
      Alcotest.(check string)
        "collision preserves existing control bytes" "corrupt proposal"
        (In_channel.with_open_bin path In_channel.input_all);
      reject "GC accepted unreadable retained proposal"
        (Yeokcham_v1_gc.plan ~root);
      let report = Yeokcham_v1_health_repository.verify ~root in
      Alcotest.(check bool)
        "health identifies proposal damage separately from state head" true
        (Yeokcham_v1_health.report_damages report
        |> List.exists (fun damage ->
            Yeokcham_v1_health.damage_affected damage
            = Yeokcham_v1_health.Durable_record
                (Yeokcham_v1_health.Integration_plan_record, "integration-plans"))
        );
      Alcotest.(check bool)
        "failed planning creates no quarantine" false
        (Sys.file_exists (root ^ "/.yeokcham/gc")))

let[@warning "-4"] equal_content_causal_heads_require_explicit_full_reconciliation
    () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      Out_channel.with_open_bin (root ^ "/note.txt") (fun out ->
          output_string out "equal public bytes\n");
      let first =
        Service.share_selected ~root ~paths:[ [ "note.txt" ] ] ~update:None
          ~title:(Some "first change") ~dry_run:false
          ~signing_capability:(Some capability)
        |> service
      in
      let second =
        Service.share_selected ~root ~paths:[ [ "note.txt" ] ] ~update:None
          ~title:(Some "independent equal change") ~dry_run:false
          ~signing_capability:(Some capability)
        |> service
      in
      let before = load repository in
      let store = S.underlying_store repository in
      let original = local before in
      let accept revision =
        L.prepare_acceptance ~store ~authority ~certificate
          ~signing_capability:capability
          ~parents:[ (L.selected original).L.basis ]
          ~chosen_revisions:[ revision ]
          ~result_snapshot:first.Service.Share.public_snapshot
          ~cursor:(H.current before.S.history).H.id original
        |> ok Fun.id |> fst
      in
      let a = accept (Option.get first.Service.Share.revision) in
      let b = accept (Option.get second.Service.Share.revision) in
      let fields local =
        match
          L.encode local |> ok Fun.id |> PE.decode
          |> ok PE.decode_error_to_string
        with
        | PE.Array fields -> fields
        | _ -> Alcotest.fail "expected local metadata array"
      in
      let references local =
        match List.nth (fields local) 3 with
        | PE.Array references -> references
        | _ -> Alcotest.fail "expected core references"
      in
      let references =
        references a @ references b
        |> List.sort_uniq (fun a b ->
            String.compare (PE.encode a) (PE.encode b))
      in
      let combined =
        fields original
        |> alter_field 3 (fun _ -> plan_array references)
        |> plan_array |> PE.encode |> L.decode ~store ~authority |> ok Fun.id
      in
      let loaded =
        S.save_collaborative ~local:combined repository ~expected:before.S.head
          ~project:before.S.project
          ~collaboration:(Option.get before.S.collaboration)
        |> ok S.error_to_string
      in
      let branch = List.hd (L.branches (local loaded)) in
      Alcotest.(check int)
        "two accepted identities survive equal bytes" 2
        (List.length branch.C.accepted_heads);
      Alcotest.(check int)
        "two causal event heads survive" 2
        (List.length branch.C.event_heads);
      let store, loaded, observed, observation =
        plan_observation root repository
      in
      let prepare reconcile_heads =
        I.prepare ~store ~loaded ~observed ~observation ~selected_revisions:[]
          ~reconcile_heads
      in
      let choice = function
        | Error (I.Choice _) -> ()
        | Error error -> Alcotest.fail (I.error_to_string error)
        | Ok _ -> Alcotest.fail "implicitly reconciled a causal fork"
      in
      choice (prepare None);
      choice (prepare (Some branch.C.accepted_heads));
      let every_head =
        List.sort C.Record_id.compare
          (branch.C.accepted_heads @ branch.C.event_heads)
      in
      choice (prepare (Some (List.hd every_head :: every_head)));
      let plan = prepare (Some every_head) |> ok I.error_to_string in
      (match I.readiness plan with
      | I.Ready _ -> ()
      | I.Conflicted _ | I.Decision _ ->
          Alcotest.fail
            "equal complete variants should compose after explicit \
             reconciliation");
      Alcotest.(check bool)
        "equal bytes still need recorded reconciliation" false (I.no_op plan);
      let decoded =
        I.decode ~store ~loaded (I.encode plan) |> ok I.error_to_string
      in
      I.revalidate ~store ~loaded ~observed ~observation decoded
      |> ok I.error_to_string |> ignore;
      Alcotest.(check bool)
        "preparation does not merge or erase either head" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head))

module Native_integrate = Service.Integrate
module Op = L.Operation

let integrate_ok r = ok Native_integrate.error_to_string r

let write_file root name bytes =
  Out_channel.with_open_bin
    (root ^ "/" ^ name)
    (fun out -> output_string out bytes)

let read_file root name =
  In_channel.with_open_bin (root ^ "/" ^ name) In_channel.input_all

let add_incoming_revision repository capability certificate authority name bytes
    =
  let loaded = load repository in
  let store = S.underlying_store repository in
  let content =
    Snapshot.Content.store store bytes |> ok Snapshot.error_to_string
  in
  let result =
    Composition.tree
      [ ([ name ], Composition.File { mode = Snapshot.Regular; content }) ]
    |> ok Composition.error_to_string
    |> Composition.store store
    |> ok Composition.error_to_string
  in
  let scope =
    Composition.Scope.store store [ [ name ] ] |> ok Composition.error_to_string
  in
  let next, revision =
    L.prepare_revision ~store ~authority ~certificate
      ~signing_capability:capability ~change:None ~previous_revisions:[]
      ~base_snapshot:(L.empty_snapshot (local loaded))
      ~result_snapshot:result ~edit_scope_root:scope ~dependencies:[]
      (local loaded)
    |> ok Fun.id
  in
  S.save_collaborative ~local:next repository ~expected:loaded.S.head
    ~project:loaded.S.project
    ~collaboration:(Option.get loaded.S.collaboration)
  |> ok S.error_to_string |> ignore;
  (revision, result)

let native_plan root chosen =
  Native_integrate.prepare ~root ~selected_revisions:chosen
    ~reconcile_heads:None
  |> integrate_ok

let native_apply root plan capability =
  Native_integrate.apply ~root ~plan:(I.id plan) ~signing_capability:capability
  |> integrate_ok

let received_nonempty_branch repository capability certificate authority =
  let revision, result =
    add_incoming_revision repository capability certificate authority
      "shared.txt" "received branch D\r\n"
  in
  let before = load repository in
  let store = S.underlying_store repository in
  let staged =
    L.create_branch ~store ~authority ~certificate
      ~signing_capability:capability ~name:"received"
      ~cursor:(H.current before.S.history).H.id (local before)
    |> ok Fun.id
  in
  let position = L.lookup staged "received" |> ok Fun.id in
  let staged = L.select staged position.L.branch |> ok Fun.id in
  let staged, basis =
    L.prepare_acceptance ~store ~authority ~certificate
      ~signing_capability:capability ~parents:[ position.L.basis ]
      ~chosen_revisions:[ revision ] ~result_snapshot:result
      ~cursor:position.L.cursor staged
    |> ok Fun.id
  in
  let received =
    L.receive_records ~store ~authority ~records:(L.record_objects staged)
      (local before)
    |> ok L.receive_error_to_string
  in
  S.save_collaborative ~local:received repository ~expected:before.S.head
    ~project:before.S.project
    ~collaboration:(Option.get before.S.collaboration)
  |> ok S.error_to_string |> ignore;
  (position.L.branch, basis, result)

let received_branch_selection_preserves_private_work () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let branch, basis, _ =
        received_nonempty_branch repository capability certificate authority
      in
      write_private root "unsaved source alternative\000";
      let before = load repository in
      let preview =
        Service.branch_switch ~root ~name:"received" ~dry_run:true |> service
      in
      Alcotest.(check bool)
        "preview proposes a private position" true
        preview.Service.switch_registers_position;
      Alcotest.(check bool)
        "future history identity is explicitly provisional" true
        preview.Service.switch_target_provisional;
      Alcotest.(check bool)
        "preview does not allocate history" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "preview preserves unsaved files" "unsaved source alternative\000"
        (read_private root);
      let selected =
        Service.branch_switch_confirmed ~root ~name:"received" ~preview
        |> service
      in
      let after = load repository in
      Alcotest.(check bool)
        "actual selection resolves provisional identity" false
        selected.Service.switch_target_provisional;
      Alcotest.(check bool)
        "known branch identity selected" true
        (C.Branch_id.equal branch (L.selected (local after)).L.branch);
      Alcotest.(check bool)
        "exact known accepted version reused" true
        (C.Record_id.equal basis (L.selected (local after)).L.basis);
      Alcotest.(check string)
        "received target files installed" "received branch D\r\n"
        (read_file root "shared.txt");
      Alcotest.(check bool)
        "source private files stay on their alternative" false
        (Sys.file_exists (root ^ "/private.bin"));
      Alcotest.(check bool)
        "no public branch/acceptance records created" true
        (L.record_objects (local before) = L.record_objects (local after));
      Alcotest.(check int)
        "one safety observation and one imported target" 3
        (List.length (H.nodes after.S.history));
      let saved = H.encode after.S.history |> ok Fun.id in
      ignore (switch root "received");
      Alcotest.(check string)
        "same selected branch does not duplicate navigation" saved
        (H.encode (load repository).S.history |> ok Fun.id);
      ignore (switch root "main");
      Alcotest.(check string)
        "unsaved source alternative remains recoverable"
        "unsaved source alternative\000" (read_private root);
      ignore (switch root "received");
      Alcotest.(check int)
        "switching back uses the existing private target" 3
        (List.length (H.nodes (load repository).S.history)))

let received_branch_switch_resumes_mutation_and_metadata_boundaries () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          let _, basis, _ =
            received_nonempty_branch repository capability certificate authority
          in
          write_private root "source recovery alternative";
          let records = L.record_objects (local (load repository)) in
          let child = Unix.fork () in
          if child = 0 then (
            let result =
              Service.For_test.branch_switch
                ~observe:(fun actual -> if actual = boundary then Unix._exit 73)
                ~root ~name:"received" ~dry_run:false
            in
            (match result with
            | Error error -> prerr_endline (Service.error_to_string error)
            | Ok _ -> ());
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "actual first-selection boundary reached" true
            (status = Unix.WEXITED 73);
          let resumed = switch root "received" in
          let after = load repository in
          Alcotest.(check bool)
            "received branch eventually selected" true
            (C.Record_id.equal basis (L.selected (local after)).L.basis);
          Alcotest.(check string)
            "exact received target" "received branch D\r\n"
            (read_file root "shared.txt");
          Alcotest.(check int)
            "one source observation and one target across retry" 3
            (List.length (H.nodes after.S.history));
          Alcotest.(check bool)
            "resume signs no new public records" true
            (records = L.record_objects (local after));
          (match resumed.Service.switch_restore with
          | Some result
            when boundary <> Service.Before_safety_publish
                 && boundary <> Service.After_safety_publish ->
              Alcotest.(check bool)
                "durable journal resumes same operation" true
                result.Service.resumed
          | _ -> ());
          ignore (switch root "main");
          Alcotest.(check string)
            "source remains available after interrupted first selection"
            "source recovery alternative" (read_private root)))
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

let received_branch_selection_refuses_obstructions_and_stale_preview () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      ignore
        (received_nonempty_branch repository capability certificate authority);
      write_file root ".yeokchamignore" "*.private\n";
      Unix.mkdir (root ^ "/shared.txt") 0o700;
      write_file root "shared.txt/keep.private" "ignored source obstruction";
      let before = load repository in
      reject "first selection replaced an ignored obstruction"
        (Service.branch_switch ~root ~name:"received" ~dry_run:false);
      Alcotest.(check bool)
        "failed preflight does not register target or capture source" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "ignored source data preserved" "ignored source obstruction"
        (read_file root "shared.txt/keep.private");
      Unix.unlink (root ^ "/shared.txt/keep.private");
      Unix.rmdir (root ^ "/shared.txt");
      let preview =
        Service.branch_switch ~root ~name:"received" ~dry_run:true |> service
      in
      write_private root "edits after preview";
      reject "stale first selection was applied"
        (Service.branch_switch_confirmed ~root ~name:"received" ~preview);
      Alcotest.(check bool)
        "stale plan preserves root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "stale plan preserves latest edits" "edits after preview"
        (read_private root))

let advance_received_branch repository capability certificate authority branch
    bytes =
  let loaded = load repository in
  let store = S.underlying_store repository in
  let staged = L.select (local loaded) branch |> ok Fun.id in
  let position = L.selected staged in
  let accepted =
    Composition.Graph.accepted (L.pool staged) position.L.basis
    |> ok Composition.Graph.error_to_string
  in
  let staged, chosen, result =
    match bytes with
    | None -> (staged, [], accepted.C.result_snapshot)
    | Some bytes ->
        let content =
          Snapshot.Content.store store bytes |> ok Snapshot.error_to_string
        in
        let result =
          Composition.tree
            [
              ( [ "shared.txt" ],
                Composition.File { mode = Snapshot.Regular; content } );
            ]
          |> ok Composition.error_to_string
          |> Composition.store store
          |> ok Composition.error_to_string
        in
        let scope =
          Composition.Scope.store store [ [ "shared.txt" ] ]
          |> ok Composition.error_to_string
        in
        let dependencies =
          Composition.Graph.represented (L.pool staged) [ position.L.basis ]
          |> ok Composition.Graph.error_to_string
        in
        let staged, revision =
          L.prepare_revision ~store ~authority ~certificate
            ~signing_capability:capability ~change:None ~previous_revisions:[]
            ~base_snapshot:accepted.C.result_snapshot ~result_snapshot:result
            ~edit_scope_root:scope ~dependencies staged
          |> ok Fun.id
        in
        (staged, [ revision ], result)
  in
  let staged, basis =
    L.prepare_acceptance ~store ~authority ~certificate
      ~signing_capability:capability ~parents:[ position.L.basis ]
      ~chosen_revisions:chosen ~result_snapshot:result ~cursor:position.L.cursor
      staged
    |> ok Fun.id
  in
  let received =
    L.receive_records ~store ~authority ~records:(L.record_objects staged)
      (local loaded)
    |> ok L.receive_error_to_string
  in
  S.save_collaborative ~local:received repository ~expected:loaded.S.head
    ~project:loaded.S.project
    ~collaboration:(Option.get loaded.S.collaboration)
  |> ok S.error_to_string |> ignore;
  basis

let saved_private_branch_can_be_selected_before_catching_up_shared_head () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let branch, original_basis, _ =
        received_nonempty_branch repository capability certificate authority
      in
      ignore (switch root "received");
      write_file root "topic-private.txt" "private E on received branch";
      ignore (switch root "main");
      let new_basis =
        advance_received_branch repository capability certificate authority
          branch (Some "received branch D2\r\n")
      in
      let selected = switch root "received" in
      Alcotest.(check bool)
        "selection reports newer known shared head" true
        (selected.Service.switch_known_heads = [ new_basis ]);
      Alcotest.(check bool)
        "selection restores historical private basis without retargeting" true
        (C.Record_id.equal original_basis
           (L.selected (local (load repository))).L.basis);
      Alcotest.(check string)
        "old private files selected before explicit integration"
        "received branch D\r\n"
        (read_file root "shared.txt");
      Service.branch_create ~root ~name:"private-fork"
        ~signing_capability:capability
      |> service |> ignore;
      let forked = load repository in
      let fork = L.lookup (local forked) "private-fork" |> ok Fun.id in
      let version =
        Composition.Graph.accepted (L.pool (local forked)) fork.L.basis
        |> ok Composition.Graph.error_to_string
      in
      Alcotest.(check bool)
        "new branch forks the private working basis rather than an unselected \
         newer head"
        true
        (version.C.accepted_parents = [ original_basis ]);
      let records = L.record_objects (local forked) in
      let plan = native_plan root [] in
      ignore (native_apply root plan None);
      Alcotest.(check bool)
        "explicit integration catches up to known accepted head" true
        (C.Record_id.equal new_basis
           (L.selected (local (load repository))).L.basis);
      Alcotest.(check string)
        "known shared update selected" "received branch D2\r\n"
        (read_file root "shared.txt");
      Alcotest.(check string)
        "private E survives shared catch-up" "private E on received branch"
        (read_file root "topic-private.txt");
      Alcotest.(check bool)
        "catch-up signs no duplicate acceptance" true
        (records = L.record_objects (local (load repository)));
      ignore (switch root "private-fork");
      Alcotest.(check string)
        "fork retains earlier shared contents" "received branch D\r\n"
        (read_file root "shared.txt");
      Alcotest.(check string)
        "fork retains private continuation" "private E on received branch"
        (read_file root "topic-private.txt");
      ignore (switch root "main");
      Alcotest.(check string)
        "original source private work survives both branches"
        "private\000bytes\255" (read_private root))

let interrupted_first_selection_keeps_exact_basis_across_new_shared_heads () =
  List.iter
    (fun update ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          let branch, original_basis, _ =
            received_nonempty_branch repository capability certificate authority
          in
          write_private root "unsaved source";
          let child = Unix.fork () in
          if child = 0 then (
            ignore
              (Service.For_test.branch_switch
                 ~observe:(fun boundary ->
                   if boundary = Service.Prepared_journal then Unix._exit 73)
                 ~root ~name:"received" ~dry_run:false);
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "first selection was durably prepared" true
            (status = Unix.WEXITED 73);
          let current_basis =
            advance_received_branch repository capability certificate authority
              branch update
          in
          Alcotest.(check bool)
            "new accepted history remains distinct even with equal bytes" false
            (C.Record_id.equal original_basis current_basis);
          let resumed = switch root "received" in
          let after = load repository in
          Alcotest.(check bool)
            "resumed selection retains original basis identity" true
            (C.Record_id.equal original_basis (L.selected (local after)).L.basis);
          Alcotest.(check bool)
            "new shared head remains visible and unaccepted locally" true
            (resumed.Service.switch_known_heads = [ current_basis ]);
          Alcotest.(check string)
            "frozen exact target contents selected" "received branch D\r\n"
            (read_file root "shared.txt");
          Alcotest.(check int)
            "receipt/retry creates no duplicate history" 3
            (List.length (H.nodes after.S.history));
          ignore (switch root "main");
          Alcotest.(check string)
            "source safety alternative retained" "unsaved source"
            (read_private root)))
    [ None; Some "later received shared contents\r\n" ]

let registered_shared_position_is_pure_idempotent_and_verified () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let branch, basis, target =
        received_nonempty_branch repository capability certificate authority
      in
      let before = load repository in
      reject "private contents were registered as the accepted target"
        (L.register_position (local before) ~history:before.S.history ~branch
           ~basis ~cursor:0L);
      let staged_history, node =
        H.target_snapshot before.S.history
          ~snapshot:(snapshot (C.Object_id.to_hex target))
          ~draft ~created_at:0L
        |> ok Fun.id
      in
      let staged =
        L.register_position (local before) ~history:staged_history ~branch
          ~basis ~cursor:node.H.id
        |> ok Fun.id
      in
      let repeated =
        L.register_position staged ~history:staged_history ~branch ~basis
          ~cursor:node.H.id
        |> ok Fun.id
      in
      Alcotest.(check string)
        "identical registration preserves exact canonical state"
        (L.encode staged |> ok Fun.id)
        (L.encode repeated |> ok Fun.id);
      let another =
        H.record_exact staged_history
          ~expected:(Option.get (H.next_sequence staged_history))
          ~snapshot:node.H.snapshot ~draft ~created_at:1L
        |> ok Fun.id
      in
      reject
        "saved private position was retargeted to an equal-content different \
         node"
        (L.register_position staged ~history:another ~branch ~basis
           ~cursor:(H.current another).H.id);
      Alcotest.(check bool)
        "pure staging does not allocate durable history" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head))

let first_shared_selection_keeps_gc_roots_and_late_external_edits () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          ignore
            (received_nonempty_branch repository capability certificate
               authority);
          write_private root "source safety retained through GC";
          let child = Unix.fork () in
          if child = 0 then (
            ignore
              (Service.For_test.branch_switch
                 ~observe:(fun actual ->
                   if actual = boundary then Unix._exit 73)
                 ~root ~name:"received" ~dry_run:false);
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "GC test reaches actual selection boundary" true
            (status = Unix.WEXITED 73);
          Yeokcham_v1_gc.apply ~root
          |> ok Yeokcham_v1_gc.error_to_string
          |> ignore;
          if boundary = Service.Materialized_journal then
            write_file root "shared.txt" "external edit after materialization";
          ignore (switch root "received");
          Alcotest.(check string)
            "GC/resume preserves target or later external bytes"
            (if boundary = Service.Materialized_journal then
               "external edit after materialization"
             else "received branch D\r\n")
            (read_file root "shared.txt");
          ignore (switch root "main");
          Alcotest.(check string)
            "source safety survived collection"
            "source safety retained through GC" (read_private root);
          if boundary = Service.Materialized_journal then (
            ignore (switch root "received");
            Alcotest.(check string)
              "late external alternative remains recoverable"
              "external edit after materialization"
              (read_file root "shared.txt"))))
    [
      Service.After_safety_publish;
      Service.Prepared_journal;
      Service.Materialized_journal;
    ]

let branch_creation_signing_releases_writer_and_revalidates () =
  List.iter
    (fun activity ->
      with_root (fun root ->
          let repository, capability, _, _, _ = initialize root in
          write_private root "observed before provider";
          let before = load repository in
          let calls = ref 0 and unlocked = ref true in
          let provider =
            T.signing_capability_of_external_signer
              ~public_key:(T.signing_public_key capability)
              ~sign:(fun ~domain bytes ->
                incr calls;
                let child = Unix.fork () in
                (if child = 0 then
                   let fd =
                     Unix.openfile
                       (root ^ "/.yeokcham/local-worktree.lock")
                       [ Unix.O_RDWR; Unix.O_CLOEXEC ]
                       0
                   in
                   try
                     Unix.lockf fd Unix.F_TLOCK 0;
                     Unix.close fd;
                     Unix._exit 0
                   with Unix.Unix_error _ -> Unix._exit 1);
                let _, status = Unix.waitpid [] child in
                unlocked := !unlocked && status = Unix.WEXITED 0;
                if !calls = 1 && activity <> 0 then (
                  write_private root "changed while provider was active";
                  if activity = 2 then Service.save ~root |> service |> ignore);
                T.sign_detached capability ~domain bytes
                |> Result.map_error T.error_to_string)
            |> trust
          in
          let result =
            Service.branch_create ~root ~name:"provider-branch"
              ~signing_capability:provider
          in
          Alcotest.(check bool)
            "branch signing holds no writer lock" true !unlocked;
          Alcotest.(check int)
            "exact branch genesis and event signatures" 2 !calls;
          let after = load repository in
          if activity = 0 then (
            service result |> ignore;
            Alcotest.(check int)
              "branch created after revalidation" 2
              (List.length (L.branches (local after))))
          else (
            reject "provider-time edits bypassed branch revalidation" result;
            Alcotest.(check int)
              "stale request creates no branch" 1
              (List.length (L.branches (local after)));
            Alcotest.(check string)
              "provider-time bytes remain current"
              "changed while provider was active" (read_private root);
            if activity = 1 then
              Alcotest.(check bool)
                "unrecorded edits do not allocate branch history" true
                (Raw.Mutable_ref.equal before.S.head after.S.head)
            else
              Alcotest.(check int)
                "concurrent capture is preserved without duplicate history" 2
                (List.length (H.nodes after.S.history)))))
    [ 0; 1; 2 ]

let[@warning "-4"] metadata_inspection_survives_missing_shared_chunks_without_authorizing_writes
    () =
  with_root (fun parent ->
      let root = Filename.concat parent "workspace\027[31m" in
      Unix.mkdir root 0o700;
      let repository, capability, certificate, authority, _ = initialize root in
      let bytes =
        String.init ((2 * 1024 * 1024) + 31) (fun i -> Char.chr (i mod 251))
      in
      let revision, result =
        add_incoming_revision repository capability certificate authority
          "shared.bin" bytes
      in
      let plan = native_plan root [ revision ] in
      ignore (native_apply root plan (Some capability));
      let before = load repository in
      let store = S.underlying_store repository in
      let tree =
        Composition.load store result |> ok Composition.error_to_string
      in
      let content =
        match List.assoc [ "shared.bin" ] (Composition.entries tree) with
        | Composition.File file -> file.content
        | Composition.Directory -> Alcotest.fail "expected shared file"
      in
      let content_id = Snapshot.Content.stored_object_id content in
      let manifest =
        Snapshot.Manifest.load_metadata store
          (Snapshot.Manifest.of_stored_object_id content_id)
        |> ok Snapshot.error_to_string
      in
      let chunk =
        List.hd (Snapshot.Manifest.chunks manifest)
        |> fst |> Snapshot.Chunk.stored_object_id
      in
      let envelope = Raw.get store chunk |> ok Raw.error_to_string in
      Unix.unlink (Raw.object_path store chunk);
      reject "strict loader accepted missing shared bytes" (S.load repository);
      let inspect () =
        match S.inspect repository |> ok S.error_to_string with
        | S.Verified _ -> Alcotest.fail "missing bytes became a verified state"
        | S.Metadata_only metadata -> metadata
      in
      let metadata = inspect () in
      Alcotest.(check string)
        "metadata preserves full history/cursor/counter"
        (H.encode before.S.history |> ok Fun.id)
        (H.encode metadata.S.metadata_history |> ok Fun.id);
      Alcotest.(check bool)
        "historical signed branch declarations stay inspectable" true
        (L.Metadata.branches (Option.get metadata.S.metadata_local)
        = L.branches (local before));
      Alcotest.(check bool)
        "missing public contents remain an explicit failed proof" true
        (match metadata.S.metadata_contents with
        | Some
            (Error (Composition.Graph.Content_error (Composition.Unavailable _)))
          ->
            true
        | _ -> false);
      let check_cli exit_code code =
        let open Yojson.Safe.Util in
        let status = failed_inspection_cli root "status" exit_code code in
        Alcotest.(check string)
          "exact saved position"
          (Int64.to_string (H.current before.S.history).H.id)
          (status |> member "saved" |> member "history" |> member "sequence"
         |> to_string);
        Alcotest.(check string)
          "exact selected branch"
          (C.Branch_id.to_hex (L.selected (local before)).L.branch)
          (status |> member "branch" |> member "id" |> to_string);
        Alcotest.(check string)
          "no working-tree capture" "not_attempted"
          (status |> member "capture" |> member "state" |> to_string);
        Alcotest.(check bool)
          "unknown changes remain unknown" true
          (status |> member "changes" = `Null);
        let history = failed_inspection_cli root "history" exit_code code in
        let entries = history |> member "entries" |> to_list in
        Alcotest.(check int)
          "history remains complete"
          (List.length (H.nodes before.S.history))
          (List.length entries);
        let current = history |> member "current" |> to_string in
        let current =
          List.find
            (fun row -> row |> member "id" |> to_string = current)
            entries
        in
        Alcotest.(check string)
          "broken current snapshot is unavailable" "unavailable"
          (current |> member "availability" |> to_string);
        Alcotest.(check bool)
          "unavailable comparison remains unknown" true
          (current |> member "changed_paths" = `Null);
        List.iter
          (fun command ->
            let result, output, errors = cli root [ command ] in
            Alcotest.(check bool)
              (command ^ " plain inspection exit: " ^ errors)
              true
              (result = Unix.WEXITED exit_code);
            Alcotest.(check bool)
              "plain failure escapes terminal controls in native paths" false
              (String.contains output '\027');
            Alcotest.(check bool)
              "plain output includes saved snapshot identity" true
              (let identity =
                 M.Snapshot_id.to_string (H.current before.S.history).H.snapshot
               in
               let rec contains offset =
                 offset + String.length identity <= String.length output
                 && (String.sub output offset (String.length identity)
                     = identity
                    || contains (offset + 1))
               in
               contains 0))
          [ "status"; "history" ]
      in
      check_cli 5 "saved-contents-unavailable";
      reject "metadata inspection authorized capture" (Service.save ~root);
      reject "metadata inspection authorized acceptance"
        (Native_integrate.prepare ~root ~selected_revisions:[]
           ~reconcile_heads:None);
      reject "metadata project escaped strict previous-root validation"
        (S.save_collaborative repository ~expected:metadata.S.metadata_head
           ~project:metadata.S.metadata_project
           ~collaboration:(Option.get metadata.S.metadata_collaboration));
      Alcotest.(check bool)
        "inspection/writes do not heal from working files" false
        (Sys.file_exists (Raw.object_path store chunk));
      Alcotest.(check string)
        "ordinary shared bytes remain unchanged" bytes
        (read_file root "shared.bin");
      Alcotest.(check bool)
        "read-only failure preserves exact root" true
        (Raw.Mutable_ref.equal before.S.head
           (Option.get
              (Raw.read_ref store ~name:S.state_head_name
              |> ok Raw.error_to_string)));
      Raw.put store envelope |> ok Raw.error_to_string |> ignore;
      Alcotest.(check bool)
        "restoring exact immutable data permits full validation" true
        (match S.inspect repository |> ok S.error_to_string with
        | S.Verified _ -> true
        | S.Metadata_only _ -> false);
      let chunk_path = Raw.object_path store chunk in
      Out_channel.with_open_bin chunk_path (fun out ->
          output_string out "corrupt immutable object");
      check_cli 6 "saved-state-unverified";
      reject "corrupt public contents authorized writes" (Service.save ~root);
      reject "corrupt immutable object was replaced implicitly"
        (Raw.put store envelope);
      Alcotest.(check string)
        "corruption remains available for explicit diagnosis"
        "corrupt immutable object"
        (In_channel.with_open_bin chunk_path In_channel.input_all);
      Alcotest.(check string)
        "corrupt-content inspection preserves working bytes" bytes
        (read_file root "shared.bin");
      Alcotest.(check bool)
        "corrupt-content inspection preserves exact root" true
        (Raw.Mutable_ref.equal before.S.head
           (Option.get
              (Raw.read_ref store ~name:S.state_head_name
              |> ok Raw.error_to_string))))

let native_integration_preserves_private_work_and_retries () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      write_file root "note.txt" "shared D\n";
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let chosen = [ Option.get shared.Service.Share.revision ] in
      write_file root "note.txt" "shared D\nprivate E\n";
      let before = load repository in
      let plan = native_plan root chosen in
      Alcotest.(check bool)
        "preview does not move root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      let result = native_apply root plan (Some capability) in
      let operation = Option.get result.Native_integrate.operation in
      let committed = load repository in
      Alcotest.(check bool)
        "completed durable fact" true
        (operation.Op.phase = Op.Completed);
      Alcotest.(check bool)
        "offline outbound work is pending" false operation.Op.acknowledged;
      Alcotest.(check int)
        "one unsaved safety plus distinct integration history"
        (List.length (H.nodes before.S.history) + 2)
        (List.length (H.nodes committed.S.history));
      Alcotest.(check string)
        "private E survives" "shared D\nprivate E\n"
        (read_file root "note.txt");
      Alcotest.(check string)
        "unselected private sentinel survives" "private\000bytes\255"
        (read_private root);
      let accepted =
        Composition.Graph.accepted
          (L.pool (local committed))
          (L.selected (local committed)).L.basis
        |> ok Composition.Graph.error_to_string
      in
      Alcotest.(check bool)
        "accepted only D" true
        (C.Object_id.equal accepted.C.result_snapshot
           shared.Service.Share.public_snapshot);
      let same = native_apply root plan None in
      Alcotest.(check bool)
        "same durable operation without signer" true
        ((Option.get same.Native_integrate.operation).Op.token
       = operation.Op.token);
      Alcotest.(check bool)
        "lost acknowledgement never republishes root" true
        (Raw.Mutable_ref.equal committed.S.head (load repository).S.head);
      let fresh = native_plan root chosen in
      let noop = native_apply root fresh None in
      Alcotest.(check bool)
        "already represented work is honest no-op" true
        noop.Native_integrate.no_op;
      Alcotest.(check bool)
        "no-op creates no operation" true
        (noop.Native_integrate.operation = None);
      Alcotest.(check bool)
        "no duplicate navigation" true
        (Raw.Mutable_ref.equal committed.S.head (load repository).S.head))

let[@warning "-4"] interrupt_native root plan capability boundary =
  let child = Unix.fork () in
  if child = 0 then (
    let observe seen =
      match (seen, boundary) with
      | Native_integrate.Mutation (a, _), Native_integrate.Mutation (b, _)
        when a = b ->
          Unix._exit 73
      | a, b when a = b -> Unix._exit 73
      | _ -> ()
    in
    ignore
      (Native_integrate.For_test.apply ~observe ~root ~plan:(I.id plan)
         ~signing_capability:(Some capability));
    Unix._exit 74);
  let _, status = Unix.waitpid [] child in
  Alcotest.(check bool)
    "interrupted at actual requested boundary" true (status = Unix.WEXITED 73)

let stage_resolution_proposal repository capability certificate authority
    revisions bytes =
  let before = load repository in
  let store = S.underlying_store repository in
  let local_before = local before in
  let selected = L.selected local_before in
  let heads =
    List.find
      (fun row -> C.Branch_id.equal row.C.branch_id selected.L.branch)
      (L.branches local_before)
  in
  let common =
    Composition.Graph.common_base (L.pool local_before) heads.C.accepted_heads
    |> ok Composition.Graph.error_to_string
  in
  let comparison =
    Composition.Graph.accepted (L.pool local_before) common
    |> ok Composition.Graph.error_to_string
    |> fun v -> v.C.result_snapshot
  in
  let base =
    Composition.load store comparison |> ok Composition.error_to_string
  in
  let content =
    Snapshot.Content.store store bytes |> ok Snapshot.error_to_string
  in
  let replacement =
    Composition.overlay ~base
      [
        ( [ "note.txt" ],
          Some (Composition.File { mode = Snapshot.Regular; content }) );
      ]
    |> ok Composition.error_to_string
    |> Composition.store store
    |> ok Composition.error_to_string
  in
  let scope =
    Composition.Scope.store store [ [ "note.txt" ] ]
    |> ok Composition.error_to_string
  in
  let payload =
    C.make_resolution_revision ~branch:selected.L.branch
      ~accepted_heads:heads.C.accepted_heads ~chosen_revisions:revisions
      ~superseded_variants:
        (C.resolution_variants (L.pool local_before)
           ~accepted_heads:heads.C.accepted_heads ~chosen_revisions:revisions
        |> model)
      ~decision_scope_root:scope ~comparison_snapshot:comparison
      ~replacement_snapshot:replacement
    |> model
    |> fun v -> C.Resolution_revision v
  in
  let context =
    C.make_context
      ~repository:(C.pool_repository (L.pool local_before))
      ~author_certificate:(C.Digest.of_hex certificate |> model)
      ~authority_heads:
        (T.authority_heads authority
        |> List.map (fun id -> C.Digest.of_hex id |> model))
      ~display_time:None
    |> model
  in
  let signed =
    T.Core.sign authority capability (C.make_body ~context ~payload)
    |> ok T.Core.error_to_string
  in
  let identity = R.id signed |> ok R.error_to_string in
  let stored =
    R.encode signed |> ok R.error_to_string |> Yeokcham_envelope.decode
    |> ok Yeokcham_envelope.decode_error_to_string
    |> Raw.put store |> ok Raw.error_to_string
  in
  let next =
    L.receive_records ~store ~authority
      ~records:[ (identity, stored) ]
      local_before
    |> ok L.receive_error_to_string
  in
  let published =
    S.save_collaborative repository ~expected:before.S.head
      ~project:before.S.project ~history:before.S.history
      ~collaboration:(Option.get before.S.collaboration)
      ~local:next
    |> ok S.error_to_string
  in
  Alcotest.(check string)
    "resolution proposal preserves exact private history"
    (H.encode before.S.history |> ok Fun.id)
    (H.encode published.S.history |> ok Fun.id);
  Alcotest.(check bool)
    "proposal does not accept shared work" true
    (L.branches local_before = L.branches (local published));
  (identity, replacement)

let resolved_native_integration_proves_exact_acceptance_and_retries () =
  List.iter
    (fun replacement ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          let left, _ =
            add_incoming_revision repository capability certificate authority
              "note.txt" "left\r\n"
          in
          let right, _ =
            add_incoming_revision repository capability certificate authority
              "note.txt" "right\r\n"
          in
          let revisions = List.sort C.Record_id.compare [ left; right ] in
          let unresolved = native_plan root revisions in
          Alcotest.(check bool)
            "unresolved work has no acceptance" true
            (match I.readiness unresolved with
            | I.Conflicted _ -> true
            | I.Ready _ | I.Decision _ -> false);
          write_private root "private E stays local";
          let resolution, public_result =
            stage_resolution_proposal repository capability certificate
              authority revisions replacement
          in
          Alcotest.(check bool)
            "preparation leaves the conflicted ordinary file absent" false
            (Sys.file_exists (root ^ "/note.txt"));
          let before = load repository in
          let prepared =
            Native_integrate.prepare_resolved ~root
              ~selected_revisions:revisions ~resolution_ids:[ resolution ]
              ~reconcile_heads:None
            |> integrate_ok
          in
          Alcotest.(check bool)
            "exact resolution identity binds the canonical plan" true
            ((I.request prepared).C.resolution_ids = [ resolution ]);
          Alcotest.(check bool)
            "new resolved proposal does not reuse unresolved identity" false
            (C.Plan_id.equal (I.id prepared) (I.id unresolved));
          Alcotest.(check bool)
            "resolved preparation preserves root" true
            (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
          let applied = native_apply root prepared (Some capability) in
          let committed = load repository in
          let accepted =
            Composition.Graph.accepted
              (L.pool (local committed))
              (L.selected (local committed)).L.basis
            |> ok Composition.Graph.error_to_string
          in
          Alcotest.(check bool)
            "accepted record binds the actual explicit resolution" true
            (accepted.C.resolutions = [ resolution ]);
          Alcotest.(check bool)
            "public result contains only the exact decided shared bytes" true
            (C.Object_id.equal accepted.C.result_snapshot public_result);
          Alcotest.(check string)
            "private continuation remains private and on disk"
            "private E stays local" (read_private root);
          Alcotest.(check string)
            "whole-path replacement bytes are exact" replacement
            (read_file root "note.txt");
          let repeated = native_apply root prepared None in
          Alcotest.(check bool)
            "resolved application retries the same operation without a signer"
            true
            ((Option.get applied.Native_integrate.operation).Op.token
           = (Option.get repeated.Native_integrate.operation).Op.token);
          Alcotest.(check bool)
            "retry publishes no duplicate acceptance/history" true
            (Raw.Mutable_ref.equal committed.S.head (load repository).S.head)))
    [
      "explicit text\r\nwithout final newline";
      "\000" ^ String.make ((2 * 1024 * 1024) + 31) 'b';
    ]

let resolved_native_integration_resumes_durable_facts () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          let left, _ =
            add_incoming_revision repository capability certificate authority
              "note.txt" "left"
          in
          let right, _ =
            add_incoming_revision repository capability certificate authority
              "note.txt" "right"
          in
          let revisions = List.sort C.Record_id.compare [ left; right ] in
          let resolution, _ =
            stage_resolution_proposal repository capability certificate
              authority revisions "chosen"
          in
          let plan =
            Native_integrate.prepare_resolved ~root
              ~selected_revisions:revisions ~resolution_ids:[ resolution ]
              ~reconcile_heads:None
            |> integrate_ok
          in
          interrupt_native root plan capability boundary;
          ignore (native_apply root plan None);
          let after = load repository in
          Alcotest.(check string)
            "resolved resume materializes exact choice" "chosen"
            (read_file root "note.txt");
          Alcotest.(check int)
            "resolved resume allocates one navigation" 2
            (List.length (H.nodes after.S.history));
          ignore (native_apply root plan None);
          Alcotest.(check bool)
            "resolved fact retry keeps the same root" true
            (Raw.Mutable_ref.equal after.S.head (load repository).S.head)))
    [
      Native_integrate.Prepared_root;
      Native_integrate.Mutation
        (Service.Safe_apply.After_mutation, [ "note.txt" ]);
      Native_integrate.Materialized_root;
      Native_integrate.Committed_root;
    ]

let unaccepted_resolution_replacement_survives_gc () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let left, _ =
        add_incoming_revision repository capability certificate authority
          "note.txt" "left"
      in
      let right, _ =
        add_incoming_revision repository capability certificate authority
          "note.txt" "right"
      in
      let revisions = List.sort C.Record_id.compare [ left; right ] in
      let bytes = "\000" ^ String.make ((2 * 1024 * 1024) + 23) 'q' in
      let resolution, replacement =
        stage_resolution_proposal repository capability certificate authority
          revisions bytes
      in
      let before = load repository in
      let replacement_id =
        C.Object_id.to_hex replacement
        |> Raw.Stored_object_id.of_hex
        |> ok Raw.Stored_object_id.parse_error_to_string
      in
      let planned =
        Yeokcham_v1_gc.plan ~root |> ok Yeokcham_v1_gc.error_to_string
      in
      let entry =
        List.find
          (fun entry ->
            Raw.Stored_object_id.equal entry.Yeokcham_v1_gc.object_id
              replacement_id)
          planned.Yeokcham_v1_gc.objects
      in
      Alcotest.(check bool)
        "unaccepted replacement is a shared root before any plan exists" false
        (entry.Yeokcham_v1_gc.disposition = Yeokcham_v1_gc.Collect);
      Yeokcham_v1_gc.apply ~root |> ok Yeokcham_v1_gc.error_to_string |> ignore;
      let after = load repository in
      Alcotest.(check bool)
        "GC does not accept, navigate or publish project metadata" true
        (Raw.Mutable_ref.equal before.S.head after.S.head);
      let store = S.underlying_store repository in
      let tree =
        Composition.load store replacement |> ok Composition.error_to_string
      in
      let content =
        match List.assoc [ "note.txt" ] (Composition.entries tree) with
        | Composition.File file -> file.content
        | Composition.Directory -> Alcotest.fail "replacement is not a file"
      in
      Alcotest.(check string)
        "complete streamed replacement closure remains readable after \
         collection"
        bytes
        (Snapshot.Content.load store content |> ok Snapshot.error_to_string);
      let prepared =
        Native_integrate.prepare_resolved ~root ~selected_revisions:revisions
          ~resolution_ids:[ resolution ] ~reconcile_heads:None
        |> integrate_ok
      in
      ignore (native_apply root prepared (Some capability));
      Alcotest.(check string)
        "collected store still materializes the exact pending decision" bytes
        (read_file root "note.txt"))

let native_integration_resumes_real_file_and_root_boundaries () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          let revision, _ =
            add_incoming_revision repository capability certificate authority
              "remote.txt" "received shared D\n"
          in
          let plan = native_plan root [ revision ] in
          let before = load repository in
          interrupt_native root plan capability boundary;
          let interrupted = load repository in
          let operation = List.hd (L.operations (local interrupted)) in
          if not (Op.committed operation) then (
            Alcotest.(check int)
              "no target history before actual commit"
              (List.length (H.nodes before.S.history))
              (List.length (H.nodes interrupted.S.history));
            reject "pending plan alias was forgotten"
              (I.forget ~store:(S.underlying_store repository) (I.id plan));
            reject "capture accepted a partial integration tree"
              (Service.save ~root));
          let resumed = native_apply root plan None in
          let after = load repository in
          Alcotest.(check bool)
            "resumed same token" true
            ((Option.get resumed.Native_integrate.operation).Op.token
           = operation.Op.token);
          Alcotest.(check string)
            "actual received file installed" "received shared D\n"
            (read_file root "remote.txt");
          Alcotest.(check string)
            "original private data retained" "private\000bytes\255"
            (read_private root);
          Alcotest.(check int)
            "one exact target history child"
            (List.length (H.nodes before.S.history) + 1)
            (List.length (H.nodes after.S.history));
          Alcotest.(check int)
            "one accepted/event pair"
            (List.length (L.record_objects (local before)) + 2)
            (List.length (L.record_objects (local after)));
          let acknowledged =
            Op.acknowledge (Option.get resumed.Native_integrate.operation)
            |> ok Fun.id
          in
          let acknowledged_local =
            L.put_operation
              ~store:(S.underlying_store repository)
              acknowledged (local after)
            |> ok Fun.id
          in
          S.save_collaborative ~local:acknowledged_local repository
            ~expected:after.S.head ~project:after.S.project
            ~collaboration:(Option.get after.S.collaboration)
          |> ok S.error_to_string |> ignore;
          Alcotest.(check bool)
            "acknowledgement durable without another acceptance" true
            (List.hd (L.operations (local (load repository)))).Op.acknowledged))
    [
      Native_integrate.Prepared_root;
      Native_integrate.Applying_root;
      Native_integrate.Mutation (Service.Safe_apply.Before_mutation, []);
      Native_integrate.Mutation (Service.Safe_apply.After_mutation, []);
      Native_integrate.Mutation (Service.Safe_apply.After_sync, []);
      Native_integrate.Materialized_root;
      Native_integrate.Committed_root;
      Native_integrate.Completed_root;
    ]

let[@warning "-4"] native_integration_materialized_retry_preserves_external_edits_and_receipts
    () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let revision, _ =
        add_incoming_revision repository capability certificate authority
          "remote.txt" "accepted D\n"
      in
      let plan = native_plan root [ revision ] in
      interrupt_native root plan capability Native_integrate.Materialized_root;
      write_file root "remote.txt" "late external E\n";
      let unrelated, _ =
        add_incoming_revision repository capability certificate authority
          "other.txt" "independent receipt\n"
      in
      let gc = Yeokcham_v1_gc.plan ~root |> ok Yeokcham_v1_gc.error_to_string in
      Alcotest.(check bool)
        "operation roots are explicit in actual GC" true
        (List.exists
           (fun object_ ->
             match object_.Yeokcham_v1_gc.disposition with
             | Yeokcham_v1_gc.Collect -> false
             | Yeokcham_v1_gc.Retain reasons ->
                 List.exists
                   (function
                     | Yeokcham_v1_gc.Integration_operation _ -> true
                     | _ -> false)
                   reasons)
           gc.Yeokcham_v1_gc.objects);
      Snapshot.Content.store
        (S.underlying_store repository)
        "unreferenced GC exercise"
      |> ok Snapshot.error_to_string
      |> ignore;
      Yeokcham_v1_gc.apply ~root |> ok Yeokcham_v1_gc.error_to_string |> ignore;
      let result = native_apply root plan None in
      let loaded = load repository in
      Alcotest.(check string)
        "no replay after Materialized" "late external E\n"
        (read_file root "remote.txt");
      Alcotest.(check bool)
        "unrelated received record retained" true
        (Option.is_some (C.find (L.pool (local loaded)) unrelated));
      let operation = Option.get result.Native_integrate.operation in
      let target =
        H.find loaded.S.history operation.Op.target_sequence |> ok Fun.id
      in
      let object_id =
        C.Object_id.of_hex (M.Snapshot_id.to_string target.H.snapshot) |> model
      in
      Alcotest.(check string)
        "history records verified target, not later disk edits" "accepted D\n"
        (preserved_entry
           (S.underlying_store repository)
           object_id [ "remote.txt" ]))

let[@warning "-4"] native_integration_pauses_on_external_edit_during_application
    () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let revision, _ =
        add_incoming_revision repository capability certificate authority
          "remote.txt" "target D\n"
      in
      let plan = native_plan root [ revision ] in
      interrupt_native root plan capability
        (Native_integrate.Mutation (Service.Safe_apply.After_sync, []));
      write_file root "remote.txt" "unexpected external bytes\n";
      reject "integration overwrote an unexplained postimage"
        (Native_integrate.apply ~root ~plan:(I.id plan) ~signing_capability:None);
      let loaded = load repository in
      let operation = Option.get (L.pending_operation (local loaded)) in
      Alcotest.(check bool)
        "durable Paused fact retains Applying stage" true
        (match operation.Op.phase with
        | Op.Paused (Op.During_apply, _) -> true
        | _ -> false);
      Alcotest.(check string)
        "unexpected bytes preserved" "unexpected external bytes\n"
        (read_file root "remote.txt");
      Alcotest.(check int)
        "no partial-tree history" 1
        (List.length (H.nodes loaded.S.history));
      reject "save captured partial tree" (Service.save ~root);
      reject "undo competed with active integration"
        (Service.navigate_history ~root ~direction:Service.Undo ~dry_run:false);
      reject "switch competed with active integration"
        (Service.branch_switch ~root ~name:"main" ~dry_run:false);
      let status = Service.inspect_local_status ~root |> service in
      Alcotest.(check bool)
        "status reports no complete observation of a partial tree" true
        (Result.is_error status.Service.capture_observation);
      reject "phase jump bypassed application"
        (Op.advance operation Op.Committed))

let native_integration_stale_plan_refuses_before_reservation () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let revision, _ =
        add_incoming_revision repository capability certificate authority
          "remote.txt" "D\n"
      in
      let plan = native_plan root [ revision ] in
      write_private root "changed after confirmation\000";
      let before = load repository in
      reject "stale plan began application"
        (Native_integrate.apply ~root ~plan:(I.id plan)
           ~signing_capability:(Some capability));
      let after = load repository in
      Alcotest.(check bool)
        "stale plan creates no operation" true
        (L.operations (local after) = []);
      Alcotest.(check bool)
        "stale plan does not move root" true
        (Raw.Mutable_ref.equal before.S.head after.S.head);
      Alcotest.(check bool)
        "stale plan does not install target" false
        (Sys.file_exists (root ^ "/remote.txt")))

let native_integration_metadata_cas_faults_are_idempotent () =
  List.iter
    (fun stop_before ->
      List.iter
        (fun root_number ->
          with_root (fun root ->
              let repository, capability, certificate, authority, _ =
                initialize root
              in
              let revision, _ =
                add_incoming_revision repository capability certificate
                  authority "remote.txt" "D\n"
              in
              let plan = native_plan root [ revision ] in
              let before = load repository in
              let child = Unix.fork () in
              if child = 0 then (
                let count = ref 0 in
                let observe seen =
                  if seen = Native_integrate.Before_root then (
                    incr count;
                    if stop_before && !count = root_number then Unix._exit 73);
                  if
                    seen = Native_integrate.After_root
                    && (not stop_before) && !count = root_number
                  then Unix._exit 73
                in
                ignore
                  (Native_integrate.For_test.apply ~observe ~root
                     ~plan:(I.id plan) ~signing_capability:(Some capability));
                Unix._exit 74);
              let _, status = Unix.waitpid [] child in
              Alcotest.(check bool)
                "actual metadata publication boundary reached" true
                (status = Unix.WEXITED 73);
              let saved =
                L.find_operation (local (load repository)) ~plan:(I.id plan)
              in
              let resumed =
                native_apply root plan
                  (if saved = None then Some capability else None)
              in
              let after = load repository in
              Option.iter
                (fun old ->
                  Alcotest.(check bool)
                    "durable token reused after lost acknowledgement" true
                    (old.Op.token
                   = (Option.get resumed.Native_integrate.operation).Op.token))
                saved;
              Alcotest.(check int)
                "CAS fault yields one accepted/event pair"
                (List.length (L.record_objects (local before)) + 2)
                (List.length (L.record_objects (local after)));
              Alcotest.(check int)
                "CAS fault yields one navigation"
                (List.length (H.nodes before.S.history) + 1)
                (List.length (H.nodes after.S.history));
              Alcotest.(check string)
                "exact target installed" "D\n"
                (read_file root "remote.txt")))
        [ 1; 2; 3; 4; 5 ])
    [ true; false ]

let native_integration_root_refuses_operation_erasure_and_partial_capture () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let revision, _ =
        add_incoming_revision repository capability certificate authority
          "remote.txt" "D\n"
      in
      let plan = native_plan root [ revision ] in
      let before = load repository in
      interrupt_native root plan capability Native_integrate.Prepared_root;
      let prepared = load repository in
      let operation = Option.get (L.pending_operation (local prepared)) in
      reject "erased durable plan/token association"
        (S.save_collaborative ~local:(local before) repository
           ~expected:prepared.S.head ~project:prepared.S.project
           ~collaboration:(Option.get prepared.S.collaboration));
      let snapshot = (H.current prepared.S.history).H.snapshot in
      let history =
        H.record_exact prepared.S.history ~expected:operation.Op.target_sequence
          ~snapshot ~draft ~created_at:operation.Op.created_at
        |> ok Fun.id
      in
      reject "allocated the target sequence to a partial-tree capture"
        (S.save_collaborative ~history repository ~expected:prepared.S.head
           ~project:prepared.S.project
           ~collaboration:(Option.get prepared.S.collaboration));
      let pending = Op.advance operation Op.Applying |> ok Fun.id in
      let replay = Op.advance operation Op.Prepared |> ok Fun.id in
      Alcotest.(check bool)
        "identical phase retry does not advance serial" true (replay = operation);
      reject "operation rewound its phase"
        (Op.validate_update ~previous:pending operation);
      reject "uncommitted operation claimed outbound acknowledgement"
        (Op.acknowledge operation);
      Alcotest.(check bool)
        "refusals do not mutate root" true
        (Raw.Mutable_ref.equal prepared.S.head (load repository).S.head);
      native_apply root plan None |> ignore)

let native_integration_signer_runs_without_writer_lock_and_revalidates () =
  List.iter
    (fun edit_during_signing ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          let revision, _ =
            add_incoming_revision repository capability certificate authority
              "remote.txt" "D\n"
          in
          let plan = native_plan root [ revision ] in
          let before = load repository in
          let calls = ref 0 in
          let external_signer =
            T.signing_capability_of_external_signer
              ~public_key:(T.signing_public_key capability)
              ~sign:(fun ~domain bytes ->
                incr calls;
                let child = Unix.fork () in
                (if child = 0 then
                   let fd =
                     Unix.openfile
                       (root ^ "/.yeokcham/local-worktree.lock")
                       [ Unix.O_RDWR; Unix.O_CLOEXEC ]
                       0
                   in
                   try
                     Unix.lockf fd Unix.F_TLOCK 0;
                     Unix.close fd;
                     Unix._exit 0
                   with Unix.Unix_error _ -> Unix._exit 1);
                let _, status = Unix.waitpid [] child in
                Alcotest.(check bool)
                  "external provider has no held writer lock" true
                  (status = Unix.WEXITED 0);
                if edit_during_signing then
                  write_private root "changed while provider was active";
                T.sign_detached capability ~domain bytes
                |> Result.map_error T.error_to_string)
            |> trust
          in
          let result =
            Native_integrate.apply ~root ~plan:(I.id plan)
              ~signing_capability:(Some external_signer)
          in
          Alcotest.(check int) "exact acceptance and event signed" 2 !calls;
          if edit_during_signing then (
            reject "provider-time disk edits bypassed revalidation" result;
            Alcotest.(check bool)
              "provider-time stale result did not reserve operation" true
              (L.operations (local (load repository)) = []);
            Alcotest.(check bool)
              "provider-time stale result did not publish metadata" true
              (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
            Alcotest.(check bool)
              "provider-time stale result did not replace files" false
              (Sys.file_exists (root ^ "/remote.txt")))
          else integrate_ok result |> ignore))
    [ false; true ]

let native_integration_entropy_and_collision_refuse_before_files () =
  with_root (fun root ->
      let repository, capability, _, _, _ = initialize root in
      write_file root "note.txt" "D\n";
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let plan =
        native_plan root [ Option.get shared.Service.Share.revision ]
      in
      let before = load repository in
      let receipt = List.hd (L.publications (local before)) in
      let calls = ref 0 in
      reject "operation token collided with publication"
        (Native_integrate.For_test.apply_with_entropy
           ~random_bytes:(fun _ ->
             incr calls;
             Ok (C.Operation_id.to_raw receipt.L.operation))
           ~observe:(fun _ -> ())
           ~root ~plan:(I.id plan) ~signing_capability:(Some capability));
      Alcotest.(check int) "collision retries bounded" 3 !calls;
      reject "entropy failure produced durable operation"
        (Native_integrate.For_test.apply_with_entropy
           ~random_bytes:(fun _ -> Error "entropy unavailable")
           ~observe:(fun _ -> ())
           ~root ~plan:(I.id plan) ~signing_capability:(Some capability));
      Alcotest.(check bool)
        "failure did not reserve history/root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check bool)
        "failure did not persist operation" true
        (L.operations (local (load repository)) = []))

let recovery_fixture root =
  let repository, capability, certificate, authority, _ = initialize root in
  let revision, _ =
    add_incoming_revision repository capability certificate authority
      "remote.txt" "shared target D\n"
  in
  let plan = native_plan root [ revision ] in
  interrupt_native root plan capability
    (Native_integrate.Mutation (Service.Safe_apply.After_sync, []));
  write_file root "remote.txt" "external X\n";
  write_private root "private Y\000";
  reject "original integration overwrote external edits"
    (Native_integrate.apply ~root ~plan:(I.id plan) ~signing_capability:None);
  let loaded = load repository in
  let operation = Option.get (L.pending_operation (local loaded)) in
  (repository, capability, revision, plan, operation)

let recover_native root token ~preview ~mode ~replan ~expected =
  Native_integrate.recover ~root ~operation:token ~dry_run:preview ~mode ~replan
    ~expected_plan:expected
  |> integrate_ok

let[@warning "-4"] interrupt_recovery root token boundary =
  let child = Unix.fork () in
  if child = 0 then (
    let observe seen =
      match (seen, boundary) with
      | ( Native_integrate.Recovery_mutation (a, _),
          Native_integrate.Recovery_mutation (b, _) )
        when a = b ->
          Unix._exit 73
      | a, b when a = b -> Unix._exit 73
      | _ -> ()
    in
    ignore
      (Native_integrate.For_test.recover ~observe ~root ~operation:token
         ~dry_run:false ~mode:None ~replan:false ~expected_plan:None);
    Unix._exit 74);
  let _, status = Unix.waitpid [] child in
  Alcotest.(check bool)
    "recovery reached actual requested boundary" true (status = Unix.WEXITED 73)

let native_recovery_restores_safety_without_acceptance_or_losing_observations ()
    =
  with_root (fun root ->
      let repository, capability, revision, plan, operation =
        recovery_fixture root
      in
      let before = load repository in
      let preview =
        recover_native root operation.Op.token ~preview:true ~mode:None
          ~replan:false ~expected:None
      in
      Alcotest.(check bool)
        "recovery preview leaves root unchanged" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "recovery preview leaves external bytes" "external X\n"
        (read_file root "remote.txt");
      let result =
        recover_native root operation.Op.token ~preview:false ~mode:None
          ~replan:false ~expected:(Some preview.Native_integrate.recovery_plan)
      in
      let recovered = result.Native_integrate.recovery_operation in
      let loaded = load repository in
      Alcotest.(check bool) "closed as recovered" true (Op.recovered recovered);
      Alcotest.(check bool)
        "recovery did not publish acceptance" false (Op.committed recovered);
      Alcotest.(check bool)
        "basis unchanged" true
        ((L.selected (local before)).L.basis
       = (L.selected (local loaded)).L.basis);
      Alcotest.(check int)
        "no signed records admitted"
        (List.length (L.record_objects (local before)))
        (List.length (L.record_objects (local loaded)));
      Alcotest.(check int)
        "one explicit safety-restoration child"
        (List.length (H.nodes before.S.history) + 1)
        (List.length (H.nodes loaded.S.history));
      Alcotest.(check string)
        "original safety restored" "private\000bytes\255" (read_private root);
      Alcotest.(check bool)
        "unaccepted introduced file removed recoverably" false
        (Sys.file_exists (root ^ "/remote.txt"));
      let store = S.underlying_store repository in
      Alcotest.(check string)
        "unexpected X retained in recovery observation" "external X\n"
        (preserved_entry store result.Native_integrate.recovery_observed
           [ "remote.txt" ]);
      Alcotest.(check string)
        "unexpected Y retained in recovery observation" "private Y\000"
        (preserved_entry store result.Native_integrate.recovery_observed
           [ "private.bin" ]);
      let repeated =
        Native_integrate.resume ~root ~operation:operation.Op.token
        |> integrate_ok
      in
      Alcotest.(check bool)
        "normal resume acknowledges recovered outcome" true
        repeated.Native_integrate.recovered;
      let again = native_apply root plan None in
      Alcotest.(check bool)
        "old plan retry never resurrects cancelled acceptance" true
        again.Native_integrate.recovered;
      Alcotest.(check bool)
        "recovered retry does not advance root" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head);
      let fresh = native_plan root [ revision ] in
      Alcotest.(check bool)
        "recovery cursor gives a fresh exact plan" false
        (C.Plan_id.equal (I.id plan) (I.id fresh));
      native_apply root fresh (Some capability) |> ignore;
      Alcotest.(check string)
        "fresh confirmed integration still usable" "shared target D\n"
        (read_file root "remote.txt"))

let native_recovery_resumes_file_and_metadata_boundaries () =
  List.iter
    (fun boundary ->
      with_root (fun root ->
          let repository, _, _, _, operation = recovery_fixture root in
          let before = load repository in
          interrupt_recovery root operation.Op.token boundary;
          let interrupted = load repository in
          let saved = List.hd (L.operations (local interrupted)) in
          let recovery = Option.get saved.Op.recovery in
          let private_committed =
            match recovery.Op.progress with
            | Op.Recovery_committed | Op.Recovery_completed -> true
            | Op.Recovery_prepared | Op.Recovery_applying
            | Op.Recovery_materialized ->
                false
          in
          Alcotest.(check int)
            "no partial recovery history before commit"
            (List.length (H.nodes before.S.history)
            + if private_committed then 1 else 0)
            (List.length (H.nodes interrupted.S.history));
          let resumed =
            Native_integrate.resume ~root ~operation:operation.Op.token
            |> integrate_ok
          in
          Alcotest.(check bool)
            "recovery resumed without signer" true
            resumed.Native_integrate.recovered;
          let loaded = load repository in
          Alcotest.(check int)
            "exactly one recovery navigation"
            (List.length (H.nodes before.S.history) + 1)
            (List.length (H.nodes loaded.S.history));
          Alcotest.(check bool)
            "recovery never admitted original acceptance" false
            (Option.is_some
               (C.find (L.pool (local loaded)) operation.Op.accepted));
          Alcotest.(check string)
            "exact safety restored after restart" "private\000bytes\255"
            (read_private root);
          let repeated =
            recover_native root operation.Op.token ~preview:false ~mode:None
              ~replan:false ~expected:(Some recovery.Op.plan_id)
          in
          Alcotest.(check bool)
            "same recovery plan on repeated acknowledgement" true
            (repeated.Native_integrate.recovery_plan = recovery.Op.plan_id)))
    [
      Native_integrate.Recovery_prepared_root;
      Native_integrate.Recovery_applying_root;
      Native_integrate.Recovery_mutation (Service.Safe_apply.Before_mutation, []);
      Native_integrate.Recovery_mutation (Service.Safe_apply.After_mutation, []);
      Native_integrate.Recovery_mutation (Service.Safe_apply.After_sync, []);
      Native_integrate.Recovery_materialized_root;
      Native_integrate.Recovery_committed_root;
      Native_integrate.Recovery_completed_root;
    ]

let native_recovery_materialized_retry_preserves_later_edits () =
  with_root (fun root ->
      let repository, _, _, _, operation = recovery_fixture root in
      interrupt_recovery root operation.Op.token
        Native_integrate.Recovery_materialized_root;
      write_private root "late after recovery materialization\000";
      Native_integrate.resume ~root ~operation:operation.Op.token
      |> integrate_ok |> ignore;
      Alcotest.(check string)
        "recovery never replays after Materialized"
        "late after recovery materialization\000" (read_private root);
      let loaded = load repository in
      Alcotest.(check string)
        "history records verified safety result" "private\000bytes\255"
        (preserved_entry
           (S.underlying_store repository)
           (C.Object_id.of_hex
              (M.Snapshot_id.to_string (H.current loaded.S.history).H.snapshot)
           |> model)
           [ "private.bin" ]))

let native_recovery_replans_without_erasing_prior_observations () =
  with_root (fun root ->
      let repository, _, _, _, operation = recovery_fixture root in
      interrupt_recovery root operation.Op.token
        (Native_integrate.Recovery_mutation (Service.Safe_apply.After_sync, []));
      write_private root "new edit during recovery\000";
      reject "recovery blindly overwrote a newer edit"
        (Native_integrate.resume ~root ~operation:operation.Op.token);
      let paused = List.hd (L.operations (local (load repository))) in
      let old = Option.get paused.Op.recovery in
      Alcotest.(check bool)
        "recovery pause reason is durable" true
        (Option.is_some old.Op.pause_reason);
      let preview =
        recover_native root operation.Op.token ~preview:true
          ~mode:(Some Op.Keep_current) ~replan:true ~expected:None
      in
      let kept =
        recover_native root operation.Op.token ~preview:false
          ~mode:(Some Op.Keep_current) ~replan:true
          ~expected:(Some preview.Native_integrate.recovery_plan)
      in
      let closed = kept.Native_integrate.recovery_operation in
      Alcotest.(check int)
        "old recovery intent retained in paged history" 1
        (List.length closed.Op.previous_recoveries);
      Alcotest.(check bool)
        "prior intent preserved exactly" true
        (List.hd closed.Op.previous_recoveries = old);
      Alcotest.(check string)
        "newer external bytes kept" "new edit during recovery\000"
        (read_private root);
      let store = S.underlying_store repository in
      Alcotest.(check string)
        "older unexpected bytes remain available" "private Y\000"
        (preserved_entry store old.Op.observed [ "private.bin" ]);
      Snapshot.Content.store store "unrooted recovery GC exercise"
      |> ok Snapshot.error_to_string
      |> ignore;
      Yeokcham_v1_gc.apply ~root |> ok Yeokcham_v1_gc.error_to_string |> ignore;
      Alcotest.(check string)
        "older observation survives actual GC" "private Y\000"
        (preserved_entry store old.Op.observed [ "private.bin" ]);
      Native_integrate.forget_recovery_roots ~root ~operation:operation.Op.token
      |> integrate_ok |> ignore;
      let released = load repository in
      let again =
        Native_integrate.forget_recovery_roots ~root
          ~operation:operation.Op.token
        |> integrate_ok
      in
      Alcotest.(check bool)
        "explicit release is idempotent" false
        (Option.get again.Op.recovery).Op.retained;
      Alcotest.(check bool)
        "release retry does not republish root" true
        (Raw.Mutable_ref.equal released.S.head (load repository).S.head))

let native_recovery_released_proposal_can_be_collected_and_reopened () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let first, _ =
        add_incoming_revision repository capability certificate authority
          "first.txt" "first public change\n"
      in
      let second, _ =
        add_incoming_revision repository capability certificate authority
          "second.txt" "second public change\n"
      in
      let plan = native_plan root [ first; second ] in
      interrupt_native root plan capability Native_integrate.Prepared_root;
      let operation =
        Option.get (L.pending_operation (local (load repository)))
      in
      recover_native root operation.Op.token ~preview:false ~mode:None
        ~replan:false ~expected:None
      |> ignore;
      Native_integrate.forget_recovery_roots ~root ~operation:operation.Op.token
      |> integrate_ok |> ignore;
      Yeokcham_v1_gc.apply ~root |> ok Yeokcham_v1_gc.error_to_string |> ignore;
      let store = S.underlying_store repository in
      let proposed =
        Raw.Stored_object_id.of_raw_bytes
          (C.Object_id.to_raw operation.Op.target)
        |> Option.get
      in
      reject "released unaccepted merged target remains retained"
        (Raw.get store proposed);
      let reopened = load repository in
      let recovered = List.hd (L.operations (local reopened)) in
      Alcotest.(check bool)
        "cancelled operation remains inspectable after GC" true
        (Op.recovered recovered);
      Alcotest.(check bool)
        "collected proposal never became acceptance" false
        (Op.committed recovered);
      Native_integrate.resume ~root ~operation:operation.Op.token
      |> integrate_ok |> ignore)

let[@warning "-4"] native_recovery_decode_rejects_malformed_intents_and_history
    () =
  with_root (fun root ->
      let repository, _, _, _, operation = recovery_fixture root in
      recover_native root operation.Op.token ~preview:false ~mode:None
        ~replan:false ~expected:None
      |> ignore;
      let loaded = load repository in
      let state = local loaded in
      let store = S.underlying_store repository in
      let pool = L.pool state in
      let scope = C.pool_repository pool in
      let authority =
        Option.get (S.authority (Option.get loaded.S.collaboration))
      in
      let value =
        L.encode state |> ok Fun.id |> Encoding.decode
        |> ok Encoding.decode_error_to_string
      in
      let fields =
        match value with Encoding.Array xs -> xs | _ -> assert false
      in
      let operation_root =
        match List.hd (List.rev fields) with
        | Encoding.Bytes raw ->
            Raw.Stored_object_id.of_raw_bytes raw |> Option.get
        | _ -> assert false
      in
      let namespace =
        "local-integration-operations-v1\000" ^ C.Repository_id.to_raw scope
      in
      let rows =
        Pages.load store ~namespace operation_root |> ok Pages.error_to_string
      in
      let key, bytes = List.hd rows in
      let row = Encoding.decode bytes |> ok Encoding.decode_error_to_string in
      let row_fields =
        match row with Encoding.Array xs -> xs | _ -> assert false
      in
      let recovery = List.hd (List.rev row_fields) in
      let recovery_fields =
        match recovery with Encoding.Array xs -> xs | _ -> assert false
      in
      let array xs =
        Encoding.array xs |> ok Encoding.construction_error_to_string
      in
      let replace index value xs =
        List.mapi (fun at original -> if at = index then value else original) xs
      in
      let local_with_root root =
        array
          (List.rev
             (Encoding.bytes (Raw.Stored_object_id.to_raw_bytes root)
             :: List.tl (List.rev fields)))
        |> Encoding.encode
      in
      let reject_recovery label recovery =
        let altered =
          array (List.rev (recovery :: List.tl (List.rev row_fields)))
        in
        let root =
          Pages.store store ~namespace [ (key, Encoding.encode altered) ]
          |> ok Pages.error_to_string
        in
        reject label (L.decode ~store ~authority (local_with_root root))
      in
      List.iter
        (fun (index, value, label) ->
          reject_recovery label (array (replace index value recovery_fields)))
        [
          (0, Encoding.integer 2L, "unsupported recovery schema accepted");
          (1, Encoding.bytes "short", "malformed attempt accepted");
          ( 1,
            Encoding.bytes (C.Operation_id.to_raw operation.Op.token),
            "main/recovery token collision accepted" );
          (2, Encoding.bytes "short", "malformed recovery plan accepted");
          (3, Encoding.bytes "short", "malformed observation accepted");
          (5, Encoding.integer (-1L), "negative recovery timestamp accepted");
          (6, Encoding.integer 9L, "unsupported recovery phase accepted");
          ( 6,
            Encoding.integer 0L,
            "completed operation with uncommitted recovery accepted" );
          (8, Encoding.integer 9L, "unsupported recovery mode accepted");
          ( 9,
            Encoding.text "paused after completion"
            |> ok Encoding.construction_error_to_string,
            "committed paused recovery accepted" );
        ];
      let previous_value =
        array (replace 6 (Encoding.integer 2L) recovery_fields)
      in
      let prior namespace =
        Pages.store store ~namespace
          [ ("attempt", Encoding.encode previous_value) ]
        |> ok Pages.error_to_string
      in
      let wrong = prior "another-recovery-namespace" in
      reject_recovery "foreign recovery history namespace accepted"
        (array
           (replace 10
              (Encoding.bytes (Raw.Stored_object_id.to_raw_bytes wrong))
              recovery_fields));
      let proper =
        prior
          ("integration-recovery-history-v1\000"
          ^ C.Repository_id.to_raw scope
          ^ C.Operation_id.to_raw operation.Op.token)
      in
      reject_recovery "duplicate historical recovery attempt accepted"
        (array
           (replace 10
              (Encoding.bytes (Raw.Stored_object_id.to_raw_bytes proper))
              recovery_fields));
      Alcotest.(check bool)
        "invalid immutable controls never published" true
        (Raw.Mutable_ref.equal loaded.S.head (load repository).S.head))

let native_recovery_copyout_resume_owns_released_observation () =
  with_root (fun root ->
      with_copy_destination root (fun destination ->
          let repository, _, _, _, operation = recovery_fixture root in
          let recovered =
            recover_native root operation.Op.token ~preview:false ~mode:None
              ~replan:false ~expected:None
          in
          let target =
            snapshot
              (C.Object_id.to_hex recovered.Native_integrate.recovery_observed)
          in
          let child = Unix.fork () in
          if child = 0 then (
            Service.For_test.copy_out ~root ~checkpoint:target ~destination
              ~dry_run:false ~expected_plan:None ~observe:(fun stage ->
                if stage = Service.Prepared_journal then Unix._exit 73)
            |> ignore;
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "copy-out intent persisted before files" true
            (status = Unix.WEXITED 73);
          Native_integrate.forget_recovery_roots ~root
            ~operation:operation.Op.token
          |> integrate_ok |> ignore;
          Yeokcham_v1_gc.apply ~root
          |> ok Yeokcham_v1_gc.error_to_string
          |> ignore;
          let journal =
            J.latest_pending ~root |> ok J.error_to_string |> Option.get
          in
          let before = load repository in
          Service.recover_operation ~root
            ~operation:(Some (J.operation_id journal))
          |> service |> ignore;
          Alcotest.(check string)
            "recorded export survives original root release" "private Y\000"
            (In_channel.with_open_bin
               (destination ^ "/private.bin")
               In_channel.input_all);
          Alcotest.(check bool)
            "export resume does not move source history" true
            (Raw.Mutable_ref.equal before.S.head (load repository).S.head)))

let native_recovery_stale_preview_and_missing_safety_refuse_before_writes () =
  with_root (fun root ->
      let repository, _, _, _, operation = recovery_fixture root in
      let preview =
        recover_native root operation.Op.token ~preview:true ~mode:None
          ~replan:false ~expected:None
      in
      write_private root "edit after recovery preview\000";
      let before = load repository in
      reject "stale recovery applied"
        (Native_integrate.recover ~root ~operation:operation.Op.token
           ~dry_run:false ~mode:None ~replan:false
           ~expected_plan:(Some preview.Native_integrate.recovery_plan));
      Alcotest.(check bool)
        "stale recovery did not reserve intent" true
        ((List.hd (L.operations (local (load repository)))).Op.recovery = None);
      let store = S.underlying_store repository in
      let safety =
        Composition.load store operation.Op.safety
        |> ok Composition.error_to_string
        |> Composition.entries
      in
      let content =
        match List.assoc [ "private.bin" ] safety with
        | Composition.File file -> file.content
        | Composition.Directory -> Alcotest.fail "expected safety file"
      in
      Unix.unlink
        (Raw.object_path store (Snapshot.Content.stored_object_id content));
      reject "unavailable safety was materialized"
        (Native_integrate.recover ~root ~operation:operation.Op.token
           ~dry_run:false ~mode:None ~replan:false ~expected_plan:None);
      Alcotest.(check bool)
        "missing safety did not change metadata" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head);
      Alcotest.(check string)
        "missing safety leaves live bytes" "edit after recovery preview\000"
        (read_private root))

let native_materialization_verifies_untouched_target_paths () =
  with_root (fun root ->
      let repository, capability, certificate, authority, _ = initialize root in
      let revision, _ =
        add_incoming_revision repository capability certificate authority
          "remote.txt" "D\n"
      in
      let plan = native_plan root [ revision ] in
      let changed = ref false in
      let observe stage =
        if stage = Native_integrate.Applying_root then (
          changed := true;
          write_private root "external untouched path edit\000")
      in
      reject "Materialized falsely accepted changed untouched target bytes"
        (Native_integrate.For_test.apply ~observe ~root ~plan:(I.id plan)
           ~signing_capability:(Some capability));
      Alcotest.(check bool) "edit injected after Prepared" true !changed;
      Alcotest.(check string)
        "untouched-path edit preserved" "external untouched path edit\000"
        (read_private root);
      Alcotest.(check int)
        "no target history falsely committed" 1
        (List.length (H.nodes (load repository).S.history)))

let native_recovery_root_cas_faults_and_cleanup_are_idempotent () =
  List.iter
    (fun before_root ->
      List.iter
        (fun target_root ->
          with_root (fun root ->
              let repository, _, _, _, operation = recovery_fixture root in
              let child = Unix.fork () in
              if child = 0 then (
                let count = ref 0 in
                let observe seen =
                  if seen = Native_integrate.Before_root then (
                    incr count;
                    if before_root && !count = target_root then Unix._exit 73);
                  if
                    seen = Native_integrate.After_root
                    && (not before_root) && !count = target_root
                  then Unix._exit 73
                in
                ignore
                  (Native_integrate.For_test.recover ~observe ~root
                     ~operation:operation.Op.token ~dry_run:false ~mode:None
                     ~replan:false ~expected_plan:None);
                Unix._exit 74);
              let _, status = Unix.waitpid [] child in
              Alcotest.(check bool)
                "recovery stopped before/after actual root CAS" true
                (status = Unix.WEXITED 73);
              let result =
                recover_native root operation.Op.token ~preview:false ~mode:None
                  ~replan:false ~expected:None
              in
              Alcotest.(check bool)
                "one closed recovery" true
                (Op.recovered result.Native_integrate.recovery_operation);
              Alcotest.(check int)
                "one private recovery child" 2
                (List.length (H.nodes (load repository).S.history));
              Native_integrate.forget_recovery_roots ~root
                ~operation:operation.Op.token
              |> integrate_ok |> ignore;
              Alcotest.(check int)
                "owned restore proof released explicitly" 0
                (List.length
                   (Yeokcham_v1_restore_proof.scan ~root
                   |> ok Yeokcham_v1_restore_proof.error_to_string));
              let released = load repository in
              Native_integrate.forget_recovery_roots ~root
                ~operation:operation.Op.token
              |> integrate_ok |> ignore;
              Alcotest.(check bool)
                "release retry has no extra root update" true
                (Raw.Mutable_ref.equal released.S.head (load repository).S.head)))
        [ 1; 2; 3; 4; 5 ])
    [ true; false ]

let native_recovery_can_cancel_materialized_but_not_committed_acceptance () =
  List.iter
    (fun committed ->
      with_root (fun root ->
          let repository, capability, certificate, authority, _ =
            initialize root
          in
          let revision, _ =
            add_incoming_revision repository capability certificate authority
              "remote.txt" "D\n"
          in
          let plan = native_plan root [ revision ] in
          interrupt_native root plan capability
            (if committed then Native_integrate.Committed_root
             else Native_integrate.Materialized_root);
          let before = load repository in
          let operation = List.hd (L.operations (local before)) in
          if committed then (
            reject "recovery unaccepted committed shared history"
              (Native_integrate.recover ~root ~operation:operation.Op.token
                 ~dry_run:false ~mode:None ~replan:false ~expected_plan:None);
            Alcotest.(check bool)
              "commit refusal preserves root" true
              (Raw.Mutable_ref.equal before.S.head (load repository).S.head))
          else (
            recover_native root operation.Op.token ~preview:false ~mode:None
              ~replan:false ~expected:None
            |> ignore;
            Alcotest.(check bool)
              "materialized acceptance never published on recovery" false
              (Option.is_some
                 (C.find
                    (L.pool (local (load repository)))
                    operation.Op.accepted));
            Alcotest.(check bool)
              "pre-integration ordinary tree restored" false
              (Sys.file_exists (root ^ "/remote.txt")))))
    [ false; true ]

let native_publication_reserves_integration_and_recovery_tokens () =
  with_root (fun root ->
      let repository, capability, _, _, operation = recovery_fixture root in
      let recovered =
        recover_native root operation.Op.token ~preview:false ~mode:None
          ~replan:false ~expected:None
      in
      let attempt =
        (Option.get recovered.Native_integrate.recovery_operation.Op.recovery)
          .Op.attempt
      in
      write_file root "note.txt" "selected D\n";
      let shared = selected_share root capability [ [ "note.txt" ] ] in
      let receipt = Option.get shared.Service.Share.publication in
      let before = load repository in
      let store = S.underlying_store repository in
      let add random_bytes =
        L.For_test.record_publication ~random_bytes ~store
          ~intent:(C.Digest.of_raw (String.make 32 'z') |> model)
          ~revision:receipt.L.revision ~source:receipt.L.source
          ~observed:receipt.L.observed
          ~contributed_scope:receipt.L.contributed_scope ~title:receipt.L.title
          (local before)
      in
      List.iter
        (fun reserved ->
          let calls = ref 0 in
          reject "publication reused a reserved integration/recovery token"
            (add (fun _ ->
                 incr calls;
                 Ok (C.Operation_id.to_raw reserved)));
          Alcotest.(check int)
            "cross-kind collisions retry exactly three times" 3 !calls)
        [ operation.Op.token; attempt ];
      let calls = ref 0 in
      let _, fresh =
        add (fun _ ->
            incr calls;
            Ok
              (if !calls = 1 then C.Operation_id.to_raw attempt
               else String.make 16 'z'))
        |> ok Fun.id
      in
      Alcotest.(check int)
        "reserved recovery token skipped before success" 2 !calls;
      Alcotest.(check bool)
        "fresh publication has its own identity" false
        (C.Operation_id.equal fresh.L.operation attempt);
      Alcotest.(check bool)
        "reservation checks did not publish a root" true
        (Raw.Mutable_ref.equal before.S.head (load repository).S.head))

let native_share_provider_is_unlocked_and_revalidated () =
  List.iter
    (fun provider_change ->
      with_root (fun root ->
          let repository, capability, _, _, _ = initialize root in
          write_file root "note.txt" "selected D\n";
          let before = load repository in
          let provider_head = ref before.S.head in
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
                       [ Unix.O_RDWR; Unix.O_CLOEXEC ]
                       0
                   in
                   try
                     Unix.lockf fd Unix.F_TLOCK 0;
                     Unix.close fd;
                     Unix._exit 0
                   with Unix.Unix_error _ -> Unix._exit 1);
                let _, status = Unix.waitpid [] child in
                Alcotest.(check bool)
                  "share provider holds no writer lock" true
                  (status = Unix.WEXITED 0);
                if provider_change = 1 || provider_change = 2 then
                  write_private root "provider-time private E";
                if provider_change = 2 then (
                  Service.save ~root |> service |> ignore;
                  provider_head := (load repository).S.head);
                if provider_change = 3 then
                  Yeokcham_v1_gc.apply ~root
                  |> ok Yeokcham_v1_gc.error_to_string
                  |> ignore;
                T.sign_detached capability ~domain bytes
                |> Result.map_error T.error_to_string)
            |> trust
          in
          let result =
            Service.share_selected ~root ~paths:[ [ "note.txt" ] ] ~update:None
              ~title:None ~dry_run:false ~signing_capability:(Some signer)
          in
          Alcotest.(check int) "one provider invocation" 1 !calls;
          if provider_change = 0 then
            let shared = result |> service in
            Alcotest.(check bool)
              "unchanged inputs publish selected work" true
              (Option.is_some shared.Service.Share.publication)
          else (
            reject "provider-time changes published obsolete capture" result;
            let current = load repository in
            Alcotest.(check bool)
              "provider-time committed state preserved" true
              (Raw.Mutable_ref.equal !provider_head current.S.head);
            Alcotest.(check bool)
              "stale share leaves no publication receipt" true
              (L.publications (local current) = []);
            Alcotest.(check string)
              "provider-time private edits survive"
              (if provider_change = 3 then "private\000bytes\255"
               else "provider-time private E")
              (read_private root);
            selected_share root capability [ [ "note.txt" ] ] |> ignore)))
    [ 0; 1; 2; 3 ]

let () =
  Alcotest.run "Local authenticated branch state"
    [
      ( "state",
        [
          Alcotest.test_case "publication skips integration and recovery tokens"
            `Quick native_publication_reserves_integration_and_recovery_tokens;
          Alcotest.test_case
            "native share provider releases lock and revalidates" `Quick
            native_share_provider_is_unlocked_and_revalidated;
          Alcotest.test_case
            "native recovery root CAS faults preserve intent and cleanup" `Quick
            native_recovery_root_cas_faults_and_cleanup_are_idempotent;
          Alcotest.test_case "native recovery cannot unaccept committed history"
            `Quick
            native_recovery_can_cancel_materialized_but_not_committed_acceptance;
          Alcotest.test_case
            "native recovery restores safety and preserves observations" `Quick
            native_recovery_restores_safety_without_acceptance_or_losing_observations;
          Alcotest.test_case
            "native recovery resumes file and metadata boundaries" `Quick
            native_recovery_resumes_file_and_metadata_boundaries;
          Alcotest.test_case
            "native recovery Materialized retry preserves later edits" `Quick
            native_recovery_materialized_retry_preserves_later_edits;
          Alcotest.test_case
            "native recovery replans with immutable prior observations" `Quick
            native_recovery_replans_without_erasing_prior_observations;
          Alcotest.test_case
            "released unaccepted proposal collects without losing operation"
            `Quick
            native_recovery_released_proposal_can_be_collected_and_reopened;
          Alcotest.test_case
            "recovery decoding rejects malformed and colliding intents" `Quick
            native_recovery_decode_rejects_malformed_intents_and_history;
          Alcotest.test_case
            "copy-out journal owns released recovery observation" `Quick
            native_recovery_copyout_resume_owns_released_observation;
          Alcotest.test_case
            "native recovery stale/missing safety refuses before writes" `Quick
            native_recovery_stale_preview_and_missing_safety_refuse_before_writes;
          Alcotest.test_case
            "native Materialized fact verifies untouched target paths" `Quick
            native_materialization_verifies_untouched_target_paths;
          Alcotest.test_case
            "native integration provider never holds writer lock and \
             revalidates"
            `Quick
            native_integration_signer_runs_without_writer_lock_and_revalidates;
          Alcotest.test_case
            "native integration entropy/collision refusal is bounded" `Quick
            native_integration_entropy_and_collision_refuse_before_files;
          Alcotest.test_case
            "native integration CAS faults preserve exactly one acceptance"
            `Quick native_integration_metadata_cas_faults_are_idempotent;
          Alcotest.test_case
            "native integration root refuses erasure and partial capture" `Quick
            native_integration_root_refuses_operation_erasure_and_partial_capture;
          Alcotest.test_case
            "native integration preserves private work and idempotent \
             acceptance"
            `Quick native_integration_preserves_private_work_and_retries;
          Alcotest.test_case
            "native integration resumes real file/root boundaries" `Quick
            native_integration_resumes_real_file_and_root_boundaries;
          Alcotest.test_case
            "native integration Materialized retry preserves external \
             edits/receipts"
            `Quick
            native_integration_materialized_retry_preserves_external_edits_and_receipts;
          Alcotest.test_case
            "native integration pauses on unexpected Applying edit" `Quick
            native_integration_pauses_on_external_edit_during_application;
          Alcotest.test_case
            "native integration stale plan refuses before reservation" `Quick
            native_integration_stale_plan_refuses_before_reservation;
          Alcotest.test_case
            "equal-content causal heads require explicit full reconciliation"
            `Quick
            equal_content_causal_heads_require_explicit_full_reconciliation;
          Alcotest.test_case
            "retained integration proposal survives restart/GC then releases \
             roots"
            `Quick integration_proposal_survives_restart_and_gc_until_release;
          Alcotest.test_case
            "proposal preflights complete contents before retention" `Quick
            integration_proposal_rejects_missing_contents_before_retention;
          Alcotest.test_case "corrupt proposal refuses replacement and GC"
            `Quick integration_proposal_corruption_blocks_gc_without_replacement;
          Alcotest.test_case
            "integration plan decodes and revalidates exact observation/cursor"
            `Quick integration_plan_decode_and_current_revalidation;
          Alcotest.test_case
            "integration plan refuses malformed scope/features/policy" `Quick
            integration_plan_rejects_malformed_control_and_scope;
          Alcotest.test_case
            "integration plan revalidation rejects false private acceptance"
            `Quick integration_plan_rejects_false_outputs_after_reference_decode;
          Alcotest.test_case
            "integration plan binds separate accepted/private outputs" `Quick
            integration_plan_binds_two_outputs_without_publication;
          Alcotest.test_case
            "integration plan binds selected heads and tolerates unrelated \
             receipt"
            `Quick
            integration_plan_ignores_unrelated_receipt_and_binds_selected_heads;
          Alcotest.test_case
            "integration plan exposes private conflicts without mutation" `Quick
            integration_plan_exposes_workspace_conflict_without_files_or_history;
          Alcotest.test_case
            "preservation accepts D and retains private E and X" `Quick
            preservation_accepts_D_and_keeps_private_E_and_X;
          Alcotest.test_case
            "preservation refuses nonancestor publication inference" `Quick
            preservation_rejects_missing_lineage_and_overlap;
          Alcotest.test_case
            "preservation does not overlay already accepted older work" `Quick
            preservation_does_not_backdate_already_accepted_work;
          Alcotest.test_case
            "native share captures only selected public work and retries" `Quick
            native_share_captures_only_selected_public_work;
          Alcotest.test_case
            "native share updates are explicit immutable revisions" `Quick
            native_share_updates_are_explicit_and_immutable;
          Alcotest.test_case
            "native share survives root interruption and lost response" `Quick
            native_share_recovers_atomic_root_and_lost_ack;
          Alcotest.test_case
            "native share refuses excluded and incomplete captures" `Quick
            native_share_refuses_excluded_paths_and_incomplete_capture;
          Alcotest.test_case
            "native share uses captured rules for absent public paths" `Quick
            native_share_uses_observed_rules_for_missing_public_paths;
          Alcotest.test_case
            "publication receipts commit and retry with exact identity" `Quick
            publication_receipts_are_atomic_and_retryable;
          Alcotest.test_case
            "publication refuses unwitnessed and foreign sources" `Quick
            publication_rejects_unwitnessed_or_foreign_sources;
          Alcotest.test_case
            "publication witnesses survive private blob collection" `Quick
            publication_witness_survives_private_content_collection;
          Alcotest.test_case
            "publication updates witness only newly selected work" `Quick
            publication_update_witnesses_only_newly_selected_edits;
          Alcotest.test_case
            "snapshot selection reserves provisional target with atomic root"
            `Quick snapshot_selection_reserves_provisional_target_atomically;
          Alcotest.test_case "branch plans reject changed inputs" `Quick
            branch_plan_rejects_changed_inputs;
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
          Alcotest.test_case
            "first received-branch selection preserves source private work"
            `Quick received_branch_selection_preserves_private_work;
          Alcotest.test_case
            "first received-branch selection resumes file and metadata \
             boundaries"
            `Quick
            received_branch_switch_resumes_mutation_and_metadata_boundaries;
          Alcotest.test_case
            "first received-branch selection refuses obstructions and stale \
             plans"
            `Quick
            received_branch_selection_refuses_obstructions_and_stale_preview;
          Alcotest.test_case
            "saved private branch selection precedes explicit shared catch-up"
            `Quick
            saved_private_branch_can_be_selected_before_catching_up_shared_head;
          Alcotest.test_case
            "first selection resumes original basis across different or \
             equal-content heads"
            `Quick
            interrupted_first_selection_keeps_exact_basis_across_new_shared_heads;
          Alcotest.test_case
            "shared private-position staging is verified and idempotent" `Quick
            registered_shared_position_is_pure_idempotent_and_verified;
          Alcotest.test_case
            "first shared selection keeps GC roots and later external edits"
            `Quick first_shared_selection_keeps_gc_roots_and_late_external_edits;
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
          Alcotest.test_case "concurrent branch names refuse local selection"
            `Quick divergent_names_are_retained_and_refused;
          Alcotest.test_case
            "historical verification differs from new admission" `Quick
            historical_load_and_current_admission;
          Alcotest.test_case
            "actual signed shared records, nonempty acceptance and fork" `Quick
            verified_shared_records_and_nonempty_fork;
          Alcotest.test_case
            "valid signature cannot bypass accepted-result proof" `Quick
            signed_false_acceptance_cannot_enter_local_state;
          Alcotest.test_case "unselected branch work survives compaction and GC"
            `Quick branch_work_is_a_retention_root;
          Alcotest.test_case
            "branch signing releases writer and refuses provider-time changes"
            `Quick branch_creation_signing_releases_writer_and_revalidates;
          Alcotest.test_case
            "read-only metadata remains available without shared chunks or \
             write authority"
            `Quick
            metadata_inspection_survives_missing_shared_chunks_without_authorizing_writes;
          Alcotest.test_case
            "resolved text and large opaque acceptance bind exact proof and \
             retry"
            `Quick
            resolved_native_integration_proves_exact_acceptance_and_retries;
          Alcotest.test_case
            "resolved integration resumes actual file and root facts" `Quick
            resolved_native_integration_resumes_durable_facts;
          Alcotest.test_case
            "unaccepted resolution replacement survives actual GC" `Quick
            unaccepted_resolution_replacement_survives_gc;
        ] );
    ]
