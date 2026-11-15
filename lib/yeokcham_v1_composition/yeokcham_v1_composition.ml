[@@@warning "-42"]

module Line_hunks = Line_hunks
module Core = Yeokcham_v1_model.Core
module S = Yeokcham_snapshot
module Raw = Yeokcham_store
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope

type path = string list

type entry =
  | Directory
  | File of { mode : S.file_mode; content : S.Content.id }

module Paths = Map.Make (struct
  type t = path

  let compare = Stdlib.compare
end)

module Names = Map.Make (String)

type tree = entry Paths.t

type error =
  | Invalid_input of string
  | Unavailable of string
  | Integrity of string
  | Conflicts of path list

let error_to_string = function
  | Invalid_input message -> "invalid composition input: " ^ message
  | Unavailable message -> "composition data unavailable: " ^ message
  | Integrity message -> "composition integrity failure: " ^ message
  | Conflicts paths ->
      "explicit composition decision required: "
      ^ String.concat ", "
          (List.map (fun path -> String.escaped (String.concat "/" path)) paths)

let ( let* ) = Result.bind

let[@warning "-4"] store_error = function
  | ( Raw.Io_error _ | Raw.File_size_changed _
    | Raw.Repository_not_initialized _ | Raw.Repository_incomplete _
    | Raw.Root_not_directory _ ) as error ->
      Unavailable (Raw.error_to_string error)
  | error -> Integrity (Raw.error_to_string error)

let[@warning "-4"] snapshot_error = function
  | S.Store_error error -> store_error error
  | error -> Integrity (S.error_to_string error)

let snapshot r = Result.map_error snapshot_error r
let stored r = Result.map_error store_error r

let construct r =
  Result.map_error (fun e -> Invalid_input (E.construction_error_to_string e)) r

let decoded result =
  Result.map_error
    (function
      | Invalid_input message -> Integrity message
      | (Unavailable _ | Integrity _ | Conflicts _) as error -> error)
    result

let array v = E.array v |> construct

let object_id id =
  Core.Object_id.of_raw (Raw.Stored_object_id.to_raw_bytes id)
  |> Result.map_error (fun e -> Integrity (Core.error_to_string e))

let raw_id id =
  Raw.Stored_object_id.of_raw_bytes (Core.Object_id.to_raw id) |> Option.get

let entries = Paths.bindings

let prefix parent path =
  List.length parent <= List.length path
  && List.for_all2 String.equal parent
       (List.filteri (fun i _ -> i < List.length parent) path)

let parent path = List.rev path |> List.tl |> List.rev

let valid_path path =
  let* _ =
    Yeokcham_v1_model.Path.of_components path
    |> Result.map_error (fun e ->
        Invalid_input (Yeokcham_v1_model.error_to_string e))
  in
  if List.mem ".yeokcham" path || List.hd path = ".git" then
    Error (Invalid_input "mandatory metadata path is outside public contents")
  else Ok ()

let tree values =
  let* result =
    List.fold_left
      (fun acc (path, entry) ->
        let* result = acc in
        let* () = valid_path path in
        if Paths.mem path result then
          Error (Invalid_input "duplicate tree path")
        else Ok (Paths.add path entry result))
      (Ok Paths.empty) values
  in
  let* () =
    Paths.fold
      (fun path _ acc ->
        let* () = acc in
        match parent path with
        | [] -> Ok ()
        | ancestor -> (
            match Paths.find_opt ancestor result with
            | Some Directory -> Ok ()
            | None | Some (File _) -> Error (Conflicts [ ancestor ])))
      result (Ok ())
  in
  Ok result

let[@warning "-4"] load store id =
  let* snapshot_value =
    S.Snapshot.load store (S.Snapshot.of_stored_object_id (raw_id id))
    |> snapshot
  in
  let* _ =
    S.Materialize.plan store snapshot_value
    |> Result.map_error (function
      | S.Materialize.Snapshot_error error -> snapshot_error error
      | error -> Integrity (S.Materialize.error_to_string error))
  in
  let rec walk path root values =
    let* node = S.Tree.load store root |> snapshot in
    List.fold_left
      (fun acc (name, entry) ->
        let* values = acc in
        let path = path @ [ name ] in
        match entry with
        | S.Tree.File { mode; content } ->
            Ok ((path, File { mode; content }) :: values)
        | S.Tree.Directory id -> walk path id ((path, Directory) :: values))
      (Ok values) (S.Tree.entries node)
  in
  let* values = walk [] (S.Snapshot.root snapshot_value) [] in
  tree values |> decoded

type trie = Dir of trie Names.t | Leaf of S.file_mode * S.Content.id

let store repository values =
  let* _ = tree (entries values) in
  let rec insert node path entry =
    match (node, path) with
    | _, [] -> (
        match entry with
        | Directory -> Dir Names.empty
        | File { mode; content } -> Leaf (mode, content))
    | Dir names, name :: rest ->
        let child =
          Option.value (Names.find_opt name names) ~default:(Dir Names.empty)
        in
        Dir (Names.add name (insert child rest entry) names)
    | Leaf _, _ -> assert false
  in
  let root =
    Paths.fold
      (fun path entry root -> insert root path entry)
      values (Dir Names.empty)
  in
  let rec persist = function
    | Leaf _ -> assert false
    | Dir names ->
        let* entries =
          Names.fold
            (fun name value acc ->
              let* entries = acc in
              let* value =
                match value with
                | Leaf (mode, content) -> Ok (S.Tree.File { mode; content })
                | Dir _ ->
                    let* id = persist value in
                    Ok (S.Tree.Directory id)
              in
              Ok ((name, value) :: entries))
            names (Ok [])
        in
        let* node = S.Tree.create (List.rev entries) |> snapshot in
        S.Tree.store repository node |> snapshot
  in
  let* root = persist root in
  let value = S.Snapshot.create ~root in
  let* id = S.Snapshot.store repository value |> snapshot in
  object_id (S.Snapshot.stored_object_id id)

let equal_entry a b =
  match (a, b) with
  | None, None | Some Directory, Some Directory -> true
  | Some (File a), Some (File b) ->
      a.mode = b.mode && S.Content.equal_id a.content b.content
  | None, Some _
  | Some _, None
  | Some Directory, Some (File _)
  | Some (File _), Some Directory ->
      false

let paths trees =
  List.fold_left
    (fun set tree ->
      Paths.fold (fun path _ set -> Paths.add path Directory set) tree set)
    Paths.empty trees
  |> Paths.bindings |> List.map fst

let differences before after =
  paths [ before; after ]
  |> List.filter (fun path ->
      not (equal_entry (Paths.find_opt path before) (Paths.find_opt path after)))

let select ~base ~observed ~paths:selected ~excluded =
  let* () =
    List.fold_left
      (fun acc path ->
        let* () = acc in
        valid_path path)
      (Ok ()) (selected @ excluded)
  in
  let* () =
    List.fold_left
      (fun acc selected ->
        let* () = acc in
        if
          List.exists
            (fun (path, _) -> prefix selected path)
            (entries base @ entries observed)
        then Ok ()
        else
          Error
            (Invalid_input
               ("selected path does not exist in saved or observed contents: "
               ^ String.escaped (String.concat "/" selected))))
      (Ok ()) selected
  in
  let selected_path path =
    (selected = [] || List.exists (fun root -> prefix root path) selected)
    && not (List.exists (fun root -> prefix root path) excluded)
  in
  let initial = Paths.filter (fun path _ -> not (selected_path path)) base in
  let result =
    Paths.fold
      (fun path entry result ->
        if selected_path path then Paths.add path entry result else result)
      observed initial
  in
  let rec ancestors path result =
    match parent path with
    | [] -> result
    | ancestor -> ancestors ancestor (Paths.add ancestor Directory result)
  in
  let result =
    Paths.fold (fun path _ result -> ancestors path result) result result
  in
  tree (entries result)

let merge repository ~base ~variants =
  let choose same before values =
    let changed = List.filter (fun value -> not (same value before)) values in
    match changed with
    | [] -> Ok before
    | value :: rest when List.for_all (same value) rest -> Ok value
    | _ -> Error ()
  in
  let merge_entry path =
    let before = Paths.find_opt path base
    and sides = List.map (Paths.find_opt path) variants in
    match choose equal_entry before sides with
    | Ok entry -> Ok entry
    | Error () -> (
        match before with
        | Some (File original) when original.mode <> S.Symlink ->
            let files =
              List.filter_map
                (function
                  | Some (File file) when file.mode <> S.Symlink ->
                      Some (file.mode, file.content)
                  | None | Some Directory | Some (File _) -> None)
                sides
            in
            if List.length files <> List.length sides then
              Error (Conflicts [ path ])
            else
              let* mode =
                choose ( = ) original.mode (List.map fst files)
                |> Result.map_error (fun () -> Conflicts [ path ])
              in
              let* content =
                match
                  choose S.Content.equal_id original.content
                    (List.map snd files)
                with
                | Ok content -> Ok content
                | Error () ->
                    let bounded id =
                      let* bytes =
                        S.Content.load_bounded repository
                          ~max_bytes:Line_hunks.max_bytes id
                        |> snapshot
                      in
                      match bytes with
                      | Some bytes -> Ok bytes
                      | None -> Error (Conflicts [ path ])
                    in
                    let* original = bounded original.content in
                    let* contents =
                      List.fold_left
                        (fun acc (_, id) ->
                          let* contents = acc in
                          let* bytes = bounded id in
                          Ok (bytes :: contents))
                        (Ok []) files
                    in
                    let* merged =
                      Line_hunks.merge ~base:original ~variants:contents
                      |> Result.map_error (fun _ -> Conflicts [ path ])
                    in
                    S.Content.store repository merged |> snapshot
              in
              Ok (Some (File { mode; content }))
        | None | Some Directory | Some (File _) -> Error (Conflicts [ path ]))
  in
  let result, conflicts, error =
    List.fold_left
      (fun (result, conflicts, error) path ->
        match merge_entry path with
        | Ok None -> (result, conflicts, error)
        | Ok (Some entry) -> (Paths.add path entry result, conflicts, error)
        | Error (Conflicts paths) -> (result, paths @ conflicts, error)
        | Error ((Invalid_input _ | Unavailable _ | Integrity _) as e) ->
            (result, conflicts, Some e))
      (Paths.empty, [], None)
      (paths (base :: variants))
  in
  match (error, conflicts) with
  | Some e, _ -> Error e
  | None, _ :: _ -> Error (Conflicts (List.sort_uniq Stdlib.compare conflicts))
  | None, [] -> tree (entries result)

module Scope = struct
  let max_page_bytes = 1024 * 1024

  let page kind values =
    let* payload = array [ E.integer 1L; E.integer kind; values ] in
    let* envelope =
      Envelope.create ~object_type:Envelope.Core_edit_scope
        ~object_format_version:1 ~mandatory_features:0L ~payload ()
      |> Result.map_error (fun e ->
          Integrity (Envelope.creation_error_to_string e))
    in
    if String.length (Envelope.encode envelope) > max_page_bytes then
      Error (Invalid_input "edit-scope page exceeds 1 MiB")
    else Ok envelope

  let path_value path = array (List.map E.bytes path)

  let chunks capacity values =
    let rec loop chunk length reversed = function
      | [] ->
          List.rev (if chunk = [] then reversed else List.rev chunk :: reversed)
      | value :: rest when length = capacity ->
          loop [] 0 (List.rev chunk :: reversed) (value :: rest)
      | value :: rest -> loop (value :: chunk) (length + 1) reversed rest
    in
    loop [] 0 [] values

  let build intern paths =
    let* () =
      List.fold_left
        (fun acc path ->
          let* () = acc in
          valid_path path)
        (Ok ()) paths
    in
    let paths = List.sort_uniq Stdlib.compare paths in
    let* values =
      List.fold_left
        (fun acc path ->
          let* values = acc in
          let* path = path_value path in
          Ok (path :: values))
        (Ok []) paths
      |> Result.map List.rev
    in
    let rec leaves pending length size reversed = function
      | [] ->
          let* payload = array (List.rev pending) in
          let* envelope = page 0L payload in
          let* id = intern envelope in
          Ok (List.rev (id :: reversed))
      | value :: rest
        when length = 128
             || size + String.length (E.encode value) > max_page_bytes - 64 ->
          if pending = [] then
            Error
              (Invalid_input "individual edit-scope path exceeds its page bound")
          else
            let* payload = array (List.rev pending) in
            let* envelope = page 0L payload in
            let* id = intern envelope in
            leaves [] 0 0 (id :: reversed) (value :: rest)
      | value :: rest ->
          leaves (value :: pending) (length + 1)
            (size + String.length (E.encode value))
            reversed rest
    in
    let* ids = leaves [] 0 0 [] values in
    let rec indexes = function
      | [ id ] -> Ok id
      | [] -> assert false
      | ids ->
          let* parents =
            List.fold_left
              (fun acc ids ->
                let* parents = acc in
                let* payload =
                  array
                    (List.map
                       (fun id ->
                         E.bytes (Raw.Stored_object_id.to_raw_bytes id))
                       ids)
                in
                let* envelope = page 1L payload in
                let* id = intern envelope in
                Ok (id :: parents))
              (Ok []) (chunks 128 ids)
          in
          indexes (List.rev parents)
    in
    indexes ids

  let store repository paths =
    let* id =
      build (fun envelope -> Raw.put repository envelope |> stored) paths
    in
    object_id id

  let[@warning "-4"] read repository root =
    let visited = Hashtbl.create 32 in
    let rec walk depth id =
      if depth > 32 || Hashtbl.mem visited id then
        Error (Integrity "cyclic, repeated or excessively deep scope page")
      else (
        Hashtbl.add visited id ();
        let* bytes =
          Raw.read_file_bounded
            ~path:(Raw.object_path repository id)
            ~max_bytes:max_page_bytes
          |> stored
        in
        let* envelope =
          Envelope.decode bytes
          |> Result.map_error (fun e ->
              Integrity (Envelope.decode_error_to_string e))
        in
        if
          Envelope.object_type envelope <> Envelope.Core_edit_scope
          || not (Raw.Stored_object_id.equal id (Raw.id_of_envelope envelope))
        then Error (Integrity "wrong edit-scope page type or identity")
        else
          match Envelope.payload envelope with
          | E.Array [ E.Integer 1L; E.Integer 0L; E.Array values ]
            when List.length values <= 128 ->
              List.fold_left
                (fun acc -> function
                  | E.Array parts ->
                      let* paths = acc in
                      let* path =
                        List.fold_left
                          (fun acc -> function
                            | E.Bytes part ->
                                let* parts = acc in
                                Ok (part :: parts)
                            | _ ->
                                Error
                                  (Integrity
                                     "scope path components must be bytes"))
                          (Ok []) parts
                        |> Result.map List.rev
                      in
                      let* () = valid_path path |> decoded in
                      Ok (path :: paths)
                  | _ -> Error (Integrity "invalid scope path"))
                (Ok []) values
              |> Result.map List.rev
          | E.Array [ E.Integer 1L; E.Integer 1L; E.Array values ]
            when values <> [] && List.length values <= 128 ->
              List.fold_left
                (fun acc -> function
                  | E.Bytes raw ->
                      let* paths = acc in
                      let* child =
                        Raw.Stored_object_id.of_raw_bytes raw
                        |> Option.to_result
                             ~none:(Integrity "malformed scope child reference")
                      in
                      let* more = walk (depth + 1) child in
                      Ok (more :: paths)
                  | _ -> Error (Integrity "scope child must be an object ID"))
                (Ok []) values
              |> Result.map (fun paths -> List.concat (List.rev paths))
          | _ -> Error (Integrity "unsupported or malformed edit-scope page"))
    in
    let* paths = walk 0 (raw_id root) in
    let* expected =
      build (fun envelope -> Ok (Raw.id_of_envelope envelope)) paths |> decoded
    in
    if not (Raw.Stored_object_id.equal expected (raw_id root)) then
      Error (Integrity "noncanonical scope order, duplicate or pagination")
    else
      Ok
        ( paths,
          Hashtbl.to_seq_keys visited
          |> List.of_seq
          |> List.sort Raw.Stored_object_id.compare )

  let load repository root = read repository root |> Result.map fst
  let closure repository root = read repository root |> Result.map snd
end

let validate_revision repository revision =
  let* before = load repository revision.Core.base_snapshot in
  let* after = load repository revision.Core.result_snapshot in
  let* declared = Scope.load repository revision.Core.edit_scope_root in
  if differences before after = declared then Ok ()
  else
    Error
      (Integrity "declared edit scope differs from actual base/result contents")
