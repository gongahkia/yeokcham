type capsule_target = {
  source_capsule : Yeokcham_id.Capsule_id.t;
  source_revision : Yeokcham_id.Capsule_revision_id.t;
  source_title : string;
  source_description : string;
  source_snapshot : Yeokcham_snapshot.Snapshot.id;
  target_snapshot : Yeokcham_snapshot.Snapshot.id;
}

type release_target = {
  source_release : Yeokcham_id.Release_id.t;
  source_message : string option;
  source_created_at : int64;
  source_base : Yeokcham_snapshot.Snapshot.id;
  source_final_snapshot : Yeokcham_snapshot.Snapshot.id;
}

type target = Capsule_revision of capsule_target | Release of release_target
type publication
type integration

type error =
  | Store_error of Yeokcham_store.error
  | Envelope_error of Yeokcham_envelope.creation_error
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of string
  | Snapshot_error of Yeokcham_snapshot.error
  | Capsule_error of Yeokcham_capsule_store.error
  | Release_error of Yeokcham_release.error
  | Scratch_error of Yeokcham_scratch.error
  | Exchange_error of Yeokcham_exchange_store.error
  | Transport_error of string
  | Publication_missing of Yeokcham_id.Publication_id.t
  | Integration_missing of Yeokcham_id.Peer_integration_id.t
  | Invalid_publication of string
  | Unsupported_integration_target
  | Publication_binding_conflict of Yeokcham_id.Publication_id.t
  | Integration_binding_conflict of Yeokcham_id.Peer_integration_id.t
  | Injected_interruption of string

val error_to_string : error -> string
val publication_id : publication -> Yeokcham_id.Publication_id.t
val publication_target : publication -> target
val publication_objects : publication -> Yeokcham_store.Stored_object_id.t list
val publication_envelope_bytes : publication -> (string, error) result
val publication_binding_bytes : publication -> (string, error) result
val capsule_target_source_capsule : capsule_target -> Yeokcham_id.Capsule_id.t

val capsule_target_source_revision :
  capsule_target -> Yeokcham_id.Capsule_revision_id.t

val capsule_target_title : capsule_target -> string
val capsule_target_description : capsule_target -> string

val capsule_target_source_snapshot :
  capsule_target -> Yeokcham_snapshot.Snapshot.id

val capsule_target_result_snapshot :
  capsule_target -> Yeokcham_snapshot.Snapshot.id

val release_target_source_release : release_target -> Yeokcham_id.Release_id.t
val release_target_message : release_target -> string option
val release_target_created_at : release_target -> int64
val release_target_base : release_target -> Yeokcham_snapshot.Snapshot.id

val release_target_final_snapshot :
  release_target -> Yeokcham_snapshot.Snapshot.id

val publish_capsule_revision :
  Yeokcham_store.repository ->
  capsule:Yeokcham_id.Capsule_id.t ->
  revision:Yeokcham_id.Capsule_revision_id.t ->
  (publication, error) result

val publish_release :
  Yeokcham_store.repository ->
  Yeokcham_id.Release_id.t ->
  (publication, error) result

val load_publication :
  Yeokcham_store.repository ->
  Yeokcham_id.Publication_id.t ->
  (publication, error) result

val transfer_objects : publication -> Yeokcham_store.Stored_object_id.t list

val fetch_local :
  ?interrupt_after:int ->
  ?on_progress:(completed:int -> total:int -> unit) ->
  source:Yeokcham_store.repository ->
  destination:Yeokcham_store.repository ->
  Yeokcham_id.Publication_id.t ->
  (Yeokcham_exchange_store.outcome * publication, error) result

val ssh_arguments :
  target:string ->
  remote_root:string ->
  publication:Yeokcham_id.Publication_id.t ->
  (string array, error) result

val serve :
  Yeokcham_store.repository ->
  publication:Yeokcham_id.Publication_id.t ->
  input:in_channel ->
  output:out_channel ->
  (unit, error) result

val fetch_stream :
  destination:Yeokcham_store.repository ->
  publication:Yeokcham_id.Publication_id.t ->
  input:in_channel ->
  output:out_channel ->
  (Yeokcham_exchange_store.outcome * publication, error) result

val fetch_ssh :
  destination:Yeokcham_store.repository ->
  target:string ->
  remote_root:string ->
  publication:Yeokcham_id.Publication_id.t ->
  (Yeokcham_exchange_store.outcome * publication, error) result

val integration_id : integration -> Yeokcham_id.Peer_integration_id.t
val integration_publication : integration -> Yeokcham_id.Publication_id.t
val integration_capsule : integration -> Yeokcham_id.Capsule_id.t
val integration_revision : integration -> Yeokcham_id.Capsule_revision_id.t
val integration_source : integration -> Yeokcham_scratch.Checkpoint_id.t
val integration_target : integration -> Yeokcham_scratch.Checkpoint_id.t
val integration_envelope_bytes : integration -> (string, error) result
val integration_binding_bytes : integration -> (string, error) result

val integrate_capsule :
  Yeokcham_store.repository ->
  publication:Yeokcham_id.Publication_id.t ->
  capsule:Yeokcham_id.Capsule_id.t ->
  title:string ->
  description:string ->
  created_at:int64 ->
  (integration, error) result

val load_integration :
  Yeokcham_store.repository ->
  Yeokcham_id.Peer_integration_id.t ->
  (integration, error) result
