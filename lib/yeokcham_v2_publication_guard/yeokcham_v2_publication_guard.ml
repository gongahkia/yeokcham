type mode = Shared | Exclusive

type error =
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_lock_path of string
  | Reentrant_upgrade of string

let lock_filename = "cache-reclamation.lock"
let ( let* ) = Result.bind

let error_to_string = function
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Invalid_lock_path path -> "invalid V2 publication-guard path: " ^ path
  | Reentrant_upgrade path ->
      "V2 publication guard cannot upgrade a held shared lock at " ^ path

let lock_path ~root =
  Filename.concat root (Filename.concat ".yeokcham/locks" lock_filename)

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let ensure_regular_lock path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
    let stat = Unix.fstat descriptor in
    if stat.Unix.st_kind = Unix.S_REG then Ok descriptor
    else (
      Unix.close descriptor;
      Error (Invalid_lock_path path))
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"open" ~path error)

let lock_command = function Shared -> Unix.F_RLOCK | Exclusive -> Unix.F_LOCK

type held = { root : string; mode : mode; mutable depth : int }

let held_guard : held option ref = ref None

let with_held held action =
  held.depth <- held.depth + 1;
  Fun.protect
    ~finally:(fun () -> held.depth <- held.depth - 1)
    (fun () -> Ok (action ()))

let with_guard ~root ~mode action =
  let path = lock_path ~root in
  match !held_guard with
  | Some held when String.equal held.root root -> (
      match (held.mode, mode) with
      | Exclusive, (Shared | Exclusive) | Shared, Shared ->
          with_held held action
      | Shared, Exclusive -> Error (Reentrant_upgrade path))
  | Some _ -> Error (Reentrant_upgrade path)
  | None ->
      let* descriptor = ensure_regular_lock path in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          try
            Unix.lockf descriptor (lock_command mode) 0;
            let held = { root; mode; depth = 1 } in
            held_guard := Some held;
            Fun.protect
              ~finally:(fun () -> held_guard := None)
              (fun () -> Ok (action ()))
          with Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"lock" ~path error))
