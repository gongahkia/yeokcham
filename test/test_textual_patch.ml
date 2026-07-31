module Patch = Paengi_textual_patch

let require_ok = function
  | Ok value -> value
  | Error message -> Alcotest.fail message

let operation ?(before_context = "") ?(after_context = "")
    ?(relaxed_context_bytes = Patch.default_relaxed_context_bytes) ~start_byte
    ~expected ~replacement () =
  Patch.make
    ~original_span:
      { Patch.start_byte; end_byte = start_byte + String.length expected }
    ~expected_preimage:expected ~replacement ~before_context ~after_context
    ~relaxed_context_bytes
  |> require_ok

let exact_original_span_applies () =
  let source = "left\000selected\255right" in
  let patch =
    operation ~start_byte:5 ~expected:"selected" ~replacement:"done" ()
  in
  match Patch.apply ~source patch with
  | Patch.Applied applied ->
      Alcotest.(check string)
        "stage" "exact-original-span"
        (Patch.stage_to_string applied.stage);
      Alcotest.(check string)
        "exact bytes" "left\000done\255right" applied.contents;
      Alcotest.(check int)
        "selected start" 5 applied.selected_span.Patch.start_byte
  | Patch.Already_satisfied _ | Patch.Conflict _ ->
      Alcotest.fail "exact original span did not apply"

let unique_preimage_retargets_elsewhere () =
  let source = "prefix target suffix" in
  let patch =
    operation ~start_byte:0 ~expected:"target" ~replacement:"done" ()
  in
  match Patch.apply ~source patch with
  | Patch.Applied applied ->
      Alcotest.(check string)
        "stage" "unique-exact-preimage"
        (Patch.stage_to_string applied.stage);
      Alcotest.(check string)
        "retargeted exact bytes" "prefix done suffix" applied.contents
  | Patch.Already_satisfied _ | Patch.Conflict _ ->
      Alcotest.fail "unique exact preimage did not apply"

let full_context_selects_one_duplicate () =
  let source = "bad SELECT wrong -- before SELECT after" in
  let patch =
    operation ~start_byte:0 ~expected:"SELECT" ~replacement:"DONE"
      ~before_context:"before " ~after_context:" after" ()
  in
  match Patch.apply ~source patch with
  | Patch.Applied applied ->
      Alcotest.(check string)
        "stage" "unique-full-context"
        (Patch.stage_to_string applied.stage);
      Alcotest.(check string)
        "only contextual candidate changes"
        "bad SELECT wrong -- before DONE after" applied.contents
  | Patch.Already_satisfied _ | Patch.Conflict _ ->
      Alcotest.fail "unique full context did not apply"

let bounded_relaxation_is_deterministic () =
  let source = "BADSELECTABCDEFGH--00005678SELECTABCDEFGH" in
  let patch =
    operation ~start_byte:0 ~expected:"SELECT" ~replacement:"DONE"
      ~before_context:"12345678" ~after_context:"ABCDEFGH"
      ~relaxed_context_bytes:[ 4 ] ()
  in
  match Patch.apply ~source patch with
  | Patch.Applied applied ->
      Alcotest.(check string)
        "stage" "relaxed-context-4"
        (Patch.stage_to_string applied.stage);
      Alcotest.(check string)
        "only near context candidate changes"
        "BADSELECTABCDEFGH--00005678DONEABCDEFGH" applied.contents
  | Patch.Already_satisfied _ | Patch.Conflict _ ->
      Alcotest.fail "bounded relaxation did not apply deterministically"

let missing_and_ambiguous_are_structured () =
  let missing =
    operation ~start_byte:0 ~expected:"needle" ~replacement:"done" ()
  in
  (match Patch.apply ~source:"haystack" missing with
  | Patch.Conflict conflict ->
      Alcotest.(check string)
        "missing conflict" "missing-match"
        (Patch.conflict_kind_to_string conflict.Patch.conflict_kind)
  | Patch.Applied _ | Patch.Already_satisfied _ ->
      Alcotest.fail "missing match did not conflict");
  let ambiguous =
    operation ~start_byte:20 ~expected:"same" ~replacement:"done" ()
  in
  match Patch.apply ~source:"same and same" ambiguous with
  | Patch.Conflict conflict ->
      Alcotest.(check string)
        "ambiguous conflict" "ambiguous-match"
        (Patch.conflict_kind_to_string conflict.Patch.conflict_kind);
      Alcotest.(check int)
        "candidates remain inspectable" 2
        (List.length conflict.Patch.conflict_candidates)
  | Patch.Applied _ | Patch.Already_satisfied _ ->
      Alcotest.fail "ambiguous match did not preserve candidate conflict"

let byte_splice_preserves_all_other_bytes () =
  let source = "\239\187\191\r\n😀\255before\nTOKEN\r\nafter\000" in
  let start_byte = String.index source 'T' in
  let patch =
    operation ~start_byte ~expected:"TOKEN" ~replacement:"REPLACED" ()
  in
  match Patch.apply ~source patch with
  | Patch.Applied { contents; selected_span; _ } ->
      Alcotest.(check bool)
        "outside bytes are identical" true
        (Patch.validates_splice ~source ~selected_span
           ~expected_preimage:"TOKEN" ~replacement:"REPLACED" ~output:contents);
      Alcotest.(check string)
        "prefix remains arbitrary bytes"
        (String.sub source 0 start_byte)
        (String.sub contents 0 start_byte)
  | Patch.Already_satisfied _ | Patch.Conflict _ ->
      Alcotest.fail "binary-safe splice did not apply"

let () =
  Alcotest.run "textual patch"
    [
      ( "matching",
        [
          Alcotest.test_case "exact original span" `Quick
            exact_original_span_applies;
          Alcotest.test_case "unique exact preimage" `Quick
            unique_preimage_retargets_elsewhere;
          Alcotest.test_case "unique full byte context" `Quick
            full_context_selects_one_duplicate;
          Alcotest.test_case "bounded context relaxation" `Quick
            bounded_relaxation_is_deterministic;
          Alcotest.test_case "missing and ambiguous conflicts" `Quick
            missing_and_ambiguous_are_structured;
        ] );
      ( "integrity",
        [
          Alcotest.test_case "byte splice invariance" `Quick
            byte_splice_preserves_all_other_bytes;
        ] );
    ]
