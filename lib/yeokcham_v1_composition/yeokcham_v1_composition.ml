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

let validate_path = valid_path

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

let overlay ~base changes =
  let* values =
    List.fold_left
      (fun acc (path, entry) ->
        let* values = acc in
        let* () = valid_path path in
        let values =
          match entry with
          | Some Directory -> values
          | None | Some (File _) ->
              Paths.filter
                (fun candidate _ -> not (prefix path candidate))
                values
        in
        Ok
          (match entry with
          | None -> Paths.remove path values
          | Some entry -> Paths.add path entry values))
      (Ok base) changes
  in
  tree (Paths.bindings values)

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

let minimal_paths paths =
  List.sort_uniq Stdlib.compare paths
  |> List.filter (fun path ->
      not
        (List.exists
           (fun ancestor -> ancestor <> path && prefix ancestor path)
           paths))

let replace_subtree ~base:target ~path ~replacement =
  let* () = valid_path path in
  let result =
    Paths.filter (fun candidate _ -> not (prefix path candidate)) target
  in
  let subtree =
    Paths.filter (fun candidate _ -> prefix path candidate) replacement
  in
  let* result =
    Paths.fold
      (fun candidate entry acc ->
        let* result = acc in
        let rec ensure ancestor result =
          match ancestor with
          | [] -> Ok result
          | ancestor -> (
              match Paths.find_opt ancestor result with
              | Some (File _) -> Error (Conflicts [ ancestor ])
              | Some Directory | None ->
                  ensure (parent ancestor) (Paths.add ancestor Directory result)
              )
        in
        let* result = ensure (parent candidate) result in
        Ok (Paths.add candidate entry result))
      subtree (Ok result)
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

let validate_decision ~base ~path ~replacement =
  let* expected = replace_subtree ~base ~path ~replacement in
  if differences expected replacement = [] then Ok ()
  else
    Error
      (Invalid_input
         "replacement changes contents outside its explicit decision")

let merge_resolved repository ~base ~variants ~decisions =
  let* () =
    if List.length decisions <= Core.max_references then Ok ()
    else Error (Invalid_input "too many workspace decisions")
  in
  let* _ =
    List.fold_left
      (fun acc (path, replacement) ->
        let* seen = acc in
        let* () = validate_decision ~base ~path ~replacement in
        if
          List.exists
            (fun previous -> prefix previous path || prefix path previous)
            seen
        then Error (Invalid_input "overlapping workspace decisions")
        else Ok (path :: seen))
      (Ok []) decisions
  in
  let mask paths tree =
    Paths.filter
      (fun path _ -> not (List.exists (fun chosen -> prefix chosen path) paths))
      tree
  in
  let rec apply installed pending =
    match
      merge repository
        ~base:(mask (List.map fst installed) base)
        ~variants:(List.map (mask (List.map fst installed)) variants)
    with
    | Error (Conflicts paths) ->
        let paths = minimal_paths paths in
        let ready, pending =
          List.partition (fun (path, _) -> List.mem path paths) pending
        in
        if ready = [] then
          if pending = [] then Error (Conflicts paths)
          else
            Error
              (Invalid_input "workspace decision does not address a conflict")
        else apply (installed @ ready) pending
    | Error ((Invalid_input _ | Unavailable _ | Integrity _) as error) ->
        Error error
    | Ok _ when pending <> [] ->
        Error
          (Invalid_input
             "workspace decision targets contents that do not conflict")
    | Ok target ->
        List.fold_left
          (fun acc (path, replacement) ->
            let* target = acc in
            replace_subtree ~base:target ~path ~replacement)
          (Ok target) installed
  in
  apply [] (List.sort (fun (a, _) (b, _) -> Stdlib.compare a b) decisions)

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

module Witness = struct
  let inspect repository ~snapshot:identity ~paths =
    let* () =
      List.fold_left
        (fun acc path ->
          let* () = acc in
          valid_path path)
        (Ok ()) paths
    in
    let* value =
      S.Snapshot.load_metadata repository
        (S.Snapshot.of_stored_object_id (raw_id identity))
      |> snapshot
    in
    let objects = Hashtbl.create 32 in
    Hashtbl.add objects (raw_id identity) ();
    let trees = Hashtbl.create 32 in
    let get_tree id =
      let raw = S.Tree.stored_object_id id in
      match Hashtbl.find_opt trees raw with
      | Some tree -> Ok tree
      | None ->
          let* tree = S.Tree.load_metadata repository id |> snapshot in
          Hashtbl.add trees raw tree;
          Hashtbl.replace objects raw ();
          Ok tree
    in
    let rec find id = function
      | [] -> Error (Invalid_input "witness path is empty")
      | name :: rest -> (
          let* tree = get_tree id in
          match (List.assoc_opt name (S.Tree.entries tree), rest) with
          | None, _ | Some (S.Tree.File _), _ :: _ -> Ok None
          | Some (S.Tree.Directory _), [] -> Ok (Some Directory)
          | Some (S.Tree.File { mode; content }), [] ->
              Ok (Some (File { mode; content }))
          | Some (S.Tree.Directory id), _ :: _ -> find id rest)
    in
    let* entries =
      List.fold_left
        (fun acc path ->
          let* entries = acc in
          let* entry = find (S.Snapshot.root value) path in
          Ok ((path, entry) :: entries))
        (Ok []) paths
      |> Result.map List.rev
    in
    Ok
      ( entries,
        Hashtbl.to_seq_keys objects
        |> List.of_seq
        |> List.sort Raw.Stored_object_id.compare )
end

module Graph = struct
  type failure =
    | Content_error of error
    | Invalid_graph of string
    | Decision of string

  let error_to_string = function
    | Content_error error -> error_to_string error
    | Invalid_graph detail -> "invalid shared graph: " ^ detail
    | Decision detail -> "shared graph needs an explicit decision: " ^ detail

  let content result =
    Result.map_error (fun error -> Content_error error) result

  module Ids = Set.Make (Core.Record_id)
  module Objects = Map.Make (Core.Object_id)

  let body pool id =
    Core.find pool id
    |> Option.to_result
         ~none:(Invalid_graph ("missing record " ^ Core.Record_id.to_hex id))

  let accepted pool id =
    let* body = body pool id in
    match body.Core.payload with
    | Core.Accepted_version value -> Ok value
    | Core.Shared_revision _ | Core.Branch_event _ | Core.Resolution_revision _
      ->
        Error (Invalid_graph "expected an accepted version")

  let revision pool id =
    let* body = body pool id in
    match body.Core.payload with
    | Core.Shared_revision value -> Ok value
    | Core.Accepted_version _ | Core.Branch_event _ | Core.Resolution_revision _
      ->
        Error (Invalid_graph "expected a shared revision")

  let rec ancestors pool seen = function
    | [] -> Ok seen
    | id :: rest when Ids.mem id seen -> ancestors pool seen rest
    | id :: rest ->
        let* value = accepted pool id in
        ancestors pool (Ids.add id seen) (value.Core.accepted_parents @ rest)

  let common_base pool heads =
    match heads with
    | [] -> Error (Decision "no accepted parent provides a base")
    | first :: rest -> (
        let* first = ancestors pool Ids.empty [ first ] in
        let* common =
          List.fold_left
            (fun acc id ->
              let* common = acc in
              let* ids = ancestors pool Ids.empty [ id ] in
              Ok (Ids.inter common ids))
            (Ok first) rest
        in
        let* inherited =
          Ids.fold
            (fun id acc ->
              let* inherited = acc in
              let* value = accepted pool id in
              let* parents =
                ancestors pool Ids.empty value.Core.accepted_parents
              in
              Ok (Ids.union inherited parents))
            common (Ok Ids.empty)
        in
        match Ids.elements (Ids.diff common inherited) with
        | [ id ] -> Ok id
        | [] ->
            Error (Decision "accepted histories have no recorded common base")
        | _ -> Error (Decision "multiple incomparable accepted merge bases"))

  let rec revision_closure pool seen ids =
    match ids with
    | [] -> Ok seen
    | id :: rest when Ids.mem id seen -> revision_closure pool seen rest
    | id :: rest ->
        let* value = revision pool id in
        revision_closure pool (Ids.add id seen) (value.Core.dependencies @ rest)

  let represented_revisions pool roots =
    let rec walk seen = function
      | [] -> Ok (Ids.elements seen)
      | id :: rest when Ids.mem id seen -> walk seen rest
      | id :: rest ->
          let* value = revision pool id in
          walk (Ids.add id seen)
            (value.Core.previous_revisions @ value.Core.dependencies @ rest)
    in
    walk Ids.empty roots

  let represented pool heads =
    let* versions = ancestors pool Ids.empty heads in
    let* roots =
      Ids.fold
        (fun id acc ->
          let* roots = acc in
          let* value = accepted pool id in
          Ok (value.Core.chosen_revisions @ roots))
        versions (Ok [])
    in
    represented_revisions pool roots

  let reconciled_base pool ~accepted_versions ~previous_revisions ~base_snapshot
      =
    List.fold_left
      (fun acc id ->
        let* found = acc in
        if found then Ok true
        else
          let* value = accepted pool id in
          if not (Core.Object_id.equal value.Core.result_snapshot base_snapshot)
          then Ok false
          else
            let* represented = represented pool [ id ] in
            Ok
              (List.for_all
                 (fun previous ->
                   List.exists (Core.Record_id.equal previous) represented)
                 previous_revisions))
      (Ok false) accepted_versions

  let rec revision_ancestors pool seen = function
    | [] -> Ok seen
    | id :: rest when Ids.mem id seen -> revision_ancestors pool seen rest
    | id :: rest ->
        let* value = revision pool id in
        revision_ancestors pool (Ids.add id seen)
          (value.Core.previous_revisions @ rest)

  type context = {
    repository : Raw.repository;
    pool : Core.pool;
    mutable loaded : tree Objects.t;
  }

  let context repository pool = { repository; pool; loaded = Objects.empty }

  let load context id =
    match Objects.find_opt id context.loaded with
    | Some tree -> Ok tree
    | None ->
        let* tree = load context.repository id |> content in
        context.loaded <- Objects.add id tree context.loaded;
        Ok tree

  let validate_revision context value =
    let* before = load context value.Core.base_snapshot in
    let* after = load context value.Core.result_snapshot in
    let* scope =
      Scope.load context.repository value.Core.edit_scope_root |> content
    in
    if differences before after = scope then Ok ()
    else
      Error
        (Invalid_graph "revision changes paths outside its exact declared scope")

  let effective_base context accepted_ancestors applied value =
    let maximal previous =
      let* inherited =
        List.fold_left
          (fun acc id ->
            let* acc = acc in
            let* value = revision context.pool id in
            let* ancestors =
              revision_ancestors context.pool Ids.empty
                value.Core.previous_revisions
            in
            Ok (Ids.union acc ancestors))
          (Ok Ids.empty) previous
      in
      Ok (List.filter (fun id -> not (Ids.mem id inherited)) previous)
    in
    let* all_previous = maximal value.Core.previous_revisions in
    match all_previous with
    | [] | [ _ ] -> (
        let* previous =
          maximal
            (List.filter
               (fun id -> Ids.mem id applied)
               value.Core.previous_revisions)
        in
        match previous with
        | [] -> Ok value.Core.base_snapshot
        | [ id ] ->
            let* previous = revision context.pool id in
            Ok previous.Core.result_snapshot
        | _ ->
            Error
              (Decision
                 "updated revision has incomparable represented predecessors"))
    | _ :: _ :: _ ->
        let* reconciled =
          reconciled_base context.pool
            ~accepted_versions:(Ids.elements accepted_ancestors)
            ~previous_revisions:value.Core.previous_revisions
            ~base_snapshot:value.Core.base_snapshot
        in
        if reconciled then Ok value.Core.base_snapshot
        else
          Error
            (Decision
               "updated revision has incomparable represented predecessors \
                without a recorded accepted reconciliation base")

  let public_base context accepted_ancestors applied value =
    let* from_accepted =
      Ids.fold
        (fun id acc ->
          let* found = acc in
          let* version = accepted context.pool id in
          Ok
            (found
            || Core.Object_id.equal version.Core.result_snapshot
                 value.Core.base_snapshot))
        accepted_ancestors (Ok false)
    in
    if from_accepted then Ok ()
    else
      let* from_dependency =
        List.fold_left
          (fun acc id ->
            let* found = acc in
            let* dependency = revision context.pool id in
            Ok
              (found
              || Ids.mem id applied
                 && Core.Object_id.equal dependency.Core.result_snapshot
                      value.Core.base_snapshot))
          (Ok false) value.Core.dependencies
      in
      if from_dependency then Ok ()
      else
        Error
          (Decision
             "revision base has no unambiguous accepted/dependency \
              correspondence at this target")

  let comparison_snapshot pool parents =
    let* common = common_base pool parents in
    let* version = accepted pool common in
    Ok version.Core.result_snapshot

  let resolution pool id =
    let* body = body pool id in
    match body.Core.payload with
    | Core.Resolution_revision value -> Ok value
    | Core.Shared_revision _ | Core.Accepted_version _ | Core.Branch_event _ ->
        Error (Invalid_graph "expected a resolution revision")

  let validate_resolution context (value : Core.resolution_revision) =
    let* comparison =
      comparison_snapshot context.pool value.Core.accepted_heads
    in
    if not (Core.Object_id.equal comparison value.Core.comparison_snapshot) then
      Error
        (Invalid_graph
           "resolution comparison differs from its recorded common accepted \
            base")
    else
      let* before = load context comparison in
      let* replacement = load context value.Core.replacement_snapshot in
      let* scope =
        Scope.load context.repository value.Core.decision_scope_root |> content
      in
      match scope with
      | [ path ] ->
          let* expected =
            replace_subtree ~base:before ~path ~replacement |> content
          in
          if differences expected replacement = [] then Ok (path, replacement)
          else
            Error
              (Invalid_graph
                 "resolution replacement changes contents outside its decided \
                  path")
      | [] | _ :: _ :: _ ->
          Error (Invalid_graph "resolution scope must contain exactly one path")

  let compose_unresolved context ~masked ~parents ~revisions =
    let mask tree =
      Paths.filter
        (fun path _ ->
          not (List.exists (fun chosen -> prefix chosen path) masked))
        tree
    in
    let merge_here ~base ~variants =
      merge context.repository ~base:(mask base)
        ~variants:(List.map mask variants)
    in

    let* parents_ancestry = ancestors context.pool Ids.empty parents in
    let* represented =
      represented context.pool parents |> Result.map Ids.of_list
    in
    let* pending =
      revision_closure context.pool Ids.empty revisions
      |> Result.map (fun ids -> Ids.diff ids represented)
    in
    let* () =
      Ids.fold
        (fun id acc ->
          let* () = acc in
          let* value = revision context.pool id in
          validate_revision context value)
        pending (Ok ())
    in
    let* () =
      Ids.fold
        (fun id acc ->
          let* () = acc in
          let* value = revision context.pool id in
          Ids.fold
            (fun other acc ->
              let* () = acc in
              let* other_value = revision context.pool other in
              if
                (not (Core.Record_id.equal id other))
                && Core.Change_id.equal value.Core.change
                     other_value.Core.change
              then
                let* first = revision_ancestors context.pool Ids.empty [ id ] in
                let* second =
                  revision_ancestors context.pool Ids.empty [ other ]
                in
                if Ids.mem other first || Ids.mem id second then Ok ()
                else
                  let* first =
                    Scope.load context.repository value.Core.edit_scope_root
                    |> content
                  in
                  let* second =
                    Scope.load context.repository
                      other_value.Core.edit_scope_root
                    |> content
                  in
                  let conflicts =
                    minimal_paths (first @ second)
                    |> List.filter (fun path ->
                        not
                          (List.exists
                             (fun chosen -> prefix chosen path)
                             masked))
                  in
                  if first = [] && second = [] then
                    Error
                      (Decision
                         "concurrent unchanged versions require exact revision \
                          selection")
                  else if conflicts = [] then Ok ()
                  else Error (Content_error (Conflicts conflicts))
              else Ok ())
            pending (Ok ()))
        pending (Ok ())
    in
    let* target =
      match parents with
      | [] when revisions = [] -> Ok Paths.empty
      | [] -> Error (Invalid_graph "genesis cannot accept chosen work")
      | [ id ] ->
          let* value = accepted context.pool id in
          load context value.Core.result_snapshot
      | _ ->
          let* common = common_base context.pool parents in
          let* version = accepted context.pool common in
          let* base = load context version.Core.result_snapshot in
          let* variants =
            List.fold_left
              (fun acc id ->
                let* variants = acc in
                let* version = accepted context.pool id in
                let* tree = load context version.Core.result_snapshot in
                Ok (tree :: variants))
              (Ok []) parents
          in
          merge_here ~base ~variants |> content
    in
    let rec layers target applied pending =
      if Ids.is_empty pending then Ok target
      else
        let* ready =
          Ids.fold
            (fun id acc ->
              let* ready = acc in
              let* value = revision context.pool id in
              if
                List.for_all
                  (fun dependency -> Ids.mem dependency applied)
                  value.Core.dependencies
                && List.for_all
                     (fun previous -> not (Ids.mem previous pending))
                     value.Core.previous_revisions
              then Ok (id :: ready)
              else Ok ready)
            pending (Ok [])
        in
        if ready = [] then
          Error (Invalid_graph "revision dependencies do not form a usable DAG")
        else
          let* variants =
            List.fold_left
              (fun acc id ->
                let* variants = acc in
                let* value = revision context.pool id in
                let* () = public_base context parents_ancestry applied value in
                let* base =
                  effective_base context parents_ancestry applied value
                in
                let* base = load context base in
                let* changed = load context value.Core.result_snapshot in
                let* combined =
                  merge_here ~base ~variants:[ target; changed ] |> content
                in
                Ok (combined :: variants))
              (Ok []) ready
          in
          let* combined = merge_here ~base:target ~variants |> content in
          let ready = Ids.of_list ready in
          layers combined (Ids.union applied ready) (Ids.diff pending ready)
    in
    layers (mask target) represented pending

  let compose_with context ~parents ~revisions ~resolutions =
    let* decisions =
      List.fold_left
        (fun acc id ->
          let* decisions = acc in
          let* value = resolution context.pool id in
          if
            value.Core.accepted_heads
            <> List.sort_uniq Core.Record_id.compare parents
            || value.Core.chosen_revisions
               <> List.sort_uniq Core.Record_id.compare revisions
          then
            Error
              (Invalid_graph
                 "resolution names different exact accepted/revision variants")
          else
            let* path, replacement = validate_resolution context value in
            if
              List.exists
                (fun (previous, _) ->
                  prefix previous path || prefix path previous)
                decisions
            then Error (Invalid_graph "overlapping resolution decisions")
            else Ok ((path, replacement) :: decisions))
        (Ok []) resolutions
    in
    let rec apply installed pending =
      match
        compose_unresolved context ~masked:(List.map fst installed) ~parents
          ~revisions
      with
      | Error (Content_error (Conflicts conflicts)) ->
          let conflicts = minimal_paths conflicts in
          let ready, pending =
            List.partition (fun (path, _) -> List.mem path conflicts) pending
          in
          if ready = [] then
            if pending = [] then Error (Content_error (Conflicts conflicts))
            else
              Error
                (Invalid_graph
                   "resolution does not address a reachable conflict")
          else apply (installed @ ready) pending
      | Error
          (( Invalid_graph _ | Decision _
           | Content_error (Invalid_input _ | Unavailable _ | Integrity _) ) as
           error) ->
          Error error
      | Ok _ when pending <> [] ->
          Error
            (Invalid_graph "resolution targets contents that do not conflict")
      | Ok target ->
          List.fold_left
            (fun acc (path, replacement) ->
              let* target = acc in
              replace_subtree ~base:target ~path ~replacement |> content)
            (Ok target) installed
    in
    apply [] decisions

  let compose ?(resolutions = []) repository pool ~parents ~revisions =
    compose_with (context repository pool) ~parents ~revisions ~resolutions

  let event pool id =
    let* body = body pool id in
    match body.Core.payload with
    | Core.Branch_event value -> Ok value
    | Core.Shared_revision _ | Core.Accepted_version _
    | Core.Resolution_revision _ ->
        Error (Invalid_graph "expected a branch event")

  let rec event_targets pool seen ids =
    match ids with
    | [] -> Ok Ids.empty
    | id :: rest when Ids.mem id seen -> event_targets pool seen rest
    | id :: rest ->
        let* value = event pool id in
        let* other = event_targets pool (Ids.add id seen) rest in
        let* targets =
          match value.Core.action with
          | Core.Rename ->
              event_targets pool (Ids.add id seen) value.Core.previous_events
          | Core.Create | Core.Advance | Core.Reconcile ->
              Ok (Ids.of_list value.Core.targets)
        in
        Ok (Ids.union targets other)

  let validate repository pool =
    let context = context repository pool in
    let* () =
      List.fold_left
        (fun acc (_, body) ->
          let* () = acc in
          match body.Core.payload with
          | Core.Shared_revision value ->
              let* () = validate_revision context value in
              let from_accepted =
                List.exists
                  (fun (_, body) ->
                    match body.Core.payload with
                    | Core.Accepted_version accepted ->
                        Core.Object_id.equal accepted.Core.result_snapshot
                          value.Core.base_snapshot
                    | Core.Shared_revision _ | Core.Branch_event _
                    | Core.Resolution_revision _ ->
                        false)
                  (Core.records pool)
              in
              let* from_dependency =
                List.fold_left
                  (fun acc id ->
                    let* found = acc in
                    let* previous = revision pool id in
                    Ok
                      (found
                      || Core.Object_id.equal previous.Core.result_snapshot
                           value.Core.base_snapshot))
                  (Ok false)
                  (value.Core.dependencies @ value.Core.previous_revisions)
              in
              if from_accepted || from_dependency then Ok ()
              else
                Error
                  (Invalid_graph
                     "shared revision base is not a recorded \
                      accepted/dependency snapshot")
          | Core.Resolution_revision value ->
              let* _ = validate_resolution context value in
              Ok ()
          | Core.Accepted_version _ | Core.Branch_event _ -> Ok ())
        (Ok ()) (Core.records pool)
    in
    let verified = ref Ids.empty and visiting = ref Ids.empty in
    let rec verify id =
      if Ids.mem id !verified then Ok ()
      else if Ids.mem id !visiting then
        Error (Invalid_graph "accepted-result cycle")
      else
        let* value = accepted pool id in
        visiting := Ids.add id !visiting;
        let* () =
          List.fold_left
            (fun acc parent ->
              let* () = acc in
              verify parent)
            (Ok ()) value.Core.accepted_parents
        in
        let* () =
          if value.Core.policy_heads = [] && value.Core.review_evidence = []
          then Ok ()
          else
            Error
              (Decision
                 "required policy/review semantics are unsupported by this \
                  verifier")
        in
        let* actual = load context value.Core.result_snapshot in
        let* expected =
          compose_with context ~parents:value.Core.accepted_parents
            ~revisions:value.Core.chosen_revisions
            ~resolutions:value.Core.resolutions
        in
        if differences expected actual <> [] then
          Error
            (Invalid_graph
               "accepted snapshot does not equal deterministic composition of \
                its exact parents/revisions")
        else (
          visiting := Ids.remove id !visiting;
          verified := Ids.add id !verified;
          Ok ())
    in
    let* () =
      List.fold_left
        (fun acc (id, body) ->
          let* () = acc in
          match body.Core.payload with
          | Core.Accepted_version _ -> verify id
          | Core.Shared_revision _ | Core.Branch_event _
          | Core.Resolution_revision _ ->
              Ok ())
        (Ok ()) (Core.records pool)
    in
    List.fold_left
      (fun acc (_, body) ->
        let* () = acc in
        match body.Core.payload with
        | Core.Shared_revision _ | Core.Accepted_version _
        | Core.Resolution_revision _ ->
            Ok ()
        | Core.Branch_event value -> (
            match value.Core.action with
            | Core.Rename -> Ok ()
            | Core.Create | Core.Advance | Core.Reconcile ->
                let* inherited =
                  event_targets pool Ids.empty value.Core.previous_events
                in
                let* selected = ancestors pool Ids.empty value.Core.targets in
                if Ids.subset inherited selected then Ok ()
                else
                  Error
                    (Invalid_graph
                       "branch update would discard an inherited accepted head")
            ))
      (Ok ()) (Core.records pool)
end
