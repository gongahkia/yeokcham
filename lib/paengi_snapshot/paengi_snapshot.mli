type file_mode = Regular | Executable | Symlink

type error =
  | Store_error of Paengi_store.error
  | Encoding_error of Paengi_encoding.construction_error
  | Envelope_creation_error of Paengi_envelope.creation_error
  | Unexpected_object_type of {
      expected : Paengi_envelope.object_type;
      actual : Paengi_envelope.object_type;
    }
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Invalid_name of string
  | Duplicate_name of string
  | Unordered_name of { previous : string; current : string }
  | Invalid_mode of int64
  | Invalid_object_id_length of int
  | Invalid_content_id_length of int
  | Noncanonical_schema_bytes
  | Noncanonical_content_representation of { length : int; limit : int }
  | Unsupported_chunking_algorithm of int64
  | Unsupported_chunking_parameters of string
  | Invalid_chunk_length of int64
  | Manifest_length_mismatch of { declared : int; actual : int }
  | Manifest_content_identity_mismatch
  | Noncanonical_chunk_boundaries
  | File_too_large of { path : string; size : int; limit : int }
  | Scan_error of { path : string; operation : string; message : string }
  | Unsupported_file_type of { path : string; kind : string }
  | Invalid_ignore_path of { line : int; path : string }

val error_to_string : error -> string

type snapshot_model_error = error

module Content : sig
  type id
  type identity

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> id
  val stored_object_id : id -> Paengi_store.Stored_object_id.t
  val equal_id : id -> id -> bool
  val identity_of_bytes : string -> identity
  val identity_to_raw_bytes : identity -> string
  val store : Paengi_store.repository -> string -> (id, error) result
  val load : Paengi_store.repository -> id -> (string, error) result
end

module Chunk : sig
  type id

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> id
  val stored_object_id : id -> Paengi_store.Stored_object_id.t
  val equal_id : id -> id -> bool
  val store : Paengi_store.repository -> string -> (id, error) result
  val load : Paengi_store.repository -> id -> (string, error) result
end

module Manifest : sig
  type id
  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> id
  val stored_object_id : id -> Paengi_store.Stored_object_id.t
  val equal_id : id -> id -> bool
  val total_length : t -> int
  val chunks : t -> (Chunk.id * int) list

  val store_chunks :
    Paengi_store.repository ->
    total_length:int ->
    full_content_id:string ->
    (Chunk.id * int) list ->
    (id, error) result

  val store_bytes : Paengi_store.repository -> string -> (id, error) result
  val load : Paengi_store.repository -> id -> (t, error) result
end

module Tree : sig
  type id

  type entry =
    | File of { mode : file_mode; content : Content.id }
    | Directory of id

  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> id
  val stored_object_id : id -> Paengi_store.Stored_object_id.t
  val equal_id : id -> id -> bool
  val create : (string * entry) list -> (t, error) result
  val entries : t -> (string * entry) list
  val id : t -> (id, error) result
  val store : Paengi_store.repository -> t -> (id, error) result
  val load : Paengi_store.repository -> id -> (t, error) result
end

module Snapshot : sig
  type id
  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> id
  val stored_object_id : id -> Paengi_store.Stored_object_id.t
  val equal_id : id -> id -> bool
  val create : root:Tree.id -> t
  val root : t -> Tree.id
  val id : t -> (id, error) result
  val store : Paengi_store.repository -> t -> (id, error) result
  val load : Paengi_store.repository -> id -> (t, error) result
end

module Materialize : sig
  type action =
    | Create_directory of string list
    | Write_file of {
        path : string list;
        content : Content.id;
        mode : file_mode;
      }
    | Create_symlink of { path : string list; target : Content.id }

  type error =
    | Snapshot_error of snapshot_model_error
    | Destination_not_directory of string
    | Destination_not_empty of string
    | Unsafe_destination_path of string list
    | Invalid_symlink_target of string list
    | Io_error of { path : string; operation : string; message : string }

  val error_to_string : error -> string

  val plan :
    Paengi_store.repository -> Snapshot.t -> (action list, error) result

  val write :
    destination:string ->
    Paengi_store.repository ->
    Snapshot.t ->
    (unit, error) result
end

val scan :
  root:string ->
  store:Paengi_store.repository ->
  (Snapshot.id * Snapshot.t, error) result

val inline_file_limit : int
