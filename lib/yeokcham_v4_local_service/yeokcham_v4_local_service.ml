module Model = Yeokcham_v4_model
module Journal = Yeokcham_v4_restore_journal
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_v4_store
module Trust = Yeokcham_v4_trust
module Package = Yeokcham_v4_package
module Recovery = Yeokcham_v4_recovery
module Transport = Yeokcham_v4_transport

module Path_map = Map.Make (struct
  type t = string list

  let compare = List.compare String.compare
end)

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Materialize_error of Snapshot.Materialize.error
  | Restore_journal_error of Journal.error
  | Model_error of Model.error
  | Trust_error of Trust.error
  | Package_error of Package.error
  | Recovery_error of Recovery.error
  | Transport_error of Transport.error
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Model.Snapshot_id.t
  | Unchanged_share of Model.Snapshot_id.t
  | Unsigned_project

type status = {
  creator : Model.Device_id.t;
  active_draft : Model.draft;
  checkpoint : Model.Snapshot_id.t;
  shared_changes : Model.shared_change list;
  shared_change_count : int;
  open_decisions : Model.decision list;
  deliveries : Model.delivery list;
  delivery_count : int;
  checkpoints : Model.checkpoint list;
  usernames : Model.username_registration list;
  uncaptured : bool;
}

type identity = {
  repository : Trust.Repository_id.t;
  device : Trust.device;
  role : Trust.role;
}

type materialized_candidate = {
  revision : Model.Revision_id.t;
  author : Model.Device_id.t;
  username : Model.Username.t option;
  directory : string;
}

type snapshot_entry_kind = File | Directory

type snapshot_entry = {
  kind : snapshot_entry_kind;
  mode : Snapshot.file_mode option;
  content : string option;
}

type path_difference = {
  path : Model.Path.t;
  before : snapshot_entry option;
  after : snapshot_entry option;
}

type comparison_target = Baseline | Candidate of Model.Revision_id.t

type decision_comparison = {
  compared_decision : Model.decision;
  compared_candidate : Model.change_revision;
  against : Model.Snapshot_id.t;
  differences : path_difference list;
}

type inspected_candidate = {
  inspected_revision : Model.change_revision;
  inspected_username : Model.Username.t option;
}

type decision_inspection = {
  inspected_decision : Model.decision;
  inspected_candidates : inspected_candidate list;
}

type package_review = {
  review_revision : Model.Revision_id.t;
  review_author : Model.Device_id.t;
  requires_adoption : bool;
}

type save_outcome = Unchanged of status | Saved of status

type compact_report = {
  kept : Model.compact_keep list;
  dropped : Model.Snapshot_id.t list;
  pruned_journals : string list;
  status : status;
}

type transport_arrival = {
  publication : Transport.publication;
  package : string;
}

type transport_receive = {
  discovered_publications : int;
  received_revisions : int;
  deferred_publications : int;
  created_decisions : int;
  transport_status : status;
}

type transport_outbound = {
  outbound_publication : Transport.publication;
  outbound_artifact : Package.artifact;
  outbound_revisions : Model.Revision_id.t list;
}

module Capture_window = struct
  type t = { first : float option; last : float option }

  let empty = { first = None; last = None }
  let quiet_seconds = 1.0
  let max_seconds = 30.0
  let clear = empty

  let observe window ~now =
    match window.first with
    | None -> { first = Some now; last = Some now }
    | Some first -> { first = Some first; last = Some now }

  let due window ~now =
    match (window.first, window.last) with
    | Some first, Some last ->
        now -. last >= quiet_seconds || now -. first >= max_seconds
    | Some _, None | None, Some _ | None, None -> false

  let timeout window ~now =
    match (window.first, window.last) with
    | Some first, Some last ->
        Float.max 0.0
          (Float.min
             (quiet_seconds -. (now -. last))
             (max_seconds -. (now -. first)))
    | Some _, None | None, Some _ | None, None -> 60.0
end

type in_place_restore = {
  safety_checkpoint : Model.Snapshot_id.t;
  restored_checkpoint : Model.Snapshot_id.t;
  resumed : bool;
}

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Materialize_error error -> Snapshot.Materialize.error_to_string error
  | Restore_journal_error error -> Journal.error_to_string error
  | Model_error error -> Model.error_to_string error
  | Trust_error error -> Trust.error_to_string error
  | Package_error error -> Package.error_to_string error
  | Recovery_error error -> Recovery.error_to_string error
  | Transport_error error -> Transport.error_to_string error
  | Invalid_checkpoint_id value ->
      "invalid saved checkpoint identifier: " ^ value
  | Unknown_checkpoint id ->
      "checkpoint is not retained by this project: "
      ^ Model.Snapshot_id.to_string id
  | Unchanged_share snapshot ->
      "share would not publish a new snapshot: "
      ^ Model.Snapshot_id.to_string snapshot
  | Unsigned_project ->
      "this V4 project has no signed collaboration state; initialize a signed \
       project"

let ( let* ) = Result.bind

let snapshot_id identity =
  identity |> Snapshot.Snapshot.stored_object_id
  |> Yeokcham_store.Stored_object_id.to_hex |> Model.Snapshot_id.of_string
  |> Result.map_error (fun error -> Model_error error)

let capture ~root store =
  let* identity, _ =
    Snapshot.scan_excluding_root_names
      ~excluded_root_names:[ ".yeokcham"; ".git" ] ~root ~store
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  snapshot_id identity

let status_of_project ?(uncaptured = false) project =
  let active_draft = Model.active_draft project in
  let projection = Model.projection project in
  let shared_changes = Model.shared_changes project in
  let deliveries = Model.deliveries project in
  {
    creator = Model.creator project;
    active_draft;
    checkpoint = active_draft.Model.latest_checkpoint;
    shared_changes;
    shared_change_count = List.length shared_changes;
    open_decisions = projection.Model.decisions;
    deliveries;
    delivery_count = List.length deliveries;
    checkpoints = Model.checkpoints project;
    usernames = Model.usernames project;
    uncaptured;
  }

let load_snapshot store snapshot =
  let text = Model.Snapshot_id.to_string snapshot in
  let* object_id =
    Yeokcham_store.Stored_object_id.of_hex text
    |> Result.map_error (fun _ -> Invalid_checkpoint_id text)
  in
  Snapshot.Snapshot.load store (Snapshot.Snapshot.of_stored_object_id object_id)
  |> Result.map_error (fun error -> Snapshot_error error)

let rec collect_leaves store prefix tree_id acc =
  let* tree =
    Snapshot.Tree.load store tree_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let rec walk acc = function
    | [] -> Ok acc
    | (name, entry) :: rest ->
        let path = prefix @ [ name ] in
        let* acc =
          match entry with
          | Snapshot.Tree.File { mode; content } ->
              Ok (Path_map.add path (mode, content) acc)
          | Snapshot.Tree.Directory child -> collect_leaves store path child acc
        in
        walk acc rest
  in
  walk acc (Snapshot.Tree.entries tree)

let leaves_of_snapshot store snapshot_id =
  let* snapshot = load_snapshot store snapshot_id in
  collect_leaves store [] (Snapshot.Snapshot.root snapshot) Path_map.empty

let entry_of_tree_entry = function
  | Snapshot.Tree.File { mode; content } ->
      {
        kind = File;
        mode = Some mode;
        content =
          Some
            (content |> Snapshot.Content.stored_object_id
           |> Yeokcham_store.Stored_object_id.to_hex);
      }
  | Snapshot.Tree.Directory _ ->
      { kind = Directory; mode = None; content = None }

let rec collect_snapshot_entries store prefix tree_id entries =
  let* tree =
    Snapshot.Tree.load store tree_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let rec walk entries = function
    | [] -> Ok entries
    | (name, entry) :: rest ->
        let path = prefix @ [ name ] in
        let entries = Path_map.add path (entry_of_tree_entry entry) entries in
        let* entries =
          match entry with
          | Snapshot.Tree.File _ -> Ok entries
          | Snapshot.Tree.Directory child ->
              collect_snapshot_entries store path child entries
        in
        walk entries rest
  in
  walk entries (Snapshot.Tree.entries tree)

let snapshot_entries store snapshot_id =
  let* snapshot = load_snapshot store snapshot_id in
  collect_snapshot_entries store []
    (Snapshot.Snapshot.root snapshot)
    Path_map.empty

let entry_equal (left_mode, left_content) (right_mode, right_content) =
  left_mode = right_mode && Snapshot.Content.equal_id left_content right_content

let differing_paths left right =
  Path_map.merge
    (fun _ left right ->
      match (left, right) with
      | Some left, Some right when entry_equal left right -> None
      | None, None -> None
      | _ -> Some ())
    left right
  |> Path_map.bindings |> List.map fst

let whole_path_edits paths =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | components :: rest ->
        let* path =
          Model.Path.of_components components
          |> Result.map_error (fun error -> Model_error error)
        in
        loop
          (Model.{ edit_path = path; edit_kind = Whole_path } :: reversed)
          rest
  in
  loop [] paths

let edits_between store ~baseline ~result =
  let* baseline_leaves = leaves_of_snapshot store baseline in
  let* result_leaves = leaves_of_snapshot store result in
  differing_paths baseline_leaves result_leaves |> whole_path_edits

let persist repository loaded project =
  let saved =
    match loaded.Store.collaboration with
    | None -> Store.save repository ~expected:loaded.Store.head ~project
    | Some collaboration ->
        Store.save_collaborative repository ~expected:loaded.Store.head ~project
          ~collaboration
  in
  saved
  |> Result.map (fun saved -> status_of_project saved.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let save_project repository loaded project =
  match loaded.Store.collaboration with
  | None -> Store.save repository ~expected:loaded.Store.head ~project
  | Some collaboration ->
      Store.save_collaborative repository ~expected:loaded.Store.head ~project
        ~collaboration

let persist_collaborative repository loaded project collaboration =
  Store.save_collaborative repository ~expected:loaded.Store.head ~project
    ~collaboration
  |> Result.map (fun saved -> status_of_project saved.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let require_collaboration loaded =
  match loaded.Store.collaboration with
  | Some collaboration -> Ok collaboration
  | None -> Error Unsigned_project

let local_certificate collaboration =
  match
    List.find_opt
      (fun certificate ->
        String.equal
          (Trust.certificate_id certificate)
          (Store.local_certificate collaboration))
      (Trust.certificates (Store.membership collaboration))
  with
  | Some certificate -> Ok certificate
  | None ->
      Error
        (Store_error
           (Store.Invalid_collaboration_state
              "local certificate is absent from membership"))

let local_device collaboration =
  let* certificate = local_certificate collaboration in
  Ok (Trust.certificate_subject certificate)

let authority_context_for_parents authority ~parents =
  match parents with
  | [] ->
      Error (Trust_error (Trust.Invalid_epoch "authority has no selected head"))
  | first :: rest ->
      let* first =
        Trust.authority_epoch authority first
        |> Result.map_error (fun error -> Trust_error error)
      in
      let recovery_device = Trust.epoch_recovery_device first in
      let rec gather revoked frontier = function
        | [] -> Ok (revoked, frontier)
        | head :: remaining ->
            let* epoch =
              Trust.authority_epoch authority head
              |> Result.map_error (fun error -> Trust_error error)
            in
            if
              not
                (Trust.device_equal recovery_device
                   (Trust.epoch_recovery_device epoch))
            then Error (Trust_error Trust.Invalid_recovery_authority)
            else
              gather
                (Trust.epoch_revoked epoch @ revoked)
                (Trust.epoch_frontier epoch @ frontier)
                remaining
      in
      let* revoked, frontier =
        gather (Trust.epoch_revoked first) (Trust.epoch_frontier first) rest
      in
      Ok
        ( parents,
          recovery_device,
          List.sort_uniq Model.Device_id.compare revoked,
          List.sort_uniq Model.Revision_id.compare frontier )

let current_authority_context authority =
  match Trust.authority_heads authority with
  | [ head ] -> authority_context_for_parents authority ~parents:[ head ]
  | [] ->
      Error (Trust_error (Trust.Invalid_epoch "authority has no active head"))
  | _ -> Error (Trust_error Trust.Authority_fork)

let selected_authority_context ?parent authority =
  match parent with
  | Some parent -> authority_context_for_parents authority ~parents:[ parent ]
  | None -> current_authority_context authority

let advance_authority_with ~authority ~membership ~parents ~recovery_device
    ~revoked ~frontier ~local_certificate ~signing_capability =
  let* epoch =
    Trust.successor_epoch authority ~parents
      ~certificates:(Trust.certificates membership)
      ~revoked ~frontier ~recovery_device ~issuer:local_certificate
      signing_capability
    |> Result.map_error (fun error -> Trust_error error)
  in
  Trust.extend_authority authority [ epoch ]
  |> Result.map_error (fun error -> Trust_error error)

let advance_authority ~parent ~authority ~membership ~local_certificate
    ~signing_capability =
  let* parents, recovery_device, revoked, frontier =
    selected_authority_context ?parent authority
  in
  advance_authority_with ~authority ~membership ~parents ~recovery_device
    ~revoked ~frontier ~local_certificate ~signing_capability

let checkpoint_observed project observed =
  let active = Model.active_draft project in
  if Model.Snapshot_id.equal active.Model.latest_checkpoint observed then
    project
  else Model.checkpoint project ~snapshot:observed

let with_repository ~root f =
  let* repository =
    Store.open_repository ~root
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  f repository loaded

let recovery_package_path root =
  Filename.concat (Filename.concat root ".yeokcham") "recovery-v1.cbor"

let write_recovery_package_to_exclusive ~path ceremony =
  try
    let channel =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      |> Unix.out_channel_of_descr
    in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        Out_channel.output_string channel
          (Recovery.encode ceremony.Recovery.package);
        Out_channel.flush channel);
    Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "could not write recovery package %s (%s): %s" path
         operation (Unix.error_message error))

let write_recovery_package_exclusive ~root ceremony =
  write_recovery_package_to_exclusive
    ~path:(recovery_package_path root)
    ceremony

let init ~root ~creator ~username ~initial_draft ~title =
  let* repository =
    Store.init_with ~root ~bootstrap:(fun underlying_store ->
        let* initial_snapshot =
          capture ~root underlying_store |> Result.map_error error_to_string
        in
        Ok
          (Model.init ~creator ~username ~initial_snapshot ~initial_draft ~title))
    |> Result.map_error (fun error -> Store_error error)
  in
  Store.load repository
  |> Result.map (fun loaded -> status_of_project loaded.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let init_collaboration ~root ~username ~initial_draft ~title ~device ~membership
    ~local_certificate =
  let* repository =
    Store.init_collaborative_with ~root ~bootstrap:(fun underlying_store ->
        let* initial_snapshot =
          capture ~root underlying_store |> Result.map_error error_to_string
        in
        let project =
          Model.init ~creator:(Trust.device_id device) ~username
            ~initial_snapshot ~initial_draft ~title
        in
        let* collaboration =
          Store.collaboration ~membership ~revisions:[] ~local_certificate
          |> Result.map_error Store.error_to_string
        in
        Ok (project, collaboration))
    |> Result.map_error (fun error -> Store_error error)
  in
  Store.load repository
  |> Result.map (fun loaded -> status_of_project loaded.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let init_authority_collaboration ~root ~username ~initial_draft ~title ~device
    ~authority ~local_certificate =
  let membership = Trust.authority_membership authority in
  let* authority =
    Trust.verify_authority ~membership (Trust.authority_epochs authority)
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* repository =
    Store.init_collaborative_with ~root ~bootstrap:(fun underlying_store ->
        let* initial_snapshot =
          capture ~root underlying_store |> Result.map_error error_to_string
        in
        let project =
          Model.init ~creator:(Trust.device_id device) ~username
            ~initial_snapshot ~initial_draft ~title
        in
        Store.collaboration_with_authority ~authority ~revisions:[]
          ~local_certificate ~authorizations:[] ~adoptions:[]
        |> Result.map_error Store.error_to_string
        |> Result.map (fun collaboration -> (project, collaboration)))
    |> Result.map_error (fun error -> Store_error error)
  in
  Store.load repository
  |> Result.map (fun loaded -> status_of_project loaded.Store.project)
  |> Result.map_error (fun error -> Store_error error)

let init_signed ~root ~username ~initial_draft ~title ~repository ~device
    ~signing_capability =
  let* root_certificate =
    Trust.root_certificate ~repository ~device signing_capability
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* membership =
    Trust.verify_membership ~repository [ root_certificate ]
    |> Result.map_error (fun error -> Trust_error error)
  in
  init_collaboration ~root ~username ~initial_draft ~title ~device ~membership
    ~local_certificate:(Trust.certificate_id root_certificate)

let init_signed_with_recovery ~root ~username ~initial_draft ~title ~repository
    ~device ~signing_capability ~recovery_device ~recovery_capability =
  let* root_certificate =
    Trust.root_certificate ~repository ~device signing_capability
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* membership =
    Trust.verify_membership ~repository [ root_certificate ]
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device signing_capability
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> Result.map_error (fun error -> Trust_error error)
  in
  let* ceremony =
    Recovery.create ~authority ~recovery_capability
    |> Result.map_error (fun error -> Recovery_error error)
  in
  let* repository =
    Store.init_collaborative_with ~root ~bootstrap:(fun underlying_store ->
        let* () = write_recovery_package_exclusive ~root ceremony in
        let* initial_snapshot =
          capture ~root underlying_store |> Result.map_error error_to_string
        in
        let project =
          Model.init ~creator:(Trust.device_id device) ~username
            ~initial_snapshot ~initial_draft ~title
        in
        Store.collaboration_with_authority ~authority ~revisions:[]
          ~local_certificate:(Trust.certificate_id root_certificate)
          ~authorizations:[] ~adoptions:[]
        |> Result.map_error Store.error_to_string
        |> Result.map (fun collaboration -> (project, collaboration)))
    |> Result.map_error (fun error -> Store_error error)
  in
  let* loaded =
    Store.load repository |> Result.map_error (fun error -> Store_error error)
  in
  Ok (status_of_project loaded.Store.project, ceremony)

let status ~root =
  with_repository ~root (fun repository loaded ->
      let* observed = capture ~root (Store.underlying_store repository) in
      let active = Model.active_draft loaded.Store.project in
      let uncaptured =
        not (Model.Snapshot_id.equal active.Model.latest_checkpoint observed)
      in
      Ok (status_of_project ~uncaptured loaded.Store.project))

let identity ~root =
  with_repository ~root (fun _ loaded ->
      let* collaboration = require_collaboration loaded in
      let* certificate = local_certificate collaboration in
      Ok
        {
          repository = Trust.repository (Store.membership collaboration);
          device = Trust.certificate_subject certificate;
          role = Trust.certificate_role certificate;
        })

let register_username ~root ~device ~username =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.register_username loaded.Store.project ~device ~username
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let enroll_device ~parent ~root ~subject ~role ~username ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      let* certificate =
        Trust.enroll
          (Store.membership collaboration)
          ~issuer:(Store.local_certificate collaboration)
          signing_capability ~subject ~role
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* membership =
        Trust.extend_membership (Store.membership collaboration) [ certificate ]
        |> Result.map_error (fun error -> Trust_error error)
      in
      let* project =
        Model.register_username loaded.Store.project
          ~device:(Trust.device_id subject) ~username
        |> Result.map_error (fun error -> Model_error error)
      in
      let* collaboration =
        match Store.authority collaboration with
        | None ->
            Store.collaboration ~membership
              ~revisions:(Store.signed_revisions collaboration)
              ~local_certificate:(Store.local_certificate collaboration)
            |> Result.map_error (fun error -> Store_error error)
        | Some authority ->
            let* authority =
              Trust.verify_authority ~membership
                (Trust.authority_epochs authority)
              |> Result.map_error (fun error -> Trust_error error)
            in
            let* authority =
              advance_authority ~parent ~authority ~membership
                ~local_certificate:(Store.local_certificate collaboration)
                ~signing_capability
            in
            Store.collaboration_with_authority ~authority
              ~revisions:(Store.signed_revisions collaboration)
              ~local_certificate:(Store.local_certificate collaboration)
              ~authorizations:(Store.authorizations collaboration)
              ~adoptions:(Store.adoptions collaboration)
            |> Result.map_error (fun error -> Store_error error)
      in
      persist_collaborative repository loaded project collaboration)

let authority_heads ~root =
  with_repository ~root (fun _ loaded ->
      let* collaboration = require_collaboration loaded in
      match Store.authority collaboration with
      | Some authority -> Ok (Trust.authority_heads authority)
      | None ->
          Error
            (Trust_error
               (Trust.Invalid_epoch
                  "legacy collaboration has no authority epochs")))

let reconcile_authority ~root ~parents ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      let* authority =
        match Store.authority collaboration with
        | Some authority -> Ok authority
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch
                    "legacy collaboration has no authority epochs"))
      in
      if List.length parents < 2 then
        Error
          (Trust_error
             (Trust.Invalid_epoch
                "a reconciliation must explicitly name at least two authority \
                 heads"))
      else if List.sort_uniq String.compare parents <> parents then
        Error
          (Trust_error
             (Trust.Invalid_epoch
                "reconciliation parent heads must be strictly sorted and unique"))
      else if
        not
          (List.for_all
             (fun parent -> Trust.authority_epoch_is_head authority parent)
             parents)
      then
        Error
          (Trust_error
             (Trust.Invalid_epoch
                "a reconciliation may name only current authority heads"))
      else
        let* parents, recovery_device, revoked, frontier =
          authority_context_for_parents authority ~parents
        in
        let* authority =
          advance_authority_with ~authority
            ~membership:(Store.membership collaboration)
            ~parents ~recovery_device ~revoked ~frontier
            ~local_certificate:(Store.local_certificate collaboration)
            ~signing_capability
        in
        let* collaboration =
          Store.collaboration_with_authority ~authority
            ~revisions:(Store.signed_revisions collaboration)
            ~local_certificate:(Store.local_certificate collaboration)
            ~authorizations:(Store.authorizations collaboration)
            ~adoptions:(Store.adoptions collaboration)
          |> Result.map_error (fun error -> Store_error error)
        in
        persist_collaborative repository loaded loaded.Store.project
          collaboration)

let revoke_device ~parent ~root ~device ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      let* authority =
        match Store.authority collaboration with
        | Some authority -> Ok authority
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch
                    "legacy collaboration has no authority epochs"))
      in
      let* local = local_device collaboration in
      let* revoked_device =
        match
          Trust.certificates (Store.membership collaboration)
          |> List.find_opt (fun certificate ->
              Model.Device_id.equal device
                (Trust.device_id (Trust.certificate_subject certificate)))
        with
        | Some certificate -> Ok (Trust.certificate_subject certificate)
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch "revocation names an unknown device"))
      in
      if Trust.device_equal local revoked_device then
        Error
          (Trust_error
             (Trust.Invalid_epoch
                "use atomic device rotation instead of revoking this local \
                 device"))
      else
        let* parents, recovery_device, revoked, frontier =
          selected_authority_context ?parent authority
        in
        let revoked =
          device :: revoked |> List.sort_uniq Model.Device_id.compare
        in
        let* authority =
          advance_authority_with ~authority
            ~membership:(Store.membership collaboration)
            ~parents ~recovery_device ~revoked ~frontier
            ~local_certificate:(Store.local_certificate collaboration)
            ~signing_capability
        in
        let* collaboration =
          Store.collaboration_with_authority ~authority
            ~revisions:(Store.signed_revisions collaboration)
            ~local_certificate:(Store.local_certificate collaboration)
            ~authorizations:(Store.authorizations collaboration)
            ~adoptions:(Store.adoptions collaboration)
          |> Result.map_error (fun error -> Store_error error)
        in
        persist_collaborative repository loaded loaded.Store.project
          collaboration)

let rotate_local_device ~parent ~root ~replacement ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      let* authority =
        match Store.authority collaboration with
        | Some authority -> Ok authority
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch
                    "legacy collaboration has no authority epochs"))
      in
      let* local = local_device collaboration in
      if Trust.device_equal local replacement then
        Error
          (Trust_error
             (Trust.Invalid_epoch "replacement device is already local"))
      else
        let* old_certificate = local_certificate collaboration in
        let* replacement_certificate =
          Trust.enroll
            (Store.membership collaboration)
            ~issuer:(Store.local_certificate collaboration)
            signing_capability ~subject:replacement
            ~role:(Trust.certificate_role old_certificate)
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* membership =
          Trust.extend_membership
            (Store.membership collaboration)
            [ replacement_certificate ]
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* authority =
          Trust.verify_authority ~membership (Trust.authority_epochs authority)
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* parents, recovery_device, revoked, frontier =
          selected_authority_context ?parent authority
        in
        let revoked =
          Trust.device_id local :: revoked
          |> List.sort_uniq Model.Device_id.compare
        in
        let* authority =
          advance_authority_with ~authority ~membership ~parents
            ~recovery_device ~revoked ~frontier
            ~local_certificate:(Store.local_certificate collaboration)
            ~signing_capability
        in
        let* collaboration =
          Store.collaboration_with_authority ~authority
            ~revisions:(Store.signed_revisions collaboration)
            ~local_certificate:(Trust.certificate_id replacement_certificate)
            ~authorizations:(Store.authorizations collaboration)
            ~adoptions:(Store.adoptions collaboration)
          |> Result.map_error (fun error -> Store_error error)
        in
        persist_collaborative repository loaded loaded.Store.project
          collaboration)

let read_recovery_package path =
  try
    In_channel.with_open_bin path In_channel.input_all
    |> Recovery.decode
    |> Result.map_error (fun error -> Recovery_error error)
  with Sys_error message ->
    Error (Recovery_error (Recovery.Invalid_package message))

let recover_authority ~root ~package ~mnemonic ~output ~replacement ~replaced =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      let* authority =
        match Store.authority collaboration with
        | Some authority -> Ok authority
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch
                    "legacy collaboration has no authority epochs"))
      in
      let* package = read_recovery_package package in
      let* recovered =
        Recovery.recover ~mnemonic ~package
        |> Result.map_error (fun error -> Recovery_error error)
      in
      let* parents, current_recovery, revoked, frontier =
        authority_context_for_parents authority
          ~parents:(Trust.authority_heads authority)
      in
      if
        not
          (String.equal
             (Trust.signing_public_key
                (Recovery.recovered_capability recovered))
             (Trust.device_public_key current_recovery))
      then Error (Trust_error Trust.Invalid_recovery_authority)
      else
        let* replacement_certificate =
          Trust.recover_enroll authority ~parents ~subject:replacement
            ~role:Trust.Administrator
            (Recovery.recovered_capability recovered)
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* membership =
          Trust.extend_membership
            (Store.membership collaboration)
            [ replacement_certificate ]
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* authority =
          Trust.verify_authority ~membership (Trust.authority_epochs authority)
          |> Result.map_error (fun error -> Trust_error error)
        in
        let revoked =
          replaced :: revoked |> List.sort_uniq Model.Device_id.compare
        in
        let* next_recovery =
          Trust.generate_device ()
          |> Result.map_error (fun error -> Trust_error error)
        in
        let next_recovery_device = Trust.generated_identity next_recovery in
        let next_recovery_capability =
          Trust.generated_signing_capability next_recovery
        in
        let* epoch =
          Trust.recover_epoch authority ~parents
            ~certificates:(Trust.certificates membership)
            ~revoked ~frontier ~recovery_device:next_recovery_device
            (Recovery.recovered_capability recovered)
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* authority =
          Trust.extend_authority authority [ epoch ]
          |> Result.map_error (fun error -> Trust_error error)
        in
        let* ceremony =
          Recovery.create ~authority
            ~recovery_capability:next_recovery_capability
          |> Result.map_error (fun error -> Recovery_error error)
        in
        let* () =
          write_recovery_package_to_exclusive ~path:output ceremony
          |> Result.map_error (fun detail ->
              Recovery_error (Recovery.Invalid_package detail))
        in
        let* collaboration =
          Store.collaboration_with_authority ~authority
            ~revisions:(Store.signed_revisions collaboration)
            ~local_certificate:(Trust.certificate_id replacement_certificate)
            ~authorizations:(Store.authorizations collaboration)
            ~adoptions:(Store.adoptions collaboration)
          |> Result.map_error (fun error -> Store_error error)
        in
        let* status =
          persist_collaborative repository loaded loaded.Store.project
            collaboration
        in
        Ok (status, ceremony))

let refresh_recovery_package ~root ~package ~mnemonic ~output =
  with_repository ~root (fun _ loaded ->
      let* collaboration = require_collaboration loaded in
      let* authority =
        match Store.authority collaboration with
        | Some authority -> Ok authority
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch
                    "legacy collaboration has no authority epochs"))
      in
      let* package = read_recovery_package package in
      let* recovered =
        Recovery.recover ~mnemonic ~package
        |> Result.map_error (fun error -> Recovery_error error)
      in
      let* _, current_recovery, _, _ =
        authority_context_for_parents authority
          ~parents:(Trust.authority_heads authority)
      in
      if
        not
          (String.equal
             (Trust.signing_public_key
                (Recovery.recovered_capability recovered))
             (Trust.device_public_key current_recovery))
      then Error (Trust_error Trust.Invalid_recovery_authority)
      else
        let* secret =
          Recovery.secret_of_mnemonic mnemonic
          |> Result.map_error (fun error -> Recovery_error error)
        in
        let* package =
          Recovery.refresh ~secret ~authority
            ~recovery_capability:(Recovery.recovered_capability recovered)
          |> Result.map_error (fun error -> Recovery_error error)
        in
        let ceremony = { Recovery.mnemonic; package } in
        write_recovery_package_to_exclusive ~path:output ceremony
        |> Result.map_error (fun detail ->
            Recovery_error (Recovery.Invalid_package detail)))

let save ~root =
  with_repository ~root (fun repository loaded ->
      let* observed = capture ~root (Store.underlying_store repository) in
      let active = Model.active_draft loaded.Store.project in
      if Model.Snapshot_id.equal active.Model.latest_checkpoint observed then
        Ok (Unchanged (status_of_project loaded.Store.project))
      else
        let project =
          Model.checkpoint loaded.Store.project ~snapshot:observed
        in
        persist repository loaded project
        |> Result.map (fun status -> Saved status))

let restore ~root ~checkpoint ~destination =
  with_repository ~root (fun repository loaded ->
      if
        not
          (List.exists
             (fun candidate ->
               Model.Snapshot_id.equal candidate.Model.checkpoint_snapshot
                 checkpoint)
             (Model.checkpoints loaded.Store.project))
      then Error (Unknown_checkpoint checkpoint)
      else
        let* snapshot =
          load_snapshot (Store.underlying_store repository) checkpoint
        in
        Snapshot.Materialize.write ~destination
          (Store.underlying_store repository)
          snapshot
        |> Result.map_error (fun error -> Materialize_error error))

let retained project checkpoint =
  List.exists
    (fun candidate ->
      Model.Snapshot_id.equal candidate.Model.checkpoint_snapshot checkpoint)
    (Model.checkpoints project)

let hex_of_raw raw =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length raw * 2)
    (fun index ->
      let byte = Char.code raw.[index / 2] in
      if index mod 2 = 0 then alphabet.[byte lsr 4]
      else alphabet.[byte land 0x0f])

let restore_operation_id ~safety ~target =
  let seed =
    String.concat ":"
      [
        Model.Snapshot_id.to_string safety;
        Model.Snapshot_id.to_string target;
        string_of_int (Unix.getpid ());
        Int64.to_string
          (Int64.of_float (Unix.gettimeofday () *. 1_000_000_000.));
      ]
  in
  Yeokcham_hash.Sha256.digest_string seed
  |> Yeokcham_hash.Sha256.to_raw_string |> hex_of_raw

let append_journal ~root journal =
  Journal.append ~root journal
  |> Result.map_error (fun error -> Restore_journal_error error)

let advance_journal ~root journal phase =
  let* next =
    Journal.advance journal phase
    |> Result.map_error (fun error -> Restore_journal_error error)
  in
  let* () = append_journal ~root next in
  Ok next

let perform_in_place ~root repository loaded journal ~resumed =
  let store = Store.underlying_store repository in
  let* applying =
    match Journal.phase journal with
    | Journal.Prepared -> advance_journal ~root journal Journal.Applying
    | Journal.Applying -> Ok journal
    | Journal.Materialized | Journal.Published -> Ok journal
  in
  let* materialized =
    match Journal.phase applying with
    | Journal.Applying ->
        let* target = load_snapshot store (Journal.target applying) in
        let* () =
          Snapshot.Materialize.write_replacing ~destination:root
            ~preserved_root_names:[ ".yeokcham"; ".git" ] store target
          |> Result.map_error (fun error -> Materialize_error error)
        in
        advance_journal ~root applying Journal.Materialized
    | Journal.Materialized | Journal.Published -> Ok applying
    | Journal.Prepared -> assert false
  in
  let* () =
    match Journal.phase materialized with
    | Journal.Materialized ->
        let project =
          Model.checkpoint loaded.Store.project
            ~snapshot:(Journal.target materialized)
        in
        let* _ =
          save_project repository loaded project
          |> Result.map_error (fun error -> Store_error error)
        in
        let* _ = advance_journal ~root materialized Journal.Published in
        Ok ()
    | Journal.Published -> Ok ()
    | Journal.Prepared | Journal.Applying -> assert false
  in
  Ok
    {
      safety_checkpoint = Journal.safety journal;
      restored_checkpoint = Journal.target journal;
      resumed;
    }

let recover_in_place ~root =
  with_repository ~root (fun repository loaded ->
      let* pending =
        Journal.latest_pending ~root
        |> Result.map_error (fun error -> Restore_journal_error error)
      in
      match pending with
      | None -> Ok None
      | Some journal ->
          if
            (not (retained loaded.Store.project (Journal.safety journal)))
            || not (retained loaded.Store.project (Journal.target journal))
          then
            Error
              (Restore_journal_error
                 (Journal.Invalid_schema
                    "pending restore names an unretained checkpoint"))
          else
            perform_in_place ~root repository loaded journal ~resumed:true
            |> Result.map Option.some)

let restore_in_place ~root ~checkpoint =
  let* recovered = recover_in_place ~root in
  match recovered with
  | Some restored
    when Model.Snapshot_id.equal restored.restored_checkpoint checkpoint ->
      Ok restored
  | Some restored ->
      Error
        (Restore_journal_error
           (Journal.Invalid_schema
              ("completed pending restore to "
              ^ Model.Snapshot_id.to_string restored.restored_checkpoint
              ^ "; rerun the requested restore")))
  | None ->
      with_repository ~root (fun repository loaded ->
          if not (retained loaded.Store.project checkpoint) then
            Error (Unknown_checkpoint checkpoint)
          else
            let store = Store.underlying_store repository in
            let* safety = capture ~root store in
            if Model.Snapshot_id.equal safety checkpoint then
              Error (Restore_journal_error Journal.Identical_snapshots)
            else
              let project =
                Model.checkpoint loaded.Store.project ~snapshot:safety
              in
              let* saved =
                save_project repository loaded project
                |> Result.map_error (fun error -> Store_error error)
              in
              let operation_id =
                restore_operation_id ~safety ~target:checkpoint
              in
              let* journal =
                Journal.make_prepared ~operation_id ~safety ~target:checkpoint
                |> Result.map_error (fun error -> Restore_journal_error error)
              in
              let* () = append_journal ~root journal in
              perform_in_place ~root repository saved journal ~resumed:false)

let new_draft ~root ~id ~title =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.new_draft loaded.Store.project ~id ~title
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let make_revision ~author ~change ~revision ~parent ~base ~result ~edits =
  Model.make_change_revision ~change ~revision ~parent ~author ~base ~result
    ~edits
  |> Result.map_error (fun error -> Model_error error)

let share ~root ~change ~revision =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let baseline = (Model.projection project).Model.projection_baseline in
      let active = Model.active_draft project in
      let* () =
        match active.Model.shared_change with
        | None -> Ok ()
        | Some change_id -> (
            match
              List.find_opt
                (fun candidate ->
                  Model.Change_id.equal candidate.Model.change_id change_id)
                (Model.shared_changes project)
            with
            | None -> Ok ()
            | Some shared -> (
                match shared.Model.revisions with
                | latest :: _
                  when Model.Snapshot_id.equal latest.Model.result_snapshot
                         observed ->
                    Error (Unchanged_share observed)
                | _ -> Ok ()))
      in
      let* edits = edits_between store ~baseline ~result:observed in
      let* recorded =
        match active.Model.shared_change with
        | None ->
            let* recorded =
              make_revision ~author:(Model.creator project) ~change ~revision
                ~parent:None ~base:baseline ~result:observed ~edits
            in
            Model.share_active project recorded
            |> Result.map_error (fun error -> Model_error error)
        | Some change_id ->
            let parent =
              match
                List.find_opt
                  (fun candidate ->
                    Model.Change_id.equal candidate.Model.change_id change_id)
                  (Model.shared_changes project)
              with
              | Some shared -> (
                  match shared.Model.revisions with
                  | latest :: _ -> Some latest.Model.revision
                  | [] -> None)
              | None -> None
            in
            let* recorded =
              make_revision ~author:(Model.creator project) ~change ~revision
                ~parent ~base:baseline ~result:observed ~edits
            in
            Model.amend_active project recorded
            |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded recorded)

let extend_signed_revisions collaboration signed =
  match Store.authority collaboration with
  | None ->
      Store.collaboration
        ~membership:(Store.membership collaboration)
        ~revisions:(signed :: Store.signed_revisions collaboration)
        ~local_certificate:(Store.local_certificate collaboration)
      |> Result.map_error (fun error -> Store_error error)
  | Some authority ->
      Store.collaboration_with_authority ~authority
        ~revisions:(signed :: Store.signed_revisions collaboration)
        ~local_certificate:(Store.local_certificate collaboration)
        ~authorizations:(Store.authorizations collaboration)
        ~adoptions:(Store.adoptions collaboration)
      |> Result.map_error (fun error -> Store_error error)

let authority_epoch_for_new_record ~selected collaboration =
  match Store.authority collaboration with
  | None -> Ok None
  | Some authority -> (
      match selected with
      | Some epoch when Trust.authority_epoch_is_head authority epoch ->
          Ok (Some (authority, epoch))
      | Some _ ->
          Error
            (Trust_error
               (Trust.Invalid_epoch
                  "a signed record must name a current authority head"))
      | None -> (
          match Trust.authority_heads authority with
          | [ epoch ] -> Ok (Some (authority, epoch))
          | [] ->
              Error
                (Trust_error
                   (Trust.Invalid_epoch "authority has no active head"))
          | _ -> Error (Trust_error Trust.Authority_fork)))

let share_signed ~authority_epoch ~root ~change ~revision ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      let* author = local_device collaboration in
      let* authority_epoch =
        authority_epoch_for_new_record ~selected:authority_epoch collaboration
      in
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let baseline = (Model.projection project).Model.projection_baseline in
      let active = Model.active_draft project in
      let* () =
        match active.Model.shared_change with
        | None -> Ok ()
        | Some change_id -> (
            match
              List.find_opt
                (fun candidate ->
                  Model.Change_id.equal candidate.Model.change_id change_id)
                (Model.shared_changes project)
            with
            | None -> Ok ()
            | Some shared -> (
                match shared.Model.revisions with
                | latest :: _
                  when Model.Snapshot_id.equal latest.Model.result_snapshot
                         observed ->
                    Error (Unchanged_share observed)
                | _ -> Ok ()))
      in
      let* edits = edits_between store ~baseline ~result:observed in
      let* recorded =
        match active.Model.shared_change with
        | None ->
            let* recorded =
              make_revision ~author:(Trust.device_id author) ~change ~revision
                ~parent:None ~base:baseline ~result:observed ~edits
            in
            Model.share_active project recorded
            |> Result.map (fun project -> (project, recorded))
            |> Result.map_error (fun error -> Model_error error)
        | Some change_id ->
            let parent =
              match
                List.find_opt
                  (fun candidate ->
                    Model.Change_id.equal candidate.Model.change_id change_id)
                  (Model.shared_changes project)
              with
              | Some shared -> (
                  match shared.Model.revisions with
                  | latest :: _ -> Some latest.Model.revision
                  | [] -> None)
              | None -> None
            in
            let* recorded =
              make_revision ~author:(Trust.device_id author) ~change ~revision
                ~parent ~base:baseline ~result:observed ~edits
            in
            Model.amend_active project recorded
            |> Result.map (fun project -> (project, recorded))
            |> Result.map_error (fun error -> Model_error error)
      in
      let project, recorded = recorded in
      let* signed =
        match authority_epoch with
        | None ->
            Trust.sign_revision
              (Store.membership collaboration)
              ~certificate:(Store.local_certificate collaboration)
              signing_capability recorded
            |> Result.map_error (fun error -> Trust_error error)
        | Some (authority, epoch) ->
            Trust.sign_revision_at authority ~epoch
              ~certificate:(Store.local_certificate collaboration)
              signing_capability recorded
            |> Result.map_error (fun error -> Trust_error error)
      in
      let* collaboration = extend_signed_revisions collaboration signed in
      persist_collaborative repository loaded project collaboration)

let withdraw ~root ~change =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.withdraw loaded.Store.project ~change
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let find_open_decision project decision =
  List.find_opt
    (fun candidate ->
      Model.Decision_id.equal candidate.Model.decision_id decision)
    (Model.projection project).Model.decisions

let require_empty_directory destination =
  try
    if (Unix.lstat destination).Unix.st_kind <> Unix.S_DIR then
      Error
        (Materialize_error
           (Snapshot.Materialize.Destination_not_directory destination))
    else if Array.length (Sys.readdir destination) <> 0 then
      Error
        (Materialize_error
           (Snapshot.Materialize.Destination_not_empty destination))
    else Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Materialize_error
         (Snapshot.Materialize.Io_error
            {
              path = destination;
              operation;
              message = Unix.error_message error;
            }))

let mkdir_exclusive path =
  try
    Unix.mkdir path 0o700;
    Ok ()
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Materialize_error
         (Snapshot.Materialize.Io_error
            { path; operation; message = Unix.error_message error }))

let unique_candidate_revisions (decision : Model.decision) =
  decision.Model.candidates
  |> List.map (fun candidate -> candidate.Model.candidate_revision)
  |> List.sort_uniq (fun left right ->
      Model.Revision_id.compare left.Model.revision right.Model.revision)

let candidate_directory_name ~username ~index =
  let handle =
    match username with
    | Some username -> Model.Username.to_string username
    | None -> "device"
  in
  Printf.sprintf "%s-%03d" handle (index + 1)

let contained_child ~destination ~name =
  if
    String.length name = 0
    || String.equal name "." || String.equal name ".."
    || not (String.equal (Filename.basename name) name)
  then
    Error
      (Materialize_error
         (Snapshot.Materialize.Io_error
            {
              path = destination;
              operation = "derive candidate directory";
              message =
                "candidate directory name is not a single path component";
            }))
  else Ok (Filename.concat destination name)

let open_decision ~root ~decision =
  with_repository ~root (fun _ loaded ->
      match find_open_decision loaded.Store.project decision with
      | Some found -> Ok found
      | None -> Error (Model_error Model.Unknown_decision))

let inspect_decision ~root ~decision =
  with_repository ~root (fun _ loaded ->
      match find_open_decision loaded.Store.project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some decision ->
          let candidates =
            decision.Model.candidates
            |> List.map (fun candidate -> candidate.Model.candidate_revision)
            |> List.sort_uniq (fun left right ->
                Model.Revision_id.compare left.Model.revision
                  right.Model.revision)
            |> List.map (fun revision ->
                {
                  inspected_revision = revision;
                  inspected_username =
                    Model.username_for_device loaded.Store.project
                      ~device:revision.Model.revision_author;
                })
          in
          Ok
            { inspected_decision = decision; inspected_candidates = candidates })

let decision_revision decision revision_id =
  decision.Model.candidates
  |> List.map (fun candidate -> candidate.Model.candidate_revision)
  |> List.find_opt (fun candidate ->
      Model.Revision_id.equal candidate.Model.revision revision_id)

let comparison_differences store ~before ~after =
  let* before_entries = snapshot_entries store before in
  let* after_entries = snapshot_entries store after in
  Path_map.merge
    (fun components before after ->
      match (before, after) with
      | Some left, Some right when left = right -> None
      | None, None -> None
      | _ ->
          let path =
            Model.Path.of_components components
            |> Result.map_error (fun error -> Model_error error)
          in
          Some (Result.map (fun path -> { path; before; after }) path))
    before_entries after_entries
  |> Path_map.bindings
  |> List.fold_left
       (fun differences (_, difference) ->
         let* differences = differences in
         let* difference = difference in
         Ok (difference :: differences))
       (Ok [])
  |> Result.map List.rev

let compare_decision ~root ~decision ~candidate ~against =
  with_repository ~root (fun repository loaded ->
      match find_open_decision loaded.Store.project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some found -> (
          match decision_revision found candidate with
          | None -> Error (Model_error Model.Unknown_revision)
          | Some candidate ->
              let* against =
                match against with
                | Baseline ->
                    Ok
                      (Model.projection loaded.Store.project)
                        .Model.projection_baseline
                | Candidate revision -> (
                    match decision_revision found revision with
                    | Some revision -> Ok revision.Model.result_snapshot
                    | None -> Error (Model_error Model.Unknown_revision))
              in
              let store = Store.underlying_store repository in
              let* differences =
                comparison_differences store ~before:against
                  ~after:candidate.Model.result_snapshot
              in
              Ok
                {
                  compared_decision = found;
                  compared_candidate = candidate;
                  against;
                  differences;
                }))

let materialize_decision ~root ~decision ~destination =
  with_repository ~root (fun repository loaded ->
      match find_open_decision loaded.Store.project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some found ->
          let* () = require_empty_directory destination in
          let store = Store.underlying_store repository in
          let revisions = unique_candidate_revisions found in
          let rec write index remaining materialized =
            match remaining with
            | [] -> Ok (List.rev materialized)
            | revision :: rest ->
                let username =
                  Model.username_for_device loaded.Store.project
                    ~device:revision.Model.revision_author
                in
                let* child =
                  contained_child ~destination
                    ~name:(candidate_directory_name ~username ~index)
                in
                let* () = mkdir_exclusive child in
                let* snapshot =
                  load_snapshot store revision.Model.result_snapshot
                in
                let* () =
                  Snapshot.Materialize.write ~destination:child store snapshot
                  |> Result.map_error (fun error -> Materialize_error error)
                in
                write (index + 1) rest
                  ({
                     revision = revision.Model.revision;
                     author = revision.Model.revision_author;
                     username;
                     directory = child;
                   }
                  :: materialized)
          in
          write 0 revisions [])

let resolve ~root ~decision ~change ~revision ~tree =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* project, observed =
        match tree with
        | None ->
            let* observed = capture ~root store in
            Ok (checkpoint_observed loaded.Store.project observed, observed)
        | Some path ->
            let* observed = capture ~root:path store in
            Ok (loaded.Store.project, observed)
      in
      let projection = Model.projection project in
      match find_open_decision project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some resolved ->
          let* edits =
            resolved.Model.decision_paths
            |> List.map Model.Path.components
            |> whole_path_edits
          in
          let* replacement =
            make_revision ~author:(Model.creator project) ~change ~revision
              ~parent:None ~base:projection.Model.projection_baseline
              ~result:observed ~edits
          in
          let* project =
            Model.resolve project ~decision ~replacement
            |> Result.map_error (fun error -> Model_error error)
          in
          persist repository loaded project)

let resolve_signed ~authority_epoch ~root ~decision ~change ~revision ~tree
    ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      let* author = local_device collaboration in
      let* authority_epoch =
        authority_epoch_for_new_record ~selected:authority_epoch collaboration
      in
      let store = Store.underlying_store repository in
      let* project, observed =
        match tree with
        | None ->
            let* observed = capture ~root store in
            Ok (checkpoint_observed loaded.Store.project observed, observed)
        | Some path ->
            let* observed = capture ~root:path store in
            Ok (loaded.Store.project, observed)
      in
      let projection = Model.projection project in
      match find_open_decision project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some resolved ->
          let* edits =
            resolved.Model.decision_paths
            |> List.map Model.Path.components
            |> whole_path_edits
          in
          let* replacement =
            make_revision ~author:(Trust.device_id author) ~change ~revision
              ~parent:None ~base:projection.Model.projection_baseline
              ~result:observed ~edits
          in
          let* project =
            Model.resolve project ~decision ~replacement
            |> Result.map_error (fun error -> Model_error error)
          in
          let* signed =
            match authority_epoch with
            | None ->
                Trust.sign_resolution
                  (Store.membership collaboration)
                  ~certificate:(Store.local_certificate collaboration)
                  signing_capability ~decision replacement
                |> Result.map_error (fun error -> Trust_error error)
            | Some (authority, epoch) ->
                Trust.sign_resolution_at authority ~epoch
                  ~certificate:(Store.local_certificate collaboration)
                  signing_capability ~decision replacement
                |> Result.map_error (fun error -> Trust_error error)
          in
          let* collaboration = extend_signed_revisions collaboration signed in
          persist_collaborative repository loaded project collaboration)

let create_package ~root ~destination =
  with_repository ~root (fun repository loaded ->
      let* collaboration = require_collaboration loaded in
      match Store.authority collaboration with
      | None ->
          Package.create
            ~source:(Store.underlying_store repository)
            ~destination
            ~membership:(Store.membership collaboration)
            ~revisions:(Store.signed_revisions collaboration)
          |> Result.map_error (fun error -> Package_error error)
      | Some authority ->
          Package.create_with_authority
            ~source:(Store.underlying_store repository)
            ~destination ~authority
            ~revisions:(Store.signed_revisions collaboration)
            ~authorizations:(Store.authorizations collaboration)
            ~adoptions:(Store.adoptions collaboration)
          |> Result.map_error (fun error -> Package_error error))

let merge_signed_revisions existing incoming =
  let rec add known = function
    | [] -> Ok known
    | signed :: rest -> (
        let revision = Trust.signed_revision_value signed in
        match
          List.find_opt
            (fun candidate ->
              Model.Revision_id.equal
                (Trust.signed_revision_id candidate)
                revision.Model.revision)
            known
        with
        | None -> add (signed :: known) rest
        | Some candidate ->
            if
              Trust.encode_signed_revision candidate
              = Trust.encode_signed_revision signed
            then add known rest
            else
              Error
                (Package_error
                   (Package.Invalid_package
                      "revision identity conflicts with a local signed record"))
        )
  in
  add existing incoming

let merge_public_records ~encode existing incoming =
  let rec add known = function
    | [] -> Ok known
    | record :: rest ->
        let bytes = encode record in
        if
          List.exists
            (fun existing -> String.equal bytes (encode existing))
            known
        then add known rest
        else add (record :: known) rest
  in
  add existing incoming

let selected_authority_head ~selected authority =
  match selected with
  | Some head when Trust.authority_epoch_is_head authority head -> Ok head
  | Some _ ->
      Error
        (Trust_error
           (Trust.Invalid_epoch "the selected authority head is not current"))
  | None -> (
      match Trust.authority_heads authority with
      | [ head ] -> Ok head
      | _ -> Error (Trust_error Trust.Authority_fork))

let review_package ~root ~package =
  with_repository ~root (fun _ loaded ->
      let* collaboration = require_collaboration loaded in
      let* authority =
        match Store.authority collaboration with
        | Some authority -> Ok authority
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch
                    "legacy collaboration has no authority epochs"))
      in
      let* inspected =
        Package.inspect_with_authority ~package ~authority
        |> Result.map_error (fun error -> Package_error error)
      in
      let* authority =
        match Package.authority inspected with
        | Some authority -> Ok authority
        | None ->
            Error
              (Package_error
                 (Package.Invalid_package
                    "authority inspection returned no authority"))
      in
      let rec reviews reversed = function
        | [] -> Ok (List.rev reversed)
        | signed :: rest ->
            let revision = Trust.signed_revision_value signed in
            let* requires_adoption =
              Trust.requires_late_review authority signed
              |> Result.map_error (fun error -> Trust_error error)
            in
            reviews
              ({
                 review_revision = revision.Model.revision;
                 review_author = revision.Model.revision_author;
                 requires_adoption;
               }
              :: reversed)
              rest
      in
      reviews [] (Package.revisions inspected))

let adopt_package_revision ~authority_epoch ~root ~package ~revision
    ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      let* expected_authority =
        match Store.authority existing with
        | Some authority -> Ok authority
        | None ->
            Error
              (Trust_error
                 (Trust.Invalid_epoch
                    "legacy collaboration has no authority epochs"))
      in
      let* inspected =
        Package.inspect_with_authority ~package ~authority:expected_authority
        |> Result.map_error (fun error -> Package_error error)
      in
      let* authority =
        match Package.authority inspected with
        | Some authority -> Ok authority
        | None ->
            Error
              (Package_error
                 (Package.Invalid_package
                    "authority inspection returned no authority"))
      in
      let matching =
        Package.revisions inspected
        |> List.filter (fun signed ->
            Model.Revision_id.equal (Trust.signed_revision_id signed) revision)
      in
      let* signed =
        match matching with
        | [ signed ] -> Ok signed
        | [] ->
            Error
              (Package_error
                 (Package.Invalid_package
                    "the requested revision is absent from the package"))
        | _ ->
            Error
              (Package_error
                 (Package.Invalid_package
                    "the package names the requested revision more than once"))
      in
      let* requires_adoption =
        Trust.requires_late_review authority signed
        |> Result.map_error (fun error -> Trust_error error)
      in
      if not requires_adoption then
        Error
          (Package_error
             (Package.Invalid_package
                "the requested revision does not require a late-arrival \
                 adoption"))
      else
        let* head =
          selected_authority_head ~selected:authority_epoch authority
        in
        let* local_certificate =
          match
            Trust.certificates (Trust.authority_membership authority)
            |> List.find_opt (fun certificate ->
                String.equal
                  (Trust.certificate_id certificate)
                  (Store.local_certificate existing))
          with
          | Some certificate -> Ok certificate
          | None ->
              Error
                (Store_error
                   (Store.Invalid_collaboration_state
                      "local certificate is absent from inspected authority"))
        in
        let local_device = Trust.certificate_subject local_certificate in
        if
          not
            (Trust.authority_device_administrator authority ~epoch:head
               local_device)
        then Error (Trust_error Trust.Unauthorized_epoch_issuer)
        else
          let* adoption =
            Trust.make_adoption authority ~epoch:head
              ~issuer:(Store.local_certificate existing)
              signing_capability ~signed_revision:signed
            |> Result.map_error (fun error -> Trust_error error)
          in
          let* revisions =
            merge_signed_revisions (Store.signed_revisions existing) [ signed ]
          in
          let* adoptions =
            merge_public_records ~encode:Trust.encode_adoption
              (Store.adoptions existing) [ adoption ]
          in
          let* collaboration =
            Store.collaboration_with_authority ~authority ~revisions
              ~local_certificate:(Store.local_certificate existing)
              ~authorizations:(Store.authorizations existing)
              ~adoptions
            |> Result.map_error (fun error -> Store_error error)
          in
          persist_collaborative repository loaded loaded.Store.project
            collaboration)

let receive_package ~root ~package =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      match Store.authority existing with
      | None ->
          let* received =
            Package.verify_and_import
              ~destination:(Store.underlying_store repository)
              ~package
              ~membership:(Store.membership existing)
              ~project:loaded.Store.project
            |> Result.map_error (fun error -> Package_error error)
          in
          let received, project = received in
          let* revisions =
            merge_signed_revisions
              (Store.signed_revisions existing)
              (Package.revisions received)
          in
          let* collaboration =
            Store.collaboration
              ~membership:(Package.membership received)
              ~revisions
              ~local_certificate:(Store.local_certificate existing)
            |> Result.map_error (fun error -> Store_error error)
          in
          persist_collaborative repository loaded project collaboration
      | Some authority ->
          let* received =
            Package.verify_and_import_with_authority
              ~destination:(Store.underlying_store repository)
              ~package ~authority ~known_adoptions:(Store.adoptions existing)
              ~project:loaded.Store.project
            |> Result.map_error (fun error -> Package_error error)
          in
          let received, project = received in
          let* authority =
            match Package.authority received with
            | Some authority -> Ok authority
            | None ->
                Error
                  (Package_error
                     (Package.Invalid_package
                        "authority-aware receive returned no authority"))
          in
          let* revisions =
            merge_signed_revisions
              (Store.signed_revisions existing)
              (Package.revisions received)
          in
          let* authorizations =
            merge_public_records ~encode:Trust.encode_authorization
              (Store.authorizations existing)
              (Package.authorizations received)
          in
          let* adoptions =
            merge_public_records ~encode:Trust.encode_adoption
              (Store.adoptions existing)
              (Package.adoptions received)
          in
          let* collaboration =
            Store.collaboration_with_authority ~authority ~revisions
              ~local_certificate:(Store.local_certificate existing)
              ~authorizations ~adoptions
            |> Result.map_error (fun error -> Store_error error)
          in
          persist_collaborative repository loaded project collaboration)

let receive_transport_batch ~root ~remote ~cursor arrivals =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      let* initial_authority =
        match Store.authority existing with
        | Some authority -> Ok authority
        | None ->
            Error
              (Store_error
                 (Store.Invalid_collaboration_state
                    "relay transport requires authority-aware collaboration"))
      in
      let transport = Store.transport existing in
      let prior_remote = Transport.find_remote transport ~name:remote in
      let known =
        match prior_remote with
        | None -> []
        | Some state -> Transport.remote_known_publications state
      in
      let review_inbox =
        match prior_remote with
        | None -> []
        | Some state -> Transport.remote_review_inbox state
      in
      let known_ids = List.map Transport.reference_id known in
      let arrivals =
        List.filter
          (fun arrival ->
            let publication_id = Transport.publication_id arrival.publication in
            (not (List.mem publication_id known_ids))
            || List.mem publication_id review_inbox)
          arrivals
      in
      let rec inspect_publications authority reversed = function
        | [] -> Ok (List.rev reversed, authority)
        | arrival :: rest ->
            let* artifact =
              Package.read_artifact ~package:arrival.package
              |> Result.map_error (fun error -> Package_error error)
            in
            if
              not
                (String.equal
                   (Transport.sha256 (Package.artifact_manifest artifact))
                   (Transport.publication_manifest arrival.publication))
            then
              Error
                (Transport_error
                   (Transport.Invalid_publication
                      "publication manifest does not match staged package"))
            else
              let* inspected =
                Package.inspect_with_authority ~package:arrival.package
                  ~authority
                |> Result.map_error (fun error -> Package_error error)
              in
              let* package_authority =
                match Package.authority inspected with
                | Some authority -> Ok authority
                | None ->
                    Error
                      (Package_error
                         (Package.Invalid_package
                            "transport package lacks authority closure"))
              in
              let* () =
                Transport.verify_publication ~authority:package_authority
                  arrival.publication
                |> Result.map_error (fun error -> Transport_error error)
              in
              inspect_publications package_authority
                ((arrival, inspected) :: reversed)
                rest
      in
      let* inspected_arrivals, inspected_authority =
        inspect_publications initial_authority [] arrivals
      in
      let* () =
        Transport.validate_feed ~known
          (List.map
             (fun (arrival, _) -> arrival.publication)
             inspected_arrivals)
        |> Result.map_error (fun error -> Transport_error error)
      in
      let existing_signed_purpose signed =
        let revision = Trust.signed_revision_value signed in
        match Trust.signed_revision_resolution signed with
        | None ->
            Model.shared_changes loaded.Store.project
            |> List.concat_map (fun change -> change.Model.revisions)
            |> List.exists (fun existing -> existing = revision)
        | Some decision ->
            Model.resolutions loaded.Store.project
            |> List.exists (fun resolution ->
                Model.Decision_id.equal resolution.Model.resolved_decision
                  decision
                && resolution.Model.replacement_revision = revision)
      in
      let needs_late_review inspected =
        let* authority =
          match Package.authority inspected with
          | Some authority -> Ok authority
          | None ->
              Error
                (Package_error
                   (Package.Invalid_package
                      "transport package lacks authority closure"))
        in
        let rec loop = function
          | [] -> Ok false
          | signed :: rest ->
              if existing_signed_purpose signed then loop rest
              else
                let* requires_review =
                  Trust.requires_late_review authority signed
                  |> Result.map_error (fun error -> Trust_error error)
                in
                if not requires_review then loop rest
                else
                  let accepted_adoptions =
                    Store.adoptions existing @ Package.adoptions inspected
                    |> List.filter (fun adoption ->
                        Trust.adoption_matches_signed_revision adoption signed
                        && Trust.authority_epoch_is_head authority
                             (Trust.adoption_epoch adoption))
                  in
                  if List.length accepted_adoptions = 1 then loop rest
                  else Ok true
        in
        loop (Package.revisions inspected)
      in
      let rec separate_review reversed_normal reversed_deferred = function
        | [] -> Ok (List.rev reversed_normal, List.rev reversed_deferred)
        | (arrival, inspected) :: rest ->
            let* defer = needs_late_review inspected in
            if defer then
              let* _ =
                Package.validate_with_authority ~package:arrival.package
                  ~authority:initial_authority
                |> Result.map_error (fun error -> Package_error error)
              in
              separate_review reversed_normal
                (arrival :: reversed_deferred)
                rest
            else
              separate_review
                (arrival :: reversed_normal)
                reversed_deferred rest
      in
      let* arrivals, deferred_arrivals =
        separate_review [] [] inspected_arrivals
      in
      let before_decisions =
        List.length (Model.projection loaded.Store.project).Model.decisions
      in
      let rec prepare authority project known_adoptions reversed = function
        | [] -> Ok (List.rev reversed, authority, project, known_adoptions)
        | arrival :: rest ->
            let* prepared =
              Package.prepare_with_authority ~package:arrival.package ~authority
                ~known_adoptions ~project
              |> Result.map_error (fun error -> Package_error error)
            in
            let verified = Package.prepared_verified prepared in
            let* authority =
              match Package.authority verified with
              | Some authority -> Ok authority
              | None ->
                  Error
                    (Package_error
                       (Package.Invalid_package
                          "authority transport preparation returned no \
                           authority"))
            in
            let known_adoptions =
              known_adoptions @ Package.adoptions verified
            in
            prepare authority
              (Package.prepared_project prepared)
              known_adoptions (prepared :: reversed) rest
      in
      let* prepared, _prepared_authority, project, _ =
        prepare initial_authority loaded.Store.project
          (Store.adoptions existing) [] arrivals
      in
      let authority = inspected_authority in
      let rec import = function
        | [] -> Ok ()
        | prepared :: rest ->
            let* _ =
              Package.import_prepared
                ~destination:(Store.underlying_store repository)
                prepared
              |> Result.map_error (fun error -> Package_error error)
            in
            import rest
      in
      let* () = import prepared in
      let verified = List.map Package.prepared_verified prepared in
      let* revisions =
        merge_signed_revisions
          (Store.signed_revisions existing)
          (List.concat_map Package.revisions verified)
      in
      let* authorizations =
        merge_public_records ~encode:Trust.encode_authorization
          (Store.authorizations existing)
          (List.concat_map Package.authorizations verified)
      in
      let* adoptions =
        merge_public_records ~encode:Trust.encode_adoption
          (Store.adoptions existing)
          (List.concat_map Package.adoptions verified)
      in
      let incoming_references =
        List.map
          (fun (arrival, _) ->
            Transport.publication_reference arrival.publication)
          inspected_arrivals
      in
      let known =
        List.sort_uniq
          (fun left right ->
            String.compare
              (Transport.reference_id left)
              (Transport.reference_id right))
          (known @ incoming_references)
      in
      let announced_manifests, announced_revisions, previous_review_inbox =
        match prior_remote with
        | None -> ([], [], [])
        | Some state ->
            ( Transport.remote_announced_manifests state,
              Transport.remote_announced_revisions state,
              Transport.remote_review_inbox state )
      in
      let completed_publications =
        List.map
          (fun arrival -> Transport.publication_id arrival.publication)
          arrivals
      in
      let deferred_publications =
        List.map
          (fun arrival -> Transport.publication_id arrival.publication)
          deferred_arrivals
      in
      let review_inbox =
        previous_review_inbox @ deferred_publications
        |> List.filter (fun id -> not (List.mem id completed_publications))
        |> List.sort_uniq String.compare
      in
      let* remote_state =
        Transport.remote_state ~name:remote ~cursor ~known ~announced_manifests
          ~announced_revisions ~review_inbox
        |> Result.map_error (fun error -> Transport_error error)
      in
      let* transport =
        Transport.with_remote transport remote_state
        |> Result.map_error (fun error -> Transport_error error)
      in
      let* collaboration =
        Store.collaboration_with_authority_transport ~transport ~authority
          ~revisions
          ~local_certificate:(Store.local_certificate existing)
          ~authorizations ~adoptions
        |> Result.map_error (fun error -> Store_error error)
      in
      let* _ = persist_collaborative repository loaded project collaboration in
      let after_decisions =
        List.length (Model.projection project).Model.decisions
      in
      Ok
        {
          discovered_publications = List.length inspected_arrivals;
          received_revisions =
            List.fold_left
              (fun count verified ->
                count + List.length (Package.revisions verified))
              0 verified;
          deferred_publications = List.length deferred_arrivals;
          created_decisions = max 0 (after_decisions - before_decisions);
          transport_status = status_of_project project;
        })

let remove_outbound_package destination =
  let objects = Filename.concat destination "objects" in
  (try
     Sys.readdir objects
     |> Array.iter (fun name ->
         try Unix.unlink (Filename.concat objects name)
         with Unix.Unix_error _ -> ());
     Unix.rmdir objects
   with Unix.Unix_error _ | Sys_error _ -> ());
  (try Unix.unlink (Filename.concat destination "manifest.cbor")
   with Unix.Unix_error _ -> ());
  try Unix.rmdir destination with Unix.Unix_error _ -> ()

let with_outbound_directory ~root run =
  try
    let destination =
      Filename.temp_file ~temp_dir:root ".yeokcham-v4-outbound-" ".tmp"
    in
    Unix.unlink destination;
    Fun.protect
      ~finally:(fun () -> remove_outbound_package destination)
      (fun () -> run destination)
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Package_error
         (Package.Io_error
            { path = root; operation; message = Unix.error_message error }))

let revision_ids revisions =
  revisions
  |> List.map Trust.signed_revision_id
  |> List.sort_uniq Model.Revision_id.compare

let revision_is_announced announced signed =
  List.exists
    (fun revision ->
      Model.Revision_id.equal revision (Trust.signed_revision_id signed))
    announced

let prepare_transport_outbound ~root ~remote ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      let* authority =
        match Store.authority existing with
        | Some authority -> Ok authority
        | None ->
            Error
              (Store_error
                 (Store.Invalid_collaboration_state
                    "relay transport requires authority-aware collaboration"))
      in
      let transport = Store.transport existing in
      let prior_remote = Transport.find_remote transport ~name:remote in
      let announced_manifests, announced_revisions, known =
        match prior_remote with
        | None -> ([], [], [])
        | Some state ->
            ( Transport.remote_announced_manifests state,
              Transport.remote_announced_revisions state,
              Transport.remote_known_publications state )
      in
      let unannounced =
        Store.signed_revisions existing
        |> List.filter (fun signed ->
            not (revision_is_announced announced_revisions signed))
      in
      (* Repack all revisions when there is no new revision.  This makes a
         membership or authority-only change observable as a new manifest,
         while an unchanged full closure is skipped by its recorded digest. *)
      let packaged_revisions =
        match unannounced with
        | [] -> Store.signed_revisions existing
        | revisions -> revisions
      in
      let package_authorizations =
        Store.authorizations existing
        |> List.filter (fun authorization ->
            List.exists
              (Trust.authorization_matches_signed_revision authorization)
              packaged_revisions)
      in
      let package_adoptions =
        Store.adoptions existing
        |> List.filter (fun adoption ->
            List.exists
              (Trust.adoption_matches_signed_revision adoption)
              packaged_revisions)
      in
      let* artifact =
        with_outbound_directory ~root (fun destination ->
            let* () =
              Package.create_with_authority
                ~source:(Store.underlying_store repository)
                ~destination ~authority ~revisions:packaged_revisions
                ~authorizations:package_authorizations
                ~adoptions:package_adoptions
              |> Result.map_error (fun error -> Package_error error)
            in
            Package.read_artifact ~package:destination
            |> Result.map_error (fun error -> Package_error error))
      in
      let manifest = Transport.sha256 (Package.artifact_manifest artifact) in
      if List.mem manifest announced_manifests then Ok None
      else
        let* device = local_device existing in
        let certificate = Store.local_certificate existing in
        let parents =
          known
          |> List.filter (fun reference ->
              Model.Device_id.equal
                (Transport.reference_publisher reference)
                (Trust.device_id device)
              && String.equal
                   (Transport.reference_certificate reference)
                   certificate)
          |> List.map Transport.reference_id
          |> List.sort_uniq String.compare
        in
        let* publication =
          Transport.create_publication
            ~repository:
              (Trust.repository (Trust.authority_membership authority))
            ~publisher:device ~certificate ~parents ~manifest
            ~signing_capability
          |> Result.map_error (fun error -> Transport_error error)
        in
        Ok
          (Some
             {
               outbound_publication = publication;
               outbound_artifact = artifact;
               outbound_revisions = revision_ids packaged_revisions;
             }))

let record_transport_outbound ~root ~remote ~publication ~revisions =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      let* authority =
        match Store.authority existing with
        | Some authority -> Ok authority
        | None ->
            Error
              (Store_error
                 (Store.Invalid_collaboration_state
                    "relay transport requires authority-aware collaboration"))
      in
      let* () =
        Transport.verify_publication ~authority publication
        |> Result.map_error (fun error -> Transport_error error)
      in
      let* device = local_device existing in
      if
        (not
           (Model.Device_id.equal
              (Transport.publication_publisher publication)
              (Trust.device_id device)))
        || not
             (String.equal
                (Transport.publication_certificate publication)
                (Store.local_certificate existing))
      then
        Error
          (Transport_error
             (Transport.Invalid_publication
                "cannot record a publication owned by another local device"))
      else
        let transport = Store.transport existing in
        let prior_remote = Transport.find_remote transport ~name:remote in
        let ( cursor,
              known,
              announced_manifests,
              announced_revisions,
              review_inbox ) =
          match prior_remote with
          | None -> (None, [], [], [], [])
          | Some state ->
              ( Transport.remote_cursor state,
                Transport.remote_known_publications state,
                Transport.remote_announced_manifests state,
                Transport.remote_announced_revisions state,
                Transport.remote_review_inbox state )
        in
        let known =
          Transport.publication_reference publication :: known
          |> List.sort_uniq (fun left right ->
              String.compare
                (Transport.reference_id left)
                (Transport.reference_id right))
        in
        let announced_manifests =
          Transport.publication_manifest publication :: announced_manifests
          |> List.sort_uniq String.compare
        in
        let announced_revisions =
          revisions @ announced_revisions
          |> List.sort_uniq Model.Revision_id.compare
        in
        let* remote_state =
          Transport.remote_state ~name:remote ~cursor ~known
            ~announced_manifests ~announced_revisions ~review_inbox
          |> Result.map_error (fun error -> Transport_error error)
        in
        let* transport =
          Transport.with_remote transport remote_state
          |> Result.map_error (fun error -> Transport_error error)
        in
        let* collaboration =
          Store.collaboration_with_authority_transport ~transport ~authority
            ~revisions:(Store.signed_revisions existing)
            ~local_certificate:(Store.local_certificate existing)
            ~authorizations:(Store.authorizations existing)
            ~adoptions:(Store.adoptions existing)
          |> Result.map_error (fun error -> Store_error error)
        in
        let* _ =
          persist_collaborative repository loaded loaded.Store.project
            collaboration
        in
        Ok ())

let transport_cursor ~root ~remote =
  with_repository ~root (fun _ loaded ->
      let* collaboration = require_collaboration loaded in
      match
        Transport.find_remote (Store.transport collaboration) ~name:remote
      with
      | None -> Ok None
      | Some state -> Ok (Transport.remote_cursor state))

let deliver ~root ~id ~next_draft ~next_title =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let* observed = capture ~root store in
      let project = checkpoint_observed loaded.Store.project observed in
      let included =
        List.map
          (fun revision -> revision.Model.revision)
          (Model.projection project).Model.applied
      in
      let created_at = Int64.of_float (Unix.gettimeofday ()) in
      let* project =
        Model.deliver project ~id ~author:(Model.creator project)
          ~snapshot:observed ~included ~next_draft ~next_title ~created_at
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let pin ~root ~checkpoint =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.pin loaded.Store.project ~snapshot:checkpoint
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let unpin ~root ~checkpoint =
  with_repository ~root (fun repository loaded ->
      let* project =
        Model.unpin loaded.Store.project ~snapshot:checkpoint
        |> Result.map_error (fun error -> Model_error error)
      in
      persist repository loaded project)

let published_journal_ids ~root =
  let* journals =
    Journal.scan ~root
    |> Result.map_error (fun error -> Restore_journal_error error)
  in
  let latest =
    List.fold_left
      (fun latest journal ->
        let prior = List.assoc_opt (Journal.operation_id journal) latest in
        match prior with
        | Some current
          when Int64.compare
                 (Journal.generation current)
                 (Journal.generation journal)
               >= 0 ->
            latest
        | Some _ ->
            (Journal.operation_id journal, journal)
            :: List.remove_assoc (Journal.operation_id journal) latest
        | None -> (Journal.operation_id journal, journal) :: latest)
      [] journals
  in
  Ok
    (latest
    |> List.filter (fun (_, journal) ->
        Journal.phase journal = Journal.Published)
    |> List.map fst
    |> List.sort_uniq String.compare)

let compact ~root ~keep_recent ~dry_run =
  with_repository ~root (fun repository loaded ->
      let* journal_snapshots =
        Journal.pending_snapshots ~root
        |> Result.map_error (fun error -> Restore_journal_error error)
      in
      let* compacted =
        Model.compact loaded.Store.project ~keep_recent ~journal_snapshots
        |> Result.map_error (fun error -> Model_error error)
      in
      let* status =
        if dry_run then Ok (status_of_project compacted.Model.project)
        else persist repository loaded compacted.Model.project
      in
      let* pruned_journals =
        if dry_run then published_journal_ids ~root
        else
          Journal.prune_published ~root
          |> Result.map_error (fun error -> Restore_journal_error error)
      in
      Ok
        ({
           kept = compacted.Model.kept;
           dropped = compacted.Model.dropped;
           pruned_journals;
           status;
         }
          : compact_report))
