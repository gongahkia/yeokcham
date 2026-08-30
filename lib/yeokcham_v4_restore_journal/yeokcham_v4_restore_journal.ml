module Encoding = Yeokcham_encoding
module Model = Yeokcham_v4_model

type phase = Prepared | Applying | Materialized | Published

type t = {
  operation_id : string;
  safety : Model.Snapshot_id.t;
  target : Model.Snapshot_id.t;
  generation : int64;
  phase : phase;
}

type error =
  | Invalid_operation_id of string
  | Identical_snapshots
  | Invalid_generation of int64
  | Invalid_transition of { previous : phase; next : phase }
  | Encoding_error of Encoding.construction_error
  | Decode_error of Encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | Journal_collision of string
  | Io_error of { operation : string; path : string; message : string }

let schema_version = 1L
let ( let* ) = Result.bind

let phase_name = function
  | Prepared -> "prepared"
  | Applying -> "applying"
  | Materialized -> "materialized"
  | Published -> "published"

let error_to_string = function
  | Invalid_operation_id value -> "invalid V4 restore operation id: " ^ value
  | Identical_snapshots ->
      "V4 in-place restore safety and target snapshots are identical"
  | Invalid_generation generation ->
      Printf.sprintf "invalid V4 restore journal generation: %Ld" generation
  | Invalid_transition { previous; next } ->
      Printf.sprintf "invalid V4 restore transition: %s to %s"
        (phase_name previous) (phase_name next)
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error error -> Encoding.decode_error_to_string error
  | Invalid_schema detail -> "invalid V4 restore journal: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V4 restore journal version: %Ld" version
  | Noncanonical_bytes -> "V4 restore journal is not canonically encoded"
  | Journal_collision path ->
      "V4 restore journal path contains different bytes: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message

let valid_operation_id value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let make_prepared ~operation_id ~safety ~target =
  if not (valid_operation_id operation_id) then
    Error (Invalid_operation_id operation_id)
  else if Model.Snapshot_id.equal safety target then Error Identical_snapshots
  else Ok { operation_id; safety; target; generation = 0L; phase = Prepared }

let operation_id journal = journal.operation_id
let safety journal = journal.safety
let target journal = journal.target
let generation journal = journal.generation
let phase journal = journal.phase

let advance journal next =
  let valid =
    match (journal.phase, next) with
    | Prepared, Applying | Applying, Materialized | Materialized, Published ->
        true
    | Prepared, (Prepared | Materialized)
    | Applying, (Prepared | Applying)
    | Materialized, (Prepared | Applying | Materialized)
    | Published, (Prepared | Applying | Materialized | Published)
    | Prepared, Published
    | Applying, Published ->
        false
  in
  if not valid then
    Error (Invalid_transition { previous = journal.phase; next })
  else if Int64.equal journal.generation Int64.max_int then
    Error (Invalid_generation journal.generation)
  else
    Ok { journal with generation = Int64.succ journal.generation; phase = next }

let phase_code = function
  | Prepared -> 0L
  | Applying -> 1L
  | Materialized -> 2L
  | Published -> 3L

let phase_of_code = function
  | 0L -> Ok Prepared
  | 1L -> Ok Applying
  | 2L -> Ok Materialized
  | 3L -> Ok Published
  | value -> Error (Invalid_schema (Printf.sprintf "unknown phase %Ld" value))

let encode journal =
  let* operation =
    Encoding.text journal.operation_id
    |> Result.map_error (fun error -> Encoding_error error)
  in
  let* safety =
    Encoding.text (Model.Snapshot_id.to_string journal.safety)
    |> Result.map_error (fun error -> Encoding_error error)
  in
  let* target =
    Encoding.text (Model.Snapshot_id.to_string journal.target)
    |> Result.map_error (fun error -> Encoding_error error)
  in
  Encoding.array
    [
      Encoding.integer schema_version;
      operation;
      safety;
      target;
      Encoding.integer journal.generation;
      Encoding.integer (phase_code journal.phase);
    ]
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
    | Encoding.Array fields when List.length fields = 6 -> Ok fields
    | Encoding.Array _ ->
        Error (Invalid_schema "record must contain six fields")
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Invalid_schema "record must be an array")
  in
  match fields with
  | [ version; operation; safety; target; generation; phase ] ->
      let* version = decoded_integer "version" version in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* operation_id = decoded_text "operation id" operation in
        let* safety_text = decoded_text "safety snapshot" safety in
        let* target_text = decoded_text "target snapshot" target in
        let* generation = decoded_integer "generation" generation in
        let* phase_code = decoded_integer "phase" phase in
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
        if not (valid_operation_id operation_id) then
          Error (Invalid_operation_id operation_id)
        else if Int64.compare generation 0L < 0 then
          Error (Invalid_generation generation)
        else if Model.Snapshot_id.equal safety target then
          Error Identical_snapshots
        else
          let* phase = phase_of_code phase_code in
          let expected_generation = phase_code in
          if not (Int64.equal generation expected_generation) then
            Error (Invalid_generation generation)
          else
            let journal = { operation_id; safety; target; generation; phase } in
            let* canonical = encode journal in
            if String.equal canonical bytes then Ok journal
            else Error Noncanonical_bytes
  | _ -> assert false

let journal_directory root =
  Filename.concat (Filename.concat root ".yeokcham") "journal"

let filename journal =
  Printf.sprintf "v4-restore-%s-%Ld.cbor" journal.operation_id
    journal.generation

let path root journal =
  Filename.concat (journal_directory root) (filename journal)

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

let read_file path =
  try
    if (Unix.lstat path).Unix.st_kind <> Unix.S_REG then
      Error (Invalid_schema ("journal entry is not a regular file: " ^ path))
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

let append ~root journal =
  let* bytes = encode journal in
  let path = path root journal in
  if Sys.file_exists path then
    let* existing = read_file path in
    if String.equal existing bytes then Ok ()
    else Error (Journal_collision path)
  else write_exclusive path bytes

let is_record_name name =
  String.starts_with ~prefix:"v4-restore-" name
  && String.ends_with ~suffix:".cbor" name

let scan ~root =
  let directory = journal_directory root in
  let names =
    try
      Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
    with
    | Sys_error _ when not (Sys.file_exists directory) -> Ok []
    | Sys_error message ->
        Error (Io_error { operation = "readdir"; path = directory; message })
  in
  let* names = names in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | name :: rest when not (is_record_name name) -> loop reversed rest
    | name :: rest ->
        let* bytes = read_file (Filename.concat directory name) in
        let* journal = decode bytes in
        if not (String.equal name (filename journal)) then
          Error (Invalid_schema "journal filename does not match its record")
        else loop (journal :: reversed) rest
  in
  let* journals = loop [] names in
  let operations =
    List.fold_left
      (fun operations journal ->
        let current =
          Option.value
            (List.assoc_opt journal.operation_id operations)
            ~default:[]
        in
        (journal.operation_id, journal :: current)
        :: List.remove_assoc journal.operation_id operations)
      [] journals
  in
  let validate_operation (_, records) =
    let records =
      List.sort
        (fun left right -> Int64.compare left.generation right.generation)
        records
    in
    let rec follow previous = function
      | [] -> Ok ()
      | next :: rest ->
          let* expected = advance previous next.phase in
          if
            (not (String.equal expected.operation_id next.operation_id))
            || (not (Model.Snapshot_id.equal expected.safety next.safety))
            || (not (Model.Snapshot_id.equal expected.target next.target))
            || not (Int64.equal expected.generation next.generation)
          then Error (Invalid_schema "restore journal chain is not contiguous")
          else follow next rest
    in
    match records with
    | first :: rest
      when Int64.equal first.generation 0L && first.phase = Prepared ->
        follow first rest
    | _ -> Error (Invalid_schema "restore journal chain lacks Prepared")
  in
  let* () =
    List.fold_left
      (fun result operation ->
        let* () = result in
        validate_operation operation)
      (Ok ()) operations
  in
  Ok journals

let latest_by_operation journals =
  List.fold_left
    (fun latest journal ->
      let prior = List.assoc_opt journal.operation_id latest in
      match prior with
      | Some current
        when Int64.compare current.generation journal.generation >= 0 ->
          latest
      | Some _ ->
          (journal.operation_id, journal)
          :: List.remove_assoc journal.operation_id latest
      | None -> (journal.operation_id, journal) :: latest)
    [] journals

let latest_pending ~root =
  let* journals = scan ~root in
  match
    latest_by_operation journals
    |> List.map snd
    |> List.filter (fun journal -> journal.phase <> Published)
  with
  | [] -> Ok None
  | [ journal ] -> Ok (Some journal)
  | _ -> Error (Invalid_schema "multiple restore operations remain incomplete")

let pending_snapshots ~root =
  let* pending = latest_pending ~root in
  match pending with
  | None -> Ok []
  | Some journal ->
      Ok
        (List.sort_uniq Model.Snapshot_id.compare
           [ journal.safety; journal.target ])

let prune_published ~root ~operations =
  let* journals = scan ~root in
  let published =
    latest_by_operation journals
    |> List.filter (fun (_, journal) -> journal.phase = Published)
    |> List.map fst
    |> List.filter (fun operation ->
        List.exists (String.equal operation) operations)
  in
  let rec loop pruned = function
    | [] -> Ok (List.rev pruned)
    | journal :: rest -> (
        if not (List.exists (String.equal journal.operation_id) published) then
          loop pruned rest
        else
          let path = path root journal in
          try
            Unix.unlink path;
            let* () = fsync_directory (journal_directory root) in
            loop (journal.operation_id :: pruned) rest
          with
          | Unix.Unix_error (Unix.ENOENT, _, _) -> loop pruned rest
          | Unix.Unix_error (error, _, _) ->
              Error (io_error "unlink" path error))
  in
  let* pruned = loop [] journals in
  Ok (List.sort_uniq String.compare pruned)
