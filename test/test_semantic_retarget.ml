[@@@warning "-41-42"]

module Retarget = Paengi_semantic_retarget

let span start_byte end_byte = Retarget.{ start_byte; end_byte }

let context selected =
  Retarget.{ before = "before "; selected; after = " after" }

let anchor ?resolved_symbol ?(module_path = "src/source.ts")
    ?(exported_symbol_path = [ "greet" ]) ?(lexical_path = [ "function:greet" ])
    ?(signature_digest = Some "signature") ?(type_shape_digest = Some "shape")
    ?(token_digest = Some "tokens") ?(overload_ordinal = 0) () =
  Retarget.
    {
      operation_id = "fixture-op";
      module_path;
      exported_symbol_path;
      resolved_symbol;
      declaration_kind = "function";
      overload_ordinal;
      signature_digest;
      type_shape_digest;
      lexical_path;
      declaration_shape_digest = "declaration-shape";
      token_digest;
      original_span = span 7 12;
      original_bytes = "greet";
      original_context = context "greet";
    }

let candidate ?resolved_symbol ?(candidate_id = "candidate")
    ?(module_path = "src/source.ts") ?(exported_symbol_path = [ "greet" ])
    ?(lexical_path = [ "function:greet" ])
    ?(signature_digest = Some "signature") ?(type_shape_digest = Some "shape")
    ?(token_digest = Some "tokens") ?(overload_ordinal = 0)
    ?(declaration_span = span 7 12) ?(declaration_bytes = "greet") () =
  Retarget.
    {
      candidate_id;
      module_path;
      exported_symbol_path;
      resolved_symbol;
      declaration_kind = "function";
      overload_ordinal;
      signature_digest;
      type_shape_digest;
      lexical_path;
      declaration_shape_digest = "declaration-shape";
      token_digest;
      declaration_span;
      name_span = Some declaration_span;
      declaration_bytes;
      declaration_context = context declaration_bytes;
      merged_declaration_count = 1;
    }

let complete =
  Retarget.
    {
      parser_complete = true;
      resolution_complete = true;
      type_resolution_complete = true;
    }

let stage result =
  result.Retarget.matching_stage
  |> Option.map Retarget.stage_to_string
  |> Option.value ~default:"none"

let exact_original_bytes_are_exact () =
  let result =
    Retarget.select ~completeness:complete ~anchor:(anchor ())
      ~candidates:[ candidate () ]
  in
  Alcotest.(check string)
    "outcome" "selected"
    (Retarget.outcome_to_string result.Retarget.outcome);
  Alcotest.(check string) "stage" "exact-original-bytes-and-span" (stage result);
  Alcotest.(check string)
    "confidence" "exact"
    (Retarget.confidence_to_string result.Retarget.confidence)

let alias_evidence_is_high_only_when_complete () =
  let result =
    Retarget.select ~completeness:complete
      ~anchor:(anchor ~module_path:"src/old.ts" ~resolved_symbol:"pkg.greet" ())
      ~candidates:
        [
          candidate ~module_path:"src/new.ts" ~resolved_symbol:"pkg.greet"
            ~declaration_span:(span 20 25) ();
        ]
  in
  Alcotest.(check string)
    "alias stage" "resolved-alias-or-symbol" (stage result);
  Alcotest.(check string)
    "high confidence" "high"
    (Retarget.confidence_to_string result.Retarget.confidence);
  Alcotest.(check bool)
    "automatic high is permitted" true
    (Retarget.permits_automatic_application result)

let incomplete_resolution_downgrades_confidence () =
  let incomplete = Retarget.{ complete with resolution_complete = false } in
  let result =
    Retarget.select ~completeness:incomplete
      ~anchor:(anchor ~module_path:"src/old.ts" ~resolved_symbol:"pkg.greet" ())
      ~candidates:
        [
          candidate ~module_path:"src/new.ts" ~resolved_symbol:"pkg.greet"
            ~declaration_span:(span 20 25) ();
        ]
  in
  Alcotest.(check string)
    "uncertain outcome" "uncertain-anchor"
    (Retarget.outcome_to_string result.Retarget.outcome);
  Alcotest.(check bool)
    "incomplete resolution cannot apply high" false
    (Retarget.permits_automatic_application result)

let overload_and_scope_evidence_disambiguate () =
  let result =
    Retarget.select ~completeness:complete
      ~anchor:
        (anchor ~overload_ordinal:1
           ~lexical_path:[ "class:Api"; "method:run" ]
           ())
      ~candidates:
        [
          candidate ~candidate_id:"overload-zero" ~overload_ordinal:0
            ~declaration_span:(span 30 35) ();
          candidate ~candidate_id:"overload-one" ~overload_ordinal:1
            ~lexical_path:[ "class:Api"; "method:run" ]
            ~declaration_span:(span 40 45) ();
        ]
  in
  Alcotest.(check string)
    "selected overload" "selected"
    (Retarget.outcome_to_string result.Retarget.outcome);
  let selected = Option.get result.Retarget.selected_candidate in
  Alcotest.(check string)
    "selected candidate" "overload-one" selected.Retarget.candidate_id

let equivalent_candidates_are_ambiguous_and_reported () =
  let result =
    Retarget.select ~completeness:complete ~anchor:(anchor ())
      ~candidates:
        [
          candidate ~candidate_id:"b" ~declaration_span:(span 20 25) ();
          candidate ~candidate_id:"a" ~declaration_span:(span 30 35) ();
        ]
  in
  Alcotest.(check string)
    "ambiguous" "ambiguous-anchor"
    (Retarget.outcome_to_string result.Retarget.outcome);
  Alcotest.(check int)
    "both reports remain" 2
    (List.length result.Retarget.candidates_considered)

let textual_fallback_is_explicit_low_confidence () =
  let result =
    Retarget.select ~completeness:complete
      ~anchor:
        (anchor ~module_path:"src/old.ts" ~exported_symbol_path:[ "old" ]
           ~lexical_path:[ "old" ] ~signature_digest:(Some "old")
           ~type_shape_digest:(Some "old") ~token_digest:(Some "old") ())
      ~candidates:
        [
          candidate ~module_path:"src/new.ts" ~exported_symbol_path:[ "new" ]
            ~lexical_path:[ "new" ] ~signature_digest:(Some "new")
            ~type_shape_digest:(Some "new") ~token_digest:(Some "new") ();
        ]
  in
  Alcotest.(check string)
    "fallback stage" "exact-textual-fallback" (stage result);
  Alcotest.(check string)
    "fallback confidence" "low"
    (Retarget.confidence_to_string result.Retarget.confidence);
  Alcotest.(check bool)
    "fallback cannot silently apply" false
    (Retarget.permits_automatic_application result)

let () =
  Alcotest.run "semantic retargeting evidence"
    [
      ( "stages",
        [
          Alcotest.test_case "exact original evidence" `Quick
            exact_original_bytes_are_exact;
          Alcotest.test_case "alias evidence" `Quick
            alias_evidence_is_high_only_when_complete;
          Alcotest.test_case "incomplete resolution reduces confidence" `Quick
            incomplete_resolution_downgrades_confidence;
          Alcotest.test_case "overloads and scopes" `Quick
            overload_and_scope_evidence_disambiguate;
          Alcotest.test_case "equivalent candidates conflict" `Quick
            equivalent_candidates_are_ambiguous_and_reported;
          Alcotest.test_case "text fallback stays low" `Quick
            textual_fallback_is_explicit_low_confidence;
        ] );
    ]
