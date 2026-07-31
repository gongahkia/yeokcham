[@@@warning "-41-42"]

module Retarget = Paengi_semantic_retarget

let default_seed = 20_260_731

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let () = Printf.printf "semantic retarget property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]
let span start_byte = Retarget.{ start_byte; end_byte = start_byte + 5 }

let context =
  Retarget.{ before = "before"; selected = "greet"; after = "after" }

let anchor =
  Retarget.
    {
      operation_id = "generated";
      module_path = "src/generated.ts";
      exported_symbol_path = [ "greet" ];
      resolved_symbol = Some "generated.greet";
      declaration_kind = "function";
      overload_ordinal = 0;
      signature_digest = Some "signature";
      type_shape_digest = Some "shape";
      lexical_path = [ "top-level"; "function:greet" ];
      declaration_shape_digest = "shape";
      token_digest = Some "token";
      original_span = span 7;
      original_bytes = "greet";
      original_context = context;
    }

let candidate id start_byte =
  Retarget.
    {
      candidate_id = id;
      module_path = "src/generated.ts";
      exported_symbol_path = [ "greet" ];
      resolved_symbol = Some "generated.greet";
      declaration_kind = "function";
      overload_ordinal = 0;
      signature_digest = Some "signature";
      type_shape_digest = Some "shape";
      lexical_path = [ "top-level"; "function:greet" ];
      declaration_shape_digest = "shape";
      token_digest = Some "token";
      declaration_span = span start_byte;
      name_span = Some (span start_byte);
      declaration_bytes = "greet";
      declaration_context = context;
      merged_declaration_count = 1;
    }

let complete =
  Retarget.
    {
      parser_complete = true;
      resolution_complete = true;
      type_resolution_complete = true;
    }

let duplicate_evidence_never_auto_applies =
  QCheck2.Test.make ~count:100
    ~name:"equivalent generated semantic evidence remains ambiguous"
    QCheck2.Gen.(pair (int_range 20 400) (int_range 401 800))
    (fun (left, right) ->
      let result =
        Retarget.select ~completeness:complete ~anchor
          ~candidates:[ candidate "left" left; candidate "right" right ]
      in
      String.equal "ambiguous-anchor"
        (Retarget.outcome_to_string result.Retarget.outcome)
      && not (Retarget.permits_automatic_application result))

let incomplete_evidence_never_reports_high =
  QCheck2.Test.make ~count:100
    ~name:"incomplete generated resolution cannot report high automatic success"
    QCheck2.Gen.(int_range 20 800)
    (fun start_byte ->
      let incomplete = Retarget.{ complete with resolution_complete = false } in
      let result =
        Retarget.select ~completeness:incomplete ~anchor
          ~candidates:[ candidate "only" start_byte ]
      in
      (not (Retarget.permits_automatic_application result))
      && not
           (String.equal "high"
              (Retarget.confidence_to_string result.Retarget.confidence)))

let () =
  Alcotest.run "semantic retarget properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "duplicates") duplicate_evidence_never_auto_applies;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "incomplete")
            incomplete_evidence_never_reports_high;
        ] );
    ]
