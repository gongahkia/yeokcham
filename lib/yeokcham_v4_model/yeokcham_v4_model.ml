type error =
  | Empty_identifier of string
  | Invalid_identifier of string
  | Empty_path
  | Unsafe_path_component of string
  | Invalid_span of { start_byte : int; end_byte : int }
  | Empty_edits
  | Empty_title
  | Duplicate_draft
  | Duplicate_change
  | Duplicate_delivery
  | Unknown_change
  | Unknown_decision
  | Unknown_revision
  | Active_draft_already_shared
  | Active_draft_not_shared
  | Revision_change_mismatch
  | Revision_author_mismatch
  | Revision_parent_mismatch
  | Initial_revision_has_parent
  | Received_revision_missing_parent
  | Active_change_withdrawal
  | Delivery_has_open_decisions
  | Delivery_includes_unknown_revision
  | Delivery_includes_duplicate_revision
  | Delivery_omits_active_change
  | Delivery_requires_shared_active_draft

let error_to_string = function
  | Empty_identifier kind -> "empty " ^ kind ^ " identifier"
  | Invalid_identifier value -> "invalid identifier: " ^ value
  | Empty_path -> "path must contain at least one component"
  | Unsafe_path_component component -> "unsafe path component: " ^ component
  | Invalid_span { start_byte; end_byte } ->
      Printf.sprintf "invalid span [%d, %d)" start_byte end_byte
  | Empty_edits -> "a change revision needs at least one edit"
  | Empty_title -> "draft title must not be empty"
  | Duplicate_draft -> "draft identifier already exists"
  | Duplicate_change -> "change identifier already exists"
  | Duplicate_delivery -> "delivery identifier already exists"
  | Unknown_change -> "unknown shared change"
  | Unknown_decision -> "unknown decision"
  | Unknown_revision -> "unknown revision"
  | Active_draft_already_shared -> "the active draft is already shared"
  | Active_draft_not_shared -> "the active draft is not shared"
  | Revision_change_mismatch -> "revision belongs to a different change"
  | Revision_author_mismatch -> "revision author differs from change author"
  | Revision_parent_mismatch -> "revision parent is not the current revision"
  | Initial_revision_has_parent -> "initial shared revision must not have a parent"
  | Received_revision_missing_parent ->
      "a received revision for an existing change must name its parent"
  | Active_change_withdrawal ->
      "close the active draft before withdrawing its shared change"
  | Delivery_has_open_decisions -> "cannot deliver while decisions are open"
  | Delivery_includes_unknown_revision ->
      "delivery includes a revision that is not currently visible"
  | Delivery_includes_duplicate_revision -> "delivery includes a revision twice"
  | Delivery_omits_active_change ->
      "delivery must include the active shared change or start from another draft"
  | Delivery_requires_shared_active_draft ->
      "delivery requires an active shared draft"

module type Identifier = sig
  type t

  val of_string : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Make_identifier (Name : sig
  val value : string
end) : Identifier = struct
  type t = string

  let valid_character = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | ':' | '/' -> true
    | _ -> false

  let of_string value =
    if String.length value = 0 then Error (Empty_identifier Name.value)
    else if String.for_all valid_character value then Ok value
    else Error (Invalid_identifier value)

  let to_string value = value
  let equal = String.equal
  let compare = String.compare
end

module Snapshot_id = Make_identifier (struct
  let value = "snapshot"
end)

module Draft_id = Make_identifier (struct
  let value = "draft"
end)

module Change_id = Make_identifier (struct
  let value = "change"
end)

module Revision_id = Make_identifier (struct
  let value = "revision"
end)

module Decision_id = Make_identifier (struct
  let value = "decision"
end)

module Delivery_id = Make_identifier (struct
  let value = "delivery"
end)

module Device_id = Make_identifier (struct
  let value = "device"
end)

module Path = struct
  type t = string list

  let safe_component component =
    String.length component > 0
    && not (String.equal component ".")
    && not (String.equal component "..")
    && not (String.contains component '/')
    && not (String.contains component '\000')

  let of_components = function
    | [] -> Error Empty_path
    | components ->
        let rec first_unsafe = function
          | [] -> None
          | component :: rest ->
              if safe_component component then first_unsafe rest else Some component
        in
        (match first_unsafe components with
        | None -> Ok components
        | Some component -> Error (Unsafe_path_component component))

  let components value = value
  let compare = List.compare String.compare
  let equal left right = compare left right = 0

  let rec is_ancestor ~ancestor ~descendant =
    match (ancestor, descendant) with
    | [], _ -> true
    | _, [] -> false
    | left :: left_rest, right :: right_rest ->
        String.equal left right && is_ancestor ~ancestor:left_rest ~descendant:right_rest

  let to_string value = String.concat "/" value
end

type span = { start_byte : int; end_byte : int }

let make_span ~start_byte ~end_byte =
  if start_byte < 0 || end_byte <= start_byte then
    Error (Invalid_span { start_byte; end_byte })
  else Ok { start_byte; end_byte }

type edit_kind = Text of span | Whole_path
type edit = { edit_path : Path.t; edit_kind : edit_kind }

type change_revision = {
  change : Change_id.t;
  revision : Revision_id.t;
  parent : Revision_id.t option;
  revision_author : Device_id.t;
  base_snapshot : Snapshot_id.t;
  result_snapshot : Snapshot_id.t;
  edits : edit list;
}

let make_change_revision ~change ~revision ~parent ~author ~base ~result ~edits =
  match edits with
  | [] -> Error Empty_edits
  | _ ->
      Ok
        {
          change;
          revision;
          parent;
          revision_author = author;
          base_snapshot = base;
          result_snapshot = result;
          edits;
        }

type draft_state = Active | Closed

type draft = {
  draft_id : Draft_id.t;
  title : string;
  state : draft_state;
  latest_checkpoint : Snapshot_id.t;
  shared_change : Change_id.t option;
}

type shared_change = {
  change_id : Change_id.t;
  source_draft : Draft_id.t option;
  change_author : Device_id.t;
  revisions : change_revision list;
  withdrawn : bool;
}

type decision_kind = Stale_base | Edit_overlap

type decision = {
  decision_id : Decision_id.t;
  decision_kind : decision_kind;
  decision_paths : Path.t list;
  candidates : change_revision list;
}

type projection = {
  projection_baseline : Snapshot_id.t;
  applied : change_revision list;
  decisions : decision list;
}

type delivery = {
  delivery_id : Delivery_id.t;
  delivery_author : Device_id.t;
  delivery_snapshot : Snapshot_id.t;
  included : Revision_id.t list;
  created_at : int64;
}

type project = {
  creator : Device_id.t;
  baseline : Snapshot_id.t;
  active : Draft_id.t;
  drafts : draft list;
  changes : shared_change list;
  deliveries : delivery list;
}

let nonempty_title title = String.length (String.trim title) > 0

let init ~creator ~initial_snapshot ~initial_draft ~title =
  let title = if nonempty_title title then title else "untitled draft" in
  {
    creator;
    baseline = initial_snapshot;
    active = initial_draft;
    drafts =
      [
        {
          draft_id = initial_draft;
          title;
          state = Active;
          latest_checkpoint = initial_snapshot;
          shared_change = None;
        };
      ];
    changes = [];
    deliveries = [];
  }

let creator project = project.creator

let drafts project = project.drafts
let shared_changes project = project.changes
let deliveries project = project.deliveries

let find_draft project draft_id =
  List.find_opt
    (fun (draft : draft) -> Draft_id.equal draft.draft_id draft_id)
    project.drafts

let active_draft project =
  match find_draft project project.active with
  | Some draft -> draft
  | None -> invalid_arg "V4 project lacks its active draft"

let replace_draft project (replacement : draft) =
  {
    project with
    drafts =
      List.map
        (fun (draft : draft) ->
          if Draft_id.equal draft.draft_id replacement.draft_id then replacement else draft)
        project.drafts;
  }

let checkpoint project ~snapshot =
  let active = active_draft project in
  replace_draft project { active with latest_checkpoint = snapshot }

let new_draft project ~id ~title =
  if not (nonempty_title title) then Error Empty_title
  else if
    List.exists
      (fun (draft : draft) -> Draft_id.equal draft.draft_id id)
      project.drafts
  then
    Error Duplicate_draft
  else
    let active = active_draft project in
    let closed = { active with state = Closed } in
    let next =
      {
        draft_id = id;
        title;
        state = Active;
        latest_checkpoint = active.latest_checkpoint;
        shared_change = None;
      }
    in
    Ok
      {
        project with
        active = id;
        drafts =
          next
          :: List.map
               (fun (draft : draft) ->
                 if Draft_id.equal draft.draft_id closed.draft_id then closed else draft)
               project.drafts;
      }

let find_change project change_id =
  List.find_opt
    (fun (change : shared_change) -> Change_id.equal change.change_id change_id)
    project.changes

let latest_revision (change : shared_change) =
  match change.revisions with
  | revision :: _ -> revision
  | [] -> invalid_arg "V4 shared change lacks an initial revision"

let replace_change project (replacement : shared_change) =
  {
    project with
    changes =
      List.map
        (fun (change : shared_change) ->
          if Change_id.equal change.change_id replacement.change_id then replacement else change)
        project.changes;
  }

let validate_initial_revision revision =
  match revision.parent with None -> Ok () | Some _ -> Error Initial_revision_has_parent

let validate_next_revision (change : shared_change) revision =
  if not (Change_id.equal change.change_id revision.change) then Error Revision_change_mismatch
  else if not (Device_id.equal change.change_author revision.revision_author) then
    Error Revision_author_mismatch
  else
    match revision.parent with
    | None -> Error Received_revision_missing_parent
    | Some parent when Revision_id.equal parent (latest_revision change).revision -> Ok ()
    | Some _ -> Error Revision_parent_mismatch

let share_active project revision =
  let active = active_draft project in
  match active.shared_change with
  | Some _ -> Error Active_draft_already_shared
  | None ->
      if Option.is_some (find_change project revision.change) then Error Duplicate_change
      else
        match validate_initial_revision revision with
        | Error error -> Error error
        | Ok () ->
            let change =
              {
                change_id = revision.change;
                source_draft = Some active.draft_id;
                change_author = revision.revision_author;
                revisions = [ revision ];
                withdrawn = false;
              }
            in
            let project = { project with changes = change :: project.changes } in
            Ok (replace_draft project { active with shared_change = Some revision.change })

let amend_active project revision =
  let active = active_draft project in
  match active.shared_change with
  | None -> Error Active_draft_not_shared
  | Some change_id -> (
      match find_change project change_id with
      | None -> invalid_arg "active draft refers to a missing V4 shared change"
      | Some change ->
          match validate_next_revision change revision with
          | Error error -> Error error
          | Ok () -> Ok (replace_change project { change with revisions = revision :: change.revisions }))

let receive project revision =
  match find_change project revision.change with
  | None -> (
      match validate_initial_revision revision with
      | Error error -> Error error
      | Ok () ->
          Ok
            {
              project with
              changes =
                {
                  change_id = revision.change;
                  source_draft = None;
                  change_author = revision.revision_author;
                  revisions = [ revision ];
                  withdrawn = false;
                }
                :: project.changes;
            })
  | Some change ->
      if change.withdrawn then Error Unknown_change
      else
        match validate_next_revision change revision with
        | Error error -> Error error
        | Ok () -> Ok (replace_change project { change with revisions = revision :: change.revisions })

let withdraw project ~change:change_id =
  match find_change project change_id with
  | None -> Error Unknown_change
  | Some change ->
      let active = active_draft project in
      if Option.fold ~none:false ~some:(Change_id.equal change_id) active.shared_change then
        Error Active_change_withdrawal
      else Ok (replace_change project { change with withdrawn = true })

let spans_overlap left right =
  left.start_byte < right.end_byte && right.start_byte < left.end_byte

let edits_conflict left right =
  if Path.equal left.edit_path right.edit_path then
    match (left.edit_kind, right.edit_kind) with
    | Text left_span, Text right_span -> spans_overlap left_span right_span
    | Text _, Whole_path | Whole_path, Text _ | Whole_path, Whole_path -> true
  else
    Path.is_ancestor ~ancestor:left.edit_path ~descendant:right.edit_path
    || Path.is_ancestor ~ancestor:right.edit_path ~descendant:left.edit_path

let revisions_conflict left right =
  List.exists
    (fun left_edit -> List.exists (fun right_edit -> edits_conflict left_edit right_edit) right.edits)
    left.edits

let unique_paths revisions =
  revisions
  |> List.concat_map
       (fun revision -> List.map (fun edit -> edit.edit_path) revision.edits)
  |> List.sort_uniq Path.compare

let decision_id kind candidates =
  let kind = match kind with Stale_base -> "stale" | Edit_overlap -> "overlap" in
  let revisions =
    candidates
    |> List.map (fun candidate -> Revision_id.to_string candidate.revision)
    |> List.sort String.compare
  in
  match Decision_id.of_string ("decision:" ^ kind ^ ":" ^ String.concat ":" revisions) with
  | Ok id -> id
  | Error _ -> invalid_arg "generated V4 decision identifier is invalid"

let make_decision kind candidates =
  {
    decision_id = decision_id kind candidates;
    decision_kind = kind;
    decision_paths = unique_paths candidates;
    candidates;
  }

let ordered_visible_changes project =
  project.changes
  |> List.filter (fun (change : shared_change) -> not change.withdrawn)
  |> List.map latest_revision
  |> List.sort (fun left right ->
         let change_order = Change_id.compare left.change right.change in
         if change_order <> 0 then change_order else Revision_id.compare left.revision right.revision)

let projection project =
  let rec compose applied decisions = function
    | [] ->
        {
          projection_baseline = project.baseline;
          applied = List.rev applied;
          decisions = List.rev decisions;
        }
    | revision :: rest ->
        if not (Snapshot_id.equal revision.base_snapshot project.baseline) then
          compose applied (make_decision Stale_base [ revision ] :: decisions) rest
        else
          let conflicts = List.filter (fun existing -> revisions_conflict existing revision) applied in
          if conflicts = [] then compose (revision :: applied) decisions rest
          else compose applied (make_decision Edit_overlap (revision :: conflicts) :: decisions) rest
  in
  compose [] [] (ordered_visible_changes project)

let resolve project ~decision:decision_id ~replacement =
  let current = projection project in
  match
    List.find_opt
      (fun (decision : decision) ->
        Decision_id.equal decision.decision_id decision_id)
      current.decisions
  with
  | None -> Error Unknown_decision
  | Some _ -> receive project replacement

let contains_duplicate identifiers equal =
  let rec loop seen = function
    | [] -> false
    | identifier :: rest ->
        if List.exists (fun prior -> equal identifier prior) seen then true
        else loop (identifier :: seen) rest
  in
  loop [] identifiers

let deliver project ~id ~author ~snapshot ~included ~next_draft ~next_title ~created_at =
  if
    List.exists
      (fun (delivery : delivery) -> Delivery_id.equal delivery.delivery_id id)
      project.deliveries
  then
    Error Duplicate_delivery
  else if not (nonempty_title next_title) then Error Empty_title
  else if
    List.exists
      (fun (draft : draft) -> Draft_id.equal draft.draft_id next_draft)
      project.drafts
  then
    Error Duplicate_draft
  else if (projection project).decisions <> [] then Error Delivery_has_open_decisions
  else if contains_duplicate included Revision_id.equal then Error Delivery_includes_duplicate_revision
  else
    let visible = (projection project).applied in
    let includes revision = List.exists (fun id -> Revision_id.equal id revision.revision) included in
    if
      not
        (List.for_all
           (fun revision_id ->
             List.exists (fun revision -> Revision_id.equal revision.revision revision_id) visible)
           included)
    then
      Error Delivery_includes_unknown_revision
    else
      let active = active_draft project in
      match active.shared_change with
      | None -> Error Delivery_requires_shared_active_draft
      | Some active_change -> (
          match find_change project active_change with
          | None -> invalid_arg "active draft refers to a missing V4 shared change"
          | Some change ->
              if not (includes (latest_revision change)) then Error Delivery_omits_active_change
              else
                let selected (change : shared_change) = includes (latest_revision change) in
                let closed = { active with state = Closed } in
                let next =
                  {
                    draft_id = next_draft;
                    title = next_title;
                    state = Active;
                    latest_checkpoint = snapshot;
                    shared_change = None;
                  }
                in
                let delivery =
                  {
                    delivery_id = id;
                    delivery_author = author;
                    delivery_snapshot = snapshot;
                    included;
                    created_at;
                  }
                in
                Ok
                  {
                    project with
                    baseline = snapshot;
                    active = next_draft;
                    drafts =
                      next
                      :: List.map
                           (fun (draft : draft) ->
                             if Draft_id.equal draft.draft_id closed.draft_id then closed
                             else draft)
                           project.drafts;
                    changes =
                      List.filter
                        (fun (change : shared_change) -> not (selected change))
                        project.changes;
                    deliveries = delivery :: project.deliveries;
                  })
