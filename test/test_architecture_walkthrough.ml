let require condition message = if not condition then Alcotest.fail message

let find candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "architecture walkthrough unavailable"

let report () =
  let cwd = Sys.getcwd () in
  find
    [
      Filename.concat cwd "docs/ARCHITECTURE_WALKTHROUGH.md";
      Filename.concat cwd "../docs/ARCHITECTURE_WALKTHROUGH.md";
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

let maps_contracts_and_boundaries () =
  let text = In_channel.with_open_bin (report ()) In_channel.input_all in
  List.iter
    (fun marker ->
      require (contains text marker) ("missing walkthrough marker: " ^ marker))
    [
      "## One model, three histories";
      "Scratch";
      "Intent";
      "Release";
      "## Storage contract";
      "## Functional core and effect boundaries";
      "## Optional analysis and external protocols";
      "## How to read the roadmap";
    ];
  List.iter
    (fun module_name ->
      require (contains text module_name) ("missing module map: " ^ module_name))
    [
      "paengi_snapshot";
      "paengi_capsule";
      "paengi_workspace";
      "paengi_release";
      "paengi_store";
      "paengi_git";
    ];
  require
    (contains text
       "return structured errors before the relevant\nvisibility point")
    "missing structured-failure boundary";
  require
    (contains text "[issue tracking](ISSUE_TRACKING.md)")
    "missing authoritative roadmap link";
  require
    (contains text "not a second backlog")
    "walkthrough duplicates the backlog"

let () =
  Alcotest.run "Architecture walkthrough"
    [
      ( "walkthrough",
        [
          Alcotest.test_case "maps contracts and boundaries" `Quick
            maps_contracts_and_boundaries;
        ] );
    ]
