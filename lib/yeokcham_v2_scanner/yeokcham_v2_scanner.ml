module Model = Yeokcham_model
module Object = Yeokcham_v2_object

type error =
  | Root_not_directory of string
  | Io_error of { operation : string; path : string; message : string }
  | File_too_large of { path : string; size : int; limit : int }
  | Snapshot_too_large of { size : int; limit : int }
  | Unsupported_file_type of { path : string; kind : string }
  | Invalid_ignore_path of { line : int; path : string }
  | Path_error of { path : string; error : Model.Path.error }
  | Snapshot_error of Model.construction_error

let max_ignore_bytes = 64 * 1024
let max_snapshot_bytes = Object.max_payload_bytes - 64
let ( let* ) = Result.bind

let error_to_string = function
  | Root_not_directory path -> "V2 scan root is not a directory: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | File_too_large { path; size; limit } ->
      Printf.sprintf "V2 scan file %s is %d bytes; limit is %d" path size limit
  | Snapshot_too_large { size; limit } ->
      Printf.sprintf "V2 scanned snapshot is %d bytes; limit is %d" size limit
  | Unsupported_file_type { path; kind } ->
      Printf.sprintf "V2 scan does not support %s at %s" kind path
  | Invalid_ignore_path { line; path } ->
      Printf.sprintf "invalid .yeokchamignore path on line %d: %S" line path
  | Path_error { path; error } ->
      Printf.sprintf "invalid scanned path %s: %s" path
        (Model.Path.error_to_string error)
  | Snapshot_error error -> Model.construction_error_to_string error

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let same_node left right =
  left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino
  && left.Unix.st_kind = right.Unix.st_kind

let lstat ~operation path =
  try Ok (Unix.lstat path)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation ~path error)

let read_regular_file ~limit path initial =
  if initial.Unix.st_kind <> Unix.S_REG then
    Error (Unsupported_file_type { path; kind = "non-regular file" })
  else if initial.Unix.st_size > limit then
    Error (File_too_large { path; size = initial.Unix.st_size; limit })
  else
    try
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let opened = Unix.fstat descriptor in
          if
            opened.Unix.st_kind <> Unix.S_REG
            || (not (same_node initial opened))
            || opened.Unix.st_size <> initial.Unix.st_size
          then
            Error
              (Io_error
                 {
                   operation = "open";
                   path;
                   message = "file changed while opening for exact scan";
                 })
          else
            let bytes = Bytes.create opened.Unix.st_size in
            let rec read offset =
              if offset = Bytes.length bytes then Ok ()
              else
                try
                  let count =
                    Unix.read descriptor bytes offset
                      (Bytes.length bytes - offset)
                  in
                  if count = 0 then
                    Error
                      (Io_error
                         {
                           operation = "read";
                           path;
                           message = "file shortened during exact scan";
                         })
                  else read (offset + count)
                with Unix.Unix_error (error, _, _) ->
                  Error (io_error ~operation:"read" ~path error)
            in
            let* () = read 0 in
            let extra = Bytes.create 1 in
            let* extra_count =
              try Ok (Unix.read descriptor extra 0 1)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"read" ~path error)
            in
            let* final = lstat ~operation:"lstat" path in
            if
              extra_count <> 0
              || (not (same_node opened final))
              || final.Unix.st_size <> opened.Unix.st_size
              || final.Unix.st_perm <> opened.Unix.st_perm
            then
              Error
                (Io_error
                   {
                     operation = "read";
                     path;
                     message = "file changed during exact scan";
                   })
            else Ok (Bytes.unsafe_to_string bytes))
    with Unix.Unix_error (error, _, _) ->
      Error (io_error ~operation:"open" ~path error)

let safe_ignore_components path =
  if String.is_empty path || String.starts_with ~prefix:"/" path then None
  else
    let components = String.split_on_char '/' path in
    match Model.Path.of_components components with
    | Ok path -> Some (Model.Path.to_components path)
    | Error _ -> None

let read_ignore_file root =
  let path = Filename.concat root ".yeokchamignore" in
  match
    try Ok (Some (Unix.lstat path)) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"lstat" ~path error)
  with
  | Error error -> Error error
  | Ok None -> Ok []
  | Ok (Some stat) ->
      if stat.Unix.st_kind <> Unix.S_REG then
        Error (Invalid_ignore_path { line = 0; path = ".yeokchamignore" })
      else
        let* contents = read_regular_file ~limit:max_ignore_bytes path stat in
        let rec parse line_number reversed = function
          | [] -> Ok (List.rev reversed)
          | line :: rest -> (
              let line =
                if String.ends_with ~suffix:"\r" line then
                  String.sub line 0 (String.length line - 1)
                else line
              in
              if String.is_empty line || String.starts_with ~prefix:"#" line
              then parse (line_number + 1) reversed rest
              else
                match safe_ignore_components line with
                | Some components ->
                    parse (line_number + 1) (components :: reversed) rest
                | None ->
                    Error
                      (Invalid_ignore_path { line = line_number; path = line }))
        in
        parse 1 [] (String.split_on_char '\n' contents)

let rec is_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | first :: rest, candidate :: candidates ->
      String.equal first candidate && is_prefix rest candidates

let is_ignored rules components =
  List.exists (fun rule -> is_prefix rule components) rules

let node_kind = function
  | Unix.S_SOCK -> "socket"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_CHR -> "character device"
  | Unix.S_BLK -> "block device"
  | Unix.S_DIR -> "directory"
  | Unix.S_REG -> "regular file"
  | Unix.S_LNK -> "symlink"

let model_path relative =
  Model.Path.of_components relative
  |> Result.map_error (fun error ->
      Path_error { path = String.concat "/" relative; error })

let scan ~root =
  let* root_stat = lstat ~operation:"lstat" root in
  if root_stat.Unix.st_kind <> Unix.S_DIR then Error (Root_not_directory root)
  else
    let* ignore_rules = read_ignore_file root in
    let rec scan_directory relative directory =
      let* names =
        try
          Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
        with Sys_error message ->
          Error (Io_error { operation = "readdir"; path = directory; message })
      in
      let rec scan_entries reversed = function
        | [] -> Ok (List.rev reversed)
        | name :: rest ->
            let child_relative = relative @ [ name ] in
            if
              (relative = [] && String.equal name ".yeokcham")
              || is_ignored ignore_rules child_relative
            then scan_entries reversed rest
            else
              let child_path = Filename.concat directory name in
              let* stat = lstat ~operation:"lstat" child_path in
              let* path = model_path child_relative in
              if stat.Unix.st_kind = Unix.S_DIR then
                let* children = scan_directory child_relative child_path in
                scan_entries
                  (List.rev_append children
                     (Model.Directory_path path :: reversed))
                  rest
              else if stat.Unix.st_kind = Unix.S_REG then
                let* content =
                  read_regular_file ~limit:max_snapshot_bytes child_path stat
                in
                let mode =
                  if stat.Unix.st_perm land 0o111 = 0 then Model.Regular
                  else Model.Executable
                in
                scan_entries
                  (Model.File_path (path, { Model.mode; content }) :: reversed)
                  rest
              else if stat.Unix.st_kind = Unix.S_LNK then
                let* target =
                  try Ok (Unix.readlink child_path)
                  with Unix.Unix_error (error, _, _) ->
                    Error
                      (io_error ~operation:"readlink" ~path:child_path error)
                in
                scan_entries
                  (Model.File_path
                     (path, { Model.mode = Model.Symlink; content = target })
                  :: reversed)
                  rest
              else
                Error
                  (Unsupported_file_type
                     { path = child_path; kind = node_kind stat.Unix.st_kind })
      in
      scan_entries [] names
    in
    let* entries = scan_directory [] root in
    let* snapshot =
      Model.Snapshot.of_entries entries
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let size = String.length (Model.Snapshot.canonical_bytes snapshot) in
    if size > max_snapshot_bytes then
      Error (Snapshot_too_large { size; limit = max_snapshot_bytes })
    else Ok snapshot
