module Core = Yeokcham_v1_model.Core
module Store = Yeokcham_v1_store
module Local = Store.Local
module History = Yeokcham_v1_undo
module Composition = Yeokcham_v1_composition

[@@@warning "-42"]

type error = Content of Composition.error | Invalid of string

let error_to_string = function
  | Content e -> Composition.error_to_string e
  | Invalid detail -> detail

type t = {
  known_present : Core.Object_id.t;
  workspace_result : Core.Object_id.t;
  contributions : Local.publication list;
}

let ( let* ) = Result.bind
let invalid r = Result.map_error (fun s -> Invalid s) r
let graph r = Result.map_error (fun e -> Invalid (Composition.Graph.error_to_string e)) r
let content r = Result.map_error (fun e -> Content e) r

let prepare ~store ~loaded ~represented ~accepted ~observed =
  let* local = loaded.Store.local |> Option.to_result ~none:(Invalid "private preservation requires a recorded working basis") in
  let basis = (Local.selected local).Local.basis in
  let* version = Composition.Graph.accepted (Local.pool local) basis |> graph in
  let* basis_revisions = Composition.Graph.represented (Local.pool local) [basis] |> graph in
  let member ids id = List.exists (Core.Record_id.equal id) ids in
  let newly_represented id = member represented id && not (member basis_revisions id) in
  let* () = Local.validate_history loaded.Store.history local |> invalid in
  let rec ancestry reversed node = match node.History.parent with
    | None -> Ok (node :: reversed)
    | Some parent -> let* parent = History.find loaded.Store.history parent |> invalid in ancestry (node::reversed) parent in
  let* ancestors = ancestry [] (History.current loaded.Store.history) in
  let relevant = Local.publications local |> List.filter (fun p -> newly_represented p.Local.revision) in
  let seen = Hashtbl.create 32 in
  let contributions = List.fold_left (fun selected node ->
    let present = List.filter (fun p -> Core.History_id.sequence p.Local.source=node.History.id) relevant in
    List.fold_left (fun selected p -> if Hashtbl.mem seen p.Local.revision then selected
      else (Hashtbl.add seen p.Local.revision (); p::selected)) selected present)
    [] (List.rev ancestors) in
  let* base = Composition.load store version.Core.result_snapshot |> content in
  let* known = List.fold_left (fun acc p ->
    let* base = acc in
    let* paths = Composition.Scope.load store p.Local.contributed_scope |> content in
    let* entries, witnesses = Composition.Witness.inspect store ~snapshot:p.Local.observed ~paths |> content in
    if witnesses <> p.Local.witnesses then Error (Invalid "publication source witnesses changed")
    else Composition.overlay ~base entries |> content) (Ok base) contributions in
  let* known_present = Composition.store store known |> content in
  let* observed = Composition.load store observed |> content in
  let* workspace = Composition.merge store ~base:known ~variants:[accepted;observed] |> content in
  let* workspace_result = Composition.store store workspace |> content in
  Ok {known_present;workspace_result;contributions}
