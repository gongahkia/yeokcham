module Core = Yeokcham_v1_model.Core
module Store = Yeokcham_v1_store
module Local = Store.Local
module Trust = Yeokcham_v1_trust
module Package = Yeokcham_v1_package
module Transport = Yeokcham_v1_transport
module Outbox = Transport.Core_outbox

[@@@warning "-42"]

type error =
  | Package_error of Package.error
  | Store_error of Store.error
  | Transport_error of Transport.error
  | Signer_required
  | Metadata of string

let error_to_string = function
  | Package_error error -> Package.error_to_string error
  | Store_error error -> Store.error_to_string error
  | Transport_error error -> Transport.error_to_string error
  | Signer_required -> "a new Core courier requires the enrolled local signer; a frozen pending batch can resume without it"
  | Metadata message -> message

let ( let* ) = Result.bind
let store result = Result.map_error (fun error -> Store_error error) result

let transport result =
  Result.map_error (fun error -> Transport_error error) result

let package result = Result.map_error (fun error -> Package_error error) result
let metadata result = Result.map_error (fun message -> Metadata message) result

type outbound = {
  batch : Outbox.batch;
  artifact : Package.artifact;
  reused : bool;
}

type boundary =
  | Freeze_before
  | Freeze_after
  | Acknowledge_before
  | Acknowledge_after

let context loaded =
  let* local =
    loaded.Store.local
    |> Option.to_result
         ~none:
           (Metadata "Core outbound requires authenticated local branch state")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result
         ~none:(Metadata "Core outbound requires verified collaboration")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result
         ~none:(Metadata "Core outbound requires verified authority")
  in
  Ok (local, collaboration, authority)

let with_writer root action =
  let path =
    Filename.concat (Filename.concat root ".yeokcham") "local-worktree.lock"
  in
  try
    let fd =
      Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600
    in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.lockf fd Unix.F_TLOCK 0;
        Fun.protect ~finally:(fun () -> Unix.lockf fd Unix.F_ULOCK 0) action)
  with Unix.Unix_error (error, _, _) ->
    Error
      (Metadata ("Core outbound writer unavailable: " ^ Unix.error_message error))

let local_device collaboration authority =
  Trust.certificates (Trust.authority_membership authority)
  |> List.find_opt (fun cert ->
      Trust.certificate_id cert = Store.local_certificate collaboration)
  |> Option.to_result
       ~none:(Metadata "Core courier local certificate is unavailable")
  |> Result.map Trust.certificate_subject

let save ~observe ~before ~after repository loaded local collaboration authority
    state =
  let* collaboration =
    Store.collaboration_with_authority_transport ~transport:state ~authority
      ~revisions:(Store.signed_revisions collaboration)
      ~local_certificate:(Store.local_certificate collaboration)
      ~authorizations:(Store.authorizations collaboration)
      ~adoptions:(Store.adoptions collaboration)
    |> store
  in
  Store.For_test.save_collaborative
    ~before_publish:(fun () -> observe before)
    ~after_publish:(fun () -> observe after)
    ~history:loaded.Store.history ~local repository ~expected:loaded.Store.head
    ~project:loaded.Store.project ~collaboration
  |> store

let remove_artifact path =
  let objects = Filename.concat path "objects" in
  (try
     Array.iter
       (fun name -> Unix.unlink (Filename.concat objects name))
       (Sys.readdir objects);
     Unix.rmdir objects
   with Unix.Unix_error _ | Sys_error _ -> ());
  (try Unix.unlink (Filename.concat path "manifest.cbor")
   with Unix.Unix_error _ -> ());
  try Unix.rmdir path with Unix.Unix_error _ -> ()

let temporary_artifact ~root create =
  try
    let path =
      Filename.temp_file
        ~temp_dir:(Filename.concat root ".yeokcham")
        "core-outbound-" ".tmp"
    in
    Unix.unlink path;
    match create path with
    | Ok artifact ->
        Ok
          (Package.claim_artifact artifact ~cleanup:(fun () ->
               remove_artifact path))
    | Error error ->
        remove_artifact path;
        Error error
  with Unix.Unix_error (error, operation, path) ->
    Error
      (Metadata
         (Printf.sprintf "Core outbound staging %s %s: %s" operation path
            (Unix.error_message error)))

let pending state ~remote ~endpoint =
  Outbox.find state ~remote ~endpoint |> transport

let prepare_with ~observe ~root ~remote ~endpoint ~signing_capability =
  let* repository = Store.open_repository ~root |> store in
  let* initial = with_writer root (fun () -> Store.load repository |> store) in
  let* local, collaboration, authority = context initial in
  let state = Store.transport collaboration in
  let* existing = pending state ~remote ~endpoint in
  let source = Store.underlying_store repository in
  let scope = Core.pool_repository (Local.pool local) in
  match existing with
  | Some batch when not (Outbox.acknowledged batch) ->
      let* () =
        Transport.verify_publication ~authority (Outbox.publication batch)
        |> transport
      in
      let* artifact =
        temporary_artifact ~root (fun destination ->
            Package.Core.restore_artifact ~source ~destination ~repository:scope
              ~authority ~manifest:(Outbox.manifest batch)
            |> package)
      in
      Ok (Some { batch; artifact; reused = true })
  | None | Some _ ->
      let* artifact =
        temporary_artifact ~root (fun destination ->
            Package.Core.create ~source ~destination ~authority
              ~records:(Local.record_objects local)
              ~selected_branch:(Local.selected local).Local.branch
              ~titles:
                (List.map
                   (fun row -> (row.Local.revision, row.Local.title))
                   (Local.publications local))
            |> package)
      in
      let keep = ref false in
      Fun.protect
        ~finally:(fun () -> if not !keep then Package.dispose_artifact artifact)
        (fun () ->
          let manifest = Package.artifact_manifest artifact in
          if
            Option.exists
              (fun batch -> Outbox.manifest batch = manifest)
              existing
          then Ok None
          else
            let* signing_capability =
              signing_capability
              |> Option.to_result
                   ~none:Signer_required
            in
            let* publisher = local_device collaboration authority in
            let certificate = Store.local_certificate collaboration in
            let known =
              match Transport.find_remote state ~name:remote with
              | None -> []
              | Some row -> Transport.remote_known_publications row
            in
            let parents =
              List.filter
                (fun reference ->
                  Yeokcham_v1_model.Device_id.equal
                    (Transport.reference_publisher reference)
                    (Trust.device_id publisher)
                  && Transport.reference_certificate reference = certificate)
                known
              |> List.map Transport.reference_id
              |> List.sort_uniq String.compare
            in
            let* publication =
              Transport.create_publication
                ~repository:
                  (Trust.repository (Trust.authority_membership authority))
                ~publisher ~certificate ~parents
                ~manifest:(Transport.sha256 manifest)
                ~signing_capability
              |> transport
            in
            let* batch =
              with_writer root (fun () ->
                  let* current = Store.load repository |> store in
                  let* current_local, collaboration, authority =
                    context current
                  in
                  let* () =
                    Transport.verify_publication ~authority publication
                    |> transport
                  in
                  let* () =
                    if
                      Transport.publication_certificate publication
                      = Store.local_certificate collaboration
                    then Ok ()
                    else
                      Error
                        (Metadata
                           "local courier identity changed while signing; \
                            prepare again")
                  in
                  let retained = Local.record_objects current_local in
                  let* () =
                    if
                      List.for_all
                        (fun row -> List.mem row retained)
                        (Local.record_objects local)
                    then Ok ()
                    else
                      Error
                        (Metadata
                           "public Core records changed while preparing the \
                            courier")
                  in
                  let previous_state = Store.transport collaboration in
                  let* state =
                    Outbox.freeze previous_state ~remote ~endpoint ~manifest
                      ~publication
                    |> transport
                  in
                  let* previous_bytes =
                    Transport.encode_local_state previous_state |> transport
                  in
                  let* bytes =
                    Transport.encode_local_state state |> transport
                  in
                  let* saved =
                    if previous_bytes = bytes then Ok current
                    else
                      save ~observe ~before:Freeze_before ~after:Freeze_after
                        repository current current_local collaboration authority
                        state
                  in
                  let* _, collaboration, _ = context saved in
                  let* batch =
                    pending (Store.transport collaboration) ~remote ~endpoint
                  in
                  batch
                  |> Option.to_result
                       ~none:(Metadata "frozen Core batch was not retained"))
            in
            if Outbox.acknowledged batch then Ok None
            else (
              keep := true;
              Ok (Some { batch; artifact; reused = false })))

let prepare = prepare_with ~observe:(fun _ -> ())

let acknowledge_with ~observe ~root ~remote ~endpoint ~publication:id =
  let* repository = Store.open_repository ~root |> store in
  with_writer root (fun () ->
      let* loaded = Store.load repository |> store in
      let* local, collaboration, authority = context loaded in
      let previous = Store.transport collaboration in
      let* batch = pending previous ~remote ~endpoint in
      let* batch =
        batch
        |> Option.to_result
             ~none:(Metadata "no frozen Core batch to acknowledge")
      in
      let* state =
        Outbox.acknowledge previous ~remote ~endpoint ~publication:id
        |> transport
      in
      if Outbox.acknowledged batch then Ok ()
      else
        let* manifest =
          Package.Core.decode_manifest
            ~repository:(Core.pool_repository (Local.pool local))
            (Outbox.manifest batch)
          |> package
        in
        let* records =
          Package.Core.record_inventory
            (Store.underlying_store repository)
            manifest
          |> package
        in
        let* local =
          List.fold_left
            (fun result operation ->
              let* local = result in
              if
                Local.Operation.committed operation
                && (not operation.Local.Operation.acknowledged)
                && operation.Local.Operation.staged <> []
                && List.for_all
                     (fun row -> List.mem row records)
                     operation.Local.Operation.staged
              then
                let* operation =
                  Local.Operation.acknowledge operation |> metadata
                in
                Local.put_operation
                  ~store:(Store.underlying_store repository)
                  operation local
                |> metadata
              else Ok local)
            (Ok local) (Local.operations local)
        in
        let* _ =
          save ~observe ~before:Acknowledge_before ~after:Acknowledge_after
            repository loaded local collaboration authority state
        in
        Ok ())

let acknowledge = acknowledge_with ~observe:(fun _ -> ())

module For_test = struct
  let prepare = prepare_with
  let acknowledge = acknowledge_with
end
