let require condition message = if not condition then Alcotest.fail message

let find candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "research and benchmark report unavailable"

let report () =
  let cwd = Sys.getcwd () in
  find
    [
      Filename.concat cwd "docs/RESEARCH_AND_BENCHMARK_REPORT.md";
      Filename.concat cwd "../docs/RESEARCH_AND_BENCHMARK_REPORT.md";
    ]

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > text_length then false
    else if String.sub text index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let report_preserves_evidence_and_negative_results () =
  let text = In_channel.with_open_bin (report ()) In_channel.input_all in
  List.iter
    (fun marker ->
      require (contains text marker) ("missing report marker: " ^ marker))
    [
      "## Evidence boundary";
      "[Measured]";
      "[Unverified]";
      "canonical-codec-v1.json";
      "large-content-v1.json";
      "scratch-retention-benchmark-v1.json";
      "semantic-retargeting-v1.json";
      "rust-typescript-retargeting-comparison-v1.json";
      "The TypeScript and Rust comparison records do not contain\n\
       host or run timestamp metadata";
      "## Negative outcomes and limits";
      "Semantic has six false negatives; textual has one";
      "Rust semantic attempts are zero";
      "Storage/restore figures do not predict a user repository or total disk \
       use";
      "not a general safety rate or language-wide semantic guarantee";
      "## Scripted demonstration evidence";
      "does not push, contact GitHub, or make full-Git compatibility\nclaims";
      "## Reproduce and validate";
      "make property-test PROPERTY_TEST_SEED=17";
      "make check";
    ]

let () =
  Alcotest.run "Research and benchmark report"
    [
      ( "report",
        [
          Alcotest.test_case "preserves evidence and negative results" `Quick
            report_preserves_evidence_and_negative_results;
        ] );
    ]
