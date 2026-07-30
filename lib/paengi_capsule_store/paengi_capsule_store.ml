module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Hash = Paengi_hash.Sha256
module Id = Paengi_id
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Capsule = Paengi_capsule

[@@@warning "-4-40-42"]

type source_boundary = {
  source : Scratch.Checkpoint_id.t;
  target : Scratch.Checkpoint_id.t;
}

type revision_link = {
  capsule : Id.Capsule_id.t;
  revision : Id.Capsule_revision_id.t;
  object_id : Store.Stored_object_id.t;
}

type parent_link = {
  revision : Id.Capsule_revision_id.t;
  object_id : Store.Stored_object_id.t;
}

type provenance =
  | Created
  | Folded
  | Split_from of revision_link
  | Combined_from of revision_link list

type capsule = {
  model : Capsule.capsule;
  created_at : int64;
}

type revision = {
  model : Capsule.revision;
  parent : parent_link option;
  expected_result : Snapshot.Snapshot.id;
  dependencies : Capsule.dependency list;
  boundaries : source_boundary list;
  provenance : provenance;
}

type current_ref = {
  generation : int64;
  capsule : Id.Capsule_id.t;
  capsule_object : Store.Stored_object_id.t;
  revision : Id.Capsule_revision_id.t;
  revision_object : Store.Stored_object_id.t;
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
  | Noncanonical_bytes of string
  | Logical_revision_id_mismatch of {
      supplied : Id.Capsule_revision_id.t;
      derived : Id.Capsule_revision_id.t;
    }
  | Invalid_current_ref_checksum

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error message -> "invalid capsule schema: " ^ message
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported capsule schema version: %Ld" version
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "expected object type %d, got object type %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)
  | Invalid_identity_length { kind; length } ->
      Printf.sprintf "%s must be 32 bytes, got %d" kind length
  | Invalid_generation generation ->
      Printf.sprintf "capsule ref generation must be non-negative, got %Ld"
        generation
  | Noncanonical_bytes name -> name ^ " bytes are noncanonical"
  | Logical_revision_id_mismatch _ ->
      "capsule revision logical ID does not match its canonical preimage"
  | Invalid_current_ref_checksum -> "capsule current ref checksum is invalid"
  | Scratch_error error -> Scratch.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Draft_error message -> message
  | Current_ref_missing capsule ->
      "capsule current ref is missing: " ^ Id.Capsule_id.to_hex capsule
  | Current_ref_corrupt message -> "capsule current ref is corrupt: " ^ message
  | Concurrent_current_update { capsule; expected_generation; actual_generation } ->
      Printf.sprintf "capsule %s changed concurrently: expected generation %s, got %s"
        (Id.Capsule_id.to_hex capsule)
        (Option.fold ~none:"absent" ~some:Int64.to_string expected_generation)
        (Option.fold ~none:"absent" ~some:Int64.to_string actual_generation)
  | Conflicting_capsule_id_reuse capsule ->
      "capsule ID is already bound to different immutable content: "
      ^ Id.Capsule_id.to_hex capsule
  | Current_ref_capsule_mismatch ->
      "capsule current ref does not resolve to its named capsule"
  | Current_ref_revision_mismatch ->
      "capsule current ref does not resolve to its named revision"
  | Parent_link_mismatch message -> "capsule parent link is invalid: " ^ message
  | Revision_history_cycle revision ->
      "capsule revision parent cycle: " ^ Id.Capsule_revision_id.to_hex revision
  | Revision_application_conflict conflicts ->
      "capsule revision cannot replay: "
      ^ String.concat "; " (List.map Capsule.application_conflict_to_string conflicts)
  | Revision_expected_result_mismatch ->
      "capsule revision replay does not reproduce its expected snapshot"
  | Injected_interruption point -> "injected interruption at " ^ point

let ( let* ) = Result.bind

let encoding_array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let raw_id kind to_bytes identity =
  let raw = to_bytes identity in
  if String.length raw = 32 then Ok raw
  else Error (Invalid_identity_length { kind; length = String.length raw })

let raw_stored identity = Store.Stored_object_id.to_raw_bytes identity

let parse_stored kind = function
  | Encoding.Bytes raw -> (
      match Store.Stored_object_id.of_raw_bytes raw with
      | Some identity -> Ok identity
      | None -> Error (Invalid_identity_length { kind; length = String.length raw }))
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
  else Error (Decode_error (Printf.sprintf "%s must contain %d values" name count))

let canonical name value encode decoded =
  let* canonical = encode decoded in
  if String.equal (Encoding.encode value) (Encoding.encode canonical) then Ok ()
  else Error (Noncanonical_bytes name)

let mode_value = function
  | Snapshot.Regular -> Encoding.integer 0L
  | Snapshot.Executable -> Encoding.integer 1L
  | Snapshot.Symlink -> Encoding.integer 2L

let mode_of_value = function
  | Encoding.Integer 0L -> Ok Snapshot.Regular
  | Encoding.Integer 1L -> Ok Snapshot.Executable
  | Encoding.Integer 2L -> Ok Snapshot.Symlink
  | Encoding.Integer value -> Error (Decode_error (Printf.sprintf "invalid file mode: %Ld" value))
  | _ -> Error (Decode_error "file mode must be an integer")

let valid_component component =
  (not (String.is_empty component))
  && not (String.equal component ".")
  && not (String.equal component "..")
  && not (String.contains component '/')
  && not (String.contains component '\000')

let path_value path =
  if path = [] || not (List.for_all valid_component path) then
    Error (Decode_error "operation path is invalid")
  else
    List.map (fun component -> Encoding.bytes component) path |> encoding_array

let path_of_value value =
  let* components = array_values "operation path" value in
  let rec decode reversed = function
    | [] ->
        let path = List.rev reversed in
        if path = [] || not (List.for_all valid_component path) then
          Error (Decode_error "operation path is invalid")
        else Ok path
    | component :: rest ->
        let* component = bytes "path component" component in
        decode (component :: reversed) rest
  in
  decode [] components

let entry_value = function
  | Scratch.Directory -> encoding_array [ Encoding.integer 0L ]
  | Scratch.File { mode; content } ->
      encoding_array
        [
          Encoding.integer 1L;
          mode_value mode;
          Encoding.bytes (raw_stored (Snapshot.Content.stored_object_id content));
        ]

let entry_of_value value =
  let* values = array_values "entry" value in
  match values with
  | [ Encoding.Integer 0L ] -> Ok Scratch.Directory
  | [ Encoding.Integer 1L; mode; content ] ->
      let* mode = mode_of_value mode in
      let* content = parse_stored "entry content ID" content in
      Ok (Scratch.File { mode; content = Snapshot.Content.of_stored_object_id content })
  | _ -> Error (Decode_error "entry has an invalid shape")

let option_entry_value = function
  | None -> Ok Encoding.null
  | Some entry -> entry_value entry

let option_entry_of_value = function
  | Encoding.Null -> Ok None
  | value -> entry_of_value value |> Result.map Option.some

let transition_value transition =
  let* path = path_value transition.Capsule.transition_path in
  let* expected = option_entry_value transition.Capsule.expected_entry in
  let* replacement = option_entry_value transition.Capsule.replacement_entry in
  encoding_array [ path; expected; replacement ]

let transition_of_value value =
  let* fields = exact_array "exact transition" 3 value in
  match fields with
  | [ path; expected; replacement ] ->
      let* transition_path = path_of_value path in
      let* expected_entry = option_entry_of_value expected in
      let* replacement_entry = option_entry_of_value replacement in
      Ok { Capsule.transition_path; expected_entry; replacement_entry }
  | _ -> assert false

let operation_value = function
  | Capsule.Exact_file_transition transition ->
      let* transition = transition_value transition in
      encoding_array [ Encoding.integer 0L; transition ]
  | Capsule.Text_edit edit ->
      let* path = path_value edit.Capsule.edit_path in
      let* anchor =
        encoding_array
          [
            Encoding.bytes edit.Capsule.anchor.Capsule.before_context;
            Encoding.bytes edit.Capsule.anchor.Capsule.selected;
            Encoding.bytes edit.Capsule.anchor.Capsule.after_context;
          ]
      in
      let* fallback = transition_value edit.Capsule.fallback_transition in
      encoding_array
        [ Encoding.integer 1L; path; anchor; Encoding.bytes edit.Capsule.replacement; fallback ]
  | Capsule.Move { source; destination; prior } ->
      let* source = path_value source in
      let* destination = path_value destination in
      let* prior = entry_value prior in
      encoding_array [ Encoding.integer 2L; source; destination; prior ]
  | Capsule.Mode_change { path; expected; replacement } ->
      let* path = path_value path in
      encoding_array [ Encoding.integer 3L; path; mode_value expected; mode_value replacement ]

let operation_of_value value =
  let* fields = array_values "capsule operation" value in
  match fields with
  | Encoding.Integer 0L :: [ transition ] ->
      transition_of_value transition |> Result.map (fun value -> Capsule.Exact_file_transition value)
  | Encoding.Integer 1L :: [ path; anchor; replacement; fallback ] ->
      let* edit_path = path_of_value path in
      let* anchor = exact_array "text anchor" 3 anchor in
      let* anchor =
        match anchor with
        | [ before_context; selected; after_context ] ->
            let* before_context = bytes "text anchor before context" before_context in
            let* selected = bytes "text anchor selected" selected in
            let* after_context = bytes "text anchor after context" after_context in
            Ok { Capsule.before_context; selected; after_context }
        | _ -> assert false
      in
      let* replacement = bytes "text replacement" replacement in
      let* fallback_transition = transition_of_value fallback in
      Ok
        (Capsule.Text_edit
           { Capsule.edit_path; anchor; replacement; fallback_transition })
  | Encoding.Integer 2L :: [ source; destination; prior ] ->
      let* source = path_of_value source in
      let* destination = path_of_value destination in
      let* prior = entry_of_value prior in
      Ok (Capsule.Move { source; destination; prior })
  | Encoding.Integer 3L :: [ path; expected; replacement ] ->
      let* path = path_of_value path in
      let* expected = mode_of_value expected in
      let* replacement = mode_of_value replacement in
      Ok (Capsule.Mode_change { path; expected; replacement })
  | _ -> Error (Decode_error "capsule operation has an invalid shape")

let values_of_list encode values =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* encoded = encode value in
        loop (encoded :: reversed) rest
  in
  loop [] values

let operations_value operations =
  let* values = values_of_list operation_value operations in
  encoding_array values

let operations_of_value value =
  let* values = array_values "capsule operations" value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* operation = operation_of_value value in
        loop (operation :: reversed) rest
  in
  loop [] values

let dependency_value = function
  | Capsule.Requires_capsule { capsule; revision } ->
      let* capsule = raw_id "capsule dependency ID" Id.Capsule_id.to_bytes capsule in
      let* revision =
        match revision with
        | None -> Ok Encoding.null
        | Some revision ->
            raw_id "capsule dependency revision ID" Id.Capsule_revision_id.to_bytes revision
            |> Result.map (fun raw -> Encoding.bytes raw)
      in
      encoding_array [ Encoding.integer 0L; Encoding.bytes capsule; revision ]
  | Capsule.Requires_release release ->
      let* release = raw_id "release dependency ID" Id.Release_id.to_bytes release in
      encoding_array [ Encoding.integer 1L; Encoding.bytes release ]
  | Capsule.Conflicts_with_capsule capsule ->
      let* capsule = raw_id "conflicting capsule ID" Id.Capsule_id.to_bytes capsule in
      encoding_array [ Encoding.integer 2L; Encoding.bytes capsule ]
  | Capsule.Ordered_after capsule ->
      let* capsule = raw_id "ordered capsule ID" Id.Capsule_id.to_bytes capsule in
      encoding_array [ Encoding.integer 3L; Encoding.bytes capsule ]

let dependency_of_value value =
  let* fields = array_values "dependency" value in
  match fields with
  | [ Encoding.Integer 0L; capsule; Encoding.Null ] ->
      parse_id "capsule dependency ID" Id.Capsule_id.of_bytes capsule
      |> Result.map (fun capsule -> Capsule.Requires_capsule { capsule; revision = None })
  | [ Encoding.Integer 0L; capsule; revision ] ->
      let* capsule = parse_id "capsule dependency ID" Id.Capsule_id.of_bytes capsule in
      let* revision = parse_id "capsule dependency revision ID" Id.Capsule_revision_id.of_bytes revision in
      Ok (Capsule.Requires_capsule { capsule; revision = Some revision })
  | [ Encoding.Integer 1L; release ] ->
      parse_id "release dependency ID" Id.Release_id.of_bytes release
      |> Result.map (fun release -> Capsule.Requires_release release)
  | [ Encoding.Integer 2L; capsule ] ->
      parse_id "conflicting capsule ID" Id.Capsule_id.of_bytes capsule
      |> Result.map (fun capsule -> Capsule.Conflicts_with_capsule capsule)
  | [ Encoding.Integer 3L; capsule ] ->
      parse_id "ordered capsule ID" Id.Capsule_id.of_bytes capsule
      |> Result.map (fun capsule -> Capsule.Ordered_after capsule)
  | _ -> Error (Decode_error "dependency has an invalid shape")

let canonical_set name encode values =
  let* values = values_of_list encode values in
  let bytes value = Encoding.encode value in
  let sorted = List.sort (fun left right -> String.compare (bytes left) (bytes right)) values in
  let rec unique previous = function
    | [] -> Ok ()
    | value :: rest ->
        let* () =
          match previous with
          | Some previous when String.equal (bytes previous) (bytes value) ->
              Error (Decode_error (name ^ " contains a duplicate"))
          | _ -> Ok ()
        in
        unique (Some value) rest
  in
  let* () = unique None sorted in
  encoding_array sorted

let canonical_set_of_value name decode value =
  let* values = array_values name value in
  let rec loop reversed previous = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let encoded = Encoding.encode value in
        let* () =
          match previous with
          | Some previous when String.compare previous encoded >= 0 ->
              Error (Noncanonical_bytes name)
          | _ -> Ok ()
        in
        let* decoded = decode value in
        loop (decoded :: reversed) (Some encoded) rest
  in
  loop [] None values

let status_value = function
  | Capsule.Passed -> encoding_array [ Encoding.integer 0L ]
  | Capsule.Failed code -> encoding_array [ Encoding.integer 1L; Encoding.integer (Int64.of_int code) ]
  | Capsule.Timed_out -> encoding_array [ Encoding.integer 2L ]
  | Capsule.Not_run -> encoding_array [ Encoding.integer 3L ]

let status_of_value value =
  let* fields = array_values "validation status" value in
  match fields with
  | [ Encoding.Integer 0L ] -> Ok Capsule.Passed
  | [ Encoding.Integer 1L; Encoding.Integer code ]
    when Int64.compare code (Int64.of_int min_int) >= 0
         && Int64.compare code (Int64.of_int max_int) <= 0 ->
      Ok (Capsule.Failed (Int64.to_int code))
  | [ Encoding.Integer 2L ] -> Ok Capsule.Timed_out
  | [ Encoding.Integer 3L ] -> Ok Capsule.Not_run
  | _ -> Error (Decode_error "validation status has an invalid shape")

let option_stored_value = function
  | None -> Encoding.null
  | Some content -> Encoding.bytes (raw_stored (Snapshot.Content.stored_object_id content))

let option_stored_of_value name = function
  | Encoding.Null -> Ok None
  | value ->
      parse_stored name value
      |> Result.map (fun identity -> Some (Snapshot.Content.of_stored_object_id identity))

let evidence_value evidence =
  let* command = List.map (fun part -> Encoding.bytes part) evidence.Capsule.command |> encoding_array in
  let environment =
    match evidence.Capsule.environment_fingerprint with
    | None -> Ok Encoding.null
    | Some value -> Encoding.text value |> Result.map_error (fun error -> Encoding_error error)
  in
  let* environment = environment in
  let* status = status_value evidence.Capsule.status in
  encoding_array
    [
      command;
      environment;
      Encoding.bytes (raw_stored (Snapshot.Snapshot.stored_object_id evidence.Capsule.snapshot));
      status;
      option_stored_value evidence.Capsule.stdout_digest;
      option_stored_value evidence.Capsule.stderr_digest;
      Encoding.integer evidence.Capsule.started_at;
      Encoding.integer evidence.Capsule.duration_ms;
    ]

let evidence_identity_value evidence =
  let* command = List.map (fun part -> Encoding.bytes part) evidence.Capsule.command |> encoding_array in
  let environment =
    match evidence.Capsule.environment_fingerprint with
    | None -> Ok Encoding.null
    | Some value -> Encoding.text value |> Result.map_error (fun error -> Encoding_error error)
  in
  let* environment = environment in
  let* status = status_value evidence.Capsule.status in
  encoding_array
    [
      command;
      environment;
      Encoding.bytes (raw_stored (Snapshot.Snapshot.stored_object_id evidence.Capsule.snapshot));
      status;
      option_stored_value evidence.Capsule.stdout_digest;
      option_stored_value evidence.Capsule.stderr_digest;
    ]

let evidence_of_value value =
  let* fields = exact_array "validation evidence" 8 value in
  match fields with
  | [ command; environment; snapshot; status; stdout_digest; stderr_digest; started_at; duration_ms ] ->
      let* command = array_values "validation command" command in
      let rec command_parts reversed = function
        | [] -> Ok (List.rev reversed)
        | part :: rest ->
            let* part = bytes "validation command part" part in
            command_parts (part :: reversed) rest
      in
      let* command = command_parts [] command in
      let* environment_fingerprint =
        match environment with
        | Encoding.Null -> Ok None
        | value -> text "validation environment fingerprint" value |> Result.map Option.some
      in
      let* snapshot = parse_stored "validation snapshot ID" snapshot in
      let* status = status_of_value status in
      let* stdout_digest = option_stored_of_value "validation stdout digest" stdout_digest in
      let* stderr_digest = option_stored_of_value "validation stderr digest" stderr_digest in
      let* started_at = integer "validation started at" started_at in
      let* duration_ms = integer "validation duration" duration_ms in
      Ok
        {
          Capsule.command;
          environment_fingerprint;
          snapshot = Snapshot.Snapshot.of_stored_object_id snapshot;
          status;
          stdout_digest;
          stderr_digest;
          started_at;
          duration_ms;
        }
  | _ -> assert false

let parent_value = function
  | None -> Ok Encoding.null
  | Some (parent : parent_link) ->
      let* revision = raw_id "parent revision ID" Id.Capsule_revision_id.to_bytes parent.revision in
      encoding_array [ Encoding.bytes revision; Encoding.bytes (raw_stored parent.object_id) ]

let parent_of_value = function
  | Encoding.Null -> Ok None
  | value ->
      let* fields = exact_array "parent revision link" 2 value in
      match fields with
      | [ revision; object_id ] ->
          let* revision = parse_id "parent revision ID" Id.Capsule_revision_id.of_bytes revision in
          let* object_id = parse_stored "parent revision object ID" object_id in
          Ok (Some { revision; object_id })
      | _ -> assert false

let revision_link_value (link : revision_link) =
  let* capsule = raw_id "revision link capsule ID" Id.Capsule_id.to_bytes link.capsule in
  let* revision = raw_id "revision link revision ID" Id.Capsule_revision_id.to_bytes link.revision in
  encoding_array [ Encoding.bytes capsule; Encoding.bytes revision; Encoding.bytes (raw_stored link.object_id) ]

let revision_link_of_value value =
  let* fields = exact_array "revision link" 3 value in
  match fields with
  | [ capsule; revision; object_id ] ->
      let* capsule = parse_id "revision link capsule ID" Id.Capsule_id.of_bytes capsule in
      let* revision = parse_id "revision link revision ID" Id.Capsule_revision_id.of_bytes revision in
      let* object_id = parse_stored "revision link object ID" object_id in
      Ok { capsule; revision; object_id }
  | _ -> assert false

let boundaries_value boundaries =
  let encode boundary =
    encoding_array
      [
        Encoding.bytes (raw_stored (Scratch.Checkpoint_id.stored_object_id boundary.source));
        Encoding.bytes (raw_stored (Scratch.Checkpoint_id.stored_object_id boundary.target));
      ]
  in
  let* values = values_of_list encode boundaries in
  encoding_array values

let boundaries_of_value value =
  let* values = array_values "source boundaries" value in
  let decode value =
    let* fields = exact_array "source boundary" 2 value in
    match fields with
    | [ source; target ] ->
        let* source = parse_stored "source checkpoint ID" source in
        let* target = parse_stored "target checkpoint ID" target in
        Ok
          {
            source = Scratch.Checkpoint_id.of_stored_object_id source;
            target = Scratch.Checkpoint_id.of_stored_object_id target;
          }
    | _ -> assert false
  in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* boundary = decode value in
        loop (boundary :: reversed) rest
  in
  loop [] values

let provenance_value = function
  | Created -> encoding_array [ Encoding.integer 0L ]
  | Folded -> encoding_array [ Encoding.integer 1L ]
  | Split_from link ->
      let* link = revision_link_value link in
      encoding_array [ Encoding.integer 2L; link ]
  | Combined_from links ->
      let* links = values_of_list revision_link_value links in
      let* links = encoding_array links in
      encoding_array [ Encoding.integer 3L; links ]

let provenance_of_value value =
  let* fields = array_values "provenance" value in
  match fields with
  | [ Encoding.Integer 0L ] -> Ok Created
  | [ Encoding.Integer 1L ] -> Ok Folded
  | [ Encoding.Integer 2L; link ] -> revision_link_of_value link |> Result.map (fun link -> Split_from link)
  | [ Encoding.Integer 3L; links ] ->
      let* links = array_values "combined provenance links" links in
      let rec loop reversed = function
        | [] -> Ok (Combined_from (List.rev reversed))
        | link :: rest ->
            let* link = revision_link_of_value link in
            loop (link :: reversed) rest
      in
      loop [] links
  | _ -> Error (Decode_error "provenance has an invalid shape")

let create_capsule ~id ~title ~description ~created_at =
  let* raw = raw_id "capsule ID" Id.Capsule_id.to_bytes id in
  let _ = raw in
  Capsule.create ~id ~title ~description ~dependencies:[]
  |> Result.map (fun model -> { model; created_at })
  |> Result.map_error (fun error -> Decode_error (Capsule.construction_error_to_string error))

let capsule_id (capsule : capsule) = Capsule.id capsule.model
let capsule_title (capsule : capsule) = Capsule.title capsule.model
let capsule_description (capsule : capsule) = Capsule.description capsule.model
let capsule_created_at (capsule : capsule) = capsule.created_at
let capsule_model (capsule : capsule) = capsule.model

let capsule_payload capsule =
  let* capsule_id = raw_id "capsule ID" Id.Capsule_id.to_bytes (capsule_id capsule) in
  let* title = Encoding.text (capsule_title capsule) |> Result.map_error (fun error -> Encoding_error error) in
  let* description = Encoding.text (capsule_description capsule) |> Result.map_error (fun error -> Encoding_error error) in
  encoding_array
    [ Encoding.integer 1L; Encoding.bytes capsule_id; Encoding.integer capsule.created_at; title; description ]

let decode_capsule_payload value =
  let* fields = exact_array "capsule" 5 value in
  match fields with
  | [ version; identity; created_at; title; description ] ->
      let* version = integer "capsule version" version in
      if not (Int64.equal version 1L) then Error (Unsupported_schema_version version)
      else
        let* id = parse_id "capsule ID" Id.Capsule_id.of_bytes identity in
        let* created_at = integer "capsule creation timestamp" created_at in
        let* title = text "capsule title" title in
        let* description = text "capsule description" description in
        let* capsule = create_capsule ~id ~title ~description ~created_at in
        let* () = canonical "capsule" value capsule_payload capsule in
        Ok capsule
  | _ -> assert false

let envelope object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let store_capsule repository capsule =
  let* payload = capsule_payload capsule in
  let* object_ = envelope Envelope.Capsule payload in
  Store.put repository object_ |> Result.map_error (fun error -> Store_error error)

let load_capsule repository object_id =
  let* object_ = Store.get repository object_id |> Result.map_error (fun error -> Store_error error) in
  if Envelope.object_type object_ <> Envelope.Capsule then
    Error (Unexpected_object_type { expected = Envelope.Capsule; actual = Envelope.object_type object_ })
  else decode_capsule_payload (Envelope.payload object_)

let revision_identity_payload (revision : revision) =
  let* capsule = raw_id "revision capsule ID" Id.Capsule_id.to_bytes (Capsule.revision_capsule revision.model) in
  let* parent = parent_value revision.parent in
  let declared_base = Encoding.bytes (raw_stored (Snapshot.Snapshot.stored_object_id (Capsule.revision_declared_base revision.model))) in
  let expected_result = Encoding.bytes (raw_stored (Snapshot.Snapshot.stored_object_id revision.expected_result)) in
  let* operations = operations_value (Capsule.revision_operations revision.model) in
  let* dependencies = canonical_set "revision dependencies" dependency_value revision.dependencies in
  let* evidence = canonical_set "revision evidence" evidence_identity_value (Capsule.revision_evidence revision.model) in
  let* boundaries = boundaries_value revision.boundaries in
  let* provenance = provenance_value revision.provenance in
  encoding_array
    [
      Encoding.integer 1L;
      Encoding.bytes capsule;
      parent;
      declared_base;
      expected_result;
      operations;
      dependencies;
      evidence;
      boundaries;
      provenance;
    ]

let revision_id_of_identity value =
  Hash.feed_string Hash.empty "paengi:capsule-revision:v1\000"
  |> fun context -> Hash.feed_string context (Encoding.encode value)
  |> Hash.get |> Hash.to_raw_string |> Id.Capsule_revision_id.of_bytes
  |> Result.get_ok

let derive_revision_id revision =
  revision_identity_payload revision |> Result.map revision_id_of_identity |> Result.get_ok

let make_revision ~id ~(capsule : capsule) ~(parent : parent_link option)
    ~declared_base ~expected_result
    ~operations ~dependencies ~evidence ~boundaries ~provenance ~created_at =
  let* model =
    Capsule.create_revision ~id ~capsule:capsule.model
      ~parent:(Option.map (fun (parent : parent_link) -> parent.revision) parent)
      ~declared_base
      ~operations ~expected_result:(Some expected_result) ~evidence ~created_at
    |> Result.map_error (fun error -> Decode_error (Capsule.construction_error_to_string error))
  in
  Ok { model; parent; expected_result; dependencies; boundaries; provenance }

let create_revision ~capsule ~parent ~declared_base ~expected_result ~operations ~dependencies ~evidence ~boundaries ~provenance ~created_at =
  let placeholder =
    Id.Capsule_revision_id.of_bytes (String.make 32 '\000') |> Result.get_ok
  in
  let* provisional =
    make_revision ~id:placeholder ~capsule ~parent ~declared_base ~expected_result
      ~operations ~dependencies ~evidence ~boundaries ~provenance ~created_at
  in
  let* identity = revision_identity_payload provisional in
  let id = revision_id_of_identity identity in
  make_revision ~id ~capsule ~parent ~declared_base ~expected_result ~operations
    ~dependencies ~evidence ~boundaries ~provenance ~created_at

let revision_id (revision : revision) = Capsule.revision_id revision.model
let revision_capsule (revision : revision) = Capsule.revision_capsule revision.model
let revision_parent (revision : revision) = revision.parent
let revision_declared_base (revision : revision) = Capsule.revision_declared_base revision.model
let revision_expected_result (revision : revision) = revision.expected_result
let revision_operations (revision : revision) = Capsule.revision_operations revision.model
let revision_dependencies (revision : revision) = revision.dependencies
let revision_evidence (revision : revision) = Capsule.revision_evidence revision.model
let revision_boundaries (revision : revision) = revision.boundaries
let revision_provenance (revision : revision) = revision.provenance
let revision_created_at (revision : revision) = Capsule.revision_created_at revision.model
let revision_model (revision : revision) = revision.model

let revision_payload revision =
  let* capsule = raw_id "revision capsule ID" Id.Capsule_id.to_bytes (revision_capsule revision) in
  let* identity = raw_id "capsule revision ID" Id.Capsule_revision_id.to_bytes (revision_id revision) in
  let* parent = parent_value revision.parent in
  let declared_base = Encoding.bytes (raw_stored (Snapshot.Snapshot.stored_object_id (revision_declared_base revision))) in
  let expected_result = Encoding.bytes (raw_stored (Snapshot.Snapshot.stored_object_id revision.expected_result)) in
  let* operations = operations_value (revision_operations revision) in
  let* dependencies = canonical_set "revision dependencies" dependency_value revision.dependencies in
  let* evidence = canonical_set "revision evidence" evidence_value (revision_evidence revision) in
  let* boundaries = boundaries_value revision.boundaries in
  let* provenance = provenance_value revision.provenance in
  encoding_array
    [
      Encoding.integer 1L;
      Encoding.bytes capsule;
      Encoding.bytes identity;
      parent;
      declared_base;
      expected_result;
      operations;
      dependencies;
      evidence;
      boundaries;
      provenance;
      Encoding.integer (revision_created_at revision);
    ]

let decode_revision_payload value =
  let* fields = exact_array "capsule revision" 12 value in
  match fields with
  | [ version; capsule_id; revision_id; parent; declared_base; expected_result; operations; dependencies; evidence; boundaries; provenance; created_at ] ->
      let* version = integer "capsule revision version" version in
      if not (Int64.equal version 1L) then Error (Unsupported_schema_version version)
      else
        let* capsule_id = parse_id "revision capsule ID" Id.Capsule_id.of_bytes capsule_id in
        let* revision_id = parse_id "capsule revision ID" Id.Capsule_revision_id.of_bytes revision_id in
        let* parent = parent_of_value parent in
        let* declared_base = parse_stored "revision declared base" declared_base in
        let* expected_result = parse_stored "revision expected result" expected_result in
        let* operations = operations_of_value operations in
        let* dependencies = canonical_set_of_value "revision dependencies" dependency_of_value dependencies in
        let* evidence = canonical_set_of_value "revision evidence" evidence_of_value evidence in
        let* boundaries = boundaries_of_value boundaries in
        let* provenance = provenance_of_value provenance in
        let* created_at = integer "revision creation timestamp" created_at in
        let* capsule = create_capsule ~id:capsule_id ~title:"persisted capsule" ~description:"" ~created_at:0L in
        let* revision =
          make_revision ~id:revision_id ~capsule ~parent
            ~declared_base:(Snapshot.Snapshot.of_stored_object_id declared_base)
            ~expected_result:(Snapshot.Snapshot.of_stored_object_id expected_result)
            ~operations ~dependencies ~evidence ~boundaries ~provenance ~created_at
        in
        let derived = derive_revision_id revision in
        let* () =
          if Id.Capsule_revision_id.equal revision_id derived then Ok ()
          else Error (Logical_revision_id_mismatch { supplied = revision_id; derived })
        in
        let* () = canonical "capsule revision" value revision_payload revision in
        Ok revision
  | _ -> assert false

let store_revision repository revision =
  let* payload = revision_payload revision in
  let* object_ = envelope Envelope.Capsule_revision payload in
  Store.put repository object_ |> Result.map_error (fun error -> Store_error error)

let load_revision repository object_id =
  let* object_ = Store.get repository object_id |> Result.map_error (fun error -> Store_error error) in
  if Envelope.object_type object_ <> Envelope.Capsule_revision then
    Error (Unexpected_object_type { expected = Envelope.Capsule_revision; actual = Envelope.object_type object_ })
  else decode_revision_payload (Envelope.payload object_)

let make_current_ref ~generation ~capsule ~capsule_object ~revision ~revision_object =
  let* _ = raw_id "current ref capsule ID" Id.Capsule_id.to_bytes capsule in
  let* _ = raw_id "current ref revision ID" Id.Capsule_revision_id.to_bytes revision in
  if Int64.compare generation 0L < 0 then Error (Invalid_generation generation)
  else Ok { generation; capsule; capsule_object; revision; revision_object }

let current_generation (current : current_ref) = current.generation
let current_capsule (current : current_ref) = current.capsule
let current_capsule_object (current : current_ref) = current.capsule_object
let current_revision (current : current_ref) = current.revision
let current_revision_object (current : current_ref) = current.revision_object

let current_ref_body (current : current_ref) =
  let* capsule = raw_id "current ref capsule ID" Id.Capsule_id.to_bytes current.capsule in
  let* revision = raw_id "current ref revision ID" Id.Capsule_revision_id.to_bytes current.revision in
  encoding_array
    [
      Encoding.integer 1L;
      Encoding.integer current.generation;
      Encoding.bytes capsule;
      Encoding.bytes (raw_stored current.capsule_object);
      Encoding.bytes revision;
      Encoding.bytes (raw_stored current.revision_object);
    ]

let current_ref_checksum body =
  Hash.feed_string Hash.empty "paengi:capsule-current-ref:v1\000"
  |> fun context -> Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_current_ref current =
  let body = current_ref_body current |> Result.get_ok in
  encoding_array [ body; Encoding.bytes (current_ref_checksum body) ]
  |> Result.get_ok |> Encoding.encode

let decode_current_ref input =
  let* value =
    Encoding.decode input
    |> Result.map_error (fun error -> Decode_error (Encoding.decode_error_to_string error))
  in
  let* fields = exact_array "capsule current ref" 2 value in
  match fields with
  | [ body; supplied_checksum ] ->
      let* values = exact_array "capsule current ref body" 6 body in
      let* supplied_checksum = bytes "capsule current ref checksum" supplied_checksum in
      let* current =
        match values with
        | [ version; generation; capsule; capsule_object; revision; revision_object ] ->
            let* version = integer "capsule current ref version" version in
            if not (Int64.equal version 1L) then Error (Unsupported_schema_version version)
            else
              let* generation = integer "capsule current ref generation" generation in
              let* capsule = parse_id "current ref capsule ID" Id.Capsule_id.of_bytes capsule in
              let* capsule_object = parse_stored "current ref capsule object ID" capsule_object in
              let* revision = parse_id "current ref revision ID" Id.Capsule_revision_id.of_bytes revision in
              let* revision_object = parse_stored "current ref revision object ID" revision_object in
              make_current_ref ~generation ~capsule ~capsule_object ~revision ~revision_object
        | _ -> assert false
      in
      if String.length supplied_checksum <> Hash.digest_size then Error Invalid_current_ref_checksum
      else
        let body = current_ref_body current |> Result.get_ok in
        if not (String.equal supplied_checksum (current_ref_checksum body)) then Error Invalid_current_ref_checksum
        else if not (String.equal input (encode_current_ref current)) then Error (Noncanonical_bytes "capsule current ref")
        else Ok current
  | _ -> assert false

let current_ref_components capsule = [ "capsules"; Id.Capsule_id.to_hex capsule; "current" ]
