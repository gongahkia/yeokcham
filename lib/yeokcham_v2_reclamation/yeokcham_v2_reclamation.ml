module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object

type object_entry = {
  entry_object_ref : Model.Opaque_object_ref.t;
  entry_object_kind : Object.kind;
  entry_stored_bytes : int64;
  entry_direct_links : Model.Opaque_object_ref.t list;
}

type candidate = {
  candidate_object_ref : Model.Opaque_object_ref.t;
  candidate_kind : Object.kind;
  candidate_stored_bytes : int64;
}

type plan = {
  plan_id : string;
  root_digest : string;
  cache_budget_bytes : int64;
  total_bytes : int64;
  marked_bytes : int64;
  projected_bytes : int64;
  required_overrun : int64 option;
  marked : Model.Opaque_object_ref.t list;
  candidates : candidate list;
}

type error =
  | Duplicate_object of Model.Opaque_object_ref.t
  | Missing_object of Model.Opaque_object_ref.t
  | Negative_stored_bytes of {
      object_ref : Model.Opaque_object_ref.t;
      bytes : int64;
    }
  | Size_overflow
  | Negative_cache_budget of int64
  | Invalid_digest_length of { name : string; actual : int }
  | Invalid_plan_id
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_manifest

let current_schema_version = 1L
let supported_mandatory_features = 0L
let digest_size = Hash.digest_size
let root_digest_domain = "yeokcham:v2:reclamation-roots:v1\000"
let plan_id_domain = "yeokcham:v2:reclamation-plan:v1\000"
let ( let* ) = Result.bind

let error_to_string = function
  | Duplicate_object object_ref ->
      "V2 reclamation inventory repeats object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Missing_object object_ref ->
      "V2 reclamation references missing object: "
      ^ Model.Opaque_object_ref.to_hex object_ref
  | Negative_stored_bytes { object_ref; bytes } ->
      Printf.sprintf "V2 reclamation object %s has negative bytes %Ld"
        (Model.Opaque_object_ref.to_hex object_ref)
        bytes
  | Size_overflow -> "V2 reclamation stored-byte total overflows int64"
  | Negative_cache_budget bytes ->
      Printf.sprintf "V2 reclamation cache budget must be nonnegative, got %Ld"
        bytes
  | Invalid_digest_length { name; actual } ->
      Printf.sprintf "V2 reclamation %s must contain %d bytes, got %d" name
        digest_size actual
  | Invalid_plan_id -> "V2 reclamation manifest plan ID does not match bytes"
  | Invalid_payload detail -> "invalid V2 reclamation manifest: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V2 reclamation manifest version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 reclamation mandatory features: %Ld" features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported V2 reclamation mandatory features: %Ld"
        features
  | Noncanonical_manifest -> "V2 reclamation manifest is noncanonical"

let compare_ref = Model.Opaque_object_ref.compare
let canonical_refs refs = List.sort_uniq compare_ref refs

let object_entry ~object_ref ~object_kind ~stored_bytes ~direct_links =
  if Int64.compare stored_bytes 0L < 0 then
    Error (Negative_stored_bytes { object_ref; bytes = stored_bytes })
  else
    Ok
      {
        entry_object_ref = object_ref;
        entry_object_kind = object_kind;
        entry_stored_bytes = stored_bytes;
        entry_direct_links = canonical_refs direct_links;
      }

let object_ref entry = entry.entry_object_ref
let object_kind entry = entry.entry_object_kind
let stored_bytes entry = entry.entry_stored_bytes
let direct_links entry = entry.entry_direct_links

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let checked_add left right =
  let result = Int64.add left right in
  if
    Int64.compare left 0L >= 0
    && Int64.compare right 0L >= 0
    && Int64.compare result 0L < 0
  then Error Size_overflow
  else Ok result

let index_objects objects =
  let rec loop indexed = function
    | [] ->
        Ok
          (List.sort
             (fun left right ->
               compare_ref (object_ref left) (object_ref right))
             indexed)
    | entry :: rest ->
        if
          List.exists
            (fun present ->
              compare_ref (object_ref entry) (object_ref present) = 0)
            indexed
        then Error (Duplicate_object (object_ref entry))
        else loop (entry :: indexed) rest
  in
  loop [] objects

let find_object indexed object_ref =
  match
    List.find_opt
      (fun entry -> compare_ref object_ref entry.entry_object_ref = 0)
      indexed
  with
  | Some entry -> Ok entry
  | None -> Error (Missing_object object_ref)

let encoded_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let root_digest roots =
  let values =
    roots |> canonical_refs
    |> List.map (fun object_ref ->
        Encoding.bytes (Model.Opaque_object_ref.to_bytes object_ref))
  in
  let* value = encoded_array values in
  let bytes = Encoding.encode value in
  Ok (Hash.digest_string (root_digest_domain ^ bytes) |> Hash.to_raw_string)

let mark ~objects ~roots =
  let* indexed = index_objects objects in
  let roots = canonical_refs roots in
  let* root_digest = root_digest roots in
  let rec visit marked = function
    | [] -> Ok marked
    | object_ref :: rest ->
        if
          List.exists (fun present -> compare_ref object_ref present = 0) marked
        then visit marked rest
        else
          let* entry = find_object indexed object_ref in
          visit (object_ref :: marked) (entry.entry_direct_links @ rest)
  in
  let* marked = visit [] roots in
  Ok (canonical_refs marked, root_digest)

let kind_code = function
  | Object.Ledger_event -> 0L
  | Object.Scratch_snapshot -> 1L
  | Object.Scratch_protection -> 2L
  | Object.Scratch_generation -> 3L
  | Object.Capsule -> 4L
  | Object.Capsule_revision -> 5L
  | Object.Workspace -> 6L
  | Object.Workspace_revision -> 7L
  | Object.Workspace_attempt -> 8L
  | Object.Conflict -> 9L
  | Object.Resolution -> 10L
  | Object.Validation_evidence -> 11L
  | Object.Release -> 12L
  | Object.Repository_authority -> 13L
  | Object.Device_certificate -> 14L
  | Object.Device_revocation -> 15L

let kind_of_code = function
  | 0L -> Ok Object.Ledger_event
  | 1L -> Ok Object.Scratch_snapshot
  | 2L -> Ok Object.Scratch_protection
  | 3L -> Ok Object.Scratch_generation
  | 4L -> Ok Object.Capsule
  | 5L -> Ok Object.Capsule_revision
  | 6L -> Ok Object.Workspace
  | 7L -> Ok Object.Workspace_revision
  | 8L -> Ok Object.Workspace_attempt
  | 9L -> Ok Object.Conflict
  | 10L -> Ok Object.Resolution
  | 11L -> Ok Object.Validation_evidence
  | 12L -> Ok Object.Release
  | 13L -> Ok Object.Repository_authority
  | 14L -> Ok Object.Device_certificate
  | 15L -> Ok Object.Device_revocation
  | _ -> Error (Invalid_payload "unknown V2 reclamation frame kind")

let candidate_compare left right =
  compare_ref left.candidate_object_ref right.candidate_object_ref

let sum_stored_bytes entries =
  let rec loop total = function
    | [] -> Ok total
    | entry :: rest ->
        let* total = checked_add total entry.entry_stored_bytes in
        loop total rest
  in
  loop 0L entries

let is_marked marked object_ref =
  List.exists (fun present -> compare_ref present object_ref = 0) marked

let plan_body_value plan =
  let candidate_value candidate =
    encoded_array
      [
        Encoding.bytes
          (Model.Opaque_object_ref.to_bytes candidate.candidate_object_ref);
        Encoding.integer (kind_code candidate.candidate_kind);
        Encoding.integer candidate.candidate_stored_bytes;
      ]
  in
  let rec candidates values = function
    | [] -> Ok (List.rev values)
    | candidate :: rest ->
        let* value = candidate_value candidate in
        candidates (value :: values) rest
  in
  let* candidates = candidates [] plan.candidates in
  let* candidates = encoded_array candidates in
  let marked =
    List.map
      (fun object_ref ->
        Encoding.bytes (Model.Opaque_object_ref.to_bytes object_ref))
      plan.marked
  in
  let* marked = encoded_array marked in
  let overrun =
    match plan.required_overrun with
    | None -> Encoding.null
    | Some bytes -> Encoding.integer bytes
  in
  encoded_array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes plan.root_digest;
      marked;
      Encoding.integer plan.cache_budget_bytes;
      candidates;
      Encoding.integer plan.total_bytes;
      Encoding.integer plan.marked_bytes;
      Encoding.integer plan.projected_bytes;
      overrun;
      Encoding.integer supported_mandatory_features;
    ]

let plan_id_of_body value =
  Encoding.encode value |> fun bytes ->
  Hash.digest_string (plan_id_domain ^ bytes) |> Hash.to_raw_string

let make_plan ~objects ~roots ~cache_budget_bytes =
  if Int64.compare cache_budget_bytes 0L < 0 then
    Error (Negative_cache_budget cache_budget_bytes)
  else
    let* indexed = index_objects objects in
    let* marked, root_digest = mark ~objects:indexed ~roots in
    let* total_bytes = sum_stored_bytes indexed in
    let marked_entries =
      List.filter (fun entry -> is_marked marked entry.entry_object_ref) indexed
    in
    let* marked_bytes = sum_stored_bytes marked_entries in
    let unmarked =
      List.filter
        (fun entry -> not (is_marked marked entry.entry_object_ref))
        indexed
    in
    let rec select projected selected = function
      | [] -> Ok (projected, List.rev selected)
      | entry :: rest ->
          if Int64.compare projected cache_budget_bytes <= 0 then
            Ok (projected, List.rev selected)
          else
            let projected = Int64.sub projected entry.entry_stored_bytes in
            select projected
              ({
                 candidate_object_ref = entry.entry_object_ref;
                 candidate_kind = entry.entry_object_kind;
                 candidate_stored_bytes = entry.entry_stored_bytes;
               }
              :: selected)
              rest
    in
    let* projected_bytes, candidates =
      if Int64.compare marked_bytes cache_budget_bytes > 0 then
        Ok (total_bytes, [])
      else select total_bytes [] unmarked
    in
    let required_overrun =
      if Int64.compare marked_bytes cache_budget_bytes > 0 then
        Some (Int64.sub marked_bytes cache_budget_bytes)
      else None
    in
    let provisional =
      {
        plan_id = "";
        root_digest;
        cache_budget_bytes;
        total_bytes;
        marked_bytes;
        projected_bytes;
        required_overrun;
        marked;
        candidates;
      }
    in
    let* body = plan_body_value provisional in
    Ok { provisional with plan_id = plan_id_of_body body }

let plan_id plan = plan.plan_id
let root_digest plan = plan.root_digest
let cache_budget_bytes plan = plan.cache_budget_bytes
let total_bytes plan = plan.total_bytes
let marked_bytes plan = plan.marked_bytes
let projected_bytes plan = plan.projected_bytes
let required_overrun plan = plan.required_overrun
let marked plan = plan.marked
let candidates plan = plan.candidates
let candidate_object_ref candidate = candidate.candidate_object_ref
let candidate_kind candidate = candidate.candidate_kind
let candidate_stored_bytes candidate = candidate.candidate_stored_bytes

let encode_manifest plan =
  match plan_body_value plan with
  | Error error -> invalid_arg (error_to_string error)
  | Ok body ->
      encoded_array
        [
          Encoding.integer current_schema_version;
          Encoding.bytes plan.plan_id;
          body;
        ]
      |> Result.map Encoding.encode |> Result.get_ok

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

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let exact_digest name value =
  if String.length value = digest_size then Ok value
  else Error (Invalid_digest_length { name; actual = String.length value })

let opaque_ref name value =
  Model.Opaque_object_ref.of_bytes value
  |> Result.map_error (fun _ ->
      Invalid_payload (name ^ " must be a 32-byte opaque object reference"))

let decode_candidate value =
  let* values = fields "V2 reclamation candidate" 3 value in
  match values with
  | [ object_ref; kind; stored_bytes ] ->
      let* object_ref = bytes "V2 reclamation candidate object" object_ref in
      let* object_ref =
        opaque_ref "V2 reclamation candidate object" object_ref
      in
      let* kind = integer "V2 reclamation candidate kind" kind in
      let* candidate_kind = kind_of_code kind in
      let* candidate_stored_bytes =
        integer "V2 reclamation candidate stored bytes" stored_bytes
      in
      if Int64.compare candidate_stored_bytes 0L < 0 then
        Error
          (Negative_stored_bytes { object_ref; bytes = candidate_stored_bytes })
      else
        Ok
          {
            candidate_object_ref = object_ref;
            candidate_kind;
            candidate_stored_bytes;
          }
  | _ -> assert false

let rec decode_candidates result = function
  | [] -> Ok (List.rev result)
  | value :: rest ->
      let* candidate = decode_candidate value in
      decode_candidates (candidate :: result) rest

let rec decode_marked result = function
  | [] -> Ok (List.rev result)
  | value :: rest ->
      let* value = bytes "V2 reclamation marked object" value in
      let* object_ref = opaque_ref "V2 reclamation marked object" value in
      decode_marked (object_ref :: result) rest

let strictly_sorted_refs name refs =
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if Model.Opaque_object_ref.compare left right < 0 then loop rest
        else
          Error
            (Invalid_payload (name ^ " must be unique ascending references"))
  in
  loop refs

let strictly_sorted_candidates candidates =
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if candidate_compare left right < 0 then loop rest
        else
          Error
            (Invalid_payload
               "V2 reclamation candidates must be unique ascending references")
  in
  loop candidates

let sum_candidate_bytes candidates =
  let rec loop total = function
    | [] -> Ok total
    | candidate :: rest ->
        let* total = checked_add total candidate.candidate_stored_bytes in
        loop total rest
  in
  loop 0L candidates

let candidate_is_marked marked candidate =
  List.exists
    (fun object_ref ->
      Model.Opaque_object_ref.equal object_ref candidate.candidate_object_ref)
    marked

let validate_decoded_plan ~cache_budget_bytes ~total_bytes ~marked_bytes
    ~projected_bytes ~required_overrun ~marked ~candidates =
  let* () =
    if
      Int64.compare marked_bytes total_bytes > 0
      || Int64.compare projected_bytes total_bytes > 0
    then
      Error
        (Invalid_payload "V2 reclamation byte totals exceed the inventory total")
    else Ok ()
  in
  let* () =
    if List.exists (candidate_is_marked marked) candidates then
      Error
        (Invalid_payload
           "V2 reclamation candidates must not include marked objects")
    else Ok ()
  in
  let* candidate_bytes = sum_candidate_bytes candidates in
  let expected_candidate_bytes = Int64.sub total_bytes projected_bytes in
  let* () =
    if Int64.equal candidate_bytes expected_candidate_bytes then Ok ()
    else
      Error
        (Invalid_payload
           "V2 reclamation candidate bytes do not match the projected total")
  in
  if Int64.compare marked_bytes cache_budget_bytes > 0 then
    match required_overrun with
    | Some overrun
      when Int64.equal overrun (Int64.sub marked_bytes cache_budget_bytes)
           && candidates = []
           && Int64.equal projected_bytes total_bytes ->
        Ok ()
    | Some _ | None ->
        Error
          (Invalid_payload
             "V2 reclamation required overrun must retain the complete \
              inventory")
  else
    match required_overrun with
    | None when Int64.compare projected_bytes cache_budget_bytes <= 0 -> Ok ()
    | None ->
        Error
          (Invalid_payload
             "V2 reclamation projected bytes exceed the cache budget")
    | Some _ ->
        Error
          (Invalid_payload
             "V2 reclamation must not report an overrun when marked bytes fit")

let decode_body body =
  let* values = fields "V2 reclamation manifest body" 10 body in
  match values with
  | [
   version;
   root_digest;
   marked_refs;
   budget;
   candidates;
   total;
   marked_bytes_value;
   projected;
   overrun;
   features;
  ] ->
      let* version = integer "V2 reclamation manifest version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* root_digest = bytes "V2 reclamation root digest" root_digest in
        let* root_digest = exact_digest "root digest" root_digest in
        let* marked_values =
          array_values "V2 reclamation marked objects" marked_refs
        in
        let* marked = decode_marked [] marked_values in
        let* () = strictly_sorted_refs "V2 reclamation marked objects" marked in
        let* cache_budget_bytes =
          integer "V2 reclamation cache budget" budget
        in
        if Int64.compare cache_budget_bytes 0L < 0 then
          Error (Negative_cache_budget cache_budget_bytes)
        else
          let* candidate_values =
            array_values "V2 reclamation candidates" candidates
          in
          let* candidates = decode_candidates [] candidate_values in
          let* () = strictly_sorted_candidates candidates in
          let* total_bytes = integer "V2 reclamation total bytes" total in
          let* marked_bytes =
            integer "V2 reclamation marked bytes" marked_bytes_value
          in
          let* projected_bytes =
            integer "V2 reclamation projected bytes" projected
          in
          let* () =
            if
              Int64.compare total_bytes 0L < 0
              || Int64.compare marked_bytes 0L < 0
              || Int64.compare projected_bytes 0L < 0
            then
              Error
                (Invalid_payload
                   "V2 reclamation byte totals must be nonnegative")
            else Ok ()
          in
          let* required_overrun =
            match overrun with
            | Encoding.Null -> Ok None
            | Encoding.Integer bytes ->
                if Int64.compare bytes 0L < 0 then
                  Error
                    (Invalid_payload
                       "V2 reclamation overrun must be nonnegative")
                else Ok (Some bytes)
            | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
            | Encoding.Map _ | Encoding.Bool _ ->
                Error
                  (Invalid_payload
                     "V2 reclamation required overrun must be an integer or \
                      null")
          in
          let* features =
            integer "V2 reclamation mandatory features" features
          in
          let* () = check_features features in
          let* () =
            validate_decoded_plan ~cache_budget_bytes ~total_bytes ~marked_bytes
              ~projected_bytes ~required_overrun ~marked ~candidates
          in
          Ok
            {
              plan_id = "";
              root_digest;
              cache_budget_bytes;
              total_bytes;
              marked_bytes;
              projected_bytes;
              required_overrun;
              marked;
              candidates;
            }
  | _ -> assert false

let decode_manifest encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "V2 reclamation manifest" 3 value in
  match values with
  | [ version; plan_id; body ] ->
      let* version = integer "V2 reclamation wrapper version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* plan_id = bytes "V2 reclamation plan ID" plan_id in
        let* plan_id = exact_digest "plan ID" plan_id in
        let* plan = decode_body body in
        let* canonical_body = plan_body_value plan in
        let expected_id = plan_id_of_body canonical_body in
        if not (String.equal expected_id plan_id) then Error Invalid_plan_id
        else
          let plan = { plan with plan_id } in
          if String.equal encoded (encode_manifest plan) then Ok plan
          else Error Noncanonical_manifest
  | _ -> assert false
