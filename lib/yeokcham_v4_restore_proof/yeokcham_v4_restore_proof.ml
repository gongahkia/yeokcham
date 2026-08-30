module Encoding = Yeokcham_encoding
module Model = Yeokcham_v4_model

type t = {
  operation_id : string;
  safety : Model.Snapshot_id.t;
  target : Model.Snapshot_id.t;
}

type error =
  | Invalid_operation_id of string
  | Identical_snapshots
  | Encoding_error of Encoding.construction_error
  | Decode_error of Encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | Proof_collision of string
  | Not_found of string
  | Io_error of { operation : string; path : string; message : string }

let schema_version = 1L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_operation_id value -> "invalid V4 restore operation id: " ^ value
  | Identical_snapshots ->
      "V4 restore proof safety and target snapshots are identical"
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error error -> Encoding.decode_error_to_string error
  | Invalid_schema detail -> "invalid V4 restore proof: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V4 restore proof version: %Ld" version
  | Noncanonical_bytes -> "V4 restore proof is not canonically encoded"
  | Proof_collision path ->
      "V4 restore proof path contains different bytes: " ^ path
  | Not_found operation -> "V4 restore proof not found: " ^ operation
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message

let valid_operation_id value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let make ~operation_id ~safety ~target =
  if not (valid_operation_id operation_id) then
    Error (Invalid_operation_id operation_id)
  else if Model.Snapshot_id.equal safety target then Error Identical_snapshots
  else Ok { operation_id; safety; target }

let operation_id proof = proof.operation_id
let safety proof = proof.safety
let target proof = proof.target

let encode proof =
  let text value =
    Encoding.text value |> Result.map_error (fun error -> Encoding_error error)
  in
  let* operation = text proof.operation_id in
  let* safety = text (Model.Snapshot_id.to_string proof.safety) in
  let* target = text (Model.Snapshot_id.to_string proof.target) in
  Encoding.array [ Encoding.integer schema_version; operation; safety; target ]
  |> Result.map Encoding.encode
  |> Result.map_error (fun error -> Encoding_error error)

let decoded_text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be text"))

let decoded_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an integer"))

let decode bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error (fun error -> Decode_error error)
  in
  let* fields =
    match value with
    | Encoding.Array fields when List.length fields = 4 -> Ok fields
    | Encoding.Array _ ->
        Error (Invalid_schema "record must contain four fields")
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Invalid_schema "record must be an array")
  in
  match fields with
  | [ version; operation; safety; target ] ->
      let* version = decoded_integer "version" version in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* operation_id = decoded_text "operation id" operation in
        let* safety_text = decoded_text "safety snapshot" safety in
        let* target_text = decoded_text "target snapshot" target in
        let* safety =
          Model.Snapshot_id.of_string safety_text
          |> Result.map_error (fun error ->
              Invalid_schema (Model.error_to_string error))
        in
        let* target =
          Model.Snapshot_id.of_string target_text
          |> Result.map_error (fun error ->
              Invalid_schema (Model.error_to_string error))
        in
        let* proof = make ~operation_id ~safety ~target in
        let* canonical = encode proof in
        if String.equal canonical bytes then Ok proof
        else Error Noncanonical_bytes
  | _ -> assert false

let proof_directory root =
  Filename.concat (Filename.concat root ".yeokcham") "restore-proofs"

let filename proof =
  Printf.sprintf "v4-restore-proof-%s.cbor" proof.operation_id

let path root proof = Filename.concat (proof_directory root) (filename proof)

let path_for_operation root operation_id =
  Filename.concat (proof_directory root)
    (Printf.sprintf "v4-restore-proof-%s.cbor" operation_id)

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

let ensure_directory directory =
  try
    if Sys.file_exists directory then
      if (Unix.lstat directory).Unix.st_kind = Unix.S_DIR then Ok ()
      else
        Error
          (Invalid_schema
             ("restore proof directory is not a directory: " ^ directory))
    else (
      Unix.mkdir directory 0o700;
      fsync_directory (Filename.dirname directory))
  with Unix.Unix_error (error, _, _) ->
    Error (io_error "mkdir" directory error)

let read_file path =
  try
    if (Unix.lstat path).Unix.st_kind <> Unix.S_REG then
      Error
        (Invalid_schema ("restore proof entry is not a regular file: " ^ path))
    else Ok (In_channel.with_open_bin path In_channel.input_all)
  with
  | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)
  | Sys_error message -> Error (Io_error { operation = "read"; path; message })

let write_exclusive path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let output = Unix.out_channel_of_descr descriptor in
    Fun.protect
      ~finally:(fun () -> close_out_noerr output)
      (fun () ->
        output_string output bytes;
        flush output;
        Unix.fsync descriptor);
    fsync_directory (Filename.dirname path)
  with
  | Unix.Unix_error (error, _, _) -> Error (io_error "create" path error)
  | Sys_error message -> Error (Io_error { operation = "write"; path; message })

let append ~root proof =
  let* () = ensure_directory (proof_directory root) in
  let* bytes = encode proof in
  let target = path root proof in
  if Sys.file_exists target then
    let* existing = read_file target in
    if String.equal existing bytes then Ok ()
    else Error (Proof_collision target)
  else write_exclusive target bytes

let is_record_name name =
  String.starts_with ~prefix:"v4-restore-proof-" name
  && String.ends_with ~suffix:".cbor" name

let scan ~root =
  let directory = proof_directory root in
  let* names =
    try
      Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
    with
    | Sys_error _ when not (Sys.file_exists directory) -> Ok []
    | Sys_error message ->
        Error (Io_error { operation = "readdir"; path = directory; message })
  in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | name :: rest when not (is_record_name name) -> loop reversed rest
    | name :: rest ->
        let* bytes = read_file (Filename.concat directory name) in
        let* proof = decode bytes in
        if not (String.equal name (filename proof)) then
          Error
            (Invalid_schema "restore proof filename does not match its record")
        else loop (proof :: reversed) rest
  in
  loop [] names

let find ~root ~operation_id =
  if not (valid_operation_id operation_id) then
    Error (Invalid_operation_id operation_id)
  else
    let target = path_for_operation root operation_id in
    if not (Sys.file_exists target) then Error (Not_found operation_id)
    else
      let* bytes = read_file target in
      let* proof = decode bytes in
      if String.equal proof.operation_id operation_id then Ok proof
      else
        Error
          (Invalid_schema "restore proof filename does not match its record")

let forget ~root ~operation_id =
  let* proof = find ~root ~operation_id in
  let target = path root proof in
  try
    Unix.unlink target;
    fsync_directory (proof_directory root)
  with Unix.Unix_error (error, _, _) -> Error (io_error "unlink" target error)

let snapshots proofs =
  proofs
  |> List.fold_left
       (fun roots proof -> proof.safety :: proof.target :: roots)
       []
  |> List.sort_uniq Model.Snapshot_id.compare
