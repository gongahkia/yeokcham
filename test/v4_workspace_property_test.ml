module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust
module Workspace = Yeokcham_v4_workspace

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let identifier character = String.make 64 character
let snapshot value = Model.Snapshot_id.of_string value |> Result.get_ok

let basis tree =
  Workspace.make_projection_basis ~repository
    ~imported_basis_id:(identifier 'a')
    ~snapshot:(snapshot "snapshot-projected")
    ~canonical_tree:tree ~source_fingerprint:tree
  |> Result.get_ok

let activated tree =
  Workspace.activate
    ~basis:(Some (basis tree))
    ~closure:Workspace.Closure_complete ~destination:Workspace.Destination_empty
  |> Result.get_ok

let observed tree =
  Workspace.make_observed_tree ~canonical_tree:tree ~source_fingerprint:tree
  |> Result.get_ok

let update_never_discards_a_dirty_tree_without_replace =
  QCheck2.Test.make ~count:300
    ~name:
      "V4 workspace update only plans dirty replacement after explicit \
       --replace"
    QCheck2.Gen.(pair (int_range 0 3) bool)
    (fun (tree_selector, replace) ->
      let projected = identifier 'b' in
      let current =
        match tree_selector with
        | 0 -> projected
        | 1 -> identifier 'c'
        | 2 -> identifier 'd'
        | _ -> identifier 'e'
      in
      let basis = basis projected in
      let receipt = Workspace.plan_receipt (activated projected) in
      match
        Workspace.plan_update ~basis:(Some basis) ~receipt:(Some receipt)
          ~closure:Workspace.Closure_complete ~observed:(observed current)
          ~replace
      with
      | Error Workspace.Dirty_workspace ->
          (not replace) && not (String.equal current projected)
      | Ok (Workspace.Already_current _) -> String.equal current projected
      | Ok (Workspace.Update plan) ->
          replace
          && (not (String.equal current projected))
          && Workspace.plan_requires_safety_checkpoint plan
      | Error
          ( Workspace.Missing_closure | Workspace.No_verified_basis
          | Workspace.Receipt_mismatch | Workspace.Unsafe_path
          | Workspace.Nonempty_destination ) ->
          false)

let receipt_generation_is_monotonic_for_verified_projection_updates =
  QCheck2.Test.make ~count:300
    ~name:
      "V4 workspace receipt generations increase exactly once per projected \
       tree update"
    QCheck2.Gen.(int_range 0 3)
    (fun selector ->
      let initial_tree = identifier 'b' in
      let next_tree = identifier (Char.chr (Char.code 'c' + selector)) in
      let receipt = Workspace.plan_receipt (activated initial_tree) in
      let next_basis = basis next_tree in
      match
        Workspace.plan_update ~basis:(Some next_basis) ~receipt:(Some receipt)
          ~closure:Workspace.Closure_complete ~observed:(observed initial_tree)
          ~replace:false
      with
      | Ok (Workspace.Update plan) ->
          Int64.equal
            (Workspace.receipt_activation_generation
               (Workspace.plan_receipt plan))
            (Int64.succ (Workspace.receipt_activation_generation receipt))
      | Ok (Workspace.Already_current _) -> String.equal initial_tree next_tree
      | Error
          ( Workspace.Dirty_workspace | Workspace.Missing_closure
          | Workspace.No_verified_basis | Workspace.Receipt_mismatch
          | Workspace.Unsafe_path | Workspace.Nonempty_destination ) ->
          false)

let () =
  Alcotest.run "V4 workspace properties"
    [
      ( "workspace",
        [
          QCheck_alcotest.to_alcotest
            update_never_discards_a_dirty_tree_without_replace;
          QCheck_alcotest.to_alcotest
            receipt_generation_is_monotonic_for_verified_projection_updates;
        ] );
    ]
