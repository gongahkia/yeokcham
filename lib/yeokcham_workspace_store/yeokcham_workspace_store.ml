module Capsule_store = Yeokcham_capsule_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Workspace = Yeokcham_workspace

[@@@warning "-4-40-42"]

type parent_link = {
  parent_revision : Id.Workspace_revision_id.t;
  parent_object_id : Store.Stored_object_id.t;
}

type precedence_edge = {
  before : Id.Capsule_revision_id.t;
  after : Id.Capsule_revision_id.t;
}

type resolution_binding = {
  binding_conflict : Id.Conflict_id.t;
  binding_resolution : Id.Resolution_id.t;
  binding_object_id : Store.Stored_object_id.t;
}

type provenance =
  | Created
  | Enabled of Id.Capsule_revision_id.t
  | Disabled of Id.Capsule_revision_id.t
  | Reordered
  | Resolved of Id.Resolution_id.t

type conflict_kind =
  | Missing_or_ambiguous_precondition
  | Competing_edits
  | Delete_modify
  | Move_modify
  | Binary_conflict
  | Dependency_failure
  | Unsupported_or_uncertain_operation

type resolution_action = Skip_operation

type workspace = {
  id : Id.Workspace_id.t;
  created_at : int64;
  name : string option;
  description : string option;
}

type workspace_revision = {
  id : Id.Workspace_revision_id.t;
  workspace : Id.Workspace_id.t;
  parent : parent_link option;
  base : Snapshot.Snapshot.id;
  selected : Capsule_store.revision_link list;
  precedence : precedence_edge list;
  resolved_order : Id.Capsule_revision_id.t list;
  resolutions : resolution_binding list;
  provenance : provenance;
  created_at : int64;
}

type conflict = {
  id : Id.Conflict_id.t;
  workspace : Id.Workspace_id.t;
  workspace_revision : Id.Workspace_revision_id.t;
  attempt : Id.Workspace_attempt_id.t option;
  base : Snapshot.Snapshot.id;
  capsule : Id.Capsule_id.t;
  capsule_revision : Id.Capsule_revision_id.t;
  operation_index : int;
  kind : conflict_kind;
  paths : Scratch.path list;
  current : Scratch.entry option;
  candidates : string list;
  created_at : int64;
}

type resolution = {
  id : Id.Resolution_id.t;
  conflict : Id.Conflict_id.t;
  workspace_revision : Id.Workspace_revision_id.t;
  attempt : Id.Workspace_attempt_id.t option;
  action : resolution_action;
  expected_current : Scratch.entry option;
  created_at : int64;
}

type attempt_outcome =
  | Attempt_applied_exactly of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Attempt_already_satisfied of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Attempt_persistent_conflict of Id.Conflict_id.t
  | Attempt_blocked_dependency of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
      blocked_by : Id.Conflict_id.t;
    }
  | Attempt_rejected_operation of Id.Conflict_id.t
  | Attempt_resolved_explicitly of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      operation_index : int;
    }

type workspace_attempt = {
  id : Id.Workspace_attempt_id.t;
  workspace : Id.Workspace_id.t;
  workspace_revision : Id.Workspace_revision_id.t;
  base : Snapshot.Snapshot.id;
  ordered : Capsule_store.revision_link list;
  starting_checkpoint : Scratch.Checkpoint_id.t;
  starting_snapshot : Snapshot.Snapshot.id;
  outcomes : attempt_outcome list;
  resulting_snapshot : Snapshot.Snapshot.id;
  conflicts : Id.Conflict_id.t list;
  created_at : int64;
}

type current_ref = {
  generation : int64;
  workspace : Id.Workspace_id.t;
  workspace_object : Store.Stored_object_id.t;
  revision : Id.Workspace_revision_id.t;
  revision_object : Store.Stored_object_id.t;
  latest_attempt : (Id.Workspace_attempt_id.t * Store.Stored_object_id.t) option;
}

type resolved = {
  workspace : workspace;
  workspace_object : Store.Stored_object_id.t;
  revision : workspace_revision;
  revision_object : Store.Stored_object_id.t;
  current : current_ref;
}

type error =
  | Store_error of Store.error
  | Envelope_error of Envelope.creation_error
  | Encoding_error of Encoding.construction_error
  | Decode_error of string
  | Unsupported_schema_version of int64
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }
  | Invalid_identity_length of { kind : string; length : int }
  | Invalid_generation of int64
  | Invalid_operation_index of int
  | Noncanonical_bytes of string
  | Logical_identity_mismatch of string
  | Invalid_current_ref_checksum
  | Workspace_missing of Id.Workspace_id.t
  | Current_ref_corrupt of string
  | Concurrent_current_update of {
      workspace : Id.Workspace_id.t;
      expected_generation : int64 option;
      actual_generation : int64 option;
    }
  | Conflicting_workspace_id_reuse of Id.Workspace_id.t
  | Current_ref_workspace_mismatch
  | Current_ref_revision_mismatch
  | Current_ref_attempt_mismatch
  | Parent_link_mismatch of string
  | Selected_link_mismatch of string
  | Resolution_binding_mismatch of string
  | Workspace_error of Workspace.error
  | Snapshot_error of Snapshot.error
  | Scratch_error of Scratch.error
  | Conflict_missing of Id.Conflict_id.t
  | Stale_resolution of string
  | Materialisation_error of string

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error message -> "invalid workspace schema: " ^ message
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported workspace schema version: %Ld" version
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "expected object type %d, got object type %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)
  | Invalid_identity_length { kind; length } ->
      Printf.sprintf "%s must be 32 bytes, got %d" kind length
  | Invalid_generation generation ->
      Printf.sprintf "workspace ref generation must be non-negative, got %Ld"
        generation
  | Invalid_operation_index index ->
      Printf.sprintf "operation index must be non-negative, got %d" index
  | Noncanonical_bytes name -> name ^ " bytes are noncanonical"
  | Logical_identity_mismatch kind ->
      kind ^ " logical ID does not match canonical preimage"
  | Invalid_current_ref_checksum -> "workspace current ref checksum is invalid"
  | Workspace_missing workspace ->
      "workspace current ref is missing: " ^ Id.Workspace_id.to_hex workspace
  | Current_ref_corrupt message ->
      "workspace current ref is corrupt: " ^ message
  | Concurrent_current_update
      { workspace; expected_generation; actual_generation } ->
      Printf.sprintf
        "workspace %s changed concurrently: expected generation %s, got %s"
        (Id.Workspace_id.to_hex workspace)
        (Option.fold ~none:"absent" ~some:Int64.to_string expected_generation)
        (Option.fold ~none:"absent" ~some:Int64.to_string actual_generation)
  | Conflicting_workspace_id_reuse workspace ->
      "workspace ID is already bound to different immutable content: "
      ^ Id.Workspace_id.to_hex workspace
  | Current_ref_workspace_mismatch ->
      "workspace current ref does not resolve to its named workspace"
  | Current_ref_revision_mismatch ->
      "workspace current ref does not resolve to its named workspace revision"
  | Current_ref_attempt_mismatch ->
      "workspace current ref does not resolve to its named workspace attempt"
  | Parent_link_mismatch message ->
      "workspace parent link is invalid: " ^ message
  | Selected_link_mismatch message ->
      "workspace selected revision link is invalid: " ^ message
  | Resolution_binding_mismatch message ->
      "workspace resolution binding is invalid: " ^ message
  | Workspace_error error -> Workspace.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Scratch_error error -> Scratch.error_to_string error
  | Conflict_missing conflict ->
      "conflict is missing: " ^ Id.Conflict_id.to_hex conflict
  | Stale_resolution message -> "resolution context is stale: " ^ message
  | Materialisation_error message ->
      "workspace materialisation failed: " ^ message

let ( let* ) = Result.bind

let value_array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let raw_id kind to_bytes identity =
  let raw = to_bytes identity in
  if String.length raw = 32 then Ok raw
  else Error (Invalid_identity_length { kind; length = String.length raw })

let raw_stored identity = Store.Stored_object_id.to_raw_bytes identity

let raw_snapshot identity =
  raw_stored (Snapshot.Snapshot.stored_object_id identity)

let raw_checkpoint identity =
  raw_stored (Scratch.Checkpoint_id.stored_object_id identity)

let parse_stored kind = function
  | Encoding.Bytes raw -> (
      match Store.Stored_object_id.of_raw_bytes raw with
      | Some identity -> Ok identity
      | None ->
          Error (Invalid_identity_length { kind; length = String.length raw }))
  | _ -> Error (Decode_error (kind ^ " must be bytes"))

let parse_id kind of_bytes = function
  | Encoding.Bytes raw ->
      if String.length raw <> 32 then
        Error (Invalid_identity_length { kind; length = String.length raw })
      else
        of_bytes raw
        |> Result.map_error (fun error ->
            Decode_error (kind ^ ": " ^ Id.parse_error_to_string error))
  | _ -> Error (Decode_error (kind ^ " must be bytes"))

let parse_snapshot kind value =
  parse_stored kind value |> Result.map Snapshot.Snapshot.of_stored_object_id

let parse_checkpoint kind value =
  parse_stored kind value
  |> Result.map Scratch.Checkpoint_id.of_stored_object_id

let integer name = function
  | Encoding.Integer value -> Ok value
  | _ -> Error (Decode_error (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | _ -> Error (Decode_error (name ^ " must be bytes"))

let text name = function
  | Encoding.Text value -> Ok value
  | _ -> Error (Decode_error (name ^ " must be text"))

let array_values name = function
  | Encoding.Array values -> Ok values
  | _ -> Error (Decode_error (name ^ " must be an array"))

let exact_array name count value =
  let* values = array_values name value in
  if List.length values = count then Ok values
  else
    Error (Decode_error (Printf.sprintf "%s must contain %d values" name count))

let canonical name value encode decoded =
  let* canonical = encode decoded in
  if String.equal (Encoding.encode value) (Encoding.encode canonical) then Ok ()
  else Error (Noncanonical_bytes name)

let canonical_set name encode values =
  let* encoded =
    List.fold_left
      (fun result value ->
        let* reversed = result in
        let* value = encode value in
        Ok (value :: reversed))
      (Ok []) values
  in
  let sorted =
    List.sort
      (fun left right ->
        String.compare (Encoding.encode left) (Encoding.encode right))
      encoded
  in
  let rec unique = function
    | left :: right :: _ when Encoding.equal left right ->
        Error (Decode_error (name ^ " contains a duplicate"))
    | _ :: rest -> unique rest
    | [] -> Ok ()
  in
  let* () = unique sorted in
  value_array sorted

let optional encode = function
  | None -> Ok Encoding.null
  | Some value -> encode value

let valid_component component =
  (not (String.is_empty component))
  && (not (String.equal component "."))
  && (not (String.equal component ".."))
  && (not (String.contains component '/'))
  && not (String.contains component '\000')

let path_value path =
  if path = [] || not (List.for_all valid_component path) then
    Error (Decode_error "invalid conflict path")
  else List.map Encoding.bytes path |> value_array

let path_of_value value =
  let* values = array_values "conflict path" value in
  let* path =
    List.fold_left
      (fun result value ->
        let* reversed = result in
        let* component = bytes "conflict path component" value in
        Ok (component :: reversed))
      (Ok []) values
  in
  let path = List.rev path in
  if path = [] || not (List.for_all valid_component path) then
    Error (Decode_error "invalid conflict path")
  else Ok path

let mode_value = function
  | Snapshot.Regular -> Encoding.integer 0L
  | Snapshot.Executable -> Encoding.integer 1L
  | Snapshot.Symlink -> Encoding.integer 2L

let mode_of_value value =
  let* code = integer "file mode" value in
  match code with
  | 0L -> Ok Snapshot.Regular
  | 1L -> Ok Snapshot.Executable
  | 2L -> Ok Snapshot.Symlink
  | _ -> Error (Decode_error "invalid file mode")

let entry_value = function
  | None -> Ok Encoding.null
  | Some Scratch.Directory -> value_array [ Encoding.integer 0L ]
  | Some (Scratch.File { mode; content }) ->
      value_array
        [
          Encoding.integer 1L;
          mode_value mode;
          Encoding.bytes
            (raw_stored (Snapshot.Content.stored_object_id content));
        ]

let entry_of_value = function
  | Encoding.Null -> Ok None
  | value -> (
      let* fields = array_values "entry" value in
      match fields with
      | [ tag ] ->
          let* tag = integer "entry tag" tag in
          if Int64.equal tag 0L then Ok (Some Scratch.Directory)
          else Error (Decode_error "invalid directory entry")
      | [ tag; mode; content ] ->
          let* tag = integer "entry tag" tag in
          if not (Int64.equal tag 1L) then
            Error (Decode_error "invalid file entry")
          else
            let* mode = mode_of_value mode in
            let* content = parse_stored "entry content" content in
            Ok
              (Some
                 (Scratch.File
                    {
                      mode;
                      content = Snapshot.Content.of_stored_object_id content;
                    }))
      | _ -> Error (Decode_error "entry has an invalid shape"))

let hash_id domain constructor payload =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context (Encoding.encode payload)
  |> Hash.get |> Hash.to_raw_string |> constructor |> Result.get_ok

let create_workspace ~id ~created_at ~name ~description =
  let* _ = raw_id "workspace ID" Id.Workspace_id.to_bytes id in
  let valid_optional = function
    | None -> Ok ()
    | Some value ->
        Encoding.text value
        |> Result.map (fun _ -> ())
        |> Result.map_error (fun error -> Encoding_error error)
  in
  let* () = valid_optional name in
  let* () = valid_optional description in
  Ok { id; created_at; name; description }

let workspace_id (workspace : workspace) = workspace.id
let workspace_created_at (workspace : workspace) = workspace.created_at
let workspace_name (workspace : workspace) = workspace.name
let workspace_description (workspace : workspace) = workspace.description

let workspace_payload (workspace : workspace) =
  let* id = raw_id "workspace ID" Id.Workspace_id.to_bytes workspace.id in
  let optional_text = function
    | None -> Ok Encoding.null
    | Some value ->
        Encoding.text value
        |> Result.map_error (fun error -> Encoding_error error)
  in
  let* name = optional_text workspace.name in
  let* description = optional_text workspace.description in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes id;
      Encoding.integer workspace.created_at;
      name;
      description;
    ]

let decode_workspace_payload value =
  let* fields = exact_array "workspace" 5 value in
  match fields with
  | [ version; id; created_at; name; description ] ->
      let* version = integer "workspace version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* id = parse_id "workspace ID" Id.Workspace_id.of_bytes id in
        let* created_at = integer "workspace creation timestamp" created_at in
        let optional_text = function
          | Encoding.Null -> Ok None
          | value -> text "workspace metadata" value |> Result.map Option.some
        in
        let* name = optional_text name in
        let* description = optional_text description in
        let* workspace = create_workspace ~id ~created_at ~name ~description in
        let* () = canonical "workspace" value workspace_payload workspace in
        Ok workspace
  | _ -> assert false

let object_envelope object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let store_workspace repository workspace =
  let* payload = workspace_payload workspace in
  let* envelope = object_envelope Envelope.Workspace payload in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_workspace repository object_id =
  let* object_ =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.Workspace then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Workspace;
           actual = Envelope.object_type object_;
         })
  else decode_workspace_payload (Envelope.payload object_)

let revision_link_value link =
  let* capsule =
    raw_id "selected capsule ID" Id.Capsule_id.to_bytes
      (Capsule_store.revision_link_capsule link)
  in
  let* revision =
    raw_id "selected capsule revision ID" Id.Capsule_revision_id.to_bytes
      (Capsule_store.revision_link_revision link)
  in
  value_array
    [
      Encoding.bytes capsule;
      Encoding.bytes revision;
      Encoding.bytes (raw_stored (Capsule_store.revision_link_object link));
    ]

let revision_link_of_value value =
  let* fields = exact_array "selected capsule revision link" 3 value in
  match fields with
  | [ capsule; revision; object_id ] ->
      let* capsule =
        parse_id "selected capsule ID" Id.Capsule_id.of_bytes capsule
      in
      let* revision =
        parse_id "selected capsule revision ID" Id.Capsule_revision_id.of_bytes
          revision
      in
      let* object_id = parse_stored "selected revision object ID" object_id in
      Ok (Capsule_store.make_revision_link ~capsule ~revision ~object_id)
  | _ -> assert false

let parent_value = function
  | None -> Ok Encoding.null
  | Some (parent : parent_link) ->
      let* revision =
        raw_id "workspace parent revision ID" Id.Workspace_revision_id.to_bytes
          parent.parent_revision
      in
      value_array
        [
          Encoding.bytes revision;
          Encoding.bytes (raw_stored parent.parent_object_id);
        ]

let parent_of_value = function
  | Encoding.Null -> Ok None
  | value -> (
      let* fields = exact_array "workspace parent link" 2 value in
      match fields with
      | [ revision; object_id ] ->
          let* revision =
            parse_id "workspace parent revision ID"
              Id.Workspace_revision_id.of_bytes revision
          in
          let* object_id =
            parse_stored "workspace parent object ID" object_id
          in
          Ok (Some { parent_revision = revision; parent_object_id = object_id })
      | _ -> assert false)

let precedence_value edge =
  let* before =
    raw_id "precedence before revision ID" Id.Capsule_revision_id.to_bytes
      edge.before
  in
  let* after =
    raw_id "precedence after revision ID" Id.Capsule_revision_id.to_bytes
      edge.after
  in
  value_array [ Encoding.bytes before; Encoding.bytes after ]

let precedence_of_value value =
  let* fields = exact_array "precedence edge" 2 value in
  match fields with
  | [ before; after ] ->
      let* before =
        parse_id "precedence before revision ID" Id.Capsule_revision_id.of_bytes
          before
      in
      let* after =
        parse_id "precedence after revision ID" Id.Capsule_revision_id.of_bytes
          after
      in
      if Id.Capsule_revision_id.equal before after then
        Error (Decode_error "precedence edge loops to itself")
      else Ok { before; after }
  | _ -> assert false

let binding_value (binding : resolution_binding) =
  let* conflict =
    raw_id "resolution conflict ID" Id.Conflict_id.to_bytes
      binding.binding_conflict
  in
  let* resolution =
    raw_id "resolution ID" Id.Resolution_id.to_bytes binding.binding_resolution
  in
  value_array
    [
      Encoding.bytes conflict;
      Encoding.bytes resolution;
      Encoding.bytes (raw_stored binding.binding_object_id);
    ]

let binding_of_value value =
  let* fields = exact_array "resolution binding" 3 value in
  match fields with
  | [ conflict; resolution; object_id ] ->
      let* conflict =
        parse_id "resolution conflict ID" Id.Conflict_id.of_bytes conflict
      in
      let* resolution =
        parse_id "resolution ID" Id.Resolution_id.of_bytes resolution
      in
      let* object_id = parse_stored "resolution object ID" object_id in
      Ok
        {
          binding_conflict = conflict;
          binding_resolution = resolution;
          binding_object_id = object_id;
        }
  | _ -> assert false

let provenance_value = function
  | Created -> value_array [ Encoding.integer 0L ]
  | Enabled revision ->
      let* revision =
        raw_id "enabled revision ID" Id.Capsule_revision_id.to_bytes revision
      in
      value_array [ Encoding.integer 1L; Encoding.bytes revision ]
  | Disabled revision ->
      let* revision =
        raw_id "disabled revision ID" Id.Capsule_revision_id.to_bytes revision
      in
      value_array [ Encoding.integer 2L; Encoding.bytes revision ]
  | Reordered -> value_array [ Encoding.integer 3L ]
  | Resolved resolution ->
      let* resolution =
        raw_id "resolved resolution ID" Id.Resolution_id.to_bytes resolution
      in
      value_array [ Encoding.integer 4L; Encoding.bytes resolution ]

let provenance_of_value value =
  let* fields = array_values "workspace provenance" value in
  match fields with
  | [ tag ] ->
      let* tag = integer "workspace provenance tag" tag in
      if Int64.equal tag 0L then Ok Created
      else if Int64.equal tag 3L then Ok Reordered
      else Error (Decode_error "invalid workspace provenance")
  | [ tag; identity ] ->
      let* tag = integer "workspace provenance tag" tag in
      if Int64.equal tag 1L then
        parse_id "enabled revision ID" Id.Capsule_revision_id.of_bytes identity
        |> Result.map (fun revision -> Enabled revision)
      else if Int64.equal tag 2L then
        parse_id "disabled revision ID" Id.Capsule_revision_id.of_bytes identity
        |> Result.map (fun revision -> Disabled revision)
      else if Int64.equal tag 4L then
        parse_id "resolved resolution ID" Id.Resolution_id.of_bytes identity
        |> Result.map (fun resolution -> Resolved resolution)
      else Error (Decode_error "invalid workspace provenance")
  | _ -> Error (Decode_error "invalid workspace provenance")

let revision_identity_payload ~workspace ~parent ~base ~selected ~precedence
    ~resolved_order ~resolutions ~provenance =
  let* workspace = raw_id "workspace ID" Id.Workspace_id.to_bytes workspace in
  let* parent = parent_value parent in
  let* selected =
    canonical_set "selected revisions" revision_link_value selected
  in
  let* precedence =
    canonical_set "precedence edges" precedence_value precedence
  in
  let* reversed_order =
    List.fold_left
      (fun result identity ->
        let* reversed = result in
        let* raw =
          raw_id "resolved revision ID" Id.Capsule_revision_id.to_bytes identity
        in
        Ok (Encoding.bytes raw :: reversed))
      (Ok []) resolved_order
  in
  let* resolved_order = value_array (List.rev reversed_order) in
  let* resolutions =
    canonical_set "resolution bindings" binding_value resolutions
  in
  let* provenance = provenance_value provenance in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes workspace;
      parent;
      Encoding.bytes (raw_snapshot base);
      selected;
      precedence;
      resolved_order;
      resolutions;
      provenance;
    ]

let revision_id_of_identity payload =
  hash_id "yeokcham:workspace-revision:v1\000" Id.Workspace_revision_id.of_bytes
    payload

let create_revision ~workspace ~parent ~base ~selected ~precedence
    ~resolved_order ~resolutions ~provenance ~created_at =
  let* identity =
    revision_identity_payload ~workspace ~parent ~base ~selected ~precedence
      ~resolved_order ~resolutions ~provenance
  in
  let id = revision_id_of_identity identity in
  Ok
    {
      id;
      workspace;
      parent;
      base;
      selected;
      precedence;
      resolved_order;
      resolutions;
      provenance;
      created_at;
    }

let revision_id (revision : workspace_revision) = revision.id
let revision_workspace (revision : workspace_revision) = revision.workspace
let revision_parent (revision : workspace_revision) = revision.parent
let revision_base (revision : workspace_revision) = revision.base
let revision_selected (revision : workspace_revision) = revision.selected
let revision_precedence (revision : workspace_revision) = revision.precedence

let revision_resolved_order (revision : workspace_revision) =
  revision.resolved_order

let revision_resolutions (revision : workspace_revision) = revision.resolutions
let revision_provenance (revision : workspace_revision) = revision.provenance
let revision_created_at (revision : workspace_revision) = revision.created_at

let derive_revision_id (revision : workspace_revision) =
  revision_identity_payload ~workspace:revision.workspace
    ~parent:revision.parent ~base:revision.base ~selected:revision.selected
    ~precedence:revision.precedence ~resolved_order:revision.resolved_order
    ~resolutions:revision.resolutions ~provenance:revision.provenance
  |> Result.map revision_id_of_identity
  |> Result.get_ok

let revision_payload (revision : workspace_revision) =
  let* identity =
    revision_identity_payload ~workspace:revision.workspace
      ~parent:revision.parent ~base:revision.base ~selected:revision.selected
      ~precedence:revision.precedence ~resolved_order:revision.resolved_order
      ~resolutions:revision.resolutions ~provenance:revision.provenance
  in
  let* id =
    raw_id "workspace revision ID" Id.Workspace_revision_id.to_bytes revision.id
  in
  let* fields = exact_array "workspace revision identity" 9 identity in
  match fields with
  | [
   version;
   workspace;
   parent;
   base;
   selected;
   precedence;
   order;
   resolutions;
   provenance;
  ] ->
      value_array
        [
          version;
          workspace;
          Encoding.bytes id;
          parent;
          base;
          selected;
          precedence;
          order;
          resolutions;
          provenance;
          Encoding.integer revision.created_at;
        ]
  | _ -> assert false

let decode_revision_payload value =
  let* fields = exact_array "workspace revision" 11 value in
  match fields with
  | [
   version;
   workspace;
   id;
   parent;
   base;
   selected;
   precedence;
   order;
   resolutions;
   provenance;
   created_at;
  ] ->
      let* version = integer "workspace revision version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* workspace =
          parse_id "workspace ID" Id.Workspace_id.of_bytes workspace
        in
        let* id =
          parse_id "workspace revision ID" Id.Workspace_revision_id.of_bytes id
        in
        let* parent = parent_of_value parent in
        let* base = parse_snapshot "workspace base snapshot ID" base in
        let* selected_values = array_values "selected revisions" selected in
        let* selected =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* link = revision_link_of_value value in
              Ok (link :: reversed))
            (Ok []) selected_values
          |> Result.map List.rev
        in
        let* precedence_values = array_values "precedence edges" precedence in
        let* precedence =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* edge = precedence_of_value value in
              Ok (edge :: reversed))
            (Ok []) precedence_values
          |> Result.map List.rev
        in
        let* order_values = array_values "resolved order" order in
        let* resolved_order =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* identity =
                parse_id "resolved revision ID" Id.Capsule_revision_id.of_bytes
                  value
              in
              Ok (identity :: reversed))
            (Ok []) order_values
          |> Result.map List.rev
        in
        let* resolution_values =
          array_values "resolution bindings" resolutions
        in
        let* resolutions =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* binding = binding_of_value value in
              Ok (binding :: reversed))
            (Ok []) resolution_values
          |> Result.map List.rev
        in
        let* provenance = provenance_of_value provenance in
        let* created_at =
          integer "workspace revision creation timestamp" created_at
        in
        let* revision =
          create_revision ~workspace ~parent ~base ~selected ~precedence
            ~resolved_order ~resolutions ~provenance ~created_at
        in
        if not (Id.Workspace_revision_id.equal id revision.id) then
          Error (Logical_identity_mismatch "workspace revision")
        else
          let* () =
            canonical "workspace revision" value revision_payload revision
          in
          Ok revision
  | _ -> assert false

let store_revision repository revision =
  let* payload = revision_payload revision in
  let* envelope = object_envelope Envelope.Workspace_revision payload in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_revision repository object_id =
  let* object_ =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.Workspace_revision then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Workspace_revision;
           actual = Envelope.object_type object_;
         })
  else decode_revision_payload (Envelope.payload object_)

let conflict_kind_value = function
  | Missing_or_ambiguous_precondition -> Encoding.integer 0L
  | Competing_edits -> Encoding.integer 1L
  | Delete_modify -> Encoding.integer 2L
  | Move_modify -> Encoding.integer 3L
  | Binary_conflict -> Encoding.integer 4L
  | Dependency_failure -> Encoding.integer 5L
  | Unsupported_or_uncertain_operation -> Encoding.integer 6L

let conflict_kind_of_value value =
  let* code = integer "conflict kind" value in
  match code with
  | 0L -> Ok Missing_or_ambiguous_precondition
  | 1L -> Ok Competing_edits
  | 2L -> Ok Delete_modify
  | 3L -> Ok Move_modify
  | 4L -> Ok Binary_conflict
  | 5L -> Ok Dependency_failure
  | 6L -> Ok Unsupported_or_uncertain_operation
  | _ -> Error (Decode_error "invalid conflict kind")

let optional_attempt_value =
  optional (fun attempt ->
      raw_id "workspace attempt ID" Id.Workspace_attempt_id.to_bytes attempt
      |> Result.map Encoding.bytes)

let optional_attempt_of_value = function
  | Encoding.Null -> Ok None
  | value ->
      parse_id "workspace attempt ID" Id.Workspace_attempt_id.of_bytes value
      |> Result.map Option.some

let paths_value paths =
  let* values =
    List.fold_left
      (fun result path ->
        let* reversed = result in
        let* value = path_value path in
        Ok (value :: reversed))
      (Ok []) paths
  in
  value_array (List.rev values)

let paths_of_value value =
  let* values = array_values "conflict paths" value in
  List.fold_left
    (fun result value ->
      let* reversed = result in
      let* path = path_of_value value in
      Ok (path :: reversed))
    (Ok []) values
  |> Result.map List.rev

let candidate_value candidate =
  Encoding.text candidate
  |> Result.map_error (fun error -> Encoding_error error)

let conflict_identity_payload ~workspace ~workspace_revision ~attempt ~base
    ~capsule ~capsule_revision ~operation_index ~kind ~paths ~current
    ~candidates =
  if operation_index < 0 then Error (Invalid_operation_index operation_index)
  else
    let* workspace =
      raw_id "conflict workspace ID" Id.Workspace_id.to_bytes workspace
    in
    let* workspace_revision =
      raw_id "conflict workspace revision ID" Id.Workspace_revision_id.to_bytes
        workspace_revision
    in
    let* attempt = optional_attempt_value attempt in
    let* capsule =
      raw_id "conflict capsule ID" Id.Capsule_id.to_bytes capsule
    in
    let* capsule_revision =
      raw_id "conflict capsule revision ID" Id.Capsule_revision_id.to_bytes
        capsule_revision
    in
    let* paths = paths_value paths in
    let* current = entry_value current in
    let* candidates =
      canonical_set "conflict candidates" candidate_value candidates
    in
    value_array
      [
        Encoding.integer 1L;
        Encoding.bytes workspace;
        Encoding.bytes workspace_revision;
        attempt;
        Encoding.bytes (raw_snapshot base);
        Encoding.bytes capsule;
        Encoding.bytes capsule_revision;
        Encoding.integer (Int64.of_int operation_index);
        conflict_kind_value kind;
        paths;
        current;
        candidates;
      ]

let conflict_id_of_identity payload =
  hash_id "yeokcham:conflict:v1\000" Id.Conflict_id.of_bytes payload

let create_conflict ~workspace ~workspace_revision ~attempt ~base ~capsule
    ~capsule_revision ~operation_index ~kind ~paths ~current ~candidates
    ~created_at =
  let* identity =
    conflict_identity_payload ~workspace ~workspace_revision ~attempt ~base
      ~capsule ~capsule_revision ~operation_index ~kind ~paths ~current
      ~candidates
  in
  let id = conflict_id_of_identity identity in
  Ok
    {
      id;
      workspace;
      workspace_revision;
      attempt;
      base;
      capsule;
      capsule_revision;
      operation_index;
      kind;
      paths;
      current;
      candidates;
      created_at;
    }

let conflict_id (conflict : conflict) = conflict.id
let conflict_workspace (conflict : conflict) = conflict.workspace

let conflict_workspace_revision (conflict : conflict) =
  conflict.workspace_revision

let conflict_attempt (conflict : conflict) = conflict.attempt
let conflict_capsule (conflict : conflict) = conflict.capsule
let conflict_capsule_revision (conflict : conflict) = conflict.capsule_revision
let conflict_operation_index (conflict : conflict) = conflict.operation_index
let conflict_kind (conflict : conflict) = conflict.kind
let conflict_paths (conflict : conflict) = conflict.paths
let conflict_current (conflict : conflict) = conflict.current
let conflict_candidates (conflict : conflict) = conflict.candidates

let conflict_payload (conflict : conflict) =
  let* identity =
    conflict_identity_payload ~workspace:conflict.workspace
      ~workspace_revision:conflict.workspace_revision ~attempt:conflict.attempt
      ~base:conflict.base ~capsule:conflict.capsule
      ~capsule_revision:conflict.capsule_revision
      ~operation_index:conflict.operation_index ~kind:conflict.kind
      ~paths:conflict.paths ~current:conflict.current
      ~candidates:conflict.candidates
  in
  let* id = raw_id "conflict ID" Id.Conflict_id.to_bytes conflict.id in
  let* fields = exact_array "conflict identity" 12 identity in
  match fields with
  | [
   version;
   workspace;
   workspace_revision;
   attempt;
   base;
   capsule;
   capsule_revision;
   operation_index;
   kind;
   paths;
   current;
   candidates;
  ] ->
      value_array
        [
          version;
          Encoding.bytes id;
          workspace;
          workspace_revision;
          attempt;
          base;
          capsule;
          capsule_revision;
          operation_index;
          kind;
          paths;
          current;
          candidates;
          Encoding.integer conflict.created_at;
        ]
  | _ -> assert false

let decode_conflict_payload value =
  let* fields = exact_array "conflict" 14 value in
  match fields with
  | [
   version;
   id;
   workspace;
   workspace_revision;
   attempt;
   base;
   capsule;
   capsule_revision;
   operation_index;
   kind;
   paths;
   current;
   candidates;
   created_at;
  ] ->
      let* version = integer "conflict version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* id = parse_id "conflict ID" Id.Conflict_id.of_bytes id in
        let* workspace =
          parse_id "conflict workspace ID" Id.Workspace_id.of_bytes workspace
        in
        let* workspace_revision =
          parse_id "conflict workspace revision ID"
            Id.Workspace_revision_id.of_bytes workspace_revision
        in
        let* attempt = optional_attempt_of_value attempt in
        let* base = parse_snapshot "conflict base snapshot" base in
        let* capsule =
          parse_id "conflict capsule ID" Id.Capsule_id.of_bytes capsule
        in
        let* capsule_revision =
          parse_id "conflict capsule revision ID"
            Id.Capsule_revision_id.of_bytes capsule_revision
        in
        let* operation_index =
          integer "conflict operation index" operation_index
        in
        if
          Int64.compare operation_index 0L < 0
          || Int64.compare operation_index (Int64.of_int max_int) > 0
        then Error (Decode_error "invalid conflict operation index")
        else
          let* kind = conflict_kind_of_value kind in
          let* paths = paths_of_value paths in
          let* current = entry_of_value current in
          let* candidate_values =
            array_values "conflict candidates" candidates
          in
          let* candidates =
            List.fold_left
              (fun result value ->
                let* reversed = result in
                let* candidate = text "conflict candidate" value in
                Ok (candidate :: reversed))
              (Ok []) candidate_values
            |> Result.map List.rev
          in
          let* created_at = integer "conflict creation timestamp" created_at in
          let* conflict =
            create_conflict ~workspace ~workspace_revision ~attempt ~base
              ~capsule ~capsule_revision
              ~operation_index:(Int64.to_int operation_index)
              ~kind ~paths ~current ~candidates ~created_at
          in
          if not (Id.Conflict_id.equal id conflict.id) then
            Error (Logical_identity_mismatch "conflict")
          else
            let* () = canonical "conflict" value conflict_payload conflict in
            Ok conflict
  | _ -> assert false

let store_conflict repository conflict =
  let* payload = conflict_payload conflict in
  let* envelope = object_envelope Envelope.Conflict payload in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_conflict repository object_id =
  let* object_ =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.Conflict then
    Error
      (Unexpected_object_type
         { expected = Envelope.Conflict; actual = Envelope.object_type object_ })
  else decode_conflict_payload (Envelope.payload object_)

let resolution_action_value = function
  | Skip_operation -> value_array [ Encoding.integer 0L ]

let resolution_action_of_value value =
  let* fields = exact_array "resolution action" 1 value in
  match fields with
  | [ tag ] ->
      let* tag = integer "resolution action tag" tag in
      if Int64.equal tag 0L then Ok Skip_operation
      else Error (Decode_error "invalid resolution action")
  | _ -> assert false

let resolution_identity_payload ~conflict ~workspace_revision ~attempt ~action
    ~expected_current =
  let* conflict =
    raw_id "resolution conflict ID" Id.Conflict_id.to_bytes conflict
  in
  let* workspace_revision =
    raw_id "resolution workspace revision ID" Id.Workspace_revision_id.to_bytes
      workspace_revision
  in
  let* attempt = optional_attempt_value attempt in
  let* action = resolution_action_value action in
  let* expected_current = entry_value expected_current in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes conflict;
      Encoding.bytes workspace_revision;
      attempt;
      action;
      expected_current;
    ]

let resolution_id_of_identity payload =
  hash_id "yeokcham:resolution:v1\000" Id.Resolution_id.of_bytes payload

let create_resolution ~(conflict : conflict) ~action ~expected_current
    ~created_at =
  let* identity =
    resolution_identity_payload ~conflict:conflict.id
      ~workspace_revision:conflict.workspace_revision ~attempt:conflict.attempt
      ~action ~expected_current
  in
  let id = resolution_id_of_identity identity in
  Ok
    {
      id;
      conflict = conflict.id;
      workspace_revision = conflict.workspace_revision;
      attempt = conflict.attempt;
      action;
      expected_current;
      created_at;
    }

let resolution_id (resolution : resolution) = resolution.id
let resolution_conflict (resolution : resolution) = resolution.conflict

let resolution_workspace_revision (resolution : resolution) =
  resolution.workspace_revision

let resolution_action (resolution : resolution) = resolution.action

let resolution_expected_current (resolution : resolution) =
  resolution.expected_current

let resolution_payload (resolution : resolution) =
  let* identity =
    resolution_identity_payload ~conflict:resolution.conflict
      ~workspace_revision:resolution.workspace_revision
      ~attempt:resolution.attempt ~action:resolution.action
      ~expected_current:resolution.expected_current
  in
  let* id = raw_id "resolution ID" Id.Resolution_id.to_bytes resolution.id in
  let* fields = exact_array "resolution identity" 6 identity in
  match fields with
  | [ version; conflict; workspace_revision; attempt; action; expected_current ]
    ->
      value_array
        [
          version;
          Encoding.bytes id;
          conflict;
          workspace_revision;
          attempt;
          action;
          expected_current;
          Encoding.integer resolution.created_at;
        ]
  | _ -> assert false

let decode_resolution_payload value =
  let* fields = exact_array "resolution" 8 value in
  match fields with
  | [
   version;
   id;
   conflict;
   workspace_revision;
   attempt;
   action;
   expected_current;
   created_at;
  ] ->
      let* version = integer "resolution version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* id = parse_id "resolution ID" Id.Resolution_id.of_bytes id in
        let* conflict =
          parse_id "resolution conflict ID" Id.Conflict_id.of_bytes conflict
        in
        let* workspace_revision =
          parse_id "resolution workspace revision ID"
            Id.Workspace_revision_id.of_bytes workspace_revision
        in
        let* attempt = optional_attempt_of_value attempt in
        let* action = resolution_action_of_value action in
        let* expected_current = entry_of_value expected_current in
        let* created_at = integer "resolution creation timestamp" created_at in
        let* identity =
          resolution_identity_payload ~conflict ~workspace_revision ~attempt
            ~action ~expected_current
        in
        let derived = resolution_id_of_identity identity in
        if not (Id.Resolution_id.equal id derived) then
          Error (Logical_identity_mismatch "resolution")
        else
          let resolution =
            {
              id;
              conflict;
              workspace_revision;
              attempt;
              action;
              expected_current;
              created_at;
            }
          in
          let* () =
            canonical "resolution" value resolution_payload resolution
          in
          Ok resolution
  | _ -> assert false

let store_resolution repository resolution =
  let* payload = resolution_payload resolution in
  let* envelope = object_envelope Envelope.Resolution payload in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_resolution repository object_id =
  let* object_ =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.Resolution then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Resolution;
           actual = Envelope.object_type object_;
         })
  else decode_resolution_payload (Envelope.payload object_)

let ordered_links_value links =
  let* values =
    List.fold_left
      (fun result link ->
        let* reversed = result in
        let* value = revision_link_value link in
        Ok (value :: reversed))
      (Ok []) links
  in
  value_array (List.rev values)

let ordered_links_of_value value =
  let* values = array_values "ordered capsule revisions" value in
  List.fold_left
    (fun result value ->
      let* reversed = result in
      let* link = revision_link_of_value value in
      Ok (link :: reversed))
    (Ok []) values
  |> Result.map List.rev

let attempt_input_payload ~workspace ~workspace_revision ~base ~ordered
    ~starting_checkpoint ~starting_snapshot =
  let* workspace =
    raw_id "attempt workspace ID" Id.Workspace_id.to_bytes workspace
  in
  let* workspace_revision =
    raw_id "attempt workspace revision ID" Id.Workspace_revision_id.to_bytes
      workspace_revision
  in
  let* ordered = ordered_links_value ordered in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes workspace;
      Encoding.bytes workspace_revision;
      Encoding.bytes (raw_snapshot base);
      ordered;
      Encoding.bytes (raw_checkpoint starting_checkpoint);
      Encoding.bytes (raw_snapshot starting_snapshot);
    ]

let derive_attempt_id ~workspace ~workspace_revision ~base ~ordered
    ~starting_checkpoint ~starting_snapshot =
  attempt_input_payload ~workspace ~workspace_revision ~base ~ordered
    ~starting_checkpoint ~starting_snapshot
  |> Result.map
       (hash_id "yeokcham:workspace-attempt:v1\000"
          Id.Workspace_attempt_id.of_bytes)
  |> Result.get_ok

let outcome_value = function
  | ( Attempt_applied_exactly { capsule; revision; operation_index }
    | Attempt_already_satisfied { capsule; revision; operation_index } ) as
    outcome ->
      if operation_index < 0 then
        Error (Invalid_operation_index operation_index)
      else
        let tag =
          match outcome with
          | Attempt_applied_exactly _ -> 0L
          | Attempt_already_satisfied _ -> 1L
          | _ -> assert false
        in
        let* capsule =
          raw_id "attempt capsule ID" Id.Capsule_id.to_bytes capsule
        in
        let* revision =
          raw_id "attempt revision ID" Id.Capsule_revision_id.to_bytes revision
        in
        value_array
          [
            Encoding.integer tag;
            Encoding.bytes capsule;
            Encoding.bytes revision;
            Encoding.integer (Int64.of_int operation_index);
          ]
  | Attempt_persistent_conflict conflict ->
      let* conflict =
        raw_id "attempt conflict ID" Id.Conflict_id.to_bytes conflict
      in
      value_array [ Encoding.integer 2L; Encoding.bytes conflict ]
  | Attempt_blocked_dependency
      { capsule; revision; operation_index; blocked_by } ->
      if operation_index < 0 then
        Error (Invalid_operation_index operation_index)
      else
        let* capsule =
          raw_id "attempt capsule ID" Id.Capsule_id.to_bytes capsule
        in
        let* revision =
          raw_id "attempt revision ID" Id.Capsule_revision_id.to_bytes revision
        in
        let* blocked_by =
          raw_id "blocked conflict ID" Id.Conflict_id.to_bytes blocked_by
        in
        value_array
          [
            Encoding.integer 3L;
            Encoding.bytes capsule;
            Encoding.bytes revision;
            Encoding.integer (Int64.of_int operation_index);
            Encoding.bytes blocked_by;
          ]
  | Attempt_rejected_operation conflict ->
      let* conflict =
        raw_id "attempt conflict ID" Id.Conflict_id.to_bytes conflict
      in
      value_array [ Encoding.integer 4L; Encoding.bytes conflict ]
  | Attempt_resolved_explicitly { capsule; revision; operation_index } ->
      if operation_index < 0 then
        Error (Invalid_operation_index operation_index)
      else
        let* capsule =
          raw_id "attempt capsule ID" Id.Capsule_id.to_bytes capsule
        in
        let* revision =
          raw_id "attempt revision ID" Id.Capsule_revision_id.to_bytes revision
        in
        value_array
          [
            Encoding.integer 5L;
            Encoding.bytes capsule;
            Encoding.bytes revision;
            Encoding.integer (Int64.of_int operation_index);
          ]

let outcome_of_value value =
  let* fields = array_values "attempt outcome" value in
  match fields with
  | [ tag; capsule; revision; operation_index ]
    when match tag with
         | Encoding.Integer 0L | Encoding.Integer 1L | Encoding.Integer 5L ->
             true
         | _ -> false ->
      let* tag = integer "attempt outcome tag" tag in
      let* capsule =
        parse_id "attempt capsule ID" Id.Capsule_id.of_bytes capsule
      in
      let* revision =
        parse_id "attempt revision ID" Id.Capsule_revision_id.of_bytes revision
      in
      let* operation_index =
        integer "attempt operation index" operation_index
      in
      if
        Int64.compare operation_index 0L < 0
        || Int64.compare operation_index (Int64.of_int max_int) > 0
      then Error (Decode_error "invalid attempt operation index")
      else if Int64.equal tag 0L then
        Ok
          (Attempt_applied_exactly
             {
               capsule;
               revision;
               operation_index = Int64.to_int operation_index;
             })
      else if Int64.equal tag 1L then
        Ok
          (Attempt_already_satisfied
             {
               capsule;
               revision;
               operation_index = Int64.to_int operation_index;
             })
      else
        Ok
          (Attempt_resolved_explicitly
             {
               capsule;
               revision;
               operation_index = Int64.to_int operation_index;
             })
  | [ Encoding.Integer 2L; conflict ] ->
      parse_id "attempt conflict ID" Id.Conflict_id.of_bytes conflict
      |> Result.map (fun conflict -> Attempt_persistent_conflict conflict)
  | [ Encoding.Integer 4L; conflict ] ->
      parse_id "attempt conflict ID" Id.Conflict_id.of_bytes conflict
      |> Result.map (fun conflict -> Attempt_rejected_operation conflict)
  | [ Encoding.Integer 3L; capsule; revision; operation_index; blocked_by ] ->
      let* capsule =
        parse_id "attempt capsule ID" Id.Capsule_id.of_bytes capsule
      in
      let* revision =
        parse_id "attempt revision ID" Id.Capsule_revision_id.of_bytes revision
      in
      let* operation_index =
        integer "attempt operation index" operation_index
      in
      if
        Int64.compare operation_index 0L < 0
        || Int64.compare operation_index (Int64.of_int max_int) > 0
      then Error (Decode_error "invalid attempt operation index")
      else
        let* blocked_by =
          parse_id "blocked conflict ID" Id.Conflict_id.of_bytes blocked_by
        in
        Ok
          (Attempt_blocked_dependency
             {
               capsule;
               revision;
               operation_index = Int64.to_int operation_index;
               blocked_by;
             })
  | _ -> Error (Decode_error "invalid attempt outcome")

let outcomes_value outcomes =
  let* values =
    List.fold_left
      (fun result outcome ->
        let* reversed = result in
        let* value = outcome_value outcome in
        Ok (value :: reversed))
      (Ok []) outcomes
  in
  value_array (List.rev values)

let outcomes_of_value value =
  let* values = array_values "attempt outcomes" value in
  List.fold_left
    (fun result value ->
      let* reversed = result in
      let* outcome = outcome_of_value value in
      Ok (outcome :: reversed))
    (Ok []) values
  |> Result.map List.rev

let conflict_ids_value conflicts =
  let* values =
    List.fold_left
      (fun result conflict ->
        let* reversed = result in
        let* raw =
          raw_id "attempt conflict ID" Id.Conflict_id.to_bytes conflict
        in
        Ok (Encoding.bytes raw :: reversed))
      (Ok []) conflicts
  in
  value_array (List.rev values)

let conflict_ids_of_value value =
  let* values = array_values "attempt conflicts" value in
  List.fold_left
    (fun result value ->
      let* reversed = result in
      let* conflict =
        parse_id "attempt conflict ID" Id.Conflict_id.of_bytes value
      in
      Ok (conflict :: reversed))
    (Ok []) values
  |> Result.map List.rev

let create_attempt ~id ~workspace ~workspace_revision ~base ~ordered
    ~starting_checkpoint ~starting_snapshot ~outcomes ~resulting_snapshot
    ~conflicts ~created_at =
  let derived =
    derive_attempt_id ~workspace ~workspace_revision ~base ~ordered
      ~starting_checkpoint ~starting_snapshot
  in
  if not (Id.Workspace_attempt_id.equal id derived) then
    Error (Logical_identity_mismatch "workspace attempt")
  else
    Ok
      {
        id;
        workspace;
        workspace_revision;
        base;
        ordered;
        starting_checkpoint;
        starting_snapshot;
        outcomes;
        resulting_snapshot;
        conflicts;
        created_at;
      }

let attempt_id (attempt : workspace_attempt) = attempt.id
let attempt_workspace (attempt : workspace_attempt) = attempt.workspace

let attempt_workspace_revision (attempt : workspace_attempt) =
  attempt.workspace_revision

let attempt_base (attempt : workspace_attempt) = attempt.base
let attempt_ordered (attempt : workspace_attempt) = attempt.ordered

let attempt_starting_checkpoint (attempt : workspace_attempt) =
  attempt.starting_checkpoint

let attempt_starting_snapshot (attempt : workspace_attempt) =
  attempt.starting_snapshot

let attempt_outcomes (attempt : workspace_attempt) = attempt.outcomes

let attempt_resulting_snapshot (attempt : workspace_attempt) =
  attempt.resulting_snapshot

let attempt_conflicts (attempt : workspace_attempt) = attempt.conflicts

let attempt_payload (attempt : workspace_attempt) =
  let* input =
    attempt_input_payload ~workspace:attempt.workspace
      ~workspace_revision:attempt.workspace_revision ~base:attempt.base
      ~ordered:attempt.ordered ~starting_checkpoint:attempt.starting_checkpoint
      ~starting_snapshot:attempt.starting_snapshot
  in
  let* id =
    raw_id "workspace attempt ID" Id.Workspace_attempt_id.to_bytes attempt.id
  in
  let* outcomes = outcomes_value attempt.outcomes in
  let* conflicts = conflict_ids_value attempt.conflicts in
  let* fields = exact_array "workspace attempt input" 7 input in
  match fields with
  | [
   version;
   workspace;
   workspace_revision;
   base;
   ordered;
   starting_checkpoint;
   starting_snapshot;
  ] ->
      value_array
        [
          version;
          Encoding.bytes id;
          workspace;
          workspace_revision;
          base;
          ordered;
          starting_checkpoint;
          starting_snapshot;
          outcomes;
          Encoding.bytes (raw_snapshot attempt.resulting_snapshot);
          conflicts;
          Encoding.array [] |> Result.get_ok;
          Encoding.integer attempt.created_at;
        ]
  | _ -> assert false

let decode_attempt_payload value =
  let* fields = exact_array "workspace attempt" 13 value in
  match fields with
  | [
   version;
   id;
   workspace;
   workspace_revision;
   base;
   ordered;
   starting_checkpoint;
   starting_snapshot;
   outcomes;
   resulting_snapshot;
   conflicts;
   evidence;
   created_at;
  ] ->
      let* version = integer "workspace attempt version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* id =
          parse_id "workspace attempt ID" Id.Workspace_attempt_id.of_bytes id
        in
        let* workspace =
          parse_id "attempt workspace ID" Id.Workspace_id.of_bytes workspace
        in
        let* workspace_revision =
          parse_id "attempt workspace revision ID"
            Id.Workspace_revision_id.of_bytes workspace_revision
        in
        let* base = parse_snapshot "attempt base snapshot" base in
        let* ordered = ordered_links_of_value ordered in
        let* starting_checkpoint =
          parse_checkpoint "attempt starting checkpoint" starting_checkpoint
        in
        let* starting_snapshot =
          parse_snapshot "attempt starting snapshot" starting_snapshot
        in
        let* outcomes = outcomes_of_value outcomes in
        let* resulting_snapshot =
          parse_snapshot "attempt resulting snapshot" resulting_snapshot
        in
        let* conflicts = conflict_ids_of_value conflicts in
        let* evidence = array_values "attempt evidence" evidence in
        if evidence <> [] then
          Error (Decode_error "attempt validation evidence is unsupported")
        else
          let* created_at = integer "attempt creation timestamp" created_at in
          let* attempt =
            create_attempt ~id ~workspace ~workspace_revision ~base ~ordered
              ~starting_checkpoint ~starting_snapshot ~outcomes
              ~resulting_snapshot ~conflicts ~created_at
          in
          let* () =
            canonical "workspace attempt" value attempt_payload attempt
          in
          Ok attempt
  | _ -> assert false

let store_attempt repository attempt =
  let* payload = attempt_payload attempt in
  let* envelope = object_envelope Envelope.Workspace_attempt payload in
  Store.put repository envelope
  |> Result.map_error (fun error -> Store_error error)

let load_attempt repository object_id =
  let* object_ =
    Store.get repository object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.Workspace_attempt then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Workspace_attempt;
           actual = Envelope.object_type object_;
         })
  else decode_attempt_payload (Envelope.payload object_)

let current_ref_body (current : current_ref) =
  let* workspace =
    raw_id "current workspace ID" Id.Workspace_id.to_bytes current.workspace
  in
  let* revision =
    raw_id "current workspace revision ID" Id.Workspace_revision_id.to_bytes
      current.revision
  in
  let* latest_attempt =
    match current.latest_attempt with
    | None -> Ok Encoding.null
    | Some (attempt, object_id) ->
        let* attempt =
          raw_id "current attempt ID" Id.Workspace_attempt_id.to_bytes attempt
        in
        value_array
          [ Encoding.bytes attempt; Encoding.bytes (raw_stored object_id) ]
  in
  value_array
    [
      Encoding.integer 1L;
      Encoding.integer current.generation;
      Encoding.bytes workspace;
      Encoding.bytes (raw_stored current.workspace_object);
      Encoding.bytes revision;
      Encoding.bytes (raw_stored current.revision_object);
      latest_attempt;
    ]

let current_ref_checksum body =
  Hash.feed_string Hash.empty "yeokcham:workspace-current-ref:v1\000"
  |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let make_current_ref ~generation ~workspace ~workspace_object ~revision
    ~revision_object ~latest_attempt =
  if Int64.compare generation 0L < 0 then Error (Invalid_generation generation)
  else
    let current =
      {
        generation;
        workspace;
        workspace_object;
        revision;
        revision_object;
        latest_attempt;
      }
    in
    let* _ = current_ref_body current in
    Ok current

let current_generation (current : current_ref) = current.generation
let current_workspace (current : current_ref) = current.workspace
let current_workspace_object (current : current_ref) = current.workspace_object
let current_revision (current : current_ref) = current.revision
let current_revision_object (current : current_ref) = current.revision_object
let current_latest_attempt (current : current_ref) = current.latest_attempt

let encode_current_ref current =
  match current_ref_body current with
  | Error _ -> assert false
  | Ok body ->
      let checksum = current_ref_checksum body in
      let fields =
        match body with Encoding.Array fields -> fields | _ -> assert false
      in
      Encoding.array (fields @ [ Encoding.bytes checksum ])
      |> Result.get_ok |> Encoding.encode

let decode_current_ref input =
  let* value =
    Encoding.decode input
    |> Result.map_error (fun error ->
        Decode_error (Encoding.decode_error_to_string error))
  in
  let* fields = exact_array "workspace current ref" 8 value in
  match fields with
  | [
   version;
   generation;
   workspace;
   workspace_object;
   revision;
   revision_object;
   latest_attempt;
   checksum;
  ] ->
      let* version = integer "workspace current ref version" version in
      if not (Int64.equal version 1L) then
        Error (Unsupported_schema_version version)
      else
        let* generation =
          integer "workspace current ref generation" generation
        in
        if Int64.compare generation 0L < 0 then
          Error (Invalid_generation generation)
        else
          let* workspace =
            parse_id "current workspace ID" Id.Workspace_id.of_bytes workspace
          in
          let* workspace_object =
            parse_stored "current workspace object ID" workspace_object
          in
          let* revision =
            parse_id "current workspace revision ID"
              Id.Workspace_revision_id.of_bytes revision
          in
          let* revision_object =
            parse_stored "current revision object ID" revision_object
          in
          let* latest_attempt =
            match latest_attempt with
            | Encoding.Null -> Ok None
            | value -> (
                let* fields = exact_array "current attempt link" 2 value in
                match fields with
                | [ attempt; object_id ] ->
                    let* attempt =
                      parse_id "current attempt ID"
                        Id.Workspace_attempt_id.of_bytes attempt
                    in
                    let* object_id =
                      parse_stored "current attempt object ID" object_id
                    in
                    Ok (Some (attempt, object_id))
                | _ -> assert false)
          in
          let* checksum = bytes "workspace current ref checksum" checksum in
          if String.length checksum <> Hash.digest_size then
            Error Invalid_current_ref_checksum
          else
            let* current =
              make_current_ref ~generation ~workspace ~workspace_object
                ~revision ~revision_object ~latest_attempt
            in
            let encoded = encode_current_ref current in
            if not (String.equal input encoded) then
              Error Invalid_current_ref_checksum
            else Ok current
  | _ -> assert false

let current_ref_components workspace =
  [ "workspaces"; Id.Workspace_id.to_hex workspace; "current" ]

let resolved_workspace (resolved : resolved) = resolved.workspace
let resolved_workspace_object (resolved : resolved) = resolved.workspace_object
let resolved_revision (resolved : resolved) = resolved.revision
let resolved_revision_object (resolved : resolved) = resolved.revision_object
let resolved_current_ref (resolved : resolved) = resolved.current

let link_compare left right =
  let compared =
    Id.Capsule_id.compare
      (Capsule_store.revision_link_capsule left)
      (Capsule_store.revision_link_capsule right)
  in
  if compared <> 0 then compared
  else
    let compared =
      Id.Capsule_revision_id.compare
        (Capsule_store.revision_link_revision left)
        (Capsule_store.revision_link_revision right)
    in
    if compared <> 0 then compared
    else
      Store.Stored_object_id.compare
        (Capsule_store.revision_link_object left)
        (Capsule_store.revision_link_object right)

let sort_links = List.sort link_compare

let precedence_compare left right =
  let compared = Id.Capsule_revision_id.compare left.before right.before in
  if compared <> 0 then compared
  else Id.Capsule_revision_id.compare left.after right.after

let binding_compare (left : resolution_binding) (right : resolution_binding) =
  let compared =
    Id.Conflict_id.compare left.binding_conflict right.binding_conflict
  in
  if compared <> 0 then compared
  else Id.Resolution_id.compare left.binding_resolution right.binding_resolution

let explicit_order_of_precedence ~selected precedence =
  if precedence = [] then Ok None
  else
    let selected_ids = List.map Capsule_store.revision_link_revision selected in
    let contains identity =
      List.exists (Id.Capsule_revision_id.equal identity) selected_ids
    in
    if List.length precedence <> List.length selected_ids - 1 then
      Error (Decode_error "precedence does not form a complete order")
    else if
      List.exists
        (fun edge -> not (contains edge.before && contains edge.after))
        precedence
    then Error (Decode_error "precedence names an unselected revision")
    else
      let has_incoming identity =
        List.exists
          (fun edge -> Id.Capsule_revision_id.equal edge.after identity)
          precedence
      in
      let starts =
        List.filter (fun identity -> not (has_incoming identity)) selected_ids
      in
      match starts with
      | [ start ] ->
          let rec follow reversed current =
            let next =
              List.filter
                (fun edge -> Id.Capsule_revision_id.equal edge.before current)
                precedence
            in
            match next with
            | [] -> Ok (List.rev (current :: reversed))
            | [ edge ] -> follow (current :: reversed) edge.after
            | _ -> Error (Decode_error "precedence has multiple successors")
          in
          let* order = follow [] start in
          if List.length order <> List.length selected_ids then
            Error
              (Decode_error "precedence has a cycle or disconnected revision")
          else Ok (Some order)
      | _ -> Error (Decode_error "precedence has no unique start")

let precedence_of_order = function
  | None -> []
  | Some revisions ->
      let rec loop reversed = function
        | before :: (after :: _ as rest) ->
            loop ({ before; after } :: reversed) rest
        | _ -> List.rev reversed
      in
      loop [] revisions

let validate_selected_link store link =
  let* revision =
    Capsule_store.load_revision store (Capsule_store.revision_link_object link)
    |> Result.map_error (fun error ->
        Selected_link_mismatch (Capsule_store.error_to_string error))
  in
  if
    not
      (Id.Capsule_id.equal
         (Capsule_store.revision_link_capsule link)
         (Capsule_store.revision_capsule revision))
  then Error (Selected_link_mismatch "logical capsule ID disagrees with object")
  else if
    not
      (Id.Capsule_revision_id.equal
         (Capsule_store.revision_link_revision link)
         (Capsule_store.revision_id revision))
  then
    Error (Selected_link_mismatch "logical revision ID disagrees with object")
  else Ok revision

let order_for_links store ~selected ~precedence =
  let* selected_revisions =
    List.fold_left
      (fun result link ->
        let* reversed = result in
        let* revision = validate_selected_link store link in
        let selected : Workspace.selected_revision =
          {
            capsule = Capsule_store.revision_capsule revision;
            revision = Capsule_store.revision_id revision;
            dependencies = Capsule_store.revision_dependencies revision;
          }
        in
        Ok ((link, selected) :: reversed))
      (Ok []) selected
    |> Result.map List.rev
  in
  let* explicit_order = explicit_order_of_precedence ~selected precedence in
  let* order =
    Workspace.derive_order
      ~selected:(List.map snd selected_revisions)
      ~explicit_order
    |> Result.map_error (fun error -> Workspace_error error)
  in
  Ok (order, selected_revisions)

let validate_revision_links store (revision : workspace_revision) =
  let* _ =
    Snapshot.Snapshot.load store revision.base
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* order, _ =
    order_for_links store ~selected:revision.selected
      ~precedence:revision.precedence
  in
  let actual =
    List.map (fun item -> item.Workspace.revision) (Workspace.revisions order)
  in
  if
    List.length actual <> List.length revision.resolved_order
    || not
         (List.for_all2 Id.Capsule_revision_id.equal actual
            revision.resolved_order)
  then
    Error
      (Selected_link_mismatch
         "stored resolved order disagrees with recomputation")
  else
    let* () =
      match revision.parent with
      | None -> Ok ()
      | Some parent ->
          if Id.Workspace_revision_id.equal parent.parent_revision revision.id
          then Error (Parent_link_mismatch "revision cannot parent itself")
          else
            let* parent_revision =
              load_revision store parent.parent_object_id
            in
            if
              not
                (Id.Workspace_revision_id.equal parent.parent_revision
                   parent_revision.id)
            then
              Error
                (Parent_link_mismatch "logical ID disagrees with parent object")
            else if
              not
                (Id.Workspace_id.equal parent_revision.workspace
                   revision.workspace)
            then
              Error (Parent_link_mismatch "parent belongs to another workspace")
            else Ok ()
    in
    Ok order

let all_object_ids root =
  let rec files reversed directory =
    match Sys.readdir directory with
    | exception Sys_error _ -> reversed
    | names ->
        List.fold_left
          (fun reversed name ->
            if String.starts_with ~prefix:"." name then reversed
            else
              let path = Filename.concat directory name in
              match (Unix.lstat path).Unix.st_kind with
              | Unix.S_DIR -> files reversed path
              | Unix.S_REG -> path :: reversed
              | _ -> reversed)
          reversed (Array.to_list names)
  in
  let objects = Filename.concat (Filename.concat root ".yeokcham") "objects" in
  files [] objects

let find_conflict_object store identity =
  let paths = all_object_ids (Store.root store) in
  let rec loop = function
    | [] -> Error (Conflict_missing identity)
    | path :: rest -> (
        let name = Filename.basename path in
        let parent = Filename.basename (Filename.dirname path) in
        let grandparent =
          Filename.basename (Filename.dirname (Filename.dirname path))
        in
        let hex = grandparent ^ parent ^ name in
        match Store.Stored_object_id.of_hex hex with
        | Error _ -> loop rest
        | Ok object_id -> (
            match load_conflict store object_id with
            | Ok conflict when Id.Conflict_id.equal conflict.id identity ->
                Ok (conflict, object_id)
            | Ok _ | Error _ -> loop rest))
  in
  loop paths

let revision_link_equal left right =
  Id.Capsule_id.equal
    (Capsule_store.revision_link_capsule left)
    (Capsule_store.revision_link_capsule right)
  && Id.Capsule_revision_id.equal
       (Capsule_store.revision_link_revision left)
       (Capsule_store.revision_link_revision right)
  && Store.Stored_object_id.equal
       (Capsule_store.revision_link_object left)
       (Capsule_store.revision_link_object right)

let ordered_links_for_order (revision : workspace_revision) order =
  Workspace.revisions order
  |> List.fold_left
       (fun result selected ->
         let* reversed = result in
         match
           List.find_opt
             (fun link ->
               Id.Capsule_revision_id.equal selected.Workspace.revision
                 (Capsule_store.revision_link_revision link))
             revision.selected
         with
         | Some link -> Ok (link :: reversed)
         | None ->
             Error
               (Selected_link_mismatch
                  "resolved order lacks a selected revision link"))
       (Ok [])
  |> Result.map List.rev

let entry_equal left right =
  let* left = entry_value left in
  let* right = entry_value right in
  Ok (Encoding.equal left right)

let validate_resolution_binding store (revision : workspace_revision)
    (binding : resolution_binding) =
  let* resolution = load_resolution store binding.binding_object_id in
  if not (Id.Resolution_id.equal resolution.id binding.binding_resolution) then
    Error
      (Resolution_binding_mismatch
         "resolution logical ID disagrees with binding object")
  else if
    not (Id.Conflict_id.equal resolution.conflict binding.binding_conflict)
  then
    Error
      (Resolution_binding_mismatch "resolution conflict disagrees with binding")
  else
    let* conflict, _ = find_conflict_object store binding.binding_conflict in
    if not (Id.Workspace_id.equal conflict.workspace revision.workspace) then
      Error
        (Resolution_binding_mismatch "conflict belongs to another workspace")
    else if
      not
        (Id.Workspace_revision_id.equal resolution.workspace_revision
           conflict.workspace_revision)
    then
      Error
        (Resolution_binding_mismatch
           "resolution workspace revision disagrees with conflict")
    else if
      not
        (Option.equal Id.Workspace_attempt_id.equal resolution.attempt
           conflict.attempt)
    then
      Error
        (Resolution_binding_mismatch
           "resolution attempt disagrees with conflict")
    else
      let* expected_current =
        entry_equal resolution.expected_current conflict.current
      in
      if expected_current then Ok ()
      else
        Error
          (Resolution_binding_mismatch
             "resolution expected current entry disagrees with conflict")

let validate_resolution_bindings store revision =
  List.fold_left
    (fun result binding ->
      let* () = result in
      validate_resolution_binding store revision binding)
    (Ok ()) revision.resolutions

let validate_attempt_context store (revision : workspace_revision) order
    (attempt : workspace_attempt) =
  if not (Snapshot.Snapshot.equal_id attempt.base revision.base) then
    Error Current_ref_attempt_mismatch
  else
    let* ordered = ordered_links_for_order revision order in
    if
      List.length ordered <> List.length attempt.ordered
      || not (List.for_all2 revision_link_equal ordered attempt.ordered)
    then Error Current_ref_attempt_mismatch
    else
      List.fold_left
        (fun result conflict_id ->
          let* () = result in
          let* conflict, _ = find_conflict_object store conflict_id in
          if
            Id.Workspace_id.equal conflict.workspace attempt.workspace
            && Id.Workspace_revision_id.equal conflict.workspace_revision
                 attempt.workspace_revision
            && Option.equal Id.Workspace_attempt_id.equal conflict.attempt
                 (Some attempt.id)
            && Snapshot.Snapshot.equal_id conflict.base attempt.base
          then Ok ()
          else Error Current_ref_attempt_mismatch)
        (Ok ()) attempt.conflicts

let read_current_bytes store workspace =
  Store.Ref_file.read store ~components:(current_ref_components workspace)
  |> Result.map_error (fun error -> Store_error error)

let read_current_ref store workspace =
  let* bytes = read_current_bytes store workspace in
  match bytes with
  | None -> Error (Workspace_missing workspace)
  | Some bytes ->
      decode_current_ref bytes
      |> Result.map_error (fun error ->
          Current_ref_corrupt (error_to_string error))

let resolve_from_ref store (current : current_ref) =
  let* workspace = load_workspace store current.workspace_object in
  if not (Id.Workspace_id.equal workspace.id current.workspace) then
    Error Current_ref_workspace_mismatch
  else
    let* revision = load_revision store current.revision_object in
    if not (Id.Workspace_revision_id.equal revision.id current.revision) then
      Error Current_ref_revision_mismatch
    else if not (Id.Workspace_id.equal revision.workspace current.workspace)
    then Error Current_ref_revision_mismatch
    else
      let* order = validate_revision_links store revision in
      let* () = validate_resolution_bindings store revision in
      let* () =
        match current.latest_attempt with
        | None -> Ok ()
        | Some (attempt_id, attempt_object) ->
            let* attempt = load_attempt store attempt_object in
            if not (Id.Workspace_attempt_id.equal attempt.id attempt_id) then
              Error Current_ref_attempt_mismatch
            else if
              not (Id.Workspace_id.equal attempt.workspace current.workspace)
            then Error Current_ref_attempt_mismatch
            else if
              not
                (Id.Workspace_revision_id.equal attempt.workspace_revision
                   current.revision)
            then Error Current_ref_attempt_mismatch
            else validate_attempt_context store revision order attempt
      in
      Ok
        {
          workspace;
          workspace_object = current.workspace_object;
          revision;
          revision_object = current.revision_object;
          current;
        }

let publish_current store ~expected ~(next : current_ref) =
  Store.Ref_file.compare_and_swap store
    ~components:(current_ref_components next.workspace)
    ~expected ~replacement:(encode_current_ref next)
  |> Result.map_error (function
    | Store.Concurrent_ref_file_update _ ->
        Concurrent_current_update
          {
            workspace = next.workspace;
            expected_generation =
              Option.bind expected (fun bytes ->
                  decode_current_ref bytes |> Result.to_option
                  |> Option.map current_generation);
            actual_generation = None;
          }
    | error -> Store_error error)

let with_repository_lock store action =
  Store.with_lock store ~name:"repository-writer"
    ~on_error:(fun error -> Store_error error)
    action

let store_state_snapshot store state =
  let entries = Scratch.State.entries state in
  let rec is_prefix prefix path =
    match (prefix, path) with
    | [], _ -> true
    | component :: prefix, candidate :: path ->
        String.equal component candidate && is_prefix prefix path
    | _ :: _, [] -> false
  in
  let direct_child_name prefix path =
    let prefix_length = List.length prefix in
    if List.length path = prefix_length + 1 && is_prefix prefix path then
      match List.rev path with name :: _ -> Some name | [] -> None
    else None
  in
  let rec store_tree prefix =
    let direct =
      List.filter_map
        (fun (path, entry) ->
          match direct_child_name prefix path with
          | None -> None
          | Some name -> Some (name, entry))
        entries
    in
    let rec build reversed = function
      | [] -> Ok (List.rev reversed)
      | (name, Scratch.File { mode; content }) :: rest ->
          build ((name, Snapshot.Tree.File { mode; content }) :: reversed) rest
      | (name, Scratch.Directory) :: rest ->
          let* child = store_tree (prefix @ [ name ]) in
          build ((name, Snapshot.Tree.Directory child) :: reversed) rest
    in
    let* tree_entries = build [] direct in
    let* tree =
      Snapshot.Tree.create tree_entries
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    Snapshot.Tree.store store tree
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* root = store_tree [] in
  Snapshot.Snapshot.store store (Snapshot.Snapshot.create ~root)
  |> Result.map_error (fun error -> Snapshot_error error)

let workspace_conflict_kind = function
  | Workspace.Missing_or_ambiguous_precondition ->
      Missing_or_ambiguous_precondition
  | Workspace.Competing_edits -> Competing_edits
  | Workspace.Delete_modify -> Delete_modify
  | Workspace.Move_modify -> Move_modify
  | Workspace.Binary_conflict -> Binary_conflict
  | Workspace.Dependency_failure -> Dependency_failure
  | Workspace.Unsupported_or_uncertain_operation ->
      Unsupported_or_uncertain_operation

let application_key conflict =
  ( conflict.Workspace.conflict_capsule,
    conflict.Workspace.conflict_revision,
    conflict.Workspace.operation_index )

let find_conflict mapping conflict =
  let capsule, revision, operation_index = application_key conflict in
  List.find_map
    (fun (candidate, stored) ->
      let candidate_capsule, candidate_revision, candidate_index =
        application_key candidate
      in
      if
        Id.Capsule_id.equal capsule candidate_capsule
        && Id.Capsule_revision_id.equal revision candidate_revision
        && Int.equal operation_index candidate_index
      then Some stored
      else None)
    mapping

let find_capsule_revision_link store identity =
  let paths = all_object_ids (Store.root store) |> List.sort String.compare in
  let rec loop = function
    | [] ->
        Error
          (Selected_link_mismatch
             ("capsule revision is missing: "
             ^ Id.Capsule_revision_id.to_hex identity))
    | path :: rest -> (
        let name = Filename.basename path in
        let parent = Filename.basename (Filename.dirname path) in
        let grandparent =
          Filename.basename (Filename.dirname (Filename.dirname path))
        in
        let hex = grandparent ^ parent ^ name in
        match Store.Stored_object_id.of_hex hex with
        | Error _ -> loop rest
        | Ok object_id -> (
            match Capsule_store.load_revision store object_id with
            | Ok revision
              when Id.Capsule_revision_id.equal identity
                     (Capsule_store.revision_id revision) ->
                Ok
                  (Capsule_store.make_revision_link
                     ~capsule:(Capsule_store.revision_capsule revision)
                     ~revision:identity ~object_id)
            | Ok _ | Error _ -> loop rest))
  in
  loop paths

module Durable = struct
  type materialisation = {
    attempt : workspace_attempt;
    attempt_object : Store.Stored_object_id.t;
    conflicts : (conflict * Store.Stored_object_id.t) list;
    actions : Scratch.operation list;
    scratch_checkpoint : Scratch.Checkpoint_id.t option;
    partial : bool;
  }

  let read_current store workspace =
    let* current = read_current_ref store workspace in
    resolve_from_ref store current

  let create_revision_from_links store ~workspace ~parent ~base ~selected
      ~explicit_order ~resolutions ~provenance ~created_at =
    let selected = sort_links selected in
    let precedence =
      precedence_of_order explicit_order |> List.sort precedence_compare
    in
    let* order, _ = order_for_links store ~selected ~precedence in
    let resolved_order =
      Workspace.revisions order
      |> List.map (fun selected -> selected.Workspace.revision)
    in
    let resolutions = List.sort binding_compare resolutions in
    create_revision ~workspace ~parent ~base ~selected ~precedence
      ~resolved_order ~resolutions ~provenance ~created_at

  let publish_revision store ~expected_bytes ~workspace ~workspace_object
      ~previous ~revision =
    let* revision_object = store_revision store revision in
    let* _ = validate_revision_links store revision in
    let generation =
      match previous with
      | None -> Ok 0L
      | Some current ->
          if Int64.equal current.generation Int64.max_int then
            Error (Invalid_generation current.generation)
          else Ok (Int64.succ current.generation)
    in
    let* generation = generation in
    let* current =
      make_current_ref ~generation ~workspace ~workspace_object
        ~revision:revision.id ~revision_object ~latest_attempt:None
    in
    let* () = publish_current store ~expected:expected_bytes ~next:current in
    resolve_from_ref store current

  let create ~store ~id ~base ~name ~description ~created_at =
    with_repository_lock store (fun () ->
        let* _ =
          Snapshot.Snapshot.load store base
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        let* workspace = create_workspace ~id ~created_at ~name ~description in
        let* initial =
          create_revision_from_links store ~workspace:id ~parent:None ~base
            ~selected:[] ~explicit_order:None ~resolutions:[]
            ~provenance:Created ~created_at
        in
        let* existing = read_current_bytes store id in
        let* workspace_object = store_workspace store workspace in
        match existing with
        | None ->
            publish_revision store ~expected_bytes:None ~workspace:id
              ~workspace_object ~previous:None ~revision:initial
        | Some bytes ->
            let* current =
              decode_current_ref bytes
              |> Result.map_error (fun error ->
                  Current_ref_corrupt (error_to_string error))
            in
            if
              Store.Stored_object_id.equal current.workspace_object
                workspace_object
              && Id.Workspace_revision_id.equal current.revision initial.id
            then resolve_from_ref store current
            else Error (Conflicting_workspace_id_reuse id))

  let list store =
    let directory =
      Filename.concat
        (Filename.concat
           (Filename.concat (Store.root store) ".yeokcham")
           "refs")
        "workspaces"
    in
    match Sys.readdir directory with
    | exception Sys_error message
      when String.ends_with ~suffix:"No such file or directory" message ->
        Ok []
    | exception Sys_error message -> Error (Materialisation_error message)
    | names ->
        List.sort String.compare (Array.to_list names)
        |> List.fold_left
             (fun result name ->
               let* reversed = result in
               match Id.Workspace_id.of_hex name with
               | Error _ -> Ok reversed
               | Ok workspace ->
                   let* resolved = read_current store workspace in
                   Ok (resolved :: reversed))
             (Ok [])
        |> Result.map List.rev

  let generation_matches expected current workspace =
    match expected with
    | None -> Ok ()
    | Some expected when Int64.equal expected current.generation -> Ok ()
    | Some expected ->
        Error
          (Concurrent_current_update
             {
               workspace;
               expected_generation = Some expected;
               actual_generation = Some current.generation;
             })

  let existing_explicit_order revision =
    explicit_order_of_precedence ~selected:revision.selected revision.precedence

  let enable_link ~store ~workspace ~link ~expected_generation ~created_at =
    let capsule = Capsule_store.revision_link_capsule link in
    let* existing_bytes = read_current_bytes store workspace in
    let* current = read_current_ref store workspace in
    let* () = generation_matches expected_generation current workspace in
    let* resolved = resolve_from_ref store current in
    let already_selected =
      List.find_opt
        (fun candidate ->
          Id.Capsule_id.equal capsule
            (Capsule_store.revision_link_capsule candidate))
        resolved.revision.selected
    in
    match already_selected with
    | Some candidate
      when Id.Capsule_revision_id.equal
             (Capsule_store.revision_link_revision candidate)
             (Capsule_store.revision_link_revision link) ->
        Ok resolved
    | _ ->
        let selected =
          link
          :: List.filter
               (fun candidate ->
                 not
                   (Id.Capsule_id.equal capsule
                      (Capsule_store.revision_link_capsule candidate)))
               resolved.revision.selected
        in
        let* explicit_order = existing_explicit_order resolved.revision in
        let explicit_order =
          match explicit_order with
          | None -> None
          | Some values ->
              Some
                (List.filter
                   (fun identity ->
                     not
                       (Id.Capsule_id.equal capsule
                          (Capsule_store.revision_link_capsule
                             (List.find
                                (fun item ->
                                  Id.Capsule_revision_id.equal identity
                                    (Capsule_store.revision_link_revision item))
                                resolved.revision.selected))))
                   values
                @ [ Capsule_store.revision_link_revision link ])
        in
        let parent =
          Some
            {
              parent_revision = resolved.revision.id;
              parent_object_id = resolved.revision_object;
            }
        in
        let* revision =
          create_revision_from_links store ~workspace ~parent
            ~base:resolved.revision.base ~selected ~explicit_order
            ~resolutions:resolved.revision.resolutions
            ~provenance:(Enabled (Capsule_store.revision_link_revision link))
            ~created_at
        in
        publish_revision store ~expected_bytes:existing_bytes ~workspace
          ~workspace_object:resolved.workspace_object ~previous:(Some current)
          ~revision

  let enable_current_capsule ~store ~workspace ~capsule ~expected_generation
      ~created_at =
    with_repository_lock store (fun () ->
        let* selected_capsule =
          Capsule_store.Durable.read_current store capsule
          |> Result.map_error (fun error ->
              Selected_link_mismatch (Capsule_store.error_to_string error))
        in
        let link =
          Capsule_store.make_revision_link ~capsule
            ~revision:
              (Capsule_store.revision_id
                 (Capsule_store.Durable.resolved_revision selected_capsule))
            ~object_id:
              (Capsule_store.Durable.resolved_revision_object selected_capsule)
        in
        enable_link ~store ~workspace ~link ~expected_generation ~created_at)

  let enable_revision ~store ~workspace ~revision ~expected_generation
      ~created_at =
    with_repository_lock store (fun () ->
        let* link = find_capsule_revision_link store revision in
        enable_link ~store ~workspace ~link ~expected_generation ~created_at)

  let disable_capsule ~store ~workspace ~capsule ~expected_generation
      ~created_at =
    with_repository_lock store (fun () ->
        let* existing_bytes = read_current_bytes store workspace in
        let* current = read_current_ref store workspace in
        let* () = generation_matches expected_generation current workspace in
        let* resolved = resolve_from_ref store current in
        match
          List.find_opt
            (fun candidate ->
              Id.Capsule_id.equal capsule
                (Capsule_store.revision_link_capsule candidate))
            resolved.revision.selected
        with
        | None -> Ok resolved
        | Some removed ->
            let selected =
              List.filter
                (fun candidate ->
                  not
                    (Id.Capsule_id.equal capsule
                       (Capsule_store.revision_link_capsule candidate)))
                resolved.revision.selected
            in
            let* explicit_order = existing_explicit_order resolved.revision in
            let explicit_order =
              Option.map
                (List.filter (fun identity ->
                     not
                       (Id.Capsule_revision_id.equal identity
                          (Capsule_store.revision_link_revision removed))))
                explicit_order
            in
            let parent =
              Some
                {
                  parent_revision = resolved.revision.id;
                  parent_object_id = resolved.revision_object;
                }
            in
            let* revision =
              create_revision_from_links store ~workspace ~parent
                ~base:resolved.revision.base ~selected ~explicit_order
                ~resolutions:resolved.revision.resolutions
                ~provenance:
                  (Disabled (Capsule_store.revision_link_revision removed))
                ~created_at
            in
            publish_revision store ~expected_bytes:existing_bytes ~workspace
              ~workspace_object:resolved.workspace_object
              ~previous:(Some current) ~revision)

  let reorder ~store ~workspace ~order ~expected_generation ~created_at =
    with_repository_lock store (fun () ->
        let* existing_bytes = read_current_bytes store workspace in
        let* current = read_current_ref store workspace in
        let* () = generation_matches expected_generation current workspace in
        let* resolved = resolve_from_ref store current in
        let parent =
          Some
            {
              parent_revision = resolved.revision.id;
              parent_object_id = resolved.revision_object;
            }
        in
        let* revision =
          create_revision_from_links store ~workspace ~parent
            ~base:resolved.revision.base ~selected:resolved.revision.selected
            ~explicit_order:(Some order)
            ~resolutions:resolved.revision.resolutions ~provenance:Reordered
            ~created_at
        in
        if Id.Workspace_revision_id.equal revision.id resolved.revision.id then
          Ok resolved
        else
          publish_revision store ~expected_bytes:existing_bytes ~workspace
            ~workspace_object:resolved.workspace_object ~previous:(Some current)
            ~revision)

  let explain_order store workspace =
    let* resolved = read_current store workspace in
    validate_revision_links store resolved.revision

  let resolution_actions store (revision : workspace_revision) =
    List.fold_left
      (fun result (binding : resolution_binding) ->
        let* reversed = result in
        let* resolution = load_resolution store binding.binding_object_id in
        if not (Id.Resolution_id.equal resolution.id binding.binding_resolution)
        then
          Error
            (Resolution_binding_mismatch
               "resolution logical ID disagrees with object")
        else if
          not
            (Id.Conflict_id.equal resolution.conflict binding.binding_conflict)
        then
          Error
            (Resolution_binding_mismatch
               "resolution conflict disagrees with binding")
        else
          match resolution.action with
          | Skip_operation ->
              let* conflict, _ =
                find_conflict_object store binding.binding_conflict
              in
              if
                not
                  (Id.Workspace_id.equal conflict.workspace revision.workspace)
              then
                Error
                  (Resolution_binding_mismatch
                     "conflict belongs to another workspace")
              else
                Ok
                  (Workspace.Skip_operation
                     {
                       capsule = conflict.capsule;
                       revision = conflict.capsule_revision;
                       operation_index = conflict.operation_index;
                     }
                  :: reversed))
      (Ok []) revision.resolutions
    |> Result.map List.rev

  let ordered_application_revisions store revision =
    let* order = validate_revision_links store revision in
    let links_by_revision =
      List.map
        (fun link -> (Capsule_store.revision_link_revision link, link))
        revision.selected
    in
    Workspace.revisions order
    |> List.fold_left
         (fun result selected ->
           let* reversed = result in
           let link =
             List.find_opt
               (fun (identity, _) ->
                 Id.Capsule_revision_id.equal identity
                   selected.Workspace.revision)
               links_by_revision
           in
           match link with
           | None ->
               Error
                 (Selected_link_mismatch "resolved order lacks a selected link")
           | Some (_, link) ->
               let* revision = validate_selected_link store link in
               Ok
                 ({
                    Workspace.selected;
                    operations = Capsule_store.revision_operations revision;
                  }
                 :: reversed))
         (Ok [])
    |> Result.map List.rev

  let verify_attempt ~store ~(revision : workspace_revision)
      ~(attempt : workspace_attempt) =
    if
      (not (Id.Workspace_id.equal attempt.workspace revision.workspace))
      || not
           (Id.Workspace_revision_id.equal attempt.workspace_revision
              revision.id)
    then Error Current_ref_attempt_mismatch
    else
      let* order = validate_revision_links store revision in
      let* () = validate_resolution_bindings store revision in
      let* () = validate_attempt_context store revision order attempt in
      let* base =
        Snapshot.Snapshot.load store revision.base
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let* state =
        Scratch.State.of_snapshot store base
        |> Result.map_error (fun error -> Scratch_error error)
      in
      let* ordered = ordered_application_revisions store revision in
      let* resolutions = resolution_actions store revision in
      let application = Workspace.apply ~state ~ordered ~resolutions in
      let* resulting =
        Snapshot.Snapshot.load store attempt.resulting_snapshot
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let* resulting =
        Scratch.State.of_snapshot store resulting
        |> Result.map_error (fun error -> Scratch_error error)
      in
      if Scratch.State.equal application.state resulting then Ok ()
      else
        Error
          (Materialisation_error
             "workspace attempt result disagrees with immutable replay")

  let materialise_application ~store ~(resolved : resolved) ~starting_checkpoint
      ~starting_snapshot ~created_at ~dry_run =
    let* base =
      Snapshot.Snapshot.load store resolved.revision.base
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* state =
      Scratch.State.of_snapshot store base
      |> Result.map_error (fun error -> Scratch_error error)
    in
    let* ordered = ordered_application_revisions store resolved.revision in
    let* resolutions = resolution_actions store resolved.revision in
    let application = Workspace.apply ~state ~ordered ~resolutions in
    let ordered_links =
      List.map
        (fun item ->
          match
            List.find_opt
              (fun link ->
                Id.Capsule_revision_id.equal item.Workspace.selected.revision
                  (Capsule_store.revision_link_revision link))
              resolved.revision.selected
          with
          | Some link -> link
          | None -> assert false)
        ordered
    in
    let attempt_id =
      derive_attempt_id ~workspace:resolved.workspace.id
        ~workspace_revision:resolved.revision.id ~base:resolved.revision.base
        ~ordered:ordered_links ~starting_checkpoint ~starting_snapshot
    in
    let* persisted_conflicts =
      List.fold_left
        (fun result application_conflict ->
          let* reversed = result in
          let* conflict =
            create_conflict ~workspace:resolved.workspace.id
              ~workspace_revision:resolved.revision.id
              ~attempt:(Some attempt_id) ~base:resolved.revision.base
              ~capsule:application_conflict.Workspace.conflict_capsule
              ~capsule_revision:application_conflict.Workspace.conflict_revision
              ~operation_index:application_conflict.Workspace.operation_index
              ~kind:
                (workspace_conflict_kind application_conflict.Workspace.kind)
              ~paths:application_conflict.Workspace.paths
              ~current:application_conflict.Workspace.current
              ~candidates:[ "skip-operation" ] ~created_at
          in
          let* object_id =
            if dry_run then
              let* payload = conflict_payload conflict in
              let* envelope = object_envelope Envelope.Conflict payload in
              Ok (Store.id_of_envelope envelope)
            else store_conflict store conflict
          in
          Ok ((application_conflict, (conflict, object_id)) :: reversed))
        (Ok []) application.conflicts
    in
    let persisted_conflicts = List.rev persisted_conflicts in
    let conflict_ids =
      List.map
        (fun (_, ((conflict : conflict), _)) -> conflict.id)
        persisted_conflicts
    in
    let outcome_of_workspace = function
      | Workspace.Applied_exactly { capsule; revision; operation_index } ->
          Ok (Attempt_applied_exactly { capsule; revision; operation_index })
      | Workspace.Already_satisfied { capsule; revision; operation_index } ->
          Ok (Attempt_already_satisfied { capsule; revision; operation_index })
      | Workspace.Resolved_explicitly { capsule; revision; operation_index } ->
          Ok
            (Attempt_resolved_explicitly { capsule; revision; operation_index })
      | Workspace.Persistent_conflict conflict ->
          find_conflict persisted_conflicts conflict
          |> Option.to_result
               ~none:(Materialisation_error "missing persisted conflict")
          |> Result.map (fun ((conflict : conflict), _) ->
              Attempt_persistent_conflict conflict.id)
      | Workspace.Rejected_operation conflict ->
          find_conflict persisted_conflicts conflict
          |> Option.to_result
               ~none:(Materialisation_error "missing persisted conflict")
          |> Result.map (fun ((conflict : conflict), _) ->
              Attempt_rejected_operation conflict.id)
      | Workspace.Blocked_dependency
          { capsule; revision; operation_index; blocked_by } ->
          find_conflict persisted_conflicts blocked_by
          |> Option.to_result
               ~none:(Materialisation_error "missing blocked conflict")
          |> Result.map (fun ((conflict : conflict), _) ->
              Attempt_blocked_dependency
                { capsule; revision; operation_index; blocked_by = conflict.id })
    in
    let* outcomes =
      List.fold_left
        (fun result outcome ->
          let* reversed = result in
          let* outcome = outcome_of_workspace outcome in
          Ok (outcome :: reversed))
        (Ok []) application.outcomes
      |> Result.map List.rev
    in
    let* resulting_snapshot = store_state_snapshot store application.state in
    let* attempt =
      create_attempt ~id:attempt_id ~workspace:resolved.workspace.id
        ~workspace_revision:resolved.revision.id ~base:resolved.revision.base
        ~ordered:ordered_links ~starting_checkpoint ~starting_snapshot ~outcomes
        ~resulting_snapshot ~conflicts:conflict_ids ~created_at
    in
    let* attempt_object =
      if dry_run then
        let* payload = attempt_payload attempt in
        let* envelope = object_envelope Envelope.Workspace_attempt payload in
        Ok (Store.id_of_envelope envelope)
      else store_attempt store attempt
    in
    Ok
      ( attempt,
        attempt_object,
        List.map snd persisted_conflicts,
        resulting_snapshot,
        conflict_ids <> [] )

  let starting_context scratch =
    let* checkpoint =
      Scratch.head_id scratch
      |> Result.map_error (fun error -> Scratch_error error)
    in
    let* checkpoint =
      match checkpoint with
      | Some checkpoint -> Ok checkpoint
      | None ->
          Error (Materialisation_error "scratch history is not initialized")
    in
    let* resolved =
      Scratch.resolve_checkpoint scratch checkpoint
      |> Result.map_error (fun error -> Scratch_error error)
    in
    Ok
      ( checkpoint,
        Scratch.Checkpoint.snapshot (Scratch.resolved_checkpoint resolved) )

  let preserve_working_snapshot ~store scratch ~root ~observed_at ~created_at =
    let* observed, _ =
      Snapshot.scan ~root ~store
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* head =
      Scratch.head scratch
      |> Result.map_error (fun error -> Scratch_error error)
    in
    match head with
    | None -> Error (Materialisation_error "scratch history is not initialized")
    | Some checkpoint
      when Snapshot.Snapshot.equal_id observed
             (Scratch.Checkpoint.snapshot checkpoint) ->
        Ok ()
    | Some _ ->
        Scratch.checkpoint scratch ~snapshot:observed ~source:Scratch.Scan
          ~observed_at ~created_at
        |> Result.map_error (fun error -> Scratch_error error)
        |> Result.map (fun _ -> ())

  let actions_to_state store ~root state =
    let* _, observed =
      Snapshot.scan ~root ~store
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* observed =
      Scratch.State.of_snapshot store observed
      |> Result.map_error (fun error -> Scratch_error error)
    in
    Ok (Scratch.State.diff ~from:observed ~to_:state)

  let materialise ~store ~scratch ~root ~workspace ~observed_at ~created_at
      ~dry_run ?before_apply ?on_progress () =
    with_repository_lock store (fun () ->
        let* _ = read_current_ref store workspace in
        let* () =
          if dry_run then Ok ()
          else
            preserve_working_snapshot ~store scratch ~root ~observed_at
              ~created_at
        in
        let* expected_bytes = read_current_bytes store workspace in
        let* current = read_current_ref store workspace in
        let* resolved = resolve_from_ref store current in
        let* starting_checkpoint, starting_snapshot =
          starting_context scratch
        in
        let* attempt, attempt_object, conflicts, resulting_snapshot, partial =
          materialise_application ~store ~resolved ~starting_checkpoint
            ~starting_snapshot ~created_at ~dry_run
        in
        if dry_run then
          let* state =
            Snapshot.Snapshot.load store resulting_snapshot
            |> Result.map_error (fun error -> Snapshot_error error)
          in
          let* state =
            Scratch.State.of_snapshot store state
            |> Result.map_error (fun error -> Scratch_error error)
          in
          let* actions = actions_to_state store ~root state in
          Ok
            {
              attempt;
              attempt_object;
              conflicts;
              actions;
              scratch_checkpoint = None;
              partial;
            }
        else
          let* plan =
            Scratch.Restore.prepare_snapshot scratch ~root
              ~target_snapshot:resulting_snapshot ~observed_at ~created_at
            |> Result.map_error (fun error -> Scratch_error error)
          in
          let actions = Scratch.Restore.actions plan in
          Option.iter (fun callback -> callback ()) before_apply;
          let* () =
            Scratch.Restore.apply ?on_progress scratch ~root plan
            |> Result.map_error (fun error -> Scratch_error error)
          in
          let* scratch_checkpoint =
            Scratch.head_id scratch
            |> Result.map_error (fun error -> Scratch_error error)
          in
          let* scratch_checkpoint =
            match scratch_checkpoint with
            | Some checkpoint -> Ok checkpoint
            | None ->
                Error
                  (Materialisation_error
                     "scratch head vanished after materialisation")
          in
          let* current_bytes = read_current_bytes store workspace in
          if not (Option.equal String.equal expected_bytes current_bytes) then
            Error
              (Concurrent_current_update
                 {
                   workspace;
                   expected_generation = Some current.generation;
                   actual_generation = None;
                 })
          else if Int64.equal current.generation Int64.max_int then
            Error (Invalid_generation current.generation)
          else
            let* next =
              make_current_ref
                ~generation:(Int64.succ current.generation)
                ~workspace ~workspace_object:resolved.workspace_object
                ~revision:resolved.revision.id
                ~revision_object:resolved.revision_object
                ~latest_attempt:(Some (attempt.id, attempt_object))
            in
            let* () = publish_current store ~expected:expected_bytes ~next in
            Ok
              {
                attempt;
                attempt_object;
                conflicts;
                actions;
                scratch_checkpoint = Some scratch_checkpoint;
                partial;
              })

  let ancestor_revision_ids store (revision : workspace_revision) =
    let rec visit seen (candidate : workspace_revision) =
      if
        List.exists
          (fun identity -> Id.Workspace_revision_id.equal identity candidate.id)
          seen
      then Error (Parent_link_mismatch "workspace revision parent cycle")
      else
        let seen = candidate.id :: seen in
        match candidate.parent with
        | None -> Ok seen
        | Some parent ->
            let* parent_revision =
              load_revision store parent.parent_object_id
            in
            if
              not
                (Id.Workspace_revision_id.equal parent.parent_revision
                   parent_revision.id)
            then
              Error
                (Parent_link_mismatch
                   "logical parent ID disagrees with parent object")
            else if
              not
                (Id.Workspace_id.equal candidate.workspace
                   parent_revision.workspace)
            then
              Error (Parent_link_mismatch "parent belongs to another workspace")
            else visit seen parent_revision
    in
    visit [] revision

  let all_conflicts store =
    all_object_ids (Store.root store)
    |> List.sort String.compare
    |> List.fold_left
         (fun result path ->
           let* conflicts = result in
           let name = Filename.basename path in
           let parent = Filename.basename (Filename.dirname path) in
           let grandparent =
             Filename.basename (Filename.dirname (Filename.dirname path))
           in
           match
             Store.Stored_object_id.of_hex (grandparent ^ parent ^ name)
           with
           | Error _ -> Ok conflicts
           | Ok object_id -> (
               match load_conflict store object_id with
               | Ok conflict -> Ok (conflict :: conflicts)
               | Error _ -> Ok conflicts))
         (Ok [])
    |> Result.map (fun conflicts ->
        List.sort
          (fun (left : conflict) (right : conflict) ->
            Id.Conflict_id.compare left.id right.id)
          conflicts)

  let list_conflicts store workspace =
    let* resolved = read_current store workspace in
    let* ancestry = ancestor_revision_ids store resolved.revision in
    let resolved_conflicts =
      List.map
        (fun (binding : resolution_binding) -> binding.binding_conflict)
        resolved.revision.resolutions
    in
    let* conflicts = all_conflicts store in
    let revision_rank revision =
      List.find_index
        (fun identity -> Id.Workspace_revision_id.equal identity revision)
        ancestry
    in
    let candidate (conflict : conflict) =
      Id.Workspace_id.equal conflict.workspace workspace
      && Option.is_some (revision_rank conflict.workspace_revision)
      && not
           (List.exists
              (fun resolved -> Id.Conflict_id.equal resolved conflict.id)
              resolved_conflicts)
    in
    let conflicts = List.filter candidate conflicts in
    let superseded (conflict : conflict) =
      let rank = Option.get (revision_rank conflict.workspace_revision) in
      List.exists
        (fun (other : conflict) ->
          let other_rank =
            Option.get (revision_rank other.workspace_revision)
          in
          other_rank < rank
          && Id.Capsule_id.equal other.capsule conflict.capsule
          && Id.Capsule_revision_id.equal other.capsule_revision
               conflict.capsule_revision
          && Int.equal other.operation_index conflict.operation_index)
        conflicts
    in
    Ok (List.filter (fun conflict -> not (superseded conflict)) conflicts)

  let show_conflict store conflict =
    find_conflict_object store conflict |> Result.map fst

  let resolve_skip ~store ~workspace ~conflict ~expected_generation ~created_at
      =
    with_repository_lock store (fun () ->
        let* existing_bytes = read_current_bytes store workspace in
        let* current = read_current_ref store workspace in
        let* () = generation_matches expected_generation current workspace in
        let* resolved = resolve_from_ref store current in
        let* target, _ = find_conflict_object store conflict in
        if not (Id.Workspace_id.equal target.workspace workspace) then
          Error (Stale_resolution "conflict belongs to another workspace")
        else if
          List.exists
            (fun (binding : resolution_binding) ->
              Id.Conflict_id.equal binding.binding_conflict conflict)
            resolved.revision.resolutions
        then
          Error (Stale_resolution "conflict already has an active resolution")
        else
          let* ancestry = ancestor_revision_ids store resolved.revision in
          if
            (not
               (List.exists
                  (fun revision ->
                    Id.Workspace_revision_id.equal revision
                      target.workspace_revision)
                  ancestry))
            || (not
                  (Snapshot.Snapshot.equal_id target.base resolved.revision.base))
            || not
                 (List.exists
                    (fun link ->
                      Id.Capsule_id.equal target.capsule
                        (Capsule_store.revision_link_capsule link)
                      && Id.Capsule_revision_id.equal target.capsule_revision
                           (Capsule_store.revision_link_revision link))
                    resolved.revision.selected)
          then
            Error
              (Stale_resolution
                 "conflict context is not active in the current workspace")
          else
            let* resolution =
              create_resolution ~conflict:target ~action:Skip_operation
                ~expected_current:target.current ~created_at
            in
            let* resolution_object = store_resolution store resolution in
            let binding =
              {
                binding_conflict = conflict;
                binding_resolution = resolution.id;
                binding_object_id = resolution_object;
              }
            in
            let parent =
              Some
                {
                  parent_revision = resolved.revision.id;
                  parent_object_id = resolved.revision_object;
                }
            in
            let* explicit_order = existing_explicit_order resolved.revision in
            let* revision =
              create_revision_from_links store ~workspace ~parent
                ~base:resolved.revision.base
                ~selected:resolved.revision.selected ~explicit_order
                ~resolutions:(binding :: resolved.revision.resolutions)
                ~provenance:(Resolved resolution.id) ~created_at
            in
            publish_revision store ~expected_bytes:existing_bytes ~workspace
              ~workspace_object:resolved.workspace_object
              ~previous:(Some current) ~revision)
end
