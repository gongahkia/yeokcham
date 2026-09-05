module Encoding = Yeokcham_encoding
module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust

type projection_basis = {
  basis_repository_value : Trust.Repository_id.t;
  basis_imported_basis_id_value : string;
  basis_snapshot_value : Model.Snapshot_id.t;
  basis_canonical_tree_value : string;
  basis_source_fingerprint_value : string;
}

type workspace_projection_receipt = {
  receipt_repository_value : Trust.Repository_id.t;
  receipt_imported_basis_id_value : string;
  receipt_snapshot_value : Model.Snapshot_id.t;
  receipt_canonical_tree_value : string;
  receipt_activation_generation_value : int64;
  receipt_source_fingerprint_value : string;
}

type observed_tree = {
  observed_canonical_tree : string;
  observed_source_fingerprint : string;
}

type staged_receipt = {
  staged_temporary : string;
  staged_target : string;
  staged_was_present : bool;
}

type closure = Closure_complete | Closure_missing

type destination =
  | Destination_empty
  | Destination_nonempty
  | Destination_unsafe

type refusal =
  | Nonempty_destination
  | Dirty_workspace
  | Missing_closure
  | No_verified_basis
  | Receipt_mismatch
  | Unsafe_path

type materialization_plan = {
  materialization_basis : projection_basis;
  materialization_receipt : workspace_projection_receipt;
  requires_safety_checkpoint : bool;
}

type update_plan =
  | Already_current of workspace_projection_receipt
  | Update of materialization_plan

type error =
  | Invalid_basis_id of string
  | Invalid_tree_id of string
  | Invalid_source_fingerprint of string
  | Source_fingerprint_mismatch
  | Invalid_generation of int64
  | Encoding_error of Encoding.construction_error
  | Decode_error of Encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | Basis_collision of string
  | Receipt_collision of string
  | Io_error of { operation : string; path : string; message : string }

let schema_version = 1L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_basis_id value -> "invalid V1 projection basis identifier: " ^ value
  | Invalid_tree_id value -> "invalid V1 projection tree identifier: " ^ value
  | Invalid_source_fingerprint value ->
      "invalid V1 projection source fingerprint: " ^ value
  | Source_fingerprint_mismatch ->
      "V1 projection source fingerprint does not bind the canonical tree"
  | Invalid_generation value ->
      Printf.sprintf "invalid V1 workspace activation generation: %Ld" value
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error error -> Encoding.decode_error_to_string error
  | Invalid_schema detail -> "invalid V1 workspace record: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V1 workspace record version: %Ld" version
  | Noncanonical_bytes -> "V1 workspace record is not canonically encoded"
  | Basis_collision path ->
      "V1 projection basis path contains different bytes: " ^ path
  | Receipt_collision path ->
      "V1 pending projection receipt contains different bytes: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message

let refusal_to_string = function
  | Nonempty_destination ->
      "workspace destination contains ordinary source entries"
  | Dirty_workspace ->
      "workspace contains bytes that do not match its activation receipt"
  | Missing_closure ->
      "workspace projection snapshot closure is missing or corrupt"
  | No_verified_basis -> "workspace has no verified imported projection basis"
  | Receipt_mismatch -> "workspace activation receipt is absent or incompatible"
  | Unsafe_path -> "workspace materialisation plan contains an unsafe path"

let valid_sha256 value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let validate_tree canonical_tree =
  if valid_sha256 canonical_tree then Ok ()
  else Error (Invalid_tree_id canonical_tree)

let validate_fingerprint source_fingerprint =
  if valid_sha256 source_fingerprint then Ok ()
  else Error (Invalid_source_fingerprint source_fingerprint)

let make_projection_basis ~repository ~imported_basis_id ~snapshot
    ~canonical_tree ~source_fingerprint =
  if not (valid_sha256 imported_basis_id) then
    Error (Invalid_basis_id imported_basis_id)
  else
    let* () = validate_tree canonical_tree in
    let* () = validate_fingerprint source_fingerprint in
    if not (String.equal canonical_tree source_fingerprint) then
      Error Source_fingerprint_mismatch
    else
      Ok
        {
          basis_repository_value = repository;
          basis_imported_basis_id_value = imported_basis_id;
          basis_snapshot_value = snapshot;
          basis_canonical_tree_value = canonical_tree;
          basis_source_fingerprint_value = source_fingerprint;
        }

let basis_repository basis = basis.basis_repository_value
let basis_imported_basis_id basis = basis.basis_imported_basis_id_value
let basis_snapshot basis = basis.basis_snapshot_value
let basis_canonical_tree basis = basis.basis_canonical_tree_value
let basis_source_fingerprint basis = basis.basis_source_fingerprint_value

let make_observed_tree ~canonical_tree ~source_fingerprint =
  let* () = validate_tree canonical_tree in
  let* () = validate_fingerprint source_fingerprint in
  if not (String.equal canonical_tree source_fingerprint) then
    Error Source_fingerprint_mismatch
  else
    Ok
      {
        observed_canonical_tree = canonical_tree;
        observed_source_fingerprint = source_fingerprint;
      }

let observed_canonical_tree observed = observed.observed_canonical_tree
let observed_source_fingerprint observed = observed.observed_source_fingerprint

let make_receipt ~(basis : projection_basis) ~activation_generation =
  if Int64.compare activation_generation 1L < 0 then
    Error (Invalid_generation activation_generation)
  else
    Ok
      {
        receipt_repository_value = basis.basis_repository_value;
        receipt_imported_basis_id_value = basis.basis_imported_basis_id_value;
        receipt_snapshot_value = basis.basis_snapshot_value;
        receipt_canonical_tree_value = basis.basis_canonical_tree_value;
        receipt_activation_generation_value = activation_generation;
        receipt_source_fingerprint_value = basis.basis_source_fingerprint_value;
      }

let receipt_repository receipt = receipt.receipt_repository_value
let receipt_imported_basis_id receipt = receipt.receipt_imported_basis_id_value
let receipt_snapshot receipt = receipt.receipt_snapshot_value
let receipt_canonical_tree receipt = receipt.receipt_canonical_tree_value

let receipt_activation_generation receipt =
  receipt.receipt_activation_generation_value

let receipt_source_fingerprint receipt =
  receipt.receipt_source_fingerprint_value

let plan_basis plan = plan.materialization_basis
let plan_receipt plan = plan.materialization_receipt
let plan_requires_safety_checkpoint plan = plan.requires_safety_checkpoint

let make_plan ~basis ~generation ~requires_safety_checkpoint =
  match make_receipt ~basis ~activation_generation:generation with
  | Error _ -> Error Receipt_mismatch
  | Ok receipt ->
      Ok
        {
          materialization_basis = basis;
          materialization_receipt = receipt;
          requires_safety_checkpoint;
        }

let activate ~basis ~closure ~destination =
  match basis with
  | None -> Error No_verified_basis
  | Some _ when closure = Closure_missing -> Error Missing_closure
  | Some _ when destination = Destination_nonempty -> Error Nonempty_destination
  | Some _ when destination = Destination_unsafe -> Error Unsafe_path
  | Some basis ->
      make_plan ~basis ~generation:1L ~requires_safety_checkpoint:false

let receipt_matches_basis receipt basis =
  Trust.Repository_id.equal receipt.receipt_repository_value
    basis.basis_repository_value
  && String.equal receipt.receipt_imported_basis_id_value
       basis.basis_imported_basis_id_value

let observed_matches_receipt observed receipt =
  String.equal observed.observed_canonical_tree
    receipt.receipt_canonical_tree_value
  && String.equal observed.observed_source_fingerprint
       receipt.receipt_source_fingerprint_value

let plan_update ~basis ~receipt ~closure ~observed ~replace =
  match (basis, receipt) with
  | None, _ -> Error No_verified_basis
  | Some _, None -> Error Receipt_mismatch
  | Some _, Some _ when closure = Closure_missing -> Error Missing_closure
  | Some basis, Some receipt when not (receipt_matches_basis receipt basis) ->
      Error Receipt_mismatch
  | Some basis, Some receipt ->
      let clean = observed_matches_receipt observed receipt in
      if (not clean) && not replace then Error Dirty_workspace
      else if
        clean
        && Model.Snapshot_id.equal receipt.receipt_snapshot_value
             basis.basis_snapshot_value
        && String.equal receipt.receipt_canonical_tree_value
             basis.basis_canonical_tree_value
        && String.equal receipt.receipt_source_fingerprint_value
             basis.basis_source_fingerprint_value
      then Ok (Already_current receipt)
      else
        let generation =
          Int64.succ receipt.receipt_activation_generation_value
        in
        make_plan ~basis ~generation ~requires_safety_checkpoint:(not clean)
        |> Result.map (fun plan -> Update plan)

let construction value =
  value |> Result.map_error (fun error -> Encoding_error error)

let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

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

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_schema (Printf.sprintf "%s has the wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let encode_basis basis =
  let* repository =
    text (Trust.Repository_id.to_string basis.basis_repository_value)
  in
  let* imported_basis_id = text basis.basis_imported_basis_id_value in
  let* snapshot =
    text (Model.Snapshot_id.to_string basis.basis_snapshot_value)
  in
  let* canonical_tree = text basis.basis_canonical_tree_value in
  let* source_fingerprint = text basis.basis_source_fingerprint_value in
  array
    [
      Encoding.integer schema_version;
      repository;
      imported_basis_id;
      snapshot;
      canonical_tree;
      source_fingerprint;
    ]
  |> Result.map Encoding.encode

let encode_receipt receipt =
  let* repository =
    text (Trust.Repository_id.to_string receipt.receipt_repository_value)
  in
  let* imported_basis_id = text receipt.receipt_imported_basis_id_value in
  let* snapshot =
    text (Model.Snapshot_id.to_string receipt.receipt_snapshot_value)
  in
  let* canonical_tree = text receipt.receipt_canonical_tree_value in
  let* source_fingerprint = text receipt.receipt_source_fingerprint_value in
  array
    [
      Encoding.integer schema_version;
      repository;
      imported_basis_id;
      snapshot;
      canonical_tree;
      Encoding.integer receipt.receipt_activation_generation_value;
      source_fingerprint;
    ]
  |> Result.map Encoding.encode

let decoded_repository value =
  let* value = decoded_text "repository identifier" value in
  Trust.Repository_id.of_string value
  |> Result.map_error (fun detail -> Invalid_schema detail)

let decoded_snapshot value =
  let* value = decoded_text "snapshot identifier" value in
  Model.Snapshot_id.of_string value
  |> Result.map_error (fun error ->
      Invalid_schema (Model.error_to_string error))

let decode_basis bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error (fun error -> Decode_error error)
  in
  let* fields = exact_array "projection basis" 6 value in
  match fields with
  | [
   version;
   repository;
   imported_basis_id;
   snapshot;
   canonical_tree;
   source_fingerprint;
  ] ->
      let* version = decoded_integer "projection basis version" version in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* repository = decoded_repository repository in
        let* imported_basis_id =
          decoded_text "imported basis identifier" imported_basis_id
        in
        let* snapshot = decoded_snapshot snapshot in
        let* canonical_tree =
          decoded_text "canonical tree identifier" canonical_tree
        in
        let* source_fingerprint =
          decoded_text "source fingerprint" source_fingerprint
        in
        let* basis =
          make_projection_basis ~repository ~imported_basis_id ~snapshot
            ~canonical_tree ~source_fingerprint
        in
        let* canonical = encode_basis basis in
        if String.equal canonical bytes then Ok basis
        else Error Noncanonical_bytes
  | _ -> assert false

let decode_receipt bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error (fun error -> Decode_error error)
  in
  let* fields = exact_array "workspace projection receipt" 7 value in
  match fields with
  | [
   version;
   repository;
   imported_basis_id;
   snapshot;
   canonical_tree;
   generation;
   source_fingerprint;
  ] ->
      let* version =
        decoded_integer "workspace projection receipt version" version
      in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* repository = decoded_repository repository in
        let* imported_basis_id =
          decoded_text "imported basis identifier" imported_basis_id
        in
        let* snapshot = decoded_snapshot snapshot in
        let* canonical_tree =
          decoded_text "canonical tree identifier" canonical_tree
        in
        let* activation_generation =
          decoded_integer "activation generation" generation
        in
        let* source_fingerprint =
          decoded_text "source fingerprint" source_fingerprint
        in
        let* basis =
          make_projection_basis ~repository ~imported_basis_id ~snapshot
            ~canonical_tree ~source_fingerprint
        in
        let* receipt = make_receipt ~basis ~activation_generation in
        let* canonical = encode_receipt receipt in
        if String.equal canonical bytes then Ok receipt
        else Error Noncanonical_bytes
  | _ -> assert false

let workspace_directory root =
  Filename.concat (Filename.concat root ".yeokcham") "workspace"

let basis_path ~root =
  Filename.concat (workspace_directory root) "projection-basis-v1.cbor"

let receipt_path ~root =
  Filename.concat (workspace_directory root) "projection-receipt-v1.cbor"

let pending_receipt_path ~root = receipt_path ~root ^ ".pending"

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
             ("workspace metadata path is not a directory: " ^ directory))
    else (
      Unix.mkdir directory 0o700;
      fsync_directory (Filename.dirname directory))
  with Unix.Unix_error (error, _, _) ->
    Error (io_error "mkdir" directory error)

let read_file path =
  try
    if (Unix.lstat path).Unix.st_kind <> Unix.S_REG then
      Error (Invalid_schema ("workspace record is not a regular file: " ^ path))
    else Ok (In_channel.with_open_bin path In_channel.input_all)
  with
  | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)
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

let write_basis ~root basis =
  let* () = ensure_directory (workspace_directory root) in
  let* bytes = encode_basis basis in
  let target = basis_path ~root in
  if Sys.file_exists target then
    let* existing = read_file target in
    if String.equal existing bytes then Ok ()
    else Error (Basis_collision target)
  else write_new target bytes

let read_optional ~path decode =
  if not (Sys.file_exists path) then Ok None
  else
    let* bytes = read_file path in
    decode bytes |> Result.map Option.some

let read_basis ~root = read_optional ~path:(basis_path ~root) decode_basis
let temporary_path target = target ^ ".pending"

let stage_receipt ~root receipt =
  let* () = ensure_directory (workspace_directory root) in
  let* bytes = encode_receipt receipt in
  let target = receipt_path ~root in
  let temporary = temporary_path target in
  if Sys.file_exists temporary then
    let* existing = read_file temporary in
    if String.equal existing bytes then
      Ok
        {
          staged_temporary = temporary;
          staged_target = target;
          staged_was_present = true;
        }
    else Error (Receipt_collision temporary)
  else
    let* () = write_new temporary bytes in
    Ok
      {
        staged_temporary = temporary;
        staged_target = target;
        staged_was_present = false;
      }

let publish_staged_receipt staged =
  try
    Unix.rename staged.staged_temporary staged.staged_target;
    fsync_directory (Filename.dirname staged.staged_target)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error "rename" staged.staged_target error)

let discard_staged_receipt staged =
  if not staged.staged_was_present then
    try Unix.unlink staged.staged_temporary with Unix.Unix_error _ -> ()

let write_receipt ~root receipt =
  let* staged = stage_receipt ~root receipt in
  match publish_staged_receipt staged with
  | Ok () -> Ok ()
  | Error error ->
      discard_staged_receipt staged;
      Error error

let read_receipt ~root = read_optional ~path:(receipt_path ~root) decode_receipt

let read_staged_receipt ~root =
  read_optional ~path:(pending_receipt_path ~root) decode_receipt

let receipt_equal left right =
  Trust.Repository_id.equal left.receipt_repository_value
    right.receipt_repository_value
  && String.equal left.receipt_imported_basis_id_value
       right.receipt_imported_basis_id_value
  && Model.Snapshot_id.equal left.receipt_snapshot_value
       right.receipt_snapshot_value
  && String.equal left.receipt_canonical_tree_value
       right.receipt_canonical_tree_value
  && Int64.equal left.receipt_activation_generation_value
       right.receipt_activation_generation_value
  && String.equal left.receipt_source_fingerprint_value
       right.receipt_source_fingerprint_value
