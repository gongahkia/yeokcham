module Core = Yeokcham_v1_model.Core
module Model = Yeokcham_v1_model
module Plan = Yeokcham_v1_integration
module Native = Native_integration
module Store = Yeokcham_v1_store
module Local = Store.Local
module Raw = Yeokcham_store
module Snapshot = Yeokcham_snapshot
module Composition = Yeokcham_v1_composition
module Trust = Yeokcham_v1_trust
module Record = Yeokcham_v1_record.Core
module E = Yeokcham_encoding

[@@@warning "-42"]

let ( let* ) = Result.bind
let metadata r = Result.map_error (fun s -> Native.Metadata s) r
let plan_error r = Result.map_error (fun e -> Native.Plan_error e) r
let content r = Result.map_error (fun e -> Native.Plan_error (Plan.Content e)) r

let model r =
  Result.map_error
    (fun e -> Native.Plan_error (Plan.Invalid (Core.error_to_string e)))
    r

let invalid s = Error (Native.Plan_error (Plan.Invalid s))
let choice s = Error (Native.Plan_error (Plan.Choice s))

let graph r =
  Result.map_error
    (function
      | Composition.Graph.Content_error e -> Native.Plan_error (Plan.Content e)
      | Composition.Graph.Invalid_graph s ->
          Native.Plan_error (Plan.Integrity s)
      | Composition.Graph.Decision s -> Native.Plan_error (Plan.Choice s))
    r

type version = {
  version_id : string;
  name : string;
  snapshot : Core.Object_id.t;
  entry : Composition.entry option;
  preview_escaped : string option;
  preview_truncated : bool;
}

type conflict = {
  conflict_id : Core.Digest.t;
  source_plan : Core.Plan_id.t;
  path : string list;
  private_workspace : bool;
  versions : version list;
}

type inspection = { plans : Plan.t list; conflicts : conflict list }
type choice = Use of string | File of string | Defer

type outcome = {
  source : Core.Plan_id.t;
  conflict : Core.Digest.t;
  prepared : Plan.t;
  deferred : bool;
  public_resolution : Core.Record_id.t option;
  retained : bool;
  retention_error : string option;
}

let traverse f values =
  List.fold_left
    (fun acc value ->
      let* values = acc in
      let* value = f value in
      Ok (value :: values))
    (Ok []) values
  |> Result.map List.rev

let local loaded =
  loaded.Store.local
  |> Option.to_result
       ~none:
         (Native.Metadata
            "conflict inspection requires authenticated local state")

let reload repository =
  Store.load repository
  |> Result.map_error (fun e -> Native.Metadata (Store.error_to_string e))

let observe ~root store =
  let* safety, _, observation =
    Snapshot.Observation.scan ~root ~store
    |> Result.map_error (fun e -> Native.Capture_error e)
  in
  let* observed =
    Snapshot.Snapshot.stored_object_id safety
    |> Raw.Stored_object_id.to_hex |> Model.Snapshot_id.of_string
    |> Result.map_error (fun e -> Native.Metadata (Model.error_to_string e))
  in
  Ok (safety, observed, observation)

let revalidate store loaded observed observation plan =
  Plan.revalidate ~store ~loaded ~observed ~observation plan |> plan_error

let comparison store loaded plan private_workspace =
  if private_workspace then
    Composition.load store (Plan.known_present plan) |> content
  else
    let* local = local loaded in
    let* base =
      Composition.Graph.common_base (Local.pool local)
        (Plan.request plan).Core.accepted_heads
      |> graph
    in
    let* value = Composition.Graph.accepted (Local.pool local) base |> graph in
    Composition.load store value.Core.result_snapshot |> content

let comparison_snapshot loaded plan =
  let* local = local loaded in
  let* base =
    Composition.Graph.common_base (Local.pool local)
      (Plan.request plan).Core.accepted_heads
    |> graph
  in
  let* value = Composition.Graph.accepted (Local.pool local) base |> graph in
  Ok value.Core.result_snapshot

let version store path version_id name snapshot =
  let* tree = Composition.load store snapshot |> content in
  let entry = List.assoc_opt path (Composition.entries tree) in
  let* preview_escaped, preview_truncated =
    match entry with
    | None | Some Composition.Directory -> Ok (None, false)
    | Some (Composition.File { content; _ }) ->
        let* bytes =
          Snapshot.Content.load_bounded store ~max_bytes:8192 content
          |> Result.map_error (fun e -> Native.Capture_error e)
        in
        Ok (Option.map String.escaped bytes, Option.is_none bytes)
  in
  Ok { version_id; name; snapshot; entry; preview_escaped; preview_truncated }

let conflict_identity plan (conflict : Core.conflict) =
  let array values =
    E.array values
    |> Result.map_error (fun e ->
        Native.Metadata (E.construction_error_to_string e))
  in
  let* path = array (List.map E.bytes conflict.Core.path) in
  let* value =
    array
      [
        E.bytes (Core.Plan_id.to_raw (Plan.id plan));
        path;
        E.bool conflict.Core.private_workspace;
      ]
  in
  Core.Digest.of_raw
    (Yeokcham_hash.Sha256.digest_string
       ("yeokcham/integration-conflict/v1\000" ^ E.encode value)
    |> Yeokcham_hash.Sha256.to_raw_string)
  |> model

let recorded_decisions store loaded plan path =
  let* local = local loaded in
  let request = Plan.request plan in
  let* decisions =
    Core.records (Local.pool local)
    |> traverse (fun (id, body) ->
        match body.Core.payload with
        | Core.Resolution_revision value
          when Core.Branch_id.equal value.Core.branch request.Core.branch
               && value.Core.accepted_heads = request.Core.accepted_heads
               && value.Core.chosen_revisions = request.Core.selected_revisions
          ->
            let* scope =
              Composition.Scope.load store value.Core.decision_scope_root
              |> content
            in
            Ok (if scope = [ path ] then Some (id, value) else None)
        | Core.Resolution_revision _ | Core.Shared_revision _
        | Core.Accepted_version _ | Core.Branch_event _ ->
            Ok None)
  in
  Ok (List.filter_map Fun.id decisions)

let conflicts store loaded plan =
  match Plan.readiness plan with
  | Plan.Ready _ | Plan.Decision _ -> Ok []
  | Plan.Conflicted values ->
      let* local = local loaded in
      traverse
        (fun (value : Core.conflict) ->
          let path = value.Core.path in
          let* base =
            if value.Core.private_workspace then Ok (Plan.known_present plan)
            else comparison_snapshot loaded plan
          in
          let* comparison = version store path "comparison" "comparison" base in
          let* versions =
            if value.Core.private_workspace then
              let* accepted =
                Plan.accepted_snapshot plan
                |> Option.to_result
                     ~none:
                       (Native.Metadata
                          "workspace conflict lacks its accepted proposal")
              in
              let* accepted =
                version store path "accepted" "accepted shared result" accepted
              in
              let* working =
                version store path "working" "private working contents"
                  (Plan.request plan).Core.workspace.Core.observed_snapshot
              in
              Ok [ comparison; accepted; working ]
            else
              let* variants =
                Core.resolution_variants (Local.pool local)
                  ~accepted_heads:(Plan.request plan).Core.accepted_heads
                  ~chosen_revisions:(Plan.request plan).Core.selected_revisions
                |> model
              in
              let* versions =
                variants
                |> traverse (fun id ->
                    let* prefix, snapshot =
                      match Core.find (Local.pool local) id with
                      | Some { Core.payload = Core.Shared_revision v; _ } ->
                          Ok ("revision", v.Core.result_snapshot)
                      | Some { Core.payload = Core.Accepted_version v; _ } ->
                          Ok ("accepted", v.Core.result_snapshot)
                      | None
                      | Some
                          {
                            Core.payload =
                              Core.Branch_event _ | Core.Resolution_revision _;
                            _;
                          } ->
                          invalid "conflict variant has the wrong record kind"
                    in
                    let name = prefix ^ ":" ^ Core.Record_id.to_hex id in
                    version store path name name snapshot)
              in
              let* recorded = recorded_decisions store loaded plan path in
              let* recorded =
                recorded
                |> traverse (fun (id, value) ->
                    version store path
                      ("resolution:" ^ Core.Record_id.to_hex id)
                      "recorded shared decision" value.Core.replacement_snapshot)
              in
              Ok ((comparison :: recorded) @ versions)
          in
          let* conflict_id = conflict_identity plan value in
          Ok
            {
              conflict_id;
              source_plan = Plan.id plan;
              path;
              private_workspace = value.Core.private_workspace;
              versions;
            })
        values

let decisions_subset left right =
  List.for_all
    (fun id ->
      List.exists (Core.Record_id.equal id)
        (Plan.request right).Core.resolution_ids)
    (Plan.request left).Core.resolution_ids
  && List.for_all
       (fun value -> List.mem value (Plan.workspace_decisions right))
       (Plan.workspace_decisions left)

let[@warning "-4"] current_plans store loaded observed observation plans =
  let* stamp = Plan.observation_digest observation |> plan_error in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | plan :: rest -> (
        if not (Core.Digest.equal stamp (Plan.plan_observation plan)) then
          loop acc rest
        else
          match revalidate store loaded observed observation plan with
          | Ok plan -> loop (plan :: acc) rest
          | Error (Native.Plan_error (Plan.Stale _)) -> loop acc rest
          | Error e -> Error e)
  in
  let* plans = loop [] plans in
  Ok
    (List.filter
       (fun plan ->
         (not (Plan.no_op plan))
         && not
              (List.exists
                 (fun other ->
                   Core.Digest.equal
                     (Plan.context_identity plan)
                     (Plan.context_identity other)
                   && decisions_subset plan other
                   && not (decisions_subset other plan))
                 plans))
       plans)

let eligible loaded =
  let* local = local loaded in
  let* branch =
    Local.branches local
    |> List.find_opt (fun row ->
        Core.Branch_id.equal row.Core.branch_id
          (Local.selected local).Local.branch)
    |> Option.to_result ~none:(Native.Metadata "selected branch is unavailable")
  in
  let* represented =
    Composition.Graph.represented (Local.pool local) branch.Core.accepted_heads
    |> graph
  in
  let changes =
    Core.records (Local.pool local)
    |> List.filter_map (fun (_, body) ->
        match body.Core.payload with
        | Core.Shared_revision value -> Some value.Core.change
        | Core.Accepted_version _ | Core.Branch_event _
        | Core.Resolution_revision _ ->
            None)
    |> List.sort_uniq Core.Change_id.compare
  in
  let revisions =
    List.concat_map
      (fun change ->
        let heads = Core.change_heads (Local.pool local) change in
        if
          List.for_all
            (fun id -> List.exists (Core.Record_id.equal id) represented)
            heads
        then []
        else heads)
      changes
    |> List.sort_uniq Core.Record_id.compare
  in
  Ok revisions

let inspect ~root ~plan =
  Native.with_writer ~root (fun repository ->
      let* loaded = reload repository in
      let* () = Native.require_idle ~root loaded in
      let store = Store.underlying_store repository in
      let* _, observed, observation = observe ~root store in
      let* plans =
        match plan with
        | Some id ->
            let* plan = Plan.load ~store ~loaded id |> plan_error in
            let* plan = revalidate store loaded observed observation plan in
            Ok [ plan ]
        | None ->
            let* plans = Plan.scan ~store ~loaded |> plan_error in
            let* plans =
              current_plans store loaded observed observation plans
            in
            if plans <> [] then Ok plans
            else
              let* selected_revisions = eligible loaded in
              let* plan =
                Plan.prepare ~store ~loaded ~observed ~observation
                  ~selected_revisions ~reconcile_heads:None
                |> plan_error
              in
              let* () = Plan.retain ~store plan |> plan_error in
              Ok [ plan ]
      in
      let* conflicts = traverse (conflicts store loaded) plans in
      Ok { plans; conflicts = List.concat conflicts })

let find_conflict store loaded observed observation requested identity =
  let* plans =
    match requested with
    | Some id ->
        let* plan = Plan.load ~store ~loaded id |> plan_error in
        Ok [ plan ]
    | None -> Plan.scan ~store ~loaded |> plan_error
  in
  let* matches =
    traverse
      (fun plan ->
        let* matches = conflicts store loaded plan in
        Ok
          (List.filter_map
             (fun conflict ->
               if Core.Digest.equal conflict.conflict_id identity then
                 Some (plan, conflict)
               else None)
             matches))
      plans
  in
  match List.concat matches with
  | [ (plan, conflict) ] ->
      let* plan = revalidate store loaded observed observation plan in
      Ok (plan, conflict)
  | [] ->
      invalid
        "unknown conflict identity; run conflicts for exact current plan and \
         version identities"
  | _ :: _ -> choice "conflict identity is ambiguous; name its exact --plan"

let reconcile plan =
  let request = Plan.request plan in
  if
    List.length request.Core.accepted_heads > 1
    || List.length (Plan.event_heads plan) > 1
  then
    Some
      (List.sort_uniq Core.Record_id.compare
         (request.Core.accepted_heads @ Plan.event_heads plan))
  else None

let replacement store loaded plan conflict selection =
  let* base = comparison store loaded plan conflict.private_workspace in
  match selection with
  | Defer -> invalid "deferred conflicts have no replacement"
  | Use name ->
      let* selected =
        match
          List.filter
            (fun value -> value.version_id = name || value.name = name)
            conflict.versions
        with
        | [ value ] -> Ok value
        | [] ->
            invalid
              "unknown version; choose an exact version listed by conflicts"
        | _ :: _ ->
            choice
              "version name is ambiguous; choose the exact version identity"
      in
      let* tree = Composition.load store selected.snapshot |> content in
      let* tree =
        Composition.replace_subtree ~base ~path:conflict.path ~replacement:tree
        |> content
      in
      let* identity = Composition.store store tree |> content in
      Ok (identity, None)
  | File path ->
      let path =
        if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
        else path
      in
      let* captured =
        Snapshot.capture_regular_file ~store ~path
        |> Result.map_error (fun e -> Native.Capture_error e)
      in
      let entry =
        Composition.File
          {
            mode = captured.Snapshot.captured_mode;
            content = captured.Snapshot.captured_content;
          }
      in
      let rec ancestors path =
        match List.rev path with
        | [] | [ _ ] -> []
        | _ :: rest ->
            let parent = List.rev rest in
            (parent, Composition.Directory) :: ancestors parent
      in
      let* selected =
        Composition.tree ((conflict.path, entry) :: ancestors conflict.path)
        |> content
      in
      let* tree =
        Composition.replace_subtree ~base ~path:conflict.path
          ~replacement:selected
        |> content
      in
      let* identity = Composition.store store tree |> content in
      Ok (identity, Some (path, captured))

let resolution_body store loaded plan conflict replacement =
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result
         ~none:(Native.Metadata "resolution needs verified collaboration")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result
         ~none:(Native.Metadata "resolution needs current authority")
  in
  let* local = local loaded in
  let request = Plan.request plan in
  let* superseded_variants =
    Core.resolution_variants (Local.pool local)
      ~accepted_heads:request.Core.accepted_heads
      ~chosen_revisions:request.Core.selected_revisions
    |> model
  in
  let* decision_scope_root =
    Composition.Scope.store store [ conflict.path ] |> content
  in
  let* comparison_snapshot = comparison_snapshot loaded plan in
  let* resolution =
    Core.make_resolution_revision ~branch:request.Core.branch
      ~accepted_heads:request.Core.accepted_heads
      ~chosen_revisions:request.Core.selected_revisions ~superseded_variants
      ~decision_scope_root ~comparison_snapshot
      ~replacement_snapshot:replacement
    |> model
  in
  let* author_certificate =
    Core.Digest.of_hex (Store.local_certificate collaboration) |> model
  in
  let* context =
    Core.make_context ~repository:request.Core.repository ~author_certificate
      ~authority_heads:request.Core.authority_heads ~display_time:None
    |> model
  in
  Ok
    ( authority,
      Core.make_body ~context ~payload:(Core.Resolution_revision resolution) )

let existing_resolution loaded body =
  let* local = local loaded in
  match
    Core.records (Local.pool local)
    |> List.filter_map (fun (id, value) ->
        if value = body then Some id else None)
  with
  | [] -> Ok None
  | [ id ] -> Ok (Some id)
  | _ :: _ ->
      choice
        "identical resolution bodies have multiple signed identities; select \
         the exact retained proposal"

let fresh_plan ~root store loaded safety observed observation source
    ~resolutions ~decisions =
  let* plan =
    Plan.prepare_decided ~workspace_decisions:decisions
      ~resolution_ids:resolutions ~store ~loaded ~observed ~observation
      ~selected_revisions:(Plan.request source).Core.selected_revisions
      ~reconcile_heads:(reconcile source)
    |> plan_error
  in
  let* () = Native.check_plan ~root ~store ~safety ~observation plan in
  Ok plan

type pending =
  | Done of outcome
  | Sign of
      Plan.t
      * conflict
      * Core.Object_id.t
      * (string * Snapshot.captured_file) option
      * Trust.authority
      * Core.body

let resolve ~root ~plan ~conflict:identity ~choice:selection ~signer =
  let* pending =
    Native.with_writer ~root (fun repository ->
        let* loaded = reload repository in
        let* () = Native.require_idle ~root loaded in
        let store = Store.underlying_store repository in
        let* safety, observed, observation = observe ~root store in
        let* source, conflict =
          find_conflict store loaded observed observation plan identity
        in
        let result prepared deferred public_resolution retained retention_error
            =
          {
            source = Plan.id source;
            conflict = identity;
            prepared;
            deferred;
            public_resolution;
            retained;
            retention_error;
          }
        in
        match selection with
        | Defer -> Ok (Done (result source true None true None))
        | Use name
          when String.starts_with ~prefix:"resolution:" name
               && not conflict.private_workspace ->
            let* id =
              Core.Record_id.of_hex
                (String.sub name 11 (String.length name - 11))
              |> model
            in
            let* recorded =
              recorded_decisions store loaded source conflict.path
            in
            let* () =
              if
                List.exists
                  (fun (record, _) -> Core.Record_id.equal record id)
                  recorded
              then Ok ()
              else
                invalid
                  "recorded resolution does not match this exact conflict; \
                   inspect conflicts for current versions"
            in
            let* prepared =
              fresh_plan ~root store loaded safety observed observation source
                ~resolutions:(id :: (Plan.request source).Core.resolution_ids)
                ~decisions:(Plan.workspace_decisions source)
            in
            let* () = Plan.retain ~store prepared |> plan_error in
            Ok (Done (result prepared false (Some id) true None))
        | Use _ | File _ ->
            let* replacement, captured =
              replacement store loaded source conflict selection
            in
            if conflict.private_workspace then
              let* decision =
                Plan.make_workspace_decision ~path:conflict.path
                  ~replacement_snapshot:replacement
                |> plan_error
              in
              let* prepared =
                fresh_plan ~root store loaded safety observed observation source
                  ~resolutions:(Plan.request source).Core.resolution_ids
                  ~decisions:(decision :: Plan.workspace_decisions source)
              in
              let* () = Plan.retain ~store prepared |> plan_error in
              Ok (Done (result prepared false None true None))
            else
              let* authority, body =
                resolution_body store loaded source conflict replacement
              in
              Ok
                (Sign (source, conflict, replacement, captured, authority, body)))
  in
  match pending with
  | Done outcome -> Ok outcome
  | Sign (source, conflict, expected_replacement, captured, authority, body) ->
      let* repository =
        Store.open_repository ~root
        |> Result.map_error (fun e -> Native.Metadata (Store.error_to_string e))
      in
      let* loaded = reload repository in
      let* existing = existing_resolution loaded body in
      let* signed =
        match existing with
        | Some _ -> Ok None
        | None ->
            let* capability = signer () |> metadata in
            let* signed =
              Trust.Core.sign authority capability body
              |> Result.map_error (fun e ->
                  Native.Plan_error (Plan.Policy (Trust.Core.error_to_string e)))
            in
            Ok (Some signed)
      in
      Native.with_writer ~root (fun repository ->
          let* loaded = reload repository in
          let* () = Native.require_idle ~root loaded in
          let store = Store.underlying_store repository in
          let* safety, observed, observation = observe ~root store in
          let* source = revalidate store loaded observed observation source in
          let* () =
            match captured with
            | None -> Ok ()
            | Some (path, value) ->
                Snapshot.validate_captured_file ~path value
                |> Result.map_error (fun e -> Native.Capture_error e)
          in
          let* replacement, _ =
            replacement store loaded source conflict selection
          in
          let* () =
            if Core.Object_id.equal replacement expected_replacement then Ok ()
            else
              Error
                (Native.Plan_error
                   (Plan.Stale "resolution replacement changed while signing"))
          in
          let* current_authority, current_body =
            resolution_body store loaded source conflict replacement
          in
          let* () =
            if body = current_body then Ok ()
            else
              Error
                (Native.Plan_error
                   (Plan.Stale
                      "resolution authority or exact context changed while \
                       signing"))
          in
          let* local = local loaded in
          let* local, resolution =
            match existing with
            | Some id ->
                let* _ = existing_resolution loaded body in
                Ok (local, id)
            | None ->
                let signed = Option.get signed in
                let* identity =
                  Record.id signed
                  |> Result.map_error (fun e ->
                      Native.Metadata (Record.error_to_string e))
                in
                let* bytes =
                  Record.encode signed
                  |> Result.map_error (fun e ->
                      Native.Metadata (Record.error_to_string e))
                in
                let* envelope =
                  Yeokcham_envelope.decode bytes
                  |> Result.map_error (fun e ->
                      Native.Metadata
                        (Yeokcham_envelope.decode_error_to_string e))
                in
                let* stored =
                  Raw.put store envelope
                  |> Result.map_error (fun e ->
                      Native.Metadata (Raw.error_to_string e))
                in
                let* local =
                  Local.receive_records ~store ~authority:current_authority
                    ~records:[ (identity, stored) ]
                    local
                  |> Result.map_error (fun e ->
                      Native.Plan_error
                        (Plan.Integrity (Local.receive_error_to_string e)))
                in
                Ok (local, identity)
          in
          let candidate = { loaded with Store.local = Some local } in
          let* prepared =
            fresh_plan ~root store candidate safety observed observation source
              ~resolutions:
                (resolution :: (Plan.request source).Core.resolution_ids)
              ~decisions:(Plan.workspace_decisions source)
          in
          let* () =
            if existing <> None then Ok ()
            else
              let* collaboration =
                loaded.Store.collaboration
                |> Option.to_result
                     ~none:
                       (Native.Metadata "verified collaboration disappeared")
              in
              let* _ =
                Store.save_collaborative repository ~expected:loaded.Store.head
                  ~project:loaded.Store.project ~history:loaded.Store.history
                  ~collaboration ~local
                |> Result.map_error (fun e ->
                    Native.Metadata (Store.error_to_string e))
              in
              Ok ()
          in
          let retained, retention_error =
            match Plan.retain ~store prepared with
            | Ok () -> (true, None)
            | Error e -> (false, Some (Plan.error_to_string e))
          in
          Ok
            {
              source = Plan.id source;
              conflict = identity;
              prepared;
              deferred = false;
              public_resolution = Some resolution;
              retained;
              retention_error;
            })
