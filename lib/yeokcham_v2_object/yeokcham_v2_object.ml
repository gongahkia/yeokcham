module Encoding = Yeokcham_encoding
module Ledger = Yeokcham_v2_ledger
module Retention = Yeokcham_v2_retention
module Snapshot = Yeokcham_model.Snapshot
module Capsule = Yeokcham_v2_capsule
module Workspace_record = Yeokcham_v2_workspace_record

type kind =
  | Ledger_event
  | Scratch_snapshot
  | Scratch_protection
  | Scratch_generation
  | Capsule
  | Capsule_revision
  | Workspace
  | Workspace_revision
  | Workspace_attempt
  | Conflict
  | Resolution

type t =
  | Ledger_event_frame of Ledger.t
  | Scratch_snapshot_frame of Snapshot.t
  | Scratch_protection_frame of Retention.protection
  | Scratch_generation_frame of Retention.generation
  | Capsule_frame of Capsule.capsule
  | Capsule_revision_frame of Capsule.revision
  | Workspace_frame of Workspace_record.workspace
  | Workspace_revision_frame of Workspace_record.workspace_revision
  | Workspace_attempt_frame of Workspace_record.workspace_attempt
  | Conflict_frame of Workspace_record.conflict
  | Resolution_frame of Workspace_record.resolution

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unknown_kind of int64
  | Ledger_error of Ledger.error
  | Retention_error of Retention.error
  | Capsule_error of Capsule.error
  | Workspace_record_error of Workspace_record.error
  | Snapshot_error of Yeokcham_model.canonical_decode_error
  | Noncanonical_frame

let current_schema_version = 1L
let supported_mandatory_features = 0L

(* Keep the encoded frame below ADR-045's envelope plaintext limit.  Sixty-four
   bytes is deliberately more than the fixed frame fields and their largest
   canonical CBOR headers. *)
let max_payload_bytes = (128 * 1024 * 1024) - 64
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_payload detail -> "invalid V2 typed object frame: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 typed object frame version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 typed object frame mandatory features: %Ld"
        features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported V2 typed object frame mandatory features: %Ld"
        features
  | Unknown_kind kind -> Printf.sprintf "unknown V2 typed object kind: %Ld" kind
  | Ledger_error error -> Ledger.error_to_string error
  | Retention_error error -> Retention.error_to_string error
  | Capsule_error error -> Capsule.error_to_string error
  | Workspace_record_error error -> Workspace_record.error_to_string error
  | Snapshot_error error ->
      Yeokcham_model.canonical_decode_error_to_string error
  | Noncanonical_frame -> "V2 typed object frame is noncanonical"

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_payload (Printf.sprintf "%s has the wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be bytes"))

let ledger_event event = Ledger_event_frame event
let scratch_snapshot snapshot = Scratch_snapshot_frame snapshot
let scratch_protection protection = Scratch_protection_frame protection
let scratch_generation generation = Scratch_generation_frame generation
let capsule capsule = Capsule_frame capsule
let capsule_revision revision = Capsule_revision_frame revision
let workspace workspace = Workspace_frame workspace
let workspace_revision revision = Workspace_revision_frame revision
let workspace_attempt attempt = Workspace_attempt_frame attempt
let conflict conflict = Conflict_frame conflict
let resolution resolution = Resolution_frame resolution

let kind = function
  | Ledger_event_frame _ -> Ledger_event
  | Scratch_snapshot_frame _ -> Scratch_snapshot
  | Scratch_protection_frame _ -> Scratch_protection
  | Scratch_generation_frame _ -> Scratch_generation
  | Capsule_frame _ -> Capsule
  | Capsule_revision_frame _ -> Capsule_revision
  | Workspace_frame _ -> Workspace
  | Workspace_revision_frame _ -> Workspace_revision
  | Workspace_attempt_frame _ -> Workspace_attempt
  | Conflict_frame _ -> Conflict
  | Resolution_frame _ -> Resolution

let ledger = function
  | Ledger_event_frame event -> Some event
  | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_frame _ | Capsule_revision_frame _ ->
      None
  | Workspace_frame _ | Workspace_revision_frame _ | Workspace_attempt_frame _
  | Conflict_frame _ | Resolution_frame _ ->
      None

let snapshot = function
  | Ledger_event_frame _ -> None
  | Scratch_snapshot_frame snapshot -> Some snapshot
  | Scratch_protection_frame _ | Scratch_generation_frame _ | Capsule_frame _
  | Capsule_revision_frame _ | Workspace_frame _ | Workspace_revision_frame _
  | Workspace_attempt_frame _ | Conflict_frame _ | Resolution_frame _ ->
      None

let protection = function
  | Scratch_protection_frame protection -> Some protection
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_generation_frame _
  | Capsule_frame _ | Capsule_revision_frame _ | Workspace_frame _
  | Workspace_revision_frame _ | Workspace_attempt_frame _ | Conflict_frame _
  | Resolution_frame _ ->
      None

let generation = function
  | Scratch_generation_frame generation -> Some generation
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Capsule_frame _ | Capsule_revision_frame _ | Workspace_frame _
  | Workspace_revision_frame _ | Workspace_attempt_frame _ | Conflict_frame _
  | Resolution_frame _ ->
      None

let capsule_record = function
  | Capsule_frame capsule -> Some capsule
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_revision_frame _ | Workspace_frame _
  | Workspace_revision_frame _ | Workspace_attempt_frame _ | Conflict_frame _
  | Resolution_frame _ ->
      None

let capsule_revision_record = function
  | Capsule_revision_frame revision -> Some revision
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_frame _ | Workspace_frame _
  | Workspace_revision_frame _ | Workspace_attempt_frame _ | Conflict_frame _
  | Resolution_frame _ ->
      None

let workspace_record = function
  | Workspace_frame workspace -> Some workspace
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_frame _ | Capsule_revision_frame _
  | Workspace_revision_frame _ | Workspace_attempt_frame _ | Conflict_frame _
  | Resolution_frame _ ->
      None

let workspace_revision_record = function
  | Workspace_revision_frame revision -> Some revision
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_frame _ | Capsule_revision_frame _
  | Workspace_frame _ | Workspace_attempt_frame _ | Conflict_frame _
  | Resolution_frame _ ->
      None

let workspace_attempt_record = function
  | Workspace_attempt_frame attempt -> Some attempt
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_frame _ | Capsule_revision_frame _
  | Workspace_frame _ | Workspace_revision_frame _ | Conflict_frame _
  | Resolution_frame _ ->
      None

let conflict_record = function
  | Conflict_frame conflict -> Some conflict
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_frame _ | Capsule_revision_frame _
  | Workspace_frame _ | Workspace_revision_frame _ | Workspace_attempt_frame _
  | Resolution_frame _ ->
      None

let resolution_record = function
  | Resolution_frame resolution -> Some resolution
  | Ledger_event_frame _ | Scratch_snapshot_frame _ | Scratch_protection_frame _
  | Scratch_generation_frame _ | Capsule_frame _ | Capsule_revision_frame _
  | Workspace_frame _ | Workspace_revision_frame _ | Workspace_attempt_frame _
  | Conflict_frame _ ->
      None

let kind_code = function
  | Ledger_event -> 0L
  | Scratch_snapshot -> 1L
  | Scratch_protection -> 2L
  | Scratch_generation -> 3L
  | Capsule -> 4L
  | Capsule_revision -> 5L
  | Workspace -> 6L
  | Workspace_revision -> 7L
  | Workspace_attempt -> 8L
  | Conflict -> 9L
  | Resolution -> 10L

let payload = function
  | Ledger_event_frame event -> Ledger.encode event
  | Scratch_snapshot_frame snapshot -> Snapshot.canonical_bytes snapshot
  | Scratch_protection_frame protection ->
      Retention.encode_protection protection
  | Scratch_generation_frame generation ->
      Retention.encode_generation generation
  | Capsule_frame capsule -> Capsule.encode_capsule capsule
  | Capsule_revision_frame revision -> Capsule.encode_revision revision
  | Workspace_frame workspace -> Workspace_record.encode_workspace workspace
  | Workspace_revision_frame revision ->
      Workspace_record.encode_workspace_revision revision
  | Workspace_attempt_frame attempt ->
      Workspace_record.encode_workspace_attempt attempt
  | Conflict_frame conflict -> Workspace_record.encode_conflict conflict
  | Resolution_frame resolution -> Workspace_record.encode_resolution resolution

let encode frame =
  let value =
    array
      [
        Encoding.integer current_schema_version;
        Encoding.integer (kind_code (kind frame));
        Encoding.bytes (payload frame);
        Encoding.integer supported_mandatory_features;
      ]
  in
  match value with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let decode_payload kind payload =
  if String.length payload > max_payload_bytes then
    Error (Invalid_payload "payload exceeds the V2 object-frame limit")
  else
    match kind with
    | Ledger_event ->
        Ledger.decode payload |> Result.map ledger_event
        |> Result.map_error (fun error -> Ledger_error error)
    | Scratch_snapshot ->
        Snapshot.decode_canonical_bytes payload
        |> Result.map scratch_snapshot
        |> Result.map_error (fun error -> Snapshot_error error)
    | Scratch_protection ->
        Retention.decode_protection payload
        |> Result.map scratch_protection
        |> Result.map_error (fun error -> Retention_error error)
    | Scratch_generation ->
        Retention.decode_generation payload
        |> Result.map scratch_generation
        |> Result.map_error (fun error -> Retention_error error)
    | Capsule ->
        Capsule.decode_capsule payload
        |> Result.map capsule
        |> Result.map_error (fun error -> Capsule_error error)
    | Capsule_revision ->
        Capsule.decode_revision payload
        |> Result.map capsule_revision
        |> Result.map_error (fun error -> Capsule_error error)
    | Workspace ->
        Workspace_record.decode_workspace payload
        |> Result.map workspace
        |> Result.map_error (fun error -> Workspace_record_error error)
    | Workspace_revision ->
        Workspace_record.decode_workspace_revision payload
        |> Result.map workspace_revision
        |> Result.map_error (fun error -> Workspace_record_error error)
    | Workspace_attempt ->
        Workspace_record.decode_workspace_attempt payload
        |> Result.map workspace_attempt
        |> Result.map_error (fun error -> Workspace_record_error error)
    | Conflict ->
        Workspace_record.decode_conflict payload
        |> Result.map conflict
        |> Result.map_error (fun error -> Workspace_record_error error)
    | Resolution ->
        Workspace_record.decode_resolution payload
        |> Result.map resolution
        |> Result.map_error (fun error -> Workspace_record_error error)

let decode encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "V2 typed object frame" 4 value in
  match values with
  | [ version; kind_value; payload; features ] ->
      let* version = integer "V2 typed object frame version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* kind_value = integer "V2 typed object frame kind" kind_value in
        let* kind =
          match kind_value with
          | 0L -> Ok Ledger_event
          | 1L -> Ok Scratch_snapshot
          | 2L -> Ok Scratch_protection
          | 3L -> Ok Scratch_generation
          | 4L -> Ok Capsule
          | 5L -> Ok Capsule_revision
          | 6L -> Ok Workspace
          | 7L -> Ok Workspace_revision
          | 8L -> Ok Workspace_attempt
          | 9L -> Ok Conflict
          | 10L -> Ok Resolution
          | value -> Error (Unknown_kind value)
        in
        let* payload = bytes "V2 typed object frame payload" payload in
        let* features =
          integer "V2 typed object frame mandatory features" features
        in
        let* () = check_mandatory_features features in
        let* frame = decode_payload kind payload in
        if String.equal encoded (encode frame) then Ok frame
        else Error Noncanonical_frame
  | _ -> assert false
