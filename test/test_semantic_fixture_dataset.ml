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
      | Dataset.Exact_bytes expected ->
          Alcotest.(check bool)
            (fixture.Dataset.fixture_id ^ " oracle bytes")
            true
            (String.length expected > 0)
      | Dataset.Safe_conflict -> ())
    Dataset.all

let adversarial_semantic_matches_never_auto_apply () =
  [
    "same-name-different-scopes";
    "duplicate-highly-similar";
    "deliberately-ambiguous";
  ]
  |> List.iter (fun fixture_id ->
      let fixture = Dataset.find fixture_id |> Option.get in
      let result = Dataset.semantic_result fixture in
      Alcotest.(check bool)
        (fixture_id ^ " cannot auto apply")
        false
        (Retarget.permits_automatic_application result))

let () =
  Alcotest.run "semantic retargeting fixture dataset"
    [
      ( "dataset",
        [
          Alcotest.test_case "versioned categories and ids" `Quick
            dataset_is_versioned_and_complete;
          Alcotest.test_case "shared strategy inputs and oracles" `Quick
            both_strategies_receive_shared_bytes_and_oracles;
          Alcotest.test_case "adversarial confidence gate" `Quick
            adversarial_semantic_matches_never_auto_apply;
        ] );
    ]
