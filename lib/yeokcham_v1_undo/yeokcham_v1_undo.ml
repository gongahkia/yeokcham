module Model = Yeokcham_v1_model
module Encoding = Yeokcham_encoding
module Core = Model.Core

type node = {
  id : int64;
  parent : int64 option;
  snapshot : Model.Snapshot_id.t;
  draft : Model.Draft_id.t;
  created_at : int64;
}

type t = {
  workspace : Core.Workspace_id.t option;
  next : int64 option;
  cursor : int64;
  entries : node list;
}

let ( let* ) = Result.bind
let nodes history = List.rev history.entries

let find history id =
  match List.find_opt (fun node -> Int64.equal node.id id) history.entries with
  | Some node -> Ok node
  | None -> Error (Printf.sprintf "unknown local history node %Ld" id)

let current history =
  match find history history.cursor with
  | Ok node -> node
  | Error _ -> invalid_arg "invalid local history cursor"

let seed ~snapshot ~draft =
  {
    workspace = None;
    next = Some 1L;
    cursor = 0L;
    entries = [ { id = 0L; parent = None; snapshot; draft; created_at = 0L } ];
  }

let workspace history = history.workspace
let next_sequence history = history.next

let bind_workspace history workspace =
  match history.workspace with
  | None -> Ok { history with workspace = Some workspace }
  | Some current when Core.Workspace_id.equal current workspace -> Ok history
  | Some _ -> Error "cannot reassign a persisted workspace namespace"

let identity history node =
  let* stored = find history node.id in
  if stored <> node then Error "history identity collision"
  else
    match history.workspace with
    | None -> Error "history has no persisted workspace namespace"
    | Some workspace ->
        Core.History_id.make ~workspace ~sequence:node.id
        |> Result.map_error Core.error_to_string

let validate_update ~previous history =
  let* () =
    match (previous.workspace, history.workspace) with
    | Some previous, Some current when Core.Workspace_id.equal previous current
      ->
        Ok ()
    | None, (None | Some _) -> Ok ()
    | Some _, (None | Some _) -> Error "cannot replace the workspace namespace"
  in
  let rec prefix earlier current =
    match (earlier, current) with
    | [], _ -> Ok history
    | _ :: _, [] -> Error "cannot erase retained history"
    | previous :: rest, node :: remaining ->
        if previous = node then prefix rest remaining
        else Error "history identity collision or rewritten ancestry"
  in
  prefix (nodes previous) (nodes history)

let children history parent =
  nodes history
  |> List.filter (fun node ->
      Option.equal Int64.equal node.parent (Some parent))

let select history id =
  let* _ = find history id in
  Ok { history with cursor = id }

let append history ~parent ~snapshot ~draft ~created_at =
  if Int64.compare created_at 0L < 0 then Error "negative history timestamp"
  else
    let* id, next =
      match history.workspace with
      | Some workspace ->
          Core.History_id.allocate ~workspace ~next:history.next
          |> Result.map (fun (id, next) -> (Core.History_id.sequence id, next))
          |> Result.map_error Core.error_to_string
      | None -> (
          match history.next with
          | None -> Error "local history IDs exhausted"
          | Some id ->
              Ok
                ( id,
                  if Int64.equal id Int64.max_int then None
                  else Some (Int64.succ id) ))
    in
    if List.exists (fun node -> Int64.equal node.id id) history.entries then
      Error "history identity collision"
    else
      let node = { id; parent; snapshot; draft; created_at } in
      Ok ({ history with next; entries = node :: history.entries }, node)

let record history ~snapshot ~draft ~created_at =
  if Model.Snapshot_id.equal (current history).snapshot snapshot then Ok history
  else
    let* history, node =
      append history ~parent:(Some history.cursor) ~snapshot ~draft ~created_at
    in
    select history node.id

let target_snapshot history ~snapshot ~draft ~created_at =
  let matches node = Model.Snapshot_id.equal node.snapshot snapshot in
  let rec ancestor node =
    if matches node then Some node
    else
      match node.parent with
      | None -> None
      | Some id -> (
          match find history id with
          | Ok node -> ancestor node
          | Error _ -> None)
  in
  match ancestor (current history) with
  | Some node -> Ok (history, node)
  | None -> (
      match List.find_opt matches history.entries with
      | Some node -> Ok (history, node)
      | None -> append history ~parent:None ~snapshot ~draft ~created_at)

let construction result =
  Result.map_error Encoding.construction_error_to_string result

let text value = construction (Encoding.text value)
let array values = construction (Encoding.array values)

let encode_node node =
  let* snapshot = text (Model.Snapshot_id.to_string node.snapshot) in
  let* draft = text (Model.Draft_id.to_string node.draft) in
  array
    [
      Encoding.integer node.id;
      Option.fold ~none:Encoding.null ~some:Encoding.integer node.parent;
      snapshot;
      draft;
      Encoding.integer node.created_at;
    ]

let encode history =
  let* entries =
    List.fold_left
      (fun result node ->
        let* entries = result in
        let* value = encode_node node in
        Ok (value :: entries))
      (Ok []) history.entries
  in
  let* entries = array entries in
  let* value =
    match history.workspace with
    | None ->
        array [ Encoding.integer 1L; Encoding.integer history.cursor; entries ]
    | Some workspace ->
        array
          [
            Encoding.integer 2L;
            Encoding.bytes (Core.Workspace_id.to_raw workspace);
            Option.fold ~none:Encoding.null ~some:Encoding.integer history.next;
            Encoding.integer history.cursor;
            entries;
          ]
  in
  Ok (Encoding.encode value)

let[@warning "-4"] decode_node = function
  | Encoding.Array
      [
        Encoding.Integer id;
        parent;
        Encoding.Text snapshot;
        Encoding.Text draft;
        Encoding.Integer created_at;
      ] ->
      let* parent =
        match parent with
        | Encoding.Null -> Ok None
        | Encoding.Integer id -> Ok (Some id)
        | _ -> Error "history parent must be an ID or null"
      in
      let* snapshot =
        Model.Snapshot_id.of_string snapshot
        |> Result.map_error Model.error_to_string
      in
      let* draft =
        Model.Draft_id.of_string draft |> Result.map_error Model.error_to_string
      in
      Ok { id; parent; snapshot; draft; created_at }
  | _ -> Error "invalid local history node"

module Sequences = Set.Make (Int64)

let decode_entries ~consecutive values =
  List.fold_left
    (fun result value ->
      let* last, entries, seen = result in
      let* node = decode_node value in
      if Int64.compare node.id 0L < 0 || Int64.compare node.created_at 0L < 0
      then Error "history IDs and timestamps must be nonnegative"
      else if
        Option.fold ~none:false
          ~some:(fun last -> Int64.compare node.id last <= 0)
          last
      then Error "history IDs must be strictly increasing"
      else if
        consecutive
        && not
             (Int64.equal node.id (Option.fold ~none:0L ~some:Int64.succ last))
      then Error "history IDs must be consecutive"
      else if
        Option.fold ~none:false
          ~some:(fun parent -> not (Sequences.mem parent seen))
          node.parent
      then Error "history parent must name an earlier node"
      else Ok (Some node.id, node :: entries, Sequences.add node.id seen))
    (Ok (None, [], Sequences.empty))
    values

let[@warning "-4"] decode bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error Encoding.decode_error_to_string
  in
  let* workspace, next, cursor, entries =
    match value with
    | Encoding.Array
        [ Encoding.Integer 1L; Encoding.Integer cursor; Encoding.Array values ]
      ->
        let* last, entries, _ = decode_entries ~consecutive:true values in
        Ok
          ( None,
            Option.bind last (fun last ->
                if Int64.equal last Int64.max_int then None
                else Some (Int64.succ last)),
            cursor,
            entries )
    | Encoding.Array
        [
          Encoding.Integer 2L;
          Encoding.Bytes workspace;
          next;
          Encoding.Integer cursor;
          Encoding.Array values;
        ] ->
        let* workspace =
          Core.Workspace_id.of_raw workspace
          |> Result.map_error Core.error_to_string
        in
        let* last, entries, _ = decode_entries ~consecutive:false values in
        let* next =
          match next with
          | Encoding.Null -> Ok None
          | Encoding.Integer n when Int64.compare n 0L >= 0 -> Ok (Some n)
          | _ -> Error "history counter must be nonnegative or exhausted"
        in
        let expected =
          Option.bind last (fun last ->
              if Int64.equal last Int64.max_int then None
              else Some (Int64.succ last))
        in
        if next <> expected then
          Error "history counter does not follow the last allocated ID"
        else Ok (Some workspace, next, cursor, entries)
    | _ -> Error "unsupported local history schema"
  in
  let history = { workspace; next; cursor; entries } in
  let* _ = find history cursor in
  let* canonical = encode history in
  if String.equal bytes canonical then Ok history
  else Error "noncanonical local history"
