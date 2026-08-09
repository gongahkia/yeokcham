module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Model = Yeokcham_model
module Restore_plan = Yeokcham_v2_restore_plan
module Scanner = Yeokcham_v2_scanner

module Fault = struct
  type t = Never | Interrupt_after_action of int

  let never = Never

  let interrupt_after_action completed_actions =
    if completed_actions <= 0 then
      invalid_arg "V2 restore fault action count must be positive"
    else Interrupt_after_action completed_actions

  let interrupts_after fault completed_actions =
    match fault with
    | Never -> false
    | Interrupt_after_action expected -> expected = completed_actions
end

type outcome = { journal : Journal.t }

type error =
  | Scanner_error of Scanner.error
  | Journal_error of Journal.error
  | Journal_store_error of Journal_store.error
  | Pure_plan_error of Restore_plan.replay_error
  | Invalid_plan of string
  | Journal_action_count_mismatch of { journal : int; plan : int }
  | Journal_not_applying of Journal.phase
  | Stale_worktree of { expected : Model.Snapshot.t; actual : Model.Snapshot.t }
  | Verification_mismatch of {
      expected : Model.Snapshot.t;
      actual : Model.Snapshot.t;
    }
  | Unsafe_path of { path : string; reason : string }
  | Unexpected_node of { path : string; expected : string; actual : string }
  | Io_error of { operation : string; path : string; message : string }
  | Injected_interruption of { completed_actions : int }

let ( let* ) = Result.bind

let snapshot_to_string snapshot =
  Model.Snapshot.id snapshot |> Yeokcham_id.Snapshot_id.to_hex

let node_kind = function
  | Unix.S_REG -> "regular file"
  | Unix.S_DIR -> "directory"
  | Unix.S_LNK -> "symlink"
  | Unix.S_CHR -> "character device"
  | Unix.S_BLK -> "block device"
  | Unix.S_FIFO -> "FIFO"
  | Unix.S_SOCK -> "socket"

let error_to_string = function
  | Scanner_error error -> Scanner.error_to_string error
  | Journal_error error -> Journal.error_to_string error
  | Journal_store_error error -> Journal_store.error_to_string error
  | Pure_plan_error error -> Restore_plan.replay_error_to_string error
  | Invalid_plan detail -> "invalid V2 restore materialisation plan: " ^ detail
  | Journal_action_count_mismatch { journal; plan } ->
      Printf.sprintf
        "V2 restore journal action count %d does not match plan action count %d"
        journal plan
  | Journal_not_applying phase ->
      let phase =
        match phase with
        | Journal.Prepared -> "prepared"
        | Journal.Applying completed -> Printf.sprintf "applying(%d)" completed
        | Journal.Materialized -> "materialized"
        | Journal.Published -> "published"
      in
      "V2 restore materialisation requires an applying phase, found " ^ phase
  | Stale_worktree { expected; actual } ->
      Printf.sprintf
        "V2 restore working tree changed after preparation: expected %s, found \
         %s"
        (snapshot_to_string expected)
        (snapshot_to_string actual)
  | Verification_mismatch { expected; actual } ->
      Printf.sprintf
        "V2 restore materialisation verification failed: expected %s, found %s"
        (snapshot_to_string expected)
        (snapshot_to_string actual)
  | Unsafe_path { path; reason } ->
      Printf.sprintf "unsafe V2 restore path %s: %s" path reason
  | Unexpected_node { path; expected; actual } ->
      Printf.sprintf "V2 restore expected %s at %s, found %s" expected path
        actual
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Injected_interruption { completed_actions } ->
      Printf.sprintf
        "injected interruption after durable V2 restore action %d before \
         journal progress"
        completed_actions

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let lstat_optional ~operation path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io_error ~operation ~path error)

let require_directory path =
  let* stat = lstat_optional ~operation:"lstat" path in
  match stat with
  | Some stat when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
  | Some stat ->
      Error
        (Unexpected_node
           {
             path;
             expected = "directory";
             actual = node_kind stat.Unix.st_kind;
           })
  | None ->
      Error
        (Unexpected_node { path; expected = "directory"; actual = "absent" })

let checked_components path =
  let components = Model.Path.to_components path in
  match components with
  | ".yeokcham" :: _ ->
      Error
        (Unsafe_path
           {
             path = Model.Path.to_string path;
             reason = "metadata is never materialised";
           })
  | [] -> Error (Unsafe_path { path = ""; reason = "empty relative path" })
  | _ -> Ok components

let output_path root path =
  let* components = checked_components path in
  Ok (List.fold_left Filename.concat root components)

let parent_components components =
  match List.rev components with [] -> [] | _ :: parent -> List.rev parent

let require_parent_directories root path =
  let* components = checked_components path in
  let* () = require_directory root in
  let rec loop directory = function
    | [] -> Ok directory
    | component :: rest ->
        let next = Filename.concat directory component in
        let* () = require_directory next in
        loop next rest
  in
  loop root (parent_components components)

let fsync_file path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        Unix.fsync descriptor;
        Ok ())
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"fsync" ~path error)

let fsync_directory path = fsync_file path

let permissions = function
  | Model.Regular -> 0o644
  | Model.Executable -> 0o755
  | Model.Symlink -> assert false

let write_all descriptor ~path bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let count =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if count = 0 then
          Error
            (Io_error
               {
                 operation = "write";
                 path;
                 message = "write returned zero before completion";
               })
        else write (offset + count)
      with Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"write" ~path error)
  in
  write 0

let temporary_path directory basename attempt =
  Filename.concat directory
    (Printf.sprintf ".%s.yeokcham-v2-restore-%d-%d" basename (Unix.getpid ())
       attempt)

let rec write_regular ~directory ~output ~content ~mode attempt =
  if attempt = 128 then
    Error
      (Io_error
         {
           operation = "create temporary";
           path = directory;
           message = "temporary name space exhausted";
         })
  else
    let temporary =
      temporary_path directory (Filename.basename output) attempt
    in
    try
      let descriptor =
        Unix.openfile temporary
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
          0o600
      in
      let result =
        Fun.protect
          ~finally:(fun () -> Unix.close descriptor)
          (fun () ->
            let* () =
              write_all descriptor ~path:temporary (Bytes.of_string content)
            in
            try
              Unix.chmod temporary (permissions mode);
              Unix.fsync descriptor;
              Ok ()
            with Unix.Unix_error (error, _, _) ->
              Error
                (io_error ~operation:"write regular file" ~path:temporary error))
      in
      match result with
      | Error error ->
          (try Unix.unlink temporary with Unix.Unix_error _ -> ());
          Error error
      | Ok () -> (
          try
            Unix.rename temporary output;
            fsync_directory directory
          with Unix.Unix_error (error, _, _) ->
            (try Unix.unlink temporary with Unix.Unix_error _ -> ());
            Error (io_error ~operation:"rename" ~path:output error))
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) ->
        write_regular ~directory ~output ~content ~mode (attempt + 1)
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"create temporary" ~path:temporary error)

let remove_file root path =
  let* directory = require_parent_directories root path in
  let* output = output_path root path in
  let* stat = lstat_optional ~operation:"lstat" output in
  match stat with
  | Some stat
    when stat.Unix.st_kind = Unix.S_REG || stat.Unix.st_kind = Unix.S_LNK -> (
      try
        Unix.unlink output;
        fsync_directory directory
      with Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"unlink" ~path:output error))
  | Some stat ->
      Error
        (Unexpected_node
           {
             path = output;
             expected = "regular file or symlink";
             actual = node_kind stat.Unix.st_kind;
           })
  | None ->
      Error
        (Unexpected_node { path = output; expected = "file"; actual = "absent" })

let remove_directory root path =
  let* directory = require_parent_directories root path in
  let* output = output_path root path in
  let* stat = lstat_optional ~operation:"lstat" output in
  match stat with
  | Some stat when stat.Unix.st_kind = Unix.S_DIR -> (
      try
        Unix.rmdir output;
        fsync_directory directory
      with Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"rmdir" ~path:output error))
  | Some stat ->
      Error
        (Unexpected_node
           {
             path = output;
             expected = "directory";
             actual = node_kind stat.Unix.st_kind;
           })
  | None ->
      Error
        (Unexpected_node
           { path = output; expected = "directory"; actual = "absent" })

let ensure_directory root path =
  let* directory = require_parent_directories root path in
  let* output = output_path root path in
  let* stat = lstat_optional ~operation:"lstat" output in
  match stat with
  | None -> (
      try
        Unix.mkdir output 0o755;
        fsync_directory directory
      with Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"mkdir" ~path:output error))
  | Some stat ->
      Error
        (Unexpected_node
           {
             path = output;
             expected = "absent directory path";
             actual = node_kind stat.Unix.st_kind;
           })

let write_file root path content mode =
  if mode = Model.Symlink then
    Error
      (Invalid_plan
         ("write-file action names symlink mode at " ^ Model.Path.to_string path))
  else
    let* directory = require_parent_directories root path in
    let* output = output_path root path in
    let* stat = lstat_optional ~operation:"lstat" output in
    match stat with
    | None -> write_regular ~directory ~output ~content ~mode 0
    | Some stat when stat.Unix.st_kind = Unix.S_REG ->
        write_regular ~directory ~output ~content ~mode 0
    | Some stat ->
        Error
          (Unexpected_node
             {
               path = output;
               expected = "absent path or regular file";
               actual = node_kind stat.Unix.st_kind;
             })

let create_symlink root path target =
  if String.contains target '\000' then
    Error
      (Invalid_plan
         ("symlink target contains NUL at " ^ Model.Path.to_string path))
  else
    let* directory = require_parent_directories root path in
    let* output = output_path root path in
    let* stat = lstat_optional ~operation:"lstat" output in
    match stat with
    | None -> (
        try
          Unix.symlink target output;
          fsync_directory directory
        with Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"symlink" ~path:output error))
    | Some stat ->
        Error
          (Unexpected_node
             {
               path = output;
               expected = "absent symlink path";
               actual = node_kind stat.Unix.st_kind;
             })

let set_file_mode root path mode =
  if mode = Model.Symlink then
    Error
      (Invalid_plan
         ("set-file-mode action names symlink mode at "
        ^ Model.Path.to_string path))
  else
    let* _directory = require_parent_directories root path in
    let* output = output_path root path in
    let* stat = lstat_optional ~operation:"lstat" output in
    match stat with
    | Some stat when stat.Unix.st_kind = Unix.S_REG -> (
        try
          Unix.chmod output (permissions mode);
          fsync_file output
        with Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"chmod" ~path:output error))
    | Some stat ->
        Error
          (Unexpected_node
             {
               path = output;
               expected = "regular file";
               actual = node_kind stat.Unix.st_kind;
             })
    | None ->
        Error
          (Unexpected_node
             { path = output; expected = "regular file"; actual = "absent" })

let apply_action root = function
  | Restore_plan.Remove_file path -> remove_file root path
  | Restore_plan.Remove_directory path -> remove_directory root path
  | Restore_plan.Ensure_directory path -> ensure_directory root path
  | Restore_plan.Write_file { path; content; mode } ->
      write_file root path content mode
  | Restore_plan.Create_symlink { path; target } ->
      create_symlink root path target
  | Restore_plan.Set_file_mode { path; mode } -> set_file_mode root path mode

let append journal_store record =
  match Journal_store.append journal_store record with
  | Ok Journal_store.Appended | Ok Journal_store.Already_appended -> Ok ()
  | Error error -> Error (Journal_store_error error)

let verify_journal plan journal =
  let action_count = List.length (Restore_plan.actions plan) in
  if action_count = 0 || Restore_plan.is_noop plan then
    Error (Invalid_plan "materialisation requires a nonempty restore plan")
  else if Journal.action_count journal <> action_count then
    Error
      (Journal_action_count_mismatch
         { journal = Journal.action_count journal; plan = action_count })
  else
    (match Journal.phase journal with
    | Journal.Applying completed -> Ok completed
    | phase -> Error (Journal_not_applying phase))
    [@warning "-4"]

let rec drop count values =
  match (count, values) with
  | 0, values -> values
  | _, [] -> []
  | count, _ :: rest -> drop (count - 1) rest

let reconcile_progress ~root ~journal_store ~plan ~journal ~completed =
  let* actual =
    Scanner.scan ~root |> Result.map_error (fun error -> Scanner_error error)
  in
  let* expected =
    Restore_plan.replay_prefix plan ~completed_actions:completed
    |> Result.map_error (fun error -> Pure_plan_error error)
  in
  if Model.Snapshot.equal actual expected then Ok (completed, journal)
  else if completed = Journal.action_count journal then
    Error (Stale_worktree { expected; actual })
  else
    let* after_next =
      Restore_plan.replay_prefix plan ~completed_actions:(completed + 1)
      |> Result.map_error (fun error -> Pure_plan_error error)
    in
    if not (Model.Snapshot.equal actual after_next) then
      Error (Stale_worktree { expected; actual })
    else
      let* advanced =
        Journal.advance journal (Journal.Applying (completed + 1))
        |> Result.map_error (fun error -> Journal_error error)
      in
      let* () = append journal_store advanced in
      Ok (completed + 1, advanced)

let materialize ?(fault = Fault.never) ~root ~journal_store ~plan ~journal () =
  let* completed = verify_journal plan journal in
  let* replayed =
    Restore_plan.replay plan
    |> Result.map_error (fun error -> Pure_plan_error error)
  in
  if not (Model.Snapshot.equal replayed (Restore_plan.target plan)) then
    Error
      (Invalid_plan "pure restore replay does not reach its target snapshot")
  else
    let* completed, journal =
      reconcile_progress ~root ~journal_store ~plan ~journal ~completed
    in
    let rec run completed journal = function
      | [] ->
          let* actual =
            Scanner.scan ~root
            |> Result.map_error (fun error -> Scanner_error error)
          in
          if not (Model.Snapshot.equal actual (Restore_plan.target plan)) then
            Error
              (Verification_mismatch
                 { expected = Restore_plan.target plan; actual })
          else
            let* materialized =
              Journal.advance journal Journal.Materialized
              |> Result.map_error (fun error -> Journal_error error)
            in
            let* () = append journal_store materialized in
            Ok { journal = materialized }
      | action :: rest ->
          let* () = apply_action root action in
          let completed = completed + 1 in
          if Fault.interrupts_after fault completed then
            Error (Injected_interruption { completed_actions = completed })
          else
            let* advanced =
              Journal.advance journal (Journal.Applying completed)
              |> Result.map_error (fun error -> Journal_error error)
            in
            let* () = append journal_store advanced in
            run completed advanced rest
    in
    run completed journal (drop completed (Restore_plan.actions plan))
