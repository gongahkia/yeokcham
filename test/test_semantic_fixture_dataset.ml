module Dataset = Paengi_semantic_fixtures
module Patch = Paengi_textual_patch
module Retarget = Paengi_semantic_retarget

let required_categories =
  [
    "function rename";
    "function move within one file";
    "function move across files";
    "class rename";
    "method rename";
    "method move";
    "module reorganisation";
    "named exports";
    "default exports";
    "re-export aliases";
    "imports and aliases";
    "overloads";
    "merged declarations";
    "namespaces";
    "generic functions and methods";
    "decorators";
    "arrow functions assigned to names";
    "nested declarations";
    "same-name declarations in different scopes";
    "duplicate highly similar declarations";
    "nearby unrelated insertion";
    "formatting-only changes";
    "comment and documentation changes";
    "CRLF";
    "LF";
    "UTF-8 BOM";
    "Unicode identifiers and strings";
    "emoji before declaration spans";
    "TSX functions and components";
    "JSX text and attributes";
    "changed function signatures";
    "function split";
    "function merge";
    "parse-damaged source";
    "unresolved imports";
    "tsconfig path mappings";
    "deliberately ambiguous targets";
    "missing target";
    "already-satisfied change";
    "binary or non-TypeScript textual-only behaviour";
  ]

let dataset_is_versioned_and_complete () =
  Alcotest.(check int) "dataset version" 1 Dataset.version;
  Alcotest.(check bool)
    "at least forty fixtures" true
    (List.length Dataset.all >= 40);
  let categories =
    List.map (fun fixture -> fixture.Dataset.category) Dataset.all
  in
  List.iter
    (fun category ->
      Alcotest.(check bool)
        ("category " ^ category) true
        (List.mem category categories))
    required_categories;
  let ids = List.map (fun fixture -> fixture.Dataset.fixture_id) Dataset.all in
  Alcotest.(check int)
    "stable ids are unique" (List.length ids)
    (List.length (List.sort_uniq String.compare ids))

let both_strategies_receive_shared_bytes_and_oracles () =
  List.iter
    (fun fixture ->
      let target = Dataset.target_bytes fixture in
      let patch = Dataset.textual_patch fixture |> Result.get_ok in
      let textual_operation : Dataset.textual_operation =
        fixture.Dataset.textual_operation
      in
      ignore (Patch.apply ~source:target patch);
      let semantic = Dataset.semantic_result fixture in
      Alcotest.(check string)
        (fixture.Dataset.fixture_id ^ " operation id")
        fixture.Dataset.operation_id semantic.Retarget.operation_id;
      Alcotest.(check bool)
        (fixture.Dataset.fixture_id ^ " target present")
        true
        (List.mem_assoc fixture.Dataset.target_path
           fixture.Dataset.retarget_base);
      match fixture.Dataset.expected_outcome with
      | Dataset.Exact_bytes expected -> (
          Alcotest.(check bool)
            (fixture.Dataset.fixture_id ^ " oracle bytes")
            true
            (String.length expected > 0);
          match fixture.Dataset.expected_target_span with
          | Some selected_span ->
              Alcotest.(check bool)
                (fixture.Dataset.fixture_id ^ " oracle is exact byte splice")
                true
                (Patch.validates_splice ~source:target ~selected_span
                   ~expected_preimage:textual_operation.Dataset.expected_preimage
                   ~replacement:textual_operation.Dataset.replacement
                   ~output:expected)
          | None ->
              Alcotest.(check string)
                (fixture.Dataset.fixture_id ^ " already-satisfied oracle")
                target expected)
      | Dataset.Safe_conflict ->
          Alcotest.(check bool)
            (fixture.Dataset.fixture_id ^ " conflict has no target span") true
            (Option.is_none fixture.Dataset.expected_target_span);
      let semantic = Dataset.semantic_result fixture in
      Alcotest.(check bool)
        (fixture.Dataset.fixture_id ^ " parser expectation")
        fixture.Dataset.parser_complete semantic.Retarget.parser_complete;
      Alcotest.(check bool)
        (fixture.Dataset.fixture_id ^ " resolution expectation")
        fixture.Dataset.resolution_complete semantic.Retarget.resolution_complete;
      Alcotest.(check bool)
        (fixture.Dataset.fixture_id ^ " type resolution expectation")
        fixture.Dataset.type_resolution_complete
        semantic.Retarget.type_resolution_complete)
    Dataset.all

let confidence_rank confidence =
  match Retarget.confidence_to_string confidence with
  | "unknown" -> 0
  | "low" -> 1
  | "medium" -> 2
  | "high" -> 3
  | "exact" -> 4
  | _ -> assert false

let fixture_confidence_ceilings_are_respected () =
  List.iter
    (fun fixture ->
      let result = Dataset.semantic_result fixture in
      Alcotest.(check bool)
        (fixture.Dataset.fixture_id ^ " confidence ceiling") true
        (confidence_rank result.Retarget.confidence
        <= confidence_rank fixture.Dataset.acceptable_confidence_ceiling))
    Dataset.all

let adversarial_semantic_matches_never_auto_apply () =
  [ "duplicate-highly-similar"; "deliberately-ambiguous" ]
  |> List.iter (fun fixture_id ->
      let fixture = Dataset.find fixture_id |> Option.get in
      let result = Dataset.semantic_result fixture in
      Alcotest.(check bool)
        (fixture_id ^ " cannot auto apply")
        false
        (Retarget.permits_automatic_application result))

let lexical_scope_evidence_beats_duplicate_text () =
  let fixture = Dataset.find "same-name-different-scopes" |> Option.get in
  let result = Dataset.semantic_result fixture in
  Alcotest.(check bool)
    "semantic scope evidence applies" true
    (Retarget.permits_automatic_application result)

let () =
  Alcotest.run "semantic retargeting fixture dataset"
    [
      ( "dataset",
        [
          Alcotest.test_case "versioned categories and ids" `Quick
            dataset_is_versioned_and_complete;
          Alcotest.test_case "shared strategy inputs and oracles" `Quick
            both_strategies_receive_shared_bytes_and_oracles;
          Alcotest.test_case "oracle confidence ceilings" `Quick
            fixture_confidence_ceilings_are_respected;
          Alcotest.test_case "adversarial confidence gate" `Quick
            adversarial_semantic_matches_never_auto_apply;
          Alcotest.test_case "lexical scope disambiguation" `Quick
            lexical_scope_evidence_beats_duplicate_text;
        ] );
    ]
