module Health = Yeokcham_v4_health

let require_ok = function
  | Ok value -> value
  | Error refusal -> Alcotest.fail (Health.refusal_to_string refusal)

let id character = String.make 64 character

let missing_report () =
  Health.verify
    [
      Health.Object_observation
        { object_id = id 'a'; status = Health.Missing; references = [] };
    ]
  |> require_ok

let report_is_sorted_and_closure_scoped () =
  let report =
    Health.verify
      [
        Health.Temporary_observation
          {
            temporary_kind = Health.Gc_temporary;
            temporary_id = "gc-run";
            reachable = false;
          };
        Health.Object_observation
          {
            object_id = id 'b';
            status = Health.Present;
            references = [ id 'a' ];
          };
        Health.Durable_observation
          {
            durable_kind = Health.Restore_proof;
            durable_id = "restore-1";
            readable = false;
            restore_mismatch = true;
          };
        Health.Object_observation
          { object_id = id 'a'; status = Health.Missing; references = [] };
      ]
    |> require_ok
  in
  let codes =
    Health.report_damages report
    |> List.map (fun damage ->
        Health.damage_code damage |> Health.damage_code_to_string)
  in
  Alcotest.(check (list string))
    "stable damage order"
    [
      "missing-object";
      "dangling-reference";
      "unreadable-durable-record";
      "restore-proof-mismatch";
      "unreachable-temporary-state";
    ]
    codes;
  Alcotest.(check bool)
    "damage is not globally clean" false
    (Health.report_is_clean report)

let observations_refuse_invalid_or_duplicate_object_identity () =
  let expect_refusal expected = function
    | Error actual ->
        Alcotest.(check bool)
          "typed observation refusal" true (actual = expected)
    | Ok _ -> Alcotest.fail "invalid health observation was accepted"
  in
  Health.verify
    [
      Health.Object_observation
        { object_id = "bad"; status = Health.Missing; references = [] };
    ]
  |> expect_refusal (Health.Invalid_identifier "bad");
  Health.verify
    [
      Health.Object_observation
        { object_id = id 'a'; status = Health.Missing; references = [] };
      Health.Object_observation
        { object_id = id 'a'; status = Health.Present; references = [] };
    ]
  |> expect_refusal (Health.Duplicate_observation (id 'a'))

let expect_outcome_refusal expected = function
  | Health.Refused actual ->
      Alcotest.(check bool) "typed repair refusal" true (actual = expected)
  | Health.Eligible _ -> Alcotest.fail "repair unexpectedly became eligible"

let plan_binds_source_exact_bytes_and_selection () =
  let source = Health.Backup "backup-20260904" in
  let candidate =
    Health.make_candidate ~source ~object_id:(id 'a')
      ~canonical_bytes_id:(id 'a')
    |> require_ok
  in
  let report = missing_report () in
  let plan =
    Health.make_plan ~repository:(id 'd') ~state_head:(id 'e') ~source
      ~damages:(Health.report_damages report)
      ~candidates:[ candidate ] ~created_at:10L ~expires_at:20L
    |> require_ok
  in
  let selection =
    Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
  in
  (match
     Health.apply_eligibility ~plan ~selection ~now:11L ~current:report
       ~reread_candidate:(Some candidate)
   with
  | Health.Eligible selected ->
      Alcotest.(check string)
        "eligible candidate is exact" (id 'a')
        (Health.candidate_bytes_id selected)
  | Health.Refused refusal -> Alcotest.fail (Health.refusal_to_string refusal));
  let wrong_selection : Health.selection =
    {
      Health.selection_plan_id = Health.plan_id plan;
      selection_candidate_id = Health.candidate_id candidate;
      selection_approved_digest = id 'f';
    }
  in
  Health.apply_eligibility ~plan ~selection:wrong_selection ~now:11L
    ~current:report ~reread_candidate:(Some candidate)
  |> expect_outcome_refusal Health.Plan_digest_mismatch;
  let changed =
    Health.make_candidate ~source ~object_id:(id 'a')
      ~canonical_bytes_id:(id 'b')
    |> require_ok
  in
  Health.apply_eligibility ~plan ~selection ~now:11L ~current:report
    ~reread_candidate:(Some changed)
  |> expect_outcome_refusal Health.Candidate_changed

let plans_are_canonical_and_expire () =
  let source = Health.Gc_quarantine "quarantine-1" in
  let candidate =
    Health.make_candidate ~source ~object_id:(id 'a')
      ~canonical_bytes_id:(id 'a')
    |> require_ok
  in
  let report = missing_report () in
  let plan =
    Health.make_plan ~repository:(id 'd') ~state_head:(id 'e') ~source
      ~damages:(Health.report_damages report)
      ~candidates:[ candidate ] ~created_at:0L ~expires_at:2L
    |> require_ok
  in
  let bytes = Health.encode_plan plan in
  let decoded = Health.decode_plan bytes |> require_ok in
  Alcotest.(check string)
    "canonical plan bytes" bytes
    (Health.encode_plan decoded);
  let selection =
    Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
  in
  Health.apply_eligibility ~plan ~selection ~now:2L ~current:report
    ~reread_candidate:(Some candidate)
  |> expect_outcome_refusal Health.Plan_expired

let plans_reject_wrong_version_noncanonical_and_unknown_fields () =
  let source = Health.Gc_quarantine "quarantine-1" in
  let candidate =
    Health.make_candidate ~source ~object_id:(id 'a')
      ~canonical_bytes_id:(id 'a')
    |> require_ok
  in
  let report = missing_report () in
  let plan =
    Health.make_plan ~repository:(id 'd') ~state_head:(id 'e') ~source
      ~damages:(Health.report_damages report)
      ~candidates:[ candidate ] ~created_at:0L ~expires_at:2L
    |> require_ok
  in
  let bytes = Health.encode_plan plan in
  let wrong_version = Bytes.of_string bytes in
  Bytes.set wrong_version 1 '\002';
  let malformed = "\x9f" ^ String.sub bytes 1 (String.length bytes - 1) in
  let unknown_field =
    "\x8a" ^ String.sub bytes 1 (String.length bytes - 1) ^ "\xf6"
  in
  List.iter
    (fun candidate ->
      Alcotest.(check bool)
        "invalid plan encoding refuses" true
        (Result.is_error (Health.decode_plan candidate)))
    [ Bytes.unsafe_to_string wrong_version; malformed; unknown_field ]

let () =
  Alcotest.run "V4 health"
    [
      ( "pure health",
        [
          Alcotest.test_case "sorted closure-scoped diagnosis" `Quick
            report_is_sorted_and_closure_scoped;
          Alcotest.test_case "invalid observations refuse" `Quick
            observations_refuse_invalid_or_duplicate_object_identity;
          Alcotest.test_case "plan binds exact source selection" `Quick
            plan_binds_source_exact_bytes_and_selection;
          Alcotest.test_case "canonical plan expires" `Quick
            plans_are_canonical_and_expire;
          Alcotest.test_case "plan decoder refuses invalid encodings" `Quick
            plans_reject_wrong_version_noncanonical_and_unknown_fields;
        ] );
    ]
