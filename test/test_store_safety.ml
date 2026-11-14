module S = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module J = Yeokcham_v1_restore_journal
module P = Yeokcham_v1_restore_proof
module M = Yeokcham_v1_model
module Service = Yeokcham_v1_local_service
module Gc = Yeokcham_v1_gc

let ok render = function Ok x -> x | Error e -> Alcotest.fail (render e)
let reject name = function Error _ -> () | Ok _ -> Alcotest.fail name

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_root f =
  let root = Filename.temp_file "yeokcham-store-safety-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () -> f root (S.init ~root |> ok S.error_to_string))

let write path bytes =
  Out_channel.with_open_bin path (fun out -> output_string out bytes)

let read path = In_channel.with_open_bin path In_channel.input_all
let snapshot name = M.Snapshot_id.of_string name |> ok M.error_to_string
let operation = String.make 64 'b'

let journal () =
  J.make_prepared ~operation_id:operation ~safety:(snapshot "safety")
    ~target:(snapshot "target")
  |> ok J.error_to_string

let proof () =
  P.make ~operation_id:operation ~safety:(snapshot "safety")
    ~target:(snapshot "target")
  |> ok P.error_to_string

let after_link = function
  | S.Final_linked | S.Directory_synced -> true
  | S.Temporary_created | S.Temporary_written | S.Temporary_synced -> false

let staged_publication_crashes () =
  List.iter
    (fun is_proof ->
      List.iter
        (fun boundary ->
          with_root (fun root _ ->
              let directory =
                Filename.concat root
                  (if is_proof then ".yeokcham/restore-proofs"
                   else ".yeokcham/journal")
              in
              if is_proof then Unix.mkdir directory 0o700;
              let filename =
                if is_proof then "v1-restore-proof-" ^ operation ^ ".cbor"
                else "v1-restore-" ^ operation ^ "-0.cbor"
              in
              let path = Filename.concat directory filename in
              let bytes =
                if is_proof then P.encode (proof ()) |> ok P.error_to_string
                else J.encode (journal ()) |> ok J.error_to_string
              in
              let child = Unix.fork () in
              if child = 0 then (
                let observe stage temporary =
                  if stage = boundary then (
                    if stage = S.Temporary_created then
                      write temporary "partially written temporary";
                    Unix._exit 73)
                in
                ignore (S.For_test.publish_file ~observe ~path ~bytes);
                Unix._exit 74);
              let _, status = Unix.waitpid [] child in
              Alcotest.(check bool)
                "terminated at actual publication boundary" true
                (status = Unix.WEXITED 73);
              let count =
                if is_proof then
                  P.scan ~root |> ok P.error_to_string |> List.length
                else J.scan ~root |> ok J.error_to_string |> List.length
              in
              Alcotest.(check int)
                "reader sees no partial final record"
                (if after_link boundary then 1 else 0)
                count;
              if Sys.file_exists path then
                Alcotest.(check string)
                  "published record complete" bytes (read path);
              if is_proof then (
                P.append ~root (proof ()) |> ok P.error_to_string;
                P.append ~root (proof ()) |> ok P.error_to_string)
              else (
                J.append ~root (journal ()) |> ok J.error_to_string;
                J.append ~root (journal ()) |> ok J.error_to_string);
              Alcotest.(check string)
                "identical retry after restart" bytes (read path)))
        [
          S.Temporary_created;
          S.Temporary_written;
          S.Temporary_synced;
          S.Final_linked;
          S.Directory_synced;
        ])
    [ false; true ]

let publication_collision_is_not_replaced () =
  with_root (fun root _ ->
      let path = Filename.concat root "existing" in
      write path "external original";
      Alcotest.(check bool)
        "existing path reported" false
        (S.publish_file_create_only ~path ~bytes:"replacement"
        |> ok S.error_to_string);
      Alcotest.(check string)
        "original contents retained" "external original" (read path))

let head_cas_recovers_killed_lock_owner () =
  List.iter
    (fun boundary ->
      with_root (fun _ repository ->
          let a =
            Snapshot.Content.store repository "A"
            |> ok Snapshot.error_to_string
            |> Snapshot.Content.stored_object_id
          in
          let b =
            Snapshot.Content.store repository "B"
            |> ok Snapshot.error_to_string
            |> Snapshot.Content.stored_object_id
          in
          let old =
            S.compare_and_swap_ref repository ~name:"test-head" ~expected:None
              ~target:(Some a)
            |> ok S.error_to_string
          in
          let child = Unix.fork () in
          if child = 0 then (
            ignore
              (S.For_test.compare_and_swap_ref
                 ~observe:(fun seen -> if seen = boundary then Unix._exit 73)
                 repository ~name:"test-head" ~expected:(Some old)
                 ~target:(Some b));
            Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "terminated while writer lock held" true (status = Unix.WEXITED 73);
          let current =
            S.read_ref repository ~name:"test-head"
            |> ok S.error_to_string |> Option.get
          in
          let expected = if boundary = S.Before_ref_replace then a else b in
          Alcotest.(check bool)
            "head is one complete identity" true
            (S.Stored_object_id.equal expected
               (S.Mutable_ref.target current |> Option.get));
          let retried =
            S.compare_and_swap_ref repository ~name:"test-head"
              ~expected:(Some current) ~target:(Some b)
            |> ok S.error_to_string
          in
          Alcotest.(check bool)
            "dead lock owner recovered without deleting live data" true
            (S.Stored_object_id.equal b
               (S.Mutable_ref.target retried |> Option.get))))
    [ S.Before_ref_replace; S.After_ref_replace; S.After_ref_sync ]

let unknown_and_live_locks_are_retained () =
  with_root (fun root repository ->
      let path = Filename.concat root ".yeokcham/locks/guard.lock" in
      List.iter
        (fun bytes ->
          write path bytes;
          reject "discarded an unknown/live lock"
            (S.with_lock repository ~name:"guard" ~on_error:Fun.id (fun () ->
                 Ok ()));
          Alcotest.(check string) "lock evidence unchanged" bytes (read path))
        [
          "unknown lock bytes";
          Printf.sprintf "yeokcham-mutable-ref-lock-v1\npid=%d\n"
            (Unix.getpid ());
        ])

let concurrent_writer_and_exception_cleanup () =
  with_root (fun _ repository ->
      S.with_lock repository ~name:"guard" ~on_error:Fun.id (fun () ->
          let child = Unix.fork () in
          (if child = 0 then
             match
               S.with_lock repository ~name:"guard" ~on_error:Fun.id (fun () ->
                   Ok ())
             with
             | Error _ -> Unix._exit 73
             | Ok () -> Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "other process cannot enter writer" true (status = Unix.WEXITED 73);
          Ok ())
      |> ok S.error_to_string;
      (try
         ignore
           (S.with_lock repository ~name:"guard" ~on_error:Fun.id (fun () ->
                raise Exit))
       with Exit -> ());
      S.with_lock repository ~name:"guard" ~on_error:Fun.id (fun () -> Ok ())
      |> ok S.error_to_string)

let gc_cannot_collect_active_capture () =
  let root = Filename.temp_file "yeokcham-gc-active-capture-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () ->
      let file = Filename.concat root "note" in
      write file "A";
      Service.init ~root
        ~creator:(M.Device_id.of_string "device" |> ok M.error_to_string)
        ~username:(M.Username.of_string "alice" |> ok M.error_to_string)
        ~initial_draft:(M.Draft_id.of_string "work" |> ok M.error_to_string)
        ~title:"work"
      |> ok Service.error_to_string |> ignore;
      write file "B";
      Service.save ~root |> ok Service.error_to_string |> ignore;
      write file "C unsaved";
      let observed = ref false in
      let observe stage =
        if stage = Service.Before_safety_publish then (
          observed := true;
          let child = Unix.fork () in
          (if child = 0 then
             match Gc.apply ~root with
             | Error _ -> Unix._exit 73
             | Ok _ -> Unix._exit 74);
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "GC cannot quarantine an active capture" true
            (status = Unix.WEXITED 73))
      in
      Service.For_test.navigate_history ~observe ~root ~direction:Service.Undo
        ~dry_run:false
      |> ok Service.error_to_string |> ignore;
      Alcotest.(check bool)
        "tested before safety root publication" true !observed;
      Alcotest.(check string) "navigation remains exact" "B" (read file);
      Gc.plan ~root |> ok Gc.error_to_string |> ignore)

let oversized_records_refuse () =
  reject "oversized journal" (J.decode (String.make 8193 '\000'));
  reject "oversized proof" (P.decode (String.make 8193 '\000'))

let () =
  Alcotest.run "Durable local metadata safety"
    [
      ( "durability",
        List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [
            ( "journal/proof publication at ten crash boundaries",
              staged_publication_crashes );
            ( "create-only publication preserves collisions",
              publication_collision_is_not_replaced );
            ( "root CAS resumes after killed writer at three boundaries",
              head_cas_recovers_killed_lock_owner );
            ( "unknown and live lock evidence is retained",
              unknown_and_live_locks_are_retained );
            ( "writer exclusion and exception cleanup",
              concurrent_writer_and_exception_cleanup );
            ( "GC and active safety capture share writer boundary",
              gc_cannot_collect_active_capture );
            ("bounded journal and proof decoders", oversized_records_refuse);
          ] );
    ]
