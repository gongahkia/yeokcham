module Object_id = Yeokcham_store.Stored_object_id

type partial
type complete
type entry = Partial of partial | Complete of complete
type inspection

type error =
  | Directory_not_directory of string
  | Directory_io_error of {
      operation : string;
      path : string;
      message : string;
    }
  | Unsafe_entry of { path : string; detail : string }
  | File_too_large of { path : string; size : int; limit : int }
  | File_size_changed of string
  | Partial_not_importable of string
  | Name_collision_exhausted of int
  | Entropy_failure of string
  | Published_partial_retained of {
      complete_name : string;
      partial_name : string;
      detail : string;
    }
  | Bundle_error of Yeokcham_bundle.error
  | Bundle_store_error of Yeokcham_bundle_store.error

val error_to_string : error -> string
val max_file_bytes : int
val max_name_attempts : int
val entry_name : entry -> string
val entry_size : entry -> int
val complete_path : complete -> string
val complete_of_entry : entry -> (complete, error) result
val inspection_object_ids : inspection -> Object_id.t list
val list : directory:string -> (entry list, error) result

val export :
  directory:string ->
  repository:Yeokcham_store.repository ->
  key:Yeokcham_bundle.key ->
  object_ids:Object_id.t list ->
  (complete, error) result

val inspect : key:Yeokcham_bundle.key -> complete -> (inspection, error) result

val import :
  repository:Yeokcham_store.repository ->
  key:Yeokcham_bundle.key ->
  complete ->
  (Object_id.t list, error) result
