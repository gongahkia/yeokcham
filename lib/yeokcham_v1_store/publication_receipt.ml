module Core = Yeokcham_v1_model.Core
module E = Yeokcham_encoding
module Raw = Yeokcham_store
module Pages = Yeokcham_v1_pages
module Composition = Yeokcham_v1_composition

[@@@warning "-42"]

let ( let* ) = Result.bind
let model r = Result.map_error Core.error_to_string r
let pages r = Result.map_error Pages.error_to_string r
let composition r = Result.map_error Composition.error_to_string r
let array fields = E.array fields |> Result.map_error E.construction_error_to_string
let namespace repository = "local-publications-v1\000" ^ Core.Repository_id.to_raw repository
let witness_namespace repository = "local-publication-witness-v1\000" ^ Core.Repository_id.to_raw repository

type t = {
  operation : Core.Operation_id.t;
  intent : Core.Digest.t;
  revision : Core.Record_id.t;
  publication_branch : Core.Branch_id.t;
  source : Core.History_id.t;
  observed : Core.Object_id.t;
  contributed_scope : Core.Object_id.t;
  title : string;
  witness_root : Raw.Stored_object_id.t;
  witnesses : Raw.Stored_object_id.t list;
}

let encode receipt =
  let* title = E.text receipt.title |> Result.map_error E.construction_error_to_string in
  let* value = array [
    E.integer 1L;
    E.bytes (Core.Digest.to_raw receipt.intent);
    E.bytes (Core.Record_id.to_raw receipt.revision);
    E.bytes (Core.Branch_id.to_raw receipt.publication_branch);
    E.bytes (Core.Workspace_id.to_raw (Core.History_id.workspace receipt.source));
    E.integer (Core.History_id.sequence receipt.source);
    E.bytes (Core.Object_id.to_raw receipt.observed);
    E.bytes (Core.Object_id.to_raw receipt.contributed_scope);
    title;
    E.bytes (Raw.Stored_object_id.to_raw_bytes receipt.witness_root)
  ] in
  Ok (E.encode value)

let store repository ~scope receipts =
  let* rows = List.fold_left (fun acc receipt ->
    let* rows = acc in
    let* bytes = encode receipt in
    Ok ((Core.Operation_id.to_raw receipt.operation, bytes) :: rows)) (Ok []) receipts in
  Pages.store repository ~namespace:(namespace scope) rows |> pages

let[@warning "-4"] load repository ~scope root =
  let* rows = Pages.load repository ~namespace:(namespace scope) root |> pages in
  List.fold_left (fun acc (operation, bytes) ->
    let* receipts = acc in
    let* operation = Core.Operation_id.of_raw operation |> model in
    let* value = E.decode bytes |> Result.map_error E.decode_error_to_string in
    let* receipt = match value with
    | E.Array [E.Integer 1L; E.Bytes intent; E.Bytes revision; E.Bytes branch;
        E.Bytes workspace; E.Integer sequence; E.Bytes observed; E.Bytes contributed_scope;
        E.Text title; E.Bytes witness_root] ->
        let* intent = Core.Digest.of_raw intent |> model in
        let* revision = Core.Record_id.of_raw revision |> model in
        let* branch = Core.Branch_id.of_raw branch |> model in
        let* workspace = Core.Workspace_id.of_raw workspace |> model in
        let* source = Core.History_id.make ~workspace ~sequence |> model in
        let* observed = Core.Object_id.of_raw observed |> model in
        let* contributed_scope = Core.Object_id.of_raw contributed_scope |> model in
        let* witness_root = Raw.Stored_object_id.of_raw_bytes witness_root
          |> Option.to_result ~none:"invalid publication witness root" in
        let* rows = Pages.load repository ~namespace:(witness_namespace scope) witness_root |> pages in
        let* witnesses = List.fold_left (fun acc (id, value) ->
          let* ids = acc in
          let* id = Raw.Stored_object_id.of_raw_bytes id
            |> Option.to_result ~none:"invalid publication witness identity" in
          if value <> "" then Error "publication witness set value must be empty"
          else Ok (id :: ids)) (Ok []) rows |> Result.map List.rev in
        Ok {operation;intent;revision;publication_branch=branch;source;observed;contributed_scope;title;witness_root;witnesses}
    | _ -> Error "unsupported publication receipt schema" in
    let* canonical = encode receipt in
    if canonical <> bytes then Error "noncanonical publication receipt"
    else Ok (receipt :: receipts)) (Ok []) rows |> Result.map List.rev

let[@warning "-4"] entry_equal a b = match a, b with
  | None, None | Some Composition.Directory, Some Composition.Directory -> true
  | Some (Composition.File a), Some (Composition.File b) ->
      a.mode = b.mode && Yeokcham_snapshot.Content.equal_id a.content b.content
  | _ -> false

let find_revision pool id = match Core.find pool id with
  | Some { Core.payload = Core.Shared_revision revision; _ } -> Ok revision
  | Some { Core.payload = (Core.Accepted_version _ | Core.Branch_event _); _ } ->
      Error "publication receipt must name a shared revision"
  | None -> Error "publication receipt names an unknown revision"

let proof repository pool ~revision:id ~observed ~contributed_scope =
  let* revision = find_revision pool id in
  let* before = match revision.Core.previous_revisions with
    | [] -> Ok revision.Core.base_snapshot
    | [ previous ] -> let* previous = find_revision pool previous in Ok previous.Core.result_snapshot
    | _ -> Error "publication correspondence needs explicit resolution of concurrent revisions" in
  let* before = Composition.load repository before |> composition in
  let* after = Composition.load repository revision.Core.result_snapshot |> composition in
  let* paths = Composition.Scope.load repository contributed_scope |> composition in
  if paths = [] || paths <> Composition.differences before after then
    Error "publication contribution must equal the newly selected public differences"
  else
    let* entries, witnesses = Composition.Witness.inspect repository ~snapshot:observed ~paths |> composition in
    let after = Composition.entries after in
    if List.for_all (fun (path, entry) -> entry_equal entry (List.assoc_opt path after)) entries then
      Ok witnesses
    else Error "selected public work does not match its private source observation"

let validate repository pool receipts =
  let intents = Hashtbl.create 32 in
  List.fold_left (fun acc receipt ->
    let* () = acc in
    if receipt.title = "" || String.length receipt.title > Core.max_name_bytes
      || String.contains receipt.title '\000' then Error "publication title must contain 1 through 1024 bytes without NUL"
    else if Hashtbl.mem intents receipt.intent then Error "duplicate publication retry intent"
    else if not (List.exists (fun state -> Core.Branch_id.equal state.Core.branch_id receipt.publication_branch)
      (Core.branch_states pool)) then Error "publication branch is not retained"
    else (
      Hashtbl.add intents receipt.intent ();
      let* witnesses = proof repository pool ~revision:receipt.revision
        ~observed:receipt.observed ~contributed_scope:receipt.contributed_scope in
      if witnesses <> receipt.witnesses then Error "publication witnesses do not prove exactly the selected paths"
      else Ok ())) (Ok ()) receipts

let add ~random_bytes repository pool ~branch ~intent ~revision ~source ~observed
    ~contributed_scope ~title receipts =
  let same_request receipt = Core.Digest.equal receipt.intent intent
    && Core.Record_id.equal receipt.revision revision && Core.Branch_id.equal receipt.publication_branch branch
    && Core.History_id.equal receipt.source source && Core.Object_id.equal receipt.observed observed
    && Core.Object_id.equal receipt.contributed_scope contributed_scope && receipt.title = title in
  match List.find_opt (fun receipt -> Core.Digest.equal receipt.intent intent) receipts with
  | Some receipt when same_request receipt -> Ok (receipts, receipt)
  | Some _ -> Error "publication retry intent already binds different work"
  | None ->
      let rec fresh attempts =
        let* operation = Core.Operation_id.generate ~random_bytes () |> model in
        if List.exists (fun r -> Core.Operation_id.equal r.operation operation) receipts then
          if attempts = 1 then Error "publication operation identity collision after three attempts"
          else fresh (attempts - 1)
        else Ok operation in
      let* operation = fresh 3 in
      let* witnesses = proof repository pool ~revision ~observed ~contributed_scope in
      let* witness_root = Pages.store repository
        ~namespace:(witness_namespace (Core.pool_repository pool))
        (List.map (fun id -> Raw.Stored_object_id.to_raw_bytes id, "") witnesses) |> pages in
      let receipt = {operation;intent;revision;publication_branch=branch;source;observed;contributed_scope;title;witness_root;witnesses} in
      let* () = validate repository pool [receipt] in
      Ok (List.sort (fun a b -> Core.Operation_id.compare a.operation b.operation) (receipt :: receipts), receipt)

let validate_history history receipts =
  List.fold_left (fun acc receipt ->
    let* () = acc in
    if not (Option.equal Core.Workspace_id.equal (Yeokcham_v1_undo.workspace history)
      (Some (Core.History_id.workspace receipt.source))) then
      Error "publication source belongs to a different workspace"
    else
      let* node = Yeokcham_v1_undo.find history (Core.History_id.sequence receipt.source) in
      if Yeokcham_v1_model.Snapshot_id.to_string node.Yeokcham_v1_undo.snapshot
        = Core.Object_id.to_hex receipt.observed then Ok ()
      else Error "publication source history payload does not match its witnessed observation") (Ok ()) receipts
