(** Root-authorized, append-only MLS epoch transitions for V2-031.

    Each record binds exactly one real MLS Add or Remove Commit to its prior
    canonical state and stores the successor snapshot only in the existing
    encrypted envelope. Records describe forward epoch evolution; they do not
    make a claim about plaintext already obtained from an earlier epoch. *)

module Authority = Yeokcham_v2_authority
module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type transition
type change = Member_added | Member_removed

type transition_result = {
  transition_result_record : transition;
  transition_result_successor_state : Group.t;
  transition_result_commit : string;
  transition_result_previous_epoch : int64;
  transition_result_next_epoch : int64;
}

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Invalid_epoch of string
  | Unauthorized_root
  | Authority_error of Authority.error
  | Group_error of Group.error
  | Envelope_error of Envelope.error
  | Signature_verification_failed
  | Identity_mismatch of string
  | Noncanonical_record
  | Divergent_epoch of Model.Mls_epoch_id.t option
  | Disconnected_epoch of Model.Mls_epoch_id.t

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val encode : transition -> string

val decode :
  authority:Authority.repository_authority ->
  string ->
  (transition, error) result

val id : transition -> Model.Mls_epoch_id.t
val parent_id : transition -> Model.Mls_epoch_id.t option
val change : transition -> change
val changed_device_id : transition -> Model.Device_id.t
val previous_epoch : transition -> int64
val next_epoch : transition -> int64
val predecessor_state_commitment : transition -> string
val successor_state_commitment : transition -> string
val successor_envelope : transition -> Envelope.t

val create :
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  parent_id:Model.Mls_epoch_id.t option ->
  change:change ->
  changed_device_id:Model.Device_id.t ->
  predecessor_state:Group.t ->
  successor_state:Group.t ->
  commit:string ->
  previous_epoch:int64 ->
  next_epoch:int64 ->
  state_key:Envelope.key ->
  state_nonce:Envelope.nonce ->
  (transition, error) result
(** Constructs and root-signs one canonical transition from already produced MLS
    states and Commit bytes. It does not itself perform an MLS operation. *)

val advance_add :
  runtime:Runtime.configuration ->
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  parent_id:Model.Mls_epoch_id.t option ->
  issuer_state:Group.t ->
  recipient_device_id:Model.Device_id.t ->
  state_key:Envelope.key ->
  state_nonce:Envelope.nonce ->
  (transition_result, error) result

val advance_removal :
  runtime:Runtime.configuration ->
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  parent_id:Model.Mls_epoch_id.t option ->
  issuer_state:Group.t ->
  removed_device_id:Model.Device_id.t ->
  state_key:Envelope.key ->
  state_nonce:Envelope.nonce ->
  (transition_result, error) result

val open_successor :
  runtime:Runtime.configuration ->
  state_key:Envelope.key ->
  transition ->
  (Group.t, error) result

val verify_chain :
  runtime:Runtime.configuration ->
  authority:Authority.repository_authority ->
  state_key:Envelope.key ->
  initial_state:Group.t ->
  transition list ->
  (Group.t, error) result
(** Verifies the unique complete chain rooted in [initial_state]. Every input
    record must be consumed; a competing child, disconnected record, corrupted
    envelope, or runtime-invalid successor fails closed. *)
