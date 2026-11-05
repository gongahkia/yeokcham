module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Model = Yeokcham_v1_model
module Record = Yeokcham_v1_record
module Store = Yeokcham_store
module Trust = Yeokcham_v1_trust
module Transport = Yeokcham_v1_transport
module History = Yeokcham_v1_undo

type error =
  | History_error of string
  | Store_error of Store.error
  | Record_error of Record.error
  | Envelope_error of Envelope.creation_error
  | Existing_repository of string
  | Bootstrap_error of string
  | Missing_state_head
  | Empty_state_head
  | Unexpected_object_type of Envelope.object_type
  | Trust_error of Trust.error
  | Transport_error of Transport.error
  | Invalid_collaboration_state of string
  | Collaborative_state_requires_collaborative_save

let error_to_string = function
  | History_error detail -> "invalid local undo history: " ^ detail
  | Store_error error -> Store.error_to_string error
  | Record_error error -> Record.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Existing_repository path ->
      "refusing to initialize V1 over an existing repository: " ^ path
  | Bootstrap_error detail -> "V1 initialization bootstrap failed: " ^ detail
  | Missing_state_head -> "V1 repository has no project-state head"
  | Empty_state_head -> "V1 project-state head has no object target"
  | Unexpected_object_type object_type ->
      Printf.sprintf "V1 project-state head points to object type %d"
        (Envelope.object_type_code object_type)
  | Trust_error error -> Trust.error_to_string error
  | Transport_error error -> Transport.error_to_string error
  | Invalid_collaboration_state detail ->
      "invalid V1 collaborative state: " ^ detail
  | Collaborative_state_requires_collaborative_save ->
      "a signed V1 collaboration state must be saved with its verified \
       collaboration records"

type repository = { store : Store.repository }

type collaboration = {
  collaboration_membership : Trust.membership;
  collaboration_authority : Trust.authority option;
  collaboration_revisions : Trust.signed_revision list;
  collaboration_authorizations : Trust.authorization list;
  collaboration_adoptions : Trust.adoption list;
  collaboration_transport : Transport.local_state;
  collaboration_local_certificate : string;
}

type loaded = {
  history : History.t;
  project : Model.project;
  collaboration : collaboration option;
  head : Store.Mutable_ref.t;
  object_id : Store.Stored_object_id.t;
}

let state_head_name = "v1-project-state"
let underlying_store repository = repository.store
let ( let* ) = Result.bind
let repository_metadata_path root = Filename.concat root ".yeokcham"

let all_project_revisions project =
  let shared =
    Model.shared_changes project
    |> List.concat_map (fun change -> change.Model.revisions)
  in
  let replacements =
    Model.resolutions project
    |> List.map (fun resolution -> resolution.Model.replacement_revision)
  in
  shared @ replacements

let revision_equal left right =
  Model.Revision_id.equal left.Model.revision right.Model.revision
  && left = right

let sorted_revisions revisions =
  List.sort
    (fun left right ->
      Model.Revision_id.compare left.Model.revision right.Model.revision)
    revisions

let validate_collaboration ~project collaboration =
  let membership = collaboration.collaboration_membership in
  let* membership =
    Trust.verify_membership
      ~repository:(Trust.repository membership)
      (Trust.certificates membership)
    |> Result.map_error (fun error -> Trust_error error)
  in
  let local_certificate_id = collaboration.collaboration_local_certificate in
  let* local_certificate =
    match
      List.find_opt
        (fun certificate ->
          String.equal (Trust.certificate_id certificate) local_certificate_id)
        (Trust.certificates membership)
    with
    | None ->
        Error
          (Invalid_collaboration_state
             "local certificate is absent from the verified membership")
    | Some certificate -> Ok certificate
  in
  let* authority =
    match collaboration.collaboration_authority with
    | None ->
        Error
          (Invalid_collaboration_state
             "V1 collaborative state requires an authority closure")
    | Some authority ->
        let* authority =
          Trust.verify_authority ~membership (Trust.authority_epochs authority)
          |> Result.map_error (fun error -> Trust_error error)
        in
        Ok authority
  in
  let* () =
    if
      List.exists
        (fun epoch ->
          Trust.authority_device_active authority ~epoch
            (Trust.certificate_subject local_certificate))
        (Trust.authority_heads authority)
    then Ok ()
    else
      Error
        (Invalid_collaboration_state
           "local certificate is not active in any authority head")
  in
  let rec verify reversed = function
    | [] -> Ok (List.rev reversed)
    | signed :: rest ->
        let* () =
          Trust.verify_signed_revision_at authority signed
          |> Result.map_error (fun error -> Trust_error error)
        in
        verify (signed :: reversed) rest
  in
  let* signed_revisions = verify [] collaboration.collaboration_revisions in
  let project_revisions = all_project_revisions project |> sorted_revisions in
  let signed_values =
    signed_revisions |> List.map Trust.signed_revision_value |> sorted_revisions
  in
  let signed_ids =
    signed_values |> List.map (fun revision -> revision.Model.revision)
  in
  let unique_signed_ids =
    List.length signed_ids
    = List.length (List.sort_uniq Model.Revision_id.compare signed_ids)
  in
  let signed_record_describes_project signed =
    let revision = Trust.signed_revision_value signed in
    match Trust.signed_revision_resolution signed with
    | None ->
        Model.shared_changes project
        |> List.concat_map (fun change -> change.Model.revisions)
        |> List.exists (fun existing -> revision_equal existing revision)
    | Some decision ->
        Model.resolutions project
        |> List.exists (fun resolution ->
            Model.Decision_id.equal resolution.Model.resolved_decision decision
            && revision_equal resolution.Model.replacement_revision revision)
  in
  let every_current_revision_has_matching_signed_record =
    List.for_all
      (fun revision ->
        List.exists
          (fun signed ->
            revision_equal revision (Trust.signed_revision_value signed)
            && signed_record_describes_project signed)
          signed_revisions)
      project_revisions
  in
  if not (unique_signed_ids && every_current_revision_has_matching_signed_record)
  then
    Error
      (Invalid_collaboration_state
         "every current project revision must have exactly one verified signed \
          record with its matching shared or resolution purpose")
  else
    let* () =
      let rec verify_authorizations = function
        | [] -> Ok ()
        | authorization :: rest ->
            let* () =
              Trust.verify_authorization authority authorization
              |> Result.map_error (fun error -> Trust_error error)
            in
            let matching =
              List.filter
                (Trust.authorization_matches_signed_revision authorization)
                signed_revisions
            in
            if List.length matching = 1 then verify_authorizations rest
            else
              Error
                (Invalid_collaboration_state
                   "authorization must name exactly one signed revision")
      in
      let rec verify_adoptions = function
        | [] -> Ok ()
        | adoption :: rest ->
            let* () =
              Trust.verify_adoption authority adoption
              |> Result.map_error (fun error -> Trust_error error)
            in
            let matching =
              List.filter
                (Trust.adoption_matches_signed_revision adoption)
                signed_revisions
            in
            if List.length matching = 1 then verify_adoptions rest
            else
              Error
                (Invalid_collaboration_state
                   "adoption must bind exactly one signed revision")
      in
      let* () =
        verify_authorizations collaboration.collaboration_authorizations
      in
      verify_adoptions collaboration.collaboration_adoptions
    in
    Ok
      {
        collaboration_membership = membership;
        collaboration_authority = Some authority;
        collaboration_revisions = signed_revisions;
        collaboration_authorizations =
          collaboration.collaboration_authorizations;
        collaboration_adoptions = collaboration.collaboration_adoptions;
        collaboration_transport = collaboration.collaboration_transport;
        collaboration_local_certificate = local_certificate_id;
      }

let collaboration ~membership:_ ~revisions:_ ~local_certificate:_ =
  Error
    (Invalid_collaboration_state
       "authority-less collaboration was retired before V1 release")

let membership collaboration = collaboration.collaboration_membership
let authority collaboration = collaboration.collaboration_authority
let signed_revisions collaboration = collaboration.collaboration_revisions
let authorizations collaboration = collaboration.collaboration_authorizations
let adoptions collaboration = collaboration.collaboration_adoptions
let transport collaboration = collaboration.collaboration_transport

let local_certificate collaboration =
  collaboration.collaboration_local_certificate

let collaboration_with_authority_transport ~transport ~authority ~revisions
    ~local_certificate ~authorizations ~adoptions =
  let collaboration =
    {
      collaboration_membership = Trust.authority_membership authority;
      collaboration_authority = Some authority;
      collaboration_revisions = revisions;
      collaboration_authorizations = authorizations;
      collaboration_adoptions = adoptions;
      collaboration_transport = transport;
      collaboration_local_certificate = local_certificate;
    }
  in
  let membership = Trust.authority_membership authority in
  let* authority =
    Trust.verify_authority ~membership (Trust.authority_epochs authority)
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* () =
    match
      List.find_opt
        (fun certificate ->
          String.equal (Trust.certificate_id certificate) local_certificate)
        (Trust.certificates membership)
    with
    | Some _ -> Ok ()
    | None ->
        Error
          (Invalid_collaboration_state
             "local certificate is absent from the verified membership")
  in
  let rec verify_revisions = function
    | [] -> Ok ()
    | revision :: rest ->
        let* () =
          Trust.verify_signed_revision_at authority revision
          |> Result.map_error (fun error -> Trust_error error)
        in
        verify_revisions rest
  in
  let* () = verify_revisions revisions in
  Ok { collaboration with collaboration_authority = Some authority }

let collaboration_with_authority ~authority ~revisions ~local_certificate
    ~authorizations ~adoptions =
  collaboration_with_authority_transport ~transport:Transport.empty_local_state
    ~authority ~revisions ~local_certificate ~authorizations ~adoptions

let construction value =
  value
  |> Result.map_error (fun error ->
      Invalid_collaboration_state (Encoding.construction_error_to_string error))

let text value = Encoding.text value |> construction
let array value = Encoding.array value |> construction

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_collaboration_state (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_collaboration_state (name ^ " must be text"))

let bytes_array values =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | value :: rest -> loop (Encoding.bytes value :: reversed) rest
  in
  loop [] values

let decode_bytes_array name = function
  | Encoding.Array values ->
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | Encoding.Bytes value :: rest -> loop (value :: reversed) rest
        | ( Encoding.Integer _ | Encoding.Text _ | Encoding.Array _
          | Encoding.Map _ | Encoding.Bool _ | Encoding.Null )
          :: _ ->
            Error (Invalid_collaboration_state (name ^ " must contain bytes"))
      in
      loop [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_collaboration_state (name ^ " must be an array"))

let collaboration_value ~project collaboration =
  let* collaboration = validate_collaboration ~project collaboration in
  let* project =
    Record.encode_project project
    |> Result.map_error (fun error -> Record_error error)
  in
  let* repository =
    text
      (Trust.Repository_id.to_string
         (Trust.repository collaboration.collaboration_membership))
  in
  let certificates =
    collaboration.collaboration_membership |> Trust.certificates
    |> List.map Trust.encode_certificate
  in
  let revisions =
    collaboration.collaboration_revisions
    |> List.sort (fun left right ->
        Model.Revision_id.compare
          (Trust.signed_revision_id left)
          (Trust.signed_revision_id right))
    |> List.map Trust.encode_signed_revision
  in
  let* certificates = bytes_array certificates in
  let* revisions = bytes_array revisions in
  let* local_certificate = text collaboration.collaboration_local_certificate in
  let authority =
    match collaboration.collaboration_authority with
    | Some authority -> authority
    | None -> assert false
  in
  let epochs =
    Trust.authority_epochs authority |> List.map Trust.encode_epoch
  in
  let authorizations =
    collaboration.collaboration_authorizations
    |> List.map Trust.encode_authorization
  in
  let adoptions =
    collaboration.collaboration_adoptions |> List.map Trust.encode_adoption
  in
  let* epochs = bytes_array epochs in
  let* authorizations = bytes_array authorizations in
  let* adoptions = bytes_array adoptions in
  let* transport =
    Transport.encode_local_state collaboration.collaboration_transport
    |> Result.map_error (fun error -> Transport_error error)
  in
  array
    [
      Encoding.integer 1L;
      Encoding.bytes project;
      repository;
      certificates;
      epochs;
      revisions;
      authorizations;
      adoptions;
      local_certificate;
      Encoding.bytes transport;
    ]

let encode_collaborative_state ~project collaboration =
  collaboration_value ~project collaboration |> Result.map Encoding.encode

let decode_collaboration_records name decode value =
  let* encoded = decode_bytes_array name value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | bytes :: rest ->
        let* record = decode bytes in
        loop (record :: reversed) rest
  in
  loop [] encoded

let decode_collaborative_state encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_collaboration_state (Encoding.decode_error_to_string error))
  in
  let* fields = array_values "V1 collaborative state" value in
  match fields with
  | [
   version;
   project_value;
   repository;
   certificates;
   epochs;
   revisions;
   authorizations;
   adoptions;
   local_certificate_value;
   transport_value;
  ] ->
      let* () =
        match version with
        | Encoding.Integer value when Int64.equal value 1L -> Ok ()
        | Encoding.Integer _ ->
            Error
              (Invalid_collaboration_state
                 "unsupported collaborative state version")
        | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
        | Encoding.Bool _ | Encoding.Null ->
            Error
              (Invalid_collaboration_state
                 "collaborative state version must be an integer")
      in
      let* project =
        match project_value with
        | Encoding.Bytes value ->
            Record.decode_project value
            |> Result.map_error (fun error -> Record_error error)
        | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
            Error (Invalid_collaboration_state "project record must be bytes")
      in
      let* repository = text_field "repository ID" repository in
      let* repository =
        Trust.Repository_id.of_string repository
        |> Result.map_error (fun error -> Invalid_collaboration_state error)
      in
      let* certificates =
        decode_collaboration_records "certificates"
          (fun bytes ->
            Trust.decode_certificate bytes
            |> Result.map_error (fun error -> Trust_error error))
          certificates
      in
      let* membership =
        Trust.verify_membership ~repository certificates
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* epochs =
        decode_collaboration_records "authority epochs"
          (fun bytes ->
            Trust.decode_epoch bytes
            |> Result.map_error (fun error -> Trust_error error))
          epochs
      in
      let* authority =
        Trust.verify_authority ~membership epochs
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* revisions =
        decode_collaboration_records "signed revisions"
          (fun bytes ->
            Trust.decode_signed_revision bytes
            |> Result.map_error (fun error -> Trust_error error))
          revisions
      in
      let* authorizations =
        decode_collaboration_records "authorizations"
          (fun bytes ->
            Trust.decode_authorization bytes
            |> Result.map_error (fun error -> Trust_error error))
          authorizations
      in
      let* adoptions =
        decode_collaboration_records "adoptions"
          (fun bytes ->
            Trust.decode_adoption bytes
            |> Result.map_error (fun error -> Trust_error error))
          adoptions
      in
      let* local_certificate =
        text_field "local certificate" local_certificate_value
      in
      let* transport =
        match transport_value with
        | Encoding.Bytes value ->
            Transport.decode_local_state value
            |> Result.map_error (fun error -> Transport_error error)
        | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
            Error (Invalid_collaboration_state "transport state must be bytes")
      in
      let* collaboration =
        collaboration_with_authority_transport ~transport ~authority ~revisions
          ~local_certificate ~authorizations ~adoptions
      in
      let* canonical = encode_collaborative_state ~project collaboration in
      if String.equal canonical encoded then Ok (project, collaboration)
      else
        Error
          (Invalid_collaboration_state "collaborative state is not canonical")
  | _ ->
      Error
        (Invalid_collaboration_state
           "V1 collaborative state has the wrong field count")

let payload_for_project project =
  let* encoded =
    Record.encode_project project
    |> Result.map_error (fun error -> Record_error error)
  in
  Encoding.decode encoded
  |> Result.map_error (fun error -> Record_error (Record.Decode_error error))

let payload_for_collaborative_project project collaboration =
  let* encoded = encode_collaborative_state ~project collaboration in
  Encoding.decode encoded
  |> Result.map_error (fun error ->
      Invalid_collaboration_state (Encoding.decode_error_to_string error))

let store_payload store payload =
  let* envelope =
    Envelope.create ~object_type:Envelope.V1_project_state
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.map_error (fun error -> Envelope_error error)
  in
  Store.put store envelope |> Result.map_error (fun error -> Store_error error)

let store_project store project =
  let* payload = payload_for_project project in
  store_payload store payload

let store_collaborative_project store project collaboration =
  let* payload = payload_for_collaborative_project project collaboration in
  store_payload store payload

let history_for_project project =
  let active = Model.active_draft project in
  History.seed ~snapshot:active.Model.latest_checkpoint
    ~draft:active.Model.draft_id

let validate_history project history =
  if
    Model.Snapshot_id.equal (History.current history).History.snapshot
      (Model.active_draft project).Model.latest_checkpoint
  then Ok history
  else Error (History_error "cursor does not match the active checkpoint")

let decode_inner encoded =
  match decode_collaborative_state encoded with
  | Ok (project, collaboration) -> Ok (project, Some collaboration)
  | Error _ ->
      Record.decode_project encoded
      |> Result.map (fun project -> (project, None))
      |> Result.map_error (fun error -> Record_error error)

let[@warning "-4"] decode_project_object store object_id =
  let* object_ =
    Store.get store object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.V1_project_state then
    Error (Unexpected_object_type (Envelope.object_type object_))
  else
    match Envelope.payload object_ with
    | Encoding.Array
        [
          Encoding.Text "yeokcham-local-state";
          Encoding.Integer 1L;
          Encoding.Bytes inner;
          Encoding.Bytes bytes;
        ] ->
        let* project, collaboration = decode_inner inner in
        let* history =
          History.decode bytes |> Result.map_error (fun e -> History_error e)
        in
        let* history = validate_history project history in
        Ok (project, collaboration, history)
    | Encoding.Array (Encoding.Text "yeokcham-local-state" :: _) ->
        Error (History_error "unsupported local state wrapper")
    | payload ->
        let* project, collaboration = decode_inner (Encoding.encode payload) in
        Ok (project, collaboration, history_for_project project)

let store_with_history store project collaboration history =
  let* history = validate_history project history in
  let* inner =
    match collaboration with
    | None ->
        Record.encode_project project
        |> Result.map_error (fun e -> Record_error e)
    | Some collaboration -> encode_collaborative_state ~project collaboration
  in
  let* history =
    History.encode history |> Result.map_error (fun e -> History_error e)
  in
  let* tag =
    Encoding.text "yeokcham-local-state"
    |> Result.map_error (fun e ->
        History_error (Encoding.construction_error_to_string e))
  in
  let* payload =
    Encoding.array
      [ tag; Encoding.integer 1L; Encoding.bytes inner; Encoding.bytes history ]
    |> Result.map_error (fun e ->
        History_error (Encoding.construction_error_to_string e))
  in
  store_payload store payload

let observed_history ?history existing project =
  match history with
  | Some history -> validate_history project history
  | None ->
      let active = Model.active_draft project in
      History.record existing ~snapshot:active.Model.latest_checkpoint
        ~draft:active.Model.draft_id
        ~created_at:(Int64.of_float (Unix.gettimeofday ()))
      |> Result.map_error (fun e -> History_error e)

let current_head repository =
  Store.read_ref repository.store ~name:state_head_name
  |> Result.map_error (fun error -> Store_error error)

let load repository =
  let* head = current_head repository in
  match head with
  | None -> Error Missing_state_head
  | Some head -> (
      match Store.Mutable_ref.target head with
      | None -> Error Empty_state_head
      | Some object_id ->
          let* project, collaboration, history =
            decode_project_object repository.store object_id
          in
          Ok { project; collaboration; history; head; object_id })

let initialize_workspace_lock ~root =
  let path =
    Filename.concat (repository_metadata_path root) "local-worktree.lock"
  in
  try
    let fd =
      Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o600
    in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
    Ok ()
  with Unix.Unix_error (error, _, _) ->
    Error
      (Store_error
         (Store.Io_error
            {
              operation = "initialize workspace lock";
              path;
              message = Unix.error_message error;
            }))

let init_with ~root ~bootstrap =
  let metadata = repository_metadata_path root in
  if Sys.file_exists metadata then Error (Existing_repository metadata)
  else
    let* store =
      Store.init ~root |> Result.map_error (fun error -> Store_error error)
    in
    let* () = initialize_workspace_lock ~root in
    let* project =
      bootstrap store |> Result.map_error (fun error -> Bootstrap_error error)
    in
    let* object_id = store_project store project in
    let* _ =
      Store.compare_and_swap_ref store ~name:state_head_name ~expected:None
        ~target:(Some object_id)
      |> Result.map_error (fun error -> Store_error error)
    in
    Ok { store }

let init ~root ~project = init_with ~root ~bootstrap:(fun _ -> Ok project)

let init_collaborative_with ~root ~bootstrap =
  let metadata = repository_metadata_path root in
  if Sys.file_exists metadata then Error (Existing_repository metadata)
  else
    let* store =
      Store.init ~root |> Result.map_error (fun error -> Store_error error)
    in
    let* () = initialize_workspace_lock ~root in
    let* project, collaboration =
      bootstrap store |> Result.map_error (fun error -> Bootstrap_error error)
    in
    let* collaboration = validate_collaboration ~project collaboration in
    let* object_id = store_collaborative_project store project collaboration in
    let* _ =
      Store.compare_and_swap_ref store ~name:state_head_name ~expected:None
        ~target:(Some object_id)
      |> Result.map_error (fun error -> Store_error error)
    in
    Ok { store }

let init_collaborative ~root ~project ~collaboration =
  init_collaborative_with ~root ~bootstrap:(fun _ ->
      Ok (project, collaboration))

let open_repository ~root =
  let* store =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let repository = { store } in
  let* _ = load repository in
  Ok repository

let previous repository expected =
  match Store.Mutable_ref.target expected with
  | None -> Error Empty_state_head
  | Some object_id -> decode_project_object repository.store object_id

let save ?history repository ~expected ~project =
  let* _, existing_collaboration, existing_history =
    previous repository expected
  in
  let* () =
    match existing_collaboration with
    | None -> Ok ()
    | Some _ -> Error Collaborative_state_requires_collaborative_save
  in
  let* history = observed_history ?history existing_history project in
  let* object_id = store_with_history repository.store project None history in
  let* head =
    Store.compare_and_swap_ref repository.store ~name:state_head_name
      ~expected:(Some expected) ~target:(Some object_id)
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok { project; collaboration = None; history; head; object_id }

let save_collaborative ?history repository ~expected ~project ~collaboration =
  let* collaboration = validate_collaboration ~project collaboration in
  let* _, _, existing_history = previous repository expected in
  let* history = observed_history ?history existing_history project in
  let* object_id =
    store_with_history repository.store project (Some collaboration) history
  in
  let* head =
    Store.compare_and_swap_ref repository.store ~name:state_head_name
      ~expected:(Some expected) ~target:(Some object_id)
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok { project; collaboration = Some collaboration; history; head; object_id }
