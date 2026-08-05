module Adapter = Paengi_rust_adapter
module Dataset = Paengi_rust_fixtures
module Patch = Paengi_textual_patch

let adapter_path () =
  match Sys.getenv_opt "PAENGI_RUST_ADAPTER" with
  | Some path when Sys.file_exists path -> path
  | Some _ | None -> (
      [
        "tools/paengi-rust-adapter/target/release/paengi-rust-adapter";
        "../tools/paengi-rust-adapter/target/release/paengi-rust-adapter";
      ]
      |> List.find_opt Sys.file_exists
      |> function
      | Some path -> path
      | None -> Alcotest.fail "missing built Rust adapter")

let configuration =
  Adapter.configuration_with ~adapter_path:(adapter_path ())
    Adapter.default_configuration

let snapshot_id = String.make 64 '3'

let source_files fixture =
  fixture.Dataset.retarget_base
  |> List.map (fun (path, contents) ->
      Adapter.Protocol.make_source_file ~path ~contents)

let sorted_unique strings = List.sort_uniq String.compare strings

let dataset_is_canonical_and_bounded () =
  Alcotest.(check int) "dataset version" 1 Dataset.version;
  Alcotest.(check int) "fixture count" 6 (List.length Dataset.all);
  let ids = List.map (fun fixture -> fixture.Dataset.fixture_id) Dataset.all in
  Alcotest.(check bool)
    "fixture ids are canonical" true
    (ids = List.sort String.compare ids
    && List.length ids = List.length (sorted_unique ids));
  List.iter
    (fun fixture ->
      Alcotest.(check int)
        (fixture.Dataset.fixture_id ^ " dataset version")
        Dataset.version fixture.Dataset.dataset_version;
      Alcotest.(check bool)
        (fixture.Dataset.fixture_id ^ " bounded source map")
        true
        (List.length fixture.Dataset.retarget_base <= 16
        && List.for_all
             (fun (path, contents) ->
               String.ends_with ~suffix:".rs" path
               && String.length contents <= 64 * 1024)
             fixture.Dataset.retarget_base))
    Dataset.all

let byte_oracles_are_exact_or_conflicts () =
  List.iter
    (fun fixture ->
      let target = Dataset.target_bytes fixture in
      let operation = Dataset.textual_patch fixture |> Result.get_ok in
      let textual : Dataset.textual_operation =
        fixture.Dataset.textual_operation
      in
      match fixture.Dataset.expected_outcome with
      | Dataset.Exact_textual_bytes expected -> (
          match Patch.apply ~source:target operation with
          | Patch.Applied applied ->
              Alcotest.(check string)
                (fixture.Dataset.fixture_id ^ " exact byte oracle")
                expected applied.contents;
              let expected_span =
                fixture.Dataset.expected_target_span |> Option.get
              in
              Alcotest.(check int)
                (fixture.Dataset.fixture_id ^ " exact target start")
                expected_span.Patch.start_byte
                applied.selected_span.Patch.start_byte;
              Alcotest.(check bool)
                (fixture.Dataset.fixture_id ^ " splice is byte-local")
                true
                (Patch.validates_splice ~source:target
                   ~selected_span:applied.selected_span
                   ~expected_preimage:textual.Dataset.expected_preimage
                   ~replacement:textual.Dataset.replacement ~output:expected)
          | Patch.Already_satisfied _ | Patch.Conflict _ ->
              Alcotest.fail (fixture.Dataset.fixture_id ^ " did not apply"))
      | Dataset.Safe_conflict -> (
          match Patch.apply ~source:target operation with
          | Patch.Conflict _ -> ()
          | Patch.Applied _ | Patch.Already_satisfied _ ->
              Alcotest.fail (fixture.Dataset.fixture_id ^ " did not conflict")))
    Dataset.all

let fallback_observations_match_fixture_oracles () =
  List.iter
    (fun fixture ->
      match
        Adapter.inspect_fallback_files configuration ~snapshot_id
          ~files:(source_files fixture)
      with
      | Adapter.Unavailable reason ->
          Alcotest.fail
            (fixture.Dataset.fixture_id ^ ": "
            ^ Adapter.unavailable_reason_to_string reason)
      | Adapter.Available assessment ->
          let expected : Dataset.fallback_expectation =
            fixture.Dataset.fallback_expectation
          in
          Alcotest.(check bool)
            (fixture.Dataset.fixture_id ^ " parser completeness")
            expected.Dataset.parser_complete
            (Adapter.Protocol.fallback_assessment_parser_complete assessment);
          Alcotest.(check bool)
            (fixture.Dataset.fixture_id ^ " fallback requirement")
            expected.Dataset.textual_fallback_required
            (Adapter.Protocol.fallback_assessment_textual_fallback_required
               assessment);
          Alcotest.(check (list string))
            (fixture.Dataset.fixture_id ^ " fallback syntax kinds")
            (sorted_unique expected.Dataset.fallback_syntax_kinds)
            (Adapter.Protocol.fallback_assessment_facts assessment
            |> List.map Adapter.Protocol.fallback_fact_syntax_kind
            |> sorted_unique))
    Dataset.all

let standard_module_observations_match_fixture_oracles () =
  Dataset.all
  |> List.iter (fun fixture ->
      match fixture.Dataset.module_expectation with
      | None -> ()
      | Some expected -> (
          match
            Adapter.resolve_module_paths_files configuration ~snapshot_id
              ~root_files:expected.Dataset.root_files
              ~files:(source_files fixture)
          with
          | Adapter.Unavailable reason ->
              Alcotest.fail
                (fixture.Dataset.fixture_id ^ ": "
                ^ Adapter.unavailable_reason_to_string reason)
          | Adapter.Available analysis ->
              Alcotest.(check bool)
                (fixture.Dataset.fixture_id ^ " module completeness")
                expected.Dataset.module_paths_complete
                (Adapter.Protocol.module_path_analysis_complete analysis);
              Alcotest.(check (list string))
                (fixture.Dataset.fixture_id ^ " module statuses")
                (List.sort String.compare expected.Dataset.module_statuses)
                (Adapter.Protocol.module_path_analysis_module_facts analysis
                |> List.map Adapter.Protocol.module_fact_status
                |> List.sort String.compare)))

let fallback_cases_remain_textual_only () =
  [ "macro-heavy-textual-fallback"; "parser-damaged-textual-fallback" ]
  |> List.iter (fun fixture_id ->
      let fixture = Dataset.find fixture_id |> Option.get in
      match
        (fixture.Dataset.expected_outcome, Dataset.textual_patch fixture)
      with
      | Dataset.Exact_textual_bytes expected, Ok operation -> (
          match
            Patch.apply ~source:(Dataset.target_bytes fixture) operation
          with
          | Patch.Applied applied ->
              Alcotest.(check string)
                (fixture_id ^ " preserves independent text oracle")
                expected applied.contents
          | Patch.Already_satisfied _ | Patch.Conflict _ ->
              Alcotest.fail (fixture_id ^ " lost textual fallback"))
      | Dataset.Safe_conflict, _ | Dataset.Exact_textual_bytes _, Error _ ->
          Alcotest.fail (fixture_id ^ " has invalid fallback fixture"))

let () =
  Alcotest.run "Rust retarget fixtures"
    [
      ( "dataset",
        [
          Alcotest.test_case "canonical bounded fixture set" `Quick
            dataset_is_canonical_and_bounded;
          Alcotest.test_case "exact bytes or structured conflict" `Quick
            byte_oracles_are_exact_or_conflicts;
          Alcotest.test_case "fallback observations match" `Quick
            fallback_observations_match_fixture_oracles;
          Alcotest.test_case "standard module observations match" `Quick
            standard_module_observations_match_fixture_oracles;
          Alcotest.test_case "fallback stays independently textual" `Quick
            fallback_cases_remain_textual_only;
        ] );
    ]
