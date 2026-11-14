module S = Yeokcham_snapshot
module F = S.Filesystem
module E = Yeokcham_encoding
module Store = Yeokcham_store
module Hash = Yeokcham_hash.Sha256

type boundary = Before_mutation | After_mutation | After_sync

type action = {
  path : string list;
  before : (string list * string) list;
  after : (string list * string) list;
  slot : string;
}

type t = {
  operation : string;
  safety : string;
  target : string;
  root : string;
  destination_parent : (string * string) option;
  parents : (string list * string) list;
  actions : action list;
  bytes : string;
}

type error =
  | Conflict of string
  | Unavailable of string
  | Invalid_plan of string

let error_to_string = function
  | Conflict detail | Unavailable detail | Invalid_plan detail -> detail

exception Invalid_plan_bytes of string
exception Refusal of string

let refuse message = raise (Refusal message)
let require render = function Ok x -> x | Error e -> refuse (render e)

let guard f =
  try Ok (f ()) with
  | Invalid_plan_bytes message -> Error (Invalid_plan message)
  | Refusal message -> Error (Conflict message)
  | Unix.Unix_error (e, call, name) ->
      let detail =
        Printf.sprintf "%s %S: %s; live and retained files were not rolled back"
          call name (Unix.error_message e)
      in
      Error
        ((if e = Unix.EEXIST then fun x -> Conflict x
          else fun x -> Unavailable x)
           detail)
  | Sys_error message | Failure message -> Error (Unavailable message)

let[@warning "-4"] require_snapshot = function
  | Ok value -> value
  | Error ((S.Scan_error _ | S.Store_error (Store.Io_error _)) as error) ->
      raise (Failure (S.error_to_string error))
  | Error error -> raise (Invalid_plan_bytes (S.error_to_string error))

let[@warning "-4"] require_target_plan = function
  | Ok value -> value
  | Error (S.Materialize.Snapshot_error error) -> require_snapshot (Error error)
  | Error error -> refuse (S.Materialize.error_to_string error)

let close fd f = Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd)
let open_root root f = close (F.open_at None root true) f

let rec directory fd path f =
  match path with
  | [] -> f fd
  | name :: rest ->
      close (F.open_at (Some fd) name true) (fun child ->
          directory child rest f)

let parent fd path f =
  match List.rev path with
  | [] -> refuse "application action cannot replace the workspace root"
  | name :: rest -> directory fd (List.rev rest) (fun p -> f p name)

let inspect fd name =
  try Some (F.inspect_at fd name)
  with Unix.Unix_error (Unix.ENOENT, _, _) -> None

let exists fd name = Option.is_some (inspect fd name)

let rec prefix left right =
  match (left, right) with
  | [], _ -> true
  | x :: xs, y :: ys when x = y -> prefix xs ys
  | _ -> false

let safe_name name =
  name <> "" && name <> "." && name <> ".."
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let valid_path path =
  path <> []
  && List.for_all safe_name path
  && (not (List.mem ".yeokcham" path))
  && List.hd path <> ".git"

let check_operation operation =
  if
    String.length operation <> 64
    || not
         (String.for_all
            (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
            operation)
  then refuse "invalid application operation identity"

let retained_directory ~root ~operation =
  Filename.concat
    (Filename.concat (Filename.concat root ".yeokcham") "restore-staging")
    operation

let stamp_matches expected actual =
  String.equal (F.stable expected) (F.stable actual)

let snapshot_bytes id =
  S.Snapshot.stored_object_id id |> Store.Stored_object_id.to_raw_bytes

let array xs = E.array xs |> require E.construction_error_to_string

let stamps_value stamps =
  stamps
  |> List.map (fun (path, stamp) ->
      array [ array (List.map E.bytes path); E.bytes stamp ])
  |> array

let encode t =
  array
    ([
       E.integer (if t.destination_parent = None then 1L else 2L);
       E.bytes t.operation;
       E.bytes t.safety;
       E.bytes t.target;
       E.bytes t.root;
       stamps_value t.parents;
       array
         (List.map
            (fun a ->
              array
                [
                  array (List.map E.bytes a.path);
                  E.bytes a.slot;
                  stamps_value a.before;
                  stamps_value a.after;
                ])
            t.actions);
     ]
    @ Option.fold ~none:[]
        ~some:(fun (parent, repository) ->
          [ E.bytes parent; E.bytes repository ])
        t.destination_parent)
  |> E.encode

let digest t = Hash.digest_string t.bytes |> Hash.to_raw_string

let write_all fd bytes =
  let rec loop offset =
    if offset < String.length bytes then
      let count =
        Unix.write_substring fd bytes offset (String.length bytes - offset)
      in
      if count = 0 then refuse "short staging write" else loop (offset + count)
  in
  loop 0

let ensure_directory fd name =
  if not (exists fd name) then (
    F.mkdir_at fd name;
    Unix.fsync fd);
  close (F.open_at (Some fd) name true) (fun _ -> ())

let with_staging root operation f =
  open_root root (fun rootfd ->
      directory rootfd [ ".yeokcham"; "restore-staging"; operation ]
        (fun staging -> f rootfd staging))

let entry_equal a b =
  match (a, b) with
  | S.Tree.Directory a, S.Tree.Directory b -> S.Tree.equal_id a b
  | S.Tree.File a, S.Tree.File b ->
      a.mode = b.mode && S.Content.equal_id a.content b.content
  | S.Tree.Directory _, S.Tree.File _ | S.Tree.File _, S.Tree.Directory _ ->
      false

let entries store id =
  S.Tree.load store id |> require_snapshot |> S.Tree.entries

let rec create_entry store fd name = function
  | S.Tree.Directory id ->
      F.mkdir_at fd name;
      close (F.open_at (Some fd) name true) (fun child ->
          List.iter
            (fun (name, e) -> create_entry store child name e)
            (entries store id);
          Unix.fsync child)
  | S.Tree.File { mode = S.Symlink; content } ->
      let target =
        S.Content.load_bounded store ~max_bytes:65536 content
        |> require_snapshot
      in
      let target =
        match target with
        | Some t when t <> "" && not (String.contains t '\000') -> t
        | _ -> refuse "unrepresentable symlink target"
      in
      F.symlink_at fd name target
  | S.Tree.File { mode = (S.Regular | S.Executable) as mode; content } ->
      close (F.create_at fd name) (fun output ->
          S.Content.stream_to_fd store content output |> require_snapshot;
          Unix.fchmod output (if mode = S.Executable then 0o755 else 0o644);
          Unix.fsync output)

let rec native_tree fd name relative =
  let kind, stamp = F.inspect_at fd name in
  let descendants =
    match kind with
    | F.Directory ->
        close (F.open_at (Some fd) name true) (fun child ->
            F.names child
            |> List.concat_map (fun name ->
                native_tree child name (relative @ [ name ])))
    | F.File | F.Link -> []
    | F.Fifo | F.Socket | F.Character | F.Block ->
        refuse "special file in application staging"
  in
  (relative, stamp) :: descendants

let verify_tree ?(exact = false) fd name stamps =
  match (stamps, inspect fd name) with
  | [], None -> true
  | [], Some _ | _ :: _, None -> false
  | _ :: _, Some _ ->
      let current = native_tree fd name [] in
      List.length current = List.length stamps
      && List.for_all2
           (fun (a, x) (b, y) ->
             a = b && if exact then x = y else stamp_matches x y)
           stamps current

let validate_parents ~root rootfd t =
  open_root root (fun current ->
      if F.identity (F.fingerprint current) <> F.identity (F.fingerprint rootfd)
      then refuse "workspace root path now names a different directory");
  if F.identity (F.fingerprint rootfd) <> F.identity t.root then
    refuse "workspace root identity changed";
  List.iter
    (fun (path, stamp) ->
      directory rootfd path (fun fd ->
          if F.identity (F.fingerprint fd) <> F.identity stamp then
            refuse
              (Printf.sprintf "parent directory identity changed: %S"
                 (String.concat "/" path))))
    t.parents

let classify rootfd staging a =
  parent rootfd a.path (fun fd name ->
      let source_initial = verify_tree ~exact:true fd name a.before in
      let staged_initial = verify_tree ~exact:true staging a.slot a.after in
      if source_initial && not staged_initial then
        raise
          (Invalid_plan_bytes
             (Printf.sprintf
                "staged target at slot %S is missing or changed before \
                 replacing %S"
                a.slot (String.concat "/" a.path)));
      let initial = source_initial && staged_initial in
      let applied =
        verify_tree fd name a.after && verify_tree staging a.slot a.before
      in
      if initial then false
      else if applied then true
      else
        refuse
          (Printf.sprintf
             "application conflict at %S; preserve the live path and retained \
              slot %S before recovery"
             (String.concat "/" a.path) a.slot))

let snapshot_entry_lookup store raw =
  let id =
    Store.Stored_object_id.of_raw_bytes raw
    |> Option.get |> S.Snapshot.of_stored_object_id
  in
  let snapshot = S.Snapshot.load store id |> require_snapshot in
  let table = Hashtbl.create 64 in
  let rec walk path id =
    List.iter
      (fun (name, entry) ->
        let path = path @ [ name ] in
        Hashtbl.add table path entry;
        match entry with
        | S.Tree.File _ -> ()
        | S.Tree.Directory child -> walk path child)
      (entries store id)
  in
  walk [] (S.Snapshot.root snapshot);
  (snapshot, fun path -> Hashtbl.find_opt table path)

let[@warning "-4"] rec entry_bytes_match store fd name expected =
  match (expected, inspect fd name) with
  | None, None -> true
  | None, Some _ | Some _, None -> false
  | Some (S.Tree.Directory id), Some (F.Directory, stamp) ->
      close (F.open_at (Some fd) name true) (fun child ->
          let expected = entries store id in
          F.identity (F.fingerprint child) = F.identity stamp
          && F.names child = List.map fst expected
          && List.for_all
               (fun (name, e) -> entry_bytes_match store child name (Some e))
               expected
          && F.fingerprint child = stamp)
  | Some (S.Tree.File { mode = S.Symlink; content }), Some (F.Link, stamp) ->
      let expected =
        S.Content.load_bounded store ~max_bytes:65536 content
        |> require_snapshot
      in
      expected = Some (F.readlink_at fd name)
      && Option.map snd (inspect fd name) = Some stamp
  | ( Some (S.Tree.File { mode = (S.Regular | S.Executable) as mode; content }),
      Some (F.File, stamp) ) ->
      close (F.open_at (Some fd) name false) (fun input ->
          let stats = Unix.fstat input in
          F.fingerprint input = stamp
          && stats.Unix.st_perm land 0o111 <> 0 = (mode = S.Executable)
          && (match S.Content.verify_fd store content input with
            | Ok () -> true
            | Error (S.Invalid_schema message)
              when String.starts_with ~prefix:"filesystem" message ->
                false
            | Error (S.Observation_changed _) -> false
            | Error error -> require_snapshot (Error error))
          && Option.map snd (inspect fd name) = Some stamp)
  | ( Some (S.Tree.Directory _),
      Some ((F.File | F.Link | F.Fifo | F.Socket | F.Character | F.Block), _) )
  | ( Some (S.Tree.File { mode = S.Symlink; _ }),
      Some
        ((F.File | F.Directory | F.Fifo | F.Socket | F.Character | F.Block), _)
    )
  | ( Some (S.Tree.File { mode = S.Regular | S.Executable; _ }),
      Some
        ((F.Directory | F.Link | F.Fifo | F.Socket | F.Character | F.Block), _)
    ) ->
      false

let apply_with ~observe ~store ~root t =
  guard (fun () ->
      with_staging root t.operation (fun repository_fd staging ->
          let with_action_root f =
            match t.destination_parent with
            | None -> f repository_fd
            | Some (path, _) -> open_root path f
          in
          with_action_root (fun rootfd ->
              let target_snapshot, target_entry =
                snapshot_entry_lookup store t.target
              in
              let _, before_entry = snapshot_entry_lookup store t.safety in
              let checked action =
                let applied = classify rootfd staging action in
                let before_fd, before_name, after_fd, after_name =
                  if applied then (staging, action.slot, rootfd, "")
                  else (rootfd, "", staging, action.slot)
                in
                let before_valid fd name =
                  match t.destination_parent with
                  | None ->
                      entry_bytes_match store fd name (before_entry action.path)
                  | Some _ when action.before = [] -> not (exists fd name)
                  | Some _ -> (
                      match inspect fd name with
                      | Some (F.Directory, _) ->
                          close (F.open_at (Some fd) name true) (fun child ->
                              F.names child = [])
                      | None
                      | Some
                          ( ( F.File | F.Link | F.Fifo | F.Socket | F.Character
                            | F.Block ),
                            _ ) ->
                          false)
                in
                let after_expected =
                  match t.destination_parent with
                  | None -> target_entry action.path
                  | Some _ ->
                      Some (S.Tree.Directory (S.Snapshot.root target_snapshot))
                in
                let before_ok, after_ok =
                  parent rootfd action.path (fun fd name ->
                      let before_fd, before_name =
                        if before_name = "" then (fd, name)
                        else (before_fd, before_name)
                      in
                      let after_fd, after_name =
                        if after_name = "" then (fd, name)
                        else (after_fd, after_name)
                      in
                      ( before_valid before_fd before_name,
                        entry_bytes_match store after_fd after_name
                          after_expected ))
                in
                if not before_ok then
                  refuse
                    (Printf.sprintf
                       "original or retained bytes changed at %S (retained \
                        slot %S); preserve both before recovery"
                       (String.concat "/" action.path)
                       action.slot);
                if not after_ok then
                  if applied then
                    refuse
                      (Printf.sprintf
                         "installed target bytes changed at %S after \
                          application"
                         (String.concat "/" action.path))
                  else
                    raise
                      (Invalid_plan_bytes
                         (Printf.sprintf
                            "staged target bytes at slot %S do not match the \
                             complete saved identity for %S"
                            action.slot
                            (String.concat "/" action.path)));
                applied
              in
              let validate_scope () =
                let action_root, repository_stamp =
                  match t.destination_parent with
                  | None -> (root, t.root)
                  | Some (path, stamp) -> (path, stamp)
                in
                open_root root (fun current ->
                    if
                      F.identity (F.fingerprint current)
                      <> F.identity repository_stamp
                      || F.identity (F.fingerprint repository_fd)
                         <> F.identity repository_stamp
                    then refuse "origin repository identity changed");
                validate_parents ~root:action_root rootfd t;
                directory repository_fd
                  [ ".yeokcham"; "restore-staging"; t.operation ]
                  (fun current ->
                    if
                      F.identity (F.fingerprint current)
                      <> F.identity (F.fingerprint staging)
                    then refuse "private staging directory identity changed")
              in
              validate_scope ();
              List.iter (fun a -> ignore (checked a)) t.actions;
              List.iter
                (fun a ->
                  validate_scope ();
                  if not (checked a) then (
                    observe Before_mutation a.path;
                    validate_scope ();
                    if checked a then
                      refuse "application changed while preparing mutation";
                    parent rootfd a.path (fun fd name ->
                        if a.before = [] then
                          F.rename_at staging a.slot fd name false
                        else if a.after = [] then
                          F.rename_at fd name staging a.slot false
                        else F.rename_at fd name staging a.slot true;
                        observe After_mutation a.path;
                        Unix.fsync fd;
                        Unix.fsync staging;
                        observe After_sync a.path);
                    if not (checked a) then
                      refuse
                        "atomic application did not install the recorded target"))
                t.actions;
              validate_scope ();
              List.iter
                (fun a ->
                  if not (checked a) then refuse "application is incomplete")
                t.actions)))

let apply ~root ~store t = apply_with ~observe:(fun _ _ -> ()) ~root ~store t

module For_test = struct
  let apply = apply_with
end

let[@warning "-4"] prepare_with ~stage ~root ~store ~operation ~safety ~target
    observation =
  guard (fun () ->
      check_operation operation;
      let target_snapshot = S.Snapshot.load store target |> require_snapshot in
      ignore (S.Materialize.plan store target_snapshot |> require_target_plan);
      let safety_snapshot = S.Snapshot.load store safety |> require_snapshot in
      let observed = S.Observation.entries observation in
      let directories = S.Observation.directories observation in
      let root_stamp = List.assoc [] observed in
      let unmanaged path id =
        let rec walk path id =
          let children = entries store id in
          let _, _, names = List.find (fun (p, _, _) -> p = path) directories in
          List.exists (fun name -> not (List.mem_assoc name children)) names
          || List.exists
               (function
                 | name, S.Tree.Directory child -> walk (path @ [ name ]) child
                 | _, S.Tree.File _ -> false)
               children
        in
        walk path id
      in
      let rec verify_target path = function
        | S.Tree.File _ -> check_path path false
        | S.Tree.Directory id ->
            check_path path true;
            List.iter
              (fun (name, e) -> verify_target (path @ [ name ]) e)
              (entries store id)
      and check_path path is_directory =
        if not (valid_path path) then
          refuse "target contains a mandatory metadata path";
        let explanation =
          S.explain_ignore ~directory:is_directory ~root path
          |> require_snapshot
        in
        if explanation.S.ignored then
          refuse
            (Printf.sprintf
               "target path is excluded by native rules: %S; inspect ignore \
                explain before selection"
               (String.concat "/" path))
      in
      List.iter
        (fun (name, e) -> verify_target [ name ] e)
        (entries store (S.Snapshot.root target_snapshot));
      let rec difference path before after =
        if before = after then []
        else
          match (before, after) with
          | Some (S.Tree.Directory a), Some (S.Tree.Directory b) ->
              compare_children path a (Some b)
          | Some a, Some b when entry_equal a b -> []
          | Some (S.Tree.Directory a), None when unmanaged path a ->
              compare_children path a None
          | Some (S.Tree.Directory a), Some (S.Tree.File _)
            when unmanaged path a ->
              refuse
                (Printf.sprintf
                   "ignored or untracked paths obstruct directory replacement: \
                    %S"
                   (String.concat "/" path))
          | _ -> [ (path, before, after) ]
      and compare_children path a b =
        let old = entries store a
        and next = Option.fold ~none:[] ~some:(entries store) b in
        List.sort_uniq String.compare (List.map fst old @ List.map fst next)
        |> List.concat_map (fun name ->
            difference (path @ [ name ]) (List.assoc_opt name old)
              (List.assoc_opt name next))
      in
      let before = entries store (S.Snapshot.root safety_snapshot)
      and after = entries store (S.Snapshot.root target_snapshot) in
      let changes =
        List.sort_uniq String.compare (List.map fst before @ List.map fst after)
        |> List.concat_map (fun name ->
            difference [ name ]
              (List.assoc_opt name before)
              (List.assoc_opt name after))
      in
      let parents =
        changes
        |> List.concat_map (fun (path, _, _) ->
            let rec collect reversed = function
              | [] | [ _ ] -> reversed
              | _ :: rest ->
                  let p = List.rev rest in
                  collect ((p, List.assoc p observed) :: reversed) rest
            in
            collect [] (List.rev path))
        |> List.sort_uniq Stdlib.compare
      in
      open_root root (fun rootfd ->
          if F.identity (F.fingerprint rootfd) <> F.identity root_stamp then
            refuse "capture root changed before staging";
          let verify_observation () =
            List.iter
              (fun (path, stamp) ->
                if path = [] then ()
                else
                  parent rootfd path (fun fd name ->
                      match inspect fd name with
                      | Some (_, actual) when actual = stamp -> ()
                      | _ ->
                          refuse
                            (Printf.sprintf
                               "capture changed before application: %S"
                               (String.concat "/" path))))
              observed
          in
          verify_observation ();
          List.iter
            (fun (path, old, next) ->
              parent rootfd path (fun fd name ->
                  F.check_destination fd name;
                  if F.device (F.fingerprint fd) <> F.device root_stamp then
                    refuse "application crosses a filesystem boundary";
                  (match (old, inspect fd name) with
                  | None, None | Some _, Some _ -> ()
                  | _ ->
                      refuse
                        (Printf.sprintf "untracked path obstructs target: %S"
                           (String.concat "/" path)));
                  let rec check name entry =
                    F.check_destination fd name;
                    match entry with
                    | S.Tree.File _ -> ()
                    | S.Tree.Directory id ->
                        List.iter
                          (fun (child, e) -> check child e)
                          (entries store id)
                  in
                  Option.iter (check name) next))
            changes;
          let scope =
            {
              operation;
              safety = snapshot_bytes safety;
              target = snapshot_bytes target;
              root = root_stamp;
              destination_parent = None;
              parents;
              actions = [];
              bytes = "";
            }
          in
          validate_parents ~root rootfd scope;
          if not stage then scope
          else
            directory rootfd [ ".yeokcham" ] (fun metadata ->
                ensure_directory metadata "restore-staging";
                directory metadata [ "restore-staging" ] (fun base ->
                    if exists base operation then
                      refuse
                        "application staging identity already exists; resume \
                         its journal";
                    F.mkdir_at base operation;
                    Unix.fsync base;
                    directory base [ operation ] (fun staging ->
                        close (F.create_at staging ".probe-a") (fun fd ->
                            Unix.fsync fd);
                        close (F.create_at staging ".probe-b") (fun fd ->
                            Unix.fsync fd);
                        F.rename_at staging ".probe-a" staging ".probe-b" true;
                        F.rename_at staging ".probe-a" staging ".probe-c" false;
                        let actions =
                          List.mapi
                            (fun index (path, old, next) ->
                              let slot = string_of_int index in
                              parent rootfd path (fun fd name ->
                                  F.check_destination fd name;
                                  if
                                    F.device (F.fingerprint fd)
                                    <> F.device (F.fingerprint staging)
                                  then
                                    refuse
                                      "application crosses a filesystem \
                                       boundary";
                                  match (old, inspect fd name) with
                                  | None, None | Some _, Some _ -> ()
                                  | _ ->
                                      refuse
                                        (Printf.sprintf
                                           "untracked path obstructs target: %S"
                                           (String.concat "/" path)));
                              let before =
                                match old with
                                | None -> []
                                | Some _ ->
                                    observed
                                    |> List.filter (fun (p, _) -> prefix path p)
                                    |> List.map (fun (p, s) ->
                                        ( List.filteri
                                            (fun i _ -> i >= List.length path)
                                            p,
                                          s ))
                                    |> List.sort Stdlib.compare
                              in
                              Option.iter (create_entry store staging slot) next;
                              let after =
                                if next = None then []
                                else native_tree staging slot []
                              in
                              { path; before; after; slot })
                            changes
                        in
                        Unix.fsync staging;
                        let t =
                          {
                            operation;
                            safety = snapshot_bytes safety;
                            target = snapshot_bytes target;
                            root = root_stamp;
                            destination_parent = None;
                            parents;
                            actions;
                            bytes = "";
                          }
                        in
                        validate_parents ~root rootfd t;
                        List.iter
                          (fun a ->
                            if classify rootfd staging a then
                              refuse
                                "new application unexpectedly already applied")
                          actions;
                        let bytes = encode t in
                        if String.length bytes > 16 * 1024 * 1024 then
                          refuse "application plan exceeds 16 MiB bound";
                        close (F.create_at staging "plan.cbor") (fun fd ->
                            write_all fd bytes;
                            Unix.fsync fd);
                        Unix.fsync staging;
                        { t with bytes })))))

let prepare ~root ~store ~operation ~safety ~target observation =
  prepare_with ~stage:true ~root ~store ~operation ~safety ~target observation

let check ~root ~store ~safety ~target observation =
  prepare_with ~stage:false ~root ~store ~operation:(String.make 64 '0') ~safety
    ~target observation
  |> Result.map (fun _ -> ())

let destination t =
  match (t.destination_parent, t.actions) with
  | Some (parent, _), [ { path = [ name ]; _ } ] ->
      Some (Filename.concat parent name)
  | None, _ | Some _, _ -> None

let copyout_binding t =
  array
    [
      E.bytes "yeokcham:copyout-preflight:v1";
      E.bytes t.target;
      E.bytes (Option.get (destination t));
      E.bytes (F.identity t.root);
      stamps_value (List.hd t.actions).before;
    ]
  |> E.encode |> Hash.digest_string |> Hash.to_raw_string

let copyout_token = copyout_binding

let prepare_copyout_with ~stage ~root ~store ~operation ~target
    ~destination:requested =
  guard (fun () ->
      check_operation operation;
      let target_snapshot = S.Snapshot.load store target |> require_snapshot in
      ignore (S.Materialize.plan store target_snapshot |> require_target_plan);
      let rec check_tree path id =
        List.iter
          (fun (name, e) ->
            let path = path @ [ name ] in
            if not (valid_path path) then
              refuse "copy target contains reserved metadata";
            match e with
            | S.Tree.File _ -> ()
            | S.Tree.Directory child -> check_tree path child)
          (entries store id)
      in
      check_tree [] (S.Snapshot.root target_snapshot);
      let name = Filename.basename requested in
      if not (valid_path [ name ]) then refuse "unsafe copy destination name";
      let parent_path = Unix.realpath (Filename.dirname requested) in
      let destination = Filename.concat parent_path name in
      let origin = Unix.realpath root in
      let metadata = Filename.concat origin ".yeokcham"
      and git = Filename.concat origin ".git" in
      let within path ancestor =
        path = ancestor || String.starts_with ~prefix:(ancestor ^ "/") path
      in
      if
        within destination metadata
        || within destination git || within origin destination
      then
        refuse "copy destination overlaps the source repository or its metadata";
      open_root root (fun repository_fd ->
          open_root parent_path (fun parentfd ->
              F.check_destination parentfd name;
              let root_stamp = F.fingerprint parentfd
              and repository_stamp = F.fingerprint repository_fd in
              if F.device root_stamp <> F.device repository_stamp then
                raise
                  (Failure
                     "copy destination is on another filesystem; choose a \
                      destination on the source filesystem");
              let before =
                match inspect parentfd name with
                | None -> []
                | Some (F.Directory, _) ->
                    close (F.open_at (Some parentfd) name true) (fun fd ->
                        if F.names fd <> [] then
                          refuse "copy destination is not empty";
                        native_tree parentfd name [])
                | Some
                    ( ( F.File | F.Link | F.Fifo | F.Socket | F.Character
                      | F.Block ),
                      _ ) ->
                    refuse "copy destination is not a real directory"
              in
              let scope =
                {
                  operation;
                  safety = snapshot_bytes target;
                  target = snapshot_bytes target;
                  root = root_stamp;
                  destination_parent = Some (parent_path, repository_stamp);
                  parents = [];
                  actions =
                    [ { path = [ name ]; slot = "0"; before; after = [] } ];
                  bytes = "";
                }
              in
              if not stage then scope
              else
                directory repository_fd [ ".yeokcham" ] (fun metadatafd ->
                    ensure_directory metadatafd "restore-staging";
                    directory metadatafd [ "restore-staging" ] (fun base ->
                        if exists base operation then
                          refuse
                            "copy operation already has staging; resume its \
                             journal";
                        F.mkdir_at base operation;
                        Unix.fsync base;
                        directory base [ operation ] (fun staging ->
                            if
                              F.device (F.fingerprint staging)
                              <> F.device root_stamp
                            then
                              raise
                                (Failure
                                   "copy staging crosses a filesystem boundary");
                            close (F.create_at staging ".probe-a") (fun fd ->
                                Unix.fsync fd);
                            close (F.create_at staging ".probe-b") (fun fd ->
                                Unix.fsync fd);
                            F.rename_at staging ".probe-a" staging ".probe-b"
                              true;
                            F.rename_at staging ".probe-a" staging ".probe-c"
                              false;
                            create_entry store staging "0"
                              (S.Tree.Directory
                                 (S.Snapshot.root target_snapshot));
                            Unix.fsync staging;
                            let after = native_tree staging "0" [] in
                            let t =
                              {
                                scope with
                                actions =
                                  [
                                    {
                                      path = [ name ];
                                      slot = "0";
                                      before;
                                      after;
                                    };
                                  ];
                              }
                            in
                            validate_parents ~root:parent_path parentfd t;
                            if classify parentfd staging (List.hd t.actions)
                            then refuse "copy unexpectedly already installed";
                            let bytes = encode t in
                            if String.length bytes > 16 * 1024 * 1024 then
                              refuse "copy plan exceeds 16 MiB bound";
                            close (F.create_at staging "plan.cbor") (fun fd ->
                                write_all fd bytes;
                                Unix.fsync fd);
                            Unix.fsync staging;
                            { t with bytes }))))))

let check_copyout ~root ~store ~target ~destination:requested =
  prepare_copyout_with ~stage:false ~root ~store ~operation:(String.make 64 '0')
    ~target ~destination:requested
  |> Result.map (fun t -> (Option.get (destination t), copyout_binding t))

let prepare_copyout ~root ~store ~operation ~target ~destination =
  prepare_copyout_with ~stage:true ~root ~store ~operation ~target ~destination

let[@warning "-4"] decode bytes =
  let value = E.decode bytes |> require E.decode_error_to_string in
  let get_bytes = function
    | E.Bytes b -> b
    | _ -> refuse "application plan field must be bytes"
  in
  let get_array = function
    | E.Array xs -> xs
    | _ -> refuse "application plan field must be an array"
  in
  let get_path value = get_array value |> List.map get_bytes in
  let valid_stamp stamp =
    let fields = String.split_on_char ':' stamp in
    if
      List.length fields <> 9
      || not
           (List.for_all
              (fun field ->
                field <> ""
                && String.for_all
                     (function '0' .. '9' | '-' -> true | _ -> false)
                     field)
              fields)
    then refuse "invalid application fingerprint"
  in
  let get_stamps value =
    let stamps =
      get_array value
      |> List.map (function
        | E.Array [ path; stamp ] ->
            let path = get_path path and stamp = get_bytes stamp in
            if not (List.for_all safe_name path) then
              refuse "unsafe relative fingerprint path";
            valid_stamp stamp;
            (path, stamp)
        | _ -> refuse "invalid application fingerprint entry")
    in
    if
      List.sort_uniq Stdlib.compare stamps <> stamps
      || List.length (List.sort_uniq Stdlib.compare (List.map fst stamps))
         <> List.length stamps
    then refuse "application fingerprints must be unique and sorted";
    stamps
  in
  let value, destination_parent =
    match value with
    | E.Array
        [
          E.Integer 2L;
          operation;
          safety;
          target;
          root;
          parents;
          actions;
          E.Bytes parent;
          E.Bytes repository;
        ] ->
        let components = String.split_on_char '/' parent in
        if
          Filename.is_relative parent
          || String.contains parent '\000'
          || parent <> "/"
             &&
             match components with
             | "" :: rest -> not (List.for_all safe_name rest)
             | _ -> true
        then
          refuse
            "copy destination parent must be a canonical absolute native path";
        valid_stamp repository;
        ( array
            [ E.integer 1L; operation; safety; target; root; parents; actions ],
          Some (parent, repository) )
    | other -> (other, None)
  in
  match value with
  | E.Array [ E.Integer 1L; operation; safety; target; root; parents; actions ]
    ->
      let operation = get_bytes operation
      and safety = get_bytes safety
      and target = get_bytes target
      and root = get_bytes root in
      check_operation operation;
      valid_stamp root;
      if String.length safety <> 32 || String.length target <> 32 then
        refuse "invalid application snapshot scope";
      let parents = get_stamps parents in
      if not (List.for_all (fun (p, _) -> p = [] || valid_path p) parents) then
        refuse "unsafe application parent";
      let actions =
        get_array actions
        |> List.mapi (fun index -> function
          | E.Array [ path; slot; before; after ] ->
              let path = get_path path
              and slot = get_bytes slot
              and before = get_stamps before
              and after = get_stamps after in
              if (not (valid_path path)) || slot <> string_of_int index then
                refuse "unsafe application action";
              List.iter
                (function
                  | [] -> ()
                  | ([], _) :: _ -> ()
                  | _ -> refuse "application fingerprint subtree lacks a root")
                [ before; after ];
              if before = [] && after = [] then
                refuse "empty application action";
              { path; slot; before; after }
          | _ -> refuse "invalid application action")
      in
      let paths = List.map (fun a -> a.path) actions in
      if
        paths <> List.sort_uniq Stdlib.compare paths
        || List.exists
             (fun p -> List.exists (fun q -> p <> q && prefix p q) paths)
             paths
      then refuse "application actions overlap or are unordered";
      (match (destination_parent, actions, parents) with
      | None, _, _ -> ()
      | Some _, [ { path = [ _ ]; after = _ :: _; _ } ], [] when safety = target
        ->
          ()
      | Some _, _, _ ->
          refuse "copy plan must install one whole directory without navigation");
      let t =
        {
          operation;
          safety;
          target;
          root;
          destination_parent;
          parents;
          actions;
          bytes;
        }
      in
      if encode t <> bytes then refuse "noncanonical application plan";
      t
  | _ -> refuse "unsupported application plan schema"

let load ~root ~operation ~digest:expected ~safety ~target =
  guard (fun () ->
      check_operation operation;
      with_staging root operation (fun _ staging ->
          close (F.open_at (Some staging) "plan.cbor" false) (fun fd ->
              let stat = Unix.fstat fd in
              let fingerprint = F.fingerprint fd in
              if
                stat.Unix.st_kind <> Unix.S_REG
                || stat.Unix.st_size > 16 * 1024 * 1024
              then refuse "invalid or oversized application plan";
              let bytes = Bytes.create stat.Unix.st_size in
              let rec read offset =
                if offset < Bytes.length bytes then
                  let count =
                    Unix.read fd bytes offset (Bytes.length bytes - offset)
                  in
                  if count = 0 then refuse "truncated application plan"
                  else read (offset + count)
              in
              read 0;
              if F.fingerprint fd <> fingerprint then
                refuse "application plan changed while reading";
              let bytes = Bytes.unsafe_to_string bytes in
              if Hash.to_raw_string (Hash.digest_string bytes) <> expected then
                refuse "application plan digest mismatch";
              let t = decode bytes in
              if
                t.operation <> operation
                || t.safety <> snapshot_bytes safety
                || t.target <> snapshot_bytes target
              then
                refuse
                  "application plan names a different operation or snapshots";
              t)))
  |> Result.map_error (function
    | Conflict detail -> Invalid_plan detail
    | Unavailable _ as error -> error
    | Invalid_plan _ as error -> error)
