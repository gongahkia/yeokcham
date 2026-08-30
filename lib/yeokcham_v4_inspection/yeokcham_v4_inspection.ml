module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

type state = {
  project : Model.project;
  signed_revisions : Trust.signed_revision list;
  authority : Trust.authority option;
  review_publications : string list;
}

type detail = Full of string | Text of string

let state ~project ~signed_revisions ~authority ~review_publications =
  {
    project;
    signed_revisions;
    authority;
    review_publications = List.sort_uniq String.compare review_publications;
  }

let has_authority state = Option.is_some state.authority
let normalize_width width = max 40 width
let quote value = Printf.sprintf "%S" value
let full value = Full value
let text value = Text value
let detail_text = function Full value | Text value -> value

let rec trim_left value offset =
  if offset < String.length value && value.[offset] = ' ' then
    trim_left value (offset + 1)
  else offset

let last_space_before value limit =
  let rec loop index found =
    if index >= limit then found
    else
      let found = if value.[index] = ' ' then Some index else found in
      loop (index + 1) found
  in
  loop 0 None

let wrap_text ~width ~indent value =
  let width = normalize_width width in
  let continuation = indent ^ "  " in
  let rec loop prefix offset =
    let remaining = String.length value - offset in
    let available = max 1 (width - String.length prefix) in
    if remaining <= available then
      [ prefix ^ String.sub value offset remaining ]
    else
      let limit = offset + available in
      match last_space_before value limit with
      | Some split when split > offset ->
          let segment = String.sub value offset (split - offset) in
          let next = trim_left value (split + 1) in
          (prefix ^ segment) :: loop continuation next
      | Some _ | None ->
          let segment = String.sub value offset available in
          (prefix ^ segment) :: loop continuation (offset + available)
  in
  loop indent 0

let render_block ~width primary details =
  let width = normalize_width width in
  let compact =
    match details with
    | [] -> primary
    | _ -> primary ^ " " ^ String.concat " " (List.map detail_text details)
  in
  let lines =
    if String.length compact <= width then [ compact ]
    else
      primary
      :: List.concat_map
           (function
             | Full value -> [ "  " ^ value ]
             | Text value -> wrap_text ~width ~indent:"  " value)
           details
  in
  String.concat "\n" lines ^ "\n"

let string_of_change change = Model.Change_id.to_string change
let string_of_revision revision = Model.Revision_id.to_string revision
let string_of_decision decision = Model.Decision_id.to_string decision
let string_of_delivery delivery = Model.Delivery_id.to_string delivery
let string_of_device device = Model.Device_id.to_string device
let string_of_snapshot snapshot = Model.Snapshot_id.to_string snapshot

let decision_kind = function
  | Model.Stale_base -> "stale-base"
  | Model.Edit_overlap -> "edit-overlap"

let role = function
  | Trust.Member -> "member"
  | Trust.Administrator -> "administrator"

let username_details project device =
  match Model.username_for_device project ~device with
  | None -> [ text "display-username unavailable" ]
  | Some username ->
      [ text ("display-username " ^ quote (Model.Username.to_string username)) ]

let revision_details project (revision : Model.change_revision) =
  let parent =
    match revision.Model.parent with
    | None -> full "parent none"
    | Some parent -> full ("parent " ^ string_of_revision parent)
  in
  [
    full ("change " ^ string_of_change revision.Model.change);
    parent;
    full ("author-device " ^ string_of_device revision.Model.revision_author);
  ]
  @ username_details project revision.Model.revision_author
  @ [
      full ("base-snapshot " ^ string_of_snapshot revision.Model.base_snapshot);
      full
        ("result-snapshot " ^ string_of_snapshot revision.Model.result_snapshot);
    ]

let edit_kind = function
  | Model.Whole_path -> "whole-path"
  | Model.Text span ->
      Printf.sprintf "text[%d,%d)" span.Model.start_byte span.Model.end_byte

let edit_detail index (edit : Model.edit) =
  text
    (Printf.sprintf "edit %d path %s %s" index
       (quote (Model.Path.to_string edit.Model.edit_path))
       (edit_kind edit.Model.edit_kind))

let shared_revisions project =
  Model.shared_changes project
  |> List.concat_map (fun change ->
      List.map
        (fun revision -> (revision, change.Model.withdrawn))
        change.Model.revisions)
  |> List.sort (fun (left, _) (right, _) ->
      String.compare
        (string_of_revision left.Model.revision)
        (string_of_revision right.Model.revision))

let decision_candidates (decision : Model.decision) =
  decision.Model.candidates
  |> List.sort (fun left right ->
      let revision_order =
        String.compare
          (string_of_revision left.Model.candidate_revision.Model.revision)
          (string_of_revision right.Model.candidate_revision.Model.revision)
      in
      if revision_order <> 0 then revision_order
      else
        Int.compare left.Model.candidate_edit_index
          right.Model.candidate_edit_index)

let signed_resolutions state =
  state.signed_revisions
  |> List.filter_map (fun signed ->
      match Trust.signed_revision_resolution signed with
      | None -> None
      | Some decision -> Some (signed, decision))
  |> List.sort (fun (left, _) (right, _) ->
      String.compare
        (string_of_revision (Trust.signed_revision_id left))
        (string_of_revision (Trust.signed_revision_id right)))

let deliveries project =
  Model.deliveries project
  |> List.sort (fun left right ->
      let created =
        Int64.compare left.Model.created_at right.Model.created_at
      in
      if created <> 0 then created
      else
        String.compare
          (string_of_delivery left.Model.delivery_id)
          (string_of_delivery right.Model.delivery_id))

let has_work state =
  shared_revisions state.project <> []
  || (Model.projection state.project).Model.decisions <> []
  || signed_resolutions state <> []
  || deliveries state.project <> []
  || state.review_publications <> []

let render_log ~width state =
  if not (has_work state) then "work empty\n"
  else
    let shared =
      shared_revisions state.project
      |> List.map (fun (revision, withdrawn) ->
          let status =
            if withdrawn then text "state withdrawn" else text "state current"
          in
          let edits =
            revision.Model.edits
            |> List.mapi (fun index edit -> edit_detail index edit)
          in
          render_block ~width
            ("shared-revision " ^ string_of_revision revision.Model.revision)
            ((status :: revision_details state.project revision) @ edits))
      |> String.concat ""
    in
    let decisions =
      (Model.projection state.project).Model.decisions
      |> List.sort (fun left right ->
          String.compare
            (string_of_decision left.Model.decision_id)
            (string_of_decision right.Model.decision_id))
      |> List.map (fun decision ->
          let paths =
            decision.Model.decision_paths
            |> List.sort Model.Path.compare
            |> List.map (fun path ->
                text ("path " ^ quote (Model.Path.to_string path)))
          in
          let candidates =
            decision_candidates decision
            |> List.map (fun candidate ->
                let revision = candidate.Model.candidate_revision in
                text
                  (Printf.sprintf "candidate %s edit %d path %s %s"
                     (string_of_revision revision.Model.revision)
                     candidate.Model.candidate_edit_index
                     (quote
                        (Model.Path.to_string
                           candidate.Model.candidate_edit.Model.edit_path))
                     (edit_kind candidate.Model.candidate_edit.Model.edit_kind)))
          in
          render_block ~width
            ("open-decision " ^ string_of_decision decision.Model.decision_id)
            (text ("kind " ^ decision_kind decision.Model.decision_kind)
             :: paths
            @ candidates))
      |> String.concat ""
    in
    let resolutions =
      signed_resolutions state
      |> List.map (fun (signed, decision) ->
          let revision = Trust.signed_revision_value signed in
          render_block ~width
            ("signed-resolution " ^ string_of_revision revision.Model.revision)
            (full ("decision " ^ string_of_decision decision)
            :: revision_details state.project revision))
      |> String.concat ""
    in
    let deliveries =
      deliveries state.project
      |> List.map (fun delivery ->
          let included =
            delivery.Model.included
            |> List.sort Model.Revision_id.compare
            |> List.map (fun revision ->
                full ("includes " ^ string_of_revision revision))
          in
          render_block ~width
            ("delivery " ^ string_of_delivery delivery.Model.delivery_id)
            (full
               ("author-device "
               ^ string_of_device delivery.Model.delivery_author)
             :: username_details state.project delivery.Model.delivery_author
            @ [
                text ("created-at " ^ Int64.to_string delivery.Model.created_at);
                full
                  ("snapshot "
                  ^ string_of_snapshot delivery.Model.delivery_snapshot);
              ]
            @ included))
      |> String.concat ""
    in
    let reviews =
      state.review_publications
      |> List.map (fun publication ->
          render_block ~width ("review-pending publication " ^ publication) [])
      |> String.concat ""
    in
    shared ^ decisions ^ resolutions ^ deliveries ^ reviews

let render_work_graph ~width state =
  if not (has_work state) then "work empty\n"
  else
    let shared =
      shared_revisions state.project
      |> List.map (fun (revision, withdrawn) ->
          let parent =
            match revision.Model.parent with
            | None -> []
            | Some value ->
                [
                  full
                    ("+-- parent --> [revision " ^ string_of_revision value
                   ^ "]");
                ]
          in
          let state_detail =
            if withdrawn then text "state withdrawn" else text "state current"
          in
          render_block ~width
            ("[revision " ^ string_of_revision revision.Model.revision ^ "]")
            ((state_detail :: parent) @ revision_details state.project revision))
      |> String.concat ""
    in
    let decisions =
      (Model.projection state.project).Model.decisions
      |> List.sort (fun left right ->
          String.compare
            (string_of_decision left.Model.decision_id)
            (string_of_decision right.Model.decision_id))
      |> List.map (fun decision ->
          let paths =
            decision.Model.decision_paths
            |> List.sort Model.Path.compare
            |> List.map (fun path ->
                text ("path " ^ quote (Model.Path.to_string path)))
          in
          let candidates =
            decision_candidates decision
            |> List.map (fun candidate ->
                full
                  (Printf.sprintf "+-- candidate edit %d --> [revision %s]"
                     candidate.Model.candidate_edit_index
                     (string_of_revision
                        candidate.Model.candidate_revision.Model.revision)))
          in
          render_block ~width
            ("[open-decision "
            ^ string_of_decision decision.Model.decision_id
            ^ "]")
            (text ("kind " ^ decision_kind decision.Model.decision_kind)
             :: paths
            @ candidates))
      |> String.concat ""
    in
    let resolutions =
      signed_resolutions state
      |> List.map (fun (signed, decision) ->
          let revision = Trust.signed_revision_value signed in
          render_block ~width
            ("[signed-resolution "
            ^ string_of_revision revision.Model.revision
            ^ "]")
            [
              full
                ("+-- resolves --> [decision "
                ^ string_of_decision decision
                ^ "]");
            ])
      |> String.concat ""
    in
    let deliveries =
      deliveries state.project
      |> List.map (fun delivery ->
          let included =
            delivery.Model.included
            |> List.sort Model.Revision_id.compare
            |> List.map (fun revision ->
                full
                  ("+-- includes --> [revision "
                  ^ string_of_revision revision
                  ^ "]"))
          in
          render_block ~width
            ("[delivery " ^ string_of_delivery delivery.Model.delivery_id ^ "]")
            (text "milestone only" :: included))
      |> String.concat ""
    in
    let reviews =
      state.review_publications
      |> List.map (fun publication ->
          render_block ~width
            ("[review-pending publication " ^ publication ^ "]")
            [])
      |> String.concat ""
    in
    shared ^ decisions ^ resolutions ^ deliveries ^ reviews

let render_authority_graph ~width state =
  match state.authority with
  | None -> None
  | Some authority ->
      let heads = Trust.authority_heads authority |> List.sort String.compare in
      let is_head epoch = List.mem (Trust.epoch_id epoch) heads in
      let epochs =
        Trust.authority_epochs authority
        |> List.sort (fun left right ->
            String.compare (Trust.epoch_id left) (Trust.epoch_id right))
      in
      let epoch_output =
        epochs
        |> List.map (fun epoch ->
            let parents =
              Trust.epoch_parents epoch |> List.sort String.compare
              |> List.map (fun parent ->
                  full ("+-- parent --> [epoch " ^ parent ^ "]"))
            in
            let revoked =
              Trust.epoch_revoked epoch
              |> List.sort Model.Device_id.compare
              |> List.map (fun device ->
                  full
                    ("+-- revokes --> [device " ^ string_of_device device ^ "]"))
            in
            let markers =
              (if is_head epoch then [ text "current-head yes" ] else [])
              @
              if List.length (Trust.epoch_parents epoch) > 1 then
                [ text "reconciliation yes" ]
              else []
            in
            render_block ~width
              ("[epoch " ^ Trust.epoch_id epoch ^ "]")
              (markers @ parents @ revoked))
        |> String.concat ""
      in
      let certificates =
        Trust.certificates (Trust.authority_membership authority)
        |> List.sort (fun left right ->
            String.compare
              (Trust.certificate_id left)
              (Trust.certificate_id right))
        |> List.map (fun certificate ->
            let device =
              Trust.certificate_subject certificate |> Trust.device_id
            in
            let head_status =
              heads
              |> List.map (fun head ->
                  let state =
                    if
                      Trust.authority_device_active authority ~epoch:head
                        (Trust.certificate_subject certificate)
                    then "active"
                    else "not-active"
                  in
                  text ("current-head " ^ head ^ " " ^ state))
            in
            let issuer =
              match Trust.certificate_issuer certificate with
              | None -> text "issuer root"
              | Some value -> full ("issuer-certificate " ^ value)
            in
            render_block ~width
              ("[certificate " ^ Trust.certificate_id certificate ^ "]")
              (full ("device " ^ string_of_device device)
              :: text ("role " ^ role (Trust.certificate_role certificate))
              :: issuer :: head_status))
        |> String.concat ""
      in
      Some (epoch_output ^ certificates)
