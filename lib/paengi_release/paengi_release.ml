module Capsule_store = Paengi_capsule_store
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Hash = Paengi_hash.Sha256
module Id = Paengi_id
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Validation = Paengi_validation
module Workspace_store = Paengi_workspace_store

type attempt_link = {
  attempt_id : Id.Workspace_attempt_id.t;
  attempt_object_id : Store.Stored_object_id.t;
}

type evidence_link = {
  evidence_id : Id.Validation_id.t;
  evidence_object_id : Store.Stored_object_id.t;
}

type release = {
  id : Id.Release_id.t;
  parents : Id.Release_id.t list;
  workspace : Id.Workspace_id.t;
  workspace_revision : Id.Workspace_revision_id.t;
  workspace_revision_object : Store.Stored_object_id.t;
  attempt : attempt_link option;
  base : Snapshot.Snapshot.id;
  capsules : Capsule_store.revision_link list;
  resolutions : Workspace_store.resolution_binding list;
  final_snapshot : Snapshot.Snapshot.id;
  evidence : evidence_link list;
  message : string option;
  created_at : int64;
}

type binding = {
  release : Id.Release_id.t;
  object_id : Store.Stored_object_id.t;
}

type attestation = {
  attested_release : Id.Release_id.t;
  signer_identity : string;
  algorithm : string;
  signature : string;
  signed_at : int64;
}

module type Signer = sig
  val signer_identity : string
  val algorithm : string
  val sign : Id.Release_id.t -> string
end

module Deterministic_test_signer : Signer = struct
  let signer_identity = "paengi deterministic test signer"
  let algorithm = "paengi-test-only-not-cryptographic-v1"

  let sign release =
    "paengi:deterministic-test-attestation:v1\000"
    ^ Id.Release_id.to_bytes release
end

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
  | Invalid_release of string
  | Logical_identity_mismatch
  | Invalid_binding_checksum
  | Invalid_attestation of string
  | Release_missing of Id.Release_id.t
  | Binding_release_mismatch
  | Conflicting_release_id_reuse of Id.Release_id.t
  | Workspace_error of Workspace_store.error
  | Validation_error of Validation.error
  | Snapshot_error of Snapshot.error
  | Workspace_attempt_missing of Id.Workspace_id.t
  | Unresolved_conflicts of Id.Workspace_attempt_id.t
  | Required_validation_failed of Id.Validation_id.t
  | Release_reproduction_mismatch
  | Parent_error of string
  | Injected_interruption of string

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Decode_error message -> "invalid release schema: " ^ message
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported release schema version: %Ld" version
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "expected object type %d, got object type %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)
  | Invalid_identity_length { kind; length } ->
      Printf.sprintf "%s must be 32 bytes, got %d" kind length
  | Invalid_release message -> "invalid release: " ^ message
  | Logical_identity_mismatch ->
      "release logical ID does not match canonical preimage"
  | Invalid_binding_checksum -> "release binding checksum is invalid"
  | Invalid_attestation message -> "invalid release attestation: " ^ message
  | Release_missing release ->
      "release binding is missing: " ^ Id.Release_id.to_hex release
  | Binding_release_mismatch ->
      "release binding does not resolve to its named release"
  | Conflicting_release_id_reuse release ->
      "release ID is already bound to different immutable content: "
      ^ Id.Release_id.to_hex release
  | Workspace_error error -> Workspace_store.error_to_string error
  | Validation_error error -> Validation.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Workspace_attempt_missing workspace ->
      "workspace has no completed current attempt: "
      ^ Id.Workspace_id.to_hex workspace
  | Unresolved_conflicts attempt ->
      "workspace attempt has unresolved conflicts: "
      ^ Id.Workspace_attempt_id.to_hex attempt
  | Required_validation_failed evidence ->
      "required validation did not pass: " ^ Id.Validation_id.to_hex evidence
  | Release_reproduction_mismatch ->
      "release final snapshot disagrees with verified workspace replay"
  | Parent_error message -> "release parent graph is invalid: " ^ message
  | Injected_interruption point -> "injected interruption: " ^ point

let ( let* ) = Result.bind

let value_array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let text value =
  Encoding.text value |> Result.map_error (fun error -> Encoding_error error)

let raw_id kind to_bytes value =
  let raw = to_bytes value in
  if String.length raw = 32 then Ok raw
  else Error (Invalid_identity_length { kind; length = String.length raw })

let raw_stored = Store.Stored_object_id.to_raw_bytes

let raw_snapshot snapshot =
  Snapshot.Snapshot.stored_object_id snapshot
  |> Store.Stored_object_id.to_raw_bytes

let hash domain value =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context value |> Hash.get |> Hash.to_raw_string

let release_from_digest digest =
  match Id.Release_id.of_bytes digest with
  | Ok release -> release
  | Error _ -> assert false

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ -> Error (Decode_error (name ^ " has wrong arity"))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an array"))

let array_field name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be bytes"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be text"))

let optional name parse = function
  | Encoding.Null -> Ok None
  | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ ) as value ->
      parse name value |> Result.map Option.some

let parse_stored name value =
  let* raw = bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some object_id -> Ok object_id
  | None -> Error (Decode_error (name ^ " must be a 32-byte stored object ID"))

let parse_typed name of_bytes value =
  let* raw = bytes name value in
  if String.length raw <> 32 then
    Error (Decode_error (name ^ " must be 32 bytes"))
  else
    match of_bytes raw with
    | Ok identity -> Ok identity
    | Error _ -> assert false

let parse_snapshot name value =
  parse_stored name value |> Result.map Snapshot.Snapshot.of_stored_object_id

let compare_release_id = Id.Release_id.compare

let ordered_unique compare values =
  let rec loop previous = function
    | [] -> true
    | value :: rest -> (
        match previous with
        | None -> loop (Some value) rest
        | Some previous -> compare previous value < 0 && loop (Some value) rest)
  in
  loop None values

let unique compare values =
  let rec loop seen = function
    | [] -> true
    | value :: rest ->
        (not (List.exists (fun existing -> compare existing value = 0) seen))
        && loop (value :: seen) rest
  in
  loop [] values

let revision_link_value link =
  let* capsule =
    raw_id "capsule ID" Id.Capsule_id.to_bytes
      (Capsule_store.revision_link_capsule link)
  in
  let* revision =
    raw_id "capsule revision ID" Id.Capsule_revision_id.to_bytes
      (Capsule_store.revision_link_revision link)
  in
  value_array
    [
      Encoding.bytes capsule;
      Encoding.bytes revision;
      Encoding.bytes (raw_stored (Capsule_store.revision_link_object link));
    ]

let decode_revision_link value =
  let* values = fields "release capsule revision link" 3 value in
  match values with
  | [ capsule; revision; object_id ] ->
      let* capsule = parse_typed "capsule ID" Id.Capsule_id.of_bytes capsule in
      let* revision =
        parse_typed "capsule revision ID" Id.Capsule_revision_id.of_bytes
          revision
      in
      let* object_id = parse_stored "capsule revision object ID" object_id in
      Ok (Capsule_store.make_revision_link ~capsule ~revision ~object_id)
  | _ -> assert false

let binding_value (binding : Workspace_store.resolution_binding) =
  let* conflict =
    raw_id "conflict ID" Id.Conflict_id.to_bytes
      binding.Workspace_store.binding_conflict
  in
  let* resolution =
    raw_id "resolution ID" Id.Resolution_id.to_bytes
      binding.Workspace_store.binding_resolution
  in
  value_array
    [
      Encoding.bytes conflict;
      Encoding.bytes resolution;
      Encoding.bytes (raw_stored binding.Workspace_store.binding_object_id);
    ]

let decode_resolution_binding value =
  let* values = fields "release resolution binding" 3 value in
  match values with
  | [ conflict; resolution; object_id ] ->
      let* binding_conflict =
        parse_typed "conflict ID" Id.Conflict_id.of_bytes conflict
      in
      let* binding_resolution =
        parse_typed "resolution ID" Id.Resolution_id.of_bytes resolution
      in
      let* binding_object_id = parse_stored "resolution object ID" object_id in
      Ok
        {
          Workspace_store.binding_conflict;
          binding_resolution;
          binding_object_id;
        }
  | _ -> assert false

let attempt_link_value (link : attempt_link option) =
  match link with
  | None -> Ok Encoding.null
  | Some (link : attempt_link) ->
      let* attempt =
        raw_id "workspace attempt ID" Id.Workspace_attempt_id.to_bytes
          link.attempt_id
      in
      value_array
        [
          Encoding.bytes attempt;
          Encoding.bytes (raw_stored link.attempt_object_id);
        ]

let decode_attempt_link = function
  | Encoding.Null -> Ok None
  | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ ) as value -> (
      let* values = fields "release workspace attempt link" 2 value in
      match values with
      | [ attempt; object_id ] ->
          let* attempt =
            parse_typed "workspace attempt ID" Id.Workspace_attempt_id.of_bytes
              attempt
          in
          let* object_id =
            parse_stored "workspace attempt object ID" object_id
          in
          Ok (Some { attempt_id = attempt; attempt_object_id = object_id })
      | _ -> assert false)

let evidence_link_value (link : evidence_link) =
  let* evidence =
    raw_id "validation evidence ID" Id.Validation_id.to_bytes link.evidence_id
  in
  value_array
    [
      Encoding.bytes evidence;
      Encoding.bytes (raw_stored link.evidence_object_id);
    ]

let decode_evidence_link value =
  let* values = fields "release validation evidence link" 2 value in
  match values with
  | [ evidence; object_id ] ->
      let* evidence =
        parse_typed "validation evidence ID" Id.Validation_id.of_bytes evidence
      in
      let* object_id = parse_stored "validation evidence object ID" object_id in
      Ok { evidence_id = evidence; evidence_object_id = object_id }
  | _ -> assert false

let optional_text = function
  | None -> Ok Encoding.null
  | Some value -> text value

let release_identity_value ~parents ~workspace ~workspace_revision
    ~workspace_revision_object ~attempt ~base ~capsules ~resolutions
    ~final_snapshot ~message =
  let* parents =
    List.fold_left
      (fun result parent ->
        let* reversed = result in
        let* parent =
          raw_id "parent release ID" Id.Release_id.to_bytes parent
        in
        Ok (Encoding.bytes parent :: reversed))
      (Ok []) parents
    |> Result.map List.rev
    |> fun result -> Result.bind result value_array
  in
  let* workspace = raw_id "workspace ID" Id.Workspace_id.to_bytes workspace in
  let* workspace_revision =
    raw_id "workspace revision ID" Id.Workspace_revision_id.to_bytes
      workspace_revision
  in
  let* attempt = attempt_link_value attempt in
  let* capsules =
    List.fold_left
      (fun result link ->
        let* reversed = result in
        let* link = revision_link_value link in
        Ok (link :: reversed))
      (Ok []) capsules
    |> Result.map List.rev
    |> fun result -> Result.bind result value_array
  in
  let* resolutions =
    List.fold_left
      (fun result binding ->
        let* reversed = result in
        let* binding = binding_value binding in
        Ok (binding :: reversed))
      (Ok []) resolutions
    |> Result.map List.rev
    |> fun result -> Result.bind result value_array
  in
  let* message = optional_text message in
  value_array
    [
      Encoding.integer 1L;
      parents;
      Encoding.bytes workspace;
      Encoding.bytes workspace_revision;
      Encoding.bytes (raw_stored workspace_revision_object);
      attempt;
      Encoding.bytes (raw_snapshot base);
      capsules;
      resolutions;
      Encoding.bytes (raw_snapshot final_snapshot);
      message;
    ]

let validate_release_fields ~parents ~capsules ~resolutions ~evidence =
  if not (unique compare_release_id parents) then
    Error (Invalid_release "parent release IDs must be unique")
  else if
    not
      (unique Id.Capsule_revision_id.compare
         (List.map Capsule_store.revision_link_revision capsules))
  then Error (Invalid_release "capsule revision links must be unique")
  else if
    not
      (ordered_unique Id.Conflict_id.compare
         (List.map
            (fun binding -> binding.Workspace_store.binding_conflict)
            resolutions))
  then Error (Invalid_release "resolution bindings must be canonically ordered")
  else if
    not
      (unique Id.Validation_id.compare
         (List.map (fun link -> link.evidence_id) evidence))
  then Error (Invalid_release "validation evidence links must be unique")
  else Ok ()

let create_release ~parents ~workspace ~workspace_revision
    ~workspace_revision_object ~attempt ~base ~capsules ~resolutions
    ~final_snapshot ~evidence ~message ~created_at =
  let* () = validate_release_fields ~parents ~capsules ~resolutions ~evidence in
  let* identity =
    release_identity_value ~parents ~workspace ~workspace_revision
      ~workspace_revision_object ~attempt ~base ~capsules ~resolutions
      ~final_snapshot ~message
  in
  let id =
    hash "paengi:release:v1\000" (Encoding.encode identity)
    |> release_from_digest
  in
  Ok
    {
      id;
      parents;
      workspace;
      workspace_revision;
      workspace_revision_object;
      attempt;
      base;
      capsules;
      resolutions;
      final_snapshot;
      evidence;
      message;
      created_at;
    }

let release_id release = release.id
let release_parents release = release.parents
let release_workspace release = release.workspace
let release_workspace_revision release = release.workspace_revision

let release_workspace_revision_object release =
  release.workspace_revision_object

let release_attempt release = release.attempt
let release_base release = release.base
let release_capsules release = release.capsules
let release_resolutions release = release.resolutions
let release_final_snapshot release = release.final_snapshot
let release_evidence release = release.evidence
let release_message release = release.message
let release_created_at release = release.created_at

let release_payload release =
  let* () =
    validate_release_fields ~parents:release.parents ~capsules:release.capsules
      ~resolutions:release.resolutions ~evidence:release.evidence
  in
  let* identity =
    release_identity_value ~parents:release.parents ~workspace:release.workspace
      ~workspace_revision:release.workspace_revision
      ~workspace_revision_object:release.workspace_revision_object
      ~attempt:release.attempt ~base:release.base ~capsules:release.capsules
      ~resolutions:release.resolutions ~final_snapshot:release.final_snapshot
      ~message:release.message
  in
  let derived =
    hash "paengi:release:v1\000" (Encoding.encode identity)
    |> release_from_digest
  in
  if not (Id.Release_id.equal release.id derived) then
    Error Logical_identity_mismatch
  else
    let* parents =
      List.fold_left
        (fun result parent ->
          let* reversed = result in
          let* parent =
            raw_id "parent release ID" Id.Release_id.to_bytes parent
          in
          Ok (Encoding.bytes parent :: reversed))
        (Ok []) release.parents
      |> Result.map List.rev
      |> fun result -> Result.bind result value_array
    in
    let* workspace =
      raw_id "workspace ID" Id.Workspace_id.to_bytes release.workspace
    in
    let* workspace_revision =
      raw_id "workspace revision ID" Id.Workspace_revision_id.to_bytes
        release.workspace_revision
    in
    let* attempt = attempt_link_value release.attempt in
    let* capsules =
      List.fold_left
        (fun result link ->
          let* reversed = result in
          let* link = revision_link_value link in
          Ok (link :: reversed))
        (Ok []) release.capsules
      |> Result.map List.rev
      |> fun result -> Result.bind result value_array
    in
    let* resolutions =
      List.fold_left
        (fun result binding ->
          let* reversed = result in
          let* binding = binding_value binding in
          Ok (binding :: reversed))
        (Ok []) release.resolutions
      |> Result.map List.rev
      |> fun result -> Result.bind result value_array
    in
    let* evidence =
      List.fold_left
        (fun result link ->
          let* reversed = result in
          let* link = evidence_link_value link in
          Ok (link :: reversed))
        (Ok []) release.evidence
      |> Result.map List.rev
      |> fun result -> Result.bind result value_array
    in
    let* message = optional_text release.message in
    let* release_id = raw_id "release ID" Id.Release_id.to_bytes release.id in
    value_array
      [
        Encoding.integer 1L;
        Encoding.bytes release_id;
        parents;
        Encoding.bytes workspace;
        Encoding.bytes workspace_revision;
        Encoding.bytes (raw_stored release.workspace_revision_object);
        attempt;
        Encoding.bytes (raw_snapshot release.base);
        capsules;
        resolutions;
        Encoding.bytes (raw_snapshot release.final_snapshot);
        evidence;
        message;
        Encoding.integer release.created_at;
      ]

let decode_release_payload value =
  let* values = fields "release" 14 value in
  match values with
  | [
   version;
   supplied_id;
   parents;
   workspace;
   workspace_revision;
   workspace_revision_object;
   attempt;
   base;
   capsules;
   resolutions;
   final_snapshot;
   evidence;
   message;
   created_at;
  ] ->
      let* version = integer "release version" version in
      if version <> 1L then Error (Unsupported_schema_version version)
      else
        let* supplied_id =
          parse_typed "release ID" Id.Release_id.of_bytes supplied_id
        in
        let* parents = array_field "release parents" parents in
        let* parents =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* parent =
                parse_typed "parent release ID" Id.Release_id.of_bytes value
              in
              Ok (parent :: reversed))
            (Ok []) parents
          |> Result.map List.rev
        in
        let* workspace =
          parse_typed "workspace ID" Id.Workspace_id.of_bytes workspace
        in
        let* workspace_revision =
          parse_typed "workspace revision ID" Id.Workspace_revision_id.of_bytes
            workspace_revision
        in
        let* workspace_revision_object =
          parse_stored "workspace revision object ID" workspace_revision_object
        in
        let* attempt = decode_attempt_link attempt in
        let* base = parse_snapshot "release base snapshot ID" base in
        let* capsules = array_field "release capsules" capsules in
        let* capsules =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* link = decode_revision_link value in
              Ok (link :: reversed))
            (Ok []) capsules
          |> Result.map List.rev
        in
        let* resolutions = array_field "release resolutions" resolutions in
        let* resolutions =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* binding = decode_resolution_binding value in
              Ok (binding :: reversed))
            (Ok []) resolutions
          |> Result.map List.rev
        in
        let* final_snapshot =
          parse_snapshot "release final snapshot ID" final_snapshot
        in
        let* evidence = array_field "release evidence" evidence in
        let* evidence =
          List.fold_left
            (fun result value ->
              let* reversed = result in
              let* link = decode_evidence_link value in
              Ok (link :: reversed))
            (Ok []) evidence
          |> Result.map List.rev
        in
        let* message = optional "release message" text_field message in
        let* created_at = integer "release creation timestamp" created_at in
        let* release =
          create_release ~parents ~workspace ~workspace_revision
            ~workspace_revision_object ~attempt ~base ~capsules ~resolutions
            ~final_snapshot ~evidence ~message ~created_at
        in
        if not (Id.Release_id.equal supplied_id release.id) then
          Error Logical_identity_mismatch
        else
          let* canonical = release_payload release in
          if Encoding.equal canonical value then Ok release
          else Error (Decode_error "release bytes are noncanonical")
  | _ -> assert false

let object_envelope object_type payload =
  Envelope.create ~object_type ~object_format_version:1 ~mandatory_features:0L
    ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let store_release store release =
  let* payload = release_payload release in
  let* envelope = object_envelope Envelope.Release payload in
  Store.put store envelope |> Result.map_error (fun error -> Store_error error)

let load_release store object_id =
  let* envelope =
    Store.get store object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type envelope <> Envelope.Release then
    Error
      (Unexpected_object_type
         { expected = Envelope.Release; actual = Envelope.object_type envelope })
  else decode_release_payload (Envelope.payload envelope)

let binding_domain = "paengi:release-binding:v1\000"

let binding_body (binding : binding) =
  let release = raw_id "release ID" Id.Release_id.to_bytes binding.release in
  match release with
  | Error error -> Error error
  | Ok release ->
      value_array
        [
          Encoding.integer 1L;
          Encoding.bytes release;
          Encoding.bytes (raw_stored binding.object_id);
        ]

let binding_checksum body = hash binding_domain (Encoding.encode body)

let encode_binding (binding : binding) =
  let release =
    raw_id "release ID" Id.Release_id.to_bytes binding.release |> Result.get_ok
  in
  let body = binding_body binding |> Result.get_ok in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes release;
      Encoding.bytes (raw_stored binding.object_id);
      Encoding.bytes (binding_checksum body);
    ]
  |> Result.get_ok |> Encoding.encode

let decode_binding input =
  let* value =
    Encoding.decode input
    |> Result.map_error (fun error ->
        Decode_error (Encoding.decode_error_to_string error))
  in
  let* values = fields "release binding" 4 value in
  match values with
  | [ version; release; object_id; checksum ] ->
      let* version = integer "release binding version" version in
      if version <> 1L then Error (Unsupported_schema_version version)
      else
        let* release =
          parse_typed "release binding ID" Id.Release_id.of_bytes release
        in
        let* object_id = parse_stored "release binding object ID" object_id in
        let* checksum = bytes "release binding checksum" checksum in
        if String.length checksum <> Hash.digest_size then
          Error Invalid_binding_checksum
        else
          let binding = { release; object_id } in
          let canonical = encode_binding binding in
          if not (String.equal canonical input) then
            Error Invalid_binding_checksum
          else Ok binding
  | _ -> assert false

let binding_release (binding : binding) = binding.release
let binding_object (binding : binding) = binding.object_id
let make_binding ~release ~object_id = { release; object_id }
let binding_components release = [ "releases"; Id.Release_id.to_hex release ]

let validate_attestation_fields ~signer_identity ~algorithm ~signature =
  if String.length signer_identity = 0 then
    Error (Invalid_attestation "signer identity is empty")
  else if String.length algorithm = 0 then
    Error (Invalid_attestation "algorithm identifier is empty")
  else if String.length signature = 0 then
    Error (Invalid_attestation "signature is empty")
  else Ok ()

let create_attestation ~release ~signer_identity ~algorithm ~signature
    ~signed_at =
  let* () =
    validate_attestation_fields ~signer_identity ~algorithm ~signature
  in
  let* _ = raw_id "attested release ID" Id.Release_id.to_bytes release in
  let* _ = text signer_identity in
  let* _ = text algorithm in
  Ok
    {
      attested_release = release;
      signer_identity;
      algorithm;
      signature;
      signed_at;
    }

let attest ~signer:(module Signer : Signer) ~release ~signed_at =
  create_attestation ~release ~signer_identity:Signer.signer_identity
    ~algorithm:Signer.algorithm ~signature:(Signer.sign release) ~signed_at

let attestation_release attestation = attestation.attested_release
let attestation_signer_identity attestation = attestation.signer_identity
let attestation_algorithm attestation = attestation.algorithm
let attestation_signature attestation = attestation.signature
let attestation_signed_at attestation = attestation.signed_at

let attestation_payload attestation =
  let* () =
    validate_attestation_fields ~signer_identity:attestation.signer_identity
      ~algorithm:attestation.algorithm ~signature:attestation.signature
  in
  let* release =
    raw_id "attested release ID" Id.Release_id.to_bytes
      attestation.attested_release
  in
  let* signer_identity = text attestation.signer_identity in
  let* algorithm = text attestation.algorithm in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes release;
      signer_identity;
      algorithm;
      Encoding.bytes attestation.signature;
      Encoding.integer attestation.signed_at;
    ]

let decode_attestation_payload value =
  let* values = fields "release attestation" 6 value in
  match values with
  | [ version; release; signer_identity; algorithm; signature; signed_at ] ->
      let* version = integer "release attestation version" version in
      if version <> 1L then Error (Unsupported_schema_version version)
      else
        let* release =
          parse_typed "attested release ID" Id.Release_id.of_bytes release
        in
        let* signer_identity =
          text_field "release attestation signer identity" signer_identity
        in
        let* algorithm = text_field "release attestation algorithm" algorithm in
        let* signature = bytes "release attestation signature" signature in
        let* signed_at = integer "release attestation timestamp" signed_at in
        let* attestation =
          create_attestation ~release ~signer_identity ~algorithm ~signature
            ~signed_at
        in
        let* canonical = attestation_payload attestation in
        if Encoding.equal canonical value then Ok attestation
        else Error (Decode_error "release attestation bytes are noncanonical")
  | _ -> assert false

let store_attestation store attestation =
  let* payload = attestation_payload attestation in
  let* envelope = object_envelope Envelope.Release_attestation payload in
  Store.put store envelope |> Result.map_error (fun error -> Store_error error)

let load_attestation store object_id =
  let* envelope =
    Store.get store object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type envelope <> Envelope.Release_attestation then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Release_attestation;
           actual = Envelope.object_type envelope;
         })
  else decode_attestation_payload (Envelope.payload envelope)

module Parent_resolver = struct
  type t = Id.Release_id.t -> (Id.Release_id.t list, string) result

  let verify_acyclic resolver root =
    let rec visit ancestors current =
      if List.exists (Id.Release_id.equal current) ancestors then
        Error "parent cycle"
      else
        let* parents = resolver current in
        List.fold_left
          (fun result parent ->
            let* () = result in
            visit (current :: ancestors) parent)
          (Ok ()) parents
    in
    visit [] root

  let contains resolver ~base ~required =
    let rec visit seen current =
      if Id.Release_id.equal current required then Ok true
      else if List.exists (Id.Release_id.equal current) seen then
        Error "parent cycle"
      else
        let* parents = resolver current in
        let rec search = function
          | [] -> Ok false
          | parent :: rest ->
              let* found = visit (current :: seen) parent in
              if found then Ok true else search rest
        in
        search parents
    in
    visit [] base
end

module Requires_release = struct
  let satisfied = Parent_resolver.contains
end

let read_binding store release =
  let* bytes =
    Store.Ref_file.read store ~components:(binding_components release)
    |> Result.map_error (fun error -> Store_error error)
  in
  match bytes with
  | None -> Error (Release_missing release)
  | Some bytes ->
      let* binding = decode_binding bytes in
      if Id.Release_id.equal binding.release release then Ok binding
      else Error Binding_release_mismatch

let read_bound_release store release =
  let* binding = read_binding store release in
  let* value = load_release store binding.object_id in
  if Id.Release_id.equal value.id release then Ok value
  else Error Binding_release_mismatch

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

let resolution_binding_equal left right =
  Id.Conflict_id.equal left.Workspace_store.binding_conflict
    right.Workspace_store.binding_conflict
  && Id.Resolution_id.equal left.Workspace_store.binding_resolution
       right.Workspace_store.binding_resolution
  && Store.Stored_object_id.equal left.Workspace_store.binding_object_id
       right.Workspace_store.binding_object_id

let verify_release_inputs store release =
  let* revision =
    Workspace_store.load_revision store release.workspace_revision_object
    |> Result.map_error (fun error -> Workspace_error error)
  in
  if
    (not
       (Id.Workspace_revision_id.equal release.workspace_revision
          (Workspace_store.revision_id revision)))
    || not
         (Id.Workspace_id.equal release.workspace
            (Workspace_store.revision_workspace revision))
  then Error (Invalid_release "workspace revision link disagrees with object")
  else
    match release.attempt with
    | None -> Error (Workspace_attempt_missing release.workspace)
    | Some attempt_link ->
        let* attempt =
          Workspace_store.load_attempt store attempt_link.attempt_object_id
          |> Result.map_error (fun error -> Workspace_error error)
        in
        if
          not
            (Id.Workspace_attempt_id.equal attempt_link.attempt_id
               (Workspace_store.attempt_id attempt))
        then
          Error (Invalid_release "workspace attempt link disagrees with object")
        else
          let* () =
            Workspace_store.Durable.verify_attempt ~store ~revision ~attempt
            |> Result.map_error (fun error -> Workspace_error error)
          in
          if Workspace_store.attempt_conflicts attempt <> [] then
            Error (Unresolved_conflicts (Workspace_store.attempt_id attempt))
          else if
            (not
               (Snapshot.Snapshot.equal_id release.base
                  (Workspace_store.attempt_base attempt)))
            || not
                 (Snapshot.Snapshot.equal_id release.final_snapshot
                    (Workspace_store.attempt_resulting_snapshot attempt))
          then Error Release_reproduction_mismatch
          else if
            List.length release.capsules
            <> List.length (Workspace_store.attempt_ordered attempt)
            || not
                 (List.for_all2 revision_link_equal release.capsules
                    (Workspace_store.attempt_ordered attempt))
          then
            Error
              (Invalid_release
                 "ordered capsule links disagree with workspace attempt")
          else if
            List.length release.resolutions
            <> List.length (Workspace_store.revision_resolutions revision)
            || not
                 (List.for_all2 resolution_binding_equal release.resolutions
                    (Workspace_store.revision_resolutions revision))
          then
            Error
              (Invalid_release
                 "resolution bindings disagree with workspace revision")
          else
            let* _ =
              Snapshot.Snapshot.load store release.final_snapshot
              |> Result.map_error (fun error -> Snapshot_error error)
            in
            List.fold_left
              (fun result link ->
                let* () = result in
                let* evidence =
                  Validation.load_evidence store link.evidence_object_id
                  |> Result.map_error (fun error -> Validation_error error)
                in
                if
                  not
                    (Id.Validation_id.equal link.evidence_id
                       (Validation.evidence_id evidence))
                then
                  Error
                    (Invalid_release
                       "validation evidence link disagrees with object")
                else if
                  not
                    (Snapshot.Snapshot.equal_id release.final_snapshot
                       (Validation.evidence_snapshot evidence))
                then
                  Error
                    (Invalid_release
                       "validation evidence targets another snapshot")
                else Ok ())
              (Ok ()) release.evidence

let verify_parent_graph store release =
  let resolver release_id =
    read_bound_release store release_id
    |> Result.map (fun release -> release.parents)
    |> Result.map_error error_to_string
  in
  if List.exists (Id.Release_id.equal release.id) release.parents then
    Error (Parent_error "release cannot parent itself")
  else
    List.fold_left
      (fun result parent ->
        let* () = result in
        Parent_resolver.verify_acyclic resolver parent
        |> Result.map_error (fun error -> Parent_error error))
      (Ok ()) release.parents

let verify_release store release =
  let* () = verify_release_inputs store release in
  let* () = verify_parent_graph store release in
  Ok release

let publish_binding store binding =
  let* existing =
    Store.Ref_file.read store ~components:(binding_components binding.release)
    |> Result.map_error (fun error -> Store_error error)
  in
  match existing with
  | Some bytes ->
      let* current = decode_binding bytes in
      if
        Id.Release_id.equal current.release binding.release
        && Store.Stored_object_id.equal current.object_id binding.object_id
      then Ok ()
      else Error (Conflicting_release_id_reuse binding.release)
  | None ->
      Store.Ref_file.compare_and_swap store
        ~components:(binding_components binding.release)
        ~expected:None ~replacement:(encode_binding binding)
      |> Result.map_error (fun error ->
          match error with
          | Store.Concurrent_ref_file_update _ ->
              Conflicting_release_id_reuse binding.release
          | Store.Root_not_directory _ | Store.Repository_not_initialized _
          | Store.Incompatible_repository_format _ | Store.Not_regular_file _
          | Store.Object_too_large _ | Store.File_size_changed _
          | Store.Io_error _ | Store.Object_identity_mismatch _
          | Store.Object_integrity_error _ | Store.Collision_or_corruption _
          | Store.Unsupported_publication _ | Store.Temporary_name_exhausted _
          | Store.Invalid_ref_name _ | Store.Corrupt_ref _
          | Store.Concurrent_ref_update _ | Store.Ref_lock_held _
          | Store.Ref_generation_exhausted _ | Store.Invalid_ref_path _ ->
              Store_error error)

module Durable = struct
  type failure_point = Before_release_binding

  let read store release = read_bound_release store release

  let list store =
    let directory =
      Filename.concat
        (Filename.concat (Store.root store) ".paengi")
        "refs/releases"
    in
    match Sys.readdir directory with
    | exception Sys_error message
      when String.ends_with ~suffix:"No such file or directory" message ->
        Ok []
    | exception Sys_error message ->
        Error
          (Store_error
             (Store.Io_error
                { operation = "read release refs"; path = directory; message }))
    | names ->
        List.sort String.compare (Array.to_list names)
        |> List.fold_left
             (fun result name ->
               let* releases = result in
               match Id.Release_id.of_hex name with
               | Error _ ->
                   Error (Decode_error "release ref path has invalid ID")
               | Ok release
                 when String.length (Id.Release_id.to_bytes release) <> 32 ->
                   Error (Decode_error "release ref path ID has invalid length")
               | Ok release ->
                   let* value = read_bound_release store release in
                   Ok (value :: releases))
             (Ok [])
        |> Result.map List.rev

  let verify store release =
    let* release = read_bound_release store release in
    verify_release store release

  let existing store release =
    read_bound_release store release
    |> Result.fold
         ~ok:(fun release -> Ok (Some release))
         ~error:(fun error ->
           match error with
           | Release_missing _ -> Ok None
           | Store_error _ | Envelope_error _ | Encoding_error _
           | Decode_error _ | Unsupported_schema_version _
           | Unexpected_object_type _ | Invalid_identity_length _
           | Invalid_release _ | Logical_identity_mismatch
           | Invalid_binding_checksum | Invalid_attestation _
           | Binding_release_mismatch | Conflicting_release_id_reuse _
           | Workspace_error _ | Validation_error _ | Snapshot_error _
           | Workspace_attempt_missing _ | Unresolved_conflicts _
           | Required_validation_failed _ | Release_reproduction_mismatch
           | Parent_error _ | Injected_interruption _ ->
               Error error)

  let run_commands ?runner ~store ~snapshot ~commands ~observed_at () =
    let rec loop reversed index = function
      | [] -> Ok (List.rev reversed)
      | command :: rest ->
          let run =
            match runner with
            | None ->
                Validation.run ~store ~snapshot ~command ~command_index:index
                  ~observed_at ()
            | Some runner ->
                Validation.run ~runner ~store ~snapshot ~command
                  ~command_index:index ~observed_at ()
          in
          let* evidence, object_id =
            run |> Result.map_error (fun error -> Validation_error error)
          in
          if not (Validation.evidence_passed evidence) then
            Error (Required_validation_failed (Validation.evidence_id evidence))
          else
            loop
              ({
                 evidence_id = Validation.evidence_id evidence;
                 evidence_object_id = object_id;
               }
              :: reversed)
              (index + 1) rest
    in
    loop [] 0 commands

  let create ?runner ~store ~workspace ~parents ~commands ~message ~observed_at
      ~created_at ?fail_at () =
    Store.with_lock store ~name:"repository-writer"
      ~on_error:(fun error -> Store_error error)
      (fun () ->
        let* resolved =
          Workspace_store.Durable.read_current store workspace
          |> Result.map_error (fun error -> Workspace_error error)
        in
        let current = Workspace_store.resolved_current_ref resolved in
        let* attempt_link =
          match Workspace_store.current_latest_attempt current with
          | None -> Error (Workspace_attempt_missing workspace)
          | Some (attempt, object_id) ->
              Ok { attempt_id = attempt; attempt_object_id = object_id }
        in
        let revision = Workspace_store.resolved_revision resolved in
        let* attempt =
          Workspace_store.load_attempt store attempt_link.attempt_object_id
          |> Result.map_error (fun error -> Workspace_error error)
        in
        let preliminary =
          create_release ~parents ~workspace
            ~workspace_revision:(Workspace_store.revision_id revision)
            ~workspace_revision_object:
              (Workspace_store.resolved_revision_object resolved)
            ~attempt:(Some attempt_link)
            ~base:(Workspace_store.revision_base revision)
            ~capsules:(Workspace_store.attempt_ordered attempt)
            ~resolutions:(Workspace_store.revision_resolutions revision)
            ~final_snapshot:(Workspace_store.attempt_resulting_snapshot attempt)
            ~evidence:[] ~message ~created_at
        in
        let* preliminary = preliminary in
        let* existing = existing store preliminary.id in
        match existing with
        | Some release -> verify_release store release
        | None -> (
            let* () = verify_release_inputs store preliminary in
            let* evidence =
              run_commands ?runner ~store ~snapshot:preliminary.final_snapshot
                ~commands ~observed_at ()
            in
            let* release =
              create_release ~parents ~workspace
                ~workspace_revision:(Workspace_store.revision_id revision)
                ~workspace_revision_object:
                  (Workspace_store.resolved_revision_object resolved)
                ~attempt:(Some attempt_link)
                ~base:(Workspace_store.revision_base revision)
                ~capsules:(Workspace_store.attempt_ordered attempt)
                ~resolutions:(Workspace_store.revision_resolutions revision)
                ~final_snapshot:
                  (Workspace_store.attempt_resulting_snapshot attempt)
                ~evidence ~message ~created_at
            in
            let* object_id = store_release store release in
            let* _ = verify_release store release in
            match fail_at with
            | Some Before_release_binding ->
                Error (Injected_interruption "before release binding")
            | None ->
                let* () =
                  publish_binding store { release = release.id; object_id }
                in
                verify_release store release))
end
