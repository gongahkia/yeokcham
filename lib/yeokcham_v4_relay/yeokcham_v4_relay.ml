module Store = Yeokcham_store
module Envelope = Yeokcham_envelope
module Transport = Yeokcham_v4_transport

type repository = { root : string }
type kind = Object | Manifest | Publication | Bootstrap

type error =
  | Invalid_repository of string
  | Invalid_identifier of string
  | Invalid_cursor of string
  | Invalid_limit of int
  | Invalid_object of string
  | Already_exists_with_different_bytes of string
  | Missing of string
  | Io_error of { path : string; operation : string; message : string }

let max_body_bytes = 64 * 1024 * 1024
let max_page_size = 128
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_repository value -> "invalid V4 relay repository ID: " ^ value
  | Invalid_identifier value -> "invalid V4 relay object ID: " ^ value
  | Invalid_cursor value -> "invalid V4 relay continuation cursor: " ^ value
  | Invalid_limit value ->
      Printf.sprintf "invalid V4 relay page limit: %d" value
  | Invalid_object detail -> "invalid V4 relay immutable bytes: " ^ detail
  | Already_exists_with_different_bytes id ->
      "V4 relay immutable ID already has different bytes: " ^ id
  | Missing id -> "V4 relay immutable ID is absent: " ^ id
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 relay %s %s: %s" operation path message

let[@warning "-4"] is_missing = function Missing _ -> true | _ -> false

let[@warning "-4"] is_immutable_conflict = function
  | Already_exists_with_different_bytes _ -> true
  | _ -> false

let valid_hex value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let check_project project =
  if valid_hex project then Ok () else Error (Invalid_repository project)

let check_id id = if valid_hex id then Ok () else Error (Invalid_identifier id)

let kind_name = function
  | Object -> "objects"
  | Manifest -> "manifests"
  | Publication -> "publications"
  | Bootstrap -> "bootstraps"

let project_path repository project = Filename.concat repository.root project

let kind_path repository project kind =
  Filename.concat (project_path repository project) (kind_name kind)

let item_path repository project kind id =
  Filename.concat (kind_path repository project kind) id

let mkdir path =
  try
    Unix.mkdir path 0o700;
    Ok ()
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path; operation; message = Unix.error_message error })

let open_repository ~root =
  if Sys.file_exists root then
    try
      if (Unix.lstat root).Unix.st_kind = Unix.S_DIR then Ok { root }
      else
        Error
          (Io_error
             { path = root; operation = "open"; message = "not a directory" })
    with Unix.Unix_error (error, operation, _) ->
      Error
        (Io_error { path = root; operation; message = Unix.error_message error })
  else
    let* () = mkdir root in
    Ok { root }

let read_limited path =
  try
    let info = Unix.lstat path in
    if info.Unix.st_kind <> Unix.S_REG then
      Error (Invalid_object "stored relay entry is not a regular file")
    else if info.Unix.st_size > max_body_bytes then
      Error (Invalid_object "stored relay entry exceeds body limit")
    else In_channel.with_open_bin path In_channel.input_all |> Result.ok
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error (Missing (Filename.basename path))
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path; operation; message = Unix.error_message error })
  | Sys_error message -> Error (Io_error { path; operation = "read"; message })

let validate_bytes kind id bytes =
  if String.length bytes > max_body_bytes then
    Error (Invalid_object "request body exceeds relay limit")
  else
    match kind with
    | Manifest | Publication | Bootstrap ->
        if String.equal (Transport.sha256 bytes) id then Ok ()
        else Error (Invalid_object "route ID does not match SHA-256 bytes")
    | Object ->
        let* object_ =
          Envelope.decode bytes
          |> Result.map_error (fun error ->
              Invalid_object (Envelope.decode_error_to_string error))
        in
        if not (String.equal bytes (Envelope.encode object_)) then
          Error (Invalid_object "object bytes are not canonical")
        else
          let actual =
            Store.id_of_envelope object_ |> Store.Stored_object_id.to_hex
          in
          if String.equal actual id then Ok ()
          else Error (Invalid_object "route ID does not match object identity")

let ensure_kind_path repository project kind =
  let* () = mkdir (project_path repository project) in
  mkdir (kind_path repository project kind)

let write_exclusive path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let rec write offset =
      if offset = String.length bytes then Ok ()
      else
        try
          let count =
            Unix.write_substring descriptor bytes offset
              (String.length bytes - offset)
          in
          if count = 0 then
            Error
              (Io_error
                 { path; operation = "write"; message = "write returned zero" })
          else write (offset + count)
        with Unix.Unix_error (error, operation, _) ->
          Error
            (Io_error { path; operation; message = Unix.error_message error })
    in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () -> write 0)
  with Unix.Unix_error (error, operation, _) ->
    Error (Io_error { path; operation; message = Unix.error_message error })

let create repository ~project ~kind ~id ~bytes =
  let* () = check_project project in
  let* () = check_id id in
  let* () = validate_bytes kind id bytes in
  let* () = ensure_kind_path repository project kind in
  let path = item_path repository project kind id in
  let compare_existing () =
    match read_limited path with
    | Ok existing when String.equal existing bytes -> Ok ()
    | Ok _ -> Error (Already_exists_with_different_bytes id)
    | Error error -> Error error
  in
  if Sys.file_exists path then compare_existing ()
  else
    match write_exclusive path bytes with
    | Ok () -> Ok ()
    | Error error ->
        if Sys.file_exists path then compare_existing () else Error error

let get repository ~project ~kind ~id =
  let* () = check_project project in
  let* () = check_id id in
  let path = item_path repository project kind id in
  let* bytes = read_limited path in
  let* () = validate_bytes kind id bytes in
  Ok bytes

let list_publications repository ~project ~cursor ~limit =
  let* () = check_project project in
  if limit <= 0 || limit > max_page_size then Error (Invalid_limit limit)
  else
    let* () =
      match cursor with
      | None -> Ok ()
      | Some cursor ->
          if valid_hex cursor then Ok () else Error (Invalid_cursor cursor)
    in
    let directory = kind_path repository project Publication in
    let names =
      try Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
      with Sys_error _ -> Ok []
    in
    let* names = names in
    let* () =
      List.fold_left
        (fun result id ->
          let* () = result in
          if valid_hex id then Ok ()
          else
            Error
              (Invalid_object "relay publication directory contains unsafe name"))
        (Ok ()) names
    in
    let after_cursor =
      match cursor with
      | None -> names
      | Some cursor ->
          List.filter (fun id -> String.compare id cursor > 0) names
    in
    let rec take remaining reversed = function
      | [] -> List.rev reversed
      | _ when remaining = 0 -> List.rev reversed
      | id :: rest -> take (remaining - 1) (id :: reversed) rest
    in
    let selected = take limit [] after_cursor in
    let next =
      if List.length after_cursor > List.length selected then
        match List.rev selected with [] -> None | id :: _ -> Some id
      else None
    in
    Ok (selected, next)
