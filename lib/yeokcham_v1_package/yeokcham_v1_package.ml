module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust
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

type artifact_source =
  | Artifact_bytes of (Store.Stored_object_id.t * string) list
  | Artifact_package of {
      artifact_package_path : string;
      artifact_object_ids : Store.Stored_object_id.t list;
    }

type artifact = {
  artifact_manifest_value : string;
  artifact_source_value : artifact_source;
  mutable artifact_cleanup : (unit -> unit) option;
}

type prepared = {
  prepared_verified_value : verified;
  prepared_project_value : Model.project;
  prepared_package_path : string;
  prepared_object_ids : Store.Stored_object_id.t list;
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
      Printf.sprintf "V1 package %s %s: %s" operation path message
  | Destination_exists path -> "V1 package destination already exists: " ^ path
  | Invalid_package detail -> "invalid V1 package: " ^ detail
  | Noncanonical_manifest -> "V1 package manifest is not canonically encoded"
  | Store_error error -> Store.error_to_string error
  | Envelope_error error -> Envelope.decode_error_to_string error
  | Object_identity_mismatch id ->
      "V1 package object bytes do not match identity: " ^ id
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
  let root = Filename.temp_file "yeokcham-v1-package-" "" in
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

let manifest_bytes ~authority ~revisions ~authorizations ~adoptions ~object_ids
    =
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
            (List.filter
               (Trust.adoption_matches_signed_revision adoption)
               revisions)
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
  let certificates =
    Trust.certificates membership |> List.map Trust.encode_certificate
  in
  let epochs =
    Trust.authority_epochs authority |> List.map Trust.encode_epoch
  in
  let revisions =
    revisions
    |> List.sort (fun left right ->
        Model.Revision_id.compare
          (Trust.signed_revision_id left)
          (Trust.signed_revision_id right))
    |> List.map Trust.encode_signed_revision
  in
  let authorizations =
    authorizations
    |> List.map Trust.encode_authorization
    |> List.sort String.compare
  in
  let adoptions =
    adoptions |> List.map Trust.encode_adoption |> List.sort String.compare
  in
  let* () = ensure_unique_bytes "authorizations" authorizations in
  let* () = ensure_unique_bytes "adoptions" adoptions in
  let object_ids =
    object_ids
    |> List.map Store.Stored_object_id.to_hex
    |> List.sort String.compare
  in
  let* repository =
    text (Trust.repository membership |> Trust.Repository_id.to_string)
  in
  let* certificates = encode_bytes certificates in
  let* epochs = encode_bytes epochs in
  let* revisions = encode_bytes revisions in
  let* authorizations = encode_bytes authorizations in
  let* adoptions = encode_bytes adoptions in
  let* object_ids = encode_texts object_ids in
  array
    [
      Encoding.integer 1L;
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
      let _ = (version, repository, certificates, revisions, object_ids) in
      Error
        (Invalid_package
           "authority-less package manifests were retired before V1 release")
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
              Trust.decode_epoch bytes
              |> Result.map_error (fun error -> Trust_error error)
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
      let* authorizations =
        decode_bytes "authorization records" authorizations
      in
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
      if not (Int64.equal version 1L) then
        Error (Invalid_package "unsupported manifest version")
      else
        let* canonical =
          manifest_bytes ~authority ~revisions ~authorizations ~adoptions
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

let manifest_object_ids bytes =
  decode_manifest bytes
  |> Result.map (fun manifest -> manifest.manifest_object_ids)

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

let source_objects ?(extra_snapshots = []) source signed_revisions =
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
  let rec collect_extra objects = function
    | [] -> Ok objects
    | snapshot :: rest ->
        let* objects = collect_snapshot_closure source objects snapshot in
        collect_extra objects rest
  in
  let* objects = collect_extra objects extra_snapshots in
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

let create ~source:_ ~destination:_ ~membership:_ ~revisions:_ =
  Error
    (Invalid_package
       "authority-less package creation was retired before V1 release")

let create_with_authority_internal ~extra_snapshots ~source ~destination
    ~authority ~revisions ~authorizations ~adoptions =
  if Sys.file_exists destination then Error (Destination_exists destination)
  else
    let* authority =
      Trust.verify_authority
        ~membership:(Trust.authority_membership authority)
        (Trust.authority_epochs authority)
      |> Result.map_error (fun error -> Trust_error error)
    in
    let* () = ensure_unique_signed_revisions revisions in
    let* object_ids = source_objects ~extra_snapshots source revisions in
    let* manifest =
      manifest_bytes ~authority ~revisions ~authorizations ~adoptions
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

let create_with_authority ~source ~destination ~authority ~revisions
    ~authorizations ~adoptions =
  create_with_authority_internal ~extra_snapshots:[] ~source ~destination
    ~authority ~revisions ~authorizations ~adoptions

let create_bootstrap_with_authority ~source ~destination ~authority ~revisions
    ~authorizations ~adoptions ~extra_snapshots =
  create_with_authority_internal ~extra_snapshots ~source ~destination
    ~authority ~revisions ~authorizations ~adoptions

let validate_object_files package object_ids =
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
  else Ok ()

let decode_object_bytes id bytes =
  let id_text = Store.Stored_object_id.to_hex id in
  let* object_ =
    Envelope.decode bytes
    |> Result.map_error (fun error -> Envelope_error error)
  in
  if not (String.equal bytes (Envelope.encode object_)) then
    Error (Invalid_package "noncanonical object bytes")
  else if not (Store.Stored_object_id.equal id (Store.id_of_envelope object_))
  then Error (Object_identity_mismatch id_text)
  else Ok object_

let iter_package_objects ~package ~object_ids ~f =
  let* () = validate_object_files package object_ids in
  let rec loop = function
    | [] -> Ok ()
    | id :: rest ->
        let* bytes =
          Store.read_file_bounded
            ~path:(object_path package (Store.Stored_object_id.to_hex id))
            ~max_bytes:(128 * 1024 * 1024)
          |> Result.map_error (fun error -> Store_error error)
        in
        let* object_ = decode_object_bytes id bytes in
        let* () = f id bytes object_ in
        loop rest
  in
  loop object_ids

let iter_artifact_objects_internal artifact ~f =
  match artifact.artifact_source_value with
  | Artifact_package { artifact_package_path; artifact_object_ids } ->
      iter_package_objects ~package:artifact_package_path
        ~object_ids:artifact_object_ids ~f
  | Artifact_bytes objects ->
      let rec loop = function
        | [] -> Ok ()
        | (id, bytes) :: rest ->
            let* object_ = decode_object_bytes id bytes in
            let* () = f id bytes object_ in
            loop rest
      in
      loop objects

let read_artifact ~package =
  let* manifest_bytes = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest_bytes in
  let* () = validate_object_files package manifest.manifest_object_ids in
  Ok
    {
      artifact_manifest_value = manifest_bytes;
      artifact_source_value =
        Artifact_package
          {
            artifact_package_path = package;
            artifact_object_ids = manifest.manifest_object_ids;
          };
      artifact_cleanup = None;
    }

let artifact_manifest artifact = artifact.artifact_manifest_value

let dispose_artifact artifact =
  match artifact.artifact_cleanup with
  | None -> ()
  | Some cleanup ->
      artifact.artifact_cleanup <- None;
      cleanup ()

let claim_artifact artifact ~cleanup =
  let artifact = { artifact with artifact_cleanup = Some cleanup } in
  Gc.finalise dispose_artifact artifact;
  artifact

let iter_artifact_objects artifact ~f =
  iter_artifact_objects_internal artifact ~f:(fun id bytes _ -> f id bytes)

let find_artifact_object artifact ~object_id =
  match artifact.artifact_source_value with
  | Artifact_bytes objects -> (
      match
        List.find_opt
          (fun (id, _) -> Store.Stored_object_id.equal id object_id)
          objects
      with
      | None -> Ok None
      | Some (id, bytes) ->
          let* _ = decode_object_bytes id bytes in
          Ok (Some bytes))
  | Artifact_package { artifact_package_path; artifact_object_ids } ->
      if
        not
          (List.exists
             (Store.Stored_object_id.equal object_id)
             artifact_object_ids)
      then Ok None
      else
        let* bytes =
          Store.read_file_bounded
            ~path:
              (object_path artifact_package_path
                 (Store.Stored_object_id.to_hex object_id))
            ~max_bytes:(128 * 1024 * 1024)
          |> Result.map_error (fun error -> Store_error error)
        in
        let* _ = decode_object_bytes object_id bytes in
        Ok (Some bytes)

let artifact_of_bytes ~manifest ~objects =
  let* decoded_manifest = decode_manifest manifest in
  let expected =
    List.map Store.Stored_object_id.to_hex decoded_manifest.manifest_object_ids
    |> List.sort String.compare
  in
  let actual =
    List.map (fun (id, _) -> Store.Stored_object_id.to_hex id) objects
    |> List.sort String.compare
  in
  if expected <> actual then
    Error (Invalid_package "artifact object files differ from manifest")
  else
    let rec verify = function
      | [] -> Ok ()
      | (id, bytes) :: rest ->
          let* object_ =
            Envelope.decode bytes
            |> Result.map_error (fun error -> Envelope_error error)
          in
          if not (String.equal bytes (Envelope.encode object_)) then
            Error (Invalid_package "artifact object bytes are not canonical")
          else if
            not (Store.Stored_object_id.equal id (Store.id_of_envelope object_))
          then
            Error (Object_identity_mismatch (Store.Stored_object_id.to_hex id))
          else verify rest
    in
    let* () = verify objects in
    Ok
      {
        artifact_manifest_value = manifest;
        artifact_source_value =
          Artifact_bytes
            (List.sort
               (fun (left, _) (right, _) ->
                 Store.Stored_object_id.compare left right)
               objects);
        artifact_cleanup = None;
      }

let materialize_artifact ~destination artifact =
  if Sys.file_exists destination then Error (Destination_exists destination)
  else
    let* manifest = decode_manifest artifact.artifact_manifest_value in
    let* () = mkdir destination in
    let* () = mkdir (package_path destination objects_name) in
    let* () =
      write_file_exclusive
        (package_path destination manifest_name)
        artifact.artifact_manifest_value
    in
    let* () =
      iter_artifact_objects artifact ~f:(fun id bytes ->
          write_file_exclusive
            (object_path destination (Store.Stored_object_id.to_hex id))
            bytes)
    in
    validate_object_files destination manifest.manifest_object_ids

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
  (Model.shared_changes project
  |> List.concat_map (fun change -> change.Model.revisions))
  @ (Model.resolutions project
    |> List.map (fun resolution -> resolution.Model.replacement_revision))
  |> List.find_opt (fun existing ->
      Model.Revision_id.equal existing.Model.revision incoming.Model.revision)

let existing_revision_has_signed_purpose project signed =
  let revision = Trust.signed_revision_value signed in
  match Trust.signed_revision_resolution signed with
  | None ->
      Model.shared_changes project
      |> List.concat_map (fun change -> change.Model.revisions)
      |> List.exists (fun existing -> existing = revision)
  | Some decision ->
      Model.resolutions project
      |> List.exists (fun resolution ->
          Model.Decision_id.equal resolution.Model.resolved_decision decision
          && resolution.Model.replacement_revision = revision)

let apply_revisions project verified =
  let pending =
    verified.verified_revisions
    |> List.sort (fun left right ->
        Model.Revision_id.compare
          (Trust.signed_revision_id left)
          (Trust.signed_revision_id right))
  in
  let rec apply project pending deferred =
    match pending with
    | [] -> Ok project
    | signed :: rest -> (
        let revision = Trust.signed_revision_value signed in
        match existing_revision project revision with
        | Some existing ->
            if
              existing = revision
              && existing_revision_has_signed_purpose project signed
            then apply project rest 0
            else
              Error (Invalid_package "revision ID conflicts with local history")
        | None -> (
            let transition =
              match Trust.signed_revision_resolution signed with
              | None -> Model.receive project revision
              | Some decision ->
                  Model.resolve project ~decision ~replacement:revision
            in
            match transition with
            | Ok project -> apply project rest 0
            | Error error ->
                if
                  (error = Model.Received_revision_missing_parent
                  || error = Model.Unknown_decision)
                  && deferred + 1 < List.length pending
                then apply project (rest @ [ signed ]) (deferred + 1)
                else Error (Model_error error)))
  in
  apply project pending 0

let verify_and_import ~destination:_ ~package:_ ~membership:_ ~project:_ =
  Error
    (Invalid_package
       "authority-less package receive was retired before V1 release")

let inspect_with_authority ~package ~authority:expected_authority =
  let repository =
    Trust.repository (Trust.authority_membership expected_authority)
  in
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  if not (Trust.Repository_id.equal manifest.manifest_repository repository)
  then Error (Invalid_package "package repository does not match destination")
  else
    let* incoming_authority =
      match manifest.manifest_authority with
      | Some authority -> Ok authority
      | None ->
          Error (Invalid_package "legacy package has no authority closure")
    in
    let* membership =
      Trust.extend_membership
        (Trust.authority_membership expected_authority)
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
              (List.filter
                 (Trust.adoption_matches_signed_revision adoption)
                 manifest.manifest_revisions)
            = 1
          then verify_adoptions rest
          else Error (Invalid_package "adoption must bind one package revision")
    in
    let* () = verify_revisions manifest.manifest_revisions in
    let* () = verify_authorizations manifest.manifest_authorizations in
    let* () = verify_adoptions manifest.manifest_adoptions in
    Ok
      {
        verified_membership = membership;
        verified_authority = Some authority;
        verified_revisions = manifest.manifest_revisions;
        verified_authorizations = manifest.manifest_authorizations;
        verified_adoptions = manifest.manifest_adoptions;
      }

let validate_with_authority ~package ~authority:expected_authority =
  let* inspected =
    inspect_with_authority ~package ~authority:expected_authority
  in
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  with_staging (fun staging_root ->
      let* staging =
        Store.init ~root:staging_root
        |> Result.map_error (fun error -> Store_error error)
      in
      let* () =
        iter_package_objects ~package ~object_ids:manifest.manifest_object_ids
          ~f:(fun _ _ object_ ->
            Store.put staging object_
            |> Result.map_error (fun error -> Store_error error)
            |> Result.map (fun _ -> ()))
      in
      let* () = verify_closure staging inspected.verified_revisions in
      Ok inspected)

let validate_snapshot_closure ~package ~snapshots =
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  with_staging (fun staging_root ->
      let* staging =
        Store.init ~root:staging_root
        |> Result.map_error (fun error -> Store_error error)
      in
      let* () =
        iter_package_objects ~package ~object_ids:manifest.manifest_object_ids
          ~f:(fun _ _ object_ ->
            Store.put staging object_
            |> Result.map_error (fun error -> Store_error error)
            |> Result.map (fun _ -> ()))
      in
      let rec validate = function
        | [] -> Ok ()
        | snapshot :: rest ->
            let* () = validate_snapshot staging snapshot in
            validate rest
      in
      validate snapshots)

let prepare_with_authority ~package ~authority:expected_authority
    ~known_adoptions ~project =
  let* inspected =
    inspect_with_authority ~package ~authority:expected_authority
  in
  let* authority =
    match inspected.verified_authority with
    | Some authority -> Ok authority
    | None ->
        Error (Invalid_package "authority inspection returned no authority")
  in
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  let rec verify_known_adoptions = function
    | [] -> Ok ()
    | adoption :: rest ->
        let* () =
          Trust.verify_adoption authority adoption
          |> Result.map_error (fun error -> Trust_error error)
        in
        verify_known_adoptions rest
  in
  let* () = verify_known_adoptions known_adoptions in
  let rec require_adoption_for_late_revisions = function
    | [] -> Ok ()
    | signed :: rest ->
        let revision = Trust.signed_revision_value signed in
        if Option.is_some (existing_revision project revision) then
          require_adoption_for_late_revisions rest
        else
          let* requires_review =
            Trust.requires_late_review authority signed
            |> Result.map_error (fun error -> Trust_error error)
          in
          if not requires_review then require_adoption_for_late_revisions rest
          else
            let adoptions =
              List.filter
                (fun adoption ->
                  Trust.adoption_matches_signed_revision adoption signed
                  && Trust.authority_epoch_is_head authority
                       (Trust.adoption_epoch adoption))
                (known_adoptions @ manifest.manifest_adoptions)
            in
            if List.length adoptions = 1 then
              require_adoption_for_late_revisions rest
            else
              Error
                (Invalid_package
                   "late revision from a revoked device requires one \
                    current-head adoption")
  in
  let* () = require_adoption_for_late_revisions manifest.manifest_revisions in
  with_staging (fun staging_root ->
      let* staging =
        Store.init ~root:staging_root
        |> Result.map_error (fun error -> Store_error error)
      in
      let* () =
        iter_package_objects ~package ~object_ids:manifest.manifest_object_ids
          ~f:(fun _ _ object_ ->
            Store.put staging object_
            |> Result.map_error (fun error -> Store_error error)
            |> Result.map (fun _ -> ()))
      in
      let* () = verify_closure staging manifest.manifest_revisions in
      let* project = apply_revisions project inspected in
      Ok
        {
          prepared_verified_value = inspected;
          prepared_project_value = project;
          prepared_package_path = package;
          prepared_object_ids = manifest.manifest_object_ids;
        })

let import_prepared ~destination prepared =
  let* () =
    iter_package_objects ~package:prepared.prepared_package_path
      ~object_ids:prepared.prepared_object_ids ~f:(fun _ _ object_ ->
        Store.put destination object_
        |> Result.map_error (fun error -> Store_error error)
        |> Result.map (fun _ -> ()))
  in
  Ok (prepared.prepared_verified_value, prepared.prepared_project_value)

let verify_and_import_with_authority ~destination ~package
    ~authority:expected_authority ~known_adoptions ~project =
  let* prepared =
    prepare_with_authority ~package ~authority:expected_authority
      ~known_adoptions ~project
  in
  import_prepared ~destination prepared

let membership verified = verified.verified_membership
let authority verified = verified.verified_authority
let revisions verified = verified.verified_revisions
let authorizations verified = verified.verified_authorizations
let adoptions verified = verified.verified_adoptions
let prepared_verified prepared = prepared.prepared_verified_value
let prepared_project prepared = prepared.prepared_project_value

let inspect_authority ~package =
  let* manifest = read_file (package_path package manifest_name) in
  let* manifest = decode_manifest manifest in
  match manifest.manifest_authority with
  | Some authority -> Ok authority
  | None -> Error (Invalid_package "legacy package has no authority closure")

module Core = struct
  module M = Model.Core
  module R = Yeokcham_v1_record.Core
  module Pages = Yeokcham_v1_pages
  module Composition = Yeokcham_v1_composition
  module Id = Store.Stored_object_id

  [@@@warning "-42"]

  let model result =
    Result.map_error (fun e -> Invalid_package (M.error_to_string e)) result

  let record result =
    Result.map_error (fun e -> Invalid_package (R.error_to_string e)) result

  let pages result =
    Result.map_error (fun e -> Invalid_package (Pages.error_to_string e)) result

  let graph result =
    Result.map_error
      (fun e -> Invalid_package (Composition.Graph.error_to_string e))
      result

  let trust result = Result.map_error (fun e -> Trust_error e) result
  let stored result = Result.map_error (fun e -> Store_error e) result
  let schema_version = 2L
  let max_manifest_bytes = 8 * 1024 * 1024
  let max_object_bytes = 128 * 1024 * 1024

  type manifest = {
    repository : M.Repository_id.t;
    selected_branch : M.Branch_id.t;
    record_root : Id.t;
    authority_root : Id.t;
    title_root : Id.t;
    inventory_root : Id.t;
  }

  type prepared = {
    control : manifest;
    public_artifact : artifact;
    public_authority : Trust.authority;
    public_pool : M.pool;
    public_records : (M.Record_id.t * Id.t) list;
    public_titles : (M.Record_id.t * string) list;
  }

  let traverse f values =
    List.fold_left
      (fun result value ->
        let* reversed = result in
        let* value = f value in
        Ok (value :: reversed))
      (Ok []) values
    |> Result.map List.rev

  let raw_id bytes =
    Id.of_raw_bytes bytes
    |> Option.to_result ~none:(Invalid_package "invalid Core object reference")

  let namespace manifest role =
    "core-public-" ^ role ^ "-v1\000"
    ^ M.Repository_id.to_raw manifest.repository

  let encode_manifest manifest =
    array
      [
        Encoding.integer schema_version;
        Encoding.bytes (M.Repository_id.to_raw manifest.repository);
        Encoding.bytes (M.Branch_id.to_raw manifest.selected_branch);
        Encoding.bytes (Id.to_raw_bytes manifest.record_root);
        Encoding.bytes (Id.to_raw_bytes manifest.authority_root);
        Encoding.bytes (Id.to_raw_bytes manifest.title_root);
        Encoding.bytes (Id.to_raw_bytes manifest.inventory_root);
      ]
    |> Result.map Encoding.encode

  let[@warning "-4"] decode_manifest ~repository bytes =
    if String.length bytes > max_manifest_bytes then
      Error (Invalid_package "Core manifest exceeds 8 MiB")
    else
      let* value =
        Encoding.decode bytes
        |> Result.map_error (fun e ->
            Invalid_package (Encoding.decode_error_to_string e))
      in
      match value with
      | Encoding.Array
          [
            Encoding.Integer 2L;
            Encoding.Bytes scope;
            Encoding.Bytes branch;
            Encoding.Bytes records;
            Encoding.Bytes authority;
            Encoding.Bytes titles;
            Encoding.Bytes inventory;
          ] ->
          let* scope = M.Repository_id.of_raw scope |> model in
          let* selected_branch = M.Branch_id.of_raw branch |> model in
          let* record_root = raw_id records in
          let* authority_root = raw_id authority in
          let* title_root = raw_id titles in
          let* inventory_root = raw_id inventory in
          let manifest =
            {
              repository = scope;
              selected_branch;
              record_root;
              authority_root;
              title_root;
              inventory_root;
            }
          in
          let* canonical = encode_manifest manifest in
          if
            (not (M.Repository_id.equal repository scope)) || canonical <> bytes
          then
            Error (Invalid_package "Core manifest scope/canonicality mismatch")
          else Ok manifest
      | _ -> Error (Invalid_package "unsupported Core package manifest schema")

  let manifest_repository manifest = manifest.repository
  let manifest_branch manifest = manifest.selected_branch

  let metadata_roots manifest =
    [
      (namespace manifest "records", manifest.record_root);
      (namespace manifest "authority", manifest.authority_root);
      (namespace manifest "titles", manifest.title_root);
      (namespace manifest "objects", manifest.inventory_root);
    ]

  let read_bounded ~limit path =
    Store.read_file_bounded ~path ~max_bytes:limit |> stored

  let read_object package ~limit id =
    read_bounded ~limit (object_path package (Id.to_hex id))

  let fetch_metadata store package manifest =
    let visited = Hashtbl.create 32 in
    let rec fetch namespace depth id =
      if depth > 32 then
        Error (Invalid_package "Core metadata traversal exceeds depth bound")
      else if Hashtbl.mem visited (namespace, id) then Ok ()
      else
        let* bytes = read_object package ~limit:Pages.max_page_bytes id in
        let* references =
          Pages.page_references ~namespace ~expected:id bytes |> pages
        in
        let* envelope = decode_object_bytes id bytes in
        let* _ = Store.put store envelope |> stored in
        Hashtbl.add visited (namespace, id) ();
        let* _ = traverse (fetch namespace (depth + 1)) references in
        Ok ()
    in
    let* _ =
      traverse
        (fun (namespace, id) -> fetch namespace 0 id)
        (metadata_roots manifest)
    in
    Ok ()

  let load_rows store manifest role root =
    Pages.load store ~namespace:(namespace manifest role) root |> pages

  let inventory store manifest =
    let* rows = load_rows store manifest "objects" manifest.inventory_root in
    traverse
      (fun (raw, value) ->
        let* id = raw_id raw in
        let* encoded =
          Encoding.decode value
          |> Result.map_error (fun e ->
              Invalid_package (Encoding.decode_error_to_string e))
        in
        let* size = integer_field "Core object size" encoded in
        if
          size < Int64.of_int Envelope.header_size
          || size > Int64.of_int max_object_bytes
        then Error (Invalid_package "Core object size is out of bounds")
        else Ok (id, Int64.to_int size))
      rows

  let metadata_ids store manifest ~inventory =
    let roots =
      metadata_roots manifest
      |> List.filter (fun (scope, _) ->
          inventory || scope <> namespace manifest "objects")
    in
    let* lists =
      traverse
        (fun (scope, id) -> Pages.closure store ~namespace:scope id |> pages)
        roots
    in
    Ok (List.concat lists |> List.sort_uniq Id.compare)

  let record_rows store manifest =
    let* rows = load_rows store manifest "records" manifest.record_root in
    traverse
      (fun (raw, value) ->
        let* id = M.Record_id.of_raw raw |> model in
        let* obj = raw_id value in
        Ok (id, obj))
      rows

  let[@warning "-4"] verify_records store authority repository records =
    let* records =
      traverse
        (fun (id, obj) ->
          let* envelope =
            Store.get ~max_bytes:R.max_record_bytes store obj |> stored
          in
          let* signed =
            R.decode ~repository (Envelope.encode envelope) |> record
          in
          let* actual = R.id signed |> record in
          let* () =
            Trust.Core.verify authority signed
            |> Result.map_error (fun e ->
                Invalid_package (Trust.Core.error_to_string e))
          in
          if not (M.Record_id.equal id actual) then
            Error (Invalid_package "Core logical record identity mismatch")
          else Ok (id, R.body signed))
        records
    in
    let rec retain pool pending =
      match pending with
      | [] -> Ok pool
      | _ ->
          let* pool, remaining =
            List.fold_left
              (fun result (id, body) ->
                let* pool, remaining = result in
                match M.retain pool ~id body with
                | Ok (pool, _) -> Ok (pool, remaining)
                | Error (M.Missing_reference _) ->
                    Ok (pool, (id, body) :: remaining)
                | Error e -> Error (Invalid_package (M.error_to_string e)))
              (Ok (pool, []))
              pending
          in
          if List.length remaining = List.length pending then
            Error (Invalid_package "Core package has missing causal references")
          else retain pool remaining
    in
    let* pool = retain (M.empty_pool ~repository) records in
    let* () = Composition.Graph.validate store pool |> graph in
    Ok pool

  let authority_key tag id =
    let* digest = M.Digest.of_hex id |> model in
    Ok (String.make 1 tag ^ M.Digest.to_raw digest)

  let authority_rows authority =
    let* certificates =
      traverse
        (fun certificate ->
          let* key = authority_key '\000' (Trust.certificate_id certificate) in
          Ok (key, Trust.encode_certificate certificate))
        (Trust.certificates (Trust.authority_membership authority))
    in
    let* epochs =
      traverse
        (fun epoch ->
          let* key = authority_key '\001' (Trust.epoch_id epoch) in
          Ok (key, Trust.encode_epoch epoch))
        (Trust.authority_epochs authority)
    in
    Ok (certificates @ epochs)

  let load_authority store manifest known_authority =
    let* rows = load_rows store manifest "authority" manifest.authority_root in
    let* certificates, epochs =
      List.fold_left
        (fun result (key, bytes) ->
          let* certificates, epochs = result in
          if String.length key <> 33 then
            Error (Invalid_package "invalid Core authority key")
          else if key.[0] = '\000' then
            let* certificate = Trust.decode_certificate bytes |> trust in
            let* expected =
              authority_key '\000' (Trust.certificate_id certificate)
            in
            if key <> expected then
              Error (Invalid_package "Core certificate identity mismatch")
            else Ok (certificate :: certificates, epochs)
          else if key.[0] = '\001' then
            let* epoch = Trust.decode_epoch bytes |> trust in
            let* expected = authority_key '\001' (Trust.epoch_id epoch) in
            if key <> expected then
              Error (Invalid_package "Core epoch identity mismatch")
            else Ok (certificates, epoch :: epochs)
          else Error (Invalid_package "unsupported Core authority entry"))
        (Ok ([], []))
        rows
    in
    let* repository =
      Trust.Repository_id.of_string (M.Repository_id.to_hex manifest.repository)
      |> Result.map_error (fun s -> Invalid_package s)
    in
    let* incoming_membership =
      Trust.verify_membership ~repository certificates |> trust
    in
    let* incoming =
      Trust.verify_authority ~membership:incoming_membership epochs |> trust
    in
    match known_authority with
    | None -> Ok incoming
    | Some known ->
        let* membership =
          Trust.extend_membership
            (Trust.authority_membership known)
            certificates
          |> trust
        in
        let epochs =
          Trust.authority_epochs known @ Trust.authority_epochs incoming
          |> List.sort_uniq (fun a b ->
              String.compare (Trust.epoch_id a) (Trust.epoch_id b))
        in
        Trust.verify_authority ~membership epochs |> trust

  let[@warning "-4"] title_rows pool titles =
    traverse
      (fun (id, title) ->
        let* _ = text title in
        if
          title = ""
          || String.length title > M.max_name_bytes
          || String.contains title '\000'
        then
          Error
            (Invalid_package
               "Core public title must contain 1 through 1024 UTF-8 bytes \
                without NUL")
        else
          match M.find pool id with
          | Some { M.payload = M.Shared_revision _; _ } ->
              Ok (M.Record_id.to_raw id, title)
          | _ ->
              Error
                (Invalid_package
                   "Core public title does not name a shared revision"))
      titles

  let load_titles store manifest pool =
    let* rows = load_rows store manifest "titles" manifest.title_root in
    let* titles =
      traverse
        (fun (raw, title) ->
          let* id = M.Record_id.of_raw raw |> model in
          Ok (id, title))
        rows
    in
    let* _ = title_rows pool titles in
    Ok titles

  let source_objects source pool records =
    let object_snapshot id =
      Model.Snapshot_id.of_string (M.Object_id.to_hex id)
      |> Result.map_error (fun e -> Model_error e)
    in
    List.fold_left
      (fun result (id, body) ->
        let* objects = result in
        let* record =
          List.assoc_opt id records
          |> Option.to_result
               ~none:(Invalid_package "Core public record map is incomplete")
        in
        let objects = add_id objects record in
        let snapshots, scope =
          match body.M.payload with
          | M.Shared_revision revision ->
              ( [ revision.M.base_snapshot; revision.M.result_snapshot ],
                Some revision.M.edit_scope_root )
          | M.Accepted_version version -> ([ version.M.result_snapshot ], None)
          | M.Branch_event _ -> ([], None)
        in
        let* objects =
          List.fold_left
            (fun result id ->
              let* objects = result in
              let* snapshot = object_snapshot id in
              collect_snapshot_closure source objects snapshot)
            (Ok objects) snapshots
        in
        match scope with
        | None -> Ok objects
        | Some id ->
            let* ids =
              Composition.Scope.closure source id
              |> Result.map_error (fun e ->
                  Invalid_package (Composition.error_to_string e))
            in
            Ok (List.fold_left add_id objects ids))
      (Ok Object_set.empty) (M.records pool)

  let has_branch pool branch =
    List.exists
      (fun row -> M.Branch_id.equal row.M.branch_id branch)
      (M.branch_states pool)

  let create ~source ~destination ~authority ~records ~selected_branch ~titles =
    let* repository =
      M.Repository_id.of_hex
        (Trust.repository (Trust.authority_membership authority)
        |> Trust.Repository_id.to_string)
      |> model
    in
    let records =
      List.sort (fun (a, _) (b, _) -> M.Record_id.compare a b) records
    in
    if
      List.length records
      <> List.length
           (List.sort_uniq
              (fun (a, _) (b, _) -> M.Record_id.compare a b)
              records)
    then Error (Invalid_package "duplicate Core record map entry")
    else
      let* pool = verify_records source authority repository records in
      let* () =
        if has_branch pool selected_branch then Ok ()
        else Error (Invalid_package "selected public branch is unknown")
      in
      let placeholder = Option.get (Id.of_raw_bytes (String.make 32 '\000')) in
      let control =
        {
          repository;
          selected_branch;
          record_root = placeholder;
          authority_root = placeholder;
          title_root = placeholder;
          inventory_root = placeholder;
        }
      in
      let* record_root =
        Pages.store source
          ~namespace:(namespace control "records")
          (List.map
             (fun (id, obj) -> (M.Record_id.to_raw id, Id.to_raw_bytes obj))
             records)
        |> pages
      in
      let* authority_values = authority_rows authority in
      let* authority_root =
        Pages.store source
          ~namespace:(namespace control "authority")
          authority_values
        |> pages
      in
      let* title_values = title_rows pool titles in
      let* title_root =
        Pages.store source ~namespace:(namespace control "titles") title_values
        |> pages
      in
      let control = { control with record_root; authority_root; title_root } in
      let* objects = source_objects source pool records in
      let* metadata = metadata_ids source control ~inventory:false in
      let objects = List.fold_left add_id objects metadata in
      let* rows =
        traverse
          (fun hex ->
            let* id =
              Id.of_hex hex
              |> Result.map_error (fun _ ->
                  Invalid_package "invalid public object identity")
            in
            let* bytes =
              read_bounded ~limit:max_object_bytes (Store.object_path source id)
            in
            let* _ = decode_object_bytes id bytes in
            Ok
              ( Id.to_raw_bytes id,
                Encoding.encode
                  (Encoding.integer (Int64.of_int (String.length bytes))) ))
          (Object_set.elements objects)
      in
      let* inventory_root =
        Pages.store source ~namespace:(namespace control "objects") rows
        |> pages
      in
      let control = { control with inventory_root } in
      let* manifest = encode_manifest control in
      let* metadata = metadata_ids source control ~inventory:true in
      let objects =
        List.fold_left add_id objects metadata |> Object_set.elements
      in
      let* ids =
        traverse
          (fun hex ->
            Id.of_hex hex
            |> Result.map_error (fun _ ->
                Invalid_package "invalid public object identity"))
          objects
      in
      if Sys.file_exists destination then Error (Destination_exists destination)
      else
        let* () = mkdir destination in
        let* () = mkdir (package_path destination objects_name) in
        let* () =
          write_file_exclusive (package_path destination manifest_name) manifest
        in
        let* _ =
          traverse
            (fun id ->
              let* bytes =
                read_bounded ~limit:max_object_bytes
                  (Store.object_path source id)
              in
              let* _ = decode_object_bytes id bytes in
              write_file_exclusive
                (object_path destination (Id.to_hex id))
                bytes)
            ids
        in
        Ok
          {
            artifact_manifest_value = manifest;
            artifact_source_value =
              Artifact_package
                {
                  artifact_package_path = destination;
                  artifact_object_ids = ids;
                };
            artifact_cleanup = None;
          }

  let prepare ~package ~repository ~known_authority =
    let* bytes =
      read_bounded ~limit:max_manifest_bytes
        (package_path package manifest_name)
    in
    let* control = decode_manifest ~repository bytes in
    with_staging (fun root ->
        let* store = Store.init ~root |> stored in
        let* () = fetch_metadata store package control in
        let* inventory_values = inventory store control in
        let* metadata = metadata_ids store control ~inventory:true in
        let object_ids =
          List.map fst inventory_values @ metadata |> List.sort_uniq Id.compare
        in
        let* () = validate_object_files package object_ids in
        let* _ =
          traverse
            (fun (id, size) ->
              let* bytes = read_object package ~limit:size id in
              if String.length bytes <> size then
                Error (Invalid_package "Core inventory length mismatch")
              else
                let* envelope = decode_object_bytes id bytes in
                Store.put store envelope |> stored |> Result.map (fun _ -> ()))
            inventory_values
        in
        let* authority = load_authority store control known_authority in
        let* records = record_rows store control in
        let* pool = verify_records store authority repository records in
        let* () =
          if has_branch pool control.selected_branch then Ok ()
          else Error (Invalid_package "selected public branch is unknown")
        in
        let* titles = load_titles store control pool in
        let* expected = source_objects store pool records in
        let* described_metadata = metadata_ids store control ~inventory:false in
        let expected = List.fold_left add_id expected described_metadata in
        let actual =
          List.fold_left
            (fun set (id, _) -> add_id set id)
            Object_set.empty inventory_values
        in
        if not (Object_set.equal expected actual) then
          Error
            (Invalid_package
               "Core inventory differs from the exact public dependency closure")
        else
          let artifact =
            {
              artifact_manifest_value = bytes;
              artifact_source_value =
                Artifact_package
                  {
                    artifact_package_path = package;
                    artifact_object_ids = object_ids;
                  };
              artifact_cleanup = None;
            }
          in
          Ok
            {
              control;
              public_artifact = artifact;
              public_authority = authority;
              public_pool = pool;
              public_records = records;
              public_titles = titles;
            })

  let prepared_artifact prepared = prepared.public_artifact
  let prepared_authority prepared = prepared.public_authority
  let prepared_pool prepared = prepared.public_pool
  let prepared_records prepared = prepared.public_records
  let prepared_titles prepared = prepared.public_titles
  let prepared_branch prepared = prepared.control.selected_branch

  let import_prepared ~destination prepared =
    iter_artifact_objects prepared.public_artifact ~f:(fun _ bytes ->
        let* envelope =
          Envelope.decode bytes |> Result.map_error (fun e -> Envelope_error e)
        in
        Store.put destination envelope |> stored |> Result.map (fun _ -> ()))
end
