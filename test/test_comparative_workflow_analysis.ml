let require condition message = if not condition then Alcotest.fail message

let find candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "comparative workflow analysis unavailable"

let report () =
  let cwd = Sys.getcwd () in
  find
    [
      Filename.concat cwd "docs/COMPARATIVE_WORKFLOW_ANALYSIS.md";
      Filename.concat cwd "../docs/COMPARATIVE_WORKFLOW_ANALYSIS.md";
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

let preserves_evidence_boundaries () =
  let text = In_channel.with_open_bin (report ()) In_channel.input_all in
  List.iter
    (fun marker ->
      require (contains text marker) ("missing evidence marker: " ^ marker))
    [
      "[Implemented Paengi fact]";
      "[Documented tool fact]";
      "[Inference]";
      "[Unverified]";
    ];
  List.iter
    (fun source ->
      require (contains text source) ("missing primary source: " ^ source))
    [
      "https://git-scm.com/docs/gitworkflows";
      "https://jj-vcs.github.io/jj/latest/technical/concurrency/";
      "https://pijul.org/manual/conflicts.html";
      "https://docs.gitbutler.com/overview";
    ];
  require
    (contains text "## Interoperability boundary")
    "missing interchange boundary";
  require
    (contains text "## Unsupported cases and errors")
    "missing unsupported-case boundary";
  require
    (contains text
       "does not execute a task in Git, Jujutsu, Pijul, or\nGitButler")
    "report claims an unrun comparison";
  require
    (contains text "not a benchmark or compatibility\nclaim")
    "report lacks performance and compatibility limit"

let () =
  Alcotest.run "Comparative workflow analysis"
    [
      ( "report",
        [
          Alcotest.test_case "preserves evidence boundaries" `Quick
            preserves_evidence_boundaries;
        ] );
    ]
