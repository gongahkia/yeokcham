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
  parents : (string list * string) list;
  actions : action list;
  bytes : string;
}

exception Refusal of string

let refuse message = raise (Refusal message)
let require render = function Ok x -> x | Error e -> refuse (render e)

let guard f =
  try Ok (f ()) with
  | Refusal message -> Error message
  | Unix.Unix_error (e, call, name) ->
      Error
        (Printf.sprintf
           "%s %S: %s; live and retained files were not rolled back" call name
           (Unix.error_message e))
  | Sys_error message | Failure message -> Error message

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
    [
      E.integer 1L;
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
  S.Tree.load store id |> require S.error_to_string |> S.Tree.entries

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
        |> require S.error_to_string
      in
      let target =
        match target with
        | Some t when t <> "" && not (String.contains t '\000') -> t
        | _ -> refuse "unrepresentable symlink target"
      in
      F.symlink_at fd name target
  | S.Tree.File { mode = (S.Regular | S.Executable) as mode; content } ->
      close (F.create_at fd name) (fun output ->
          S.Content.stream_to_fd store content output
          |> require S.error_to_string;
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

let verify_tree fd name stamps =
  match (stamps, inspect fd name) with
  | [], None -> true
  | [], Some _ | _ :: _, None -> false
  | _ :: _, Some _ ->
      let current = native_tree fd name [] in
      List.length current = List.length stamps
      && List.for_all2
           (fun (a, x) (b, y) -> a = b && stamp_matches x y)
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
      let initial =
        verify_tree fd name a.before && verify_tree staging a.slot a.after
      in
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

let apply_with ~observe ~root t =
  guard (fun () ->
      with_staging root t.operation (fun rootfd staging ->
          let validate_scope () =
            validate_parents ~root rootfd t;
            directory rootfd [ ".yeokcham"; "restore-staging"; t.operation ]
              (fun current ->
                if
                  F.identity (F.fingerprint current)
                  <> F.identity (F.fingerprint staging)
                then refuse "private staging directory identity changed")
          in
          validate_scope ();
          List.iter (fun a -> ignore (classify rootfd staging a)) t.actions;
          List.iter
            (fun a ->
              validate_scope ();
              if not (classify rootfd staging a) then (
                observe Before_mutation a.path;
                validate_scope ();
                if classify rootfd staging a then
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
                if not (classify rootfd staging a) then
                  refuse
                    "atomic application did not install the recorded target"))
            t.actions;
          validate_scope ();
          List.iter
            (fun a ->
              if not (classify rootfd staging a) then
                refuse "application is incomplete")
            t.actions))

let apply ~root t = apply_with ~observe:(fun _ _ -> ()) ~root t

module For_test = struct
  let apply = apply_with
end

let[@warning "-4"] prepare ~root ~store ~operation ~safety ~target observation =
  guard (fun () ->
      check_operation operation;
      let target_snapshot =
        S.Snapshot.load store target |> require S.error_to_string
      in
      ignore
        (S.Materialize.plan store target_snapshot
        |> require S.Materialize.error_to_string);
      let safety_snapshot =
        S.Snapshot.load store safety |> require S.error_to_string
      in
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
          |> require S.error_to_string
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
          directory rootfd [ ".yeokcham" ] (fun metadata ->
              ensure_directory metadata "restore-staging";
              directory metadata [ "restore-staging" ] (fun base ->
                  if exists base operation then
                    refuse
                      "application staging identity already exists; resume its \
                       journal";
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
                                    "application crosses a filesystem boundary";
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
      let t = { operation; safety; target; root; parents; actions; bytes } in
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
