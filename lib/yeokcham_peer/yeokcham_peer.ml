module Capsule_store = Yeokcham_capsule_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let ( let* ) = Result.bind

type capsule_target = {
  source_capsule : Id.Capsule_id.t;
  source_revision : Id.Capsule_revision_id.t;
  source_title : string;
  source_description : string;
  source_snapshot : Snapshot.Snapshot.id;
  target_snapshot : Snapshot.Snapshot.id;
}

type release_target = {
  source_release : Id.Release_id.t;
  source_message : string option;
  source_created_at : int64;
  source_base : Snapshot.Snapshot.id;
  source_final_snapshot : Snapshot.Snapshot.id;
}

type target = Capsule_revision of capsule_target | Release of release_target

type publication = {
  publication_identity : Id.Publication_id.t;
  publication_target : target;
  publication_objects : Store.Stored_object_id.t list;
}

type integration = {
  integration_identity : Id.Peer_integration_id.t;
  integration_publication : Id.Publication_id.t;
  integration_capsule : Id.Capsule_id.t;
  integration_revision : Id.Capsule_revision_id.t;
  integration_source : Scratch.Checkpoint_id.t;
  integration_target : Scratch.Checkpoint_id.t;
}

type error =
  | Store_error of Store.error
  | Envelope_error of Envelope.creation_error
  | Encoding_error of Encoding.construction_error
  | Decode_error of string
  | Snapshot_error of Snapshot.error
  | Capsule_error of Capsule_store.error
  | Release_error of Release.error
  | Scratch_error of Scratch.error
  | Exchange_error of Exchange_store.error
  | Transport_error of string
  | Publication_missing of Id.Publication_id.t
  | Integration_missing of Id.Peer_integration_id.t
  | Invalid_publication of string
  | Unsupported_integration_target
  | Publication_binding_conflict of Id.Publication_id.t
  | Integration_binding_conflict of Id.Peer_integration_id.t
  | Injected_interruption of string

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error message -> "peer decode: " ^ message
  | Snapshot_error error -> Snapshot.error_to_string error
  | Capsule_error error -> Capsule_store.error_to_string error
  | Release_error error -> Release.error_to_string error
  | Scratch_error error -> Scratch.error_to_string error
  | Exchange_error error -> Exchange_store.error_to_string error
  | Transport_error message -> "peer transport: " ^ message
  | Publication_missing identity ->
      "peer publication is missing: " ^ Id.Publication_id.to_hex identity
  | Integration_missing identity ->
      "peer integration is missing: " ^ Id.Peer_integration_id.to_hex identity
  | Invalid_publication message -> "invalid peer publication: " ^ message
  | Unsupported_integration_target ->
      "only a peer capsule publication can be integrated into native intent"
  | Publication_binding_conflict identity ->
      "peer publication binding conflicts: " ^ Id.Publication_id.to_hex identity
  | Integration_binding_conflict identity ->
      "peer integration binding conflicts: "
      ^ Id.Peer_integration_id.to_hex identity
  | Injected_interruption point -> "peer operation interrupted at " ^ point

let publication_id publication = publication.publication_identity
let publication_target publication = publication.publication_target
let publication_objects publication = publication.publication_objects
let capsule_target_source_capsule target = target.source_capsule
let capsule_target_source_revision target = target.source_revision
let capsule_target_title target = target.source_title
let capsule_target_description target = target.source_description
let capsule_target_source_snapshot target = target.source_snapshot
let capsule_target_result_snapshot target = target.target_snapshot
let release_target_source_release target = target.source_release
let release_target_message target = target.source_message
let release_target_created_at target = target.source_created_at
let release_target_base target = target.source_base
let release_target_final_snapshot target = target.source_final_snapshot
let integration_id integration = integration.integration_identity
let integration_publication integration = integration.integration_publication
let integration_capsule integration = integration.integration_capsule
let integration_revision integration = integration.integration_revision
let integration_source integration = integration.integration_source
let integration_target integration = integration.integration_target
let publication_domain = "yeokcham:peer-publication:v1\000"
let publication_binding_domain = "yeokcham:peer-publication-binding:v1\000"
let integration_domain = "yeokcham:peer-integration:v1\000"
let integration_binding_domain = "yeokcham:peer-integration-binding:v1\000"

let array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Decode_error (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an array"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be bytes"))

let text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be text"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an integer"))

let raw_id name parser value =
  let* raw = bytes name value in
  if String.length raw <> 32 then
    Error
      (Decode_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))
  else
    parser raw
    |> Result.map_error (fun error ->
        Decode_error (Id.parse_error_to_string error))

let stored_id name value =
  let* raw = bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None -> Error (Decode_error (name ^ " must be a 32-byte stored-object ID"))

let encoded_text value =
  Encoding.text value |> Result.map_error (fun error -> Encoding_error error)

let raw_stored identity =
  Encoding.bytes (Store.Stored_object_id.to_raw_bytes identity)

let raw_snapshot identity =
  raw_stored (Snapshot.Snapshot.stored_object_id identity)

let target_value = function
  | Capsule_revision target ->
      let* title = encoded_text target.source_title in
      let* description = encoded_text target.source_description in
      array
        [
          Encoding.integer 0L;
          Encoding.bytes (Id.Capsule_id.to_bytes target.source_capsule);
          Encoding.bytes
            (Id.Capsule_revision_id.to_bytes target.source_revision);
          title;
          description;
          raw_snapshot target.source_snapshot;
          raw_snapshot target.target_snapshot;
        ]
  | Release target ->
      let* message =
        match target.source_message with
        | None -> Ok Encoding.null
        | Some value -> encoded_text value
      in
      array
        [
          Encoding.integer 1L;
          Encoding.bytes (Id.Release_id.to_bytes target.source_release);
          message;
          Encoding.integer target.source_created_at;
          raw_snapshot target.source_base;
          raw_snapshot target.source_final_snapshot;
        ]

let target_of_value value =
  let* fields =
    match value with
    | Encoding.Array (Encoding.Integer 0L :: _) ->
        exact_array "capsule publication target" 7 value
    | Encoding.Array (Encoding.Integer 1L :: _) ->
        exact_array "release publication target" 6 value
    | Encoding.Array _ ->
        Error (Decode_error "peer publication target has an unknown tag")
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Decode_error "peer publication target must be an array")
  in
  let* tag, fields =
    match fields with
    | tag :: rest ->
        integer "peer publication target tag" tag
        |> Result.map (fun tag -> (tag, rest))
    | [] -> Error (Decode_error "peer publication target is empty")
  in
  if Int64.equal tag 0L then
    match fields with
    | [ capsule; revision; title; description; source; target ] ->
        let* source_capsule =
          raw_id "source capsule ID" Id.Capsule_id.of_bytes capsule
        in
        let* source_revision =
          raw_id "source revision ID" Id.Capsule_revision_id.of_bytes revision
        in
        let* source_title = text "source capsule title" title in
        let* source_description =
          text "source capsule description" description
        in
        let* source_snapshot = stored_id "source snapshot ID" source in
        let* target_snapshot = stored_id "target snapshot ID" target in
        Ok
          (Capsule_revision
             {
               source_capsule;
               source_revision;
               source_title;
               source_description;
               source_snapshot =
                 Snapshot.Snapshot.of_stored_object_id source_snapshot;
               target_snapshot =
                 Snapshot.Snapshot.of_stored_object_id target_snapshot;
             })
    | _ ->
        Error (Decode_error "capsule publication target has an invalid shape")
  else if Int64.equal tag 1L then
    match fields with
    | [ release; message; created_at; base; final_snapshot ] ->
        let* source_release =
          raw_id "source release ID" Id.Release_id.of_bytes release
        in
        let* source_message =
          match message with
          | Encoding.Null -> Ok None
          | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ ) as value ->
              text "source release message" value |> Result.map Option.some
        in
        let* source_created_at =
          integer "source release timestamp" created_at
        in
        let* source_base = stored_id "source release base snapshot ID" base in
        let* source_final_snapshot =
          stored_id "source release final snapshot ID" final_snapshot
        in
        Ok
          (Release
             {
               source_release;
               source_message;
               source_created_at;
               source_base = Snapshot.Snapshot.of_stored_object_id source_base;
               source_final_snapshot =
                 Snapshot.Snapshot.of_stored_object_id source_final_snapshot;
             })
    | _ ->
        Error (Decode_error "release publication target has an invalid shape")
  else Error (Decode_error "peer publication target has an unknown tag")

let object_ids_value identities = identities |> List.map raw_stored |> array

let object_ids_of_value value =
  let* values =
    match value with
    | Encoding.Array values -> Ok values
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Decode_error "publication object IDs must be an array")
  in
  let rec decode previous reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* identity = stored_id "publication object ID" value in
        let* () =
          match previous with
          | None -> Ok ()
          | Some prior when Store.Stored_object_id.compare prior identity < 0 ->
              Ok ()
          | Some _ ->
              Error
                (Decode_error "publication object IDs are not strictly ordered")
        in
        decode (Some identity) (identity :: reversed) rest
  in
  decode None [] values

let publication_identity_value target objects =
  let* target = target_value target in
  let* objects = object_ids_value objects in
  array [ Encoding.integer 1L; target; objects ]

let publication_id_for target objects =
  let* value = publication_identity_value target objects in
  let identity =
    Hash.feed_string Hash.empty publication_domain |> fun context ->
    Hash.feed_string context (Encoding.encode value)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Publication_id.of_bytes identity
  |> Result.map_error (fun error ->
      Decode_error (Id.parse_error_to_string error))

let create_publication ~target ~objects =
  let* identity = publication_id_for target objects in
  Ok
    {
      publication_identity = identity;
      publication_target = target;
      publication_objects = objects;
    }

let publication_payload publication =
  let* target = target_value publication.publication_target in
  let* objects = object_ids_value publication.publication_objects in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes
        (Id.Publication_id.to_bytes publication.publication_identity);
      target;
      objects;
    ]

let decode_publication_payload value =
  let* fields = exact_array "peer publication" 4 value in
  match fields with
  | [ version; identity; target; objects ] ->
      let* version = integer "peer publication version" version in
      if not (Int64.equal version 1L) then
        Error (Decode_error "unsupported peer publication version")
      else
        let* identity =
          raw_id "peer publication ID" Id.Publication_id.of_bytes identity
        in
        let* target = target_of_value target in
        let* objects = object_ids_of_value objects in
        let* derived = publication_id_for target objects in
        if not (Id.Publication_id.equal identity derived) then
          Error
            (Decode_error
               "peer publication logical identity does not match payload")
        else
          let publication =
            {
              publication_identity = identity;
              publication_target = target;
              publication_objects = objects;
            }
          in
          let* canonical = publication_payload publication in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok publication
          else Error (Decode_error "peer publication payload is noncanonical")
  | _ -> assert false

let sorted_unique identities =
  List.sort_uniq Store.Stored_object_id.compare identities

let snapshot_storage_type = function
  | Envelope.Snapshot | Envelope.Tree | Envelope.Content
  | Envelope.File_manifest | Envelope.Chunk ->
      true
  | Envelope.Scratch_event | Envelope.Checkpoint | Envelope.Capsule
  | Envelope.Capsule_revision | Envelope.Release | Envelope.Conflict
  | Envelope.Validation | Envelope.Resolution | Envelope.Repository_config
  | Envelope.Retention_change | Envelope.Scratch_generation_segment
  | Envelope.Scratch_generation | Envelope.Scratch_cleanup_manifest
  | Envelope.Workspace | Envelope.Workspace_revision
  | Envelope.Workspace_attempt | Envelope.Release_attestation
  | Envelope.Git_mapping | Envelope.Imported_transition | Envelope.Imported_tag
  | Envelope.Ref_event | Envelope.Device_identity | Envelope.Divergent_ref_set
  | Envelope.Git_archive | Envelope.Git_adoption | Envelope.Peer_publication
  | Envelope.Peer_integration | Envelope.Git_lineage_node | Envelope.Git_lineage
  | Envelope.Peer_identity | Envelope.Peer_contact | Envelope.Peer_advertisement
  | Envelope.Peer_sync_node | Envelope.Peer_sync_conflict ->
      false

let collect_content store seen content =
  let identity = Snapshot.Content.stored_object_id content in
  if List.exists (Store.Stored_object_id.equal identity) seen then Ok seen
  else
    let* object_ =
      Store.get store identity
      |> Result.map_error (fun error -> Store_error error)
    in
    let actual = Envelope.object_type object_ in
    if actual = Envelope.Content then Ok (identity :: seen)
    else if actual = Envelope.File_manifest then
      let* manifest =
        Snapshot.Manifest.load store
          (Snapshot.Manifest.of_stored_object_id identity)
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let seen = identity :: seen in
      let rec chunks seen = function
        | [] -> Ok seen
        | (chunk, _) :: rest ->
            let chunk = Snapshot.Chunk.stored_object_id chunk in
            if List.exists (Store.Stored_object_id.equal chunk) seen then
              chunks seen rest
            else
              let* object_ =
                Store.get store chunk
                |> Result.map_error (fun error -> Store_error error)
              in
              if Envelope.object_type object_ <> Envelope.Chunk then
                Error
                  (Invalid_publication
                     "a file manifest references a non-chunk object")
              else chunks (chunk :: seen) rest
      in
      chunks seen (Snapshot.Manifest.chunks manifest)
    else
      Error
        (Invalid_publication
           ("a snapshot file reference has unsupported object type "
           ^ string_of_int (Envelope.object_type_code actual)))

let rec collect_tree store seen tree =
  let identity = Snapshot.Tree.stored_object_id tree in
  if List.exists (Store.Stored_object_id.equal identity) seen then Ok seen
  else
    let* tree =
      Snapshot.Tree.load store tree
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let seen = identity :: seen in
    let rec entries seen = function
      | [] -> Ok seen
      | (_, Snapshot.Tree.File { content; _ }) :: rest ->
          let* seen = collect_content store seen content in
          entries seen rest
      | (_, Snapshot.Tree.Directory child) :: rest ->
          let* seen = collect_tree store seen child in
          entries seen rest
    in
    entries seen (Snapshot.Tree.entries tree)

let collect_snapshot store snapshot =
  let identity = Snapshot.Snapshot.stored_object_id snapshot in
  let* snapshot =
    Snapshot.Snapshot.load store snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* objects =
    collect_tree store [ identity ] (Snapshot.Snapshot.root snapshot)
  in
  Ok (sorted_unique objects)

let target_snapshots = function
  | Capsule_revision target ->
      [ target.source_snapshot; target.target_snapshot ]
  | Release target -> [ target.source_base; target.source_final_snapshot ]

let expected_objects store target =
  let rec collect seen = function
    | [] -> Ok (sorted_unique seen)
    | snapshot :: rest ->
        let* closure = collect_snapshot store snapshot in
        collect (List.rev_append closure seen) rest
  in
  collect [] (target_snapshots target)

let validate_publication store publication =
  let* expected = expected_objects store publication.publication_target in
  let actual = sorted_unique publication.publication_objects in
  if List.length actual <> List.length publication.publication_objects then
    Error (Invalid_publication "object closure contains duplicate IDs")
  else if
    List.length expected <> List.length actual
    || not (List.for_all2 Store.Stored_object_id.equal expected actual)
  then
    Error
      (Invalid_publication "object closure does not exactly match its snapshots")
  else
    let rec check = function
      | [] -> Ok ()
      | identity :: rest ->
          let* object_ =
            Store.get store identity
            |> Result.map_error (fun error -> Store_error error)
          in
          if snapshot_storage_type (Envelope.object_type object_) then
            check rest
          else
            Error
              (Invalid_publication
                 "object closure contains a non-snapshot object")
    in
    check actual

let envelope object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let store_publication store publication =
  let* payload = publication_payload publication in
  let* object_ = envelope Envelope.Peer_publication payload in
  Store.put store object_ |> Result.map_error (fun error -> Store_error error)

let publication_envelope_bytes publication =
  let* payload = publication_payload publication in
  let* object_ = envelope Envelope.Peer_publication payload in
  Ok (Envelope.encode object_)

let load_publication_object store physical =
  let* object_ =
    Store.get store physical
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.Peer_publication then
    Error
      (Decode_error "peer publication binding targets the wrong object type")
  else
    let* publication = decode_publication_payload (Envelope.payload object_) in
    let* () = validate_publication store publication in
    Ok publication

let binding_checksum domain logical physical =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context logical |> fun context ->
  Hash.feed_string context physical |> Hash.get |> Hash.to_raw_string

let publication_components identity =
  [ "peer-publications"; Id.Publication_id.to_hex identity ]

let integration_components identity =
  [ "peer-integrations"; Id.Peer_integration_id.to_hex identity ]

let encode_publication_binding identity physical =
  let logical = Id.Publication_id.to_bytes identity in
  let physical = Store.Stored_object_id.to_raw_bytes physical in
  let checksum = binding_checksum publication_binding_domain logical physical in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes logical;
      Encoding.bytes physical;
      Encoding.bytes checksum;
    ]
  |> Result.map Encoding.encode

let publication_binding_bytes publication =
  let* payload = publication_payload publication in
  let* object_ = envelope Envelope.Peer_publication payload in
  let physical = Store.id_of_envelope object_ in
  encode_publication_binding publication.publication_identity physical

let decode_publication_binding bytes_value =
  let* value =
    Encoding.decode bytes_value
    |> Result.map_error (fun error ->
        Decode_error (Encoding.decode_error_to_string error))
  in
  let* fields = exact_array "peer publication binding" 4 value in
  match fields with
  | [ version; logical; physical; checksum ] ->
      let* version = integer "peer publication binding version" version in
      if not (Int64.equal version 1L) then
        Error (Decode_error "unsupported peer publication binding version")
      else
        let* identity =
          raw_id "peer publication binding ID" Id.Publication_id.of_bytes
            logical
        in
        let* physical =
          stored_id "peer publication binding object ID" physical
        in
        let* checksum = bytes "peer publication binding checksum" checksum in
        let expected =
          binding_checksum publication_binding_domain
            (Id.Publication_id.to_bytes identity)
            (Store.Stored_object_id.to_raw_bytes physical)
        in
        if not (String.equal checksum expected) then
          Error (Decode_error "peer publication binding checksum is invalid")
        else
          let* canonical = encode_publication_binding identity physical in
          if String.equal canonical bytes_value then Ok (identity, physical)
          else Error (Decode_error "peer publication binding is noncanonical")
  | _ -> assert false

let publish_publication_binding store identity physical =
  let* replacement = encode_publication_binding identity physical in
  let components = publication_components identity in
  let* existing =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  match existing with
  | Some current when String.equal current replacement -> Ok ()
  | Some _ -> Error (Publication_binding_conflict identity)
  | None ->
      Store.Ref_file.compare_and_swap store ~components ~expected:None
        ~replacement
      |> Result.map_error (fun error ->
          match error with
          | Store.Concurrent_ref_file_update _ ->
              Publication_binding_conflict identity
          | Store.Root_not_directory _ | Store.Repository_not_initialized _
          | Store.Repository_incomplete _
          | Store.Incompatible_repository_format _ | Store.Not_regular_file _
          | Store.Object_too_large _ | Store.File_size_changed _
          | Store.Io_error _ | Store.Object_identity_mismatch _
          | Store.Object_integrity_error _ | Store.Collision_or_corruption _
          | Store.Unsupported_publication _ | Store.Temporary_name_exhausted _
          | Store.Invalid_ref_name _ | Store.Corrupt_ref _
          | Store.Concurrent_ref_update _ | Store.Ref_lock_held _
          | Store.Ref_generation_exhausted _ | Store.Invalid_ref_path _ ->
              Store_error error)

let publish_publication store publication =
  let* () = validate_publication store publication in
  let* physical = store_publication store publication in
  let* () =
    publish_publication_binding store publication.publication_identity physical
  in
  Ok publication

let load_publication store identity =
  let components = publication_components identity in
  let* binding =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Publication_missing identity)
  | Some binding ->
      let* bound_identity, physical = decode_publication_binding binding in
      if not (Id.Publication_id.equal identity bound_identity) then
        Error
          (Decode_error
             "peer publication binding identity disagrees with its path")
      else
        let* publication = load_publication_object store physical in
        if Id.Publication_id.equal identity publication.publication_identity
        then Ok publication
        else
          Error
            (Decode_error
               "peer publication binding targets another logical publication")

let transfer_objects publication = publication.publication_objects

let publish_capsule_revision store ~capsule ~revision =
  let* resolved =
    Capsule_store.Durable.show store capsule
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let* history =
    Capsule_store.Durable.history store capsule
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let selected =
    List.find_opt
      (fun candidate ->
        Id.Capsule_revision_id.equal revision
          (Capsule_store.revision_id candidate))
      history
  in
  match selected with
  | None ->
      Error
        (Invalid_publication
           "selected capsule revision is not a verified revision of the named \
            capsule")
  | Some selected ->
      let* revision_object =
        Capsule_store.store_revision store selected
        |> Result.map_error (fun error -> Capsule_error error)
      in
      let link =
        Capsule_store.make_revision_link ~capsule ~revision
          ~object_id:revision_object
      in
      let* _ =
        Capsule_store.Durable.verify_link store link
        |> Result.map_error (fun error -> Capsule_error error)
      in
      let target =
        Capsule_revision
          {
            source_capsule = capsule;
            source_revision = revision;
            source_title =
              Capsule_store.capsule_title
                (Capsule_store.Durable.resolved_capsule resolved);
            source_description =
              Capsule_store.capsule_description
                (Capsule_store.Durable.resolved_capsule resolved);
            source_snapshot = Capsule_store.revision_declared_base selected;
            target_snapshot = Capsule_store.revision_expected_result selected;
          }
      in
      let* objects = expected_objects store target in
      let* publication = create_publication ~target ~objects in
      publish_publication store publication

let publish_release store identity =
  let* release =
    Release.Durable.verify store identity
    |> Result.map_error (fun error -> Release_error error)
  in
  let target =
    Release
      {
        source_release = identity;
        source_message = Release.release_message release;
        source_created_at = Release.release_created_at release;
        source_base = Release.release_base release;
        source_final_snapshot = Release.release_final_snapshot release;
      }
  in
  let* objects = expected_objects store target in
  let* publication = create_publication ~target ~objects in
  publish_publication store publication

let transfer_session publication =
  let bytes =
    Hash.feed_string Hash.empty "yeokcham:peer-local-transfer-session:v1\000"
    |> fun context ->
    Hash.feed_string context
      (Id.Publication_id.to_bytes publication.publication_identity)
    |> Hash.get |> Hash.to_raw_string
  in
  Exchange.session_id_of_bytes (String.sub bytes 0 16)
  |> Result.map_error (fun error ->
      Exchange_error (Exchange_store.Protocol_error error))

let fetch_local ?interrupt_after ?on_progress ~source ~destination identity =
  let* publication = load_publication source identity in
  let* publication_object = store_publication source publication in
  let objects =
    sorted_unique (publication_object :: publication.publication_objects)
  in
  let* session_id = transfer_session publication in
  let* outcome =
    Exchange_store.transfer ?interrupt_after ?on_progress ~source ~destination
      ~session_id ~object_ids:objects ()
    |> Result.map_error (fun error -> Exchange_error error)
  in
  let* received = load_publication_object destination publication_object in
  if not (Id.Publication_id.equal identity received.publication_identity) then
    Error
      (Invalid_publication
         "received publication identity changed during transfer")
  else
    let* () =
      publish_publication_binding destination identity publication_object
    in
    Ok (outcome, received)

let strict_id_list identities =
  let rec loop = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) ->
        Store.Stored_object_id.compare left right < 0 && loop rest
  in
  loop identities

let valid_ssh_target target =
  (not (String.is_empty target))
  && String.length target <= 255
  && String.for_all
       (function
         | 'a' .. 'z'
         | 'A' .. 'Z'
         | '0' .. '9'
         | '.' | '-' | '_' | '@' | ':' | '[' | ']' ->
             true
         | _ -> false)
       target

let valid_remote_root root =
  (not (String.is_empty root))
  && (not (Filename.is_relative root))
  && String.length root <= 4096
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '.' | '-' | '_' -> true
         | _ -> false)
       root

let ssh_arguments ~target ~remote_root ~publication =
  if not (valid_ssh_target target) then
    Error (Transport_error "SSH target contains unsupported characters")
  else if not (valid_remote_root remote_root) then
    Error
      (Transport_error
         "remote repository root must be an absolute path using safe Unix \
          characters")
  else
    let command =
      "yeokcham peer --root " ^ remote_root ^ " serve --publication "
      ^ Id.Publication_id.to_hex publication
    in
    Ok
      [|
        "ssh";
        "-T";
        "-o";
        "BatchMode=yes";
        "-o";
        "ConnectTimeout=5";
        "-o";
        "ClearAllForwardings=yes";
        "--";
        target;
        command;
      |]

let read_exact channel length =
  let bytes = Bytes.create length in
  let rec read offset =
    if offset = length then Ok (Bytes.unsafe_to_string bytes)
    else
      try
        let count = In_channel.input channel bytes offset (length - offset) in
        if count = 0 then
          Error (Transport_error "peer transport ended mid-frame")
        else read (offset + count)
      with
      | End_of_file -> Error (Transport_error "peer transport ended mid-frame")
      | Sys_error message -> Error (Transport_error message)
  in
  read 0

let frame_length header =
  let value = ref 0L in
  for index = 0 to 7 do
    value :=
      Int64.logor
        (Int64.shift_left !value 8)
        (Int64.of_int (Char.code header.[index]))
  done;
  let maximum =
    Int64.add
      (Int64.of_int Store.max_object_bytes)
      (Int64.of_int Exchange.max_control_message_bytes)
  in
  if Int64.compare !value 1L < 0 || Int64.compare !value maximum > 0 then
    Error (Transport_error "peer transport frame length is out of bounds")
  else Ok (Int64.to_int !value)

let read_message channel =
  let* header = read_exact channel 8 in
  let* length = frame_length header in
  let* payload = read_exact channel length in
  Exchange.decode (header ^ payload)
  |> Result.map_error (fun error ->
      Transport_error (Exchange.error_to_string error))

let write_message channel message =
  let* bytes =
    Exchange.encode message
    |> Result.map_error (fun error ->
        Transport_error (Exchange.error_to_string error))
  in
  try
    Out_channel.output_string channel bytes;
    Out_channel.flush channel;
    Ok ()
  with Sys_error message -> Error (Transport_error message)

let hello =
  Exchange.Hello
    {
      repository_format = Store.repository_format;
      supported_versions = [ Exchange.protocol_version ];
      required_features = Exchange.supported_required_features;
    }

let is_member identity identities =
  List.exists (Store.Stored_object_id.equal identity) identities

let validate_want ~session_id ~sequence ~offered = function
  | Exchange.Want
      {
        session_id = actual_session;
        sequence = actual_sequence;
        object_ids;
        required_features;
      } ->
      if
        not
          (String.equal
             (Exchange.session_id_to_bytes session_id)
             (Exchange.session_id_to_bytes actual_session))
      then Error (Transport_error "peer Want uses another session")
      else if not (Int64.equal sequence actual_sequence) then
        Error (Transport_error "peer Want uses another inventory sequence")
      else if required_features <> Exchange.supported_required_features then
        Error (Transport_error "peer Want uses incompatible required features")
      else if not (strict_id_list object_ids) then
        Error (Transport_error "peer Want object IDs are not strictly ordered")
      else if
        not
          (List.for_all (fun identity -> is_member identity offered) object_ids)
      then Error (Transport_error "peer Want requests an unoffered object")
      else Ok object_ids
  | Exchange.Hello _ | Exchange.Inventory _ | Exchange.Object _ | Exchange.End _
  | Exchange.Error_message _ ->
      Error (Transport_error "peer transport expected Want")

let chunks size values =
  let rec loop reversed values =
    match values with
    | [] -> List.rev reversed
    | _ ->
        let rec take count reversed values =
          if count = 0 then (List.rev reversed, values)
          else
            match values with
            | [] -> (List.rev reversed, [])
            | value :: rest -> take (count - 1) (value :: reversed) rest
        in
        let page, rest = take size [] values in
        loop (page :: reversed) rest
  in
  loop [] values

let serve store ~publication ~input ~output =
  let* publication = load_publication store publication in
  let* publication_object = store_publication store publication in
  let objects =
    sorted_unique (publication_object :: publication.publication_objects)
  in
  let* session_id = transfer_session publication in
  let* receiver =
    Exchange.initial_receiver
      ~object_byte_budget:Exchange.max_total_object_bytes
    |> Result.map_error (fun error ->
        Transport_error (Exchange.error_to_string error))
  in
  let* remote_hello = read_message input in
  let* _ =
    Exchange.accept_hello receiver remote_hello
    |> Result.map_error (fun error ->
        Transport_error (Exchange.error_to_string error))
  in
  let* () = write_message output hello in
  let pages = chunks Exchange.max_ids_per_page objects in
  let rec send_pages sequence object_sequence = function
    | [] ->
        write_message output
          (Exchange.End
             {
               session_id;
               status = Exchange.Complete;
               required_features = Exchange.supported_required_features;
             })
    | page :: rest ->
        let inventory =
          Exchange.Inventory
            {
              session_id;
              sequence;
              final = rest = [];
              object_ids = page;
              required_features = Exchange.supported_required_features;
            }
        in
        let* () = write_message output inventory in
        let* want = read_message input in
        let* wanted = validate_want ~session_id ~sequence ~offered:page want in
        let rec send_objects object_sequence = function
          | [] -> Ok object_sequence
          | identity :: rest ->
              let* object_ =
                Exchange_store.object_message store ~session_id
                  ~sequence:object_sequence identity
                |> Result.map_error (fun error -> Exchange_error error)
              in
              let* () = write_message output object_ in
              send_objects Int64.(add object_sequence 1L) rest
        in
        let* object_sequence = send_objects object_sequence wanted in
        send_pages Int64.(add sequence 1L) object_sequence rest
  in
  send_pages 0L 0L pages

let destination_missing destination identity =
  let path = Store.object_path destination identity in
  if not (Sys.file_exists path) then Ok true
  else
    Store.get destination identity
    |> Result.map (fun _ -> false)
    |> Result.map_error (fun error -> Store_error error)

let find_received_publication destination identity =
  let* entries =
    Store.list_objects destination
    |> Result.map_error (fun error -> Store_error error)
  in
  let rec loop = function
    | [] -> Error (Publication_missing identity)
    | entry :: rest -> (
        if entry.Store.object_type <> Envelope.Peer_publication then loop rest
        else
          match load_publication_object destination entry.Store.id with
          | Ok publication
            when Id.Publication_id.equal publication.publication_identity
                   identity ->
              Ok (entry.Store.id, publication)
          | Ok _ | Error _ -> loop rest)
  in
  loop entries

let fetch_stream ~destination ~publication ~input ~output =
  let* receiver =
    Exchange.initial_receiver
      ~object_byte_budget:Exchange.max_total_object_bytes
    |> Result.map_error (fun error ->
        Transport_error (Exchange.error_to_string error))
  in
  let* () = write_message output hello in
  let* remote_hello = read_message input in
  let* receiver =
    Exchange.accept_hello receiver remote_hello
    |> Result.map_error (fun error ->
        Transport_error (Exchange.error_to_string error))
  in
  let rec receive receiver offered requested transferred =
    let* inventory = read_message input in
    let* receiver, offered_ids =
      Exchange.accept_inventory receiver inventory
      |> Result.map_error (fun error ->
          Transport_error (Exchange.error_to_string error))
    in
    let sequence, final =
      match inventory with
      | Exchange.Inventory { sequence; final; _ } -> (sequence, final)
      | Exchange.Hello _ | Exchange.Want _ | Exchange.Object _ | Exchange.End _
      | Exchange.Error_message _ ->
          assert false
    in
    let rec select_missing reversed = function
      | [] -> Ok (List.rev reversed)
      | identity :: rest ->
          let* missing = destination_missing destination identity in
          select_missing
            (if missing then identity :: reversed else reversed)
            rest
    in
    let* wanted = select_missing [] offered_ids in
    let* receiver, want =
      Exchange.register_want receiver ~sequence wanted
      |> Result.map_error (fun error ->
          Transport_error (Exchange.error_to_string error))
    in
    let* () = write_message output want in
    let rec receive_objects receiver transferred = function
      | [] -> Ok (receiver, transferred)
      | _ :: rest ->
          let* object_ = read_message input in
          let* receiver, identity =
            Exchange_store.receive_object destination receiver object_
            |> Result.map_error (fun error -> Exchange_error error)
          in
          receive_objects receiver (identity :: transferred) rest
    in
    let* receiver, transferred = receive_objects receiver transferred wanted in
    let offered = offered + List.length offered_ids in
    let requested = requested + List.length wanted in
    if final then
      let* end_message = read_message input in
      let* _ =
        Exchange.accept_end receiver end_message
        |> Result.map_error (fun error ->
            Transport_error (Exchange.error_to_string error))
      in
      let* physical, received =
        find_received_publication destination publication
      in
      let* () = publish_publication_binding destination publication physical in
      Ok
        ( {
            Exchange_store.offered;
            requested;
            transferred = List.rev transferred;
          },
          received )
    else receive receiver offered requested transferred
  in
  receive receiver 0 0 []

let read_limited channel limit =
  let bytes = Bytes.create limit in
  try
    let count = In_channel.input channel bytes 0 limit in
    Bytes.sub_string bytes 0 count
  with End_of_file | Sys_error _ -> ""

let fetch_ssh ~destination ~target ~remote_root ~publication =
  let* arguments = ssh_arguments ~target ~remote_root ~publication in
  try
    let input, output, error =
      Unix.open_process_args_full "ssh" arguments (Unix.environment ())
    in
    let result = fetch_stream ~destination ~publication ~input ~output in
    let stderr = read_limited error 4096 in
    let status = Unix.close_process_full (input, output, error) in
    if status = Unix.WEXITED 0 then result
    else
      Error
        (Transport_error
           ("SSH peer command failed"
           ^ if String.is_empty stderr then "" else ": " ^ stderr))
  with Unix.Unix_error (error, operation, argument) ->
    Error
      (Transport_error
         (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))

let integration_identity_value ~publication ~capsule ~revision ~source ~target =
  array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Publication_id.to_bytes publication);
      Encoding.bytes (Id.Capsule_id.to_bytes capsule);
      Encoding.bytes (Id.Capsule_revision_id.to_bytes revision);
      raw_stored (Scratch.Checkpoint_id.stored_object_id source);
      raw_stored (Scratch.Checkpoint_id.stored_object_id target);
    ]

let integration_id_for ~publication ~capsule ~revision ~source ~target =
  let* value =
    integration_identity_value ~publication ~capsule ~revision ~source ~target
  in
  let raw =
    Hash.feed_string Hash.empty integration_domain |> fun context ->
    Hash.feed_string context (Encoding.encode value)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Peer_integration_id.of_bytes raw
  |> Result.map_error (fun error ->
      Decode_error (Id.parse_error_to_string error))

let integration_payload integration =
  array
    [
      Encoding.integer 1L;
      Encoding.bytes
        (Id.Peer_integration_id.to_bytes integration.integration_identity);
      Encoding.bytes
        (Id.Publication_id.to_bytes integration.integration_publication);
      Encoding.bytes (Id.Capsule_id.to_bytes integration.integration_capsule);
      Encoding.bytes
        (Id.Capsule_revision_id.to_bytes integration.integration_revision);
      raw_stored
        (Scratch.Checkpoint_id.stored_object_id integration.integration_source);
      raw_stored
        (Scratch.Checkpoint_id.stored_object_id integration.integration_target);
    ]

let decode_integration_payload value =
  let* fields = exact_array "peer integration" 7 value in
  match fields with
  | [ version; identity; publication; capsule; revision; source; target ] ->
      let* version = integer "peer integration version" version in
      if not (Int64.equal version 1L) then
        Error (Decode_error "unsupported peer integration version")
      else
        let* integration_identity =
          raw_id "peer integration ID" Id.Peer_integration_id.of_bytes identity
        in
        let* integration_publication =
          raw_id "peer integration publication ID" Id.Publication_id.of_bytes
            publication
        in
        let* integration_capsule =
          raw_id "peer integration capsule ID" Id.Capsule_id.of_bytes capsule
        in
        let* integration_revision =
          raw_id "peer integration revision ID" Id.Capsule_revision_id.of_bytes
            revision
        in
        let* source = stored_id "peer integration source checkpoint" source in
        let* target = stored_id "peer integration target checkpoint" target in
        let integration_source =
          Scratch.Checkpoint_id.of_stored_object_id source
        in
        let integration_target =
          Scratch.Checkpoint_id.of_stored_object_id target
        in
        let* derived =
          integration_id_for ~publication:integration_publication
            ~capsule:integration_capsule ~revision:integration_revision
            ~source:integration_source ~target:integration_target
        in
        if not (Id.Peer_integration_id.equal integration_identity derived) then
          Error
            (Decode_error
               "peer integration logical identity does not match payload")
        else
          let integration =
            {
              integration_identity;
              integration_publication;
              integration_capsule;
              integration_revision;
              integration_source;
              integration_target;
            }
          in
          let* canonical = integration_payload integration in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok integration
          else Error (Decode_error "peer integration payload is noncanonical")
  | _ -> assert false

let store_integration store integration =
  let* payload = integration_payload integration in
  let* object_ = envelope Envelope.Peer_integration payload in
  Store.put store object_ |> Result.map_error (fun error -> Store_error error)

let integration_envelope_bytes integration =
  let* payload = integration_payload integration in
  let* object_ = envelope Envelope.Peer_integration payload in
  Ok (Envelope.encode object_)

let encode_integration_binding identity physical =
  let logical = Id.Peer_integration_id.to_bytes identity in
  let physical = Store.Stored_object_id.to_raw_bytes physical in
  let checksum = binding_checksum integration_binding_domain logical physical in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes logical;
      Encoding.bytes physical;
      Encoding.bytes checksum;
    ]
  |> Result.map Encoding.encode

let decode_integration_binding bytes_value =
  let* value =
    Encoding.decode bytes_value
    |> Result.map_error (fun error ->
        Decode_error (Encoding.decode_error_to_string error))
  in
  let* fields = exact_array "peer integration binding" 4 value in
  match fields with
  | [ version; logical; physical; checksum ] ->
      let* version = integer "peer integration binding version" version in
      if not (Int64.equal version 1L) then
        Error (Decode_error "unsupported peer integration binding version")
      else
        let* identity =
          raw_id "peer integration binding ID" Id.Peer_integration_id.of_bytes
            logical
        in
        let* physical =
          stored_id "peer integration binding object ID" physical
        in
        let* checksum = bytes "peer integration binding checksum" checksum in
        let expected =
          binding_checksum integration_binding_domain
            (Id.Peer_integration_id.to_bytes identity)
            (Store.Stored_object_id.to_raw_bytes physical)
        in
        if not (String.equal checksum expected) then
          Error (Decode_error "peer integration binding checksum is invalid")
        else
          let* canonical = encode_integration_binding identity physical in
          if String.equal canonical bytes_value then Ok (identity, physical)
          else Error (Decode_error "peer integration binding is noncanonical")
  | _ -> assert false

let publish_integration_binding store identity physical =
  let* replacement = encode_integration_binding identity physical in
  let components = integration_components identity in
  let* existing =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  match existing with
  | Some current when String.equal current replacement -> Ok ()
  | Some _ -> Error (Integration_binding_conflict identity)
  | None ->
      Store.Ref_file.compare_and_swap store ~components ~expected:None
        ~replacement
      |> Result.map_error (fun error ->
          match error with
          | Store.Concurrent_ref_file_update _ ->
              Integration_binding_conflict identity
          | Store.Root_not_directory _ | Store.Repository_not_initialized _
          | Store.Repository_incomplete _
          | Store.Incompatible_repository_format _ | Store.Not_regular_file _
          | Store.Object_too_large _ | Store.File_size_changed _
          | Store.Io_error _ | Store.Object_identity_mismatch _
          | Store.Object_integrity_error _ | Store.Collision_or_corruption _
          | Store.Unsupported_publication _ | Store.Temporary_name_exhausted _
          | Store.Invalid_ref_name _ | Store.Corrupt_ref _
          | Store.Concurrent_ref_update _ | Store.Ref_lock_held _
          | Store.Ref_generation_exhausted _ | Store.Invalid_ref_path _ ->
              Store_error error)

let integration_binding_bytes integration =
  let* payload = integration_payload integration in
  let* object_ = envelope Envelope.Peer_integration payload in
  encode_integration_binding integration.integration_identity
    (Store.id_of_envelope object_)

let detached_checkpoints store ~source ~target ~created_at =
  let source_checkpoint =
    Scratch.Checkpoint.create_initial ~snapshot:source ~created_at
  in
  let* source_checkpoint =
    Scratch.Checkpoint.store store source_checkpoint
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let* source_snapshot =
    Snapshot.Snapshot.load store source
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* target_snapshot =
    Snapshot.Snapshot.load store target
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* source_state =
    Scratch.State.of_snapshot store source_snapshot
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let* target_state =
    Scratch.State.of_snapshot store target_snapshot
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let operations = Scratch.State.diff ~from:source_state ~to_:target_state in
  let* replayed =
    Scratch.State.apply source_state operations
    |> Result.map_error (fun error -> Scratch_error error)
  in
  if not (Scratch.State.equal replayed target_state) then
    Error
      (Invalid_publication
         "peer capsule transition replay does not reach its target snapshot")
  else
    let event =
      Scratch.Event.create ~parent:source_checkpoint ~base:source
        ~resulting:target ~operations ~source:Scratch.Explicit
        ~observed_at:created_at
    in
    let* event =
      Scratch.Event.store store event
      |> Result.map_error (fun error -> Scratch_error error)
    in
    let target_checkpoint =
      Scratch.Checkpoint.create ~parent:source_checkpoint ~event
        ~snapshot:target ~created_at
    in
    Scratch.Checkpoint.store store target_checkpoint
    |> Result.map_error (fun error -> Scratch_error error)
    |> Result.map (fun target_checkpoint ->
        (source_checkpoint, target_checkpoint))

let validate_integration store integration =
  let* publication =
    load_publication store integration.integration_publication
  in
  let target = publication.publication_target in
  match target with
  | Release _ -> Error Unsupported_integration_target
  | Capsule_revision target ->
      let* source =
        Scratch.Checkpoint.load store integration.integration_source
        |> Result.map_error (fun error -> Scratch_error error)
      in
      let* result =
        Scratch.Checkpoint.load store integration.integration_target
        |> Result.map_error (fun error -> Scratch_error error)
      in
      if
        (not
           (Snapshot.Snapshot.equal_id
              (Scratch.Checkpoint.snapshot source)
              target.source_snapshot))
        || not
             (Snapshot.Snapshot.equal_id
                (Scratch.Checkpoint.snapshot result)
                target.target_snapshot)
      then
        Error
          (Invalid_publication
             "peer integration checkpoint snapshots disagree with its \
              publication")
      else
        let* resolved =
          Capsule_store.Durable.show store integration.integration_capsule
          |> Result.map_error (fun error -> Capsule_error error)
        in
        let revision = Capsule_store.Durable.resolved_revision resolved in
        if
          Id.Capsule_revision_id.equal integration.integration_revision
            (Capsule_store.revision_id revision)
        then Ok ()
        else
          Error
            (Invalid_publication
               "peer integration capsule current revision disagrees with its \
                receipt")

let publish_integration store integration =
  let* () = validate_integration store integration in
  let* physical = store_integration store integration in
  let* () =
    publish_integration_binding store integration.integration_identity physical
  in
  Ok integration

let integrate_capsule store ~publication ~capsule ~title ~description
    ~created_at =
  let* publication = load_publication store publication in
  match publication.publication_target with
  | Release _ -> Error Unsupported_integration_target
  | Capsule_revision target ->
      if
        Snapshot.Snapshot.equal_id target.source_snapshot target.target_snapshot
      then
        Error
          (Invalid_publication
             "a peer capsule publication has no snapshot delta")
      else
        let* source, target_checkpoint =
          detached_checkpoints store ~source:target.source_snapshot
            ~target:target.target_snapshot ~created_at
        in
        let scratch = Scratch.open_repository store in
        let* resolved =
          Capsule_store.Durable.create_from_checkpoints ~store ~scratch
            ~id:capsule ~title ~description ~dependencies:[] ~evidence:[]
            ~from:source ~target:target_checkpoint ~created_at
            ~changed_at:created_at ()
          |> Result.map_error (fun error -> Capsule_error error)
        in
        let revision =
          Capsule_store.Durable.resolved_revision resolved
          |> Capsule_store.revision_id
        in
        let* integration_identity =
          integration_id_for ~publication:publication.publication_identity
            ~capsule ~revision ~source ~target:target_checkpoint
        in
        let integration =
          {
            integration_identity;
            integration_publication = publication.publication_identity;
            integration_capsule = capsule;
            integration_revision = revision;
            integration_source = source;
            integration_target = target_checkpoint;
          }
        in
        publish_integration store integration

let load_integration store identity =
  let components = integration_components identity in
  let* binding =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Integration_missing identity)
  | Some binding ->
      let* bound_identity, physical = decode_integration_binding binding in
      if not (Id.Peer_integration_id.equal identity bound_identity) then
        Error
          (Decode_error
             "peer integration binding identity disagrees with its path")
      else
        let* object_ =
          Store.get store physical
          |> Result.map_error (fun error -> Store_error error)
        in
        if Envelope.object_type object_ <> Envelope.Peer_integration then
          Error
            (Decode_error
               "peer integration binding targets the wrong object type")
        else
          let* integration =
            decode_integration_payload (Envelope.payload object_)
          in
          if
            not
              (Id.Peer_integration_id.equal identity
                 integration.integration_identity)
          then
            Error
              (Decode_error
                 "peer integration binding targets another logical integration")
          else
            let* () = validate_integration store integration in
            Ok integration
