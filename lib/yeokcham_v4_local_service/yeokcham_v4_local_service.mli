(** Local V4 saved-work transitions and verified offline-package receive.

    This adapter has no network transport or semantic merge behaviour. Command
    `status` and `save` scan exact snapshots when invoked. Linux `watch` lives
    in the CLI and only calls `save` after debounce; it is not part of this
    module. *)

type error =
  | Store_error of Yeokcham_v4_store.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Materialize_error of Yeokcham_snapshot.Materialize.error
  | Restore_journal_error of Yeokcham_v4_restore_journal.error
  | Model_error of Yeokcham_v4_model.error
  | Trust_error of Yeokcham_v4_trust.error
  | Package_error of Yeokcham_v4_package.error
  | Recovery_error of Yeokcham_v4_recovery.error
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Yeokcham_v4_model.Snapshot_id.t
  | Unchanged_share of Yeokcham_v4_model.Snapshot_id.t
  | Unsigned_project

type status = {
  creator : Yeokcham_v4_model.Device_id.t;
  active_draft : Yeokcham_v4_model.draft;
  checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  shared_changes : Yeokcham_v4_model.shared_change list;
  shared_change_count : int;
  open_decisions : Yeokcham_v4_model.decision list;
  deliveries : Yeokcham_v4_model.delivery list;
  delivery_count : int;
  checkpoints : Yeokcham_v4_model.checkpoint list;
  usernames : Yeokcham_v4_model.username_registration list;
  uncaptured : bool;
}

type identity = {
  repository : Yeokcham_v4_trust.Repository_id.t;
  device : Yeokcham_v4_trust.device;
  role : Yeokcham_v4_trust.role;
}

type materialized_candidate = {
  revision : Yeokcham_v4_model.Revision_id.t;
  author : Yeokcham_v4_model.Device_id.t;
  username : Yeokcham_v4_model.Username.t option;
  directory : string;
}
(** A read-only candidate tree created for an open decision. [directory] is a
    generated child of the requested destination, not an identifier-derived
    path. *)

type snapshot_entry_kind = File | Directory

type snapshot_entry = {
  kind : snapshot_entry_kind;
  mode : Yeokcham_snapshot.file_mode option;
  content : string option;
}
(** A byte-safe description of one path in an exact snapshot. [content] is the
    canonical object identity of a file's bytes; it is absent for directories.
    No textual diff is attempted, so binary files remain inspectable. *)

type path_difference = {
  path : Yeokcham_v4_model.Path.t;
  before : snapshot_entry option;
  after : snapshot_entry option;
}

type comparison_target =
  | Baseline
  | Candidate of Yeokcham_v4_model.Revision_id.t

type decision_comparison = {
  compared_decision : Yeokcham_v4_model.decision;
  compared_candidate : Yeokcham_v4_model.change_revision;
  against : Yeokcham_v4_model.Snapshot_id.t;
  differences : path_difference list;
}
(** An entirely read-only comparison between an open decision candidate and
    either the current projection baseline or another candidate in the same
    decision. *)

type inspected_candidate = {
  inspected_revision : Yeokcham_v4_model.change_revision;
  inspected_username : Yeokcham_v4_model.Username.t option;
}

type decision_inspection = {
  inspected_decision : Yeokcham_v4_model.decision;
  inspected_candidates : inspected_candidate list;
}

type package_review = {
  review_revision : Yeokcham_v4_model.Revision_id.t;
  review_author : Yeokcham_v4_model.Device_id.t;
  requires_adoption : bool;
}
(** Public, read-only package review data. A positive [requires_adoption] means
    a current authority head has revoked the historical signer, so this exact
    signed record cannot be received without an administrator's later adoption.
*)

type save_outcome = Unchanged of status | Saved of status

type compact_report = {
  kept : Yeokcham_v4_model.compact_keep list;
  dropped : Yeokcham_v4_model.Snapshot_id.t list;
  pruned_journals : string list;
  status : status;
}

module Capture_window : sig
  type t

  val empty : t
  val quiet_seconds : float
  val max_seconds : float
  val observe : t -> now:float -> t
  val due : t -> now:float -> bool
  val timeout : t -> now:float -> float
  val clear : t
end

type in_place_restore = {
  safety_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  restored_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  resumed : bool;
}

val error_to_string : error -> string
val recovery_package_path : string -> string

val init :
  root:string ->
  creator:Yeokcham_v4_model.Device_id.t ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  (status, error) result

val init_signed :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  repository:Yeokcham_v4_trust.Repository_id.t ->
  device:Yeokcham_v4_trust.device ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Initializes a collaboration-capable V4 state. [device] is the initial
    administrator and [signing_capability] is supplied by an external local
    signer provider; it is never persisted by this module. *)

val init_signed_with_recovery :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  repository:Yeokcham_v4_trust.Repository_id.t ->
  device:Yeokcham_v4_trust.device ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  recovery_device:Yeokcham_v4_trust.device ->
  recovery_capability:Yeokcham_v4_trust.signing_capability ->
  (status * Yeokcham_v4_recovery.ceremony, error) result
(** Creates the root authority epoch and its initial encrypted recovery package
    before publishing the first V4 state. The caller must present the returned
    24-word mnemonic to the user exactly once and persist or export the package
    through an explicit adapter. *)

val init_collaboration :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  device:Yeokcham_v4_trust.device ->
  membership:Yeokcham_v4_trust.membership ->
  local_certificate:string ->
  (status, error) result
(** Initializes an already enrolled device from public collaboration state. The
    caller keeps the corresponding private signing capability outside V4 project
    objects. *)

val init_authority_collaboration :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  device:Yeokcham_v4_trust.device ->
  authority:Yeokcham_v4_trust.authority ->
  local_certificate:string ->
  (status, error) result
(** Initializes an already-enrolled device using a verified V4 authority
    closure. It is intended for a peer that has compared the root phrase and
    obtained the public enrollment closure out of band. *)

val save : root:string -> (save_outcome, error) result
val status : root:string -> (status, error) result
val identity : root:string -> (identity, error) result

val register_username :
  root:string ->
  device:Yeokcham_v4_model.Device_id.t ->
  username:Yeokcham_v4_model.Username.t ->
  (status, error) result

val enroll_device :
  parent:string option ->
  root:string ->
  subject:Yeokcham_v4_trust.device ->
  role:Yeokcham_v4_trust.role ->
  username:Yeokcham_v4_model.Username.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** An already authorized administrator enrols [subject]. On an authority fork,
    [parent] must name the single current head this branch-local action
    advances. The username is only local display registration made alongside,
    never certificate data. *)

val revoke_device :
  parent:string option ->
  root:string ->
  device:Yeokcham_v4_model.Device_id.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Advances one authority head. On a fork, [parent] must explicitly name that
    current head. Historical records remain verifiable; new records by the
    revoked device do not. A local device must use rotation rather than revoking
    itself. *)

val rotate_local_device :
  parent:string option ->
  root:string ->
  replacement:Yeokcham_v4_trust.device ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Atomically enrolls [replacement], revokes the current local device, and
    changes the local certificate in one selected branch. On a fork, [parent]
    must name that current head. The replacement private key must already be in
    the platform signer. *)

val reconcile_authority :
  root:string ->
  parents:string list ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Explicitly creates a multi-parent authority successor. [parents] must be a
    strictly sorted, duplicate-free list of at least two current heads. It
    leaves every unselected concurrent head active. The local device must be an
    administrator active in every named parent. *)

val recover_authority :
  root:string ->
  package:string ->
  mnemonic:string ->
  output:string ->
  replacement:Yeokcham_v4_trust.device ->
  replaced:Yeokcham_v4_model.Device_id.t ->
  (status * Yeokcham_v4_recovery.ceremony, error) result
(** Uses an encrypted recovery package to enroll [replacement] as an
    administrator, revoke [replaced], and rotate recovery material in one
    recovery successor epoch. [output] is written exclusively before the state
    head advances; callers must store the returned mnemonic offline. *)

val refresh_recovery_package :
  root:string ->
  package:string ->
  mnemonic:string ->
  output:string ->
  (unit, error) result
(** Produces an additional, exclusively-created encrypted recovery package for
    the current authority closure without rotating identity or authority. The
    existing 24-word mnemonic is required and remains unchanged. *)

val authority_heads : root:string -> (string list, error) result

val review_package :
  root:string -> package:string -> (package_review list, error) result
(** Verifies a V2 package manifest and reports its signed records without
    importing objects or modifying the model or working tree. *)

val adopt_package_revision :
  authority_epoch:string option ->
  root:string ->
  package:string ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Records a current-head administrator's one-time adoption for one exact,
    currently review-required package record. On an authority fork,
    [authority_epoch] must select the current head issuing the adoption. The
    record and authority closure are persisted, but package objects and model
    revisions are not imported; call [receive_package] afterwards. *)

val restore :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  destination:string ->
  (unit, error) result

val restore_in_place :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  (in_place_restore, error) result

val recover_in_place : root:string -> (in_place_restore option, error) result

val pin :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  (status, error) result

val unpin :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  (status, error) result

val compact :
  root:string ->
  keep_recent:int ->
  dry_run:bool ->
  (compact_report, error) result

val new_draft :
  root:string ->
  id:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  (status, error) result

val share :
  root:string ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  (status, error) result

val share_signed :
  authority_epoch:string option ->
  root:string ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** When authority has multiple current heads, [authority_epoch] must select the
    current head recorded in the revision signature. *)

val withdraw :
  root:string -> change:Yeokcham_v4_model.Change_id.t -> (status, error) result

val resolve :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  tree:string option ->
  (status, error) result

val resolve_signed :
  authority_epoch:string option ->
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  tree:string option ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** When authority has multiple current heads, [authority_epoch] must select the
    current head recorded in the resolution signature. *)

val create_package : root:string -> destination:string -> (unit, error) result

val receive_package : root:string -> package:string -> (status, error) result
(** Imports only verified immutable objects and then atomically advances the
    collaborative V4 state. It does not materialize or otherwise touch the
    working tree. *)

val open_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  (Yeokcham_v4_model.decision, error) result

val materialize_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  destination:string ->
  (materialized_candidate list, error) result

val inspect_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  (decision_inspection, error) result

val compare_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  candidate:Yeokcham_v4_model.Revision_id.t ->
  against:comparison_target ->
  (decision_comparison, error) result

val deliver :
  root:string ->
  id:Yeokcham_v4_model.Delivery_id.t ->
  next_draft:Yeokcham_v4_model.Draft_id.t ->
  next_title:string ->
  (status, error) result
