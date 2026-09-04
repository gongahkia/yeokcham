module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust
module Workspace = Yeokcham_v4_workspace

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let snapshot value = Model.Snapshot_id.of_string value |> Result.get_ok

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let identifier character = String.make 64 character

let make_basis ?(tree = identifier 'b') ?(imported_basis_id = identifier 'a') ()
    =
  Workspace.make_projection_basis ~repository ~imported_basis_id
    ~snapshot:(snapshot "snapshot-projected")
    ~canonical_tree:tree ~source_fingerprint:tree
  |> require_ok Workspace.error_to_string

let observed tree =
  Workspace.make_observed_tree ~canonical_tree:tree ~source_fingerprint:tree
  |> require_ok Workspace.error_to_string

let activated basis =
  Workspace.activate ~basis:(Some basis) ~closure:Workspace.Closure_complete
    ~destination:Workspace.Destination_empty
  |> require_ok Workspace.refusal_to_string

let expect_refusal expected = function
  | Error actual when actual = expected -> ()
  | Error actual ->
      Alcotest.failf "expected %s, got %s"
        (Workspace.refusal_to_string expected)
        (Workspace.refusal_to_string actual)
  | Ok _ -> Alcotest.fail "expected a typed workspace refusal"

let activation_plans_the_unique_verified_tree () =
  let basis = make_basis () in
  let plan = activated basis in
  let receipt = Workspace.plan_receipt plan in
  Alcotest.(check string)
    "receipt binds the immutable imported basis" (identifier 'a')
    (Workspace.receipt_imported_basis_id receipt);
  Alcotest.(check string)
    "receipt binds the exact canonical tree" (identifier 'b')
    (Workspace.receipt_canonical_tree receipt);
  Alcotest.(check int64)
    "first activation has generation one" 1L
    (Workspace.receipt_activation_generation receipt);
  Alcotest.(check bool)
    "initial empty activation has no replacement safety checkpoint" false
    (Workspace.plan_requires_safety_checkpoint plan)

let activation_returns_every_typed_refusal () =
  let basis = make_basis () in
  Workspace.activate ~basis:None ~closure:Workspace.Closure_complete
    ~destination:Workspace.Destination_empty
  |> expect_refusal Workspace.No_verified_basis;
  Workspace.activate ~basis:(Some basis) ~closure:Workspace.Closure_missing
    ~destination:Workspace.Destination_empty
  |> expect_refusal Workspace.Missing_closure;
  Workspace.activate ~basis:(Some basis) ~closure:Workspace.Closure_complete
    ~destination:Workspace.Destination_nonempty
  |> expect_refusal Workspace.Nonempty_destination;
  Workspace.activate ~basis:(Some basis) ~closure:Workspace.Closure_complete
    ~destination:Workspace.Destination_unsafe
  |> expect_refusal Workspace.Unsafe_path

let clean_update_is_a_noop_and_dirty_update_requires_explicit_replace () =
  let basis = make_basis () in
  let receipt = Workspace.plan_receipt (activated basis) in
  ( Workspace.plan_update ~basis:(Some basis) ~receipt:(Some receipt)
      ~closure:Workspace.Closure_complete
      ~observed:(observed (identifier 'b'))
      ~replace:false
  |> function
    | Ok (Workspace.Already_current current) ->
        Alcotest.(check int64)
          "clean update does not advance a receipt" 1L
          (Workspace.receipt_activation_generation current)
    | Ok (Workspace.Update _) -> Alcotest.fail "clean update planned a rewrite"
    | Error refusal -> Alcotest.fail (Workspace.refusal_to_string refusal) );
  Workspace.plan_update ~basis:(Some basis) ~receipt:(Some receipt)
    ~closure:Workspace.Closure_complete
    ~observed:(observed (identifier 'c'))
    ~replace:false
  |> expect_refusal Workspace.Dirty_workspace;
  Workspace.plan_update ~basis:(Some basis) ~receipt:(Some receipt)
    ~closure:Workspace.Closure_complete
    ~observed:(observed (identifier 'c'))
    ~replace:true
  |> function
  | Ok (Workspace.Update plan) ->
      Alcotest.(check bool)
        "replace plans a durable safety checkpoint" true
        (Workspace.plan_requires_safety_checkpoint plan);
      Alcotest.(check int64)
        "replace advances receipt generation" 2L
        (Workspace.receipt_activation_generation (Workspace.plan_receipt plan))
  | Ok (Workspace.Already_current _) ->
      Alcotest.fail "dirty replace did not plan materialisation"
  | Error refusal -> Alcotest.fail (Workspace.refusal_to_string refusal)

let update_refuses_missing_closure_and_incompatible_receipt () =
  let basis = make_basis () in
  let receipt = Workspace.plan_receipt (activated basis) in
  Workspace.plan_update ~basis:(Some basis) ~receipt:(Some receipt)
    ~closure:Workspace.Closure_missing
    ~observed:(observed (identifier 'b'))
    ~replace:false
  |> expect_refusal Workspace.Missing_closure;
  let incompatible = make_basis ~imported_basis_id:(identifier 'c') () in
  Workspace.plan_update ~basis:(Some incompatible) ~receipt:(Some receipt)
    ~closure:Workspace.Closure_complete
    ~observed:(observed (identifier 'b'))
    ~replace:false
  |> expect_refusal Workspace.Receipt_mismatch;
  Workspace.plan_update ~basis:(Some basis) ~receipt:None
    ~closure:Workspace.Closure_complete
    ~observed:(observed (identifier 'b'))
    ~replace:false
  |> expect_refusal Workspace.Receipt_mismatch

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let persistent_records_have_canonical_golden_bytes () =
  let basis = make_basis () in
  let receipt =
    let activation = activated basis in
    let first = Workspace.plan_receipt activation in
    let updated = make_basis ~tree:(identifier 'c') () in
    Workspace.plan_update ~basis:(Some updated) ~receipt:(Some first)
      ~closure:Workspace.Closure_complete
      ~observed:(observed (identifier 'b'))
      ~replace:false
    |> require_ok Workspace.refusal_to_string
    |> function
    | Workspace.Update plan -> Workspace.plan_receipt plan
    | Workspace.Already_current _ ->
        Alcotest.fail "changed verified tree was ignored"
  in
  let expected_basis =
    Golden.read_lower_hex_file (golden_path "v4/projection-basis-v1.cbor.hex")
    |> require_ok Fun.id
  in
  let expected_receipt =
    Golden.read_lower_hex_file
      (golden_path "v4/workspace-projection-receipt-v1.cbor.hex")
    |> require_ok Fun.id
  in
  Alcotest.(check string)
    "basis canonical bytes" expected_basis
    (Workspace.encode_basis basis |> require_ok Workspace.error_to_string);
  Alcotest.(check string)
    "receipt canonical bytes" expected_receipt
    (Workspace.encode_receipt receipt |> require_ok Workspace.error_to_string);
  let decoded_basis =
    Workspace.decode_basis expected_basis
    |> require_ok Workspace.error_to_string
  in
  let decoded_receipt =
    Workspace.decode_receipt expected_receipt
    |> require_ok Workspace.error_to_string
  in
  Alcotest.(check string)
    "basis canonical round trip" expected_basis
    (Workspace.encode_basis decoded_basis
    |> require_ok Workspace.error_to_string);
  Alcotest.(check string)
    "receipt canonical round trip" expected_receipt
    (Workspace.encode_receipt decoded_receipt
    |> require_ok Workspace.error_to_string)

let records_reject_unknown_noncanonical_and_malformed_input () =
  let basis_bytes =
    Workspace.encode_basis (make_basis ())
    |> require_ok Workspace.error_to_string
  in
  let receipt_bytes =
    Workspace.encode_receipt
      (Workspace.plan_receipt (activated (make_basis ())))
    |> require_ok Workspace.error_to_string
  in
  List.iter
    (fun bytes ->
      match Workspace.decode_basis bytes with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "basis decoder accepted invalid bytes")
    [
      "\x86\x02\x60\x60\x60\x60\x60";
      "\x9f" ^ String.sub basis_bytes 1 (String.length basis_bytes - 1);
    ];
  List.iter
    (fun bytes ->
      match Workspace.decode_receipt bytes with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "receipt decoder accepted invalid bytes")
    [
      "\x87\x02\x60\x60\x60\x60\x01\x60";
      "\x9f" ^ String.sub receipt_bytes 1 (String.length receipt_bytes - 1);
    ]

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root run =
  let root = Filename.temp_file "v4-workspace-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".yeokcham") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let local_records_are_create_only_or_atomic () =
  with_root (fun root ->
      let basis = make_basis () in
      Workspace.write_basis ~root basis |> require_ok Workspace.error_to_string;
      Workspace.write_basis ~root basis |> require_ok Workspace.error_to_string;
      let stored_basis =
        Workspace.read_basis ~root |> require_ok Workspace.error_to_string
      in
      Alcotest.(check bool)
        "basis is present" true
        (Option.is_some stored_basis);
      let collision =
        Workspace.write_basis ~root (make_basis ~tree:(identifier 'c') ())
        |> Result.is_error
      in
      Alcotest.(check bool)
        "different basis cannot overwrite the verified marker" true collision;
      let receipt = Workspace.plan_receipt (activated basis) in
      Workspace.write_receipt ~root receipt
      |> require_ok Workspace.error_to_string;
      let changed_basis = make_basis ~tree:(identifier 'c') () in
      let changed_receipt =
        Workspace.plan_update ~basis:(Some changed_basis)
          ~receipt:(Some receipt) ~closure:Workspace.Closure_complete
          ~observed:(observed (identifier 'b'))
          ~replace:false
        |> require_ok Workspace.refusal_to_string
        |> function
        | Workspace.Update plan -> Workspace.plan_receipt plan
        | Workspace.Already_current _ ->
            Alcotest.fail "expected updated receipt"
      in
      Workspace.write_receipt ~root changed_receipt
      |> require_ok Workspace.error_to_string;
      let read_receipt =
        Workspace.read_receipt ~root |> require_ok Workspace.error_to_string
      in
      Alcotest.(check string)
        "atomic replacement has new exact tree" (identifier 'c')
        (read_receipt |> Option.get |> Workspace.receipt_canonical_tree))

let () =
  Alcotest.run "V4 workspace"
    [
      ( "pure transition",
        [
          Alcotest.test_case "activation plans the unique verified tree" `Quick
            activation_plans_the_unique_verified_tree;
          Alcotest.test_case "activation returns typed refusals" `Quick
            activation_returns_every_typed_refusal;
          Alcotest.test_case "clean and dirty update rules" `Quick
            clean_update_is_a_noop_and_dirty_update_requires_explicit_replace;
          Alcotest.test_case "update refusal boundaries" `Quick
            update_refuses_missing_closure_and_incompatible_receipt;
        ] );
      ( "persistent records",
        [
          Alcotest.test_case "canonical golden bytes" `Quick
            persistent_records_have_canonical_golden_bytes;
          Alcotest.test_case "rejects malformed records" `Quick
            records_reject_unknown_noncanonical_and_malformed_input;
          Alcotest.test_case "basis create and receipt replacement" `Quick
            local_records_are_create_only_or_atomic;
        ] );
    ]
