[@@@warning "-41-42"]

module Retarget = Yeokcham_semantic_retarget
module Patch = Yeokcham_textual_patch

let span start_byte end_byte = Retarget.{ start_byte; end_byte }

let context selected =
  Retarget.{ before = "before "; selected; after = " after" }

let anchor ?resolved_symbol ?(module_path = "src/source.ts")
    ?(exported_symbol_path = [ "greet" ]) ?(lexical_path = [ "function:greet" ])
    ?(signature_digest = Some "signature") ?(type_shape_digest = Some "shape")
    ?(token_digest = Some "tokens") () =
  Retarget.
    {
      operation_id = "demo-retarget";
      module_path;
      exported_symbol_path;
      resolved_symbol;
      declaration_kind = "function";
      overload_ordinal = 0;
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
    ?(token_digest = Some "tokens") ?(declaration_span = span 7 12)
    ?(declaration_bytes = "greet") () =
  Retarget.
    {
      candidate_id;
      module_path;
      exported_symbol_path;
      resolved_symbol;
      declaration_kind = "function";
      overload_ordinal = 0;
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

let semantic_stage result =
  result.Retarget.matching_stage
  |> Option.map Retarget.stage_to_string
  |> Option.value ~default:"none"

let print_semantic name result =
  Printf.printf
    "semantic case=%s outcome=%s stage=%s confidence=%s automatic=%b \
     fallback=%b candidates=%d\n"
    name
    (Retarget.outcome_to_string result.Retarget.outcome)
    (semantic_stage result)
    (Retarget.confidence_to_string result.Retarget.confidence)
    (Retarget.permits_automatic_application result)
    result.Retarget.textual_fallback_used
    (List.length result.Retarget.candidates_considered)

let print_patch name = function
  | Patch.Applied applied ->
      Printf.printf "textual case=%s outcome=applied stage=%s bytes=%s\n" name
        (Patch.stage_to_string applied.stage)
        applied.contents
  | Patch.Already_satisfied applied ->
      Printf.printf "textual case=%s outcome=already-satisfied stage=%s\n" name
        (Patch.stage_to_string applied.stage)
  | Patch.Conflict conflict ->
      let stage =
        conflict.Patch.conflict_stage
        |> Option.map Patch.stage_to_string
        |> Option.value ~default:"none"
      in
      Printf.printf
        "textual case=%s outcome=conflict kind=%s stage=%s candidates=%d\n" name
        (Patch.conflict_kind_to_string conflict.Patch.conflict_kind)
        stage
        (List.length conflict.Patch.conflict_candidates)

let patch ~start_byte ~expected ~replacement =
  Patch.make
    ~original_span:
      Patch.{ start_byte; end_byte = start_byte + String.length expected }
    ~expected_preimage:expected ~replacement ~before_context:""
    ~after_context:"" ~relaxed_context_bytes:[]

let run_patch name source operation =
  match operation with
  | Ok operation -> Patch.apply ~source operation |> print_patch name
  | Error error ->
      Printf.printf "textual case=%s outcome=rejected error=%s\n" name error

let () =
  let incomplete = Retarget.{ complete with resolution_complete = false } in
  Retarget.select ~completeness:incomplete
    ~anchor:(anchor ~module_path:"src/old.ts" ~resolved_symbol:"pkg.greet" ())
    ~candidates:
      [
        candidate ~module_path:"src/new.ts" ~resolved_symbol:"pkg.greet"
          ~declaration_span:(span 20 25) ();
      ]
  |> print_semantic "incomplete-alias";
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
  |> print_semantic "exact-textual-fallback";
  Retarget.select ~completeness:complete ~anchor:(anchor ())
    ~candidates:
      [
        candidate ~candidate_id:"a" ~declaration_span:(span 20 25) ();
        candidate ~candidate_id:"b" ~declaration_span:(span 30 35) ();
      ]
  |> print_semantic "ambiguity";
  run_patch "unique-preimage" "prefix target suffix"
    (patch ~start_byte:0 ~expected:"target" ~replacement:"done");
  run_patch "ambiguity" "same and same"
    (patch ~start_byte:20 ~expected:"same" ~replacement:"done");
  Patch.make
    ~original_span:Patch.{ start_byte = 4; end_byte = 3 }
    ~expected_preimage:"x" ~replacement:"done" ~before_context:""
    ~after_context:"" ~relaxed_context_bytes:[]
  |> run_patch "invalid-operation" "irrelevant"
