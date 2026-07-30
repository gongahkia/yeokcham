module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Store = Paengi_store

type file_mode = Regular | Executable | Symlink

type error =
  | Store_error of Store.error
  | Encoding_error of Encoding.construction_error
  | Envelope_creation_error of Envelope.creation_error
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
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

let object_type_name object_type =
  Printf.sprintf "object type %d" (Envelope.object_type_code object_type)

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Envelope_creation_error error -> Envelope.creation_error_to_string error
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "expected %s, got %s"
        (object_type_name expected)
        (object_type_name actual)
  | Invalid_schema message ->
      Printf.sprintf "invalid persisted snapshot schema: %s" message
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported persisted snapshot schema version: %Ld"
        version
  | Invalid_name name -> Printf.sprintf "invalid tree entry name: %S" name
  | Duplicate_name name -> Printf.sprintf "duplicate tree entry name: %S" name
  | Unordered_name { previous; current } ->
      Printf.sprintf "tree names are not strictly ordered: %S then %S" previous
        current
  | Invalid_mode mode -> Printf.sprintf "invalid persisted file mode: %Ld" mode
  | Invalid_object_id_length length ->
      Printf.sprintf "stored object ID must be 32 bytes, got %d" length
  | Noncanonical_schema_bytes ->
      "persisted snapshot schema bytes are noncanonical"
  | File_too_large { path; size; limit } ->
      Printf.sprintf "file exceeds inline storage limit (%d > %d bytes): %s"
        size limit path
  | Scan_error { path; operation; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Unsupported_file_type { path; kind } ->
      Printf.sprintf "unsupported filesystem node (%s): %s" kind path
  | Invalid_ignore_path { line; path } ->
      Printf.sprintf "invalid .paengiignore path on line %d: %S" line path

let ( let* ) = Result.bind

let encoding_array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_schema (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be bytes"))

let raw_object_id value =
  let* raw = bytes "stored object ID" value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None -> Error (Invalid_object_id_length (String.length raw))

let envelope object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_creation_error error)

let canonical_payload_matches expected payload =
  if String.equal expected (Encoding.encode payload) then Ok ()
  else Error Noncanonical_schema_bytes

let valid_name name =
  (not (String.is_empty name))
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let mode_code = function Regular -> 0L | Executable -> 1L | Symlink -> 2L

let mode_of_code = function
  | 0L -> Ok Regular
  | 1L -> Ok Executable
  | 2L -> Ok Symlink
  | value -> Error (Invalid_mode value)

module Content = struct
  type id = Store.Stored_object_id.t

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal

  let payload value =
    encoding_array [ Encoding.integer 1L; Encoding.bytes value ]

  let store repository value =
    let* payload = payload value in
    let* object_ = envelope Envelope.Content payload in
    Store.put repository object_
    |> Result.map_error (fun error -> Store_error error)

  let decode payload_value =
    let* fields = exact_array "content" 2 payload_value in
    match fields with
    | [ version; value ] ->
        let* version = integer "content version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* value = bytes "content value" value in
          let* canonical = payload value in
          let* () =
            canonical_payload_matches (Encoding.encode canonical) payload_value
          in
          Ok value
    | _ -> Error (Invalid_schema "content must contain two values")

  let load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Content then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Content;
             actual = Envelope.object_type object_;
           })
    else decode (Envelope.payload object_)
end

module Tree = struct
  type id = Store.Stored_object_id.t

  type entry =
    | File of { mode : file_mode; content : Content.id }
    | Directory of id

  type t = (string * entry) list

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal
  let entries tree = tree

  let create entries =
    let sorted =
      List.sort (fun (left, _) (right, _) -> String.compare left right) entries
    in
    let rec validate previous = function
      | [] -> Ok sorted
      | (name, _) :: rest ->
          if not (valid_name name) then Error (Invalid_name name)
          else
            let* () =
              match previous with
              | None -> Ok ()
              | Some prior ->
                  let comparison = String.compare prior name in
                  if comparison = 0 then Error (Duplicate_name name) else Ok ()
            in
            validate (Some name) rest
    in
    validate None sorted

  let entry_value (name, entry) =
    match entry with
    | File { mode; content } ->
        encoding_array
          [
            Encoding.integer 0L;
            Encoding.bytes name;
            Encoding.integer (mode_code mode);
            Encoding.bytes (Store.Stored_object_id.to_raw_bytes content);
          ]
    | Directory child ->
        encoding_array
          [
            Encoding.integer 1L;
            Encoding.bytes name;
            Encoding.bytes (Store.Stored_object_id.to_raw_bytes child);
          ]

  let payload entries =
    let rec encode reversed = function
      | [] -> Ok (List.rev reversed)
      | entry :: rest ->
          let* encoded = entry_value entry in
          encode (encoded :: reversed) rest
    in
    let* values = encode [] entries in
    let* entries = encoding_array values in
    encoding_array [ Encoding.integer 1L; entries ]

  let store repository tree =
    let* payload = payload tree in
    let* object_ = envelope Envelope.Tree payload in
    Store.put repository object_
    |> Result.map_error (fun error -> Store_error error)

  let decode_entry value =
    let* fields = array_values "tree entry" value in
    match fields with
    | tag :: fields ->
        let* tag = integer "tree entry tag" tag in
        if Int64.equal tag 0L then
          match fields with
          | [ name; mode; content ] ->
              let* name = bytes "tree file name" name in
              let* mode = integer "tree file mode" mode in
              let* mode = mode_of_code mode in
              let* content = raw_object_id content in
              Ok (name, File { mode; content })
          | _ ->
              Error (Invalid_schema "file tree entry must contain four values")
        else if Int64.equal tag 1L then
          match fields with
          | [ name; child ] ->
              let* name = bytes "tree directory name" name in
              let* child = raw_object_id child in
              Ok (name, Directory child)
          | _ ->
              Error
                (Invalid_schema "directory tree entry must contain three values")
        else
          Error
            (Invalid_schema (Printf.sprintf "unknown tree entry tag: %Ld" tag))
    | [] -> Error (Invalid_schema "tree entry is empty")

  let ensure_input_order entries =
    let rec ordered previous = function
      | [] -> Ok ()
      | (name, _) :: rest ->
          let* () =
            match previous with
            | None -> Ok ()
            | Some prior ->
                let comparison = String.compare prior name in
                if comparison = 0 then Error (Duplicate_name name)
                else if comparison > 0 then
                  Error (Unordered_name { previous = prior; current = name })
                else Ok ()
          in
          ordered (Some name) rest
    in
    ordered None entries

  let decode payload_value =
    let* fields = exact_array "tree" 2 payload_value in
    match fields with
    | [ version; entries_value ] ->
        let* version = integer "tree version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* entries_value = array_values "tree entries" entries_value in
          let rec decode_entries reversed = function
            | [] -> Ok (List.rev reversed)
            | value :: rest ->
                let* entry = decode_entry value in
                decode_entries (entry :: reversed) rest
          in
          let* entries = decode_entries [] entries_value in
          let* () = ensure_input_order entries in
          let* tree = create entries in
          let* canonical = payload tree in
          let* () =
            canonical_payload_matches (Encoding.encode canonical) payload_value
          in
          Ok tree
    | _ -> Error (Invalid_schema "tree must contain two values")

  let load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Tree then
      Error
        (Unexpected_object_type
           { expected = Envelope.Tree; actual = Envelope.object_type object_ })
    else
      let* tree = decode (Envelope.payload object_) in
      let rec validate_references = function
        | [] -> Ok ()
        | (_, File { content; _ }) :: rest ->
            let* _ = Content.load repository content in
            validate_references rest
        | (_, Directory child) :: rest ->
            let* child_object =
              Store.get repository child
              |> Result.map_error (fun error -> Store_error error)
            in
            if Envelope.object_type child_object <> Envelope.Tree then
              Error
                (Unexpected_object_type
                   {
                     expected = Envelope.Tree;
                     actual = Envelope.object_type child_object;
                   })
            else validate_references rest
      in
      let* () = validate_references tree in
      Ok tree
end

module Snapshot = struct
  type id = Store.Stored_object_id.t
  type t = { root : Tree.id }

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal
  let create ~root = { root }
  let root snapshot = snapshot.root

  let payload snapshot =
    encoding_array
      [
        Encoding.integer 1L;
        Encoding.bytes (Store.Stored_object_id.to_raw_bytes snapshot.root);
      ]

  let store repository snapshot =
    let* payload = payload snapshot in
    let* object_ = envelope Envelope.Snapshot payload in
    Store.put repository object_
    |> Result.map_error (fun error -> Store_error error)

  let decode payload_value =
    let* fields = exact_array "snapshot" 2 payload_value in
    match fields with
    | [ version; root ] ->
        let* version = integer "snapshot version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* root = raw_object_id root in
          let snapshot = create ~root in
          let* canonical = payload snapshot in
          let* () =
            canonical_payload_matches (Encoding.encode canonical) payload_value
          in
          Ok snapshot
    | _ -> Error (Invalid_schema "snapshot must contain two values")

  let load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Snapshot then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Snapshot;
             actual = Envelope.object_type object_;
           })
    else
      let* snapshot = decode (Envelope.payload object_) in
      let* _ = Tree.load repository snapshot.root in
      Ok snapshot
end

let snapshot_error_to_string = error_to_string

type snapshot_model_error = error

module Materialize = struct
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

  let error_to_string = function
    | Snapshot_error error -> snapshot_error_to_string error
    | Destination_not_directory path ->
        Printf.sprintf "materialisation destination is not a directory: %s" path
    | Destination_not_empty path ->
        Printf.sprintf "materialisation destination is not empty: %s" path
    | Unsafe_destination_path components ->
        Printf.sprintf "unsafe materialisation path: %s"
          (String.concat "/" components)
    | Invalid_symlink_target components ->
        Printf.sprintf "symlink target contains NUL bytes: %s"
          (String.concat "/" components)
    | Io_error { path; operation; message } ->
        Printf.sprintf "%s failed for %s: %s" operation path message

  let io_error operation path error =
    Io_error { path; operation; message = Unix.error_message error }

  let safe_output_path destination components =
    if List.for_all valid_name components then
      Ok (List.fold_left Filename.concat destination components)
    else Error (Unsafe_destination_path components)

  let plan repository snapshot =
    let rec plan_tree prefix identity =
      let* tree =
        Tree.load repository identity
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let rec plan_entries reversed = function
        | [] -> Ok (List.rev reversed)
        | (name, entry) :: rest ->
            let path = prefix @ [ name ] in
            let* actions =
              match entry with
              | Tree.File { mode = Symlink; content } ->
                  Ok [ Create_symlink { path; target = content } ]
              | Tree.File { mode = (Regular | Executable) as mode; content } ->
                  Ok [ Write_file { path; content; mode } ]
              | Tree.Directory child ->
                  let* descendants = plan_tree path child in
                  Ok (Create_directory path :: descendants)
            in
            plan_entries (List.rev_append actions reversed) rest
      in
      plan_entries [] (Tree.entries tree)
    in
    plan_tree [] (Snapshot.root snapshot)

  let validate_destination destination =
    try
      let stat = Unix.lstat destination in
      if stat.Unix.st_kind <> Unix.S_DIR then
        Error (Destination_not_directory destination)
      else
        try
          if Array.length (Sys.readdir destination) = 0 then Ok ()
          else Error (Destination_not_empty destination)
        with Sys_error message ->
          Error
            (Io_error { path = destination; operation = "readdir"; message })
    with Unix.Unix_error (error, _, _) ->
      Error (io_error "lstat" destination error)

  let write_all descriptor path bytes =
    let length = Bytes.length bytes in
    let rec write offset =
      if offset = length then Ok ()
      else
        try
          match Unix.write descriptor bytes offset (length - offset) with
          | 0 ->
              Error
                (Io_error
                   {
                     path;
                     operation = "write";
                     message = "write returned zero before completion";
                   })
          | count -> write (offset + count)
        with Unix.Unix_error (error, _, _) ->
          Error (io_error "write" path error)
    in
    write 0

  let close descriptor path =
    try
      Unix.close descriptor;
      Ok ()
    with Unix.Unix_error (error, _, _) -> Error (io_error "close" path error)

  let write_file path contents mode =
    try
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      let write_result = write_all descriptor path (Bytes.of_string contents) in
      let close_result = close descriptor path in
      let* () = write_result in
      let* () = close_result in
      let permissions = if mode = Executable then 0o755 else 0o644 in
      try
        Unix.chmod path permissions;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "chmod" path error)
    with Unix.Unix_error (error, _, _) -> Error (io_error "create" path error)

  let create_directory path =
    try
      Unix.mkdir path 0o700;
      Ok ()
    with Unix.Unix_error (error, _, _) -> Error (io_error "mkdir" path error)

  let create_symlink path target components =
    if String.contains target '\000' then
      Error (Invalid_symlink_target components)
    else
      try
        Unix.symlink target path;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "symlink" path error)

  let write ~destination repository snapshot =
    let* () = validate_destination destination in
    let* actions = plan repository snapshot in
    let rec apply = function
      | [] -> Ok ()
      | action :: rest ->
          let* () =
            match action with
            | Create_directory components ->
                let* path = safe_output_path destination components in
                create_directory path
            | Write_file { path = components; content; mode } ->
                let* path = safe_output_path destination components in
                let* contents =
                  Content.load repository content
                  |> Result.map_error (fun error -> Snapshot_error error)
                in
                write_file path contents mode
            | Create_symlink { path = components; target } ->
                let* path = safe_output_path destination components in
                let* target =
                  Content.load repository target
                  |> Result.map_error (fun error -> Snapshot_error error)
                in
                create_symlink path target components
          in
          apply rest
    in
    apply actions
end

let inline_file_limit = Store.max_object_bytes - 128

let scan_error operation path error =
  Scan_error { path; operation; message = Unix.error_message error }

let read_file path size =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        let bytes = Bytes.create size in
        let rec read offset =
          if offset = size then Ok ()
          else
            try
              match Unix.read descriptor bytes offset (size - offset) with
              | 0 ->
                  Error
                    (Scan_error
                       {
                         path;
                         operation = "read";
                         message = "file ended before its recorded size";
                       })
              | count -> read (offset + count)
            with Unix.Unix_error (error, _, _) ->
              Error (scan_error "read" path error)
        in
        let* () = read 0 in
        let probe = Bytes.create 1 in
        let* extra =
          try Ok (Unix.read descriptor probe 0 1)
          with Unix.Unix_error (error, _, _) ->
            Error (scan_error "read" path error)
        in
        if extra = 0 then Ok (Bytes.unsafe_to_string bytes)
        else
          Error
            (Scan_error
               {
                 path;
                 operation = "read";
                 message = "file grew while it was scanned";
               }))
  with Unix.Unix_error (error, _, _) -> Error (scan_error "open" path error)

let safe_ignore_components path =
  if String.is_empty path || String.starts_with ~prefix:"/" path then None
  else
    let components = String.split_on_char '/' path in
    if List.for_all valid_name components then Some components else None

let read_ignore_file root =
  let path = Filename.concat root ".paengiignore" in
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then
      Error (Invalid_ignore_path { line = 0; path = ".paengiignore" })
    else if stat.Unix.st_size > inline_file_limit then
      Error
        (File_too_large
           { path; size = stat.Unix.st_size; limit = inline_file_limit })
    else
      let* contents = read_file path stat.Unix.st_size in
      let lines = String.split_on_char '\n' contents in
      let rec parse line_number reversed = function
        | [] -> Ok (List.rev reversed)
        | line :: rest -> (
            let line =
              if String.ends_with ~suffix:"\r" line then
                String.sub line 0 (String.length line - 1)
              else line
            in
            if String.is_empty line || String.starts_with ~prefix:"#" line then
              parse (line_number + 1) reversed rest
            else
              match safe_ignore_components line with
              | Some components ->
                  parse (line_number + 1) (components :: reversed) rest
              | None ->
                  Error
                    (Invalid_ignore_path { line = line_number; path = line }))
      in
      parse 1 [] lines
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | Unix.Unix_error (error, _, _) -> Error (scan_error "lstat" path error)

let rec is_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | left :: left_rest, right :: right_rest ->
      String.equal left right && is_prefix left_rest right_rest

let is_ignored rules components =
  List.exists (fun rule -> is_prefix rule components) rules

let scan ~root ~store =
  let* root_stat =
    try Ok (Unix.lstat root)
    with Unix.Unix_error (error, _, _) ->
      Error (scan_error "lstat" root error)
  in
  if root_stat.Unix.st_kind <> Unix.S_DIR then
    Error (Unsupported_file_type { path = root; kind = "not a directory" })
  else
    let* ignore_rules = read_ignore_file root in
    let rec scan_directory relative path =
      let names =
        try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare)
        with Sys_error message ->
          Error (Scan_error { path; operation = "readdir"; message })
      in
      let* names = names in
      let rec scan_entries reversed = function
        | [] -> Tree.create (List.rev reversed)
        | name :: rest ->
            let child_relative = relative @ [ name ] in
            if
              (relative = [] && String.equal name ".paengi")
              || is_ignored ignore_rules child_relative
            then scan_entries reversed rest
            else
              let child_path = Filename.concat path name in
              let* stat =
                try Ok (Unix.lstat child_path)
                with Unix.Unix_error (error, _, _) ->
                  Error (scan_error "lstat" child_path error)
              in
              let* entry =
                if stat.Unix.st_kind = Unix.S_DIR then
                  let* child = scan_directory child_relative child_path in
                  Ok (Tree.Directory child)
                else if stat.Unix.st_kind = Unix.S_REG then
                  if stat.Unix.st_size > inline_file_limit then
                    Error
                      (File_too_large
                         {
                           path = child_path;
                           size = stat.Unix.st_size;
                           limit = inline_file_limit;
                         })
                  else
                    let* contents = read_file child_path stat.Unix.st_size in
                    let* content = Content.store store contents in
                    let mode =
                      if stat.Unix.st_perm land 0o111 = 0 then Regular
                      else Executable
                    in
                    Ok (Tree.File { mode; content })
                else if stat.Unix.st_kind = Unix.S_LNK then
                  let* target =
                    try Ok (Unix.readlink child_path)
                    with Unix.Unix_error (error, _, _) ->
                      Error (scan_error "readlink" child_path error)
                  in
                  let* content = Content.store store target in
                  Ok (Tree.File { mode = Symlink; content })
                else
                  Error
                    (Unsupported_file_type
                       {
                         path = child_path;
                         kind = "non-regular filesystem node";
                       })
              in
              scan_entries ((name, entry) :: reversed) rest
      in
      let* tree = scan_entries [] names in
      Tree.store store tree
    in
    let* root_tree = scan_directory [] root in
    let snapshot = Snapshot.create ~root:root_tree in
    let* identity = Snapshot.store store snapshot in
    Ok (identity, snapshot)
