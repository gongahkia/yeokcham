module Semantic = Paengi_semantic

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

let () = Printf.printf "semantic property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let rename_preserves_retarget_bytes =
  QCheck2.Test.make ~count:100
    ~name:"exact declaration identity retargets generated formatting changes"
    QCheck2.Gen.(pair (int_range 0 9999) bool)
    (fun (value, multiline) ->
      let before =
        Printf.sprintf
          "function original(value: number): number { return value + %d; }\n"
          value
      in
      let after =
        Printf.sprintf
          "function renamed(value: number): number { return value + %d; }\n"
          value
      in
      let target, expected =
        if multiline then
          ( Printf.sprintf
              "function original(\n\
              \  value: number,\n\
               ): number {\n\
              \  return value + %d;\n\
               }\n"
              value,
            Printf.sprintf
              "function renamed(\n\
              \  value: number,\n\
               ): number {\n\
              \  return value + %d;\n\
               }\n"
              value )
        else
          ( Printf.sprintf
              "function original(value:number):number{\n\
              \  return value + %d;\n\
               }\n"
              value,
            Printf.sprintf
              "function renamed(value:number):number{\n\
              \  return value + %d;\n\
               }\n"
              value )
      in
      match Semantic.infer ~path:[ "generated.ts" ] ~before ~after with
      | Error _ -> false
      | Ok [ proposal ] -> (
          match Semantic.apply ~source:target proposal with
          | Semantic.Applied applied ->
              String.equal "exact"
                (Semantic.confidence_to_string applied.applied_confidence)
              && String.equal expected applied.applied_source
          | Semantic.Application_conflict _ -> false)
      | Ok _ -> false)

let duplicate_exact_identities_never_apply =
  QCheck2.Test.make ~count:100
    ~name:"multiple exact declaration identities always become conflicts"
    QCheck2.Gen.(int_range 0 9999)
    (fun value ->
      let before =
        Printf.sprintf "function original(): number { return %d; }\n" value
      in
      let after =
        Printf.sprintf "function renamed(): number { return %d; }\n" value
      in
      let target =
        Printf.sprintf
          "function original(): number { return %d; }\n\
           function original(): number { return %d; }\n"
          value value
      in
      match Semantic.infer ~path:[ "duplicate.ts" ] ~before ~after with
      | Ok [ proposal ] -> (
          match Semantic.apply ~source:target proposal with
          | Semantic.Application_conflict conflict ->
              String.equal "ambiguous-anchor"
                (Semantic.application_conflict_kind_to_string
                   conflict.application_conflict_kind)
          | Semantic.Applied _ -> false)
      | Error _ | Ok _ -> false)

let () =
  Alcotest.run "semantic properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "retarget") rename_preserves_retarget_bytes;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "duplicates")
            duplicate_exact_identities_never_apply;
        ] );
    ]
