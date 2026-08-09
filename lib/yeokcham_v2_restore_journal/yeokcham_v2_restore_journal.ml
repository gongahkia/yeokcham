module Encoding = Yeokcham_encoding
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

type phase = Prepared | Applying of int | Materialized | Published

type t = {
  repository_id : Model.Repository_id.t;
  operation_id : Model.Transaction_id.t;
  safety_event_id : Ledger.Event_id.t;
  safety_snapshot : Model.Opaque_object_ref.t;
  target_snapshot : Model.Opaque_object_ref.t;
  generation : int64;
  phase : phase;
  action_count : int;
  mandatory_features : int64;
}

type journal_file = {
  file_operation_id : Model.Transaction_id.t;
  file_generation : int64;
}

type error =
  | Nonpositive_action_count of int
  | Too_many_actions of int
  | Identical_snapshot_references
  | Invalid_generation of int64
  | Generation_exhausted
  | Invalid_progress of { completed : int; action_count : int }
  | Invalid_phase_for_generation of { phase : phase; generation : int64 }
  | Invalid_transition of { previous : phase; next : phase }
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Unknown_phase of int64
  | Invalid_payload of string
  | Noncanonical_record
  | Invalid_journal_filename of string
  | Invalid_chain of string

let current_schema_version = 1L
let supported_mandatory_features = 0L
let max_actions = 1_000_000
let max_record_bytes = 4096
let journal_filename_prefix = "restore-"
let journal_filename_suffix = ".cbor"
let ( let* ) = Result.bind

let phase_to_string = function
  | Prepared -> "prepared"
  | Applying completed -> Printf.sprintf "applying(%d)" completed
  | Materialized -> "materialized"
  | Published -> "published"

let error_to_string = function
  | Nonpositive_action_count count ->
      Printf.sprintf "V2 restore journal action count must be positive, got %d"
        count
  | Too_many_actions count ->
      Printf.sprintf "V2 restore journal action count %d exceeds %d" count
        max_actions
  | Identical_snapshot_references ->
      "V2 restore journal safety and target snapshots must differ"
  | Invalid_generation generation ->
      Printf.sprintf "invalid V2 restore journal generation: %Ld" generation
  | Generation_exhausted -> "V2 restore journal generation is exhausted"
  | Invalid_progress { completed; action_count } ->
      Printf.sprintf
        "V2 restore journal completed action count %d is outside 0..%d"
        completed action_count
  | Invalid_phase_for_generation { phase; generation } ->
      Printf.sprintf "V2 restore journal phase %s is invalid at generation %Ld"
        (phase_to_string phase) generation
  | Invalid_transition { previous; next } ->
      Printf.sprintf "invalid V2 restore journal transition: %s -> %s"
        (phase_to_string previous) (phase_to_string next)
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 restore journal mandatory feature bits: %Ld"
        features
  | Unsupported_mandatory_features features ->
      Printf.sprintf
        "unsupported V2 restore journal mandatory feature bits: %Ld" features
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 restore journal schema version: %Ld"
        version
  | Unknown_phase phase ->
      Printf.sprintf "unknown V2 restore journal phase: %Ld" phase
  | Invalid_payload detail -> "invalid V2 restore journal record: " ^ detail
  | Noncanonical_record -> "V2 restore journal record is noncanonical"
  | Invalid_journal_filename name ->
      "invalid V2 restore journal filename: " ^ name
  | Invalid_chain detail -> "invalid V2 restore journal chain: " ^ detail

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let check_action_count action_count =
  if action_count <= 0 then Error (Nonpositive_action_count action_count)
  else if action_count > max_actions then Error (Too_many_actions action_count)
  else Ok ()

let completed_actions_for action_count = function
  | Prepared -> 0
  | Applying completed -> completed
  | Materialized | Published -> action_count

let check_phase ~generation ~phase ~action_count =
  let completed = completed_actions_for action_count phase in
  if Int64.compare generation 0L < 0 then Error (Invalid_generation generation)
  else if completed < 0 || completed > action_count then
    Error (Invalid_progress { completed; action_count })
  else
    match phase with
    | Prepared when Int64.equal generation 0L -> Ok ()
    | Prepared -> Error (Invalid_phase_for_generation { phase; generation })
    | Applying _ when Int64.compare generation 1L >= 0 -> Ok ()
    | (Materialized | Published) when Int64.compare generation 1L >= 0 -> Ok ()
    | Applying _ | Materialized | Published ->
        Error (Invalid_phase_for_generation { phase; generation })

let make_record ~repository_id ~operation_id ~safety_event_id ~safety_snapshot
    ~target_snapshot ~generation ~phase ~action_count ~mandatory_features =
  let* () = check_action_count action_count in
  let* () = check_mandatory_features mandatory_features in
  if Model.Opaque_object_ref.equal safety_snapshot target_snapshot then
    Error Identical_snapshot_references
  else
    let* () = check_phase ~generation ~phase ~action_count in
    Ok
      {
        repository_id;
        operation_id;
        safety_event_id;
        safety_snapshot;
        target_snapshot;
        generation;
        phase;
        action_count;
        mandatory_features;
      }

let make_prepared ~repository_id ~operation_id ~safety_event_id ~safety_snapshot
    ~target_snapshot ~action_count ~mandatory_features =
  make_record ~repository_id ~operation_id ~safety_event_id ~safety_snapshot
    ~target_snapshot ~generation:0L ~phase:Prepared ~action_count
    ~mandatory_features

let repository_id record = record.repository_id
let operation_id record = record.operation_id
let safety_event_id record = record.safety_event_id
let safety_snapshot record = record.safety_snapshot
let target_snapshot record = record.target_snapshot
let generation record = record.generation
let phase record = record.phase
let action_count record = record.action_count

let completed_actions record =
  completed_actions_for record.action_count record.phase

let filename record =
  Printf.sprintf "%s%s-%016Lx%s" journal_filename_prefix
    (Model.Transaction_id.to_hex record.operation_id)
    record.generation journal_filename_suffix

let journal_file_operation_id file = file.file_operation_id
let journal_file_generation file = file.file_generation

let hexadecimal_value = function
  | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
  | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
  | _ -> None

let nonnegative_int64_of_fixed_hex encoded =
  if
    String.length encoded <> 16
    ||
    match hexadecimal_value encoded.[0] with
    | Some value -> value > 7
    | None -> true
  then Error ()
  else
    let rec decode offset result =
      if offset = String.length encoded then Ok result
      else
        match hexadecimal_value encoded.[offset] with
        | None -> Error ()
        | Some value ->
            decode (offset + 1)
              Int64.(logor (shift_left result 4) (of_int value))
    in
    decode 0 0L

let parse_filename name =
  let prefix_length = String.length journal_filename_prefix in
  let suffix_length = String.length journal_filename_suffix in
  let operation_length = Model.Transaction_id.byte_length * 2 in
  let generation_length = 16 in
  let expected_length =
    prefix_length + operation_length + 1 + generation_length + suffix_length
  in
  if
    String.length name <> expected_length
    || (not (String.starts_with ~prefix:journal_filename_prefix name))
    || (not (String.ends_with ~suffix:journal_filename_suffix name))
    || name.[prefix_length + operation_length] <> '-'
  then Error (Invalid_journal_filename name)
  else
    let operation = String.sub name prefix_length operation_length in
    let generation =
      String.sub name (prefix_length + operation_length + 1) generation_length
    in
    let* operation_id =
      Model.Transaction_id.of_hex operation
      |> Result.map_error (fun _ -> Invalid_journal_filename name)
    in
    let* generation =
      nonnegative_int64_of_fixed_hex generation
      |> Result.map_error (fun () -> Invalid_journal_filename name)
    in
    Ok { file_operation_id = operation_id; file_generation = generation }

let is_journal_filename name =
  String.starts_with ~prefix:journal_filename_prefix name

let is_decimal value =
  String.length value > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) value

let is_temporary_journal_filename name =
  if not (String.starts_with ~prefix:"." name) then false
  else
    let body = String.sub name 1 (String.length name - 1) in
    match String.split_on_char '.' body with
    | [ stem; "cbor"; temporary ] -> (
        match String.split_on_char '-' temporary with
        | [ "tmp"; process; attempt ] ->
            is_decimal process && is_decimal attempt
            && Result.is_ok (parse_filename (stem ^ journal_filename_suffix))
        | _ -> false)
    | _ -> false

let phase_code = function
  | Prepared -> 0L
  | Applying _ -> 1L
  | Materialized -> 2L
  | Published -> 3L

let legal_next record next =
  (match (record.phase, next) with
  | Prepared, Applying 0 -> true
  | Applying completed, Applying next_completed ->
      next_completed = completed + 1 && next_completed <= record.action_count
  | Applying completed, Materialized -> completed = record.action_count
  | Materialized, Published -> true
  | _ -> false)
  [@warning "-4"]

let advance record next =
  if not (legal_next record next) then
    Error (Invalid_transition { previous = record.phase; next })
  else if Int64.equal record.generation Int64.max_int then
    Error Generation_exhausted
  else
    make_record ~repository_id:record.repository_id
      ~operation_id:record.operation_id ~safety_event_id:record.safety_event_id
      ~safety_snapshot:record.safety_snapshot
      ~target_snapshot:record.target_snapshot
      ~generation:(Int64.succ record.generation)
      ~phase:next ~action_count:record.action_count
      ~mandatory_features:record.mandatory_features

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

let integer_of_count name value =
  if
    Int64.compare value 0L < 0
    || Int64.compare value (Int64.of_int max_actions) > 0
  then Error (Invalid_payload (name ^ " is outside the supported range"))
  else Ok (Int64.to_int value)

let value record =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Repository_id.to_bytes record.repository_id);
      Encoding.bytes (Model.Transaction_id.to_bytes record.operation_id);
      Encoding.bytes (Ledger.Event_id.to_bytes record.safety_event_id);
      Encoding.bytes (Model.Opaque_object_ref.to_bytes record.safety_snapshot);
      Encoding.bytes (Model.Opaque_object_ref.to_bytes record.target_snapshot);
      Encoding.integer record.generation;
      Encoding.integer (phase_code record.phase);
      Encoding.integer (Int64.of_int (completed_actions record));
      Encoding.integer (Int64.of_int record.action_count);
      Encoding.integer record.mandatory_features;
    ]

let encode record =
  match value record with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let identity name of_bytes bytes =
  of_bytes bytes
  |> Result.map_error (fun _ ->
      Invalid_payload (name ^ " has an invalid byte length"))

let phase_of_fields ~code ~completed ~action_count =
  match code with
  | 0L when completed = 0 -> Ok Prepared
  | 0L -> Error (Invalid_progress { completed; action_count })
  | 1L -> Ok (Applying completed)
  | 2L when completed = action_count -> Ok Materialized
  | 3L when completed = action_count -> Ok Published
  | 2L | 3L -> Error (Invalid_progress { completed; action_count })
  | code -> Error (Unknown_phase code)

let decode encoded =
  if String.length encoded > max_record_bytes then
    Error (Invalid_payload "record exceeds its bounded size")
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "V2 restore journal" 11 value in
    match values with
    | [
     version;
     repository_id;
     operation_id;
     safety_event_id;
     safety_snapshot;
     target_snapshot;
     generation;
     phase_code;
     completed_actions;
     action_count;
     mandatory_features;
    ] ->
        let* version = integer "V2 restore journal version" version in
        if not (Int64.equal version current_schema_version) then
          Error (Unsupported_schema_version version)
        else
          let* repository_id =
            bytes "V2 restore journal repository ID" repository_id
          in
          let* repository_id =
            identity "V2 restore journal repository ID"
              Model.Repository_id.of_bytes repository_id
          in
          let* operation_id =
            bytes "V2 restore journal operation ID" operation_id
          in
          let* operation_id =
            identity "V2 restore journal operation ID"
              Model.Transaction_id.of_bytes operation_id
          in
          let* safety_event_id =
            bytes "V2 restore journal safety event ID" safety_event_id
          in
          let* safety_event_id =
            identity "V2 restore journal safety event ID"
              Ledger.Event_id.of_bytes safety_event_id
          in
          let* safety_snapshot =
            bytes "V2 restore journal safety snapshot" safety_snapshot
          in
          let* safety_snapshot =
            identity "V2 restore journal safety snapshot"
              Model.Opaque_object_ref.of_bytes safety_snapshot
          in
          let* target_snapshot =
            bytes "V2 restore journal target snapshot" target_snapshot
          in
          let* target_snapshot =
            identity "V2 restore journal target snapshot"
              Model.Opaque_object_ref.of_bytes target_snapshot
          in
          let* generation =
            integer "V2 restore journal generation" generation
          in
          let* phase_code = integer "V2 restore journal phase" phase_code in
          let* completed_actions =
            integer "V2 restore journal completed actions" completed_actions
          in
          let* completed_actions =
            integer_of_count "V2 restore journal completed actions"
              completed_actions
          in
          let* action_count =
            integer "V2 restore journal action count" action_count
          in
          let* action_count =
            integer_of_count "V2 restore journal action count" action_count
          in
          let* mandatory_features =
            integer "V2 restore journal mandatory features" mandatory_features
          in
          let* phase =
            phase_of_fields ~code:phase_code ~completed:completed_actions
              ~action_count
          in
          let* record =
            make_record ~repository_id ~operation_id ~safety_event_id
              ~safety_snapshot ~target_snapshot ~generation ~phase ~action_count
              ~mandatory_features
          in
          if String.equal encoded (encode record) then Ok record
          else Error Noncanonical_record
    | _ -> assert false

let validate_chain records =
  let rec loop previous = function
    | [] -> Ok ()
    | current :: rest -> (
        match advance previous (phase current) with
        | Error error -> Error (Invalid_chain (error_to_string error))
        | Ok expected ->
            if String.equal (encode expected) (encode current) then
              loop current rest
            else
              Error
                (Invalid_chain
                   "a successor does not retain the previous record bindings"))
  in
  match records with
  | [] -> Ok ()
  | first :: rest ->
      if not (Int64.equal (generation first) 0L) then
        Error (Invalid_chain "the first generation is not zero")
      else if phase first <> Prepared then
        Error (Invalid_chain "generation zero is not prepared")
      else loop first rest
