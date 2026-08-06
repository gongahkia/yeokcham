module Semantic = Yeokcham_semantic

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let fixture name =
  let paths =
    [
      Filename.concat "fixtures/semantic" name;
      Filename.concat "test/fixtures/semantic" name;
    ]
  in
  match List.find_opt Sys.file_exists paths with
  | Some path -> In_channel.with_open_bin path In_channel.input_all
  | None -> Alcotest.fail ("missing semantic fixture: " ^ name)

let rename_proposal () =
  Semantic.infer ~path:[ "src"; "greeting.ts" ]
    ~before:(fixture "rename-before.ts")
    ~after:(fixture "rename-after.ts")
  |> require_ok Semantic.inference_error_to_string
  |> function
  | [ proposal ] -> proposal
  | _ -> Alcotest.fail "rename fixture did not infer exactly one proposal"

let parses_supported_top_level_declarations () =
  let source =
    "export interface Profile {\n\
    \  name: string;\n\
     }\n\n\
     type Code = string;\n\n\
     const answer = 42;\n\n\
     function run(): void {}\n"
  in
  let parsed =
    Semantic.parse source |> require_ok Semantic.parse_error_to_string
  in
  Alcotest.(check int)
    "top-level declarations" 4
    (List.length (Semantic.declarations parsed));
  let paths =
    List.map Semantic.declaration_structural_path (Semantic.declarations parsed)
  in
  Alcotest.(check bool)
    "structural paths are unique" true
    (List.length paths = List.length (List.sort_uniq compare paths))

let invalid_source_returns_no_sidecar () =
  let invalid = "function broken(): string { return \"unterminated; }" in
  (match Semantic.parse invalid with
  | Error error ->
      Alcotest.(check bool)
        "unterminated source" true
        (String.starts_with ~prefix:"unterminated string literal"
           (Semantic.parse_error_to_string error))
  | Ok _ -> Alcotest.fail "invalid TypeScript parsed successfully");
  match Semantic.infer ~path:[ "broken.ts" ] ~before:invalid ~after:invalid with
  | Error error ->
      Alcotest.(check bool)
        "inference reports before parse failure" true
        (String.starts_with ~prefix:"before source: unterminated string literal"
           (Semantic.inference_error_to_string error))
  | Ok _ -> Alcotest.fail "parse failure produced a semantic proposal"

let detects_rename_move_and_replace_proposals () =
  let rename = rename_proposal () in
  (match Semantic.proposal_kind rename with
  | Semantic.Rename_declaration { from_name; to_name } ->
      Alcotest.(check string) "rename source" "greet" from_name;
      Alcotest.(check string) "rename target" "welcome" to_name
  | Semantic.Move_declaration _ | Semantic.Replace_declaration _ ->
      Alcotest.fail "rename fixture inferred another operation");
  let move =
    Semantic.infer ~path:[ "move.ts" ] ~before:(fixture "move-before.ts")
      ~after:(fixture "move-after.ts")
    |> require_ok Semantic.inference_error_to_string
  in
  Alcotest.(check bool)
    "detects at least one move" true
    (List.exists
       (fun proposal ->
         match Semantic.proposal_kind proposal with
         | Semantic.Move_declaration _ -> true
         | Semantic.Rename_declaration _ | Semantic.Replace_declaration _ ->
             false)
       move);
  let replace =
    Semantic.infer ~path:[ "replace.ts" ]
      ~before:(fixture "replace-before.ts")
      ~after:(fixture "replace-after.ts")
    |> require_ok Semantic.inference_error_to_string
  in
  Alcotest.(check bool)
    "detects a replacement" true
    (List.exists
       (fun proposal ->
         match Semantic.proposal_kind proposal with
         | Semantic.Replace_declaration _ -> true
         | Semantic.Rename_declaration _ | Semantic.Move_declaration _ -> false)
       replace)

let exact_identity_retargets_a_formatting_change () =
  let proposal = rename_proposal () in
  let target = fixture "rename-retarget.ts" in
  match Semantic.apply ~source:target proposal with
  | Semantic.Applied { applied_source; applied_confidence; _ } ->
      Alcotest.(check string)
        "renamed declaration preserves target bytes"
        "export function welcome(\n\
        \  name: string,\n\
         ): string {\n\
        \  return `hello, ${name}`;\n\
         }\n"
        applied_source;
      Alcotest.(check string)
        "identity confidence" "exact"
        (Semantic.confidence_to_string applied_confidence)
  | Semantic.Application_conflict _ ->
      Alcotest.fail "unique exact identity did not retarget"

let ambiguous_and_low_confidence_matches_are_conflicts () =
  let proposal = rename_proposal () in
  let ambiguous =
    "function greet(name: string): string {\n\
    \  return `hello, ${name}`;\n\
     }\n\n\
     function greet(name: string): string {\n\
    \  return `hello, ${name}`;\n\
     }\n"
  in
  (match Semantic.apply ~source:ambiguous proposal with
  | Semantic.Application_conflict conflict ->
      Alcotest.(check string)
        "ambiguous anchor conflict" "ambiguous-anchor"
        (Semantic.application_conflict_kind_to_string
           conflict.application_conflict_kind)
  | Semantic.Applied _ ->
      Alcotest.fail "multiply matched anchor was not a structured conflict");
  let low_confidence =
    "function other(alpha: string, beta: number): string {\n\
    \  return alpha.repeat(beta);\n\
     }\n"
  in
  match Semantic.apply ~source:low_confidence proposal with
  | Semantic.Application_conflict conflict ->
      Alcotest.(check string)
        "low confidence conflict" "low-confidence-anchor"
        (Semantic.application_conflict_kind_to_string
           conflict.application_conflict_kind)
  | Semantic.Applied _ ->
      Alcotest.fail "low-confidence anchor was not a structured conflict"

let exact_textual_fallback_is_retained_not_automatic () =
  let proposal = rename_proposal () in
  let before = fixture "rename-before.ts" in
  let after = fixture "rename-after.ts" in
  let fallback =
    Semantic.apply_exact_textual_fallback ~source:before proposal
    |> require_ok Semantic.fallback_error_to_string
  in
  Alcotest.(check string) "fallback replays exact bytes" after fallback;
  match
    Semantic.apply_exact_textual_fallback
      ~source:(fixture "rename-retarget.ts")
      proposal
  with
  | Error Semantic.Source_does_not_match_exact_fallback -> ()
  | Ok _ -> Alcotest.fail "fallback silently accepted different target bytes"

let structural_or_replacement_matches_need_manual_review () =
  let proposal = rename_proposal () in
  let structurally_similar =
    "function anotherName(name: string): string {\n\
    \  return `hello, ${name}`;\n\
     }\n"
  in
  match Semantic.apply ~source:structurally_similar proposal with
  | Semantic.Application_conflict conflict ->
      Alcotest.(check string)
        "structural match requires review" "manual-review-required"
        (Semantic.application_conflict_kind_to_string
           conflict.application_conflict_kind)
  | Semantic.Applied _ ->
      Alcotest.fail "structural match silently changed a different declaration"

let changed_literal_never_receives_exact_confidence () =
  let proposal = rename_proposal () in
  let changed_body =
    "export function greet(name: string): string {\n\
    \  return `goodbye, ${name}`;\n\
     }\n"
  in
  match Semantic.apply ~source:changed_body proposal with
  | Semantic.Application_conflict conflict ->
      let kind =
        Semantic.application_conflict_kind_to_string
          conflict.application_conflict_kind
      in
      Alcotest.(check bool)
        "literal change has a nonexact outcome" true
        (String.equal kind "manual-review-required"
        || String.equal kind "low-confidence-anchor")
  | Semantic.Applied _ ->
      Alcotest.fail "changed literal received automatic semantic application"

let () =
  Alcotest.run "semantic sidecar"
    [
      ( "parser",
        [
          Alcotest.test_case "parses supported top-level declarations" `Quick
            parses_supported_top_level_declarations;
          Alcotest.test_case "parse failure produces no sidecar" `Quick
            invalid_source_returns_no_sidecar;
          Alcotest.test_case "detects rename move replace" `Quick
            detects_rename_move_and_replace_proposals;
        ] );
      ( "application",
        [
          Alcotest.test_case "exact identity retargets formatting" `Quick
            exact_identity_retargets_a_formatting_change;
          Alcotest.test_case "ambiguous and low confidence conflict" `Quick
            ambiguous_and_low_confidence_matches_are_conflicts;
          Alcotest.test_case "exact fallback remains explicit" `Quick
            exact_textual_fallback_is_retained_not_automatic;
          Alcotest.test_case "nonexact operations need review" `Quick
            structural_or_replacement_matches_need_manual_review;
          Alcotest.test_case "changed literals need review" `Quick
            changed_literal_never_receives_exact_confidence;
        ] );
    ]
