module Encoding = Yeokcham_encoding
module Ledger = Yeokcham_v2_ledger
module Snapshot = Yeokcham_model.Snapshot

type kind = Ledger_event | Scratch_snapshot
type t = Ledger_event_frame of Ledger.t | Scratch_snapshot_frame of Snapshot.t

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unknown_kind of int64
  | Ledger_error of Ledger.error
  | Snapshot_error of Yeokcham_model.canonical_decode_error
  | Noncanonical_frame

let current_schema_version = 1L
let supported_mandatory_features = 0L
let max_payload_bytes = 128 * 1024 * 1024
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_payload detail -> "invalid V2 typed object frame: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 typed object frame version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 typed object frame mandatory features: %Ld"
        features
  | Unsupported_mandatory_features features ->
      Printf.sprintf
        "unsupported V2 typed object frame mandatory features: %Ld" features
  | Unknown_kind kind -> Printf.sprintf "unknown V2 typed object kind: %Ld" kind
  | Ledger_error error -> Ledger.error_to_string error
  | Snapshot_error error -> Yeokcham_model.canonical_decode_error_to_string error
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
      Error (Invalid_payload (Printf.sprintf "%s has the wrong field count" name))
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

let kind = function
  | Ledger_event_frame _ -> Ledger_event
  | Scratch_snapshot_frame _ -> Scratch_snapshot

let ledger = function Ledger_event_frame event -> Some event | _ -> None
let snapshot = function Scratch_snapshot_frame snapshot -> Some snapshot | _ -> None

let kind_code = function Ledger_event -> 0L | Scratch_snapshot -> 1L

let payload = function
  | Ledger_event_frame event -> Ledger.encode event
  | Scratch_snapshot_frame snapshot -> Snapshot.canonical_bytes snapshot

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
  match value with Ok value -> Encoding.encode value | Error error -> invalid_arg (error_to_string error)

let decode_payload kind payload =
  if String.length payload > max_payload_bytes then
    Error (Invalid_payload "payload exceeds the V2 object-frame limit")
  else
    match kind with
    | Ledger_event ->
        Ledger.decode payload
        |> Result.map ledger_event
        |> Result.map_error (fun error -> Ledger_error error)
    | Scratch_snapshot ->
        Snapshot.decode_canonical_bytes payload
        |> Result.map scratch_snapshot
        |> Result.map_error (fun error -> Snapshot_error error)

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
          | value -> Error (Unknown_kind value)
        in
        let* payload = bytes "V2 typed object frame payload" payload in
        let* features = integer "V2 typed object frame mandatory features" features in
        let* () = check_mandatory_features features in
        let* frame = decode_payload kind payload in
        if String.equal encoded (encode frame) then Ok frame
        else Error Noncanonical_frame
  | _ -> assert false
