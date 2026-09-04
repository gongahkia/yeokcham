type profile = { requested_path_count : int; requested_logical_bytes : int64 }

type layout = {
  generated_directories : int;
  generated_files : int;
  generated_logical_bytes : int64;
}

type error =
  | Relative_root of string
  | Root_missing of string
  | Root_not_directory of string
  | Root_not_empty of string
  | Path_count_too_small of int
  | Logical_bytes_too_small of { bytes : int64; minimum : int }
  | Io_error of { path : string; operation : string; message : string }

let error_to_string = function
  | Relative_root path -> "fixture root must be absolute: " ^ path
  | Root_missing path -> "fixture root does not exist: " ^ path
  | Root_not_directory path -> "fixture root is not a directory: " ^ path
  | Root_not_empty path -> "fixture root is not empty: " ^ path
  | Path_count_too_small count ->
      Printf.sprintf "fixture path count must be at least two, got %d" count
  | Logical_bytes_too_small { bytes; minimum } ->
      Printf.sprintf
        "fixture logical bytes must be at least the file count (%d), got %Ld"
        minimum bytes
  | Io_error { path; operation; message } ->
      Printf.sprintf "fixture %s failed for %s: %s" operation path message

let profile ~path_count ~logical_bytes =
  { requested_path_count = path_count; requested_logical_bytes = logical_bytes }

let layout_for ({ requested_path_count; requested_logical_bytes } : profile) =
  if requested_path_count < 2 then
    Error (Path_count_too_small requested_path_count)
  else
    let generated_directories = (requested_path_count + 100) / 101 in
    let generated_files = requested_path_count - generated_directories in
    if requested_logical_bytes < Int64.of_int generated_files then
      Error
        (Logical_bytes_too_small
           { bytes = requested_logical_bytes; minimum = generated_files })
    else
      Ok
        {
          generated_directories;
          generated_files;
          generated_logical_bytes = requested_logical_bytes;
        }

let validate = layout_for
let directory_count layout = layout.generated_directories
let file_count layout = layout.generated_files
let logical_bytes layout = layout.generated_logical_bytes

let root_is_empty root =
  try
    let kind = (Unix.lstat root).Unix.st_kind in
    if kind <> Unix.S_DIR then Error (Root_not_directory root)
    else if Array.length (Sys.readdir root) = 0 then Ok ()
    else Error (Root_not_empty root)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error (Root_missing root)
  | Unix.Unix_error (error, operation, _) ->
      Error
        (Io_error { path = root; operation; message = Unix.error_message error })

let is_absolute path = String.length path > 0 && Char.equal path.[0] '/'
let write_all channel bytes length = output channel bytes 0 length

let fill_bytes state bytes length =
  for index = 0 to length - 1 do
    state :=
      Int64.logand
        (Int64.add (Int64.mul !state 1_103_515_245L) 12_345L)
        0x7fff_ffffL;
    Bytes.set bytes index (Char.chr (Int64.to_int (Int64.logand !state 0xffL)))
  done

let file_bytes ~index ~files ~total =
  let quotient = Int64.div total (Int64.of_int files) in
  let remainder = Int64.rem total (Int64.of_int files) in
  if Int64.of_int index < remainder then Int64.succ quotient else quotient

let write_file ~path ~index ~length =
  let buffer = Bytes.create 65_536 in
  let state = ref (Int64.add 0x1f12_3bb5L (Int64.of_int index)) in
  try
    Out_channel.with_open_bin path (fun channel ->
        let remaining = ref length in
        while Int64.compare !remaining 0L > 0 do
          let write_length =
            Int64.min !remaining (Int64.of_int (Bytes.length buffer))
            |> Int64.to_int
          in
          fill_bytes state buffer write_length;
          write_all channel buffer write_length;
          remaining := Int64.sub !remaining (Int64.of_int write_length)
        done)
    |> fun () -> Ok ()
  with
  | Sys_error message -> Error (Io_error { path; operation = "write"; message })
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path; operation; message = Unix.error_message error })

let mkdir path =
  try
    Unix.mkdir path 0o755;
    Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error (Io_error { path; operation; message = Unix.error_message error })

let ( let* ) = Result.bind

let generate ~root profile =
  if not (is_absolute root) then Error (Relative_root root)
  else
    let* layout = validate profile in
    let* () = root_is_empty root in
    let* () =
      List.init layout.generated_directories Fun.id
      |> List.fold_left
           (fun result directory ->
             let* () = result in
             mkdir (Filename.concat root (Printf.sprintf "dir-%05d" directory)))
           (Ok ())
    in
    let* () =
      List.init layout.generated_files Fun.id
      |> List.fold_left
           (fun result index ->
             let* () = result in
             let directory = index / 100 in
             let path =
               Filename.concat
                 (Filename.concat root (Printf.sprintf "dir-%05d" directory))
                 (Printf.sprintf "file-%05d.bin" index)
             in
             write_file ~path ~index
               ~length:
                 (file_bytes ~index ~files:layout.generated_files
                    ~total:layout.generated_logical_bytes))
           (Ok ())
    in
    Ok layout
