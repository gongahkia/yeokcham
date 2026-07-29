open! Fixture_spec

let path_exists path =
  try
    ignore (Unix.lstat path);
    true
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let full_path root components = List.fold_left Filename.concat root components

let mkdir_parents root path =
  match List.rev path with
  | [] -> ()
  | _ :: reversed_parent ->
      ignore
        (List.fold_left
           (fun current component ->
             let next = Filename.concat current component in
             if path_exists next then (
               if (Unix.lstat next).Unix.st_kind <> Unix.S_DIR then
                 failwith
                   (Printf.sprintf "fixture parent is not a directory: %s" next))
             else Unix.mkdir next 0o755;
             next)
           root (List.rev reversed_parent))

let write_file root (file : file_entry) =
  mkdir_parents root file.file_path;
  let path = full_path root file.file_path in
  let channel =
    open_out_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o644 path
  in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel file.contents);
  match file.mode with
  | Fixture_spec.Regular -> ()
  | Fixture_spec.Executable -> Unix.chmod path 0o755

let write_symlink root (link : symlink_entry) =
  mkdir_parents root link.link_path;
  let path = full_path root link.link_path in
  let target = full_path "" link.target in
  Unix.symlink ~to_dir:false target path

let has_symlink entries =
  List.exists (function File _ -> false | Symlink _ -> true) entries

let write ~destination entries =
  match Fixture_spec.validate entries with
  | Error message -> Error message
  | Ok () when path_exists destination ->
      Error (Printf.sprintf "destination exists: %s" destination)
  | Ok () when has_symlink entries && not (Unix.has_symlink ()) ->
      Error "symbolic links are unavailable"
  | Ok () -> (
      let staging =
        Printf.sprintf "%s.paengi-fixture-%d" destination (Unix.getpid ())
      in
      if path_exists staging then
        Error (Printf.sprintf "staging path exists: %s" staging)
      else
        try
          Unix.mkdir staging 0o755;
          List.iter
            (function
              | File file -> write_file staging file
              | Symlink link -> write_symlink staging link)
            entries;
          if path_exists destination then
            Error (Printf.sprintf "destination appeared: %s" destination)
          else (
            Unix.rename staging destination;
            Ok ())
        with error -> Error (Printexc.to_string error))
