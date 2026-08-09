module Cutover = Yeokcham_cutover
module Journal = Yeokcham_v2_restore_journal
module Model = Yeokcham_v2_model

type repository = {
  root : string;
  journal : string;
  repository_id : Model.Repository_id.t;
}

type append_outcome = Appended | Already_appended
type write_outcome = Written | Already_present

type error =
  | Cutover_error of Cutover.error
  | Not_v2_root of Cutover.classification
  | Journal_error of Journal.error
  | Repository_mismatch of {
      expected : Model.Repository_id.t;
      actual : Model.Repository_id.t;
    }
  | Journal_collision of string
  | Journal_entry_changed of string
  | Invalid_journal_path of string
  | Io_error of { operation : string; path : string; message : string }

let max_temporary_attempts = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Cutover_error error -> Cutover.error_to_string error
  | Not_v2_root classification ->
      "V2 restore journal storage requires a V2-only root, found "
      ^ Cutover.classification_to_string classification
  | Journal_error error -> Journal.error_to_string error
  | Repository_mismatch { expected; actual } ->
      Printf.sprintf "V2 restore journal repository %s does not match %s"
        (Model.Repository_id.to_hex actual)
        (Model.Repository_id.to_hex expected)
  | Journal_collision path ->
      "V2 restore journal path already contains different bytes: " ^ path
  | Journal_entry_changed path ->
      "V2 restore journal entry changed while being read: " ^ path
  | Invalid_journal_path path -> "invalid V2 restore journal path: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let check_v2_root root =
  let* classification =
    Cutover.detect ~root |> Result.map_error (fun error -> Cutover_error error)
  in
  match classification with
  | Cutover.V2 -> Ok ()
  | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
    | Cutover.Incomplete _ ) as classification ->
      Error (Not_v2_root classification)

let open_repository ~root ~repository_id =
  let* () = check_v2_root root in
  Ok { root; journal = Filename.concat root ".yeokcham/journal"; repository_id }

let record_path repository record =
  Filename.concat repository.journal (Journal.filename record)

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        Unix.fsync descriptor;
        Ok ())
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"fsync" ~path error)

let read_regular_file ~limit path =
  try
    let initial = Unix.lstat path in
    if initial.Unix.st_kind <> Unix.S_REG then Error (Invalid_journal_path path)
    else if initial.Unix.st_size > limit then
      Error
        (Io_error
           {
             operation = "read";
             path;
             message = "restore journal entry exceeds its bounded size";
           })
    else
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let opened = Unix.fstat descriptor in
          if
            opened.Unix.st_kind <> Unix.S_REG
            || opened.Unix.st_size <> initial.Unix.st_size
          then Error (Journal_entry_changed path)
          else
            let bytes = Bytes.create opened.Unix.st_size in
            let rec read offset =
              if offset = Bytes.length bytes then
                Ok (Bytes.unsafe_to_string bytes)
              else
                try
                  let count =
                    Unix.read descriptor bytes offset
                      (Bytes.length bytes - offset)
                  in
                  if count = 0 then Error (Journal_entry_changed path)
                  else read (offset + count)
                with Unix.Unix_error (error, _, _) ->
                  Error (io_error ~operation:"read" ~path error)
            in
            read 0)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"lstat" ~path error)

let write_all descriptor bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let count =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if count = 0 then Error "write returned zero bytes"
        else write (offset + count)
      with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  write 0

let temporary_path final attempt =
  Filename.concat (Filename.dirname final)
    (Printf.sprintf ".%s.tmp-%d-%d" (Filename.basename final) (Unix.getpid ())
       attempt)

let create_temporary final bytes =
  let rec create attempt =
    if attempt = max_temporary_attempts then
      Error
        (Io_error
           {
             operation = "create temporary restore journal entry";
             path = Filename.dirname final;
             message = "temporary name space exhausted";
           })
    else
      let path = temporary_path final attempt in
      try
        let descriptor =
          Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
        in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () =
                write_all descriptor (Bytes.unsafe_of_string bytes)
                |> Result.map_error (fun message ->
                    Io_error { operation = "write"; path; message })
              in
              try
                Unix.fsync descriptor;
                Ok path
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"fsync" ~path error))
        in
        match result with
        | Ok _ -> result
        | Error _ ->
            (try Unix.unlink path with Unix.Unix_error _ -> ());
            result
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"create" ~path error)
  in
  create 0

let write_create_only ~final ~bytes =
  let* temporary = create_temporary final bytes in
  let directory = Filename.dirname final in
  let linked =
    try
      Unix.link temporary final;
      Ok true
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok false
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"link" ~path:final error)
  in
  let cleanup () = try Unix.unlink temporary with Unix.Unix_error _ -> () in
  match linked with
  | Error error ->
      cleanup ();
      Error error
  | Ok true ->
      let* () = fsync_directory directory in
      cleanup ();
      let* () = fsync_directory directory in
      Ok Written
  | Ok false ->
      cleanup ();
      let* existing = read_regular_file ~limit:Journal.max_record_bytes final in
      if String.equal existing bytes then Ok Already_present
      else Error (Journal_collision final)

let temporary_stat_kind_if_present path =
  try Ok (Some (Unix.lstat path).Unix.st_kind) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"lstat" ~path error)

let read_directory path =
  try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare)
  with Sys_error message ->
    Error (Io_error { operation = "read journal directory"; path; message })

let check_record_repository repository record =
  let actual = Journal.repository_id record in
  if Model.Repository_id.equal repository.repository_id actual then Ok ()
  else
    Error (Repository_mismatch { expected = repository.repository_id; actual })

let compare_records left right =
  let operation =
    Model.Transaction_id.compare
      (Journal.operation_id left)
      (Journal.operation_id right)
  in
  if operation <> 0 then operation
  else Int64.compare (Journal.generation left) (Journal.generation right)

let validate_chains records =
  let validate_one records =
    Journal.validate_chain records
    |> Result.map_error (fun error -> Journal_error error)
  in
  let rec loop current = function
    | [] -> (
        match current with [] -> Ok () | _ -> validate_one (List.rev current))
    | record :: rest -> (
        match current with
        | previous :: _
          when Model.Transaction_id.equal
                 (Journal.operation_id previous)
                 (Journal.operation_id record) ->
            loop (record :: current) rest
        | [] -> loop [ record ] rest
        | _ ->
            let* () = validate_one (List.rev current) in
            loop [ record ] rest)
  in
  loop [] records

let scan_unchecked repository =
  let* names = read_directory repository.journal in
  let rec scan records = function
    | [] ->
        let records = List.sort compare_records records in
        let* () = validate_chains records in
        Ok records
    | name :: rest when Journal.is_temporary_journal_filename name -> (
        let path = Filename.concat repository.journal name in
        let* kind = temporary_stat_kind_if_present path in
        match kind with
        | None | Some Unix.S_REG -> scan records rest
        | Some
            ( Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
            | Unix.S_SOCK ) ->
            Error (Invalid_journal_path path))
    | name :: rest when Journal.is_journal_filename name ->
        let path = Filename.concat repository.journal name in
        let* file =
          Journal.parse_filename name
          |> Result.map_error (fun error -> Journal_error error)
        in
        let* bytes = read_regular_file ~limit:Journal.max_record_bytes path in
        let* record =
          Journal.decode bytes
          |> Result.map_error (fun error -> Journal_error error)
        in
        if
          Model.Transaction_id.equal
            (Journal.journal_file_operation_id file)
            (Journal.operation_id record)
          && Int64.equal
               (Journal.journal_file_generation file)
               (Journal.generation record)
        then
          let* () = check_record_repository repository record in
          scan (record :: records) rest
        else Error (Invalid_journal_path path)
    | _ :: rest -> scan records rest
  in
  scan [] names

let scan repository =
  let* () = check_v2_root repository.root in
  scan_unchecked repository

let append repository record =
  let* () = check_v2_root repository.root in
  let* () = check_record_repository repository record in
  let* records = scan_unchecked repository in
  let operation_id = Journal.operation_id record in
  let operation_records =
    List.filter
      (fun candidate ->
        Model.Transaction_id.equal operation_id (Journal.operation_id candidate))
      records
  in
  let same_generation =
    List.find_opt
      (fun candidate ->
        Int64.equal (Journal.generation candidate) (Journal.generation record))
      operation_records
  in
  let* () =
    match same_generation with
    | Some existing
      when String.equal (Journal.encode existing) (Journal.encode record) ->
        Ok ()
    | Some _ -> Error (Journal_collision (record_path repository record))
    | None ->
        Journal.validate_chain (operation_records @ [ record ])
        |> Result.map_error (fun error -> Journal_error error)
  in
  let* outcome =
    write_create_only
      ~final:(record_path repository record)
      ~bytes:(Journal.encode record)
  in
  match outcome with
  | Written -> Ok Appended
  | Already_present -> Ok Already_appended

let latest repository ~operation_id =
  let* records = scan repository in
  Ok
    (List.fold_left
       (fun latest record ->
         if
           Model.Transaction_id.equal operation_id (Journal.operation_id record)
         then Some record
         else latest)
       None records)
