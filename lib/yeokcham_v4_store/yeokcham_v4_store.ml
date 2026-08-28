module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Model = Yeokcham_v4_model
module Record = Yeokcham_v4_record
module Store = Yeokcham_store
module Trust = Yeokcham_v4_trust
module Transport = Yeokcham_v4_transport

type error =
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
  | Store_error error -> Store.error_to_string error
  | Record_error error -> Record.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Existing_repository path ->
      "refusing to initialize V4 over an existing repository: " ^ path
  | Bootstrap_error detail -> "V4 initialization bootstrap failed: " ^ detail
  | Missing_state_head -> "V4 repository has no project-state head"
  | Empty_state_head -> "V4 project-state head has no object target"
  | Unexpected_object_type object_type ->
      Printf.sprintf "V4 project-state head points to object type %d"
        (Envelope.object_type_code object_type)
  | Trust_error error -> Trust.error_to_string error
  | Transport_error error -> Transport.error_to_string error
  | Invalid_collaboration_state detail ->
      "invalid V4 collaborative state: " ^ detail
  | Collaborative_state_requires_collaborative_save ->
      "a signed V4 collaboration state must be saved with its verified \
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
  project : Model.project;
  collaboration : collaboration option;
  head : Store.Mutable_ref.t;
  object_id : Store.Stored_object_id.t;
}

let state_head_name = "v4-project-state"
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
             "V4 collaborative state requires an authority closure")
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
       "authority-less collaboration was retired before V4 release")

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
  let epochs = Trust.authority_epochs authority |> List.map Trust.encode_epoch in
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

(* Version 2 has the same authority closure as version 3, but predates the
   local-only transport state.  Keep its encoder solely for canonical decoding
   of retained V2 objects; all new authority-aware saves use V3. *)
let retired_encode_collaborative_state_v2 ~project collaboration =
  let* value = collaboration_value ~project collaboration in
  match value with
  | Encoding.Array
      [
        _;
        project;
        repository;
        certificates;
        epochs;
        revisions;
        authorizations;
        adoptions;
        local_certificate;
        _transport;
      ] ->
      array
        [
          Encoding.integer 2L;
          project;
          repository;
          certificates;
          epochs;
          revisions;
          authorizations;
          adoptions;
          local_certificate;
        ]
      |> Result.map Encoding.encode
  | Encoding.Array _ ->
      Error
        (Invalid_collaboration_state
           "version 2 requires authority-aware collaboration")
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_collaboration_state "collaborative state must be an array")

let rec retired_decode_collaborative_state encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_collaboration_state (Encoding.decode_error_to_string error))
  in
  let* fields = array_values "V4 collaborative state" value in
  match fields with
  | [ version; project; repository; certificates; revisions; local_certificate ]
    ->
      let version =
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
      let* () = version in
      let* project =
        match project with
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
      let* certificates = decode_bytes_array "certificates" certificates in
      let* certificates =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | encoded :: rest ->
              let* certificate =
                Trust.decode_certificate encoded
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (certificate :: reversed) rest
        in
        loop [] certificates
      in
      let* revisions = decode_bytes_array "signed revisions" revisions in
      let* revisions =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | encoded :: rest ->
              let* signed =
                Trust.decode_signed_revision encoded
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (signed :: reversed) rest
        in
        loop [] revisions
      in
      let* local_certificate =
        text_field "local certificate" local_certificate
      in
      let* membership =
        Trust.verify_membership ~repository certificates
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* collaboration =
        collaboration ~membership ~revisions ~local_certificate
      in
      let* collaboration = validate_collaboration ~project collaboration in
      let* canonical = encode_collaborative_state ~project collaboration in
      if String.equal canonical encoded then Ok (project, collaboration)
      else
        Error
          (Invalid_collaboration_state "collaborative state is not canonical")
  | [
   version;
   project;
   repository;
   certificates;
   epochs;
   revisions;
   authorizations;
   adoptions;
   local_certificate_value;
  ] ->
      let* () =
        match version with
        | Encoding.Integer value when Int64.equal value 2L -> Ok ()
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
        match project with
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
      let* certificates = decode_bytes_array "certificates" certificates in
      let* certificates =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | encoded :: rest ->
              let* certificate =
                Trust.decode_certificate encoded
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (certificate :: reversed) rest
        in
        loop [] certificates
      in
      let* membership =
        Trust.verify_membership ~repository certificates
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* epochs = decode_bytes_array "authority epochs" epochs in
      let* epochs =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | encoded :: rest ->
              let* epoch =
                Trust.decode_epoch encoded
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (epoch :: reversed) rest
        in
        loop [] epochs
      in
      let* authority =
        Trust.verify_authority ~membership epochs
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* revisions = decode_bytes_array "signed revisions" revisions in
      let* revisions =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | encoded :: rest ->
              let* signed =
                Trust.decode_signed_revision encoded
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (signed :: reversed) rest
        in
        loop [] revisions
      in
      let* authorizations =
        decode_bytes_array "authorizations" authorizations
      in
      let* authorizations =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | encoded :: rest ->
              let* authorization =
                Trust.decode_authorization encoded
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (authorization :: reversed) rest
        in
        loop [] authorizations
      in
      let* adoptions = decode_bytes_array "adoptions" adoptions in
      let* adoptions =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | encoded :: rest ->
              let* adoption =
                Trust.decode_adoption encoded
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (adoption :: reversed) rest
        in
        loop [] adoptions
      in
      let* local_certificate =
        text_field "local certificate" local_certificate_value
      in
      let* collaboration =
        collaboration_with_authority ~authority ~revisions ~local_certificate
          ~authorizations ~adoptions
      in
      let* collaboration = validate_collaboration ~project collaboration in
      let* canonical =
        retired_encode_collaborative_state_v2 ~project collaboration
      in
      if String.equal canonical encoded then Ok (project, collaboration)
      else
        Error
          (Invalid_collaboration_state "collaborative state is not canonical")
  | [
   version;
   project_value;
   repository;
   certificates;
   epochs;
   revisions;
   authorizations_value;
   adoptions_value;
   local_certificate_value;
   transport;
  ] ->
      let* () =
        match version with
        | Encoding.Integer value when Int64.equal value 3L -> Ok ()
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
      let* transport =
        match transport with
        | Encoding.Bytes value ->
            Transport.decode_local_state value
            |> Result.map_error (fun error -> Transport_error error)
        | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
            Error (Invalid_collaboration_state "transport state must be bytes")
      in
      let legacy =
        Encoding.array
          [
            Encoding.integer 2L;
            project_value;
            repository;
            certificates;
            epochs;
            revisions;
            authorizations_value;
            adoptions_value;
            local_certificate_value;
          ]
        |> Result.get_ok |> Encoding.encode
      in
      let* project, legacy_collaboration =
        retired_decode_collaborative_state legacy
      in
      let* authority =
        match authority legacy_collaboration with
        | Some authority -> Ok authority
        | None ->
            Error
              (Invalid_collaboration_state
                 "transport state requires authority-aware collaboration")
      in
      let* collaboration =
        collaboration_with_authority_transport ~transport ~authority
          ~revisions:(signed_revisions legacy_collaboration)
          ~local_certificate:(local_certificate legacy_collaboration)
          ~authorizations:(authorizations legacy_collaboration)
          ~adoptions:(adoptions legacy_collaboration)
      in
      let* canonical = encode_collaborative_state ~project collaboration in
      if String.equal canonical encoded then Ok (project, collaboration)
      else
        Error
          (Invalid_collaboration_state "collaborative state is not canonical")
  | _ ->
      Error
        (Invalid_collaboration_state
           "V4 collaborative state has the wrong field count")

let _ = retired_decode_collaborative_state

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
  let* fields = array_values "V4 collaborative state" value in
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
           "V4 collaborative state has the wrong field count")

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
    Envelope.create ~object_type:Envelope.V4_project_state
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

let decode_project_object store object_id =
  let* object_ =
    Store.get store object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type object_ <> Envelope.V4_project_state then
    Error (Unexpected_object_type (Envelope.object_type object_))
  else
    let encoded = Envelope.payload object_ |> Encoding.encode in
    match decode_collaborative_state encoded with
    | Ok (project, collaboration) -> Ok (project, Some collaboration)
    | Error
        ( Invalid_collaboration_state _ | Record_error _ | Trust_error _
        | Transport_error _ | Store_error _ | Envelope_error _
        | Existing_repository _ | Bootstrap_error _ | Missing_state_head
        | Empty_state_head | Unexpected_object_type _
        | Collaborative_state_requires_collaborative_save ) ->
        Record.decode_project encoded
        |> Result.map (fun project -> (project, None))
        |> Result.map_error (fun error -> Record_error error)

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
          let* project, collaboration =
            decode_project_object repository.store object_id
          in
          Ok { project; collaboration; head; object_id })

let init_with ~root ~bootstrap =
  let metadata = repository_metadata_path root in
  if Sys.file_exists metadata then Error (Existing_repository metadata)
  else
    let* store =
      Store.init ~root |> Result.map_error (fun error -> Store_error error)
    in
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

let save repository ~expected ~project =
  let* existing_collaboration =
    match Store.Mutable_ref.target expected with
    | None -> Error Empty_state_head
    | Some object_id ->
        let* _, collaboration =
          decode_project_object repository.store object_id
        in
        Ok collaboration
  in
  let* () =
    match existing_collaboration with
    | None -> Ok ()
    | Some _ -> Error Collaborative_state_requires_collaborative_save
  in
  let* object_id = store_project repository.store project in
  let* head =
    Store.compare_and_swap_ref repository.store ~name:state_head_name
      ~expected:(Some expected) ~target:(Some object_id)
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok { project; collaboration = None; head; object_id }

let save_collaborative repository ~expected ~project ~collaboration =
  let* collaboration = validate_collaboration ~project collaboration in
  let* object_id =
    store_collaborative_project repository.store project collaboration
  in
  let* head =
    Store.compare_and_swap_ref repository.store ~name:state_head_name
      ~expected:(Some expected) ~target:(Some object_id)
    |> Result.map_error (fun error -> Store_error error)
  in
  Ok { project; collaboration = Some collaboration; head; object_id }
