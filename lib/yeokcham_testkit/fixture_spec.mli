type path = string list
type mode = Regular | Executable
type file_entry = { file_path : path; contents : string; mode : mode }
type symlink_entry = { link_path : path; target : path }
type entry = File of file_entry | Symlink of symlink_entry
type t = entry list

val generate : seed:int -> t
val validate : t -> (unit, string) result
val equal : t -> t -> bool
val entry_count : t -> int
