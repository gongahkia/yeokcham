module Encoding = Yeokcham_encoding
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

type protection_reason =
  | User_pin
  | Capsule_boundary of Model.Opaque_object_ref.t
  | Release_boundary of Model.Opaque_object_ref.t

type protection_action = Protect | Unprotect

type protection = {
  protected_snapshot_ref : Model.Opaque_object_ref.t;
  protection_action : protection_action;
  protection_reason : protection_reason;
}

type cleanup_kind = Ledger_event | Scratch_snapshot

type cleanup_candidate = {
  candidate_object_ref : Model.Opaque_object_ref.t;
  candidate_kind : cleanup_kind;
}

type generation = {
  active_ref : Ledger.Ref_name.t;
  active_head : Ledger.Event_id.t;
  retired_refs : Ledger.Ref_name.t list;
  cleanup_candidates : cleanup_candidate list;
}

type checkpoint = {
  event_id : Ledger.Event_id.t;
  event_object_ref : Model.Opaque_object_ref.t;
  checkpoint_snapshot_ref : Model.Opaque_object_ref.t;
}

type object_size = {
  sized_object_ref : Model.Opaque_object_ref.t;
  stored_bytes : int64;
}

type policy = { recent_count : int; storage_budget_bytes : int64 option }

type retention_decision =
  | Current_head
  | Protected of protection_reason list
  | Recent
  | Expired
  | Budget_excluded

type planned_checkpoint = {
  checkpoint : checkpoint;
  decision : retention_decision;
}

type plan = {
  retained : planned_checkpoint list;
  excluded : planned_checkpoint list;
  retained_bytes : int64;
  required_overrun : int64 option;
}

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Duplicate_retired_ref of string
  | Empty_retired_refs
  | Active_ref_is_retired of string
  | Duplicate_cleanup_candidate of Model.Opaque_object_ref.t
  | Invalid_recent_count of int
  | Negative_storage_budget of int64
  | Empty_history
  | Duplicate_checkpoint_event of Ledger.Event_id.t
  | Duplicate_checkpoint_object of Model.Opaque_object_ref.t
  | Duplicate_object_size of Model.Opaque_object_ref.t
  | Negative_object_size of {
      object_ref : Model.Opaque_object_ref.t;
      bytes : int64;
    }
  | Missing_object_size of Model.Opaque_object_ref.t
  | Size_overflow
  | Cleanup_kind_collision of Model.Opaque_object_ref.t

let schema_version = 1L
let supported_mandatory_features = 0L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_payload detail -> "invalid V2 retention record: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 retention record version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 retention mandatory features: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported V2 retention mandatory features: %Ld" features
  | Duplicate_retired_ref ref_name ->
      "V2 retention generation repeats retired ref: " ^ ref_name
  | Empty_retired_refs -> "V2 retention generation has no retired source ref"
  | Active_ref_is_retired ref_name ->
      "V2 retention generation retires its active ref: " ^ ref_name
  | Duplicate_cleanup_candidate object_ref ->
      "V2 retention generation repeats cleanup object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Invalid_recent_count count ->
      Printf.sprintf "V2 retention recent count must be nonnegative, got %d"
        count
  | Negative_storage_budget bytes ->
      Printf.sprintf "V2 retention storage budget must be nonnegative, got %Ld"
        bytes
  | Empty_history -> "V2 retention requires a nonempty causal scratch history"
  | Duplicate_checkpoint_event event_id ->
      "V2 retention history repeats event: " ^ Ledger.Event_id.to_hex event_id
  | Duplicate_checkpoint_object object_ref ->
      "V2 retention history repeats event object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Duplicate_object_size object_ref ->
      "V2 retention size map repeats object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Negative_object_size { object_ref; bytes } ->
      Printf.sprintf "V2 retention object %s has negative size %Ld"
        (Model.Opaque_object_ref.to_hex object_ref)
        bytes
  | Missing_object_size object_ref ->
      "V2 retention has no exact stored size for object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Size_overflow -> "V2 retention stored-byte total overflows int64"
  | Cleanup_kind_collision object_ref ->
      "V2 retention cleanup object has incompatible expected kinds: "
      ^ Model.Opaque_object_ref.to_hex object_ref

let protection ~snapshot_ref ~action ~reason : protection =
  {
    protected_snapshot_ref = snapshot_ref;
    protection_action = action;
    protection_reason = reason;
  }

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let encoded_text value =
  Encoding.text value
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

let array_values name = function
  | Encoding.Array values -> Ok values
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

let text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be text"))

let rec all = function
  | [] -> Ok []
  | result :: rest ->
      let* value = result in
      let* values = all rest in
      Ok (value :: values)

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let opaque_ref name bytes =
  Model.Opaque_object_ref.of_bytes bytes
  |> Result.map_error (fun _ ->
      Invalid_payload (name ^ " must be a 32-byte opaque object reference"))

let event_id name bytes =
  Ledger.Event_id.of_bytes bytes
  |> Result.map_error (fun _ ->
      Invalid_payload (name ^ " must be a 32-byte ledger event ID"))

let ref_name name value =
  Ledger.Ref_name.of_string value
  |> Result.map_error (fun error -> Invalid_payload (name ^ ": " ^ error))

let reason_compare left right =
  match (left, right) with
  | User_pin, User_pin -> 0
  | User_pin, (Capsule_boundary _ | Release_boundary _) -> -1
  | (Capsule_boundary _ | Release_boundary _), User_pin -> 1
  | Capsule_boundary left, Capsule_boundary right ->
      Model.Opaque_object_ref.compare left right
  | Capsule_boundary _, Release_boundary _ -> -1
  | Release_boundary _, Capsule_boundary _ -> 1
  | Release_boundary left, Release_boundary right ->
      Model.Opaque_object_ref.compare left right

let equal_reason left right = Int.equal (reason_compare left right) 0

let reason_value = function
  | User_pin -> array [ Encoding.integer 0L ]
  | Capsule_boundary binding ->
      array
        [
          Encoding.integer 1L;
          Encoding.bytes (Model.Opaque_object_ref.to_bytes binding);
        ]
  | Release_boundary binding ->
      array
        [
          Encoding.integer 2L;
          Encoding.bytes (Model.Opaque_object_ref.to_bytes binding);
        ]

let decode_reason value =
  let* values = array_values "V2 scratch protection reason" value in
  match values with
  | [ tag ] ->
      let* tag = integer "V2 scratch protection reason code" tag in
      if Int64.equal tag 0L then Ok User_pin
      else
        Error (Invalid_payload "V2 scratch protection reason has wrong fields")
  | [ tag; binding ] ->
      let* tag = integer "V2 scratch protection reason code" tag in
      let* binding = bytes "V2 scratch protection binding" binding in
      let* binding = opaque_ref "V2 scratch protection binding" binding in
      if Int64.equal tag 1L then Ok (Capsule_boundary binding)
      else if Int64.equal tag 2L then Ok (Release_boundary binding)
      else Error (Invalid_payload "unknown V2 scratch protection reason code")
  | _ -> Error (Invalid_payload "V2 scratch protection reason has wrong fields")

let action_code = function Protect -> 0L | Unprotect -> 1L

let action_of_code = function
  | 0L -> Ok Protect
  | 1L -> Ok Unprotect
  | _ -> Error (Invalid_payload "unknown V2 scratch protection action")

let protection_value
    ({ protected_snapshot_ref; protection_action; protection_reason } :
      protection) =
  let* reason = reason_value protection_reason in
  array
    [
      Encoding.integer schema_version;
      Encoding.bytes (Model.Opaque_object_ref.to_bytes protected_snapshot_ref);
      Encoding.integer (action_code protection_action);
      reason;
      Encoding.integer supported_mandatory_features;
    ]

let encode_protection protection =
  match protection_value protection with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let decode_protection encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "V2 scratch protection" 5 value in
  match values with
  | [ version; snapshot_ref; action; reason; features ] ->
      let* version = integer "V2 scratch protection version" version in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* snapshot_ref =
          bytes "V2 scratch protection snapshot" snapshot_ref
        in
        let* snapshot_ref =
          opaque_ref "V2 scratch protection snapshot" snapshot_ref
        in
        let* action = integer "V2 scratch protection action" action in
        let* action = action_of_code action in
        let* reason = decode_reason reason in
        let* features =
          integer "V2 scratch protection mandatory features" features
        in
        let* () = check_features features in
        let protection : protection =
          {
            protected_snapshot_ref = snapshot_ref;
            protection_action = action;
            protection_reason = reason;
          }
        in
        if String.equal encoded (encode_protection protection) then
          Ok protection
        else Error (Invalid_payload "noncanonical V2 scratch protection")
  | _ -> assert false

let cleanup_kind_code = function Ledger_event -> 0L | Scratch_snapshot -> 1L

let cleanup_kind_of_code = function
  | 0L -> Ok Ledger_event
  | 1L -> Ok Scratch_snapshot
  | _ -> Error (Invalid_payload "unknown V2 scratch cleanup frame kind")

let cleanup_candidate_compare (left : cleanup_candidate)
    (right : cleanup_candidate) =
  Model.Opaque_object_ref.compare left.candidate_object_ref
    right.candidate_object_ref

let cleanup_candidate_value
    ({ candidate_object_ref; candidate_kind } : cleanup_candidate) =
  array
    [
      Encoding.bytes (Model.Opaque_object_ref.to_bytes candidate_object_ref);
      Encoding.integer (cleanup_kind_code candidate_kind);
    ]

let decode_cleanup_candidate value =
  let* values = fields "V2 scratch cleanup candidate" 2 value in
  match values with
  | [ object_ref; expected_kind ] ->
      let* object_ref = bytes "V2 scratch cleanup object" object_ref in
      let* object_ref = opaque_ref "V2 scratch cleanup object" object_ref in
      let* expected_kind =
        integer "V2 scratch cleanup expected kind" expected_kind
      in
      let* expected_kind = cleanup_kind_of_code expected_kind in
      Ok
        ({ candidate_object_ref = object_ref; candidate_kind = expected_kind }
          : cleanup_candidate)
  | _ -> assert false

let duplicate_by compare values =
  let rec loop = function
    | left :: right :: _ when Int.equal (compare left right) 0 -> Some left
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop (List.sort compare values)

let validate_generation ~active_ref ~active_head:_ ~retired_refs
    ~cleanup_candidates =
  match retired_refs with
  | [] -> Error Empty_retired_refs
  | _ -> (
      match duplicate_by Ledger.Ref_name.compare retired_refs with
      | Some duplicate ->
          Error (Duplicate_retired_ref (Ledger.Ref_name.to_string duplicate))
      | None -> (
          if
            List.exists
              (fun retired -> Ledger.Ref_name.equal active_ref retired)
              retired_refs
          then
            Error (Active_ref_is_retired (Ledger.Ref_name.to_string active_ref))
          else
            match duplicate_by cleanup_candidate_compare cleanup_candidates with
            | Some duplicate ->
                Error
                  (Duplicate_cleanup_candidate duplicate.candidate_object_ref)
            | None -> Ok ()))

let make_generation ~active_ref ~active_head ~retired_refs
    ~(cleanup_candidates : cleanup_candidate list) =
  let* () =
    validate_generation ~active_ref ~active_head ~retired_refs
      ~cleanup_candidates
  in
  Ok
    {
      active_ref;
      active_head;
      retired_refs = List.sort Ledger.Ref_name.compare retired_refs;
      cleanup_candidates =
        List.sort cleanup_candidate_compare cleanup_candidates;
    }

let generation_value generation =
  let* () =
    validate_generation ~active_ref:generation.active_ref
      ~active_head:generation.active_head ~retired_refs:generation.retired_refs
      ~cleanup_candidates:generation.cleanup_candidates
  in
  let retired_refs =
    List.sort Ledger.Ref_name.compare generation.retired_refs
  in
  let cleanup_candidates =
    List.sort cleanup_candidate_compare generation.cleanup_candidates
  in
  let retired_refs =
    List.map
      (fun ref_name -> encoded_text (Ledger.Ref_name.to_string ref_name))
      retired_refs
  in
  let cleanup = List.map cleanup_candidate_value cleanup_candidates in
  let* retired_refs = all retired_refs in
  let* cleanup = all cleanup in
  let* active_ref =
    encoded_text (Ledger.Ref_name.to_string generation.active_ref)
  in
  let* retired_refs = array retired_refs in
  let* cleanup = array cleanup in
  array
    [
      Encoding.integer schema_version;
      active_ref;
      Encoding.bytes (Ledger.Event_id.to_bytes generation.active_head);
      retired_refs;
      cleanup;
      Encoding.integer supported_mandatory_features;
    ]

let encode_generation generation =
  match generation_value generation with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let decode_ref_names values =
  let rec decode reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* value = text "V2 scratch retired ref" value in
        let* value = ref_name "V2 scratch retired ref" value in
        decode (value :: reversed) rest
  in
  decode [] values

let decode_cleanup values =
  let rec decode reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* value = decode_cleanup_candidate value in
        decode (value :: reversed) rest
  in
  decode [] values

let decode_generation encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "V2 scratch generation" 6 value in
  match values with
  | [ version; active_ref; active_head; retired_refs; cleanup; features ] ->
      let* version = integer "V2 scratch generation version" version in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* active_ref = text "V2 scratch generation active ref" active_ref in
        let* active_ref =
          ref_name "V2 scratch generation active ref" active_ref
        in
        let* active_head =
          bytes "V2 scratch generation active head" active_head
        in
        let* active_head =
          event_id "V2 scratch generation active head" active_head
        in
        let* retired_refs =
          array_values "V2 scratch generation retired refs" retired_refs
        in
        let* retired_refs = decode_ref_names retired_refs in
        let* cleanup =
          array_values "V2 scratch generation cleanup candidates" cleanup
        in
        let* cleanup_candidates = decode_cleanup cleanup in
        let* features =
          integer "V2 scratch generation mandatory features" features
        in
        let* () = check_features features in
        let* generation =
          make_generation ~active_ref ~active_head ~retired_refs
            ~cleanup_candidates
        in
        if String.equal encoded (encode_generation generation) then
          Ok generation
        else Error (Invalid_payload "noncanonical V2 scratch generation")
  | _ -> assert false

let make_policy ~recent_count ~storage_budget_bytes =
  if recent_count < 0 then Error (Invalid_recent_count recent_count)
  else
    match storage_budget_bytes with
    | Some bytes when Int64.compare bytes 0L < 0 ->
        Error (Negative_storage_budget bytes)
    | None | Some _ -> Ok { recent_count; storage_budget_bytes }

let compare_checkpoint left right =
  Ledger.Event_id.compare left.event_id right.event_id

let checkpoint_equal left right = Int.equal (compare_checkpoint left right) 0
let ref_equal left right = Model.Opaque_object_ref.equal left right

let validate_history history =
  match history with
  | [] -> Error Empty_history
  | _ -> (
      match duplicate_by compare_checkpoint history with
      | Some duplicate -> Error (Duplicate_checkpoint_event duplicate.event_id)
      | None -> (
          let event_refs =
            List.map
              (fun checkpoint ->
                (checkpoint.event_object_ref, checkpoint.event_object_ref))
              history
          in
          let event_refs =
            List.sort
              (fun (left, _) (right, _) ->
                Model.Opaque_object_ref.compare left right)
              event_refs
          in
          let rec duplicate = function
            | (left, _) :: (right, _) :: _ when ref_equal left right ->
                Some left
            | _ :: rest -> duplicate rest
            | [] -> None
          in
          match duplicate event_refs with
          | Some object_ref -> Error (Duplicate_checkpoint_object object_ref)
          | None -> Ok ()))

let validate_object_sizes object_sizes =
  let sorted =
    List.sort
      (fun left right ->
        Model.Opaque_object_ref.compare left.sized_object_ref
          right.sized_object_ref)
      object_sizes
  in
  let rec loop = function
    | [] -> Ok sorted
    | { sized_object_ref; stored_bytes }
      :: ({ sized_object_ref = next; _ } :: _ as rest) ->
        if Int64.compare stored_bytes 0L < 0 then
          Error
            (Negative_object_size
               { object_ref = sized_object_ref; bytes = stored_bytes })
        else if ref_equal sized_object_ref next then
          Error (Duplicate_object_size sized_object_ref)
        else loop rest
    | [ { sized_object_ref; stored_bytes } ] ->
        if Int64.compare stored_bytes 0L < 0 then
          Error
            (Negative_object_size
               { object_ref = sized_object_ref; bytes = stored_bytes })
        else Ok sorted
  in
  loop sorted

let size_for sizes object_ref =
  match
    List.find_opt (fun size -> ref_equal size.sized_object_ref object_ref) sizes
  with
  | Some size -> Ok size.stored_bytes
  | None -> Error (Missing_object_size object_ref)

let safe_add left right =
  if Int64.compare right 0L < 0 then Error Size_overflow
  else if Int64.compare left (Int64.sub Int64.max_int right) > 0 then
    Error Size_overflow
  else Ok (Int64.add left right)

let unique_refs refs = List.sort_uniq Model.Opaque_object_ref.compare refs

let checkpoint_refs checkpoint =
  [ checkpoint.event_object_ref; checkpoint.checkpoint_snapshot_ref ]

let bytes_for_refs ~sizes refs =
  let rec sum total = function
    | [] -> Ok total
    | object_ref :: rest ->
        let* bytes = size_for sizes object_ref in
        let* total = safe_add total bytes in
        sum total rest
  in
  sum 0L (unique_refs refs)

let bytes_for_checkpoints ~sizes checkpoints =
  checkpoints |> List.map checkpoint_refs |> List.flatten
  |> bytes_for_refs ~sizes

let latest_action claims snapshot_ref reason =
  List.fold_left
    (fun current claim ->
      if
        ref_equal claim.protected_snapshot_ref snapshot_ref
        && equal_reason claim.protection_reason reason
      then Some claim.protection_action
      else current)
    None claims

let effective_reasons claims snapshot_ref =
  let reasons =
    claims
    |> List.filter_map (fun claim ->
        if ref_equal claim.protected_snapshot_ref snapshot_ref then
          Some claim.protection_reason
        else None)
    |> List.sort_uniq reason_compare
  in
  List.filter
    (fun reason ->
      match latest_action claims snapshot_ref reason with
      | Some Protect -> true
      | None | Some Unprotect -> false)
    reasons

let last count values =
  let length = List.length values in
  if count >= length then values
  else
    let rec drop remaining = function
      | tail when remaining = 0 -> tail
      | _ :: tail -> drop (remaining - 1) tail
      | [] -> []
    in
    drop (length - count) values

let contains_checkpoint checkpoints checkpoint =
  List.exists
    (fun candidate -> checkpoint_equal candidate checkpoint)
    checkpoints

let incremental_refs existing checkpoint =
  checkpoint_refs checkpoint
  |> List.filter (fun object_ref ->
      not (List.exists (fun kept -> ref_equal kept object_ref) existing))
  |> unique_refs

let select ~policy ~claims ~history ~object_sizes =
  let* () = validate_history history in
  let* object_sizes = validate_object_sizes object_sizes in
  let current = List.hd (List.rev history) in
  let recent = last policy.recent_count history in
  let protected checkpoint =
    effective_reasons claims checkpoint.checkpoint_snapshot_ref
  in
  let required =
    List.filter
      (fun checkpoint ->
        checkpoint_equal checkpoint current || protected checkpoint <> [])
      history
  in
  let optional =
    List.filter
      (fun checkpoint ->
        (not (contains_checkpoint required checkpoint))
        && contains_checkpoint recent checkpoint)
      history
  in
  let* required_bytes = bytes_for_checkpoints ~sizes:object_sizes required in
  let required_overrun =
    match policy.storage_budget_bytes with
    | Some budget when Int64.compare required_bytes budget > 0 ->
        Some (Int64.sub required_bytes budget)
    | None | Some _ -> None
  in
  let* selected_optional =
    match policy.storage_budget_bytes with
    | None -> Ok optional
    | Some budget ->
        let rec choose refs total selected = function
          | [] -> Ok selected
          | checkpoint :: rest ->
              let additions = incremental_refs refs checkpoint in
              let* extra = bytes_for_refs ~sizes:object_sizes additions in
              let* proposed = safe_add total extra in
              if Int64.compare proposed budget <= 0 then
                choose (additions @ refs) proposed (checkpoint :: selected) rest
              else choose refs total selected rest
        in
        choose
          (required |> List.map checkpoint_refs |> List.flatten |> unique_refs)
          required_bytes [] (List.rev optional)
  in
  let selected = required @ selected_optional in
  let* retained_bytes = bytes_for_checkpoints ~sizes:object_sizes selected in
  let decision checkpoint =
    if checkpoint_equal checkpoint current then Current_head
    else
      match protected checkpoint with
      | _ :: _ as reasons -> Protected reasons
      | [] when contains_checkpoint selected_optional checkpoint -> Recent
      | [] when contains_checkpoint optional checkpoint -> (
          match policy.storage_budget_bytes with
          | Some _ -> Budget_excluded
          | None -> assert false)
      | [] -> Expired
  in
  let retained, excluded =
    List.fold_right
      (fun checkpoint (retained, excluded) ->
        let planned = { checkpoint; decision = decision checkpoint } in
        match planned.decision with
        | Current_head | Protected _ | Recent -> (planned :: retained, excluded)
        | Expired | Budget_excluded -> (retained, planned :: excluded))
      history ([], [])
  in
  Ok { retained; excluded; retained_bytes; required_overrun }

let cleanup_candidates ~history ~retained ~externally_referenced =
  let* () = validate_history history in
  let retained_snapshots =
    List.map (fun checkpoint -> checkpoint.checkpoint_snapshot_ref) retained
  in
  let protected_snapshot snapshot_ref =
    List.exists
      (fun retained -> ref_equal retained snapshot_ref)
      retained_snapshots
    || List.exists
         (fun object_ref -> ref_equal object_ref snapshot_ref)
         externally_referenced
  in
  let event_candidates =
    List.map
      (fun checkpoint ->
        {
          candidate_object_ref = checkpoint.event_object_ref;
          candidate_kind = Ledger_event;
        })
      history
  in
  let snapshot_candidates =
    List.filter_map
      (fun checkpoint ->
        if protected_snapshot checkpoint.checkpoint_snapshot_ref then None
        else
          Some
            {
              candidate_object_ref = checkpoint.checkpoint_snapshot_ref;
              candidate_kind = Scratch_snapshot;
            })
      history
  in
  let candidates =
    List.sort cleanup_candidate_compare (event_candidates @ snapshot_candidates)
  in
  let rec validate reversed = function
    | [] -> Ok (List.rev reversed)
    | candidate :: rest -> (
        match reversed with
        | previous :: _
          when ref_equal previous.candidate_object_ref
                 candidate.candidate_object_ref ->
            if previous.candidate_kind = candidate.candidate_kind then
              validate reversed rest
            else Error (Cleanup_kind_collision candidate.candidate_object_ref)
        | _ -> validate (candidate :: reversed) rest)
  in
  validate [] candidates
