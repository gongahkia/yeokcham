module Health = Yeokcham_v1_health

type error =
  | Health_error of Health.refusal
  | Invalid_plan_id of string
  | Metadata_missing of string
  | Invalid_metadata_path of string
  | Plan_collision of string
  | Not_found of string
  | Io_error of { operation : string; path : string; message : string }

let ( let* ) = Result.bind

let error_to_string = function
  | Health_error refusal -> Health.refusal_to_string refusal
  | Invalid_plan_id id -> "invalid V1 repair plan identifier: " ^ id
  | Metadata_missing path -> "V1 metadata directory is missing: " ^ path
  | Invalid_metadata_path path -> "invalid V1 repair metadata path: " ^ path
  | Plan_collision path ->
      "V1 repair plan path contains different bytes: " ^ path
  | Not_found id -> "V1 repair plan is absent: " ^ id
  | Io_error { operation; path; message } ->
      Printf.sprintf "V1 repair plan %s %s: %s" operation path message

let directory ~root =
  Filename.concat (Filename.concat root ".yeokcham") "repair-plans"

let file_name id = "v1-repair-plan-" ^ id ^ ".cbor"

let path ~root ~id =
  if Health.valid_digest id then
    Ok (Filename.concat (directory ~root) (file_name id))
  else Error (Invalid_plan_id id)

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

let metadata_directory ~root = Filename.concat root ".yeokcham"

let ensure_directory ~root =
  let metadata = metadata_directory ~root in
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

let read_file path =
  try
    if (Unix.lstat path).Unix.st_kind <> Unix.S_REG then
      Error (Invalid_metadata_path path)
    else Ok (In_channel.with_open_bin path In_channel.input_all)
  with
  | Unix.Unix_error (error, _, _) -> Error (io_error "read" path error)
  | Sys_error message -> Error (Io_error { operation = "read"; path; message })

let write_new path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let output = Unix.out_channel_of_descr descriptor in
    Fun.protect
      ~finally:(fun () -> close_out_noerr output)
      (fun () ->
        Out_channel.output_string output bytes;
        Out_channel.flush output;
        Unix.fsync descriptor);
    fsync_directory (Filename.dirname path)
  with
  | Unix.Unix_error (error, _, _) -> Error (io_error "create" path error)
  | Sys_error message -> Error (Io_error { operation = "write"; path; message })

let append ~root plan =
  let* () = ensure_directory ~root in
  let id = Health.plan_id plan in
  let* target = path ~root ~id in
  let bytes = Health.encode_plan plan in
  if Sys.file_exists target then
    let* existing = read_file target in
    if String.equal existing bytes then Ok () else Error (Plan_collision target)
  else write_new target bytes

let find ~root ~id =
  let* target = path ~root ~id in
  if not (Sys.file_exists target) then Error (Not_found id)
  else
    let* bytes = read_file target in
    let* plan =
      Health.decode_plan bytes
      |> Result.map_error (fun error -> Health_error error)
    in
    if String.equal id (Health.plan_id plan) then Ok plan
    else Error (Invalid_plan_id id)

let id_from_file_name name =
  let prefix = "v1-repair-plan-" in
  let suffix = ".cbor" in
  if String.starts_with ~prefix name && String.ends_with ~suffix name then
    let length =
      String.length name - String.length prefix - String.length suffix
    in
    if length = 64 then
      let id = String.sub name (String.length prefix) length in
      if Health.valid_digest id then Some id else None
    else None
  else None

let scan ~root =
  let target = directory ~root in
  try
    if not (Sys.file_exists target) then Ok []
    else if (Unix.lstat target).Unix.st_kind <> Unix.S_DIR then
      Error (Invalid_metadata_path target)
    else
      let names =
        Sys.readdir target |> Array.to_list |> List.sort String.compare
      in
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | name :: rest -> (
            match id_from_file_name name with
            | None ->
                Error (Invalid_metadata_path (Filename.concat target name))
            | Some id ->
                let* plan = find ~root ~id in
                loop (plan :: reversed) rest)
      in
      loop [] names
  with Unix.Unix_error (error, _, _) -> Error (io_error "scan" target error)
