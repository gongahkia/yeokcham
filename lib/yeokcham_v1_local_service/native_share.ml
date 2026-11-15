module Core = Yeokcham_v1_model.Core
module Model = Yeokcham_v1_model
module Store = Yeokcham_v1_store
module Local = Store.Local
module History = Yeokcham_v1_undo
module Snapshot = Yeokcham_snapshot
module Composition = Yeokcham_v1_composition
module Trust = Yeokcham_v1_trust
module E = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

[@@@warning "-42"]

type error =
  | Invalid of string
  | Choice of string
  | Policy of string
  | Content of Composition.error
  | Metadata of string

let error_to_string = function
  | Invalid s | Choice s | Policy s | Metadata s -> s
  | Content e -> Composition.error_to_string e

let ( let* ) = Result.bind
let metadata r = Result.map_error (fun s -> Metadata s) r
let model r = r |> Result.map_error (fun e -> Metadata (Core.error_to_string e))
let content r = Result.map_error (fun e -> Content e) r

let array v =
  E.array v
  |> Result.map_error (fun e -> Invalid (E.construction_error_to_string e))

type result = {
  publication : Local.publication option;
  change : Core.Change_id.t option;
  revision : Core.Record_id.t option;
  title : string;
  source : Core.History_id.t;
  observed : Core.Object_id.t;
  base_snapshot : Core.Object_id.t;
  public_snapshot : Core.Object_id.t;
  contributed_paths : string list list;
  public_paths : string list list;
  captures_unsaved : bool;
  preview : bool;
  repeated : bool;
}

type prepared = {
  summary : result;
  project : Model.project;
  history : History.t;
  local : Local.t;
  collaboration : Store.collaboration;
  authority : Trust.authority;
  previous : Core.Record_id.t list;
  dependencies : Core.Record_id.t list;
  intent : Core.Digest.t;
}

let change_heads pool change =
  let heads = Core.change_heads pool change in
  Core.records pool
  |> List.filter_map (fun (id, body) ->
      match body.Core.payload with
      | Core.Shared_revision value
        when List.exists (Core.Record_id.equal id) heads ->
          Some (id, value)
      | Core.Shared_revision _ | Core.Accepted_version _ | Core.Branch_event _
        ->
          None)

let prepare ~store ~loaded ~observed ~observation ~paths ~update ~title =
  let* local =
    loaded.Store.local
    |> Option.to_result
         ~none:
           (Invalid "selected sharing requires authenticated local branch state")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result
         ~none:
           (Policy "selected sharing requires verified membership and authority")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result
         ~none:(Policy "selected sharing requires verified authority")
  in
  let* () =
    match Trust.authority_heads authority with
    | [ _ ] -> Ok ()
    | [] | _ :: _ ->
        Error
          (Choice
             "authority heads require explicit reconciliation before sharing")
  in
  let selected = Local.selected local in
  let* basis =
    Composition.Graph.accepted (Local.pool local) selected.Local.basis
    |> Result.map_error (fun e ->
        Metadata (Composition.Graph.error_to_string e))
  in
  let* base_snapshot, previous, dependencies, old_result =
    match update with
    | None -> Ok (basis.Core.result_snapshot, [], [], basis.Core.result_snapshot)
    | Some change -> (
        match change_heads (Local.pool local) change with
        | [] ->
            Error
              (Invalid "unknown change; inspect the shared change identities")
        | [ (id, version) ] ->
            Ok
              ( version.Core.base_snapshot,
                [ id ],
                version.Core.dependencies,
                version.Core.result_snapshot )
        | _ :: _ ->
            Error
              (Choice
                 "change has concurrent revisions; choose/reconcile them \
                  explicitly before updating"))
  in
  let* base = Composition.load store base_snapshot |> content in
  let* prior = Composition.load store old_result |> content in
  let* observed_id =
    Core.Object_id.of_hex (Model.Snapshot_id.to_string observed) |> model
  in
  let* observed_tree = Composition.load store observed_id |> content in
  let paths = List.sort_uniq Stdlib.compare paths in
  let directory path =
    match
      ( List.assoc_opt path (Composition.entries observed_tree),
        List.assoc_opt path (Composition.entries prior) )
    with
    | Some Composition.Directory, _ | _, Some Composition.Directory -> true
    | None, None | Some (Composition.File _), _ | _, Some (Composition.File _)
      ->
        false
  in
  let ignored path =
    Snapshot.Observation.ignored observation ~path ~directory:(directory path)
  in
  let* () =
    match List.find_opt ignored paths with
    | None -> Ok ()
    | Some path ->
        Error
          (Invalid
             ("selected path is excluded by captured native rules: "
             ^ String.escaped (String.concat "/" path)
             ^ "; use ignore explain"))
  in
  let excluded =
    Composition.entries prior |> List.map fst |> List.filter ignored
  in
  let* result =
    Composition.select ~base:prior ~observed:observed_tree ~paths ~excluded
    |> content
  in
  let contributed_paths = Composition.differences prior result in
  let public_paths = Composition.differences base result in
  let* public_snapshot = Composition.store store result |> content in
  let* title =
    match title with
    | Some title
      when title <> ""
           && String.length title <= Core.max_name_bytes
           && not (String.contains title '\000') ->
        Ok title
    | Some _ ->
        Error
          (Invalid "title must contain 1 through 1024 UTF-8 bytes without NUL")
    | None ->
        let paths =
          if contributed_paths = [] then public_paths else contributed_paths
        in
        let label =
          match paths with
          | [] -> "included work"
          | first :: rest ->
              String.escaped (String.concat "/" first)
              ^
              if rest = [] then ""
              else Printf.sprintf " and %d other paths" (List.length rest)
        in
        let label =
          if String.length label > 900 then String.sub label 0 900 else label
        in
        Ok ((if Option.is_some update then "Update " else "Share ") ^ label)
  in
  let* encoded_title =
    E.text title
    |> Result.map_error (fun e -> Invalid (E.construction_error_to_string e))
  in
  let project =
    if
      Model.Snapshot_id.equal
        (Model.active_draft loaded.Store.project).Model.latest_checkpoint
        observed
    then loaded.Store.project
    else Model.checkpoint loaded.Store.project ~snapshot:observed
  in
  let* history =
    History.record loaded.Store.history ~snapshot:observed
      ~draft:(Model.active_draft project).Model.draft_id
      ~created_at:(Int64.of_float (Unix.gettimeofday ()))
    |> metadata
  in
  let* source =
    History.identity history (History.current history) |> metadata
  in
  let* encoded_paths =
    List.fold_left
      (fun acc path ->
        let* rows = acc in
        let* row = array (List.map E.bytes path) in
        Ok (row :: rows))
      (Ok []) paths
    |> Result.map List.rev
  in
  let* encoded_paths = array encoded_paths in
  let* payload =
    array
      [
        E.integer 1L;
        E.bytes
          (Core.Repository_id.to_raw (Core.pool_repository (Local.pool local)));
        E.bytes (Core.Workspace_id.to_raw (Core.History_id.workspace source));
        E.integer (Core.History_id.sequence source);
        E.bytes (Core.Branch_id.to_raw selected.Local.branch);
        E.bytes (Core.Record_id.to_raw selected.Local.basis);
        E.bytes (Core.Object_id.to_raw observed_id);
        encoded_paths;
        Option.fold ~none:E.null
          ~some:(fun id -> E.bytes (Core.Change_id.to_raw id))
          update;
        encoded_title;
      ]
  in
  let* intent =
    Core.Digest.of_raw
      (Hash.to_raw_string
         (Hash.digest_string
            ("yeokcham/local-share-intent/v1\000" ^ E.encode payload)))
    |> model
  in
  let publication = Local.find_publication local ~intent in
  let summary =
    {
      publication;
      change = update;
      revision = Option.map (fun p -> p.Local.revision) publication;
      title;
      source;
      observed = observed_id;
      base_snapshot;
      public_snapshot;
      contributed_paths;
      public_paths;
      captures_unsaved =
        (History.current history).History.id
        <> (History.current loaded.Store.history).History.id;
      preview = true;
      repeated = Option.is_some publication;
    }
  in
  let summary =
    match publication with
    | None -> summary
    | Some p ->
        let change =
          match Core.find (Local.pool local) p.Local.revision with
          | Some { Core.payload = Core.Shared_revision value; _ } ->
              Some value.Core.change
          | None
          | Some
              {
                Core.payload = Core.Accepted_version _ | Core.Branch_event _;
                _;
              } ->
              None
        in
        { summary with change }
  in
  Ok
    {
      summary;
      project;
      history;
      local;
      collaboration;
      authority;
      previous;
      dependencies;
      intent;
    }

let preview prepared = prepared.summary

let stage ~store ~signing_capability prepared =
  let summary = prepared.summary in
  let* local =
    Local.remember prepared.local
      ~cursor:(History.current prepared.history).History.id
    |> metadata
  in
  if
    summary.repeated
    || (summary.contributed_paths = [] && prepared.previous = [])
  then
    Ok
      ( prepared.project,
        prepared.history,
        local,
        { summary with preview = false } )
  else
    let* certificate =
      Trust.certificates (Store.membership prepared.collaboration)
      |> List.find_opt (fun c ->
          Trust.certificate_id c
          = Store.local_certificate prepared.collaboration)
      |> Option.to_result
           ~none:(Policy "the enrolled local certificate is unavailable")
    in
    let device = Trust.certificate_subject certificate in
    let* () =
      if
        Trust.device_public_key device
        <> Trust.signing_public_key signing_capability
        || not
             (List.for_all
                (fun epoch ->
                  Trust.authority_device_active prepared.authority ~epoch device)
                (Trust.authority_heads prepared.authority))
      then
        Error
          (Policy "the signing device is not the active enrolled local author")
      else Ok ()
    in
    let* scope =
      Composition.Scope.store store summary.public_paths |> content
    in
    let* local, revision =
      Local.prepare_revision ~store ~authority:prepared.authority
        ~certificate:(Store.local_certificate prepared.collaboration)
        ~signing_capability ~change:summary.change
        ~previous_revisions:prepared.previous
        ~base_snapshot:summary.base_snapshot
        ~result_snapshot:summary.public_snapshot ~edit_scope_root:scope
        ~dependencies:prepared.dependencies local
      |> metadata
    in
    let* contributed_scope =
      Composition.Scope.store store summary.contributed_paths |> content
    in
    let* local, publication =
      Local.record_publication ~store ~intent:prepared.intent ~revision
        ~source:summary.source ~observed:summary.observed ~contributed_scope
        ~title:summary.title local
      |> metadata
    in
    let* change =
      match Core.find (Local.pool local) revision with
      | Some { Core.payload = Core.Shared_revision value; _ } ->
          Ok value.Core.change
      | None
      | Some { Core.payload = Core.Accepted_version _ | Core.Branch_event _; _ }
        ->
          Error (Metadata "staged shared revision disappeared")
    in
    Ok
      ( prepared.project,
        prepared.history,
        local,
        {
          summary with
          preview = false;
          publication = Some publication;
          revision = Some revision;
          change = Some change;
        } )
