module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust
module Store = Yeokcham_store
module Envelope = Yeokcham_envelope
module Snapshot = Yeokcham_snapshot
module Encoding = Yeokcham_encoding
module Object_set = Set.Make (String)

type verified = {
  verified_membership : Trust.membership;
  verified_authority : Trust.authority option;
  verified_revisions : Trust.signed_revision list;
  verified_authorizations : Trust.authorization list;
  verified_adoptions : Trust.adoption list;
}

type manifest = {
  manifest_repository : Trust.Repository_id.t;
  manifest_membership : Trust.membership;
  manifest_authority : Trust.authority option;
  manifest_revisions : Trust.signed_revision list;
  manifest_authorizations : Trust.authorization list;
  manifest_adoptions : Trust.adoption list;
  manifest_object_ids : Store.Stored_object_id.t list;
}

type error =
  | Io_error of { path : string; operation : string; message : string }
  | Destination_exists of string
  | Invalid_package of string
  | Noncanonical_manifest
  | Store_error of Store.error
  | Envelope_error of Envelope.decode_error
  | Object_identity_mismatch of string
  | Trust_error of Trust.error
  | Snapshot_error of Snapshot.error
  | Model_error of Model.error

let ( let* ) = Result.bind
let manifest_name = "manifest.cbor"
let objects_name = "objects"

let error_to_string = function
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 package %s %s: %s" operation path message
  | Destination_exists path -> "V4 package destination already exists: " ^ path
  | Invalid_package detail -> "invalid V4 package: " ^ detail
  | Noncanonical_manifest -> "V4 package manifest is not canonically encoded"
  | Store_error error -> Store.error_to_string error
  | Envelope_error error -> Envelope.decode_error_to_string error
  | Object_identity_mismatch id ->
      "V4 package object bytes do not match identity: " ^ id
  | Trust_error error -> Trust.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Model_error error -> Model.error_to_string error

let construction value =
  Result.map_error
    (fun error -> Invalid_package (Encoding.construction_error_to_string error))
    value

let text value = Encoding.text value |> construction
let array values = Encoding.array values |> construction

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be text"))

let bytes_field name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be bytes"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_package (name ^ " must be integer"))

let package_path root name = Filename.concat root name
let object_path root id = Filename.concat (package_path root objects_name) id

let write_file_exclusive path bytes =
  try
    let channel =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      |> Unix.out_channel_of_descr
    in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        Out_channel.output_string channel bytes;
        Out_channel.flush channel);
    Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error (Io_error { path; operation; message = Unix.error_message error })

let read_file path =
  try In_channel.with_open_bin path In_channel.input_all |> Result.ok
  with Sys_error message ->
    Error (Io_error { path; operation = "read"; message })

let mkdir path =
  try
    Unix.mkdir path 0o700;
    Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error (Io_error { path; operation; message = Unix.error_message error })

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_staging f =
  let root = Filename.temp_file "yeokcham-v4-package-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let encode_bytes values =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | value :: rest -> loop (Encoding.bytes value :: reversed) rest
  in
  loop [] values

let decode_bytes name value =
  let* values = array_values name value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* value = bytes_field name value in
        loop (value :: reversed) rest
  in
  loop [] values

let encode_texts values =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | value :: rest ->
        let* value = text value in
        loop (value :: reversed) rest
  in
  loop [] values

let decode_object_ids value =
  let* values = array_values "object IDs" value in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* text = text_field "object ID" value in
        let* id =
          Store.Stored_object_id.of_hex text
          |> Result.map_error (fun _ -> Invalid_package "invalid object ID")
        in
        loop (id :: reversed) rest
  in
  loop [] values

let ensure_unique_signed_revisions revisions =
  let ids =
    revisions
    |> List.map Trust.signed_revision_id
    |> List.sort Model.Revision_id.compare
  in
  let rec unique = function
    | [] | [ _ ] -> Ok ()
    | first :: (second :: _ as rest) ->
        if Model.Revision_id.equal first second then
          Error
            (Invalid_package
               "manifest contains the same revision more than once")
        else unique rest
  in
  unique ids

let manifest_bytes ~membership ~revisions ~object_ids =
  let* repository =
    text (Trust.repository membership |> Trust.Repository_id.to_string)
  in
  let certificates =
    Trust.certificates membership |> List.map Trust.encode_certificate
  in
  let revisions =
    revisions
    |> List.sort (fun left right ->
        Model.Revision_id.compare
          (Trust.signed_revision_id left)
          (Trust.signed_revision_id right))
    |> List.map Trust.encode_signed_revision
  in
  let object_ids =
    object_ids
    |> List.map Store.Stored_object_id.to_hex
    |> List.sort String.compare
  in
  let* certificates = encode_bytes certificates in
  let* revisions = encode_bytes revisions in
  let* object_ids = encode_texts object_ids in
  array [ Encoding.integer 1L; repository; certificates; revisions; object_ids ]
  |> Result.map Encoding.encode

let ensure_unique_bytes name values =
  let sorted = List.sort String.compare values in
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | left :: (right :: _ as rest) ->
        if String.equal left right then
          Error (Invalid_package (name ^ " contains a duplicate record"))
        else loop rest
  in
  loop sorted

let manifest_bytes_v2 ~authority ~revisions ~authorizations ~adoptions
    ~object_ids =
  let membership = Trust.authority_membership authority in
  let* authority =
    Trust.verify_authority ~membership (Trust.authority_epochs authority)
    |> Result.map_error (fun error -> Trust_error error)
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
  let rec verify_authorizations = function
    | [] -> Ok ()
    | authorization :: rest ->
        let* () =
          Trust.verify_authorization authority authorization
          |> Result.map_error (fun error -> Trust_error error)
        in
        if
          List.length
            (List.filter
               (Trust.authorization_matches_signed_revision authorization)
               revisions)
          = 1
        then verify_authorizations rest
        else
          Error
            (Invalid_package
               "authorization must name exactly one signed revision")
  in
  let rec verify_adoptions = function
    | [] -> Ok ()
    | adoption :: rest ->
        let* () =
          Trust.verify_adoption authority adoption
          |> Result.map_error (fun error -> Trust_error error)
        in
        if
          List.length
            (List.filter (Trust.adoption_matches_signed_revision adoption) revisions)
          = 1
        then verify_adoptions rest
        else
          Error
            (Invalid_package "adoption must bind exactly one signed revision")
  in
  let* () = ensure_unique_signed_revisions revisions in
  let* () = verify_revisions revisions in
  let* () = verify_authorizations authorizations in
  let* () = verify_adoptions adoptions in
  let certificates = Trust.certificates membership |> List.map Trust.encode_certificate in
  let epochs = Trust.authority_epochs authority |> List.map Trust.encode_epoch in
  let revisions =
    revisions
    |> List.sort (fun left right ->
           Model.Revision_id.compare
             (Trust.signed_revision_id left)
             (Trust.signed_revision_id right))
    |> List.map Trust.encode_signed_revision
  in
  let authorizations = authorizations |> List.map Trust.encode_authorization |> List.sort String.compare in
  let adoptions = adoptions |> List.map Trust.encode_adoption |> List.sort String.compare in
  let* () = ensure_unique_bytes "authorizations" authorizations in
  let* () = ensure_unique_bytes "adoptions" adoptions in
  let object_ids =
    object_ids |> List.map Store.Stored_object_id.to_hex |> List.sort String.compare
  in
  let* repository = text (Trust.repository membership |> Trust.Repository_id.to_string) in
  let* certificates = encode_bytes certificates in
  let* epochs = encode_bytes epochs in
  let* revisions = encode_bytes revisions in
  let* authorizations = encode_bytes authorizations in
  let* adoptions = encode_bytes adoptions in
  let* object_ids = encode_texts object_ids in
  array
    [
      Encoding.integer 2L;
      repository;
      certificates;
      epochs;
      revisions;
      authorizations;
      adoptions;
      object_ids;
    ]
  |> Result.map Encoding.encode

let decode_manifest bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Invalid_package (Encoding.decode_error_to_string error))
  in
  let* fields = array_values "manifest" value in
  match fields with
  | [ version; repository; certificates; revisions; object_ids ] ->
      let* version = integer_field "manifest version" version in
      let* repository = text_field "manifest repository" repository in
      let* repository =
        Trust.Repository_id.of_string repository
        |> Result.map_error (fun detail -> Invalid_package detail)
      in
      let* certificates = decode_bytes "certificate records" certificates in
      let* certificates =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | bytes :: rest ->
              let* certificate =
                Trust.decode_certificate bytes
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (certificate :: reversed) rest
        in
        loop [] certificates
      in
      let* revisions = decode_bytes "revision records" revisions in
      let* revisions =
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | bytes :: rest ->
              let* revision =
                Trust.decode_signed_revision bytes
                |> Result.map_error (fun error -> Trust_error error)
              in
              loop (revision :: reversed) rest
        in
        loop [] revisions
      in
      let* object_ids = decode_object_ids object_ids in
      if not (Int64.equal version 1L) then
        Error (Invalid_package "unsupported manifest version")
      else
        let* () = ensure_unique_signed_revisions revisions in
        let* membership =
          Trust.verify_membership ~repository certificates
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* canonical = manifest_bytes ~membership ~revisions ~object_ids in
        if String.equal bytes canonical then
          Ok
            {
              manifest_repository = repository;
              manifest_membership = membership;
              manifest_authority = None;
              manifest_revisions = revisions;
              manifest_authorizations = [];
              manifest_adoptions = [];
              manifest_object_ids = object_ids;
            }
        else Error Noncanonical_manifest
  | [
   version;
   repository;
   certificates;
   epochs;
   revisions;
   authorizations;
   adoptions;
   object_ids;
  ] ->
      let* version = integer_field "manifest version" version in
      let* repository = text_field "manifest repository" repository in
      let* repository =
        Trust.Repository_id.of_string repository
        |> Result.map_error (fun detail -> Invalid_package detail)
      in
      let* certificates = decode_bytes "certificate records" certificates in
      let rec decode_certificates reversed = function
        | [] -> Ok (List.rev reversed)
        | bytes :: rest ->
            let* certificate =
              Trust.decode_certificate bytes
              |> Result.map_error (fun error -> Trust_error error)
            in
            decode_certificates (certificate :: reversed) rest
      in
      let* certificates = decode_certificates [] certificates in
      let* membership =
        Trust.verify_membership ~repository certificates
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* epochs = decode_bytes "authority epoch records" epochs in
      let rec decode_epochs reversed = function
        | [] -> Ok (List.rev reversed)
        | bytes :: rest ->
            let* epoch =
              Trust.decode_epoch bytes |> Result.map_error (fun error -> Trust_error error)
            in
            decode_epochs (epoch :: reversed) rest
      in
      let* epochs = decode_epochs [] epochs in
      let* authority =
        Trust.verify_authority ~membership epochs
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* revisions = decode_bytes "revision records" revisions in
      let rec decode_revisions reversed = function
        | [] -> Ok (List.rev reversed)
        | bytes :: rest ->
            let* revision =
              Trust.decode_signed_revision bytes
              |> Result.map_error (fun error -> Trust_error error)
            in
            decode_revisions (revision :: reversed) rest
      in
      let* revisions = decode_revisions [] revisions in
      let* authorizations = decode_bytes "authorization records" authorizations in
      let rec decode_authorizations reversed = function
        | [] -> Ok (List.rev reversed)
        | bytes :: rest ->
            let* authorization =
              Trust.decode_authorization bytes
              |> Result.map_error (fun error -> Trust_error error)
            in
            decode_authorizations (authorization :: reversed) rest
      in
      let* authorizations = decode_authorizations [] authorizations in
      let* adoptions = decode_bytes "adoption records" adoptions in
      let rec decode_adoptions reversed = function
        | [] -> Ok (List.rev reversed)
        | bytes :: rest ->
            let* adoption =
              Trust.decode_adoption bytes
              |> Result.map_error (fun error -> Trust_error error)
            in
            decode_adoptions (adoption :: reversed) rest
      in
      let* adoptions = decode_adoptions [] adoptions in
      let* object_ids = decode_object_ids object_ids in
      if not (Int64.equal version 2L) then
        Error (Invalid_package "unsupported manifest version")
      else
        let* canonical =
          manifest_bytes_v2 ~authority ~revisions ~authorizations ~adoptions
            ~object_ids
        in
        if String.equal bytes canonical then
          Ok
            {
              manifest_repository = repository;
              manifest_membership = membership;
              manifest_authority = Some authority;
              manifest_revisions = revisions;
              manifest_authorizations = authorizations;
              manifest_adoptions = adoptions;
              manifest_object_ids = object_ids;
            }
        else Error Noncanonical_manifest
  | _ -> Error (Invalid_package "manifest has wrong field count")

let snapshot_object_id snapshot =
  Model.Snapshot_id.to_string snapshot
  |> Store.Stored_object_id.of_hex
  |> Result.map_error (fun _ ->
      Invalid_package "revision snapshot ID is invalid")

let add_id set id = Object_set.add (Store.Stored_object_id.to_hex id) set

let rec collect_tree_closure source set tree_id =
  let tree_key =
    Store.Stored_object_id.to_hex (Snapshot.Tree.stored_object_id tree_id)
  in
  if Object_set.mem tree_key set then Ok set
  else
    let set = Object_set.add tree_key set in
    let* tree =
      Snapshot.Tree.load source tree_id
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let rec entries set = function
      | [] -> Ok set
      | (_, Snapshot.Tree.Directory child) :: rest ->
          let* set = collect_tree_closure source set child in
          entries set rest
      | (_, Snapshot.Tree.File { content; _ }) :: rest ->
          let* set = collect_content_closure source set content in
          entries set rest
    in
    entries set (Snapshot.Tree.entries tree)

and collect_content_closure source set content_id =
  let stored_id = Snapshot.Content.stored_object_id content_id in
  let content_key = Store.Stored_object_id.to_hex stored_id in
  if Object_set.mem content_key set then Ok set
  else
    let set = Object_set.add content_key set in
    let* object_ =
      Store.get source stored_id
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ = Envelope.Content then
      let* _ =
        Snapshot.Content.load source content_id
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      Ok set
    else if Envelope.object_type object_ = Envelope.File_manifest then
      let* manifest =
        Snapshot.Manifest.load source
          (Snapshot.Manifest.of_stored_object_id stored_id)
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let rec chunks set = function
        | [] -> Ok set
        | (chunk, _) :: rest ->
            let chunk_id = Snapshot.Chunk.stored_object_id chunk in
            let set = add_id set chunk_id in
            let* _ =
              Snapshot.Chunk.load source chunk
              |> Result.map_error (fun error -> Snapshot_error error)
            in
            chunks set rest
      in
      chunks set (Snapshot.Manifest.chunks manifest)
    else
      let* _ =
        Snapshot.Content.load source content_id
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      Ok set

let collect_snapshot_closure source set snapshot =
  let* stored_id = snapshot_object_id snapshot in
  let key = Store.Stored_object_id.to_hex stored_id in
  if Object_set.mem key set then Ok set
  else
    let set = Object_set.add key set in
    let* snapshot =
      Snapshot.Snapshot.load source
        (Snapshot.Snapshot.of_stored_object_id stored_id)
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    collect_tree_closure source set (Snapshot.Snapshot.root snapshot)

let source_objects source signed_revisions =
  let rec collect set = function
    | [] -> Ok set
    | signed :: rest ->
        let revision = Trust.signed_revision_value signed in
        let* set =
          collect_snapshot_closure source set revision.Model.base_snapshot
        in
        let* set =
          collect_snapshot_closure source set revision.Model.result_snapshot
        in
        collect set rest
  in
  let* objects = collect Object_set.empty signed_revisions in
  let parsed =
    Object_set.elements objects
    |> List.map (fun id ->
        Store.Stored_object_id.of_hex id
        |> Result.map_error (fun _ ->
            Invalid_package "invalid collected object ID"))
  in
  List.fold_right
    (fun result accumulated ->
      let* value = result in
      let* values = accumulated in
      Ok (value :: values))
    parsed (Ok [])

let create ~source ~destination ~membership ~revisions =
  if Sys.file_exists destination then Error (Destination_exists destination)
  else
    let* membership =
      Trust.verify_membership
        ~repository:(Trust.repository membership)
        (Trust.certificates membership)
      |> Result.map_error (fun error -> Trust_error error)
    in
    let* () =
      let rec verify = function
        | [] -> Ok ()
        | revision :: rest ->
            let* () =
              Trust.verify_signed_revision membership revision
              |> Result.map_error (fun error -> Trust_error error)
            in
            verify rest
      in
      verify revisions
    in
    let* () = ensure_unique_signed_revisions revisions in
    let* object_ids = source_objects source revisions in
    let* manifest = manifest_bytes ~membership ~revisions ~object_ids in
    let* () = mkdir destination in
    let* () = mkdir (package_path destination objects_name) in
    let* () =
      write_file_exclusive (package_path destination manifest_name) manifest
    in
    let rec copy = function
      | [] -> Ok ()
      | id :: rest ->
          let* object_ =
            Store.get source id
            |> Result.map_error (fun error -> Store_error error)
          in
          let* () =
            write_file_exclusive
              (object_path destination (Store.Stored_object_id.to_hex id))
              (Envelope.encode object_)
          in
          copy rest
    in
    copy object_ids

let create_with_authority ~source ~destination ~authority ~revisions
    ~authorizations ~adoptions =
  if Sys.file_exists destination then Error (Destination_exists destination)
  else
    let* authority =
      Trust.verify_authority
        ~membership:(Trust.authority_membership authority)
        (Trust.authority_epochs authority)
      |> Result.map_error (fun error -> Trust_error error)
    in
    let* () = ensure_unique_signed_revisions revisions in
    let* object_ids = source_objects source revisions in
    let* manifest =
      manifest_bytes_v2 ~authority ~revisions ~authorizations ~adoptions
        ~object_ids
    in
    let* () = mkdir destination in
    let* () = mkdir (package_path destination objects_name) in
    let* () =
      write_file_exclusive (package_path destination manifest_name) manifest
    in
    let rec copy = function
      | [] -> Ok ()
      | id :: rest ->
          let* object_ =
            Store.get source id
            |> Result.map_error (fun error -> Store_error error)
          in
          let* () =
            write_file_exclusive
              (object_path destination (Store.Stored_object_id.to_hex id))
              (Envelope.encode object_)
          in
          copy rest
    in
    copy object_ids

let package_object_bytes package object_ids =
  let directory = package_path package objects_name in
  let* names =
    try Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
    with Sys_error message ->
      Error (Io_error { path = directory; operation = "list"; message })
  in
  let expected =
    object_ids
    |> List.map Store.Stored_object_id.to_hex
    |> List.sort String.compare
  in
  if names <> expected then
    Error (Invalid_package "object files differ from manifest")
  else
    let rec read reversed = function
      | [] -> Ok (List.rev reversed)
      | id :: rest ->
          let id_text = Store.Stored_object_id.to_hex id in
          let* bytes = read_file (object_path package id_text) in
          let* object_ =
            Envelope.decode bytes
            |> Result.map_error (fun error -> Envelope_error error)
          in
          if not (String.equal bytes (Envelope.encode object_)) then
            Error (Invalid_package "noncanonical object bytes")
          else if
            not (Store.Stored_object_id.equal id (Store.id_of_envelope object_))
          then Error (Object_identity_mismatch id_text)
          else read ((id, object_) :: reversed) rest
    in
    read [] object_ids

let rec validate_tree store tree_id =
  let* tree =
    Snapshot.Tree.load store tree_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let rec validate_entries = function
    | [] -> Ok ()
    | (_, Snapshot.Tree.File { content; _ }) :: rest ->
        let* _ =
          Snapshot.Content.load store content
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        validate_entries rest
    | (_, Snapshot.Tree.Directory child) :: rest ->
        let* () = validate_tree store child in
        validate_entries rest
  in
  validate_entries (Snapshot.Tree.entries tree)

let validate_snapshot store snapshot =
  let id =
    Model.Snapshot_id.to_string snapshot
    |> Store.Stored_object_id.of_hex
    |> Result.map_error (fun _ ->
        Invalid_package "revision snapshot ID is invalid")
  in
  let* id = id in
  let* snapshot =
    Snapshot.Snapshot.load store (Snapshot.Snapshot.of_stored_object_id id)
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  validate_tree store (Snapshot.Snapshot.root snapshot)

let verify_closure staging revisions =
  let rec loop = function
    | [] -> Ok ()
    | signed :: rest ->
        let revision = Trust.signed_revision_value signed in
        let* () = validate_snapshot staging revision.Model.base_snapshot in
        let* () = validate_snapshot staging revision.Model.result_snapshot in
        loop rest
  in
  loop revisions

let existing_revision project incoming =
  Model.shared_changes project
  |> List.concat_map (fun change -> change.Model.revisions)
  |> List.find_opt (fun existing ->
      Model.Revision_id.equal existing.Model.revision incoming.Model.revision)

let apply_revisions project verified =
  let pending =
    verified.verified_revisions
    |> List.map Trust.signed_revision_value
    |> List.sort (fun left right ->
        Model.Revision_id.compare left.Model.revision right.Model.revision)
  in
  let rec apply project pending deferred =
    match pending with
    | [] -> Ok project
    | revision :: rest -> (
        match existing_revision project revision with
        | Some existing ->
            if existing = revision then apply project rest 0
            else
              Error (Invalid_package "revision ID conflicts with local history")
        | None -> (
            match Model.receive project revision with
            | Ok project -> apply project rest 0
            | Error error ->
                if
                  error = Model.Received_revision_missing_parent
                  && deferred + 1 < List.length pending
                then apply project (rest @ [ revision ]) (deferred + 1)
                else Error (Model_error error)))
  in
  apply project pending 0

let verify_and_import ~destination ~package ~membership:expected_membership
    ~project =
  let repository = Trust.repository expected_membership in
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  if not (Trust.Repository_id.equal manifest.manifest_repository repository) then
    Error (Invalid_package "package repository does not match destination")
  else if Option.is_some manifest.manifest_authority then
    Error (Invalid_package "authority package requires authority-aware receive")
  else
    let* package_membership =
      Ok manifest.manifest_membership
    in
    let* membership =
      Trust.extend_membership expected_membership
        (Trust.certificates package_membership)
      |> Result.map_error (fun error -> Trust_error error)
    in
    let* () =
      let rec verify = function
        | [] -> Ok ()
        | revision :: rest ->
            let* () =
              Trust.verify_signed_revision membership revision
              |> Result.map_error (fun error -> Trust_error error)
            in
            verify rest
      in
      verify manifest.manifest_revisions
    in
    let* objects = package_object_bytes package manifest.manifest_object_ids in
    with_staging (fun staging_root ->
        let* staging =
          Store.init ~root:staging_root
          |> Result.map_error (fun error -> Store_error error)
        in
        let rec stage = function
          | [] -> Ok ()
          | (_, object_) :: rest ->
              let* _ =
                Store.put staging object_
                |> Result.map_error (fun error -> Store_error error)
              in
              stage rest
        in
        let* () = stage objects in
        let* () = verify_closure staging manifest.manifest_revisions in
        let verified =
          {
            verified_membership = membership;
            verified_authority = None;
            verified_revisions = manifest.manifest_revisions;
            verified_authorizations = [];
            verified_adoptions = [];
          }
        in
        (* Apply the causal model transition while every received object is
           still confined to staging. A missing or incompatible parent must
           not even add otherwise-valid immutable package objects locally. *)
        let* project = apply_revisions project verified in
        let rec import = function
          | [] -> Ok ()
          | (_, object_) :: rest ->
              let* _ =
                Store.put destination object_
                |> Result.map_error (fun error -> Store_error error)
              in
              import rest
        in
        let* () = import objects in
        Ok (verified, project))

let verify_and_import_with_authority ~destination ~package
    ~authority:expected_authority ~project =
  let repository = Trust.repository (Trust.authority_membership expected_authority) in
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  if not (Trust.Repository_id.equal manifest.manifest_repository repository) then
    Error (Invalid_package "package repository does not match destination")
  else
    let* incoming_authority =
      match manifest.manifest_authority with
      | Some authority -> Ok authority
      | None -> Error (Invalid_package "legacy package has no authority closure")
    in
    let* membership =
      Trust.extend_membership (Trust.authority_membership expected_authority)
        (Trust.certificates manifest.manifest_membership)
      |> Result.map_error (fun error -> Trust_error error)
    in
    let* expected_authority =
      Trust.verify_authority ~membership
        (Trust.authority_epochs expected_authority)
      |> Result.map_error (fun error -> Trust_error error)
    in
    let* incoming_authority =
      Trust.verify_authority ~membership
        (Trust.authority_epochs incoming_authority)
      |> Result.map_error (fun error -> Trust_error error)
    in
    let* authority =
      Trust.extend_authority expected_authority
        (Trust.authority_epochs incoming_authority)
      |> Result.map_error (fun error -> Trust_error error)
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
    let rec verify_authorizations = function
      | [] -> Ok ()
      | authorization :: rest ->
          let* () =
            Trust.verify_authorization authority authorization
            |> Result.map_error (fun error -> Trust_error error)
          in
          if
            List.length
              (List.filter
                 (Trust.authorization_matches_signed_revision authorization)
                 manifest.manifest_revisions)
            = 1
          then verify_authorizations rest
          else
            Error
              (Invalid_package
                 "authorization must name exactly one package revision")
    in
    let rec verify_adoptions = function
      | [] -> Ok ()
      | adoption :: rest ->
          let* () =
            Trust.verify_adoption authority adoption
            |> Result.map_error (fun error -> Trust_error error)
          in
          if
            List.length
              (List.filter (Trust.adoption_matches_signed_revision adoption)
                 manifest.manifest_revisions)
            = 1
          then verify_adoptions rest
          else Error (Invalid_package "adoption must bind one package revision")
    in
    let* () = verify_revisions manifest.manifest_revisions in
    let* () = verify_authorizations manifest.manifest_authorizations in
    let* () = verify_adoptions manifest.manifest_adoptions in
    let* objects =
      package_object_bytes package manifest.manifest_object_ids
    in
    with_staging (fun staging_root ->
        let* staging =
          Store.init ~root:staging_root
          |> Result.map_error (fun error -> Store_error error)
        in
        let rec stage = function
          | [] -> Ok ()
          | (_, object_) :: rest ->
              let* _ =
                Store.put staging object_
                |> Result.map_error (fun error -> Store_error error)
              in
              stage rest
        in
        let* () = stage objects in
        let* () = verify_closure staging manifest.manifest_revisions in
        let verified =
          {
            verified_membership = membership;
            verified_authority = Some authority;
            verified_revisions = manifest.manifest_revisions;
            verified_authorizations = manifest.manifest_authorizations;
            verified_adoptions = manifest.manifest_adoptions;
          }
        in
        let* project = apply_revisions project verified in
        let rec import = function
          | [] -> Ok ()
          | (_, object_) :: rest ->
              let* _ =
                Store.put destination object_
                |> Result.map_error (fun error -> Store_error error)
              in
              import rest
        in
        let* () = import objects in
        Ok (verified, project))

let membership verified = verified.verified_membership
let authority verified = verified.verified_authority
let revisions verified = verified.verified_revisions
let authorizations verified = verified.verified_authorizations
let adoptions verified = verified.verified_adoptions

let inspect_authority ~package =
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  match manifest.manifest_authority with
  | Some authority -> Ok authority
  | None -> Error (Invalid_package "legacy package has no authority closure")
