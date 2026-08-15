val envelope_version : int
val header_size : int
val checksum_algorithm_code : int
val current_object_format_version : int
val supported_mandatory_features : int64

type object_type =
  | Content
  | Tree
  | Snapshot
  | Scratch_event
  | Checkpoint
  | Capsule
  | Capsule_revision
  | Release
  | Conflict
  | Validation
  | Resolution
  | Repository_config
  | Chunk
  | File_manifest
  | Retention_change
  | Scratch_generation_segment
  | Scratch_generation
  | Scratch_cleanup_manifest
  | Workspace
  | Workspace_revision
  | Workspace_attempt
  | Release_attestation
  | Git_mapping
  | Imported_transition
  | Imported_tag
  | Ref_event
  | Device_identity
  | Divergent_ref_set
  | Git_archive
  | Git_adoption
  | Peer_publication
  | Peer_integration
  | Git_lineage_node
  | Git_lineage
  | Peer_identity
  | Peer_contact
  | Peer_advertisement
  | Peer_sync_node
  | Peer_sync_conflict

val object_type_code : object_type -> int
val object_type_of_code : int -> object_type option

type creation_error =
  | Invalid_object_format_version of int
  | Unsupported_mandatory_features of int64

val creation_error_to_string : creation_error -> string

type 'payload envelope = private {
  object_type : object_type;
  object_format_version : int;
  mandatory_features : int64;
  checksum : string;
  payload : 'payload;
}

type t = Yeokcham_encoding.t envelope

val object_type : 'payload envelope -> object_type
val object_format_version : 'payload envelope -> int
val mandatory_features : 'payload envelope -> int64
val checksum : 'payload envelope -> string
val payload : 'payload envelope -> 'payload

val create :
  object_type:object_type ->
  object_format_version:int ->
  mandatory_features:int64 ->
  payload:Yeokcham_encoding.t ->
  unit ->
  (t, creation_error) result

type decode_error_kind =
  | Truncated_header of int
  | Invalid_magic
  | Unsupported_envelope_version of int
  | Unknown_checksum_algorithm of int
  | Payload_length_out_of_range
  | Length_mismatch of { declared : int64; actual : int }
  | Checksum_mismatch
  | Unknown_object_type of int
  | Unsupported_object_format_version of int
  | Unknown_mandatory_features of int64
  | Invalid_payload of string

type decode_error = { offset : int; kind : decode_error_kind }

val decode_error_to_string : decode_error -> string
val encode : t -> string
val verify : string -> (string envelope, decode_error) result

val decode_with :
  payload_decoder:(string -> ('payload, string) result) ->
  string ->
  ('payload envelope, decode_error) result

val decode : string -> (t, decode_error) result
