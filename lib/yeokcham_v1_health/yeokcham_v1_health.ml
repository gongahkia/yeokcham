module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

type damage_code =
  | Missing_object
  | Malformed_envelope
  | Canonical_id_mismatch
  | Dangling_reference
  | Unreadable_durable_record
  | Restore_proof_mismatch
  | Unreachable_temporary_state

type blocked_operation =
  | Verify
  | Repair_plan
  | Repair_apply
  | Restore
  | Workspace
  | Compaction
  | Temporary_recovery

type durable_record_kind =
  | State_head
  | Restore_proof
  | Workspace_receipt
  | Gc_transaction
  | Repair_plan_record

type temporary_state_kind =
  | Restore_temporary
  | Gc_temporary
  | Transfer_temporary
  | Repair_temporary

type affected =
  | Object of string
  | Durable_record of durable_record_kind * string
  | Temporary_state of temporary_state_kind * string

type damage = {
  damage_code_value : damage_code;
  damage_affected_value : affected;
  damage_blocked_operations_value : blocked_operation list;
}

type report = { report_damages_value : damage list }
type object_status = Present | Missing | Malformed | Id_mismatch of string

type observation =
  | Object_observation of {
      object_id : string;
      status : object_status;
      references : string list;
    }
  | Durable_observation of {
      durable_kind : durable_record_kind;
      durable_id : string;
      readable : bool;
      restore_mismatch : bool;
    }
  | Temporary_observation of {
      temporary_kind : temporary_state_kind;
      temporary_id : string;
      reachable : bool;
    }

type repair_source =
  | Gc_quarantine of string
  | Offline_package of string
  | Configured_relay of string
  | Bootstrap_artifact of string
  | Backup of string

type repair_candidate = {
  candidate_id_value : string;
  candidate_object_id_value : string;
  candidate_bytes_id_value : string;
  candidate_source_value : repair_source;
}

type repair_plan = {
  plan_id_value : string;
  plan_repository_value : string;
  plan_state_head_value : string;
  plan_source_value : repair_source;
  plan_damages_value : damage list;
  plan_candidates_value : repair_candidate list;
  plan_created_at_value : int64;
  plan_expires_at_value : int64;
}

type selection = {
  selection_plan_id : string;
  selection_candidate_id : string;
  selection_approved_digest : string;
}

type refusal =
  | Invalid_identifier of string
  | Invalid_locator of string
  | Duplicate_observation of string
  | No_damage
  | Invalid_expiry of { created_at : int64; expires_at : int64 }
  | Candidate_source_mismatch
  | Candidate_not_missing
  | Plan_expired
  | Plan_id_mismatch
  | Plan_digest_mismatch
  | Candidate_not_in_plan
  | Candidate_changed
  | State_head_changed
  | Damage_changed
  | Destination_no_longer_missing

type repair_outcome = Eligible of repair_candidate | Refused of refusal

let schema_version = 1L
let ( let* ) = Result.bind

let damage_code_to_string = function
  | Missing_object -> "missing-object"
  | Malformed_envelope -> "malformed-envelope"
  | Canonical_id_mismatch -> "canonical-id-mismatch"
  | Dangling_reference -> "dangling-reference"
  | Unreadable_durable_record -> "unreadable-durable-record"
  | Restore_proof_mismatch -> "restore-proof-mismatch"
  | Unreachable_temporary_state -> "unreachable-temporary-state"

let blocked_operation_to_string = function
  | Verify -> "verify"
  | Repair_plan -> "repair-plan"
  | Repair_apply -> "repair-apply"
  | Restore -> "restore"
  | Workspace -> "workspace"
  | Compaction -> "compaction"
  | Temporary_recovery -> "temporary-recovery"

let refusal_to_string = function
  | Invalid_identifier value -> "invalid V1 health identifier: " ^ value
  | Invalid_locator value -> "invalid V1 repair source locator: " ^ value
  | Duplicate_observation value -> "duplicate V1 health observation: " ^ value
  | No_damage -> "repair planning requires at least one diagnosed damage"
  | Invalid_expiry { created_at; expires_at } ->
      Printf.sprintf "invalid V1 repair plan expiry %Ld..%Ld" created_at
        expires_at
  | Candidate_source_mismatch ->
      "repair candidate does not originate at the plan's explicit source"
  | Candidate_not_missing ->
      "repair candidate is not an exact candidate for a missing object"
  | Plan_expired -> "repair plan has expired"
  | Plan_id_mismatch -> "repair selection names another plan"
  | Plan_digest_mismatch -> "repair approval does not match the exact plan"
  | Candidate_not_in_plan -> "repair selection names no candidate in the plan"
  | Candidate_changed -> "repair source candidate changed after planning"
  | State_head_changed -> "V1 state head changed after repair planning"
  | Damage_changed -> "repair diagnosis changed after planning"
  | Destination_no_longer_missing ->
      "repair destination is no longer the exact missing object"

let repair_source_to_string = function
  | Gc_quarantine value -> "gc-quarantine:" ^ value
  | Offline_package value -> "offline-package:" ^ value
  | Configured_relay value -> "configured-relay:" ^ value
  | Bootstrap_artifact value -> "bootstrap-artifact:" ^ value
  | Backup value -> "backup:" ^ value

let valid_digest value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let valid_locator value =
  String.length value > 0
  && String.length value <= 4096
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          value)

let check_digest value =
  if valid_digest value then Ok () else Error (Invalid_identifier value)

let source_locator = function
  | Gc_quarantine value
  | Offline_package value
  | Configured_relay value
  | Bootstrap_artifact value
  | Backup value ->
      value

let check_source source =
  let locator = source_locator source in
  if valid_locator locator then Ok () else Error (Invalid_locator locator)

let damage_code damage = damage.damage_code_value
let damage_affected damage = damage.damage_affected_value
let damage_blocked_operations damage = damage.damage_blocked_operations_value
let report_damages report = report.report_damages_value
let report_is_clean report = report.report_damages_value = []

let code_rank = function
  | Missing_object -> 0
  | Malformed_envelope -> 1
  | Canonical_id_mismatch -> 2
  | Dangling_reference -> 3
  | Unreadable_durable_record -> 4
  | Restore_proof_mismatch -> 5
  | Unreachable_temporary_state -> 6

let durable_rank = function
  | State_head -> 0
  | Restore_proof -> 1
  | Workspace_receipt -> 2
  | Gc_transaction -> 3
  | Repair_plan_record -> 4

let temporary_rank = function
  | Restore_temporary -> 0
  | Gc_temporary -> 1
  | Transfer_temporary -> 2
  | Repair_temporary -> 3

let compare_affected left right =
  match (left, right) with
  | Object left, Object right -> String.compare left right
  | Object _, (Durable_record _ | Temporary_state _) -> -1
  | (Durable_record _ | Temporary_state _), Object _ -> 1
  | Durable_record (left_kind, left_id), Durable_record (right_kind, right_id)
    ->
      let kind =
        Int.compare (durable_rank left_kind) (durable_rank right_kind)
      in
      if kind = 0 then String.compare left_id right_id else kind
  | Durable_record _, Temporary_state _ -> -1
  | Temporary_state _, Durable_record _ -> 1
  | Temporary_state (left_kind, left_id), Temporary_state (right_kind, right_id)
    ->
      let kind =
        Int.compare (temporary_rank left_kind) (temporary_rank right_kind)
      in
      if kind = 0 then String.compare left_id right_id else kind

let compare_damage left right =
  let code =
    Int.compare
      (code_rank left.damage_code_value)
      (code_rank right.damage_code_value)
  in
  if code = 0 then
    compare_affected left.damage_affected_value right.damage_affected_value
  else code

let normalize_operations operations =
  let rank = function
    | Verify -> 0
    | Repair_plan -> 1
    | Repair_apply -> 2
    | Restore -> 3
    | Workspace -> 4
    | Compaction -> 5
    | Temporary_recovery -> 6
  in
  List.sort_uniq
    (fun left right -> Int.compare (rank left) (rank right))
    operations

let make_damage code affected operations =
  {
    damage_code_value = code;
    damage_affected_value = affected;
    damage_blocked_operations_value = normalize_operations operations;
  }

let missing_operations =
  [ Verify; Repair_plan; Repair_apply; Restore; Workspace; Compaction ]

let record_operations =
  [ Verify; Repair_plan; Repair_apply; Restore; Workspace; Compaction ]

let verify observations =
  let rec validate_objects seen = function
    | [] -> Ok ()
    | Object_observation { object_id; status; references } :: rest ->
        let* () = check_digest object_id in
        if List.mem object_id seen then Error (Duplicate_observation object_id)
        else
          let* () =
            match status with
            | Present | Missing | Malformed -> Ok ()
            | Id_mismatch actual -> check_digest actual
          in
          let rec validate_references = function
            | [] -> Ok ()
            | reference :: remaining ->
                let* () = check_digest reference in
                validate_references remaining
          in
          let* () = validate_references references in
          validate_objects (object_id :: seen) rest
    | Durable_observation { durable_id; _ } :: rest
    | Temporary_observation { temporary_id = durable_id; _ } :: rest ->
        if valid_locator durable_id then validate_objects seen rest
        else Error (Invalid_locator durable_id)
  in
  let* () = validate_objects [] observations in
  let object_state id =
    observations
    |> List.find_map (function
      | Object_observation { object_id; status; _ }
        when String.equal id object_id ->
          Some status
      | Object_observation _ | Durable_observation _ | Temporary_observation _
        ->
          None)
  in
  let rec collect reversed = function
    | [] -> Ok (List.sort_uniq compare_damage reversed)
    | Object_observation { object_id; status; references } :: rest ->
        let direct =
          match status with
          | Present -> []
          | Missing ->
              [
                make_damage Missing_object (Object object_id) missing_operations;
              ]
          | Malformed ->
              [
                make_damage Malformed_envelope (Object object_id)
                  missing_operations;
              ]
          | Id_mismatch _ ->
              [
                make_damage Canonical_id_mismatch (Object object_id)
                  missing_operations;
              ]
        in
        let dangling =
          match status with
          | Present ->
              references
              |> List.filter (fun reference ->
                  match object_state reference with
                  | Some Present -> false
                  | Some Missing | Some Malformed | Some (Id_mismatch _) | None
                    ->
                      true)
              |> List.map (fun reference ->
                  make_damage Dangling_reference (Object reference)
                    [
                      Verify;
                      Repair_plan;
                      Repair_apply;
                      Restore;
                      Workspace;
                      Compaction;
                    ])
          | Missing | Malformed | Id_mismatch _ -> []
        in
        collect
          (List.rev_append direct (List.rev_append dangling reversed))
          rest
    | Durable_observation
        { durable_kind; durable_id; readable; restore_mismatch }
      :: rest ->
        let unreadable =
          if readable then []
          else
            [
              make_damage Unreadable_durable_record
                (Durable_record (durable_kind, durable_id))
                record_operations;
            ]
        in
        let mismatch =
          if restore_mismatch then
            [
              make_damage Restore_proof_mismatch
                (Durable_record (durable_kind, durable_id))
                [ Verify; Repair_plan; Repair_apply; Restore; Compaction ];
            ]
          else []
        in
        collect
          (List.rev_append unreadable (List.rev_append mismatch reversed))
          rest
    | Temporary_observation { temporary_kind; temporary_id; reachable } :: rest
      ->
        let next =
          if reachable then reversed
          else
            make_damage Unreachable_temporary_state
              (Temporary_state (temporary_kind, temporary_id))
              [ Verify; Repair_plan; Repair_apply; Temporary_recovery ]
            :: reversed
        in
        collect next rest
  in
  collect [] observations
  |> Result.map (fun damages -> { report_damages_value = damages })

let source_tag = function
  | Gc_quarantine _ -> "gc-quarantine"
  | Offline_package _ -> "offline-package"
  | Configured_relay _ -> "configured-relay"
  | Bootstrap_artifact _ -> "bootstrap-artifact"
  | Backup _ -> "backup"

let hex_of_raw raw =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length raw * 2)
    (fun index ->
      let byte = Char.code raw.[index / 2] in
      if index mod 2 = 0 then alphabet.[byte lsr 4] else alphabet.[byte land 15])

let sha256 value = Hash.digest_string value |> Hash.to_raw_string |> hex_of_raw

let candidate_material ~source ~object_id ~canonical_bytes_id =
  "yeokcham:v1:repair-candidate:1\000" ^ source_tag source ^ "\000"
  ^ source_locator source ^ "\000" ^ object_id ^ "\000" ^ canonical_bytes_id

let make_candidate ~source ~object_id ~canonical_bytes_id =
  let* () = check_source source in
  let* () = check_digest object_id in
  let* () = check_digest canonical_bytes_id in
  let candidate_id =
    candidate_material ~source ~object_id ~canonical_bytes_id |> sha256
  in
  Ok
    {
      candidate_id_value = candidate_id;
      candidate_object_id_value = object_id;
      candidate_bytes_id_value = canonical_bytes_id;
      candidate_source_value = source;
    }

let candidate_id candidate = candidate.candidate_id_value
let candidate_object_id candidate = candidate.candidate_object_id_value
let candidate_bytes_id candidate = candidate.candidate_bytes_id_value
let candidate_source candidate = candidate.candidate_source_value

let candidate_equal left right =
  String.equal left.candidate_id_value right.candidate_id_value
  && String.equal left.candidate_object_id_value right.candidate_object_id_value
  && String.equal left.candidate_bytes_id_value right.candidate_bytes_id_value
  && left.candidate_source_value = right.candidate_source_value

let candidate_compare left right =
  String.compare left.candidate_id_value right.candidate_id_value

let candidate_targets_missing damages candidate =
  String.equal candidate.candidate_object_id_value
    candidate.candidate_bytes_id_value
  && List.exists
       (fun damage ->
         damage.damage_code_value = Missing_object
         && damage.damage_affected_value
            = Object candidate.candidate_object_id_value)
       damages

let source_code = function
  | Gc_quarantine _ -> 0L
  | Offline_package _ -> 1L
  | Configured_relay _ -> 2L
  | Bootstrap_artifact _ -> 3L
  | Backup _ -> 4L

let source_of_code code locator =
  match code with
  | 0L -> Ok (Gc_quarantine locator)
  | 1L -> Ok (Offline_package locator)
  | 2L -> Ok (Configured_relay locator)
  | 3L -> Ok (Bootstrap_artifact locator)
  | 4L -> Ok (Backup locator)
  | _ -> Error (Invalid_locator "unknown repair source kind")

let code_of_damage_code = function
  | Missing_object -> 0L
  | Malformed_envelope -> 1L
  | Canonical_id_mismatch -> 2L
  | Dangling_reference -> 3L
  | Unreadable_durable_record -> 4L
  | Restore_proof_mismatch -> 5L
  | Unreachable_temporary_state -> 6L

let damage_code_of_code = function
  | 0L -> Ok Missing_object
  | 1L -> Ok Malformed_envelope
  | 2L -> Ok Canonical_id_mismatch
  | 3L -> Ok Dangling_reference
  | 4L -> Ok Unreadable_durable_record
  | 5L -> Ok Restore_proof_mismatch
  | 6L -> Ok Unreachable_temporary_state
  | _ -> Error (Invalid_locator "unknown damage code")

let operation_code = function
  | Verify -> 0L
  | Repair_plan -> 1L
  | Repair_apply -> 2L
  | Restore -> 3L
  | Workspace -> 4L
  | Compaction -> 5L
  | Temporary_recovery -> 6L

let operation_of_code = function
  | 0L -> Ok Verify
  | 1L -> Ok Repair_plan
  | 2L -> Ok Repair_apply
  | 3L -> Ok Restore
  | 4L -> Ok Workspace
  | 5L -> Ok Compaction
  | 6L -> Ok Temporary_recovery
  | _ -> Error (Invalid_locator "unknown blocked operation")

let durable_code = function
  | State_head -> 0L
  | Restore_proof -> 1L
  | Workspace_receipt -> 2L
  | Gc_transaction -> 3L
  | Repair_plan_record -> 4L

let durable_of_code = function
  | 0L -> Ok State_head
  | 1L -> Ok Restore_proof
  | 2L -> Ok Workspace_receipt
  | 3L -> Ok Gc_transaction
  | 4L -> Ok Repair_plan_record
  | _ -> Error (Invalid_locator "unknown durable record kind")

let temporary_code = function
  | Restore_temporary -> 0L
  | Gc_temporary -> 1L
  | Transfer_temporary -> 2L
  | Repair_temporary -> 3L

let temporary_of_code = function
  | 0L -> Ok Restore_temporary
  | 1L -> Ok Gc_temporary
  | 2L -> Ok Transfer_temporary
  | 3L -> Ok Repair_temporary
  | _ -> Error (Invalid_locator "unknown temporary state kind")

let construction =
  Result.map_error (fun _ ->
      Invalid_locator "invalid canonical repair plan text")

let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

let encode_operations operations =
  operations
  |> List.map (fun operation -> Encoding.integer (operation_code operation))
  |> array

let encode_damage damage =
  let* affected_kind, affected_subkind, affected_id =
    match damage.damage_affected_value with
    | Object id -> Ok (0L, 0L, id)
    | Durable_record (kind, id) -> Ok (1L, durable_code kind, id)
    | Temporary_state (kind, id) -> Ok (2L, temporary_code kind, id)
  in
  let* affected_id = text affected_id in
  let* operations = encode_operations damage.damage_blocked_operations_value in
  array
    [
      Encoding.integer (code_of_damage_code damage.damage_code_value);
      Encoding.integer affected_kind;
      Encoding.integer affected_subkind;
      affected_id;
      operations;
    ]

let encode_damages damages =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | damage :: rest ->
        let* damage = encode_damage damage in
        loop (damage :: reversed) rest
  in
  loop [] damages

let encode_candidate candidate =
  let* candidate_id = text candidate.candidate_id_value in
  let* object_id = text candidate.candidate_object_id_value in
  let* bytes_id = text candidate.candidate_bytes_id_value in
  array [ candidate_id; object_id; bytes_id ]

let encode_candidates candidates =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | candidate :: rest ->
        let* candidate = encode_candidate candidate in
        loop (candidate :: reversed) rest
  in
  loop [] candidates

let plan_bytes ~repository ~state_head ~source ~damages ~candidates ~created_at
    ~expires_at =
  let* repository = text repository in
  let* state_head = text state_head in
  let* source_locator = text (source_locator source) in
  let* damages = encode_damages damages in
  let* candidates = encode_candidates candidates in
  array
    [
      Encoding.integer schema_version;
      repository;
      state_head;
      Encoding.integer created_at;
      Encoding.integer expires_at;
      Encoding.integer (source_code source);
      source_locator;
      damages;
      candidates;
    ]
  |> Result.map Encoding.encode

let make_plan ~repository ~state_head ~source ~damages ~candidates ~created_at
    ~expires_at =
  let* () = check_digest repository in
  let* () = check_digest state_head in
  let* () = check_source source in
  if Int64.compare created_at 0L < 0 || Int64.compare expires_at created_at <= 0
  then Error (Invalid_expiry { created_at; expires_at })
  else if damages = [] then Error No_damage
  else
    let damages = List.sort_uniq compare_damage damages in
    let candidates = List.sort_uniq candidate_compare candidates in
    let rec validate_candidates = function
      | [] -> Ok ()
      | candidate :: rest ->
          if candidate.candidate_source_value <> source then
            Error Candidate_source_mismatch
          else if not (candidate_targets_missing damages candidate) then
            Error Candidate_not_missing
          else validate_candidates rest
    in
    let* () = validate_candidates candidates in
    let* bytes =
      plan_bytes ~repository ~state_head ~source ~damages ~candidates
        ~created_at ~expires_at
    in
    let plan_id = sha256 bytes in
    Ok
      {
        plan_id_value = plan_id;
        plan_repository_value = repository;
        plan_state_head_value = state_head;
        plan_source_value = source;
        plan_damages_value = damages;
        plan_candidates_value = candidates;
        plan_created_at_value = created_at;
        plan_expires_at_value = expires_at;
      }

let plan_id plan = plan.plan_id_value
let plan_digest plan = plan.plan_id_value
let plan_repository plan = plan.plan_repository_value
let plan_state_head plan = plan.plan_state_head_value
let plan_source plan = plan.plan_source_value
let plan_damages plan = plan.plan_damages_value
let plan_candidates plan = plan.plan_candidates_value
let plan_created_at plan = plan.plan_created_at_value
let plan_expires_at plan = plan.plan_expires_at_value

let make_selection plan ~candidate_id =
  {
    selection_plan_id = plan.plan_id_value;
    selection_candidate_id = candidate_id;
    selection_approved_digest = plan.plan_id_value;
  }

let damage_equal left right =
  left.damage_code_value = right.damage_code_value
  && left.damage_affected_value = right.damage_affected_value
  && left.damage_blocked_operations_value
     = right.damage_blocked_operations_value

let report_matches_plan plan report =
  let expected = plan.plan_damages_value in
  let actual = report.report_damages_value in
  List.length expected = List.length actual
  && List.for_all2 damage_equal expected actual

let apply_eligibility ~plan ~selection ~now ~current_state_head ~current
    ~reread_candidate =
  if not (String.equal selection.selection_plan_id plan.plan_id_value) then
    Refused Plan_id_mismatch
  else if
    not (String.equal selection.selection_approved_digest plan.plan_id_value)
  then Refused Plan_digest_mismatch
  else if Int64.compare now plan.plan_expires_at_value >= 0 then
    Refused Plan_expired
  else if not (String.equal current_state_head plan.plan_state_head_value) then
    Refused State_head_changed
  else if not (report_matches_plan plan current) then Refused Damage_changed
  else
    match
      List.find_opt
        (fun candidate ->
          String.equal candidate.candidate_id_value
            selection.selection_candidate_id)
        plan.plan_candidates_value
    with
    | None -> Refused Candidate_not_in_plan
    | Some planned -> (
        match reread_candidate with
        | None -> Refused Candidate_changed
        | Some candidate when not (candidate_equal planned candidate) ->
            Refused Candidate_changed
        | Some candidate
          when not
                 (candidate_targets_missing (report_damages current) candidate)
          ->
            Refused Destination_no_longer_missing
        | Some candidate -> Eligible candidate)

let encode_plan plan =
  plan_bytes ~repository:plan.plan_repository_value
    ~state_head:plan.plan_state_head_value ~source:plan.plan_source_value
    ~damages:plan.plan_damages_value ~candidates:plan.plan_candidates_value
    ~created_at:plan.plan_created_at_value
    ~expires_at:plan.plan_expires_at_value
  |> Result.get_ok

let array_values = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_locator "repair plan field must be an array")

let exact_array length value =
  let* values = array_values value in
  if List.length values = length then Ok values
  else Error (Invalid_locator "repair plan has the wrong field count")

let text_value = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_locator "repair plan field must be text")

let integer_value = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_locator "repair plan field must be an integer")

let decode_operations value =
  let* values = array_values value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* value = integer_value value in
        let* operation = operation_of_code value in
        loop (operation :: reversed) rest
  in
  let* operations = loop [] values in
  if operations = normalize_operations operations then Ok operations
  else
    Error (Invalid_locator "repair plan operations are not sorted and unique")

let decode_damage value =
  let* values = exact_array 5 value in
  match values with
  | [ code; affected_kind; affected_subkind; affected_id; operations ] ->
      let* raw_code = integer_value code in
      let* code = damage_code_of_code raw_code in
      let* affected_kind = integer_value affected_kind in
      let* affected_subkind = integer_value affected_subkind in
      let* affected_id = text_value affected_id in
      let* operations = decode_operations operations in
      let* affected =
        match affected_kind with
        | 0L ->
            let* () = check_digest affected_id in
            Ok (Object affected_id)
        | 1L ->
            let* kind = durable_of_code affected_subkind in
            if valid_locator affected_id then
              Ok (Durable_record (kind, affected_id))
            else Error (Invalid_locator affected_id)
        | 2L ->
            let* kind = temporary_of_code affected_subkind in
            if valid_locator affected_id then
              Ok (Temporary_state (kind, affected_id))
            else Error (Invalid_locator affected_id)
        | _ -> Error (Invalid_locator "unknown repair plan affected kind")
      in
      Ok (make_damage code affected operations)
  | _ -> assert false

let decode_damages value =
  let* values = array_values value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* damage = decode_damage value in
        loop (damage :: reversed) rest
  in
  let* damages = loop [] values in
  if damages = List.sort_uniq compare_damage damages then Ok damages
  else
    Error (Invalid_locator "repair plan damage list is not sorted and unique")

let decode_candidate source value =
  let* values = exact_array 3 value in
  match values with
  | [ candidate_id_text; object_id; bytes_id ] ->
      let* candidate_id_text = text_value candidate_id_text in
      let* object_id = text_value object_id in
      let* bytes_id = text_value bytes_id in
      let* candidate =
        make_candidate ~source ~object_id ~canonical_bytes_id:bytes_id
      in
      if String.equal candidate_id_text (candidate_id candidate) then
        Ok candidate
      else Error (Invalid_identifier candidate_id_text)
  | _ -> assert false

let decode_candidates source value =
  let* values = array_values value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* candidate = decode_candidate source value in
        loop (candidate :: reversed) rest
  in
  let* candidates = loop [] values in
  if candidates = List.sort_uniq candidate_compare candidates then Ok candidates
  else
    Error (Invalid_locator "repair plan candidates are not sorted and unique")

let decode_plan bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun _ ->
        Invalid_locator "invalid repair plan encoding")
  in
  let* values = exact_array 9 value in
  match values with
  | [
   version;
   repository;
   state_head;
   created_at;
   expires_at;
   source_kind;
   source_locator;
   damages;
   candidates;
  ] ->
      let* version = integer_value version in
      if not (Int64.equal version schema_version) then
        Error (Invalid_locator "unsupported repair plan schema version")
      else
        let* repository = text_value repository in
        let* state_head = text_value state_head in
        let* created_at = integer_value created_at in
        let* expires_at = integer_value expires_at in
        let* source_kind = integer_value source_kind in
        let* source_locator = text_value source_locator in
        let* source = source_of_code source_kind source_locator in
        let* damages = decode_damages damages in
        let* candidates = decode_candidates source candidates in
        let* plan =
          make_plan ~repository ~state_head ~source ~damages ~candidates
            ~created_at ~expires_at
        in
        if String.equal bytes (encode_plan plan) then Ok plan
        else Error (Invalid_locator "repair plan is not canonically encoded")
  | _ -> assert false
