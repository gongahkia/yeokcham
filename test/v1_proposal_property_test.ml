module Model = Yeokcham_v1_model
module Proposal = Yeokcham_v1_proposal
module Snapshot = Yeokcham_snapshot

let require_ok = Result.get_ok
let id parse value = parse value |> require_ok
let snapshot value = id Model.Snapshot_id.of_string value
let decision value = id Model.Decision_id.of_string value
let revision value = id Model.Revision_id.of_string value
let change value = id Model.Change_id.of_string value
let device value = id Model.Device_id.of_string value
let path value = id Model.Path.of_components [ value ]

let revision_record revision_id =
  Model.make_change_revision
    ~change:(change ("change-" ^ revision_id))
    ~revision:(revision revision_id) ~parent:None
    ~author:(device "device-alice") ~base:(snapshot "snapshot-base")
    ~result:(snapshot ("snapshot-" ^ revision_id))
    ~edits:[ Model.{ edit_path = path "entry"; edit_kind = Whole_path } ]
  |> require_ok

let entry = function
  | 0 -> None
  | 1 -> Some (Proposal.File { mode = Snapshot.Regular; content = "one" })
  | 2 -> Some (Proposal.File { mode = Snapshot.Regular; content = "two" })
  | 3 -> Some (Proposal.File { mode = Snapshot.Executable; content = "one" })
  | _ -> Some Proposal.Directory

let tree entry =
  match entry with
  | None -> Proposal.tree_of_entries [] |> require_ok
  | Some entry ->
      Proposal.tree_of_entries [ (path "entry", entry) ] |> require_ok

let canonical_pairing_is_order_independent =
  QCheck2.Test.make ~count:300
    ~name:"V1 exact proposal classification is independent of pair input order"
    QCheck2.Gen.(triple (int_range 0 4) (int_range 0 4) (int_range 0 4))
    (fun (base_entry, left_entry, right_entry) ->
      let base = tree (entry base_entry) in
      let left_tree = tree (entry left_entry) in
      let right_tree = tree (entry right_entry) in
      let left = revision_record "revision-left" in
      let right = revision_record "revision-right" in
      let forward =
        Proposal.classify
          ~decision:(decision "decision-proposal")
          ~current_baseline:(snapshot "snapshot-base") ~left ~right ~base
          ~left_tree ~right_tree
      in
      let reverse =
        Proposal.classify
          ~decision:(decision "decision-proposal")
          ~current_baseline:(snapshot "snapshot-base") ~left:right ~right:left
          ~base ~left_tree:right_tree ~right_tree:left_tree
      in
      forward = reverse)

let ready_output_is_always_one_of_its_exact_inputs =
  QCheck2.Test.make ~count:300
    ~name:"V1 ready proposal output always names an exact input entry"
    QCheck2.Gen.(triple (int_range 0 4) (int_range 0 4) (int_range 0 4))
    (fun (base_entry, left_entry, right_entry) ->
      let base = tree (entry base_entry) in
      let left_tree = tree (entry left_entry) in
      let right_tree = tree (entry right_entry) in
      let left = revision_record "revision-left" in
      let right = revision_record "revision-right" in
      let proposal =
        Proposal.classify
          ~decision:(decision "decision-proposal")
          ~current_baseline:(snapshot "snapshot-base") ~left ~right ~base
          ~left_tree ~right_tree
      in
      match Proposal.selected proposal with
      | None -> true
      | Some selected ->
          List.for_all
            (fun (_, source, selected) ->
              match source with
              | Proposal.Base -> selected = entry base_entry
              | Proposal.Left -> selected = entry left_entry
              | Proposal.Right -> selected = entry right_entry)
            selected)

let () =
  Alcotest.run "V1 proposal properties"
    [
      ( "proposal",
        [
          QCheck_alcotest.to_alcotest canonical_pairing_is_order_independent;
          QCheck_alcotest.to_alcotest
            ready_output_is_always_one_of_its_exact_inputs;
        ] );
    ]
