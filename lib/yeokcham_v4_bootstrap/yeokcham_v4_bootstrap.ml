module Model = Yeokcham_v4_model
module Package = Yeokcham_v4_package
module Record = Yeokcham_v4_record
module Store = Yeokcham_v4_store
module Raw_store = Yeokcham_store
module Envelope = Yeokcham_envelope
module Encoding = Yeokcham_encoding
module Transport = Yeokcham_v4_transport
module Trust = Yeokcham_v4_trust

type basis = {
  repository_value : Trust.Repository_id.t;
  manifest_value : string;
  state_value : Model.state;
  publisher_value : Model.Device_id.t;
  certificate_value : string;
  signature_value : string;
  id_value : string;
}

type verified = {
  verified_basis : basis;
  verified_package : Package.artifact;
  verified_authority : Trust.authority;
  verified_records : Package.verified;
}

type error =
  | Invalid_basis of string
  | Noncanonical_bytes
  | Record_error of Record.error
  | Package_error of Package.error
  | Store_error of Store.error
  | Trust_error of Trust.error
  | Model_error of Model.error
  | Transport_error of Transport.error
  | Envelope_error of Envelope.decode_error

let schema_version = 1L
let signature_domain = "yeokcham:v4:bootstrap-basis:1\000"
let portable_draft_id = "bootstrap-v4"
let portable_draft_title = "portable shared history"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_basis detail -> "invalid V4 bootstrap basis: " ^ detail
  | Noncanonical_bytes -> "V4 bootstrap basis is not canonically encoded"
  | Record_error error -> Record.error_to_string error
  | Package_error error -> Package.error_to_string error
  | Store_error error -> Store.error_to_string error
  | Trust_error error -> Trust.error_to_string error
  | Model_error error -> Model.error_to_string error
  | Transport_error error -> Transport.error_to_string error
  | Envelope_error error -> Envelope.decode_error_to_string error

let construction value =
  Result.map_error
    (fun error -> Invalid_basis (Encoding.construction_error_to_string error))
    value

let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ -> Error (Invalid_basis (name ^ " has the wrong field count"))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_basis (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_basis (name ^ " must be text"))

let bytes_field name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_basis (name ^ " must be bytes"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Invalid_basis (name ^ " must be an integer"))

let unsigned_bytes ~repository ~manifest ~state ~publisher ~certificate =
  let* state = Record.encode_state state |> Result.map_error (fun error -> Record_error error) in
  let* repository = text (Trust.Repository_id.to_string repository) in
  let* manifest = text manifest in
  let state = Encoding.bytes state in
  let* publisher = text (Model.Device_id.to_string publisher) in
  let* certificate = text certificate in
  let* algorithm = text Trust.algorithm in
  array [ Encoding.integer schema_version; repository; manifest; state; publisher; certificate; algorithm ]
  |> Result.map Encoding.encode

let encode basis =
  let unsigned =
    unsigned_bytes ~repository:basis.repository_value ~manifest:basis.manifest_value
      ~state:basis.state_value ~publisher:basis.publisher_value
      ~certificate:basis.certificate_value
    |> Result.get_ok
  in
  Encoding.array [ Encoding.decode unsigned |> Result.get_ok; Encoding.bytes basis.signature_value ]
  |> Result.get_ok |> Encoding.encode

let id basis = basis.id_value
let manifest basis = basis.manifest_value

let deduplicate_snapshots snapshots =
  List.sort_uniq Model.Snapshot_id.compare snapshots

let named_snapshots state =
  let from_changes =
    state.Model.state_changes
    |> List.concat_map (fun change ->
           change.Model.revisions
           |> List.concat_map (fun revision -> [ revision.Model.base_snapshot; revision.Model.result_snapshot ]))
  in
  let from_resolutions =
    state.Model.state_resolutions
    |> List.concat_map (fun resolution ->
           [ resolution.Model.replacement_revision.Model.base_snapshot;
             resolution.Model.replacement_revision.Model.result_snapshot ])
  in
  let from_deliveries =
    state.Model.state_deliveries |> List.map (fun delivery -> delivery.Model.delivery_snapshot)
  in
  deduplicate_snapshots (state.Model.state_baseline :: from_changes @ from_resolutions @ from_deliveries)

let portable_state_of_project project =
  let exported = Model.export project in
  let* draft = Model.Draft_id.of_string portable_draft_id |> Result.map_error (fun error -> Model_error error) in
  let changes =
    exported.Model.state_changes
    |> List.map (fun change -> { change with Model.source_draft = None })
  in
  let provisional =
    {
      exported with
      Model.state_active_draft = draft;
      state_drafts =
        [
          {
            Model.draft_id = draft;
            title = portable_draft_title;
            state = Model.Active;
            latest_checkpoint = exported.Model.state_baseline;
            shared_change = None;
          };
        ];
      state_changes = changes;
      state_pins = [];
      state_usernames = [];
    }
  in
  let snapshots = named_snapshots provisional in
  let state_checkpoints =
    List.map (fun checkpoint_snapshot -> Model.{ checkpoint_snapshot }) snapshots
  in
  let state = { provisional with Model.state_checkpoints } in
  let* _ = Model.import state |> Result.map_error (fun error -> Model_error error) in
  Ok state

let valid_portable_state state =
  let* _ = Model.import state |> Result.map_error (fun error -> Model_error error) in
  let* expected_draft =
    Model.Draft_id.of_string portable_draft_id
    |> Result.map_error (fun error -> Model_error error)
  in
  let active_drafts =
    List.filter (fun draft -> draft.Model.state = Model.Active) state.Model.state_drafts
  in
  let expected_snapshots = named_snapshots state in
  let actual_snapshots =
    state.Model.state_checkpoints
    |> List.map (fun checkpoint -> checkpoint.Model.checkpoint_snapshot)
    |> deduplicate_snapshots
  in
  if state.Model.state_pins <> [] || state.Model.state_usernames <> [] then
    Error (Invalid_basis "portable state contains local pins or usernames")
  else if actual_snapshots <> expected_snapshots then
    Error (Invalid_basis "portable state retains a non-history checkpoint")
  else
    match active_drafts with
    | [ draft ]
      when Model.Draft_id.equal draft.Model.draft_id expected_draft
           && Model.Draft_id.equal state.Model.state_active_draft expected_draft
           && String.equal draft.Model.title portable_draft_title
           && Model.Snapshot_id.equal draft.Model.latest_checkpoint state.Model.state_baseline
           && draft.Model.shared_change = None
           && List.for_all (fun change -> change.Model.source_draft = None) state.Model.state_changes ->
        Ok ()
    | _ -> Error (Invalid_basis "portable state contains source draft state")

let decode bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error -> Invalid_basis (Encoding.decode_error_to_string error))
  in
  let* fields = exact_array "bootstrap basis" 2 value in
  match fields with
  | [ unsigned; signature ] ->
      let* signature = bytes_field "bootstrap basis signature" signature in
      let* fields = exact_array "bootstrap basis unsigned body" 7 unsigned in
      (match fields with
      | [ version; repository; manifest; state; publisher; certificate; algorithm ] ->
          let* version = integer_field "bootstrap basis version" version in
          if not (Int64.equal version schema_version) then
            Error (Invalid_basis "unsupported bootstrap basis version")
          else
            let* repository = text_field "bootstrap basis repository" repository in
            let* repository = Trust.Repository_id.of_string repository |> Result.map_error (fun detail -> Invalid_basis detail) in
            let* manifest = text_field "bootstrap basis manifest" manifest in
            let* () = if Transport.valid_digest manifest then Ok () else Error (Invalid_basis "bootstrap basis manifest is not a digest") in
            let* state = bytes_field "bootstrap basis state" state in
            let* state = Record.decode_state state |> Result.map_error (fun error -> Record_error error) in
            let* () = valid_portable_state state in
            let* publisher = text_field "bootstrap basis publisher" publisher in
            let* publisher = Model.Device_id.of_string publisher |> Result.map_error (fun error -> Model_error error) in
            let* certificate = text_field "bootstrap basis certificate" certificate in
            let* () = if Transport.valid_digest certificate then Ok () else Error (Invalid_basis "bootstrap basis certificate is not a digest") in
            let* algorithm = text_field "bootstrap basis algorithm" algorithm in
            if not (String.equal algorithm Trust.algorithm) then Error (Invalid_basis "unsupported bootstrap basis algorithm")
            else
              let* canonical_unsigned = unsigned_bytes ~repository ~manifest ~state ~publisher ~certificate in
              let canonical = Encoding.array [ Encoding.decode canonical_unsigned |> Result.get_ok; Encoding.bytes signature ] |> Result.get_ok |> Encoding.encode in
              if not (String.equal canonical bytes) then Error Noncanonical_bytes
              else
                Ok { repository_value = repository; manifest_value = manifest; state_value = state; publisher_value = publisher; certificate_value = certificate; signature_value = signature; id_value = Transport.sha256 bytes }
      | _ -> assert false)
  | _ -> assert false

let root_certificate authority =
  match
    Trust.certificates (Trust.authority_membership authority)
    |> List.find_opt (fun certificate -> Trust.certificate_issuer certificate = None)
  with
  | Some certificate -> Ok certificate
  | None -> Error (Invalid_basis "authority closure has no root certificate")

let require_state_records records state =
  let rec require_changes = function
    | [] -> Ok ()
    | change :: rest ->
        let rec require_revisions = function
          | [] -> require_changes rest
          | revision :: remaining ->
              let matching =
                List.filter (fun signed ->
                    Model.Revision_id.equal (Trust.signed_revision_id signed) revision.Model.revision
                    && Trust.signed_revision_value signed = revision
                    && Trust.signed_revision_resolution signed = None)
                  records
              in
              if List.length matching = 1 then require_revisions remaining
              else Error (Invalid_basis "shared projection revision lacks its signed record")
        in
        require_revisions change.Model.revisions
  in
  let rec require_resolutions = function
    | [] -> Ok ()
    | resolution :: rest ->
        let matching =
          List.filter (fun signed ->
              Model.Revision_id.equal (Trust.signed_revision_id signed) resolution.Model.replacement_revision.Model.revision
              && Trust.signed_revision_value signed = resolution.Model.replacement_revision
              && Trust.signed_revision_resolution signed = Some resolution.Model.resolved_decision)
            records
        in
        if List.length matching = 1 then require_resolutions rest
        else Error (Invalid_basis "resolution projection lacks its signed record")
  in
  let all_ids = List.map Trust.signed_revision_id records in
  let rec require_deliveries = function
    | [] -> Ok ()
    | delivery :: rest ->
        if List.for_all (fun id -> List.exists (Model.Revision_id.equal id) all_ids) delivery.Model.included then require_deliveries rest
        else Error (Invalid_basis "delivery names a revision absent from the package")
  in
  let* () = require_changes state.Model.state_changes in
  let* () = require_resolutions state.Model.state_resolutions in
  require_deliveries state.Model.state_deliveries

let create ~source ~destination ~project ~authority ~revisions ~authorizations
    ~adoptions ~publisher ~certificate ~signing_capability =
  let* state = portable_state_of_project project in
  let* () =
    Package.create_bootstrap_with_authority ~source ~destination ~authority
      ~revisions ~authorizations ~adoptions
      ~extra_snapshots:(named_snapshots state)
    |> Result.map_error (fun error -> Package_error error)
  in
  let* artifact = Package.read_artifact ~package:destination |> Result.map_error (fun error -> Package_error error) in
  let manifest_value = Transport.sha256 (Package.artifact_manifest artifact) in
  let signing_device =
    Trust.device_of_public_key (Trust.signing_public_key signing_capability)
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* signing_device = signing_device in
  if not (Trust.device_equal signing_device publisher) then Error (Invalid_basis "signing capability does not match bootstrap publisher")
  else
    let* unsigned =
      unsigned_bytes ~repository:(Trust.repository (Trust.authority_membership authority))
        ~manifest:manifest_value ~state ~publisher:(Trust.device_id publisher) ~certificate
    in
    let signature = Trust.sign_detached signing_capability ~domain:signature_domain unsigned in
    let provisional =
      { repository_value = Trust.repository (Trust.authority_membership authority); manifest_value; state_value = state; publisher_value = Trust.device_id publisher; certificate_value = certificate; signature_value = signature; id_value = "" }
    in
    let id_value = Transport.sha256 (encode provisional) in
    Ok ({ provisional with id_value }, artifact)

let verify ~repository ~package ~bytes =
  let* basis = decode bytes in
  if not (Trust.Repository_id.equal repository basis.repository_value) then
    Error (Invalid_basis "bootstrap basis belongs to another repository")
  else
    let* artifact = Package.read_artifact ~package |> Result.map_error (fun error -> Package_error error) in
    if not (String.equal basis.manifest_value (Transport.sha256 (Package.artifact_manifest artifact))) then
      Error (Invalid_basis "bootstrap basis manifest does not match package")
    else
      let* authority = Package.inspect_authority ~package |> Result.map_error (fun error -> Package_error error) in
      if not (Trust.Repository_id.equal repository (Trust.repository (Trust.authority_membership authority))) then
        Error (Invalid_basis "package authority belongs to another repository")
      else
        let certificate =
          Trust.certificates (Trust.authority_membership authority)
          |> List.find_opt (fun certificate -> String.equal (Trust.certificate_id certificate) basis.certificate_value)
        in
        let* certificate =
          match certificate with
          | Some certificate -> Ok certificate
          | None -> Error (Invalid_basis "bootstrap publisher certificate is absent")
        in
        let publisher = Trust.certificate_subject certificate in
        if not (Model.Device_id.equal (Trust.device_id publisher) basis.publisher_value) then
          Error (Invalid_basis "bootstrap publisher does not match certificate")
        else if not (List.exists (fun epoch -> Trust.authority_device_active authority ~epoch publisher) (Trust.authority_heads authority)) then
          Error (Invalid_basis "bootstrap publisher is not active at a current authority head")
        else
          let* unsigned =
            unsigned_bytes ~repository:basis.repository_value ~manifest:basis.manifest_value
              ~state:basis.state_value ~publisher:basis.publisher_value
              ~certificate:basis.certificate_value
          in
          let* () =
            Trust.verify_detached ~device:publisher ~domain:signature_domain
              ~signature:basis.signature_value unsigned
            |> Result.map_error (fun error -> Trust_error error)
          in
          let* records = Package.validate_with_authority ~package ~authority |> Result.map_error (fun error -> Package_error error) in
          let* () =
            Package.validate_snapshot_closure ~package ~snapshots:(named_snapshots basis.state_value)
            |> Result.map_error (fun error -> Package_error error)
          in
          let* () = require_state_records (Package.revisions records) basis.state_value in
          Ok { verified_basis = basis; verified_package = artifact; verified_authority = authority; verified_records = records }

let authority verified = verified.verified_authority
let root_certificate verified = root_certificate verified.verified_authority

let import ~destination verified ~creator ~username ~initial_draft ~title
    ~local_certificate =
  let authority = verified.verified_authority in
  let certificate =
    Trust.certificates (Trust.authority_membership authority)
    |> List.find_opt (fun certificate -> String.equal (Trust.certificate_id certificate) local_certificate)
  in
  let* certificate =
    match certificate with
    | Some certificate -> Ok certificate
    | None -> Error (Invalid_basis "local certificate is absent from bootstrap authority")
  in
  if not (Model.Device_id.equal (Trust.device_id (Trust.certificate_subject certificate)) creator) then
    Error (Invalid_basis "local certificate does not match bootstrap device")
  else if not (List.exists (fun epoch -> Trust.authority_device_active authority ~epoch (Trust.certificate_subject certificate)) (Trust.authority_heads authority)) then
    Error (Invalid_basis "bootstrap device is not active at a current authority head")
  else
    let rec import_objects = function
      | [] -> Ok ()
      | (id, bytes) :: rest ->
          let* object_ = Envelope.decode bytes |> Result.map_error (fun error -> Envelope_error error) in
          if not (Raw_store.Stored_object_id.equal id (Raw_store.id_of_envelope object_)) then
            Error (Invalid_basis "verified package object changed identity")
          else
            let* _ = Raw_store.put destination object_ |> Result.map_error (fun error -> Store_error (Store.Store_error error)) in
            import_objects rest
    in
    let* () = import_objects (Package.artifact_objects verified.verified_package) in
    let* project =
      Model.bootstrap verified.verified_basis.state_value ~creator ~username
        ~initial_draft ~title
      |> Result.map_error (fun error -> Model_error error)
    in
    let* collaboration =
      Store.collaboration_with_authority ~authority
        ~revisions:(Package.revisions verified.verified_records)
        ~local_certificate
        ~authorizations:(Package.authorizations verified.verified_records)
        ~adoptions:(Package.adoptions verified.verified_records)
      |> Result.map_error (fun error -> Store_error error)
    in
    Ok (project, collaboration)
