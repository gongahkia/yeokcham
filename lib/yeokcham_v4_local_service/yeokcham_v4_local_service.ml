module Model = Yeokcham_v4_model
module Journal = Yeokcham_v4_restore_journal
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_v4_store

module Path_map = Map.Make (struct
  type t = string list

  let compare = List.compare String.compare
end)

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Materialize_error of Snapshot.Materialize.error
  | Restore_journal_error of Journal.error
  | Model_error of Model.error
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Model.Snapshot_id.t
  | Unchanged_share of Model.Snapshot_id.t

type status = {
  active_draft : Model.draft;
  checkpoint : Model.Snapshot_id.t;
  shared_changes : Model.shared_change list;
  shared_change_count : int;
  open_decisions : Model.decision list;
  deliveries : Model.delivery list;
  delivery_count : int;
  checkpoints : Model.checkpoint list;
  usernames : Model.username_registration list;
  uncaptured : bool;
}

type materialized_candidate = {
  revision : Model.Revision_id.t;
  author : Model.Device_id.t;
  username : Model.Username.t option;
  directory : string;
}

type save_outcome = Unchanged of status | Saved of status

type compact_report = {
  kept : Model.compact_keep list;
  dropped : Model.Snapshot_id.t list;
  pruned_journals : string list;
  status : status;
}

module Capture_window = struct
  type t = { first : float option; last : float option }

  let empty = { first = None; last = None }
  let quiet_seconds = 1.0
  let max_seconds = 30.0
  let clear = empty

  let observe window ~now =
    match window.first with
    | None -> { first = Some now; last = Some now }
    | Some first -> { first = Some first; last = Some now }

  let due window ~now =
    match (window.first, window.last) with
    | Some first, Some last ->
        now -. last >= quiet_seconds || now -. first >= max_seconds
    | Some _, None | None, Some _ | None, None -> false

  let timeout window ~now =
    match (window.first, window.last) with
    | Some first, Some last ->
        Float.max 0.0
          (Float.min
             (quiet_seconds -. (now -. last))
             (max_seconds -. (now -. first)))
    | Some _, None | None, Some _ | None, None -> 60.0
end

type in_place_restore = {
  safety_checkpoint : Model.Snapshot_id.t;
  restored_checkpoint : Model.Snapshot_id.t;
  resumed : bool;
}

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Materialize_error error -> Snapshot.Materialize.error_to_string error
  | Restore_journal_error error -> Journal.error_to_string error
  | Model_error error -> Model.error_to_string error
  | Invalid_checkpoint_id value ->
      "invalid saved checkpoint identifier: " ^ value
  | Unknown_checkpoint id ->
      "checkpoint is not retained by this project: "
      ^ Model.Snapshot_id.to_string id
  | Unchanged_share snapshot ->
      "share would not publish a new snapshot: "
      ^ Model.Snapshot_id.to_string snapshot

let ( let* ) = Result.bind

let snapshot_id identity =
  identity |> Snapshot.Snapshot.stored_object_id
  |> Yeokcham_store.Stored_object_id.to_hex |> Model.Snapshot_id.of_string
  |> Result.map_error (fun error -> Model_error error)

let capture ~root store =
  let* identity, _ =
    Snapshot.scan_excluding_root_names
      ~excluded_root_names:[ ".yeokcham"; ".git" ] ~root ~store
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  snapshot_id identity

let status_of_project ?(uncaptured = false) project =
  let active_draft = Model.active_draft project in
  let projection = Model.projection project in
  let shared_changes = Model.shared_changes project in
  let deliveries = Model.deliveries project in
  {
    active_draft;
    checkpoint = active_draft.Model.latest_checkpoint;
    shared_changes;
    shared_change_count = List.length shared_changes;
    open_decisions = projection.Model.decisions;
    deliveries;
    delivery_count = List.length deliveries;
    checkpoints = Model.checkpoints project;
    usernames = Model.usernames project;
    uncaptured;
  }

let load_snapshot store snapshot =
  let text = Model.Snapshot_id.to_string snapshot in
  let* object_id =
    Yeokcham_store.Stored_object_id.of_hex text
    |> Result.map_error (fun _ -> Invalid_checkpoint_id text)
  in
  Snapshot.Snapshot.load store (Snapshot.Snapshot.of_stored_object_id object_id)
  |> Result.map_error (fun error -> Snapshot_error error)

let rec collect_leaves store prefix tree_id acc =
  let* tree =
    Snapshot.Tree.load store tree_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let rec walk acc = function
    | [] -> Ok acc
    | (name, entry) :: rest ->
        let path = prefix @ [ name ] in
        let* acc =
          match entry with
          | Snapshot.Tree.File { mode; content } ->
              Ok (Path_map.add path (mode, content) acc)
          | Snapshot.Tree.Directory child -> collect_leaves store path child acc
        in
        walk acc rest
  in
  walk acc (Snapshot.Tree.entries tree)

let leaves_of_snapshot store snapshot_id =
  let* snapshot = load_snapshot store snapshot_id in
  collect_leaves store [] (Snapshot.Snapshot.root snapshot) Path_map.empty

let entry_equal (left_mode, left_content) (right_mode, right_content) =
  left_mode = right_mode && Snapshot.Content.equal_id left_content right_content

let differing_paths left right =
  Path_map.merge
    (fun _ left right ->
      match (left, right) with
      | Some left, Some right when entry_equal left right -> None
      | None, None -> None
      | _ -> Some ())
    left right
  |> Path_map.bindings |> List.map fst

let whole_path_edits paths =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | components :: rest ->
        let* path =
          Model.Path.of_components components
          |> Result.map_error (fun error -> Model_error error)
        in
        loop
          (Model.{ edit_path = path; edit_kind = Whole_path } :: reversed)
          rest
  in
  loop [] paths

let edits_between store ~baseline ~result =
  let* baseline_leaves = leaves_of_snapshot store baseline in
  let* result_leaves = leaves_of_snapshot store result in
  differing_paths baseline_leaves result_leaves |> whole_path_edits

let persist repository loaded project =
  Store.save repository ~expected:loaded.Store.head ~project
  |> Result.map (fun saved -> status_of_project saved.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let checkpoint_observed project observed =
  let active = Model.active_draft project in
  if Model.Snapshot_id.equal active.Model.latest_checkpoint observed then
    project
  else Model.checkpoint project ~snapshot:observed

let with_repository ~root f =
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  f repository loaded

let init ~root ~creator ~username ~initial_draft ~title =
  let* repository =
    Store.init_with ~root ~bootstrap:(fun underlying_store ->
        let* initial_snapshot =
          capture ~root underlying_store |> Result.map_error error_to_string
        in
        Ok
          (Model.init ~creator ~username ~initial_snapshot ~initial_draft ~title))
    |> Result.map_error (fun error -> Store_error error)
  in
  Store.load repository
  |> Result.map (fun loaded -> status_of_project loaded.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let status ~root =
  with_repository ~root (fun repository loaded ->
      let* observed = capture ~root (Store.underlying_store repository) in
      let active = Model.active_draft loaded.Store.project in
      let uncaptured =
        not (Model.Snapshot_id.equal active.Model.latest_checkpoint observed)
      in
      Ok (status_of_project ~uncaptured loaded.Store.project))

let register_username ~root ~device ~username =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.register_username loaded.Store.project ~device ~username
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let save ~root =
  with_repository ~root (fun repository loaded ->
      let* observed = capture ~root (Store.underlying_store repository) in
      let active = Model.active_draft loaded.Store.project in
      if Model.Snapshot_id.equal active.Model.latest_checkpoint observed then
        Ok (Unchanged (status_of_project loaded.Store.project))
      else
        let project =
          Model.checkpoint loaded.Store.project ~snapshot:observed
        in
        persist repository loaded project
        |> Result.map (fun status -> Saved status))

let restore ~root ~checkpoint ~destination =
  with_repository ~root (fun repository loaded ->
      if
        not
          (List.exists
             (fun candidate ->
               Model.Snapshot_id.equal candidate.Model.checkpoint_snapshot
                 checkpoint)
             (Model.checkpoints loaded.Store.project))
      then Error (Unknown_checkpoint checkpoint)
      else
        let* snapshot =
          load_snapshot (Store.underlying_store repository) checkpoint
        in
        Snapshot.Materialize.write ~destination
          (Store.underlying_store repository)
          snapshot
        |> Result.map_error (fun error -> Materialize_error error))

let retained project checkpoint =
  List.exists
    (fun candidate ->
      Model.Snapshot_id.equal candidate.Model.checkpoint_snapshot checkpoint)
    (Model.checkpoints project)

let hex_of_raw raw =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length raw * 2)
    (fun index ->
      let byte = Char.code raw.[index / 2] in
      if index mod 2 = 0 then alphabet.[byte lsr 4]
      else alphabet.[byte land 0x0f])

let restore_operation_id ~safety ~target =
  let seed =
    String.concat ":"
      [
        Model.Snapshot_id.to_string safety;
        Model.Snapshot_id.to_string target;
        string_of_int (Unix.getpid ());
        Int64.to_string
          (Int64.of_float (Unix.gettimeofday () *. 1_000_000_000.));
      ]
  in
  Yeokcham_hash.Sha256.digest_string seed
  |> Yeokcham_hash.Sha256.to_raw_string |> hex_of_raw

let append_journal ~root journal =
  Journal.append ~root journal
  |> Result.map_error (fun error -> Restore_journal_error error)

let advance_journal ~root journal phase =
  let* next =
    Journal.advance journal phase
    |> Result.map_error (fun error -> Restore_journal_error error)
  in
  let* () = append_journal ~root next in
  Ok next

let perform_in_place ~root repository loaded journal ~resumed =
  let store = Store.underlying_store repository in
  let* applying =
    match Journal.phase journal with
    | Journal.Prepared -> advance_journal ~root journal Journal.Applying
    | Journal.Applying -> Ok journal
    | Journal.Materialized | Journal.Published -> Ok journal
  in
  let* materialized =
    match Journal.phase applying with
    | Journal.Applying ->
        let* target = load_snapshot store (Journal.target applying) in
        let* () =
          Snapshot.Materialize.write_replacing ~destination:root
            ~preserved_root_names:[ ".yeokcham"; ".git" ] store target
          |> Result.map_error (fun error -> Materialize_error error)
        in
        advance_journal ~root applying Journal.Materialized
    | Journal.Materialized | Journal.Published -> Ok applying
    | Journal.Prepared -> assert false
  in
  let* () =
    match Journal.phase materialized with
    | Journal.Materialized ->
        let project =
          Model.checkpoint loaded.Store.project
            ~snapshot:(Journal.target materialized)
        in
        let* _ =
          Store.save repository ~expected:loaded.Store.head ~project
          |> Result.map_error (fun error -> Store_error error)
        in
        let* _ = advance_journal ~root materialized Journal.Published in
        Ok ()
    | Journal.Published -> Ok ()
    | Journal.Prepared | Journal.Applying -> assert false
  in
  Ok
    {
      safety_checkpoint = Journal.safety journal;
      restored_checkpoint = Journal.target journal;
      resumed;
    }

let recover_in_place ~root =
  with_repository ~root (fun repository loaded ->
      let* pending =
        Journal.latest_pending ~root
        |> Result.map_error (fun error -> Restore_journal_error error)
      in
      match pending with
      | None -> Ok None
      | Some journal ->
          if
            (not (retained loaded.Store.project (Journal.safety journal)))
            || not (retained loaded.Store.project (Journal.target journal))
          then
            Error
              (Restore_journal_error
                 (Journal.Invalid_schema
                    "pending restore names an unretained checkpoint"))
          else
            perform_in_place ~root repository loaded journal ~resumed:true
            |> Result.map Option.some)

let restore_in_place ~root ~checkpoint =
  let* recovered = recover_in_place ~root in
  match recovered with
  | Some restored
    when Model.Snapshot_id.equal restored.restored_checkpoint checkpoint ->
      Ok restored
  | Some restored ->
      Error
        (Restore_journal_error
           (Journal.Invalid_schema
              ("completed pending restore to "
              ^ Model.Snapshot_id.to_string restored.restored_checkpoint
              ^ "; rerun the requested restore")))
  | None ->
      with_repository ~root (fun repository loaded ->
          if not (retained loaded.Store.project checkpoint) then
            Error (Unknown_checkpoint checkpoint)
          else
            let store = Store.underlying_store repository in
            let* safety = capture ~root store in
            if Model.Snapshot_id.equal safety checkpoint then
              Error (Restore_journal_error Journal.Identical_snapshots)
            else
              let project =
                Model.checkpoint loaded.Store.project ~snapshot:safety
              in
              let* saved =
                Store.save repository ~expected:loaded.Store.head ~project
                |> Result.map_error (fun error -> Store_error error)
              in
              let operation_id =
                restore_operation_id ~safety ~target:checkpoint
              in
              let* journal =
                Journal.make_prepared ~operation_id ~safety ~target:checkpoint
                |> Result.map_error (fun error -> Restore_journal_error error)
              in
              let* () = append_journal ~root journal in
              perform_in_place ~root repository saved journal ~resumed:false)

let new_draft ~root ~id ~title =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.new_draft loaded.Store.project ~id ~title
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let make_revision project ~change ~revision ~parent ~base ~result ~edits =
  Model.make_change_revision ~change ~revision ~parent
    ~author:(Model.creator project) ~base ~result ~edits
  |> Result.map_error (fun error -> Model_error error)

let share ~root ~change ~revision =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let baseline = (Model.projection project).Model.projection_baseline in
      let active = Model.active_draft project in
      let* () =
        match active.Model.shared_change with
        | None -> Ok ()
        | Some change_id -> (
            match
              List.find_opt
                (fun candidate ->
                  Model.Change_id.equal candidate.Model.change_id change_id)
                (Model.shared_changes project)
            with
            | None -> Ok ()
            | Some shared -> (
                match shared.Model.revisions with
                | latest :: _
                  when Model.Snapshot_id.equal latest.Model.result_snapshot
                         observed ->
                    Error (Unchanged_share observed)
                | _ -> Ok ()))
      in
      let* edits = edits_between store ~baseline ~result:observed in
      let* recorded =
        match active.Model.shared_change with
        | None ->
            let* recorded =
              make_revision project ~change ~revision ~parent:None
                ~base:baseline ~result:observed ~edits
            in
            Model.share_active project recorded
            |> Result.map_error (fun error -> Model_error error)
        | Some change_id ->
            let parent =
              match
                List.find_opt
                  (fun candidate ->
                    Model.Change_id.equal candidate.Model.change_id change_id)
                  (Model.shared_changes project)
              with
              | Some shared -> (
                  match shared.Model.revisions with
                  | latest :: _ -> Some latest.Model.revision
                  | [] -> None)
              | None -> None
            in
            let* recorded =
              make_revision project ~change ~revision ~parent ~base:baseline
                ~result:observed ~edits
            in
            Model.amend_active project recorded
            |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded recorded)

let withdraw ~root ~change =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.withdraw loaded.Store.project ~change
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let find_open_decision project decision =
  List.find_opt
    (fun candidate ->
      Model.Decision_id.equal candidate.Model.decision_id decision)
    (Model.projection project).Model.decisions

let require_empty_directory destination =
  try
    if (Unix.lstat destination).Unix.st_kind <> Unix.S_DIR then
      Error
        (Materialize_error
           (Snapshot.Materialize.Destination_not_directory destination))
    else if Array.length (Sys.readdir destination) <> 0 then
      Error
        (Materialize_error
           (Snapshot.Materialize.Destination_not_empty destination))
    else Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Materialize_error
         (Snapshot.Materialize.Io_error
            {
              path = destination;
              operation;
              message = Unix.error_message error;
            }))

let mkdir_exclusive path =
  try
    Unix.mkdir path 0o700;
    Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Materialize_error
         (Snapshot.Materialize.Io_error
            { path; operation; message = Unix.error_message error }))

let unique_candidate_revisions (decision : Model.decision) =
  decision.Model.candidates
  |> List.map (fun candidate -> candidate.Model.candidate_revision)
  |> List.sort_uniq (fun left right ->
      Model.Revision_id.compare left.Model.revision right.Model.revision)

let candidate_directory_name ~username ~index =
  let handle =
    match username with
    | Some username -> Model.Username.to_string username
    | None -> "device"
  in
  Printf.sprintf "%s-%03d" handle (index + 1)

let contained_child ~destination ~name =
  if
    String.length name = 0
    || String.equal name "." || String.equal name ".."
    || not (String.equal (Filename.basename name) name)
  then
    Error
      (Materialize_error
         (Snapshot.Materialize.Io_error
            {
              path = destination;
              operation = "derive candidate directory";
              message =
                "candidate directory name is not a single path component";
            }))
  else Ok (Filename.concat destination name)

let open_decision ~root ~decision =
  with_repository ~root (fun _ loaded ->
      match find_open_decision loaded.Store.project decision with
      | Some found -> Ok found
      | None -> Error (Model_error Model.Unknown_decision))

let materialize_decision ~root ~decision ~destination =
  with_repository ~root (fun repository loaded ->
      match find_open_decision loaded.Store.project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some found ->
          let* () = require_empty_directory destination in
          let store = Store.underlying_store repository in
          let revisions = unique_candidate_revisions found in
          let rec write index remaining materialized =
            match remaining with
            | [] -> Ok (List.rev materialized)
            | revision :: rest ->
                let username =
                  Model.username_for_device loaded.Store.project
                    ~device:revision.Model.revision_author
                in
                let* child =
                  contained_child ~destination
                    ~name:(candidate_directory_name ~username ~index)
                in
                let* () = mkdir_exclusive child in
                let* snapshot =
                  load_snapshot store revision.Model.result_snapshot
                in
                let* () =
                  Snapshot.Materialize.write ~destination:child store snapshot
                  |> Result.map_error (fun error -> Materialize_error error)
                in
                write (index + 1) rest
                  ({
                     revision = revision.Model.revision;
                     author = revision.Model.revision_author;
                     username;
                     directory = child;
                   }
                  :: materialized)
          in
          write 0 revisions [])

let resolve ~root ~decision ~change ~revision ~tree =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* project, observed =
        match tree with
        | None ->
            let* observed = capture ~root store in
            Ok (checkpoint_observed loaded.Store.project observed, observed)
        | Some path ->
            let* observed = capture ~root:path store in
            Ok (loaded.Store.project, observed)
      in
      let projection = Model.projection project in
      match find_open_decision project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some resolved ->
          let* edits =
            resolved.Model.decision_paths
            |> List.map Model.Path.components
            |> whole_path_edits
          in
          let* replacement =
            make_revision project ~change ~revision ~parent:None
              ~base:projection.Model.projection_baseline ~result:observed ~edits
          in
          let* project =
            Model.resolve project ~decision ~replacement
            |> Result.map_error (fun error -> Model_error error)
          in
          persist repository loaded project)

let deliver ~root ~id ~next_draft ~next_title =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let included =
        List.map
          (fun revision -> revision.Model.revision)
          (Model.projection project).Model.applied
      in
      let created_at = Int64.of_float (Unix.gettimeofday ()) in
      let* project =
        Model.deliver project ~id ~author:(Model.creator project)
          ~snapshot:observed ~included ~next_draft ~next_title ~created_at
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let pin ~root ~checkpoint =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.pin loaded.Store.project ~snapshot:checkpoint
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let unpin ~root ~checkpoint =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.unpin loaded.Store.project ~snapshot:checkpoint
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let published_journal_ids ~root =
  let* journals =
    Journal.scan ~root
    |> Result.map_error (fun error -> Restore_journal_error error)
  in
  let latest =
    List.fold_left
      (fun latest journal ->
        let prior = List.assoc_opt (Journal.operation_id journal) latest in
        match prior with
        | Some current
          when Int64.compare
                 (Journal.generation current)
                 (Journal.generation journal)
               >= 0 ->
            latest
        | Some _ ->
            (Journal.operation_id journal, journal)
            :: List.remove_assoc (Journal.operation_id journal) latest
        | None -> (Journal.operation_id journal, journal) :: latest)
      [] journals
  in
  Ok
    (latest
    |> List.filter (fun (_, journal) ->
        Journal.phase journal = Journal.Published)
    |> List.map fst
    |> List.sort_uniq String.compare)

let compact ~root ~keep_recent ~dry_run =
  with_repository ~root (fun repository loaded ->
      let* journal_snapshots =
        Journal.pending_snapshots ~root
        |> Result.map_error (fun error -> Restore_journal_error error)
      in
      let* compacted =
        Model.compact loaded.Store.project ~keep_recent ~journal_snapshots
        |> Result.map_error (fun error -> Model_error error)
      in
      let* status =
        if dry_run then Ok (status_of_project compacted.Model.project)
        else persist repository loaded compacted.Model.project
      in
      let* pruned_journals =
        if dry_run then published_journal_ids ~root
        else
          Journal.prune_published ~root
          |> Result.map_error (fun error -> Restore_journal_error error)
      in
      Ok
        {
          kept = compacted.Model.kept;
          dropped = compacted.Model.dropped;
          pruned_journals;
          status;
        })
