type error =
  | Empty_identifier of string
  | Invalid_identifier of string
  | Empty_path
  | Unsafe_path_component of string
  | Invalid_span of { start_byte : int; end_byte : int }
  | Empty_edits
  | Empty_title
  | Invalid_project_state of string
  | Duplicate_draft
  | Duplicate_change
  | Duplicate_revision
  | Duplicate_delivery
  | Unknown_change
  | Unknown_decision
  | Decision_already_resolved
  | Unknown_revision
  | Active_draft_already_shared
  | Active_draft_not_shared
  | Revision_change_mismatch
  | Revision_author_mismatch
  | Revision_parent_mismatch
  | Initial_revision_has_parent
  | Received_revision_missing_parent
  | Resolution_base_mismatch
  | Active_change_withdrawal
  | Delivery_has_open_decisions
  | Delivery_includes_unknown_revision
  | Delivery_includes_duplicate_revision
  | Delivery_omits_active_change
  | Delivery_requires_shared_active_draft
  | Unknown_checkpoint
  | Not_pinned
  | Invalid_keep_recent
  | Empty_username
  | Invalid_username of string
  | Username_already_registered

let error_to_string = function
  | Empty_identifier kind -> "empty " ^ kind ^ " identifier"
  | Invalid_identifier value -> "invalid identifier: " ^ value
  | Empty_path -> "path must contain at least one component"
  | Unsafe_path_component component -> "unsafe path component: " ^ component
  | Invalid_span { start_byte; end_byte } ->
      Printf.sprintf "invalid span [%d, %d)" start_byte end_byte
  | Empty_edits -> "a change revision needs at least one edit"
  | Empty_title -> "draft title must not be empty"
  | Invalid_project_state detail -> "invalid persisted project state: " ^ detail
  | Duplicate_draft -> "draft identifier already exists"
  | Duplicate_change -> "change identifier already exists"
  | Duplicate_revision -> "revision identifier already exists"
  | Duplicate_delivery -> "delivery identifier already exists"
  | Unknown_change -> "unknown shared change"
  | Unknown_decision -> "unknown decision"
  | Decision_already_resolved -> "decision already has a resolution"
  | Unknown_revision -> "unknown revision"
  | Active_draft_already_shared -> "the active draft is already shared"
  | Active_draft_not_shared -> "the active draft is not shared"
  | Revision_change_mismatch -> "revision belongs to a different change"
  | Revision_author_mismatch -> "revision author differs from change author"
  | Revision_parent_mismatch -> "revision parent is not the current revision"
  | Initial_revision_has_parent ->
      "initial shared revision must not have a parent"
  | Received_revision_missing_parent ->
      "a received revision for an existing change must name its parent"
  | Resolution_base_mismatch ->
      "a resolution must be based on the current delivery baseline"
  | Active_change_withdrawal ->
      "close the active draft before withdrawing its shared change"
  | Delivery_has_open_decisions -> "cannot deliver while decisions are open"
  | Delivery_includes_unknown_revision ->
      "delivery includes a revision that is not currently visible"
  | Delivery_includes_duplicate_revision -> "delivery includes a revision twice"
  | Delivery_omits_active_change ->
      "delivery must include the active shared change or start from another \
       draft"
  | Delivery_requires_shared_active_draft ->
      "delivery requires an active shared draft"
  | Unknown_checkpoint -> "checkpoint is not retained by this project"
  | Not_pinned -> "checkpoint is not pinned"
  | Invalid_keep_recent -> "compaction keep-recent count must be nonnegative"
  | Empty_username -> "username must not be empty"
  | Invalid_username value -> "invalid username: " ^ value
  | Username_already_registered -> "username is already registered to a device"

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

module Username = struct
  type t = string

  let valid_first = function 'a' .. 'z' | '0' .. '9' -> true | _ -> false

  let valid_rest = function
    | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false

  let of_string value =
    let length = String.length value in
    if length = 0 then Error Empty_username
    else if
      length > 32
      || (not (valid_first value.[0]))
      || not (String.for_all valid_rest value)
    then Error (Invalid_username value)
    else Ok value

  let to_string value = value
  let equal = String.equal
  let compare = String.compare
end

module Path = struct
  type t = string list

  let safe_component component =
    String.length component > 0
    && (not (String.equal component "."))
    && (not (String.equal component ".."))
    && (not (String.contains component '/'))
    && not (String.contains component '\000')

  let of_components = function
    | [] -> Error Empty_path
    | components -> (
        let rec first_unsafe = function
          | [] -> None
          | component :: rest ->
              if safe_component component then first_unsafe rest
              else Some component
        in
        match first_unsafe components with
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
        String.equal left right
        && is_ancestor ~ancestor:left_rest ~descendant:right_rest

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

let make_change_revision ~change ~revision ~parent ~author ~base ~result ~edits
    =
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

type checkpoint = { checkpoint_snapshot : Snapshot_id.t }

type shared_change = {
  change_id : Change_id.t;
  source_draft : Draft_id.t option;
  change_author : Device_id.t;
  revisions : change_revision list;
  withdrawn : bool;
}

type decision_kind = Stale_base | Edit_overlap

type edit_reference = {
  referenced_revision : Revision_id.t;
  referenced_edit_index : int;
}

type edit_candidate = {
  candidate_revision : change_revision;
  candidate_edit_index : int;
  candidate_edit : edit;
}

type decision = {
  decision_id : Decision_id.t;
  decision_kind : decision_kind;
  decision_paths : Path.t list;
  candidates : edit_candidate list;
}

type projection = {
  projection_baseline : Snapshot_id.t;
  applied : change_revision list;
  applied_edits : edit_candidate list;
  decisions : decision list;
}

type delivery = {
  delivery_id : Delivery_id.t;
  delivery_author : Device_id.t;
  delivery_snapshot : Snapshot_id.t;
  included : Revision_id.t list;
  created_at : int64;
}

type resolution = {
  resolved_decision : Decision_id.t;
  suppressed_edits : edit_reference list;
  replacement_revision : change_revision;
}

type username_registration = {
  username_device : Device_id.t;
  username : Username.t;
}

type state = {
  state_creator : Device_id.t;
  state_baseline : Snapshot_id.t;
  state_active_draft : Draft_id.t;
  state_drafts : draft list;
  state_checkpoints : checkpoint list;
  state_changes : shared_change list;
  state_resolutions : resolution list;
  state_deliveries : delivery list;
  state_pins : Snapshot_id.t list;
  state_usernames : username_registration list;
}

type project = {
  creator : Device_id.t;
  baseline : Snapshot_id.t;
  active : Draft_id.t;
  drafts : draft list;
  checkpoints : checkpoint list;
  changes : shared_change list;
  resolutions : resolution list;
  deliveries : delivery list;
  pins : Snapshot_id.t list;
  usernames : username_registration list;
}

let nonempty_title title = String.length (String.trim title) > 0

let init ~creator ~username ~initial_snapshot ~initial_draft ~title =
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
    checkpoints = [ { checkpoint_snapshot = initial_snapshot } ];
    resolutions = [];
    deliveries = [];
    pins = [];
    usernames = [ { username_device = creator; username } ];
  }

let creator project = project.creator
let drafts project = project.drafts
let checkpoints project = project.checkpoints
let pins project = project.pins
let shared_changes project = project.changes
let resolutions project = project.resolutions
let deliveries project = project.deliveries
let usernames project = project.usernames

let username_for_device project ~device =
  List.find_map
    (fun registration ->
      if Device_id.equal registration.username_device device then
        Some registration.username
      else None)
    project.usernames

let export project =
  {
    state_creator = project.creator;
    state_baseline = project.baseline;
    state_active_draft = project.active;
    state_drafts = project.drafts;
    state_checkpoints = project.checkpoints;
    state_changes = project.changes;
    state_resolutions = project.resolutions;
    state_deliveries = project.deliveries;
    state_pins = project.pins;
    state_usernames = project.usernames;
  }

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
          if Draft_id.equal draft.draft_id replacement.draft_id then replacement
          else draft)
        project.drafts;
  }

let record_checkpoint project snapshot =
  if
    List.exists
      (fun checkpoint ->
        Snapshot_id.equal checkpoint.checkpoint_snapshot snapshot)
      project.checkpoints
  then project
  else
    {
      project with
      checkpoints = { checkpoint_snapshot = snapshot } :: project.checkpoints;
    }

let retain_revision project revision =
  record_checkpoint
    (record_checkpoint project revision.base_snapshot)
    revision.result_snapshot

let checkpoint project ~snapshot =
  let active = active_draft project in
  record_checkpoint project snapshot |> fun project ->
  replace_draft project { active with latest_checkpoint = snapshot }

let new_draft project ~id ~title =
  if not (nonempty_title title) then Error Empty_title
  else if
    List.exists
      (fun (draft : draft) -> Draft_id.equal draft.draft_id id)
      project.drafts
  then Error Duplicate_draft
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
                 if Draft_id.equal draft.draft_id closed.draft_id then closed
                 else draft)
               project.drafts;
      }

let find_change project change_id =
  List.find_opt
    (fun (change : shared_change) -> Change_id.equal change.change_id change_id)
    project.changes

let revision_exists project revision_id =
  let shared =
    List.exists
      (fun (change : shared_change) ->
        List.exists
          (fun revision -> Revision_id.equal revision.revision revision_id)
          change.revisions)
      project.changes
  in
  shared
  || List.exists
       (fun resolution ->
         Revision_id.equal resolution.replacement_revision.revision revision_id)
       project.resolutions

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
          if Change_id.equal change.change_id replacement.change_id then
            replacement
          else change)
        project.changes;
  }

let validate_initial_revision revision =
  match revision.parent with
  | None -> Ok ()
  | Some _ -> Error Initial_revision_has_parent

let validate_next_revision (change : shared_change) revision =
  if not (Change_id.equal change.change_id revision.change) then
    Error Revision_change_mismatch
  else if not (Device_id.equal change.change_author revision.revision_author)
  then Error Revision_author_mismatch
  else
    match revision.parent with
    | None -> Error Received_revision_missing_parent
    | Some parent
      when Revision_id.equal parent (latest_revision change).revision ->
        Ok ()
    | Some _ -> Error Revision_parent_mismatch

let has_duplicate equal values =
  let rec loop seen = function
    | [] -> false
    | value :: rest ->
        if List.exists (fun prior -> equal value prior) seen then true
        else loop (value :: seen) rest
  in
  loop [] values

let register_username project ~device ~username =
  match
    List.find_opt
      (fun registration ->
        Username.equal registration.username username
        && not (Device_id.equal registration.username_device device))
      project.usernames
  with
  | Some _ -> Error Username_already_registered
  | None ->
      let replacement = { username_device = device; username } in
      let present =
        List.exists
          (fun registration ->
            Device_id.equal registration.username_device device)
          project.usernames
      in
      let usernames =
        if present then
          List.map
            (fun registration ->
              if Device_id.equal registration.username_device device then
                replacement
              else registration)
            project.usernames
        else replacement :: project.usernames
      in
      Ok { project with usernames }

let import state =
  let invalid detail = Error (Invalid_project_state detail) in
  if
    has_duplicate Draft_id.equal
      (List.map (fun (draft : draft) -> draft.draft_id) state.state_drafts)
  then invalid "draft identifiers are not unique"
  else if
    has_duplicate Device_id.equal
      (List.map
         (fun registration -> registration.username_device)
         state.state_usernames)
  then invalid "username devices are not unique"
  else if
    has_duplicate Username.equal
      (List.map
         (fun registration -> registration.username)
         state.state_usernames)
  then invalid "usernames are not unique"
  else if state.state_checkpoints = [] then
    invalid "project has no saved checkpoint"
  else if
    has_duplicate Snapshot_id.equal
      (List.map
         (fun checkpoint -> checkpoint.checkpoint_snapshot)
         state.state_checkpoints)
  then invalid "checkpoint snapshots are not unique"
  else if has_duplicate Snapshot_id.equal state.state_pins then
    invalid "pinned snapshots are not unique"
  else if
    List.exists
      (fun pin ->
        not
          (List.exists
             (fun checkpoint ->
               Snapshot_id.equal checkpoint.checkpoint_snapshot pin)
             state.state_checkpoints))
      state.state_pins
  then invalid "pinned snapshot is not retained"
  else if
    not
      (List.exists
         (fun checkpoint ->
           Snapshot_id.equal checkpoint.checkpoint_snapshot state.state_baseline)
         state.state_checkpoints)
  then invalid "delivery baseline is not retained"
  else if
    List.exists
      (fun (draft : draft) ->
        not
          (List.exists
             (fun checkpoint ->
               Snapshot_id.equal checkpoint.checkpoint_snapshot
                 draft.latest_checkpoint)
             state.state_checkpoints))
      state.state_drafts
  then invalid "draft checkpoint is not retained"
  else if
    has_duplicate Change_id.equal
      (List.map
         (fun (change : shared_change) -> change.change_id)
         state.state_changes)
  then invalid "change identifiers are not unique"
  else if
    has_duplicate Delivery_id.equal
      (List.map
         (fun (delivery : delivery) -> delivery.delivery_id)
         state.state_deliveries)
  then invalid "delivery identifiers are not unique"
  else
    let active =
      List.filter
        (fun (draft : draft) -> draft.state = Active)
        state.state_drafts
    in
    match active with
    | [ draft ] when Draft_id.equal draft.draft_id state.state_active_draft ->
        let all_revisions =
          List.concat_map
            (fun (change : shared_change) -> change.revisions)
            state.state_changes
          @ List.map
              (fun resolution -> resolution.replacement_revision)
              state.state_resolutions
        in
        if
          has_duplicate Revision_id.equal
            (List.map (fun revision -> revision.revision) all_revisions)
        then invalid "revision identifiers are not unique"
        else
          let valid_revision_chain (change : shared_change) = function
            | [] -> Error "shared change has no initial revision"
            | first :: rest -> (
                if not (Change_id.equal first.change change.change_id) then
                  Error "initial revision names a different change"
                else if
                  not
                    (Device_id.equal first.revision_author change.change_author)
                then Error "initial revision names a different author"
                else
                  match first.parent with
                  | Some _ -> Error "initial revision has a parent"
                  | None ->
                      let rec follow previous = function
                        | [] -> Ok ()
                        | next :: remaining -> (
                            if
                              not (Change_id.equal next.change change.change_id)
                            then Error "revision names a different change"
                            else if
                              not
                                (Device_id.equal next.revision_author
                                   change.change_author)
                            then Error "revision names a different author"
                            else
                              match next.parent with
                              | Some parent
                                when Revision_id.equal parent previous.revision
                                ->
                                  follow next remaining
                              | Some _ -> Error "revision parent is not linear"
                              | None ->
                                  Error "non-initial revision lacks parent")
                      in
                      follow first rest)
          in
          let changes_valid =
            List.for_all
              (fun (change : shared_change) ->
                change.revisions <> []
                && Result.is_ok
                     (valid_revision_chain change (List.rev change.revisions)))
              state.state_changes
          in
          if not changes_valid then
            invalid "shared change revision chain is invalid"
          else if
            List.exists
              (fun (draft : draft) -> not (nonempty_title draft.title))
              state.state_drafts
          then invalid "draft title is empty"
          else if
            List.exists
              (fun resolution ->
                resolution.replacement_revision.parent <> None
                || (not
                      (Snapshot_id.equal
                         resolution.replacement_revision.base_snapshot
                         state.state_baseline))
                || List.exists
                     (fun reference -> reference.referenced_edit_index < 0)
                     resolution.suppressed_edits)
              state.state_resolutions
          then invalid "resolution is malformed"
          else
            let named_revision_snapshots =
              List.concat_map
                (fun (change : shared_change) ->
                  List.concat_map
                    (fun revision ->
                      [ revision.base_snapshot; revision.result_snapshot ])
                    change.revisions)
                state.state_changes
              @ List.concat_map
                  (fun resolution ->
                    [
                      resolution.replacement_revision.base_snapshot;
                      resolution.replacement_revision.result_snapshot;
                    ])
                  state.state_resolutions
              @ List.map
                  (fun (delivery : delivery) -> delivery.delivery_snapshot)
                  state.state_deliveries
            in
            if
              List.exists
                (fun snapshot ->
                  not
                    (List.exists
                       (fun checkpoint ->
                         Snapshot_id.equal checkpoint.checkpoint_snapshot
                           snapshot)
                       state.state_checkpoints))
                named_revision_snapshots
            then invalid "named history snapshot is not retained"
            else
              let project =
                {
                  creator = state.state_creator;
                  baseline = state.state_baseline;
                  active = state.state_active_draft;
                  drafts = state.state_drafts;
                  checkpoints = state.state_checkpoints;
                  changes = state.state_changes;
                  resolutions = state.state_resolutions;
                  deliveries = state.state_deliveries;
                  pins = state.state_pins;
                  usernames = state.state_usernames;
                }
              in
              let active = active_draft project in
              let active_link_valid =
                match active.shared_change with
                | None -> true
                | Some change_id -> (
                    match find_change project change_id with
                    | Some change ->
                        Option.fold ~none:false
                          ~some:(Draft_id.equal active.draft_id)
                          change.source_draft
                    | None -> false)
              in
              if active_link_valid then Ok project
              else invalid "active draft refers to a missing shared change"
    | [] -> invalid "project has no active draft"
    | _ -> invalid "project has more than one active draft"

let share_active project revision =
  let active = active_draft project in
  match active.shared_change with
  | Some _ -> Error Active_draft_already_shared
  | None -> (
      if revision_exists project revision.revision then Error Duplicate_revision
      else if Option.is_some (find_change project revision.change) then
        Error Duplicate_change
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
            let project =
              retain_revision
                { project with changes = change :: project.changes }
                revision
            in
            Ok
              (replace_draft project
                 { active with shared_change = Some revision.change }))

let amend_active project revision =
  let active = active_draft project in
  match active.shared_change with
  | None -> Error Active_draft_not_shared
  | Some change_id -> (
      match find_change project change_id with
      | None -> invalid_arg "active draft refers to a missing V4 shared change"
      | Some change -> (
          if revision_exists project revision.revision then
            Error Duplicate_revision
          else
            match validate_next_revision change revision with
            | Error error -> Error error
            | Ok () ->
                Ok
                  (replace_change
                     (retain_revision project revision)
                     { change with revisions = revision :: change.revisions })))

let receive project revision =
  if revision_exists project revision.revision then Error Duplicate_revision
  else
    match find_change project revision.change with
    | None -> (
        match validate_initial_revision revision with
        | Error error -> Error error
        | Ok () ->
            Ok
              (retain_revision
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
                 }
                 revision))
    | Some change -> (
        if change.withdrawn then Error Unknown_change
        else
          match validate_next_revision change revision with
          | Error error -> Error error
          | Ok () ->
              Ok
                (replace_change
                   (retain_revision project revision)
                   { change with revisions = revision :: change.revisions }))

let withdraw project ~change:change_id =
  match find_change project change_id with
  | None -> Error Unknown_change
  | Some change ->
      let active = active_draft project in
      if
        Option.fold ~none:false
          ~some:(Change_id.equal change_id)
          active.shared_change
      then Error Active_change_withdrawal
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

let candidates_of_revision revision =
  List.mapi
    (fun candidate_edit_index candidate_edit ->
      { candidate_revision = revision; candidate_edit_index; candidate_edit })
    revision.edits

let reference_of_candidate candidate =
  {
    referenced_revision = candidate.candidate_revision.revision;
    referenced_edit_index = candidate.candidate_edit_index;
  }

let same_reference left right =
  Revision_id.equal left.referenced_revision right.referenced_revision
  && Int.equal left.referenced_edit_index right.referenced_edit_index

let candidates_conflict left right =
  edits_conflict left.candidate_edit right.candidate_edit

let compare_candidates left right =
  let change_order =
    Change_id.compare left.candidate_revision.change
      right.candidate_revision.change
  in
  if change_order <> 0 then change_order
  else
    let revision_order =
      Revision_id.compare left.candidate_revision.revision
        right.candidate_revision.revision
    in
    if revision_order <> 0 then revision_order
    else Int.compare left.candidate_edit_index right.candidate_edit_index

let unique_paths candidates =
  candidates
  |> List.map (fun candidate -> candidate.candidate_edit.edit_path)
  |> List.sort_uniq Path.compare

let decision_id kind candidates =
  let kind =
    match kind with Stale_base -> "stale" | Edit_overlap -> "overlap"
  in
  let edits =
    candidates
    |> List.map (fun candidate ->
        Revision_id.to_string candidate.candidate_revision.revision
        ^ "."
        ^ string_of_int candidate.candidate_edit_index)
    |> List.sort String.compare
  in
  match
    Decision_id.of_string ("decision:" ^ kind ^ ":" ^ String.concat ":" edits)
  with
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
      if change_order <> 0 then change_order
      else Revision_id.compare left.revision right.revision)

let suppressed_candidate project candidate =
  let reference = reference_of_candidate candidate in
  List.exists
    (fun resolution ->
      List.exists
        (fun suppressed -> same_reference suppressed reference)
        resolution.suppressed_edits)
    project.resolutions

let resolution_revisions project =
  List.map
    (fun resolution -> resolution.replacement_revision)
    project.resolutions

let revisions_from_candidates candidates =
  candidates
  |> List.sort compare_candidates
  |> List.fold_left
       (fun revisions candidate ->
         if
           List.exists
             (fun revision ->
               Revision_id.equal revision.revision
                 candidate.candidate_revision.revision)
             revisions
         then revisions
         else candidate.candidate_revision :: revisions)
       []
  |> List.rev

let stale_components candidates =
  let rec gather current_revision current rest components =
    match rest with
    | [] -> List.rev (List.rev current :: components)
    | candidate :: rest ->
        if
          Revision_id.equal current_revision
            candidate.candidate_revision.revision
        then gather current_revision (candidate :: current) rest components
        else
          gather candidate.candidate_revision.revision [ candidate ] rest
            (List.rev current :: components)
  in
  match List.sort compare_candidates candidates with
  | [] -> []
  | candidate :: rest ->
      gather candidate.candidate_revision.revision [ candidate ] rest []

let overlap_components candidates =
  let add_candidate components candidate =
    let connected, disconnected =
      List.partition
        (fun component ->
          List.exists
            (fun existing -> candidates_conflict existing candidate)
            component)
        components
    in
    (candidate :: List.concat connected) :: disconnected
  in
  candidates
  |> List.sort compare_candidates
  |> List.fold_left add_candidate []
  |> List.map (List.sort compare_candidates)
  |> List.sort (fun left right ->
      match (left, right) with
      | left_candidate :: _, right_candidate :: _ ->
          compare_candidates left_candidate right_candidate
      | [], [] -> 0
      | [], _ -> -1
      | _, [] -> 1)

let projection project =
  let visible =
    ordered_visible_changes project @ resolution_revisions project
    |> List.concat_map candidates_of_revision
    |> List.filter (fun candidate ->
        not (suppressed_candidate project candidate))
    |> List.sort compare_candidates
  in
  let stale, current =
    List.partition
      (fun candidate ->
        not
          (Snapshot_id.equal candidate.candidate_revision.base_snapshot
             project.baseline))
      visible
  in
  let components = overlap_components current in
  let applied_edits, overlap_decisions =
    List.fold_left
      (fun (applied, decisions) component ->
        match component with
        | [ candidate ] -> (candidate :: applied, decisions)
        | _ -> (applied, make_decision Edit_overlap component :: decisions))
      ([], []) components
  in
  let decisions =
    List.map (make_decision Stale_base) (stale_components stale)
    @ List.rev overlap_decisions
    |> List.sort (fun left right ->
        Decision_id.compare left.decision_id right.decision_id)
  in
  let applied_edits = List.rev applied_edits in
  {
    projection_baseline = project.baseline;
    applied = revisions_from_candidates applied_edits;
    applied_edits;
    decisions;
  }

let resolve project ~decision:decision_id ~replacement =
  if
    List.exists
      (fun resolution ->
        Decision_id.equal resolution.resolved_decision decision_id)
      project.resolutions
  then Error Decision_already_resolved
  else if revision_exists project replacement.revision then
    Error Duplicate_revision
  else if Option.is_some (find_change project replacement.change) then
    Error Duplicate_change
  else if not (Snapshot_id.equal replacement.base_snapshot project.baseline)
  then Error Resolution_base_mismatch
  else
    match replacement.parent with
    | Some _ -> Error Initial_revision_has_parent
    | None -> (
        let current = projection project in
        match
          List.find_opt
            (fun (decision : decision) ->
              Decision_id.equal decision.decision_id decision_id)
            current.decisions
        with
        | None -> Error Unknown_decision
        | Some resolved ->
            let suppressed_edits =
              List.map reference_of_candidate resolved.candidates
            in
            Ok
              (retain_revision
                 {
                   project with
                   resolutions =
                     {
                       resolved_decision = decision_id;
                       suppressed_edits;
                       replacement_revision = replacement;
                     }
                     :: project.resolutions;
                 }
                 replacement))

let contains_duplicate identifiers equal =
  let rec loop seen = function
    | [] -> false
    | identifier :: rest ->
        if List.exists (fun prior -> equal identifier prior) seen then true
        else loop (identifier :: seen) rest
  in
  loop [] identifiers

let deliver project ~id ~author ~snapshot ~included ~next_draft ~next_title
    ~created_at =
  if
    List.exists
      (fun (delivery : delivery) -> Delivery_id.equal delivery.delivery_id id)
      project.deliveries
  then Error Duplicate_delivery
  else if not (nonempty_title next_title) then Error Empty_title
  else if
    List.exists
      (fun (draft : draft) -> Draft_id.equal draft.draft_id next_draft)
      project.drafts
  then Error Duplicate_draft
  else if (projection project).decisions <> [] then
    Error Delivery_has_open_decisions
  else if contains_duplicate included Revision_id.equal then
    Error Delivery_includes_duplicate_revision
  else
    let visible = (projection project).applied in
    let includes revision =
      List.exists (fun id -> Revision_id.equal id revision.revision) included
    in
    if
      not
        (List.for_all
           (fun revision_id ->
             List.exists
               (fun revision -> Revision_id.equal revision.revision revision_id)
               visible)
           included)
    then Error Delivery_includes_unknown_revision
    else
      let active = active_draft project in
      match active.shared_change with
      | None -> Error Delivery_requires_shared_active_draft
      | Some active_change -> (
          match find_change project active_change with
          | None ->
              invalid_arg "active draft refers to a missing V4 shared change"
          | Some change ->
              let active_revision = latest_revision change in
              let active_is_represented candidate =
                includes candidate.candidate_revision
                || List.exists
                     (fun resolution ->
                       includes resolution.replacement_revision
                       && List.exists
                            (fun suppressed ->
                              same_reference suppressed
                                (reference_of_candidate candidate))
                            resolution.suppressed_edits)
                     project.resolutions
              in
              if
                not
                  (List.for_all active_is_represented
                     (candidates_of_revision active_revision))
              then Error Delivery_omits_active_change
              else
                let represented_by_included_resolution candidate =
                  List.exists
                    (fun resolution ->
                      includes resolution.replacement_revision
                      && List.exists
                           (fun suppressed ->
                             same_reference suppressed
                               (reference_of_candidate candidate))
                           resolution.suppressed_edits)
                    project.resolutions
                in
                let consumed (change : shared_change) =
                  let latest = latest_revision change in
                  includes latest
                  || List.for_all represented_by_included_resolution
                       (candidates_of_revision latest)
                in
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
                let project = record_checkpoint project snapshot in
                Ok
                  {
                    project with
                    baseline = snapshot;
                    active = next_draft;
                    drafts =
                      next
                      :: List.map
                           (fun (draft : draft) ->
                             if Draft_id.equal draft.draft_id closed.draft_id
                             then closed
                             else draft)
                           project.drafts;
                    changes =
                      List.filter
                        (fun (change : shared_change) -> not (consumed change))
                        project.changes;
                    resolutions = [];
                    deliveries = delivery :: project.deliveries;
                  })

let retained checkpoints snapshot =
  List.exists
    (fun checkpoint ->
      Snapshot_id.equal checkpoint.checkpoint_snapshot snapshot)
    checkpoints

let pin project ~snapshot =
  if not (retained project.checkpoints snapshot) then Error Unknown_checkpoint
  else if List.exists (Snapshot_id.equal snapshot) project.pins then Ok project
  else Ok { project with pins = snapshot :: project.pins }

let unpin project ~snapshot =
  if not (List.exists (Snapshot_id.equal snapshot) project.pins) then
    Error Not_pinned
  else
    Ok
      {
        project with
        pins =
          List.filter
            (fun pinned -> not (Snapshot_id.equal pinned snapshot))
            project.pins;
      }

type protection_reason =
  | Baseline
  | Draft
  | Shared_revision
  | Delivery
  | Resolution
  | Open_decision
  | Pin
  | Restore_journal
  | Recent

let protection_reason_to_string = function
  | Baseline -> "baseline"
  | Draft -> "draft"
  | Shared_revision -> "share"
  | Delivery -> "delivery"
  | Resolution -> "resolution"
  | Open_decision -> "decision"
  | Pin -> "pin"
  | Restore_journal -> "restore-safety"
  | Recent -> "recent"

type compact_keep = {
  snapshot : Snapshot_id.t;
  reasons : protection_reason list;
}

type compact_result = {
  project : project;
  kept : compact_keep list;
  dropped : Snapshot_id.t list;
}

let default_keep_recent = 32

let reason_order = function
  | Baseline -> 0
  | Draft -> 1
  | Shared_revision -> 2
  | Delivery -> 3
  | Resolution -> 4
  | Open_decision -> 5
  | Pin -> 6
  | Restore_journal -> 7
  | Recent -> 8

let sort_reasons reasons =
  List.sort_uniq
    (fun left right -> Int.compare (reason_order left) (reason_order right))
    reasons

module Snapshot_map = Map.Make (struct
  type t = Snapshot_id.t

  let compare = Snapshot_id.compare
end)

let add_reason table snapshot reason =
  Snapshot_map.update snapshot
    (function
      | None -> Some [ reason ]
      | Some reasons ->
          if List.exists (fun existing -> existing = reason) reasons then
            Some reasons
          else Some (reason :: reasons))
    table

let add_revision_snapshots table revision reason =
  add_reason
    (add_reason table revision.base_snapshot reason)
    revision.result_snapshot reason

let named_protection_table project journal_snapshots =
  let table = add_reason Snapshot_map.empty project.baseline Baseline in
  let table =
    List.fold_left
      (fun table (draft : draft) ->
        add_reason table draft.latest_checkpoint Draft)
      table project.drafts
  in
  let table =
    List.fold_left
      (fun table (change : shared_change) ->
        List.fold_left
          (fun table revision ->
            add_revision_snapshots table revision Shared_revision)
          table change.revisions)
      table project.changes
  in
  let table =
    List.fold_left
      (fun table (delivery : delivery) ->
        add_reason table delivery.delivery_snapshot Delivery)
      table project.deliveries
  in
  let table =
    List.fold_left
      (fun table (resolution : resolution) ->
        add_revision_snapshots table resolution.replacement_revision Resolution)
      table project.resolutions
  in
  let table =
    List.fold_left
      (fun table (decision : decision) ->
        List.fold_left
          (fun table candidate ->
            add_revision_snapshots table candidate.candidate_revision
              Open_decision)
          table decision.candidates)
      table (projection project).decisions
  in
  let table =
    List.fold_left
      (fun table snapshot -> add_reason table snapshot Pin)
      table project.pins
  in
  List.fold_left
    (fun table snapshot -> add_reason table snapshot Restore_journal)
    table journal_snapshots

let compact project ~keep_recent ~journal_snapshots =
  if keep_recent < 0 then Error Invalid_keep_recent
  else
    let protected = named_protection_table project journal_snapshots in
    let kept_rev, dropped_rev, _remaining_recent =
      List.fold_left
        (fun (kept, dropped, remaining_recent) checkpoint ->
          let snapshot = checkpoint.checkpoint_snapshot in
          match Snapshot_map.find_opt snapshot protected with
          | Some reasons ->
              ( { snapshot; reasons = sort_reasons reasons } :: kept,
                dropped,
                remaining_recent )
          | None ->
              if remaining_recent > 0 then
                ( { snapshot; reasons = [ Recent ] } :: kept,
                  dropped,
                  remaining_recent - 1 )
              else (kept, snapshot :: dropped, remaining_recent))
        ([], [], keep_recent) project.checkpoints
    in
    let kept = List.rev kept_rev in
    let dropped = List.rev dropped_rev in
    let project =
      {
        project with
        checkpoints =
          List.map (fun keep -> { checkpoint_snapshot = keep.snapshot }) kept;
      }
    in
    match import (export project) with
    | Error error -> Error error
    | Ok project -> Ok { project; kept; dropped }
