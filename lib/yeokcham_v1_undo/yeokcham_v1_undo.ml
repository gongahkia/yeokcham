module Model = Yeokcham_v1_model
module Encoding = Yeokcham_encoding

type node = {
  id : int64;
  parent : int64 option;
  snapshot : Model.Snapshot_id.t;
  draft : Model.Draft_id.t;
  created_at : int64;
}

type t = { cursor : int64; entries : node list }

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
    cursor = 0L;
    entries = [ { id = 0L; parent = None; snapshot; draft; created_at = 0L } ];
  }

let children history parent =
  nodes history
  |> List.filter (fun node ->
      Option.equal Int64.equal node.parent (Some parent))

let select history id =
  let* _ = find history id in
  Ok { history with cursor = id }

let append history ~parent ~snapshot ~draft ~created_at =
  let last = List.hd history.entries in
  if Int64.equal last.id Int64.max_int then Error "local history IDs exhausted"
  else if Int64.compare created_at 0L < 0 then
    Error "negative history timestamp"
  else
    let node =
      { id = Int64.succ last.id; parent; snapshot; draft; created_at }
    in
    Ok ({ history with entries = node :: history.entries }, node)

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
    array [ Encoding.integer 1L; Encoding.integer history.cursor; entries ]
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

let[@warning "-4"] decode bytes =
  let* value =
    Encoding.decode bytes |> Result.map_error Encoding.decode_error_to_string
  in
  match value with
  | Encoding.Array
      [ Encoding.Integer 1L; Encoding.Integer cursor; Encoding.Array values ] ->
      let* _, entries =
        List.fold_left
          (fun result value ->
            let* expected, entries = result in
            let* node = decode_node value in
            if
              (not (Int64.equal node.id expected))
              || Int64.compare node.created_at 0L < 0
            then
              Error "history IDs must be consecutive and timestamps nonnegative"
            else if
              Option.fold ~none:false
                ~some:(fun parent ->
                  Int64.compare parent 0L < 0
                  || Int64.compare parent node.id >= 0)
                node.parent
            then Error "history parent must name an earlier node"
            else Ok (Int64.succ expected, node :: entries))
          (Ok (0L, []))
          values
      in
      let history = { cursor; entries } in
      let* _ = find history cursor in
      let* canonical = encode history in
      if String.equal bytes canonical then Ok history
      else Error "noncanonical local history"
  | _ -> Error "unsupported local history schema"
