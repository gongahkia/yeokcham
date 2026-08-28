module Encoding = Yeokcham_encoding
module Model = Yeokcham_v4_model

type error =
  | Encoding_error of Encoding.construction_error
  | Decode_error of Encoding.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Model_error of Model.error
  | Noncanonical_bytes

let error_to_string = function
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error error -> Encoding.decode_error_to_string error
  | Invalid_schema detail -> "invalid V4 state schema: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V4 state schema version: %Ld" version
  | Model_error error -> Model.error_to_string error
  | Noncanonical_bytes -> "V4 state record is not canonically encoded"

let schema_version = 1L
let ( let* ) = Result.bind

let construction value =
  Result.map_error (fun error -> Encoding_error error) value

let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_schema (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

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

let decoded_bool name = function
  | Encoding.Bool value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be a boolean"))

let model value = Result.map_error (fun error -> Model_error error) value

let encode_list encode values =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | value :: rest ->
        let* encoded = encode value in
        loop (encoded :: reversed) rest
  in
  loop [] values

let decode_list name decode value =
  let* values = array_values name value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* decoded = decode value in
        loop (decoded :: reversed) rest
  in
  loop [] values

let encode_snapshot id = text (Model.Snapshot_id.to_string id)
let encode_draft_id id = text (Model.Draft_id.to_string id)
let encode_change_id id = text (Model.Change_id.to_string id)
let encode_revision_id id = text (Model.Revision_id.to_string id)
let encode_decision_id id = text (Model.Decision_id.to_string id)
let encode_delivery_id id = text (Model.Delivery_id.to_string id)
let encode_device_id id = text (Model.Device_id.to_string id)
let encode_username username = text (Model.Username.to_string username)

let decode_snapshot value =
  let* value = decoded_text "snapshot identifier" value in
  Model.Snapshot_id.of_string value |> model

let decode_draft_id value =
  let* value = decoded_text "draft identifier" value in
  Model.Draft_id.of_string value |> model

let decode_change_id value =
  let* value = decoded_text "change identifier" value in
  Model.Change_id.of_string value |> model

let decode_revision_id value =
  let* value = decoded_text "revision identifier" value in
  Model.Revision_id.of_string value |> model

let decode_decision_id value =
  let* value = decoded_text "decision identifier" value in
  Model.Decision_id.of_string value |> model

let decode_delivery_id value =
  let* value = decoded_text "delivery identifier" value in
  Model.Delivery_id.of_string value |> model

let decode_device_id value =
  let* value = decoded_text "device identifier" value in
  Model.Device_id.of_string value |> model

let decode_username value =
  let* value = decoded_text "username" value in
  Model.Username.of_string value |> model

let encode_path path = Model.Path.components path |> encode_list text

let decode_path value =
  let* components = decode_list "path" (decoded_text "path component") value in
  Model.Path.of_components components |> model

let encode_span span =
  array
    [
      Encoding.integer (Int64.of_int span.Model.start_byte);
      Encoding.integer (Int64.of_int span.Model.end_byte);
    ]

let int_from_int64 name value =
  if
    Int64.compare value (Int64.of_int min_int) < 0
    || Int64.compare value (Int64.of_int max_int) > 0
  then Error (Invalid_schema (name ^ " is outside the supported integer range"))
  else Ok (Int64.to_int value)

let decode_span value =
  let* fields = exact_array "span" 2 value in
  match fields with
  | [ start_byte; end_byte ] ->
      let* start_byte = decoded_integer "span start" start_byte in
      let* end_byte = decoded_integer "span end" end_byte in
      let* start_byte = int_from_int64 "span start" start_byte in
      let* end_byte = int_from_int64 "span end" end_byte in
      Model.make_span ~start_byte ~end_byte |> model
  | _ -> assert false

let encode_edit edit =
  let* path = encode_path edit.Model.edit_path in
  match edit.Model.edit_kind with
  | Model.Text span ->
      let* span = encode_span span in
      array [ path; Encoding.integer 0L; span ]
  | Model.Whole_path -> array [ path; Encoding.integer 1L; Encoding.null ]

let decode_edit value =
  let* fields = exact_array "edit" 3 value in
  match fields with
  | [ path; kind; detail ] ->
      let* edit_path = decode_path path in
      let* kind = decoded_integer "edit kind" kind in
      if Int64.equal kind 0L then
        let* span = decode_span detail in
        Ok Model.{ edit_path; edit_kind = Text span }
      else if Int64.equal kind 1L then
        match detail with
        | Encoding.Null -> Ok Model.{ edit_path; edit_kind = Whole_path }
        | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
        | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ ->
            Error (Invalid_schema "whole-path edit must have null detail")
      else Error (Invalid_schema "unknown edit kind")
  | _ -> assert false

let encode_parent = function
  | None -> Ok Encoding.null
  | Some parent -> encode_revision_id parent

let decode_parent value =
  match value with
  | Encoding.Null -> Ok None
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Bool _ ->
      decode_revision_id value |> Result.map Option.some

let encode_revision revision =
  let* change = encode_change_id revision.Model.change in
  let* revision_id = encode_revision_id revision.Model.revision in
  let* parent = encode_parent revision.Model.parent in
  let* author = encode_device_id revision.Model.revision_author in
  let* base = encode_snapshot revision.Model.base_snapshot in
  let* result = encode_snapshot revision.Model.result_snapshot in
  let* edits = encode_list encode_edit revision.Model.edits in
  array [ change; revision_id; parent; author; base; result; edits ]

let decode_revision value =
  let* fields = exact_array "change revision" 7 value in
  match fields with
  | [ change; revision; parent; author; base; result; edits ] ->
      let* change = decode_change_id change in
      let* revision = decode_revision_id revision in
      let* parent = decode_parent parent in
      let* author = decode_device_id author in
      let* base = decode_snapshot base in
      let* result = decode_snapshot result in
      let* edits = decode_list "revision edits" decode_edit edits in
      Model.make_change_revision ~change ~revision ~parent ~author ~base ~result
        ~edits
      |> model
  | _ -> assert false

let encode_draft_state = function
  | Model.Active -> Encoding.integer 0L
  | Model.Closed -> Encoding.integer 1L

let decode_draft_state value =
  let* value = decoded_integer "draft state" value in
  if Int64.equal value 0L then Ok Model.Active
  else if Int64.equal value 1L then Ok Model.Closed
  else Error (Invalid_schema "unknown draft state")

let encode_optional encode = function
  | None -> Ok Encoding.null
  | Some value -> encode value

let decode_optional decode = function
  | Encoding.Null -> Ok None
  | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ ) as value ->
      decode value |> Result.map Option.some

let encode_draft draft =
  let* id = encode_draft_id draft.Model.draft_id in
  let* title = text draft.Model.title in
  let* checkpoint = encode_snapshot draft.Model.latest_checkpoint in
  let* shared = encode_optional encode_change_id draft.Model.shared_change in
  array [ id; title; encode_draft_state draft.Model.state; checkpoint; shared ]

let decode_draft value =
  let* fields = exact_array "draft" 5 value in
  match fields with
  | [ draft_id; title; state; latest_checkpoint; shared_change ] ->
      let* draft_id = decode_draft_id draft_id in
      let* title = decoded_text "draft title" title in
      let* state = decode_draft_state state in
      let* latest_checkpoint = decode_snapshot latest_checkpoint in
      let* shared_change = decode_optional decode_change_id shared_change in
      Ok Model.{ draft_id; title; state; latest_checkpoint; shared_change }
  | _ -> assert false

let encode_checkpoint checkpoint =
  encode_snapshot checkpoint.Model.checkpoint_snapshot

let decode_checkpoint value =
  let* checkpoint_snapshot = decode_snapshot value in
  Ok Model.{ checkpoint_snapshot }

let encode_change change =
  let* id = encode_change_id change.Model.change_id in
  let* source = encode_optional encode_draft_id change.Model.source_draft in
  let* author = encode_device_id change.Model.change_author in
  let* revisions = encode_list encode_revision change.Model.revisions in
  array [ id; source; author; revisions; Encoding.bool change.Model.withdrawn ]

let decode_change value =
  let* fields = exact_array "shared change" 5 value in
  match fields with
  | [ change_id; source_draft; change_author; revisions; withdrawn ] ->
      let* change_id = decode_change_id change_id in
      let* source_draft = decode_optional decode_draft_id source_draft in
      let* change_author = decode_device_id change_author in
      let* revisions =
        decode_list "change revisions" decode_revision revisions
      in
      let* withdrawn = decoded_bool "change withdrawal state" withdrawn in
      Ok Model.{ change_id; source_draft; change_author; revisions; withdrawn }
  | _ -> assert false

let encode_edit_reference reference =
  let* revision = encode_revision_id reference.Model.referenced_revision in
  array
    [
      revision;
      Encoding.integer (Int64.of_int reference.Model.referenced_edit_index);
    ]

let decode_edit_reference value =
  let* fields = exact_array "edit reference" 2 value in
  match fields with
  | [ revision; index ] ->
      let* referenced_revision = decode_revision_id revision in
      let* index = decoded_integer "edit reference index" index in
      let* referenced_edit_index =
        int_from_int64 "edit reference index" index
      in
      Ok Model.{ referenced_revision; referenced_edit_index }
  | _ -> assert false

let encode_resolution resolution =
  let* decision = encode_decision_id resolution.Model.resolved_decision in
  let* suppressed =
    encode_list encode_edit_reference resolution.Model.suppressed_edits
  in
  let* replacement = encode_revision resolution.Model.replacement_revision in
  array [ decision; suppressed; replacement ]

let decode_resolution value =
  let* fields = exact_array "resolution" 3 value in
  match fields with
  | [ decision; suppressed; replacement ] ->
      let* resolved_decision = decode_decision_id decision in
      let* suppressed_edits =
        decode_list "suppressed edits" decode_edit_reference suppressed
      in
      let* replacement_revision = decode_revision replacement in
      Ok Model.{ resolved_decision; suppressed_edits; replacement_revision }
  | _ -> assert false

let encode_delivery delivery =
  let* id = encode_delivery_id delivery.Model.delivery_id in
  let* author = encode_device_id delivery.Model.delivery_author in
  let* snapshot = encode_snapshot delivery.Model.delivery_snapshot in
  let* included = encode_list encode_revision_id delivery.Model.included in
  array
    [
      id; author; snapshot; included; Encoding.integer delivery.Model.created_at;
    ]

let decode_delivery value =
  let* fields = exact_array "delivery" 5 value in
  match fields with
  | [ id; author; snapshot; included; created_at ] ->
      let* delivery_id = decode_delivery_id id in
      let* delivery_author = decode_device_id author in
      let* delivery_snapshot = decode_snapshot snapshot in
      let* included =
        decode_list "included revisions" decode_revision_id included
      in
      let* created_at = decoded_integer "delivery timestamp" created_at in
      Ok
        Model.
          {
            delivery_id;
            delivery_author;
            delivery_snapshot;
            included;
            created_at;
          }
  | _ -> assert false

let encode_username_registration registration =
  let* device = encode_device_id registration.Model.username_device in
  let* username = encode_username registration.Model.username in
  array [ device; username ]

let decode_username_registration value =
  let* fields = exact_array "username registration" 2 value in
  match fields with
  | [ device; username ] ->
      let* username_device = decode_device_id device in
      let* username = decode_username username in
      Ok Model.{ username_device; username }
  | _ -> assert false

let sort_drafts =
  List.sort (fun left right ->
      Model.Draft_id.compare left.Model.draft_id right.Model.draft_id)

let sort_changes =
  List.sort (fun left right ->
      Model.Change_id.compare left.Model.change_id right.Model.change_id)

let sort_resolutions =
  List.sort (fun left right ->
      Model.Decision_id.compare left.Model.resolved_decision
        right.Model.resolved_decision)

let sort_deliveries =
  List.sort (fun left right ->
      Model.Delivery_id.compare left.Model.delivery_id right.Model.delivery_id)

let sort_pins = List.sort_uniq Model.Snapshot_id.compare

let sort_usernames =
  List.sort (fun left right ->
      Model.Device_id.compare left.Model.username_device
        right.Model.username_device)

let encode_state_value state =
  let* creator = encode_device_id state.Model.state_creator in
  let* baseline = encode_snapshot state.Model.state_baseline in
  let* active = encode_draft_id state.Model.state_active_draft in
  let* drafts =
    encode_list encode_draft (sort_drafts state.Model.state_drafts)
  in
  let* checkpoints =
    encode_list encode_checkpoint state.Model.state_checkpoints
  in
  let* changes =
    encode_list encode_change (sort_changes state.Model.state_changes)
  in
  let* resolutions =
    encode_list encode_resolution
      (sort_resolutions state.Model.state_resolutions)
  in
  let* deliveries =
    encode_list encode_delivery (sort_deliveries state.Model.state_deliveries)
  in
  let* pins = encode_list encode_snapshot (sort_pins state.Model.state_pins) in
  let* usernames =
    encode_list encode_username_registration (sort_usernames state.Model.state_usernames)
  in
  array
    [
      Encoding.integer schema_version;
      creator;
      baseline;
      active;
      drafts;
      checkpoints;
      changes;
      resolutions;
      deliveries;
      pins;
      usernames;
    ]

let decode_state_components ~creator ~baseline ~active ~drafts ~checkpoints
    ~changes ~resolutions ~deliveries ~pins ~usernames =
  let* state_creator = decode_device_id creator in
  let* state_baseline = decode_snapshot baseline in
  let* state_active_draft = decode_draft_id active in
  let* state_drafts = decode_list "drafts" decode_draft drafts in
  let* state_checkpoints = decode_list "checkpoints" decode_checkpoint checkpoints in
  let* state_changes = decode_list "shared changes" decode_change changes in
  let* state_resolutions =
    decode_list "resolutions" decode_resolution resolutions
  in
  let* state_deliveries = decode_list "deliveries" decode_delivery deliveries in
  let* state_pins = decode_list "pins" decode_snapshot pins in
  let* state_usernames =
    decode_list "username registrations" decode_username_registration usernames
  in
  Ok
    Model.
      {
        state_creator;
        state_baseline;
        state_active_draft;
        state_drafts;
        state_checkpoints;
        state_changes;
        state_resolutions;
        state_deliveries;
        state_pins;
        state_usernames;
      }

let decode_state_value value =
  let* fields = array_values "V4 state" value in
  match fields with
  | [
   version;
   creator;
   baseline;
   active;
   drafts;
   checkpoints;
   changes;
   resolutions;
   deliveries;
   pins;
   usernames;
  ] ->
      let* version = decoded_integer "V4 state schema version" version in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        decode_state_components ~creator ~baseline ~active ~drafts
          ~checkpoints ~changes ~resolutions ~deliveries ~pins ~usernames
        |> Result.map (fun state -> (version, state))
  | _ -> Error (Invalid_schema "V4 state has an unsupported field count")

let encode_state state =
  let* _ = Model.import state |> model in
  let* value = encode_state_value state in
  Ok (Encoding.encode value)

let decode_state encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error -> Decode_error error)
  in
  let* version, state = decode_state_value value in
  let* _ = Model.import state |> model in
  let* canonical_value = encode_state_value state in
  let canonical = Encoding.encode canonical_value in
  if String.equal encoded canonical then Ok state else Error Noncanonical_bytes

let encode_change_revision revision =
  let* value = encode_revision revision in
  Ok (Encoding.encode value)

let decode_change_revision encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error -> Decode_error error)
  in
  let* revision = decode_revision value in
  let* canonical = encode_change_revision revision in
  if String.equal encoded canonical then Ok revision
  else Error Noncanonical_bytes

let encode_project project = Model.export project |> encode_state

let decode_project encoded =
  let* state = decode_state encoded in
  Model.import state |> model
