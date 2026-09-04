module Hook = Yeokcham_v4_hook

type error =
  | Hook_error of Hook.error
  | Metadata_missing of string
  | Invalid_metadata_path of string
  | Io_error of { operation : string; path : string; message : string }

let ( let* ) = Result.bind

let error_to_string = function
  | Hook_error error -> Hook.error_to_string error
  | Metadata_missing path -> "V4 metadata directory is missing: " ^ path
  | Invalid_metadata_path path -> "invalid V4 hooks metadata path: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "V4 hooks %s %s: %s" operation path message

let directory ~root = Filename.concat (Filename.concat root ".yeokcham") "hooks"
let path ~root = Filename.concat (directory ~root) "hooks-v1.cbor"

let io_error operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let fsync_directory directory =
  try
    let descriptor = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () -> Unix.fsync descriptor);
    Ok ()
  with
  | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _) ->
      Ok ()
  | Unix.Unix_error (error, _, _) ->
      Error (io_error "fsync directory" directory error)

let ensure_directory ~root =
  let metadata = Filename.concat root ".yeokcham" in
  let target = directory ~root in
  try
    if not (Sys.file_exists metadata) then Error (Metadata_missing metadata)
    else if (Unix.lstat metadata).Unix.st_kind <> Unix.S_DIR then
      Error (Invalid_metadata_path metadata)
    else if Sys.file_exists target then
      if (Unix.lstat target).Unix.st_kind = Unix.S_DIR then Ok ()
      else Error (Invalid_metadata_path target)
    else (
      Unix.mkdir target 0o700;
      fsync_directory metadata)
  with Unix.Unix_error (error, _, _) -> Error (io_error "mkdir" target error)

let read_file target =
  try
    if (Unix.lstat target).Unix.st_kind <> Unix.S_REG then
      Error (Invalid_metadata_path target)
    else Ok (In_channel.with_open_bin target In_channel.input_all)
  with
  | Unix.Unix_error (error, _, _) -> Error (io_error "read" target error)
  | Sys_error message ->
      Error (Io_error { operation = "read"; path = target; message })

let load ~root =
  let target = path ~root in
  if not (Sys.file_exists target) then Ok Hook.empty
  else
    let* bytes = read_file target in
    Hook.decode bytes |> Result.map_error (fun error -> Hook_error error)

let write_temporary target bytes =
  let directory = Filename.dirname target in
  let temporary =
    Filename.concat directory
      (".hooks-v1.cbor.tmp-" ^ string_of_int (Unix.getpid ()))
  in
  try
    let descriptor =
      Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let output = Unix.out_channel_of_descr descriptor in
    Fun.protect
      ~finally:(fun () -> close_out_noerr output)
      (fun () ->
        Out_channel.output_string output bytes;
        Out_channel.flush output;
        Unix.fsync descriptor);
    Ok temporary
  with Unix.Unix_error (error, _, _) ->
    Error (io_error "create temporary" temporary error)

let save ~root registry =
  let* () = ensure_directory ~root in
  let target = path ~root in
  let bytes = Hook.encode registry in
  let* temporary = write_temporary target bytes in
  try
    Unix.rename temporary target;
    fsync_directory (Filename.dirname target)
  with Unix.Unix_error (error, _, _) -> Error (io_error "rename" target error)
