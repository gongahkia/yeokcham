module M = Yeokcham_v1_model.Core
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope

(* Shared record labels use OCaml 5.5 type-directed disambiguation. *)
[@@@warning "-42"]

open M

type error =
  | Model_error of M.error
  | Encoding_error of E.construction_error
  | Decode_error of E.decode_error
  | Envelope_error of Envelope.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Wrong_object_type
  | Noncanonical_bytes
  | Oversized_record of int
  | Invalid_signature_length of int

let error_to_string = function
  | Model_error e -> M.error_to_string e
  | Encoding_error e -> E.construction_error_to_string e
  | Decode_error e -> E.decode_error_to_string e
  | Envelope_error e -> Envelope.decode_error_to_string e
  | Invalid_schema detail -> "invalid core record: " ^ detail
  | Unsupported_schema_version v ->
      Printf.sprintf "unsupported core schema: %Ld" v
  | Wrong_object_type -> "core record kind and envelope type disagree"
  | Noncanonical_bytes -> "core record is not canonical"
  | Oversized_record n -> Printf.sprintf "core record exceeds 8 MiB: %d bytes" n
  | Invalid_signature_length n ->
      Printf.sprintf "invalid core signature length: %d" n

let ( let* ) = Result.bind
let schema_version = 1L
let max_record_bytes = 8 * 1024 * 1024
let model result = Result.map_error (fun e -> Model_error e) result
let construction result = Result.map_error (fun e -> Encoding_error e) result
let array values = E.array values |> construction
let text value = E.text value |> construction

let map values =
  E.map (List.mapi (fun i v -> (Int64.of_int i, v)) values) |> construction

let invalid message = Error (Invalid_schema message)

let object_type = function
  | M.Shared_revision_kind -> Envelope.Core_shared_revision
  | M.Accepted_version_kind -> Envelope.Core_accepted_version
  | M.Branch_event_kind -> Envelope.Core_branch_event
  | M.Resolution_revision_kind -> Envelope.Core_resolution_revision

let signature_domain kind = "yeokcham/record/" ^ M.kind_name kind ^ "/v1"

let bounded bytes =
  if String.length bytes > max_record_bytes then
    Error (Oversized_record (String.length bytes))
  else Ok bytes

let encoded_ids to_raw ids =
  array (List.map (fun id -> E.bytes (to_raw id)) ids)

let records = encoded_ids M.Record_id.to_raw
let digests = encoded_ids M.Digest.to_raw

let action_code = function
  | M.Create -> 0L
  | M.Rename -> 1L
  | M.Advance -> 2L
  | M.Reconcile -> 3L

let payload_value = function
  | M.Shared_revision r ->
      let* previous = records r.previous_revisions in
      let* dependencies = records r.dependencies in
      map
        [
          E.bytes (M.Change_id.to_raw r.change);
          previous;
          E.bytes (M.Object_id.to_raw r.base_snapshot);
          E.bytes (M.Object_id.to_raw r.result_snapshot);
          E.bytes (M.Object_id.to_raw r.edit_scope_root);
          dependencies;
        ]
  | M.Accepted_version v ->
      let* parents = records v.accepted_parents in
      let* chosen = records v.chosen_revisions in
      let* resolutions = records v.resolutions in
      let* profile = text v.composition_profile in
      let* policy = digests v.policy_heads in
      let* reviews = digests v.review_evidence in
      map
        [
          E.bytes (M.Branch_id.to_raw v.branch);
          parents;
          chosen;
          resolutions;
          E.bytes (M.Object_id.to_raw v.result_snapshot);
          profile;
          policy;
          reviews;
        ]
  | M.Resolution_revision r ->
      let* heads = records r.accepted_heads in
      let* chosen = records r.chosen_revisions in
      let* variants = records r.superseded_variants in
      map
        [
          E.bytes (M.Branch_id.to_raw r.branch);
          heads;
          chosen;
          variants;
          E.bytes (M.Object_id.to_raw r.decision_scope_root);
          E.bytes (M.Object_id.to_raw r.comparison_snapshot);
          E.bytes (M.Object_id.to_raw r.replacement_snapshot);
        ]
  | M.Branch_event e ->
      let* previous = records e.previous_events in
      let* targets = records e.targets in
      let* name =
        match e.display_name with None -> Ok E.null | Some n -> text n
      in
      map
        [
          E.bytes (M.Branch_id.to_raw e.branch);
          previous;
          E.integer (action_code e.action);
          targets;
          name;
        ]

let body_value (body : M.body) =
  let* kind = text (M.kind_name (M.kind body.payload)) in
  let* parents = records (M.parents body.payload) in
  let* heads = digests body.context.authority_heads in
  let* payload = payload_value body.payload in
  let time =
    match body.context.display_time with
    | None -> E.null
    | Some n -> E.integer n
  in
  array
    [
      kind;
      E.integer schema_version;
      E.bytes (M.Repository_id.to_raw body.context.repository);
      parents;
      E.bytes (M.Digest.to_raw body.context.author_certificate);
      heads;
      payload;
      time;
    ]

let encode_body body =
  let* value = body_value body in
  bounded (E.encode value)

let signing_input body =
  let* bytes = encode_body body in
  Ok (signature_domain (M.kind body.M.payload) ^ bytes)

let decoded_bytes = function
  | E.Bytes b -> Ok b
  | E.Integer _ | E.Text _ | E.Array _ | E.Map _ | E.Bool _ | E.Null ->
      invalid "expected byte string"

let decoded_text = function
  | E.Text t -> Ok t
  | E.Integer _ | E.Bytes _ | E.Array _ | E.Map _ | E.Bool _ | E.Null ->
      invalid "expected UTF-8 text"

let decoded_id parse value =
  let* bytes = decoded_bytes value in
  parse bytes |> model

let decoded_set parse compare = function
  | E.Array values when List.compare_length_with values M.max_references <= 0 ->
      let rec loop previous reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest -> (
            let* id = decoded_id parse value in
            match previous with
            | Some p when compare p id >= 0 -> Error Noncanonical_bytes
            | _ -> loop (Some id) (id :: reversed) rest)
      in
      loop None [] values
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Map _ | E.Bool _ | E.Null
    ->
      invalid "expected bounded sorted unique identifier set"

let record_ids = decoded_set M.Record_id.of_raw M.Record_id.compare
let digest_ids = decoded_set M.Digest.of_raw M.Digest.compare

let fields count = function
  | E.Map pairs when List.length pairs = count ->
      if
        List.mapi (fun i (key, _) -> key = Int64.of_int i) pairs
        |> List.for_all Fun.id
      then Ok (List.map snd pairs)
      else invalid "payload map keys must be consecutive from zero"
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Map _ | E.Bool _ | E.Null
    ->
      invalid "wrong payload map shape"

let decode_payload kind value =
  match kind with
  | "shared-revision" -> (
      let* values = fields 6 value in
      match values with
      | [ change; previous; base; result; scope; dependencies ] ->
          let* change = decoded_id M.Change_id.of_raw change in
          let* previous_revisions = record_ids previous in
          let* base_snapshot = decoded_id M.Object_id.of_raw base in
          let* result_snapshot = decoded_id M.Object_id.of_raw result in
          let* edit_scope_root = decoded_id M.Object_id.of_raw scope in
          let* dependencies = record_ids dependencies in
          let* r =
            M.make_shared_revision ~change ~previous_revisions ~base_snapshot
              ~result_snapshot ~edit_scope_root ~dependencies
            |> model
          in
          Ok (M.Shared_revision r)
      | _ -> assert false)
  | "accepted-version" -> (
      let* values = fields 8 value in
      match values with
      | [
       branch; parents; chosen; resolutions; result; profile; policy; reviews;
      ] ->
          let* branch = decoded_id M.Branch_id.of_raw branch in
          let* accepted_parents = record_ids parents in
          let* chosen_revisions = record_ids chosen in
          let* resolutions = record_ids resolutions in
          let* result_snapshot = decoded_id M.Object_id.of_raw result in
          let* composition_profile = decoded_text profile in
          let* policy_heads = digest_ids policy in
          let* review_evidence = digest_ids reviews in
          let* v =
            M.make_accepted_version ~branch ~accepted_parents ~chosen_revisions
              ~resolutions ~result_snapshot ~composition_profile ~policy_heads
              ~review_evidence
            |> model
          in
          Ok (M.Accepted_version v)
      | _ -> assert false)
  | "resolution-revision" -> (
      let* values = fields 7 value in
      match values with
      | [ branch; heads; chosen; variants; scope; comparison; replacement ] ->
          let* branch = decoded_id M.Branch_id.of_raw branch in
          let* accepted_heads = record_ids heads in
          let* chosen_revisions = record_ids chosen in
          let* superseded_variants = record_ids variants in
          let* decision_scope_root = decoded_id M.Object_id.of_raw scope in
          let* comparison_snapshot = decoded_id M.Object_id.of_raw comparison in
          let* replacement_snapshot =
            decoded_id M.Object_id.of_raw replacement
          in
          let* r =
            M.make_resolution_revision ~branch ~accepted_heads ~chosen_revisions
              ~superseded_variants ~decision_scope_root ~comparison_snapshot
              ~replacement_snapshot
            |> model
          in
          Ok (M.Resolution_revision r)
      | _ -> assert false)
  | "branch-event" -> (
      let* values = fields 5 value in
      match values with
      | [ branch; previous; action; targets; name ] ->
          let* branch = decoded_id M.Branch_id.of_raw branch in
          let* previous_events = record_ids previous in
          let* targets = record_ids targets in
          let* action =
            match action with
            | E.Integer 0L -> Ok M.Create
            | E.Integer 1L -> Ok M.Rename
            | E.Integer 2L -> Ok M.Advance
            | E.Integer 3L -> Ok M.Reconcile
            | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Map _
            | E.Bool _ | E.Null ->
                invalid "unknown branch action"
          in
          let* display_name =
            match name with
            | E.Null -> Ok None
            | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Map _
            | E.Bool _ ->
                let* n = decoded_text name in
                Ok (Some n)
          in
          let* e =
            M.make_branch_event ~branch ~previous_events ~action ~targets
              ~display_name
            |> model
          in
          Ok (M.Branch_event e)
      | _ -> assert false)
  | _ -> invalid "unknown core record kind"

let decode_body_value ~repository = function
  | E.Array
      [
        E.Text kind;
        E.Integer version;
        scope;
        parents;
        certificate;
        heads;
        payload;
        time;
      ] ->
      if version <> schema_version then
        Error (Unsupported_schema_version version)
      else
        let* scope = decoded_id M.Repository_id.of_raw scope in
        if not (M.Repository_id.equal repository scope) then
          Error (Model_error M.Wrong_scope)
        else
          let* parents = record_ids parents in
          let* author_certificate = decoded_id M.Digest.of_raw certificate in
          let* authority_heads = digest_ids heads in
          let* display_time =
            match time with
            | E.Null -> Ok None
            | E.Integer n -> Ok (Some n)
            | E.Bytes _ | E.Text _ | E.Array _ | E.Map _ | E.Bool _ ->
                invalid "display time must be an integer or null"
          in
          let* context =
            M.make_context ~repository ~author_certificate ~authority_heads
              ~display_time
            |> model
          in
          let* payload = decode_payload kind payload in
          if parents <> M.parents payload then
            invalid "body parents disagree with payload parents"
          else Ok (M.make_body ~context ~payload)
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Map _ | E.Bool _ | E.Null
    ->
      invalid "expected eight-field core body tuple"

(* The largest payload has seven reference sets; bound parser work as well as
   bytes before constructing model values. *)
let limits =
  E.make_limits ~max_depth:8 ~max_items:((8 * M.max_references) + 128) ()
  |> Result.get_ok

let decode_value bytes =
  let* bytes = bounded bytes in
  E.decode ~limits bytes |> Result.map_error (fun e -> Decode_error e)

let decode_body ~repository bytes =
  let* value = decode_value bytes in
  decode_body_value ~repository value

type signed = { body_value : M.body; signature_value : string }

let body signed = signed.body_value
let signature signed = signed.signature_value

let attach_signature body ~signature =
  if String.length signature <> 64 then
    Error (Invalid_signature_length (String.length signature))
  else
    let* _ = encode_body body in
    Ok { body_value = body; signature_value = signature }

let encode signed =
  let* body = body_value signed.body_value in
  let* payload = array [ body; E.bytes signed.signature_value ] in
  let envelope =
    Envelope.create
      ~object_type:(object_type (M.kind signed.body_value.payload))
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:0L ~payload ()
    |> Result.get_ok
  in
  bounded (Envelope.encode envelope)

let decode ~repository bytes =
  let* bytes = bounded bytes in
  let* envelope =
    Envelope.verify bytes |> Result.map_error (fun e -> Envelope_error e)
  in
  let* value = decode_value (Envelope.payload envelope) in
  match value with
  | E.Array [ body; E.Bytes signature ] ->
      let* body = decode_body_value ~repository body in
      if Envelope.object_type envelope <> object_type (M.kind body.payload) then
        Error Wrong_object_type
      else attach_signature body ~signature
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Map _ | E.Bool _ | E.Null
    ->
      invalid "expected body/signature pair"

let id signed =
  let* bytes = encode signed in
  Yeokcham_hash.Sha256.(digest_string bytes |> to_raw_string)
  |> M.Record_id.of_raw |> model

let encode_history_id id =
  E.array
    [
      E.bytes (M.Workspace_id.to_raw (M.History_id.workspace id));
      E.integer (M.History_id.sequence id);
    ]
  |> Result.get_ok |> E.encode

let decode_history_id bytes =
  let* value = decode_value bytes in
  match value with
  | E.Array [ workspace; E.Integer sequence ] ->
      let* workspace = decoded_id M.Workspace_id.of_raw workspace in
      M.History_id.make ~workspace ~sequence |> model
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Map _ | E.Bool _ | E.Null
    ->
      invalid "expected workspace/sequence history pair"
