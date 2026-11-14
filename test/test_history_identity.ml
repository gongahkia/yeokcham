module H = Yeokcham_v1_undo
module M = Yeokcham_v1_model
module C = M.Core
module E = Yeokcham_encoding
module S = Yeokcham_v1_store
module Raw = Yeokcham_store
module Envelope = Yeokcham_envelope

let ok render = function
  | Ok value -> value
  | Error e -> Alcotest.fail (render e)

let reject label = function Error _ -> () | Ok _ -> Alcotest.fail label
let snapshot s = M.Snapshot_id.of_string s |> ok M.error_to_string
let draft = M.Draft_id.of_string "work" |> ok M.error_to_string

let workspace byte =
  C.Workspace_id.of_raw (String.make 16 byte) |> ok C.error_to_string

let seed () =
  H.seed ~snapshot:(snapshot "A") ~draft |> fun h ->
  H.bind_workspace h (workspace 'a') |> ok Fun.id

let record h s =
  H.record h ~snapshot:(snapshot s) ~draft ~created_at:1L |> ok Fun.id

let array a = E.array a |> ok E.construction_error_to_string
let text a = E.text a |> ok E.construction_error_to_string

let namespaced_positions () =
  let a = seed () in
  let first = H.identity a (H.current a) |> ok Fun.id in
  let h = record (record a "B") "A" in
  let third = H.identity h (H.current h) |> ok Fun.id in
  Alcotest.(check bool)
    "content equality does not merge position identities" false
    (C.History_id.equal first third);
  let h = H.select h 0L |> ok Fun.id |> fun h -> record h "D" in
  let reopened = H.encode h |> ok Fun.id |> H.decode |> ok Fun.id in
  Alcotest.(check string)
    "namespace survives encoding"
    (C.Workspace_id.to_hex (workspace 'a'))
    (C.Workspace_id.to_hex (Option.get (H.workspace reopened)));
  Alcotest.(check (option int64))
    "counter does not follow cursor backwards" (Some 4L)
    (H.next_sequence reopened);
  Alcotest.(check (list int64))
    "alternates retained" [ 1L; 3L ]
    (H.children reopened 0L |> List.map (fun n -> n.H.id));
  Alcotest.(check bool)
    "original identity survives navigation" true
    (C.History_id.equal first
       (H.identity reopened (H.find reopened 0L |> ok Fun.id) |> ok Fun.id));
  H.validate_update ~previous:a reopened |> ok Fun.id |> ignore;
  reject "namespace reassignment accepted"
    (H.bind_workspace reopened (workspace 'b'));
  reject "history deletion accepted" (H.validate_update ~previous:reopened a)

let canonical_history ~sequence ~next ~snapshot =
  array
    [
      E.integer 2L;
      E.bytes (C.Workspace_id.to_raw (workspace 'a'));
      next;
      E.integer sequence;
      array
        [
          array
            [
              E.integer sequence;
              E.null;
              text snapshot;
              text "work";
              E.integer 0L;
            ];
        ];
    ]
  |> E.encode

let golden_schema () =
  let bytes = H.encode (seed ()) |> ok Fun.id in
  let path = "golden/local/history-v2.cbor.hex" in
  let path = if Sys.file_exists path then path else "test/" ^ path in
  Alcotest.(check string)
    "ordered history-v2 schema bytes"
    (Yeokcham_testkit.Golden_fixture.refresh_lower_hex_file path bytes
    |> ok Fun.id)
    bytes

let counters_and_collisions () =
  let at_end =
    canonical_history ~sequence:Int64.max_int ~next:E.null ~snapshot:"A"
    |> H.decode |> ok Fun.id
  in
  reject "exhaustion wrapped sequence"
    (H.record at_end ~snapshot:(snapshot "B") ~draft ~created_at:1L);
  let repeated =
    H.record at_end ~snapshot:(snapshot "A") ~draft ~created_at:1L |> ok Fun.id
  in
  Alcotest.(check string)
    "identical retry at exhaustion remains unchanged"
    (H.encode at_end |> ok Fun.id)
    (H.encode repeated |> ok Fun.id);
  reject "counter rollback accepted"
    (H.decode
       (canonical_history ~sequence:0L ~next:(E.integer 0L) ~snapshot:"A"));
  reject "counter exhaustion fabricated"
    (H.decode (canonical_history ~sequence:0L ~next:E.null ~snapshot:"A"));
  let h = seed () in
  let other = { (H.current h) with H.snapshot = snapshot "B" } in
  reject "same ID with different content accepted" (H.identity h other);
  let changed =
    canonical_history ~sequence:0L ~next:(E.integer 1L) ~snapshot:"B"
    |> H.decode |> ok Fun.id
  in
  reject "rewritten ancestor accepted" (H.validate_update ~previous:h changed)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_root f =
  let root = Filename.temp_file "yeokcham-history-id-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let project () =
  M.init
    ~creator:(M.Device_id.of_string "device" |> ok M.error_to_string)
    ~username:(M.Username.of_string "alice" |> ok M.error_to_string)
    ~initial_snapshot:(snapshot "A") ~initial_draft:draft ~title:"test"

let load root =
  S.open_repository ~root |> ok S.error_to_string |> S.load
  |> ok S.error_to_string

let namespace loaded =
  H.workspace loaded.S.history |> Option.get |> C.Workspace_id.to_hex

let durable_restart_and_retry () =
  with_root (fun root ->
      with_root (fun other ->
          let repository =
            S.init ~root ~project:(project ()) |> ok S.error_to_string
          in
          let initial = S.load repository |> ok S.error_to_string in
          let other =
            S.init ~root:other ~project:(project ())
            |> ok S.error_to_string |> S.load |> ok S.error_to_string
          in
          Alcotest.(check bool)
            "separate workspaces get different namespaces" false
            (namespace initial = namespace other);
          let child = Unix.fork () in
          (if child = 0 then
             try
               let reopened = S.open_repository ~root |> ok S.error_to_string in
               let before = S.load reopened |> ok S.error_to_string in
               S.save reopened ~expected:before.S.head
                 ~project:
                   (M.checkpoint before.S.project ~snapshot:(snapshot "B"))
               |> ok S.error_to_string |> ignore;
               Unix._exit 0
             with _ -> Unix._exit 1);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "fresh writer process succeeded" true (status = Unix.WEXITED 0);
          let saved = load root in
          Alcotest.(check string)
            "same workspace after writer restart" (namespace initial)
            (namespace saved);
          Alcotest.(check int64)
            "next history position" 1L (H.current saved.S.history).H.id;
          Alcotest.(check (option int64))
            "durable counter" (Some 2L)
            (H.next_sequence saved.S.history);
          reject "stale concurrent writer accepted"
            (S.save repository ~expected:initial.S.head
               ~project:
                 (M.checkpoint initial.S.project ~snapshot:(snapshot "C")));
          let repeated =
            S.save repository ~expected:saved.S.head ~project:saved.S.project
            |> ok S.error_to_string
          in
          Alcotest.(check int)
            "identical content retry does not append" 2
            (List.length (H.nodes repeated.S.history));
          Alcotest.(check bool)
            "stale attempt did not alter durable nodes" true
            (Raw.Stored_object_id.equal saved.S.object_id repeated.S.object_id);
          Alcotest.(check (option int64))
            "failed attempt did not consume durable allocation" (Some 2L)
            (H.next_sequence repeated.S.history)))

let[@warning "-4"] replace_history_fixture repository loaded history =
  let raw = S.underlying_store repository in
  let object_ = Raw.get raw loaded.S.object_id |> ok Raw.error_to_string in
  let payload =
    match Envelope.payload object_ with
    | E.Array [ tag; version; inner; E.Bytes _ ] ->
        array [ tag; version; inner; E.bytes history ]
    | _ -> Alcotest.fail "expected wrapped state"
  in
  let envelope =
    Envelope.create ~object_type:Envelope.V1_project_state
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> ok Envelope.creation_error_to_string
  in
  let target = Raw.put raw envelope |> ok Raw.error_to_string in
  Raw.compare_and_swap_ref raw ~name:S.state_head_name
    ~expected:(Some loaded.S.head) ~target:(Some target)
  |> ok Raw.error_to_string |> ignore

let durable_exhaustion_and_collision () =
  with_root (fun root ->
      let repository =
        S.init ~root ~project:(project ()) |> ok S.error_to_string
      in
      let initial = S.load repository |> ok S.error_to_string in
      let original_workspace = Option.get (H.workspace initial.S.history) in
      let changed =
        canonical_history ~sequence:0L ~next:(E.integer 1L) ~snapshot:"B"
        |> H.decode |> ok Fun.id
      in
      (* the fixture namespace differs as well as the payload; both must refuse *)
      reject "candidate replaced namespace"
        (S.save ~history:changed repository ~expected:initial.S.head
           ~project:(M.checkpoint initial.S.project ~snapshot:(snapshot "B")));
      let changed =
        H.seed ~snapshot:(snapshot "B") ~draft |> fun h ->
        H.bind_workspace h original_workspace |> ok Fun.id
      in
      reject "candidate rewrote history position"
        (S.save ~history:changed repository ~expected:initial.S.head
           ~project:(M.checkpoint initial.S.project ~snapshot:(snapshot "B")));
      let full =
        array
          [
            E.integer 2L;
            E.bytes (C.Workspace_id.to_raw original_workspace);
            E.null;
            E.integer Int64.max_int;
            array
              [
                array
                  [
                    E.integer Int64.max_int;
                    E.null;
                    text "A";
                    text "work";
                    E.integer 0L;
                  ];
              ];
          ]
        |> E.encode
      in
      replace_history_fixture repository initial full;
      let exhausted = load root in
      reject "store published after allocation exhaustion"
        (S.save repository ~expected:exhausted.S.head
           ~project:(M.checkpoint exhausted.S.project ~snapshot:(snapshot "B")));
      let after = load root in
      Alcotest.(check bool)
        "exhaustion retained atomic head" true
        (Raw.Mutable_ref.equal exhausted.S.head after.S.head))

let interrupted_root_publication () =
  List.iter
    (fun after_publish ->
      with_root (fun root ->
          let repository =
            S.init ~root ~project:(project ()) |> ok S.error_to_string
          in
          let before = S.load repository |> ok S.error_to_string in
          let project =
            M.checkpoint before.S.project ~snapshot:(snapshot "B")
          in
          let child = Unix.fork () in
          if child = 0 then (
            let stop () = Unix._exit 77 in
            S.For_test.save repository ~expected:before.S.head ~project
              ~before_publish:(if after_publish then fun () -> () else stop)
              ~after_publish:(if after_publish then stop else fun () -> ())
            |> ignore;
            Unix._exit 1);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "child stopped at actual publication boundary" true
            (status = Unix.WEXITED 77);
          let current = load root in
          Alcotest.(check string)
            "namespace retained through crash" (namespace before)
            (namespace current);
          Alcotest.(check int64)
            "cursor and counter publish together"
            (if after_publish then 1L else 0L)
            (H.current current.S.history).H.id;
          Alcotest.(check (option int64))
            "allocation shares cursor root"
            (Some (if after_publish then 2L else 1L))
            (H.next_sequence current.S.history);
          let retried =
            S.save repository ~expected:current.S.head ~project
            |> ok S.error_to_string
          in
          Alcotest.(check int64)
            "retry reaches the same next node" 1L
            (H.current retried.S.history).H.id;
          Alcotest.(check int)
            "retry does not append twice" 2
            (List.length (H.nodes retried.S.history));
          Alcotest.(check (option int64))
            "retry does not reserve twice" (Some 2L)
            (H.next_sequence retried.S.history)))
    [ false; true ]

let randomized_restarts =
  QCheck.Test.make ~count:150
    ~name:"save/navigation/reopen preserves identities and allocation"
    QCheck.(list_size (Gen.int_bound 60) (pair bool (int_range 0 5)))
    (fun operations ->
      let start = seed () in
      let final =
        List.fold_left
          (fun h (navigate, n) ->
            let before = h in
            let h =
              if navigate then
                let nodes = H.nodes h in
                H.select h (List.nth nodes (n mod List.length nodes)).H.id
                |> ok Fun.id
              else record h (string_of_int n)
            in
            let reopened = H.encode h |> ok Fun.id |> H.decode |> ok Fun.id in
            H.validate_update ~previous:before reopened |> ok Fun.id |> ignore;
            reopened)
          start operations
      in
      let nodes = H.nodes final in
      H.next_sequence final = Some (Int64.of_int (List.length nodes))
      && List.for_all
           (fun node ->
             C.History_id.sequence (H.identity final node |> ok Fun.id)
             = node.H.id)
           nodes)

let () =
  Alcotest.run "Durable history identities"
    [
      ( "state",
        [
          Alcotest.test_case "history schema golden bytes" `Quick golden_schema;
          Alcotest.test_case "position, namespace and alternate continuations"
            `Quick namespaced_positions;
          Alcotest.test_case "counter validation, exhaustion and collisions"
            `Quick counters_and_collisions;
          Alcotest.test_case "fresh writer process, retry and stale writer"
            `Quick durable_restart_and_retry;
          Alcotest.test_case "store collision and exhaustion are atomic" `Quick
            durable_exhaustion_and_collision;
          Alcotest.test_case "crash before and after root CAS" `Quick
            interrupted_root_publication;
          QCheck_alcotest.to_alcotest randomized_restarts;
        ] );
    ]
