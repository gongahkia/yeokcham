(* Record labels are intentionally shared across typed contracts; the project
   targets OCaml 5.5, so the OCaml-4.00 compatibility warning is inapplicable. *)
[@@@warning "-42"]

type error =
  | Invalid_identifier of string
  | Entropy_failure of string
  | Invalid_field of string
  | Duplicate_id of string
  | Wrong_scope
  | Missing_reference of string
  | Wrong_reference_kind of string
  | Identity_collision of string
  | Sequence_exhausted
  | Unsupported_policy of string

let error_to_string = function
  | Invalid_identifier name -> "invalid core identifier: " ^ name
  | Entropy_failure detail -> "core identity entropy unavailable: " ^ detail
  | Invalid_field detail -> "invalid core record field: " ^ detail
  | Duplicate_id name -> "duplicate core identifier in " ^ name
  | Wrong_scope -> "core record belongs to a different repository"
  | Missing_reference id -> "missing core reference: " ^ id
  | Wrong_reference_kind id -> "wrong core reference kind: " ^ id
  | Identity_collision id -> "core identity collision: " ^ id
  | Sequence_exhausted -> "workspace history sequence is exhausted"
  | Unsupported_policy detail -> "unsupported core policy: " ^ detail

let ( let* ) = Result.bind
let max_references = 16384
let max_name_bytes = 1024

module type Id = sig
  type t

  val of_raw : string -> (t, error) result
  val to_raw : t -> string
  val of_hex : string -> (t, error) result
  val to_hex : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module type Random_id = sig
  include Id

  val generate :
    random_bytes:(int -> (string, string) result) -> unit -> (t, error) result
end

module Make_id (Size : sig
  val bytes : int
  val name : string
end) =
struct
  type t = string

  let of_raw raw =
    if String.length raw = Size.bytes then Ok raw
    else Error (Invalid_identifier Size.name)

  let to_raw value = value

  let to_hex value =
    let hex = Bytes.create (Size.bytes * 2) in
    String.iteri
      (fun i c ->
        Bytes.set hex (i * 2) "0123456789abcdef".[Char.code c lsr 4];
        Bytes.set hex ((i * 2) + 1) "0123456789abcdef".[Char.code c land 15])
      value;
    Bytes.unsafe_to_string hex

  let of_hex hex =
    let digit = function
      | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
      | 'a' .. 'f' as c -> Some (10 + Char.code c - Char.code 'a')
      | _ -> None
    in
    if String.length hex <> Size.bytes * 2 then
      Error (Invalid_identifier Size.name)
    else
      let bytes = Bytes.create Size.bytes in
      let rec loop i =
        if i = Size.bytes then Ok (Bytes.unsafe_to_string bytes)
        else
          match (digit hex.[i * 2], digit hex.[(i * 2) + 1]) with
          | Some a, Some b ->
              Bytes.set bytes i (Char.chr ((a lsl 4) lor b));
              loop (i + 1)
          | _ -> Error (Invalid_identifier Size.name)
      in
      loop 0

  let equal = String.equal
  let compare = String.compare
end

module Make_random_id (Name : sig
  val name : string
end) =
struct
  include Make_id (struct
    let bytes = 16
    let name = Name.name
  end)

  let generate ~random_bytes () =
    try
      match random_bytes 16 with
      | Error detail -> Error (Entropy_failure detail)
      | Ok bytes -> of_raw bytes
    with _ -> Error (Entropy_failure "random source failed")
end

module Workspace_id = Make_random_id (struct
  let name = "workspace"
end)

module Branch_id = Make_random_id (struct
  let name = "branch"
end)

module Change_id = Make_random_id (struct
  let name = "change"
end)

module Repository_id = Make_id (struct
  let bytes = 32
  let name = "repository"
end)

module Record_id = Make_id (struct
  let bytes = 32
  let name = "record"
end)

module Object_id = Make_id (struct
  let bytes = 32
  let name = "object"
end)

module Digest = Make_id (struct
  let bytes = 32
  let name = "digest"
end)

module History_id = struct
  type t = { workspace : Workspace_id.t; sequence : int64 }

  let make ~workspace ~sequence =
    if Int64.compare sequence 0L < 0 then
      Error (Invalid_field "negative history sequence")
    else Ok { workspace; sequence }

  let workspace id = id.workspace
  let sequence id = id.sequence

  let compare a b =
    let workspace_order = Workspace_id.compare a.workspace b.workspace in
    if workspace_order = 0 then Int64.compare a.sequence b.sequence
    else workspace_order

  let equal a b = compare a b = 0

  let allocate ~workspace ~next =
    match next with
    | None -> Error Sequence_exhausted
    | Some sequence ->
        let* id = make ~workspace ~sequence in
        Ok
          ( id,
            if sequence = Int64.max_int then None
            else Some (Int64.succ sequence) )
end

let bounded name values =
  if List.compare_length_with values max_references > 0 then
    Error (Invalid_field (name ^ " exceeds reference limit"))
  else Ok ()

let canonical_set compare name values =
  let* () = bounded name values in
  let values = List.sort compare values in
  let rec unique = function
    | a :: (b :: _ as rest) ->
        if compare a b = 0 then Error (Duplicate_id name) else unique rest
    | _ -> Ok values
  in
  unique values

let record_set name values = canonical_set Record_id.compare name values
let digest_set name values = canonical_set Digest.compare name values

let valid_name name value =
  if String.length value = 0 || String.length value > max_name_bytes then
    Error (Invalid_field (name ^ " must contain 1-1024 UTF-8 bytes"))
  else if String.contains value '\000' then
    Error (Invalid_field (name ^ " contains NUL"))
  else
    match Yeokcham_encoding.text value with
    | Ok _ -> Ok ()
    | Error _ -> Error (Invalid_field (name ^ " is not UTF-8"))

let validate_branch_name = valid_name "branch name"

let valid_profile = function
  | "line-hunks-v1" -> Ok ()
  | _ -> Error (Invalid_field "unsupported composition profile")

type shared_revision = {
  change : Change_id.t;
  previous_revisions : Record_id.t list;
  base_snapshot : Object_id.t;
  result_snapshot : Object_id.t;
  edit_scope_root : Object_id.t;
  dependencies : Record_id.t list;
}

type accepted_version = {
  branch : Branch_id.t;
  accepted_parents : Record_id.t list;
  chosen_revisions : Record_id.t list;
  resolutions : Record_id.t list;
  result_snapshot : Object_id.t;
  composition_profile : string;
  policy_heads : Digest.t list;
  review_evidence : Digest.t list;
}

type branch_action = Create | Rename | Advance | Reconcile

type branch_event = {
  branch : Branch_id.t;
  previous_events : Record_id.t list;
  action : branch_action;
  targets : Record_id.t list;
  display_name : string option;
}

type payload =
  | Shared_revision of shared_revision
  | Accepted_version of accepted_version
  | Branch_event of branch_event

type kind = Shared_revision_kind | Accepted_version_kind | Branch_event_kind

let kind = function
  | Shared_revision _ -> Shared_revision_kind
  | Accepted_version _ -> Accepted_version_kind
  | Branch_event _ -> Branch_event_kind

let kind_name = function
  | Shared_revision_kind -> "shared-revision"
  | Accepted_version_kind -> "accepted-version"
  | Branch_event_kind -> "branch-event"

let parents = function
  | Shared_revision revision -> revision.previous_revisions
  | Accepted_version version -> version.accepted_parents
  | Branch_event event -> event.previous_events

let make_shared_revision ~change ~previous_revisions ~base_snapshot
    ~result_snapshot ~edit_scope_root ~dependencies =
  let* previous_revisions =
    record_set "previous revisions" previous_revisions
  in
  let* dependencies = record_set "revision dependencies" dependencies in
  Ok
    {
      change;
      previous_revisions;
      base_snapshot;
      result_snapshot;
      edit_scope_root;
      dependencies;
    }

let make_accepted_version ~branch ~accepted_parents ~chosen_revisions
    ~resolutions ~result_snapshot ~composition_profile ~policy_heads
    ~review_evidence =
  let* accepted_parents = record_set "accepted parents" accepted_parents in
  let* chosen_revisions = record_set "chosen revisions" chosen_revisions in
  let* resolutions = record_set "resolutions" resolutions in
  let* policy_heads = digest_set "policy heads" policy_heads in
  let* review_evidence = digest_set "review evidence" review_evidence in
  let* () = valid_profile composition_profile in
  if accepted_parents = [] && (chosen_revisions <> [] || resolutions <> []) then
    Error (Invalid_field "genesis must not select revisions or resolutions")
  else
    Ok
      {
        branch;
        accepted_parents;
        chosen_revisions;
        resolutions;
        result_snapshot;
        composition_profile;
        policy_heads;
        review_evidence;
      }

let make_branch_event ~branch ~previous_events ~action ~targets ~display_name =
  let* previous_events = record_set "previous branch events" previous_events in
  let* targets = record_set "branch targets" targets in
  let* () =
    match display_name with
    | None -> Ok ()
    | Some value -> validate_branch_name value
  in
  let valid =
    match action with
    | Create ->
        previous_events = []
        && List.length targets = 1
        && Option.is_some display_name
    | Rename ->
        previous_events <> [] && targets = [] && Option.is_some display_name
    | Advance ->
        previous_events <> [] && targets <> [] && Option.is_none display_name
    | Reconcile ->
        List.length previous_events >= 2
        && targets <> []
        && Option.is_none display_name
  in
  if valid then Ok { branch; previous_events; action; targets; display_name }
  else Error (Invalid_field "branch action/parents/targets/name do not agree")

type context = {
  repository : Repository_id.t;
  author_certificate : Digest.t;
  authority_heads : Digest.t list;
  display_time : int64 option;
}

let make_context ~repository ~author_certificate ~authority_heads ~display_time
    =
  let* authority_heads = digest_set "authority heads" authority_heads in
  if authority_heads = [] then
    Error (Invalid_field "authority heads must not be empty")
  else
    match display_time with
    | Some time when Int64.compare time 0L < 0 ->
        Error (Invalid_field "negative display time")
    | _ -> Ok { repository; author_certificate; authority_heads; display_time }

type body = { context : context; payload : payload }

let make_body ~context ~payload = { context; payload }

module Records = Map.Make (Record_id)

type pool = { repository : Repository_id.t; records : body Records.t }
type insertion = Added | Unchanged

let empty_pool ~repository = { repository; records = Records.empty }
let pool_repository (pool : pool) = pool.repository
let records pool = Records.bindings pool.records
let find pool id = Records.find_opt id pool.records

let require pool expected id =
  match find pool id with
  | None -> Error (Missing_reference (Record_id.to_hex id))
  | Some body when kind body.payload <> expected ->
      Error (Wrong_reference_kind (Record_id.to_hex id))
  | Some body -> Ok body

let check_all check values =
  List.fold_left
    (fun result value ->
      let* () = result in
      check value)
    (Ok ()) values

let require_all pool expected ids =
  check_all
    (fun id ->
      let* _ = require pool expected id in
      Ok ())
    ids

let supported_policy ~policy_heads ~review_evidence ~resolutions =
  if policy_heads <> [] then
    Error (Unsupported_policy "policy records are not implemented")
  else if review_evidence <> [] then
    Error (Unsupported_policy "review evidence is not implemented")
  else if resolutions <> [] then
    Error (Unsupported_policy "resolution records are not implemented")
  else Ok ()

let retain (pool : pool) ~id body =
  if not (Repository_id.equal pool.repository body.context.repository) then
    Error Wrong_scope
  else
    match find pool id with
    | Some previous when previous = body -> Ok (pool, Unchanged)
    | Some _ -> Error (Identity_collision (Record_id.to_hex id))
    | None ->
        let* () =
          match body.payload with
          | Shared_revision revision ->
              let* () =
                if
                  revision.previous_revisions = []
                  && Records.exists
                       (fun _ body ->
                         match body.payload with
                         | Shared_revision existing ->
                             Change_id.equal existing.change revision.change
                         | Accepted_version _ | Branch_event _ -> false)
                       pool.records
                then
                  Error
                    (Identity_collision
                       ("change " ^ Change_id.to_hex revision.change))
                else Ok ()
              in
              let* () =
                check_all
                  (fun parent ->
                    let* body = require pool Shared_revision_kind parent in
                    match body.payload with
                    | Shared_revision previous
                      when Change_id.equal previous.change revision.change ->
                        Ok ()
                    | Shared_revision _ | Accepted_version _ | Branch_event _ ->
                        Error
                          (Invalid_field
                             "previous revision belongs to another change"))
                  revision.previous_revisions
              in
              require_all pool Shared_revision_kind revision.dependencies
          | Accepted_version version ->
              let* () =
                supported_policy ~policy_heads:version.policy_heads
                  ~review_evidence:version.review_evidence
                  ~resolutions:version.resolutions
              in
              let* () =
                require_all pool Accepted_version_kind version.accepted_parents
              in
              require_all pool Shared_revision_kind version.chosen_revisions
          | Branch_event event ->
              let* () =
                check_all
                  (fun parent ->
                    let* body = require pool Branch_event_kind parent in
                    match body.payload with
                    | Branch_event previous
                      when Branch_id.equal previous.branch event.branch ->
                        Ok ()
                    | Shared_revision _ | Accepted_version _ | Branch_event _ ->
                        Error
                          (Invalid_field
                             "previous event belongs to another branch"))
                  event.previous_events
              in
              let* () = require_all pool Accepted_version_kind event.targets in
              if
                event.action = Create
                && Records.exists
                     (fun _ body ->
                       match body.payload with
                       | Branch_event previous ->
                           previous.action = Create
                           && Branch_id.equal previous.branch event.branch
                       | Shared_revision _ | Accepted_version _ -> false)
                     pool.records
              then
                Error
                  (Identity_collision ("branch " ^ Branch_id.to_hex event.branch))
              else Ok ()
        in
        Ok ({ pool with records = Records.add id body pool.records }, Added)

module Record_set = Set.Make (Record_id)
module Branch_map = Map.Make (Branch_id)

type branch_state = {
  branch_id : Branch_id.t;
  event_heads : Record_id.t list;
  accepted_heads : Record_id.t list;
  display_names : string list;
}

let branch_states pool =
  let groups =
    Records.fold
      (fun id body groups ->
        match body.payload with
        | Branch_event event ->
            let events =
              Option.value (Branch_map.find_opt event.branch groups) ~default:[]
            in
            Branch_map.add event.branch ((id, event) :: events) groups
        | Shared_revision _ | Accepted_version _ -> groups)
      pool.records Branch_map.empty
  in
  let inherited ~extract ~add ~empty ids =
    let rec walk visited collected = function
      | [] -> collected
      | id :: rest when Record_set.mem id visited -> walk visited collected rest
      | id :: rest -> (
          let visited = Record_set.add id visited in
          match find pool id with
          | Some { payload = Branch_event event; _ } ->
              let values = extract event in
              if values = [] then
                walk visited collected (event.previous_events @ rest)
              else walk visited (List.fold_left add collected values) rest
          | Some { payload = Shared_revision _ | Accepted_version _; _ } | None
            ->
              walk visited collected rest)
    in
    walk Record_set.empty empty ids
  in
  let accepted_ancestors visited ids =
    let rec walk visited = function
      | [] -> visited
      | id :: rest when Record_set.mem id visited -> walk visited rest
      | id :: rest -> (
          let visited = Record_set.add id visited in
          match find pool id with
          | Some { payload = Accepted_version version; _ } ->
              walk visited (version.accepted_parents @ rest)
          | Some { payload = Shared_revision _ | Branch_event _; _ } | None ->
              walk visited rest)
    in
    walk visited ids
  in
  Branch_map.bindings groups
  |> List.map (fun (branch_id, events) ->
      let superseded =
        List.fold_left
          (fun set (_, event) ->
            List.fold_left
              (fun set id -> Record_set.add id set)
              set event.previous_events)
          Record_set.empty events
      in
      let event_heads =
        List.filter_map
          (fun (id, _) ->
            if Record_set.mem id superseded then None else Some id)
          events
        |> List.sort Record_id.compare
      in
      let targets =
        inherited
          ~extract:(fun event -> event.targets)
          ~add:(fun set id -> Record_set.add id set)
          ~empty:Record_set.empty event_heads
        |> Record_set.elements
      in
      let ancestors =
        List.fold_left
          (fun set id ->
            match find pool id with
            | Some { payload = Accepted_version version; _ } ->
                accepted_ancestors set version.accepted_parents
            | Some { payload = Shared_revision _ | Branch_event _; _ } | None ->
                set)
          Record_set.empty targets
      in
      let accepted_heads =
        List.filter (fun id -> not (Record_set.mem id ancestors)) targets
      in
      {
        branch_id;
        event_heads;
        accepted_heads;
        display_names =
          inherited
            ~extract:(fun event -> Option.to_list event.display_name)
            ~add:(fun set name ->
              if List.mem name set then set else name :: set)
            ~empty:[] event_heads
          |> List.sort String.compare;
      })

type history_node = {
  history_id : History_id.t;
  parent : History_id.t option;
  snapshot : Object_id.t;
  working_basis : Record_id.t option;
  published_revisions : Record_id.t list;
}

let make_history_node ~id ~parent ~snapshot ~working_basis ~published_revisions
    =
  let* published_revisions =
    record_set "published history correspondence" published_revisions
  in
  let* () =
    match parent with
    | None -> Ok ()
    | Some parent ->
        if
          Workspace_id.equal
            (History_id.workspace parent)
            (History_id.workspace id)
        then
          if
            Int64.compare (History_id.sequence parent) (History_id.sequence id)
            < 0
          then Ok ()
          else Error (Invalid_field "history parent must precede its child")
        else if History_id.sequence id = 0L then Ok ()
        else
          Error
            (Invalid_field
               "cross-workspace ancestry must start at sequence zero")
  in
  Ok { history_id = id; parent; snapshot; working_basis; published_revisions }

module History = Map.Make (History_id)

type history = history_node History.t

let empty_history = History.empty
let history_nodes history = List.map snd (History.bindings history)

let retain_history history node =
  match History.find_opt node.history_id history with
  | Some existing when existing = node -> Ok (history, Unchanged)
  | Some _ ->
      Error
        (Identity_collision
           ("history sequence "
           ^ Int64.to_string (History_id.sequence node.history_id)))
  | None ->
      let* () =
        match node.parent with
        | None -> Ok ()
        | Some parent ->
            if History.mem parent history then Ok ()
            else Error (Missing_reference "history parent")
      in
      Ok (History.add node.history_id node history, Added)

type workspace_observation = {
  workspace : Workspace_id.t;
  cursor : History_id.t;
  working_basis : Record_id.t;
  basis_snapshot : Object_id.t;
  observed_snapshot : Object_id.t;
  correspondence : (Record_id.t * History_id.t) list;
}

let make_workspace_observation ~workspace ~cursor ~working_basis ~basis_snapshot
    ~observed_snapshot ~correspondence =
  let* () = bounded "workspace correspondence" correspondence in
  if not (Workspace_id.equal workspace (History_id.workspace cursor)) then
    Error (Invalid_field "workspace cursor belongs to another workspace")
  else
    let correspondence =
      List.sort (fun (a, _) (b, _) -> Record_id.compare a b) correspondence
    in
    let rec unique = function
      | (a, _) :: ((b, _) :: _ as rest) ->
          if Record_id.equal a b then
            Error (Duplicate_id "workspace correspondence")
          else unique rest
      | _ -> Ok ()
    in
    let* () = unique correspondence in
    Ok
      {
        workspace;
        cursor;
        working_basis;
        basis_snapshot;
        observed_snapshot;
        correspondence;
      }

type composition_request = {
  repository : Repository_id.t;
  branch : Branch_id.t;
  accepted_heads : Record_id.t list;
  selected_revisions : Record_id.t list;
  resolution_ids : Record_id.t list;
  authority_heads : Digest.t list;
  policy_heads : Digest.t list;
  review_evidence : Digest.t list;
  workspace : workspace_observation;
  composition_profile : string;
}

let make_composition_request ~repository ~branch ~accepted_heads
    ~selected_revisions ~resolution_ids ~authority_heads ~policy_heads
    ~review_evidence ~workspace ~composition_profile =
  let* accepted_heads = record_set "request accepted heads" accepted_heads in
  let* selected_revisions =
    record_set "request selected revisions" selected_revisions
  in
  let* resolution_ids = record_set "request resolutions" resolution_ids in
  let* authority_heads = digest_set "request authority heads" authority_heads in
  let* policy_heads = digest_set "request policy heads" policy_heads in
  let* review_evidence = digest_set "request review evidence" review_evidence in
  let* () = valid_profile composition_profile in
  if accepted_heads = [] || authority_heads = [] then
    Error (Invalid_field "request needs accepted and authority heads")
  else
    Ok
      {
        repository;
        branch;
        accepted_heads;
        selected_revisions;
        resolution_ids;
        authority_heads;
        policy_heads;
        review_evidence;
        workspace;
        composition_profile;
      }

let validate_request_references (pool : pool) (request : composition_request) =
  if not (Repository_id.equal pool.repository request.repository) then
    Error Wrong_scope
  else
    let* () =
      supported_policy ~policy_heads:request.policy_heads
        ~review_evidence:request.review_evidence
        ~resolutions:request.resolution_ids
    in
    let* () = require_all pool Accepted_version_kind request.accepted_heads in
    let* () =
      require_all pool Shared_revision_kind request.selected_revisions
    in
    let* _ =
      require pool Accepted_version_kind request.workspace.working_basis
    in
    require_all pool Shared_revision_kind
      (List.map fst request.workspace.correspondence)

type conflict = {
  path : string list;
  versions : Record_id.t list;
  private_workspace : bool;
}

type blocker =
  | Missing_objects of Object_id.t list
  | Conflicts of conflict list
  | Invalid_authority of string
  | Required_review_unsupported
  | Policy_unavailable of Digest.t list
  | Stale_inputs
  | Ambiguous_correspondence

type composition_result = {
  accepted_snapshot : Object_id.t;
  workspace_snapshot : Object_id.t;
}

type 'plan preparation = Prepared of 'plan | Blocked of blocker list

let check_review_requirement ~required =
  if required then Error Required_review_unsupported else Ok ()
