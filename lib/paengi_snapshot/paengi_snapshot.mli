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
  | Noncanonical_schema_bytes
  | File_too_large of { path : string; size : int; limit : int }
  | Scan_error of { path : string; operation : string; message : string }
  | Unsupported_file_type of { path : string; kind : string }
  | Invalid_ignore_path of { line : int; path : string }

val error_to_string : error -> string

module Content : sig
  type id

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> id
  val stored_object_id : id -> Paengi_store.Stored_object_id.t
  val equal_id : id -> id -> bool
  val store : Paengi_store.repository -> string -> (id, error) result
  val load : Paengi_store.repository -> id -> (string, error) result
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
    | Snapshot_error of error
    | Destination_not_directory of string
    | Destination_not_empty of string
    | Unsafe_destination_path of string list
    | Invalid_symlink_target of string list
    | Io_error of { path : string; operation : string; message : string }

  val error_to_string : error -> string
  val plan : Paengi_store.repository -> Snapshot.t -> (action list, error) result

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
