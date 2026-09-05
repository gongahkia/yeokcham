module Model = Yeokcham_v4_model
module Journal = Yeokcham_v4_restore_journal
module Restore_proof = Yeokcham_v4_restore_proof
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_v4_store
module Trust = Yeokcham_v4_trust
module Package = Yeokcham_v4_package
module Bootstrap = Yeokcham_v4_bootstrap
module Proposal = Yeokcham_v4_proposal
module Recovery = Yeokcham_v4_recovery
module Receipt = Yeokcham_v4_receipt
module Transport = Yeokcham_v4_transport
module Semantic_config = Yeokcham_v4_semantic_config
module Lsp_sidecar = Yeokcham_v4_lsp_sidecar
module Workspace = Yeokcham_v4_workspace

[@@@warning "-40-42"]

module Path_map = Map.Make (struct
  type t = string list

  let compare = List.compare String.compare
end)

module Name_map = Map.Make (String)

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Materialize_error of Snapshot.Materialize.error
  | Restore_journal_error of Journal.error
  | Restore_proof_error of Restore_proof.error
  | Model_error of Model.error
  | Trust_error of Trust.error
  | Package_error of Package.error
  | Bootstrap_error of Bootstrap.error
  | Recovery_error of Recovery.error
  | Transport_error of Transport.error
  | Workspace_error of Workspace.error
  | Workspace_refusal of Workspace.refusal
  | Proposal_error of Proposal.tree_error
  | Proposal_refused of Proposal.refusal list
  | Stale_proposal of {
      decision : Model.Decision_id.t;
      left : Model.Revision_id.t;
      right : Model.Revision_id.t;
      reason : proposal_staleness;
    }
  | Invalid_proposal_tree of string
  | Proposal_destination_inside_worktree of string
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Model.Snapshot_id.t
  | Unchanged_share of Model.Snapshot_id.t
  | Unsigned_project

and proposal_staleness =
  | Decision_not_open
  | Candidate_not_in_decision of Model.Revision_id.t

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

type inspection_state = {
  inspection_project : Model.project;
  inspection_signed_revisions : Trust.signed_revision list;
  inspection_authority : Trust.authority option;
  inspection_review_publications : string list;
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

type decision_proposal = Proposal.t

type semantic_advice =
  | Semantic_not_configured
  | Semantic_multiple_servers of string list
  | Semantic_report of Lsp_sidecar.report

type inspected_decision_proposal = {
  exact_proposal : decision_proposal;
  semantic_advice : semantic_advice;
}

type materialized_proposal = {
  materialized_proposal : decision_proposal;
  proposal_directory : string;
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

type working_tree_comparison = {
  saved_checkpoint : Model.Snapshot_id.t;
  observed_snapshot : Model.Snapshot_id.t;
  differences : path_difference list;
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

type restore_proof = {
  proof_operation : string;
  proof_safety : Model.Snapshot_id.t;
  proof_target : Model.Snapshot_id.t;
}

type storage_root = {
  root_snapshot : Model.Snapshot_id.t;
  root_reasons : Model.protection_reason list;
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

type bootstrap_outbound = {
  bootstrap_basis : Bootstrap.basis;
  bootstrap_artifact : Package.artifact;
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
  restore_operation : string;
  safety_checkpoint : Model.Snapshot_id.t;
  restored_checkpoint : Model.Snapshot_id.t;
  resumed : bool;
}

type workspace_materialization = {
  workspace_basis : Workspace.projection_basis;
  workspace_receipt : Workspace.workspace_projection_receipt;
  workspace_safety_checkpoint : Model.Snapshot_id.t option;
  workspace_restore_proof : string option;
}

type workspace_update =
  | Workspace_already_current of Workspace.workspace_projection_receipt
  | Workspace_updated of workspace_materialization

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Materialize_error error -> Snapshot.Materialize.error_to_string error
  | Restore_journal_error error -> Journal.error_to_string error
  | Restore_proof_error error -> Restore_proof.error_to_string error
  | Model_error error -> Model.error_to_string error
  | Trust_error error -> Trust.error_to_string error
  | Package_error error -> Package.error_to_string error
  | Bootstrap_error error -> Bootstrap.error_to_string error
  | Recovery_error error -> Recovery.error_to_string error
  | Transport_error error -> Transport.error_to_string error
  | Workspace_error error -> Workspace.error_to_string error
  | Workspace_refusal refusal -> Workspace.refusal_to_string refusal
  | Proposal_error error -> Proposal.tree_error_to_string error
  | Proposal_refused refusals ->
      "proposal is refused: "
      ^ String.concat "; " (List.map Proposal.refusal_to_string refusals)
  | Stale_proposal { decision; left; right; reason } -> (
      let pair =
        Printf.sprintf "%s and %s"
          (Model.Revision_id.to_string left)
          (Model.Revision_id.to_string right)
      in
      match reason with
      | Decision_not_open ->
          Printf.sprintf "proposal is stale: decision %s is no longer open (%s)"
            (Model.Decision_id.to_string decision)
            pair
      | Candidate_not_in_decision revision ->
          Printf.sprintf
            "proposal is stale: revision %s is no longer a candidate of \
             decision %s (%s)"
            (Model.Revision_id.to_string revision)
            (Model.Decision_id.to_string decision)
            pair)
  | Invalid_proposal_tree detail -> "invalid exact proposal tree: " ^ detail
  | Proposal_destination_inside_worktree destination ->
      "proposal destination must be outside the live working tree: "
      ^ destination
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

let validate_snapshot_closure store snapshot_id =
  let* leaves = leaves_of_snapshot store snapshot_id in
  Path_map.bindings leaves
  |> List.fold_left
       (fun result (_, (_, content)) ->
         let* () = result in
         Snapshot.Content.load store content
         |> Result.map (fun _ -> ())
         |> Result.map_error (fun error -> Snapshot_error error))
       (Ok ())

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

let tree_id snapshot =
  Snapshot.Snapshot.root snapshot
  |> Snapshot.Tree.stored_object_id |> Yeokcham_store.Stored_object_id.to_hex

let workspace_destination ~root =
  try
    if (Unix.lstat root).Unix.st_kind <> Unix.S_DIR then
      Workspace.Destination_unsafe
    else
      let entries = Sys.readdir root in
      if
        Array.for_all
          (fun name ->
            String.equal name ".yeokcham"
            && (Unix.lstat (Filename.concat root name)).Unix.st_kind
               = Unix.S_DIR)
          entries
      then Workspace.Destination_empty
      else Workspace.Destination_nonempty
  with Unix.Unix_error _ | Sys_error _ -> Workspace.Destination_unsafe

let workspace_basis_and_closure ~root repository loaded =
  let* basis =
    Workspace.read_basis ~root
    |> Result.map_error (fun _ -> Workspace_refusal Workspace.No_verified_basis)
  in
  match basis with
  | None -> Ok (None, Workspace.Closure_complete)
  | Some basis ->
      let* collaboration = require_collaboration loaded in
      let repository_id = Trust.repository (Store.membership collaboration) in
      let projected_snapshot =
        (Model.projection loaded.Store.project).Model.projection_baseline
      in
      if
        (not
           (Trust.Repository_id.equal repository_id
              (Workspace.basis_repository basis)))
        || not
             (Model.Snapshot_id.equal projected_snapshot
                (Workspace.basis_snapshot basis))
      then Error (Workspace_refusal Workspace.No_verified_basis)
      else
        let store = Store.underlying_store repository in
        let* closure =
          match load_snapshot store projected_snapshot with
          | Error _ -> Ok Workspace.Closure_missing
          | Ok snapshot
            when not
                   (String.equal (tree_id snapshot)
                      (Workspace.basis_canonical_tree basis)) ->
              Ok Workspace.Closure_missing
          | Ok snapshot -> (
              match
                ( Snapshot.Materialize.plan store snapshot,
                  validate_snapshot_closure store projected_snapshot )
              with
              | Ok _, Ok () -> Ok Workspace.Closure_complete
              | ( Error
                    ( Snapshot.Materialize.Unsafe_destination_path _
                    | Snapshot.Materialize.Invalid_symlink_target _ ),
                  _ ) ->
                  Error (Workspace_refusal Workspace.Unsafe_path)
              | ( Error
                    ( Snapshot.Materialize.Snapshot_error _
                    | Snapshot.Materialize.Destination_not_directory _
                    | Snapshot.Materialize.Destination_not_empty _
                    | Snapshot.Materialize.Io_error _ ),
                  _ ) ->
                  Ok Workspace.Closure_missing
              | Ok _, Error _ -> Ok Workspace.Closure_missing)
        in
        Ok (Some basis, closure)

let workspace_receipt ~root =
  match Workspace.read_receipt ~root with
  | Ok receipt -> Ok receipt
  | Error _ -> Error (Workspace_refusal Workspace.Receipt_mismatch)

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

let bootstrap_from_package ~root ~repository ~package ~basis ~verify_phrase
    ~username ~initial_draft ~title ~device ~local_certificate =
  let* verified =
    Bootstrap.verify ~repository ~package ~bytes:basis
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  let* root_certificate =
    Bootstrap.root_certificate verified
    |> Result.map_error (fun error -> Bootstrap_error error)
  in
  if
    not
      (String.equal verify_phrase
         (Recovery.verification_phrase root_certificate))
  then
    Error
      (Bootstrap_error
         (Bootstrap.Invalid_basis
            "root verification phrase does not match the authority closure"))
  else
    let basis_id = Bootstrap.verified_id verified in
    let* repository =
      Store.init_collaborative_with ~root ~bootstrap:(fun underlying_store ->
          let* project, collaboration =
            Bootstrap.import ~destination:underlying_store verified
              ~creator:(Trust.device_id device) ~username ~initial_draft ~title
              ~local_certificate
            |> Result.map_error Bootstrap.error_to_string
          in
          let projected_snapshot =
            (Model.projection project).Model.projection_baseline
          in
          let* snapshot =
            load_snapshot underlying_store projected_snapshot
            |> Result.map_error error_to_string
          in
          let canonical_tree = tree_id snapshot in
          let* workspace_basis =
            Workspace.make_projection_basis ~repository
              ~imported_basis_id:basis_id ~snapshot:projected_snapshot
              ~canonical_tree ~source_fingerprint:canonical_tree
            |> Result.map_error Workspace.error_to_string
          in
          Workspace.write_basis ~root workspace_basis
          |> Result.map_error Workspace.error_to_string
          |> Result.map (fun () -> (project, collaboration)))
      |> Result.map_error (fun error -> Store_error error)
    in
    let* loaded =
      Store.load repository |> Result.map_error (fun error -> Store_error error)
    in
    Ok (status_of_project loaded.Store.project)

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

let inspection_state ~root =
  with_repository ~root (fun _ loaded ->
      let ( inspection_signed_revisions,
            inspection_authority,
            inspection_review_publications ) =
        match loaded.Store.collaboration with
        | None -> ([], None, [])
        | Some collaboration ->
            let review_publications =
              Store.transport collaboration
              |> Transport.remotes
              |> List.concat_map Transport.remote_review_inbox
              |> List.sort_uniq String.compare
            in
            ( Store.signed_revisions collaboration,
              Store.authority collaboration,
              review_publications )
      in
      Ok
        {
          inspection_project = loaded.Store.project;
          inspection_signed_revisions;
          inspection_authority;
          inspection_review_publications;
        })

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

let ensure_retained project snapshot =
  if retained project snapshot then Ok ()
  else Error (Unknown_checkpoint snapshot)

let ensure_restore_proof ~root store journal =
  let* () = validate_snapshot_closure store (Journal.safety journal) in
  let* () = validate_snapshot_closure store (Journal.target journal) in
  let* proof =
    Restore_proof.make
      ~operation_id:(Journal.operation_id journal)
      ~safety:(Journal.safety journal) ~target:(Journal.target journal)
    |> Result.map_error (fun error -> Restore_proof_error error)
  in
  Restore_proof.append ~root proof
  |> Result.map_error (fun error -> Restore_proof_error error)

let latest_journals journals =
  List.fold_left
    (fun latest journal ->
      match List.assoc_opt (Journal.operation_id journal) latest with
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

let proof_matches_journal proof journal =
  String.equal (Restore_proof.operation_id proof) (Journal.operation_id journal)
  && Model.Snapshot_id.equal
       (Restore_proof.safety proof)
       (Journal.safety journal)
  && Model.Snapshot_id.equal
       (Restore_proof.target proof)
       (Journal.target journal)

let retention_inputs ~root =
  let* journals =
    Journal.scan ~root
    |> Result.map_error (fun error -> Restore_journal_error error)
  in
  let* proofs =
    Restore_proof.scan ~root
    |> Result.map_error (fun error -> Restore_proof_error error)
  in
  let latest = latest_journals journals |> List.map snd in
  let journal_roots =
    latest
    |> List.filter (fun journal ->
        Journal.phase journal <> Journal.Published
        || not
             (List.exists
                (fun proof -> proof_matches_journal proof journal)
                proofs))
    |> List.concat_map (fun journal ->
        [ Journal.safety journal; Journal.target journal ])
    |> List.sort_uniq Model.Snapshot_id.compare
  in
  Ok (latest, proofs, journal_roots)

let validate_retention_inputs ~store ~project ~journal_roots proofs =
  let roots =
    List.sort_uniq Model.Snapshot_id.compare
      (journal_roots @ Restore_proof.snapshots proofs)
  in
  List.fold_left
    (fun result snapshot ->
      let* () = result in
      let* () = ensure_retained project snapshot in
      validate_snapshot_closure store snapshot)
    (Ok ()) roots

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
        let* () =
          Yeokcham_store.with_lock store ~name:"restore-retention"
            ~on_error:(fun error -> Store_error (Store.Store_error error))
            (fun () -> ensure_restore_proof ~root store materialized)
        in
        let* _ = advance_journal ~root materialized Journal.Published in
        Ok ()
    | Journal.Published -> Ok ()
    | Journal.Prepared | Journal.Applying -> assert false
  in
  Ok
    {
      restore_operation = Journal.operation_id journal;
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

let workspace_materialization_of_plan plan restored =
  let basis = Workspace.plan_basis plan in
  let receipt = Workspace.plan_receipt plan in
  match restored with
  | None ->
      {
        workspace_basis = basis;
        workspace_receipt = receipt;
        workspace_safety_checkpoint = None;
        workspace_restore_proof = None;
      }
  | Some restored ->
      {
        workspace_basis = basis;
        workspace_receipt = receipt;
        workspace_safety_checkpoint = Some restored.safety_checkpoint;
        workspace_restore_proof = Some restored.restore_operation;
      }

let materialize_workspace_plan ~root plan =
  let receipt = Workspace.plan_receipt plan in
  let checkpoint = Workspace.basis_snapshot (Workspace.plan_basis plan) in
  let* observed =
    with_repository ~root (fun repository _ ->
        capture ~root (Store.underlying_store repository))
  in
  let* staged =
    Workspace.stage_receipt ~root receipt
    |> Result.map_error (fun error -> Workspace_error error)
  in
  let restored =
    if Model.Snapshot_id.equal observed checkpoint then Ok None
    else restore_in_place ~root ~checkpoint |> Result.map Option.some
  in
  match restored with
  | Error error ->
      Workspace.discard_staged_receipt staged;
      Error error
  | Ok restored -> (
      match Workspace.publish_staged_receipt staged with
      | Ok () -> Ok (workspace_materialization_of_plan plan restored)
      | Error receipt_error -> (
          Workspace.discard_staged_receipt staged;
          let rollback =
            match restored with
            | None -> Ok ()
            | Some restored ->
                restore_in_place ~root ~checkpoint:restored.safety_checkpoint
                |> Result.map (fun _ -> ())
          in
          match rollback with
          | Ok () -> Error (Workspace_error receipt_error)
          | Error rollback_error -> Error rollback_error))

let materialize_workspace_activation ~root plan =
  let receipt = Workspace.plan_receipt plan in
  let checkpoint = Workspace.basis_snapshot (Workspace.plan_basis plan) in
  let* staged =
    Workspace.stage_receipt ~root receipt
    |> Result.map_error (fun error -> Workspace_error error)
  in
  let materialized =
    with_repository ~root (fun repository _ ->
        let store = Store.underlying_store repository in
        let* target = load_snapshot store checkpoint in
        Snapshot.Materialize.write_replacing ~destination:root
          ~preserved_root_names:[ ".yeokcham"; ".git" ] store target
        |> Result.map_error (fun error -> Materialize_error error))
  in
  match materialized with
  | Error error -> Error error
  | Ok () ->
      Workspace.publish_staged_receipt staged
      |> Result.map_error (fun error -> Workspace_error error)
      |> Result.map (fun () -> workspace_materialization_of_plan plan None)

let workspace_activate ~root =
  let* plan =
    with_repository ~root (fun repository loaded ->
        let* basis, closure =
          workspace_basis_and_closure ~root repository loaded
        in
        let* plan =
          Workspace.activate ~basis ~closure
            ~destination:Workspace.Destination_empty
          |> Result.map_error (fun refusal -> Workspace_refusal refusal)
        in
        match workspace_destination ~root with
        | Workspace.Destination_empty -> Ok plan
        | Workspace.Destination_unsafe ->
            Error (Workspace_refusal Workspace.Unsafe_path)
        | Workspace.Destination_nonempty -> (
            let* pending =
              Workspace.read_staged_receipt ~root
              |> Result.map_error (fun error -> Workspace_error error)
            in
            match pending with
            | Some receipt
              when Workspace.receipt_equal receipt (Workspace.plan_receipt plan)
              ->
                Ok plan
            | Some _ | None ->
                Error (Workspace_refusal Workspace.Nonempty_destination)))
  in
  materialize_workspace_activation ~root plan

let workspace_update ~root ~replace =
  let* update =
    with_repository ~root (fun repository loaded ->
        let* basis, closure =
          workspace_basis_and_closure ~root repository loaded
        in
        let* receipt = workspace_receipt ~root in
        let store = Store.underlying_store repository in
        let* observed_snapshot = capture ~root store in
        let* observed =
          load_snapshot store observed_snapshot
          |> Result.map_error (fun _ ->
              Workspace_refusal Workspace.Missing_closure)
        in
        let canonical_tree = tree_id observed in
        let* observed =
          Workspace.make_observed_tree ~canonical_tree
            ~source_fingerprint:canonical_tree
          |> Result.map_error (fun error -> Workspace_error error)
        in
        Workspace.plan_update ~basis ~receipt ~closure ~observed ~replace
        |> Result.map_error (fun refusal -> Workspace_refusal refusal))
  in
  match update with
  | Workspace.Already_current receipt -> Ok (Workspace_already_current receipt)
  | Workspace.Update plan ->
      materialize_workspace_plan ~root plan
      |> Result.map (fun materialized -> Workspace_updated materialized)

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

let require_proposal_destination_outside_worktree ~root ~destination =
  let realpath path =
    try Ok (Unix.realpath path)
    with Unix.Unix_error (error, operation, _) ->
      Error
        (Materialize_error
           (Snapshot.Materialize.Io_error
              { path; operation; message = Unix.error_message error }))
  in
  let* root = realpath root in
  let* destination = realpath destination in
  let nested =
    if String.equal root Filename.dir_sep then
      String.starts_with ~prefix:Filename.dir_sep destination
    else String.starts_with ~prefix:(root ^ Filename.dir_sep) destination
  in
  if String.equal root destination || nested then
    Error (Proposal_destination_inside_worktree destination)
  else Ok ()

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

type proposal_source = {
  proposal_tree : Proposal.tree;
  exact_entries : Snapshot.Tree.entry Path_map.t;
}

type prepared_decision_proposal = {
  prepared_proposal : Proposal.t;
  prepared_base : proposal_source;
  prepared_left : proposal_source;
  prepared_right : proposal_source;
}

let proposal_entry_of_tree_entry = function
  | Snapshot.Tree.File { mode; content } ->
      Proposal.File
        {
          mode;
          content =
            content |> Snapshot.Content.stored_object_id
            |> Yeokcham_store.Stored_object_id.to_hex;
        }
  | Snapshot.Tree.Directory _ -> Proposal.Directory

let rec collect_proposal_source_entries store prefix tree_id entries =
  let* tree =
    Snapshot.Tree.load store tree_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let rec walk entries = function
    | [] -> Ok entries
    | (name, entry) :: rest ->
        let path = prefix @ [ name ] in
        let entries = Path_map.add path entry entries in
        let* entries =
          match entry with
          | Snapshot.Tree.File _ -> Ok entries
          | Snapshot.Tree.Directory child ->
              collect_proposal_source_entries store path child entries
        in
        walk entries rest
  in
  walk entries (Snapshot.Tree.entries tree)

let proposal_tree_of_entries entries =
  let rec paths reversed = function
    | [] -> Ok (List.rev reversed)
    | (components, entry) :: rest ->
        let* path =
          Model.Path.of_components components
          |> Result.map_error (fun error -> Model_error error)
        in
        paths ((path, proposal_entry_of_tree_entry entry) :: reversed) rest
  in
  let* entries = Path_map.bindings entries |> paths [] in
  Proposal.tree_of_entries entries
  |> Result.map_error (fun error -> Proposal_error error)

let proposal_source_of_snapshot store snapshot_id =
  let* snapshot = load_snapshot store snapshot_id in
  let* exact_entries =
    collect_proposal_source_entries store []
      (Snapshot.Snapshot.root snapshot)
      Path_map.empty
  in
  let* proposal_tree = proposal_tree_of_entries exact_entries in
  Ok { proposal_tree; exact_entries }

let canonical_proposal_pair left right =
  if Model.Revision_id.compare left.Model.revision right.Model.revision <= 0
  then (left, right)
  else (right, left)

let stale_proposal ~decision ~left ~right reason =
  Error (Stale_proposal { decision; left; right; reason })

let prepare_decision_proposal repository loaded ~decision ~left ~right =
  match find_open_decision loaded.Store.project decision with
  | None -> stale_proposal ~decision ~left ~right Decision_not_open
  | Some found -> (
      match (decision_revision found left, decision_revision found right) with
      | None, _ ->
          stale_proposal ~decision ~left ~right (Candidate_not_in_decision left)
      | _, None ->
          stale_proposal ~decision ~left ~right
            (Candidate_not_in_decision right)
      | Some left, Some right ->
          let left, right = canonical_proposal_pair left right in
          let store = Store.underlying_store repository in
          let* prepared_base =
            proposal_source_of_snapshot store left.Model.base_snapshot
          in
          let* prepared_left =
            proposal_source_of_snapshot store left.Model.result_snapshot
          in
          let* prepared_right =
            proposal_source_of_snapshot store right.Model.result_snapshot
          in
          let current_baseline =
            (Model.projection loaded.Store.project).Model.projection_baseline
          in
          let prepared_proposal =
            Proposal.classify ~decision ~current_baseline ~left ~right
              ~base:prepared_base.proposal_tree
              ~left_tree:prepared_left.proposal_tree
              ~right_tree:prepared_right.proposal_tree
          in
          Ok { prepared_proposal; prepared_base; prepared_left; prepared_right }
      )

let proposal_pairs ~root ~decision =
  with_repository ~root (fun _ loaded ->
      match find_open_decision loaded.Store.project decision with
      | None -> Error (Model_error Model.Unknown_decision)
      | Some found ->
          let revisions = unique_candidate_revisions found in
          let rec pairs reversed = function
            | [] -> List.rev reversed
            | left :: rest ->
                let reversed =
                  List.fold_left
                    (fun reversed right ->
                      (left.Model.revision, right.Model.revision) :: reversed)
                    reversed rest
                in
                pairs reversed rest
          in
          Ok (pairs [] revisions))

let propose_decision ~root ~decision ~left ~right =
  with_repository ~root (fun repository loaded ->
      prepare_decision_proposal repository loaded ~decision ~left ~right
      |> Result.map (fun prepared -> prepared.prepared_proposal))

let changed_semantic_paths (proposal : Proposal.t) =
  proposal.Proposal.paths
  |> List.filter_map (fun path ->
      if
        path.Proposal.base = path.Proposal.left
        && path.Proposal.base = path.Proposal.right
      then None
      else Some (Model.Path.to_string path.Proposal.path))
  |> List.sort_uniq String.compare

let inspect_decision_proposal ~root ~decision ~left ~right ~semantic_server =
  with_repository ~root (fun repository loaded ->
      let* prepared =
        prepare_decision_proposal repository loaded ~decision ~left ~right
      in
      let exact_proposal = prepared.prepared_proposal in
      let unavailable reason =
        Semantic_report
          (Lsp_sidecar.Unavailable { server = "configuration"; reason })
      in
      let semantic_advice =
        match Semantic_config.list ~root with
        | Error error -> unavailable (Semantic_config.error_to_string error)
        | Ok servers -> (
            let paths = changed_semantic_paths exact_proposal in
            let matching =
              List.filter
                (fun (server : Semantic_config.server) ->
                  server.enabled
                  && List.exists (Semantic_config.matches_path server) paths)
                servers
            in
            let selected =
              match semantic_server with
              | None -> (
                  match matching with
                  | [] -> `No_server
                  | [ server ] -> `Server server
                  | servers ->
                      `Several
                        (List.map
                           (fun (server : Semantic_config.server) ->
                             server.name)
                           servers))
              | Some name -> (
                  match
                    List.find_opt
                      (fun (server : Semantic_config.server) ->
                        String.equal server.name name)
                      servers
                  with
                  | None -> `Unavailable ("unknown semantic server: " ^ name)
                  | Some server when not server.enabled ->
                      `Unavailable ("semantic server is disabled: " ^ name)
                  | Some server -> `Server server)
            in
            match selected with
            | `No_server -> Semantic_not_configured
            | `Several names -> Semantic_multiple_servers names
            | `Unavailable reason -> unavailable reason
            | `Server server ->
                let store = Store.underlying_store repository in
                let provenance = exact_proposal.Proposal.provenance in
                let report =
                  match
                    ( load_snapshot store provenance.left_base,
                      load_snapshot store provenance.left_result,
                      load_snapshot store provenance.right_result )
                  with
                  | Ok base, Ok left, Ok right ->
                      Lsp_sidecar.inspect ~store ~server
                        ~base:
                          ( Model.Snapshot_id.to_string provenance.left_base,
                            base )
                        ~left:
                          ( Model.Snapshot_id.to_string provenance.left_result,
                            left )
                        ~right:
                          ( Model.Snapshot_id.to_string provenance.right_result,
                            right )
                        ~paths
                  | Error error, _, _ | _, Error error, _ | _, _, Error error ->
                      Lsp_sidecar.Unavailable
                        {
                          server = server.name;
                          reason =
                            "cannot load named snapshot: "
                            ^ error_to_string error;
                        }
                in
                Semantic_report report)
      in
      Ok { exact_proposal; semantic_advice })

type selected_tree_entry =
  | Selected_file of Snapshot.file_mode * Snapshot.Content.id
  | Selected_directory

type selected_tree_group = {
  direct : selected_tree_entry option;
  descendants : (string list * selected_tree_entry) list;
}

let source_entries prepared = function
  | Proposal.Base -> prepared.prepared_base.exact_entries
  | Proposal.Left -> prepared.prepared_left.exact_entries
  | Proposal.Right -> prepared.prepared_right.exact_entries

let selected_tree_entry_of_source source_entry =
  match source_entry with
  | Snapshot.Tree.File { mode; content } -> Selected_file (mode, content)
  | Snapshot.Tree.Directory _ -> Selected_directory

let selected_tree_entries prepared =
  match Proposal.selected prepared.prepared_proposal with
  | None ->
      Error
        (Proposal_refused
           (match prepared.prepared_proposal.Proposal.readiness with
           | Proposal.Ready -> []
           | Proposal.Refused refusals -> refusals))
  | Some selected ->
      List.fold_left
        (fun entries (path, source, expected) ->
          let* entries = entries in
          match expected with
          | None -> Ok entries
          | Some expected -> (
              let components = Model.Path.components path in
              let exact_entries = source_entries prepared source in
              match Path_map.find_opt components exact_entries with
              | None ->
                  Error
                    (Invalid_proposal_tree
                       ("selected source entry disappeared at "
                      ^ Model.Path.to_string path))
              | Some source_entry ->
                  let actual = proposal_entry_of_tree_entry source_entry in
                  if actual <> expected then
                    Error
                      (Invalid_proposal_tree
                         ("selected source entry changed at "
                        ^ Model.Path.to_string path))
                  else
                    Ok
                      ((components, selected_tree_entry_of_source source_entry)
                      :: entries)))
        (Ok []) selected
      |> Result.map List.rev

let group_selected_tree_entries entries =
  List.fold_left
    (fun groups (components, entry) ->
      let* groups = groups in
      match components with
      | [] -> Error (Invalid_proposal_tree "proposal selected the tree root")
      | name :: rest ->
          let group =
            Option.value
              (Name_map.find_opt name groups)
              ~default:{ direct = None; descendants = [] }
          in
          let* group =
            match rest with
            | [] -> (
                match group.direct with
                | None -> Ok { group with direct = Some entry }
                | Some _ ->
                    Error
                      (Invalid_proposal_tree
                         ("proposal selected a path twice: " ^ name)))
            | _ ->
                Ok
                  {
                    group with
                    descendants = (rest, entry) :: group.descendants;
                  }
          in
          Ok (Name_map.add name group groups))
    (Ok Name_map.empty) entries

let rec store_selected_tree store entries =
  let* groups = group_selected_tree_entries entries in
  let rec make_entries reversed = function
    | [] ->
        Snapshot.Tree.create (List.rev reversed)
        |> Result.map_error (fun error -> Snapshot_error error)
    | (name, group) :: rest ->
        let* entry =
          match group.direct with
          | None ->
              Error
                (Invalid_proposal_tree
                   ("proposal omitted a directory entry for " ^ name))
          | Some (Selected_file (mode, content)) ->
              if group.descendants <> [] then
                Error
                  (Invalid_proposal_tree
                     ("proposal selects both a file and descendants at " ^ name))
              else Ok (Snapshot.Tree.File { mode; content })
          | Some Selected_directory ->
              let* child =
                store_selected_tree store (List.rev group.descendants)
              in
              Ok (Snapshot.Tree.Directory child)
        in
        make_entries ((name, entry) :: reversed) rest
  in
  let* tree = make_entries [] (Name_map.bindings groups) in
  Snapshot.Tree.store store tree
  |> Result.map_error (fun error -> Snapshot_error error)

let materialize_decision_proposal ~root ~decision ~left ~right ~destination =
  with_repository ~root (fun repository loaded ->
      let* prepared =
        prepare_decision_proposal repository loaded ~decision ~left ~right
      in
      let* entries = selected_tree_entries prepared in
      let* () = require_empty_directory destination in
      let* () =
        require_proposal_destination_outside_worktree ~root ~destination
      in
      let store = Store.underlying_store repository in
      let* root = store_selected_tree store entries in
      let snapshot = Snapshot.Snapshot.create ~root in
      let* () =
        Snapshot.Materialize.write ~destination store snapshot
        |> Result.map_error (fun error -> Materialize_error error)
      in
      Ok
        {
          materialized_proposal = prepared.prepared_proposal;
          proposal_directory = destination;
        })

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

let inspect_working_tree ~root =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      let saved_checkpoint =
        (Model.active_draft loaded.Store.project).Model.latest_checkpoint
      in
      let* observed_snapshot = capture ~root store in
      let* differences =
        comparison_differences store ~before:saved_checkpoint
          ~after:observed_snapshot
      in
      Ok { saved_checkpoint; observed_snapshot; differences })

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

let _receive_package_pre_receipt ~root ~package =
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

let _receive_transport_batch_pre_receipt ~root ~remote ~cursor arrivals =
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

let error_of_receipt = function
  | Receipt.Store_error error -> Store_error error
  | Receipt.Model_error error -> Model_error error
  | Receipt.Trust_error error -> Trust_error error
  | Receipt.Package_error error -> Package_error error
  | Receipt.Transport_error error -> Transport_error error
  | Receipt.Unsigned_project -> Unsigned_project

let status_of_receipt (status : Receipt.status) =
  {
    creator = status.Receipt.creator;
    active_draft = status.Receipt.active_draft;
    checkpoint = status.Receipt.checkpoint;
    shared_changes = status.Receipt.shared_changes;
    shared_change_count = status.Receipt.shared_change_count;
    open_decisions = status.Receipt.open_decisions;
    deliveries = status.Receipt.deliveries;
    delivery_count = status.Receipt.delivery_count;
    checkpoints = status.Receipt.checkpoints;
    usernames = status.Receipt.usernames;
    uncaptured = status.Receipt.uncaptured;
  }

let receive_package ~root ~package =
  Receipt.receive_package ~root ~package
  |> Result.map status_of_receipt
  |> Result.map_error error_of_receipt

let receive_transport_batch ~root ~remote ~cursor arrivals =
  let arrivals : Receipt.transport_arrival list =
    List.map
      (fun (arrival : transport_arrival) ->
        ({
           Receipt.publication = arrival.publication;
           package = arrival.package;
         }
          : Receipt.transport_arrival))
      arrivals
  in
  Receipt.receive_transport_batch ~root ~remote ~cursor arrivals
  |> Result.map (fun received ->
      {
        discovered_publications = received.Receipt.discovered_publications;
        received_revisions = received.Receipt.received_revisions;
        deferred_publications = received.Receipt.deferred_publications;
        created_decisions = received.Receipt.created_decisions;
        transport_status = status_of_receipt received.Receipt.transport_status;
      })
  |> Result.map_error error_of_receipt

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
    let destination = Filename.temp_file "yeokcham-v4-outbound-" ".tmp" in
    Unix.unlink destination;
    match run destination with
    | Ok value -> Ok (value, destination)
    | Error error ->
        remove_outbound_package destination;
        Error error
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

let prepare_bootstrap_outbound ~root ~signing_capability =
  with_repository ~root (fun repository loaded ->
      let* existing = require_collaboration loaded in
      let* authority =
        match Store.authority existing with
        | Some authority -> Ok authority
        | None ->
            Error
              (Store_error
                 (Store.Invalid_collaboration_state
                    "bootstrap requires authority-aware collaboration"))
      in
      let* publisher = local_device existing in
      with_outbound_directory ~root (fun destination ->
          Bootstrap.create
            ~source:(Store.underlying_store repository)
            ~destination ~project:loaded.Store.project ~authority
            ~revisions:(Store.signed_revisions existing)
            ~authorizations:(Store.authorizations existing)
            ~adoptions:(Store.adoptions existing) ~publisher
            ~certificate:(Store.local_certificate existing)
            ~signing_capability
          |> Result.map_error (fun error -> Bootstrap_error error))
      |> Result.map (fun ((bootstrap_basis, bootstrap_artifact), destination) ->
          {
            bootstrap_basis;
            bootstrap_artifact =
              Package.claim_artifact bootstrap_artifact ~cleanup:(fun () ->
                  remove_outbound_package destination);
          }))

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
      let* artifact, destination =
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
      let artifact =
        Package.claim_artifact artifact ~cleanup:(fun () ->
            remove_outbound_package destination)
      in
      let manifest = Transport.sha256 (Package.artifact_manifest artifact) in
      if List.mem manifest announced_manifests then (
        Package.dispose_artifact artifact;
        Ok None)
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

let restore_proof_of_record proof =
  {
    proof_operation = Restore_proof.operation_id proof;
    proof_safety = Restore_proof.safety proof;
    proof_target = Restore_proof.target proof;
  }

let restore_proofs ~root =
  Restore_proof.scan ~root
  |> Result.map (List.map restore_proof_of_record)
  |> Result.map_error (fun error -> Restore_proof_error error)

let retain_restore_proof ~root ~operation =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      Yeokcham_store.with_lock store ~name:"restore-retention"
        ~on_error:(fun error -> Store_error (Store.Store_error error))
        (fun () ->
          let* journals =
            Journal.scan ~root
            |> Result.map_error (fun error -> Restore_journal_error error)
          in
          match List.assoc_opt operation (latest_journals journals) with
          | None ->
              Error
                (Restore_journal_error
                   (Journal.Invalid_schema "restore operation has no journal"))
          | Some journal when Journal.phase journal <> Journal.Published ->
              Error
                (Restore_journal_error
                   (Journal.Invalid_schema
                      "only a completed restore journal can be retained"))
          | Some journal ->
              let* () =
                ensure_retained loaded.Store.project (Journal.safety journal)
              in
              let* () =
                ensure_retained loaded.Store.project (Journal.target journal)
              in
              let* () = ensure_restore_proof ~root store journal in
              let* proof =
                Restore_proof.find ~root ~operation_id:operation
                |> Result.map_error (fun error -> Restore_proof_error error)
              in
              Ok (restore_proof_of_record proof)))

let forget_restore_proof ~root ~operation =
  with_repository ~root (fun repository _loaded ->
      let store = Store.underlying_store repository in
      Yeokcham_store.with_lock store ~name:"restore-retention"
        ~on_error:(fun error -> Store_error (Store.Store_error error))
        (fun () ->
          Restore_proof.forget ~root ~operation_id:operation
          |> Result.map_error (fun error -> Restore_proof_error error)))

let storage_roots ~root =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      Yeokcham_store.with_lock store ~name:"restore-retention"
        ~on_error:(fun error -> Store_error (Store.Store_error error))
        (fun () ->
          let* _latest, proofs, journal_roots = retention_inputs ~root in
          let* () =
            validate_retention_inputs ~store ~project:loaded.Store.project
              ~journal_roots proofs
          in
          Model.compact loaded.Store.project ~keep_recent:0
            ~journal_snapshots:journal_roots
            ~proof_snapshots:(Restore_proof.snapshots proofs)
          |> Result.map (fun compacted ->
              List.map
                (fun keep ->
                  {
                    root_snapshot = keep.Model.snapshot;
                    root_reasons = keep.Model.reasons;
                  })
                compacted.Model.kept)
          |> Result.map_error (fun error -> Model_error error)))

let compact ~root ~keep_recent ~dry_run =
  with_repository ~root (fun repository loaded ->
      let store = Store.underlying_store repository in
      Yeokcham_store.with_lock store ~name:"restore-retention"
        ~on_error:(fun error -> Store_error (Store.Store_error error))
        (fun () ->
          let* latest, proofs, journal_roots = retention_inputs ~root in
          let* () =
            validate_retention_inputs ~store ~project:loaded.Store.project
              ~journal_roots proofs
          in
          let* compacted =
            Model.compact loaded.Store.project ~keep_recent
              ~journal_snapshots:journal_roots
              ~proof_snapshots:(Restore_proof.snapshots proofs)
            |> Result.map_error (fun error -> Model_error error)
          in
          let matching_published =
            latest
            |> List.filter (fun journal ->
                Journal.phase journal = Journal.Published
                && List.exists
                     (fun proof -> proof_matches_journal proof journal)
                     proofs)
            |> List.map Journal.operation_id
            |> List.sort_uniq String.compare
          in
          let* status =
            if dry_run then Ok (status_of_project compacted.Model.project)
            else persist repository loaded compacted.Model.project
          in
          let* pruned_journals =
            if dry_run then Ok matching_published
            else
              Journal.prune_published ~root ~operations:matching_published
              |> Result.map_error (fun error -> Restore_journal_error error)
          in
          Ok
            ({
               kept = compacted.Model.kept;
               dropped = compacted.Model.dropped;
               pruned_journals;
               status;
             }
              : compact_report)))
