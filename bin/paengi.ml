module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Compaction = Paengi_compaction
module Capsule = Paengi_capsule
module Capsule_store = Paengi_capsule_store

let now () = Int64.of_float (Unix.gettimeofday ())

let fail render error =
  prerr_endline (render error);
  exit 2

let checkpoint_id value =
  match Store.Stored_object_id.of_hex value with
  | Ok identity -> Scratch.Checkpoint_id.of_stored_object_id identity
  | Error error -> fail Store.Stored_object_id.parse_error_to_string error

let capsule_id value =
  match Paengi_id.Capsule_id.of_hex value with
  | Ok identity -> identity
  | Error error -> fail Paengi_id.parse_error_to_string error

let print_checkpoint checkpoint =
  print_endline
    (Store.Stored_object_id.to_hex
       (Scratch.Checkpoint_id.stored_object_id
          (Scratch.Checkpoint.id checkpoint)))

let render_path path = String.concat "/" path

let render_operation = function
  | Scratch.Create { path; _ } -> "create " ^ render_path path
  | Scratch.Delete { path; _ } -> "delete " ^ render_path path
  | Scratch.Modify_content { path; _ } -> "modify " ^ render_path path
  | Scratch.Change_mode { path; _ } -> "mode " ^ render_path path
  | Scratch.Move { source; destination; _ } ->
      "move " ^ render_path source ^ " -> " ^ render_path destination

let render_capsule_operation = function
  | Capsule.Exact_file_transition transition ->
      "exact " ^ render_path transition.Capsule.transition_path
  | Capsule.Text_edit edit -> "text " ^ render_path edit.Capsule.edit_path
  | Capsule.Move { source; destination; _ } ->
      "move " ^ render_path source ^ " -> " ^ render_path destination
  | Capsule.Mode_change { path; _ } -> "mode " ^ render_path path

let parse_root arguments =
  let rec loop root reversed = function
    | "--root" :: path :: rest -> loop path reversed rest
    | value :: rest -> loop root (value :: reversed) rest
    | [] -> (root, List.rev reversed)
  in
  loop (Sys.getcwd ()) [] arguments

let open_scratch root =
  let store =
    Store.open_repository ~root |> Result.map_error Store.error_to_string
  in
  store |> Result.map (fun store -> (store, Scratch.open_repository store))

let initialise root =
  let store = Store.init ~root |> Result.map_error Store.error_to_string in
  match store with
  | Error error -> fail Fun.id error
  | Ok store -> (
      let snapshot =
        Snapshot.scan ~root ~store |> Result.map_error Snapshot.error_to_string
      in
      match snapshot with
      | Error error -> fail Fun.id error
      | Ok (snapshot, _) -> (
          let scratch = Scratch.open_repository store in
          match
            Scratch.create_initial scratch ~snapshot ~created_at:(now ())
          with
          | Ok checkpoint -> print_checkpoint checkpoint
          | Error error -> fail Scratch.error_to_string error))

let checkpoint root =
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (store, scratch) -> (
      let snapshot =
        Snapshot.scan ~root ~store |> Result.map_error Snapshot.error_to_string
      in
      match snapshot with
      | Error error -> fail Fun.id error
      | Ok (snapshot, _) -> (
          let timestamp = now () in
          match
            Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
              ~observed_at:timestamp ~created_at:timestamp
          with
          | Ok (Scratch.Created checkpoint) -> print_checkpoint checkpoint
          | Ok (Scratch.Unchanged checkpoint) ->
              print_endline
                ("unchanged "
                ^ Store.Stored_object_id.to_hex
                    (Scratch.Checkpoint_id.stored_object_id
                       (Scratch.Checkpoint.id checkpoint)))
          | Error error -> fail Scratch.error_to_string error))

let timeline root arguments =
  let limit =
    match arguments with
    | [] -> 32
    | [ "--limit"; value ] -> (
        match int_of_string_opt value with
        | Some value -> value
        | None -> exit 2)
    | _ -> exit 2
  in
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (_, scratch) -> (
      match Scratch.timeline scratch ~limit () with
      | Error error -> fail Scratch.error_to_string error
      | Ok entries ->
          List.iter
            (fun entry ->
              let checkpoint = entry.Scratch.checkpoint in
              let retention =
                entry.Scratch.effective_retention
                |> List.map Scratch.retention_reason_to_string
                |> String.concat ","
              in
              Printf.printf "%d %s %Ld %s\n" entry.Scratch.depth
                (Store.Stored_object_id.to_hex
                   (Scratch.Checkpoint_id.stored_object_id
                      entry.Scratch.logical_id))
                (Scratch.Checkpoint.created_at checkpoint)
                retention)
            entries)

let restore root arguments =
  let dry_run, target =
    match arguments with
    | [ "--dry-run"; target ] -> (true, target)
    | [ target ] -> (false, target)
    | _ -> exit 2
  in
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (_, scratch) -> (
      let target = checkpoint_id target in
      if dry_run then
        match Scratch.Restore.dry_run scratch ~root ~target with
        | Ok plan ->
            Scratch.Restore.actions plan
            |> List.iter (fun action -> print_endline (render_operation action));
            Printf.printf "%d actions\n"
              (List.length (Scratch.Restore.actions plan))
        | Error error -> fail Scratch.error_to_string error
      else
        let timestamp = now () in
        match
          Scratch.Restore.restore scratch ~root ~target ~observed_at:timestamp
            ~created_at:timestamp
        with
        | Ok None -> print_endline "restored"
        | Ok (Some safety) ->
            Printf.printf "restored safety=%s\n"
              (Store.Stored_object_id.to_hex
                 (Scratch.Checkpoint_id.stored_object_id safety))
        | Error error -> fail Scratch.error_to_string error)

let change_pin root arguments pin =
  match arguments with
  | [ checkpoint ] -> (
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (_, scratch) -> (
          let checkpoint = checkpoint_id checkpoint in
          let result =
            if pin then Scratch.pin scratch checkpoint ~changed_at:(now ())
            else Scratch.unpin scratch checkpoint ~changed_at:(now ())
          in
          match result with
          | Ok () -> print_endline "ok"
          | Error error -> fail Scratch.error_to_string error))
  | _ -> exit 2

let parse_int64 value =
  try Some (Int64.of_string value) with Failure _ -> None

let compact root arguments =
  let default = Compaction.Policy.default in
  let rec parse mode explain recent periodic budget timestamp = function
    | [] ->
        let policy =
          Compaction.Policy.create ~recent_window_seconds:recent
            ~periodic_interval_seconds:periodic ~storage_budget_bytes:budget
          |> Result.map_error Compaction.Policy.error_to_string
        in
        (mode, explain, policy, Option.value timestamp ~default:(now ()))
    | "--dry-run" :: rest ->
        parse `Dry_run explain recent periodic budget timestamp rest
    | "--resume" :: rest ->
        parse `Resume explain recent periodic budget timestamp rest
    | "--prune" :: rest ->
        parse `Prune explain recent periodic budget timestamp rest
    | "--explain" :: rest ->
        parse mode true recent periodic budget timestamp rest
    | "--recent-seconds" :: value :: rest -> (
        match parse_int64 value with
        | Some value -> parse mode explain value periodic budget timestamp rest
        | None -> exit 2)
    | "--periodic-seconds" :: value :: rest -> (
        match parse_int64 value with
        | Some value -> parse mode explain recent value budget timestamp rest
        | None -> exit 2)
    | "--storage-budget-bytes" :: value :: rest -> (
        match parse_int64 value with
        | Some value ->
            parse mode explain recent periodic (Some value) timestamp rest
        | None -> exit 2)
    | "--now-unix-seconds" :: value :: rest -> (
        match parse_int64 value with
        | Some value ->
            parse mode explain recent periodic budget (Some value) rest
        | None -> exit 2)
    | _ -> exit 2
  in
  let mode, explain, policy, timestamp =
    parse `Activate false
      (Compaction.Policy.recent_window_seconds default)
      (Compaction.Policy.periodic_interval_seconds default)
      (Compaction.Policy.storage_budget_bytes default)
      None arguments
  in
  match policy with
  | Error error -> fail Fun.id error
  | Ok policy -> (
      match open_scratch root with
      | Error error -> fail Fun.id error
      | Ok (store, scratch) -> (
          let print_cleanup report =
            Printf.printf
              "generation=%s quarantined-objects=%d quarantined-bytes=%Ld \
               pruned-objects=%d pruned-bytes=%Ld already-quarantined=%d \
               already-pruned=%d\n"
              (Store.Stored_object_id.to_hex
                 (Scratch.Generation_id.stored_object_id
                    report.Compaction.generation))
              report.Compaction.quarantined_objects
              report.Compaction.quarantined_bytes
              report.Compaction.pruned_objects report.Compaction.pruned_bytes
              report.Compaction.already_quarantined_objects
              report.Compaction.already_pruned_objects
          in
          match mode with
          | `Dry_run -> (
              match
                Compaction.analyze ~store scratch ~policy ~now:timestamp
              with
              | Error error -> fail Compaction.error_to_string error
              | Ok plan ->
                  Compaction.render_explain plan |> List.iter print_endline)
          | `Activate -> (
              match
                Compaction.activate ~store scratch ~policy ~now:timestamp
              with
              | Error error -> fail Compaction.error_to_string error
              | Ok execution ->
                  if explain then
                    Compaction.render_explain
                      (Compaction.execution_plan execution)
                    |> List.iter print_endline;
                  print_cleanup (Compaction.execution_cleanup execution))
          | `Resume -> (
              match Compaction.resume_cleanup ~store scratch with
              | Error error -> fail Compaction.error_to_string error
              | Ok report -> print_cleanup report)
          | `Prune -> (
              match Compaction.prune ~store scratch with
              | Error error -> fail Compaction.error_to_string error
              | Ok report -> print_cleanup report)))

let watch root arguments =
  let interval_ms, debounce_ms, iterations =
    let rec parse interval debounce iterations = function
      | [] -> (interval, debounce, iterations)
      | "--interval-ms" :: value :: rest -> (
          match int_of_string_opt value with
          | Some value when value >= 0 -> parse value debounce iterations rest
          | Some _ | None -> exit 2)
      | "--debounce-ms" :: value :: rest -> (
          match int_of_string_opt value with
          | Some value when value >= 0 -> parse interval value iterations rest
          | Some _ | None -> exit 2)
      | "--iterations" :: value :: rest -> (
          match int_of_string_opt value with
          | Some value when value >= 0 ->
              parse interval debounce (Some value) rest
          | Some _ | None -> exit 2)
      | _ -> exit 2
    in
    parse 500 500 None arguments
  in
  match open_scratch root with
  | Error error -> fail Fun.id error
  | Ok (store, scratch) ->
      let polling = ref (Scratch.Polling.create ~debounce_ms) in
      let rec loop count =
        match iterations with
        | Some limit when count >= limit -> ()
        | None | Some _ -> (
            let scanned = Snapshot.scan ~root ~store in
            match scanned with
            | Error error -> fail Snapshot.error_to_string error
            | Ok (snapshot, _) -> (
                let head =
                  Scratch.head scratch
                  |> Result.map_error Scratch.error_to_string
                in
                match head with
                | Error error -> fail Fun.id error
                | Ok None ->
                    prerr_endline "scratch history is not initialized";
                    exit 2
                | Ok (Some checkpoint) ->
                    let updated, checkpoint_now =
                      Scratch.Polling.observe !polling
                        ~head:(Scratch.Checkpoint.snapshot checkpoint)
                        ~observed:snapshot
                        ~now_ms:(Int64.of_float (Unix.gettimeofday () *. 1000.))
                    in
                    polling := updated;
                    if checkpoint_now then (
                      let timestamp = now () in
                      (match
                         Scratch.checkpoint scratch ~snapshot
                           ~source:Scratch.Scan ~observed_at:timestamp
                           ~created_at:timestamp
                       with
                      | Ok (Scratch.Created checkpoint) ->
                          print_checkpoint checkpoint
                      | Ok (Scratch.Unchanged _) -> ()
                      | Error error -> fail Scratch.error_to_string error);
                      if interval_ms > 0 then
                        ignore
                          (Unix.select [] [] []
                             (float_of_int interval_ms /. 1000.));
                      loop (count + 1))))
      in
      loop 0

let capsule root arguments =
  match arguments with
  | [ "show"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store ->
          let resolved =
            Capsule_store.Durable.show store (capsule_id identity)
            |> Result.map_error Capsule_store.error_to_string
          in
          (match resolved with
          | Error error -> fail Fun.id error
          | Ok resolved ->
              let capsule = Capsule_store.Durable.resolved_capsule resolved in
              let revision = Capsule_store.Durable.resolved_revision resolved in
              Printf.printf "capsule %s\nrevision %s\ntitle %s\ndescription %s\n"
                (Paengi_id.Capsule_id.to_hex (Capsule_store.capsule_id capsule))
                (Paengi_id.Capsule_revision_id.to_hex
                   (Capsule_store.revision_id revision))
                (Capsule_store.capsule_title capsule)
                (Capsule_store.capsule_description capsule)))
  | [ "current-diff"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store ->
          Capsule_store.Durable.current_diff store (capsule_id identity)
          |> Result.map_error Capsule_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok operations ->
              List.iter
                (fun operation ->
                  print_endline (render_capsule_operation operation))
                operations)
  | [ "history"; identity ] -> (
      match Store.open_repository ~root with
      | Error error -> fail Store.error_to_string error
      | Ok store ->
          Capsule_store.Durable.history store (capsule_id identity)
          |> Result.map_error Capsule_store.error_to_string
          |> function
          | Error error -> fail Fun.id error
          | Ok revisions ->
              List.iter
                (fun revision ->
                  print_endline
                    (Paengi_id.Capsule_revision_id.to_hex
                       (Capsule_store.revision_id revision)))
                revisions)
  | _ -> exit 2

let usage () =
  prerr_endline
    "usage: paengi <init|checkpoint|timeline|restore|pin|unpin|compact|watch|capsule> \
     [--root PATH] ...";
  exit 2

let () =
  Sys.catch_break true;
  try
    match Array.to_list Sys.argv with
    | _ :: command :: arguments -> (
        let root, arguments = parse_root arguments in
        match command with
        | "init" when arguments = [] -> initialise root
        | "checkpoint" when arguments = [] -> checkpoint root
        | "timeline" -> timeline root arguments
        | "restore" -> restore root arguments
        | "pin" -> change_pin root arguments true
        | "unpin" -> change_pin root arguments false
        | "compact" -> compact root arguments
        | "watch" -> watch root arguments
        | "capsule" -> capsule root arguments
        | _ -> usage ())
    | _ -> usage ()
  with Sys.Break -> print_endline "watch stopped"
