type path = string list

type reason =
  | Initial_scan
  | Path_change
  | Rename
  | Rescan_required
  | Overflow
  | Watcher_lost
  | Path_budget_exceeded

type target = Whole_root | Paths of path list
type scan_request = { reason : reason; target : target }
type error = Invalid_path of path

let max_paths_per_request = 256

let error_to_string = function
  | Invalid_path path ->
      "watcher path is not a safe relative path: " ^ String.concat "/" path

let valid_path path =
  path <> []
  && List.for_all
       (fun component ->
         (not (String.is_empty component))
         && (not (String.equal component "."))
         && (not (String.equal component ".."))
         && (not (String.contains component '/'))
         && not (String.contains component '\000'))
       path

type observation =
  | Path_changed of path
  | Renamed of { source : path; destination : path }
  | Rename_notice of path
  | Rescan
  | Overflowed
  | Lost

let is_rescan = function
  | Rescan -> true
  | Path_changed _ | Renamed _ | Rename_notice _ | Overflowed | Lost -> false

let is_overflow = function
  | Overflowed -> true
  | Path_changed _ | Renamed _ | Rename_notice _ | Rescan | Lost -> false

let is_lost = function
  | Lost -> true
  | Path_changed _ | Renamed _ | Rename_notice _ | Rescan | Overflowed -> false

let normalize observations =
  let full_rescan_reason observations =
    if List.exists is_lost observations then Some Watcher_lost
    else if List.exists is_overflow observations then Some Overflow
    else if List.exists is_rescan observations then Some Rescan_required
    else None
  in
  let rec collect saw_rename paths = function
    | [] ->
        let paths = List.sort_uniq Stdlib.compare paths in
        if paths = [] then Ok None
        else if List.length paths > max_paths_per_request then
          Ok (Some { reason = Path_budget_exceeded; target = Whole_root })
        else
          Ok
            (Some
               {
                 reason = (if saw_rename then Rename else Path_change);
                 target = Paths paths;
               })
    | Path_changed path :: rest ->
        if valid_path path then collect saw_rename (path :: paths) rest
        else Error (Invalid_path path)
    | Renamed { source; destination } :: rest ->
        if not (valid_path source) then Error (Invalid_path source)
        else if not (valid_path destination) then
          Error (Invalid_path destination)
        else collect true (source :: destination :: paths) rest
    | Rename_notice path :: rest ->
        if valid_path path then collect true (path :: paths) rest
        else Error (Invalid_path path)
    | Rescan :: _ -> Ok (Some { reason = Rescan_required; target = Whole_root })
    | Overflowed :: _ -> Ok (Some { reason = Overflow; target = Whole_root })
    | Lost :: _ -> Ok (Some { reason = Watcher_lost; target = Whole_root })
  in
  match full_rescan_reason observations with
  | Some reason -> Ok (Some { reason; target = Whole_root })
  | None -> collect false [] observations

module Linux = struct
  type event =
    | Created of path
    | Changed of path
    | Deleted of path
    | Moved of { source : path; destination : path }
    | Queue_overflow
    | Watch_lost

  let normalize events =
    let observations =
      List.map
        (function
          | Created path | Changed path | Deleted path -> Path_changed path
          | Moved { source; destination } -> Renamed { source; destination }
          | Queue_overflow -> Overflowed
          | Watch_lost -> Lost)
        events
    in
    normalize observations
end

module Macos = struct
  type event =
    | Item_created of path
    | Item_modified of path
    | Item_removed of path
    | Item_renamed of path
    | Must_scan_subdirs
    | Kernel_dropped
    | User_dropped
    | Client_overflow
    | Event_ids_wrapped
    | Root_changed
    | Unmounted

  let normalize events =
    let observations =
      List.map
        (function
          | Item_created path | Item_modified path | Item_removed path ->
              Path_changed path
          | Item_renamed path -> Rename_notice path
          | Must_scan_subdirs -> Rescan
          | Kernel_dropped | User_dropped | Client_overflow -> Overflowed
          | Event_ids_wrapped | Root_changed | Unmounted -> Lost)
        events
    in
    normalize observations
end
