module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store

type repository = {
  object_store : Object_store.repository;
  public_keys : Ledger.public_key_registry;
}

type publication =
  | Published of {
      object_ref : Model.Opaque_object_ref.t;
      event_id : Ledger.Event_id.t;
    }
  | Already_published of {
      object_ref : Model.Opaque_object_ref.t;
      event_id : Ledger.Event_id.t;
    }

type error =
  | Object_store_error of Object_store.error
  | Ledger_object_required of Object.kind
  | Ledger_error of Ledger.error
  | Unknown_signer of Ledger.Signer_key_id.t
  | Repository_mismatch of {
      expected : Model.Repository_id.t;
      actual : Model.Repository_id.t;
    }

let ( let* ) = Result.bind

let kind_to_string = function
  | Object.Ledger_event -> "ref-ledger event"
  | Object.Scratch_snapshot -> "scratch snapshot"
  | Object.Scratch_protection -> "scratch protection"
  | Object.Scratch_generation -> "scratch generation"
  | Object.Capsule -> "capsule"
  | Object.Capsule_revision -> "capsule revision"
  | Object.Workspace -> "workspace"
  | Object.Workspace_revision -> "workspace revision"
  | Object.Workspace_attempt -> "workspace attempt"
  | Object.Conflict -> "workspace conflict"
  | Object.Resolution -> "workspace resolution"
  | Object.Validation_evidence -> "validation evidence"
  | Object.Release -> "release"
  | Object.Repository_authority -> "repository authority"
  | Object.Device_certificate -> "device certificate"
  | Object.Device_revocation -> "device revocation"

let error_to_string = function
  | Object_store_error error -> Object_store.error_to_string error
  | Ledger_object_required kind ->
      "V2 ledger storage requires a ref-ledger frame, found "
      ^ kind_to_string kind
  | Ledger_error error -> Ledger.error_to_string error
  | Unknown_signer key ->
      "ref-ledger signer is unavailable: " ^ Ledger.Signer_key_id.to_hex key
  | Repository_mismatch { expected; actual } ->
      Printf.sprintf
        "ref-ledger event repository %s does not match enclosing repository %s"
        (Model.Repository_id.to_hex actual)
        (Model.Repository_id.to_hex expected)

let open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys =
  let* object_store =
    Object_store.open_repository ~root ~repository_id ~address_key
      ~encryption_key
    |> Result.map_error (fun error -> Object_store_error error)
  in
  Ok { object_store; public_keys }

let repository_id repository =
  Object_store.repository_id repository.object_store

let object_path repository = Object_store.object_path repository.object_store

let list_object_refs repository =
  Object_store.list_object_refs repository.object_store
  |> Result.map_error (fun error -> Object_store_error error)

let ledger_of_object object_ =
  match Object.ledger object_ with
  | Some event -> Ok event
  | None -> Error (Ledger_object_required (Object.kind object_))

let verify_event repository event =
  let* verification =
    Ledger.verify ~public_keys:repository.public_keys event
    |> Result.map_error (fun error -> Ledger_error error)
  in
  match verification with
  | Ledger.Cryptographically_valid verified ->
      let event = Ledger.verified_event verified in
      let actual_repository =
        Ledger.event_unsigned event |> Ledger.unsigned_repository_id
      in
      let expected = repository_id repository in
      if Model.Repository_id.equal expected actual_repository then Ok verified
      else Error (Repository_mismatch { expected; actual = actual_repository })
  | Ledger.Unknown_signer key -> Error (Unknown_signer key)

let validate_envelope repository ~envelope =
  let* object_ref, object_ =
    Object_store.validate_envelope repository.object_store ~envelope
    |> Result.map_error (fun error -> Object_store_error error)
  in
  let* event = ledger_of_object object_ in
  let* verified = verify_event repository event in
  Ok (object_ref, Ledger.event_id (Ledger.verified_event verified))

let publish repository ~envelope =
  let* object_ref, event_id = validate_envelope repository ~envelope in
  let* publication =
    Object_store.publish repository.object_store ~envelope
    |> Result.map_error (fun error -> Object_store_error error)
  in
  match publication with
  | Object_store.Published published ->
      if Model.Opaque_object_ref.equal object_ref published then
        Ok (Published { object_ref; event_id })
      else assert false
  | Object_store.Already_published existing ->
      if Model.Opaque_object_ref.equal object_ref existing then
        Ok (Already_published { object_ref; event_id })
      else assert false

let load_object repository ~object_ref =
  Object_store.load repository.object_store ~object_ref
  |> Result.map_error (fun error -> Object_store_error error)

let load repository ~object_ref =
  let* object_ = load_object repository ~object_ref in
  let* event = ledger_of_object object_ in
  verify_event repository event
