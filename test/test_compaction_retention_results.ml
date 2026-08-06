let require condition message = if not condition then Alcotest.fail message

let find candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "compaction retention result report unavailable"

let report () =
  let cwd = Sys.getcwd () in
  find
    [
      Filename.concat cwd "docs/COMPACTION_RETENTION_RESULTS.md";
      Filename.concat cwd "../docs/COMPACTION_RETENTION_RESULTS.md";
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

let report_links_evidence_and_limits_claims () =
  let text = In_channel.with_open_bin (report ()) In_channel.input_all in
  List.iter
    (fun marker ->
      require (contains text marker) ("missing report marker: " ^ marker))
    [
      "scratch-retention-benchmark-v1.json";
      "scratch-retention-benchmark-v1.schema.json";
      "## Recorded environment";
      "five measured repetitions";
      "active_object_store_bytes";
      "max_physical_event_depth";
      "median_restore_ns";
      "restored_pinned_target: true";
      "[Measurement]";
      "[Inference]";
      "not a general causal, workload, or cross-host claim";
      "## Limits and unsupported cases";
      "does not measure exponential thinning";
    ];
  List.iter
    (fun value ->
      require (contains text value) ("missing recorded metric: " ^ value))
    [ "20,628"; "10,956"; "13,003"; "12,040"; "14,883,995"; "7,522,821" ]

let () =
  Alcotest.run "Compaction retention results"
    [
      ( "report",
        [
          Alcotest.test_case "links evidence and limits claims" `Quick
            report_links_evidence_and_limits_claims;
        ] );
    ]
