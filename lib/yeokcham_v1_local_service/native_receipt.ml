module Core = Yeokcham_v1_model.Core
module Store = Yeokcham_v1_store
module Raw = Yeokcham_store
module Trust = Yeokcham_v1_trust
module Package = Yeokcham_v1_package
module History = Yeokcham_v1_undo

[@@@warning "-42"]

type error =
  | Package_error of Package.error
  | Store_error of Store.error
  | Trust_error of Trust.error
  | Admission_error of Store.Local.receive_error
  | Metadata of string

let error_to_string = function
  | Package_error error -> Package.error_to_string error
  | Store_error error -> Store.error_to_string error
  | Trust_error error -> Trust.error_to_string error
  | Admission_error error -> Store.Local.receive_error_to_string error
  | Metadata message -> message

let ( let* ) = Result.bind
let store result = Result.map_error (fun error -> Store_error error) result
let trust result = Result.map_error (fun error -> Trust_error error) result
let metadata result = Result.map_error (fun message -> Metadata message) result
let package result = Result.map_error (fun error -> Package_error error) result

type outcome = {
  records_added : int;
  branches_added : int;
  unchanged : bool;
  cursor : Core.History_id.t;
  working_basis : Core.Record_id.t;
  selected_branch : Core.Branch_id.t;
  known_branches : Core.branch_state list;
  state_head : Raw.Stored_object_id.t;
}

type boundary = Before_metadata_publish | After_metadata_publish

let context loaded =
  let* local =
    loaded.Store.local
    |> Option.to_result
         ~none:
           (Metadata "Core receipt requires authenticated local branch state")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result
         ~none:(Metadata "Core receipt requires verified collaboration")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result
         ~none:(Metadata "Core receipt requires verified authority")
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
      (Metadata ("Core receipt writer unavailable: " ^ Unix.error_message error))

let merge_authority known incoming =
  let* membership =
    Trust.extend_membership
      (Trust.authority_membership known)
      (Trust.certificates (Trust.authority_membership incoming))
    |> trust
  in
  let epochs =
    Trust.authority_epochs known @ Trust.authority_epochs incoming
    |> List.sort_uniq (fun a b ->
        String.compare (Trust.epoch_id a) (Trust.epoch_id b))
  in
  Trust.verify_authority ~membership epochs |> trust

let authority_ids authority =
  ( List.map Trust.certificate_id
      (Trust.certificates (Trust.authority_membership authority))
    |> List.sort String.compare,
    List.map Trust.epoch_id (Trust.authority_epochs authority)
    |> List.sort String.compare )

let receive_with ~observe ~root ~package:directory =
  let* repository = Store.open_repository ~root |> store in
  let* initial = Store.load repository |> store in
  let* local, _, authority = context initial in
  let* prepared =
    Package.Core.prepare ~package:directory
      ~repository:(Core.pool_repository (Store.Local.pool local))
      ~known_authority:(Some authority)
    |> package
  in
  let* () =
    Package.Core.import_prepared
      ~destination:(Store.underlying_store repository)
      prepared
    |> package
  in
  with_writer root (fun () ->
      let* loaded = Store.load repository |> store in
      let* previous, collaboration, known = context loaded in
      let* authority =
        merge_authority known (Package.Core.prepared_authority prepared)
      in
      let* local =
        Store.Local.receive_records
          ~store:(Store.underlying_store repository)
          ~authority
          ~records:(Package.Core.prepared_records prepared)
          previous
        |> Result.map_error (fun error -> Admission_error error)
      in
      let* encoded = Store.Local.encode local |> metadata in
      let* previous_encoded = Store.Local.encode previous |> metadata in
      let changed =
        encoded <> previous_encoded
        || authority_ids known <> authority_ids authority
      in
      let* saved =
        if not changed then Ok loaded
        else
          let* collaboration =
            Store.collaboration_with_authority_transport
              ~transport:(Store.transport collaboration)
              ~authority
              ~revisions:(Store.signed_revisions collaboration)
              ~local_certificate:(Store.local_certificate collaboration)
              ~authorizations:(Store.authorizations collaboration)
              ~adoptions:(Store.adoptions collaboration)
            |> store
          in
          Store.For_test.save_collaborative
            ~before_publish:(fun () -> observe Before_metadata_publish)
            ~after_publish:(fun () -> observe After_metadata_publish)
            ~history:loaded.Store.history ~local repository
            ~expected:loaded.Store.head ~project:loaded.Store.project
            ~collaboration
          |> store
      in
      let* cursor =
        History.identity saved.Store.history
          (History.current saved.Store.history)
        |> metadata
      in
      let local = Option.get saved.Store.local in
      let selected = Store.Local.selected local in
      Ok
        {
          records_added =
            List.length (Store.Local.record_objects local)
            - List.length (Store.Local.record_objects previous);
          branches_added =
            List.length (Store.Local.branches local)
            - List.length (Store.Local.branches previous);
          unchanged = not changed;
          cursor;
          working_basis = selected.Store.Local.basis;
          selected_branch = selected.Store.Local.branch;
          known_branches = Store.Local.branches local;
          state_head = saved.Store.object_id;
        })

let receive = receive_with ~observe:(fun _ -> ())

module For_test = struct
  let receive = receive_with
end
