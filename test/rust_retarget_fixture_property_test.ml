module Adapter = Yeokcham_rust_adapter
module Dataset = Yeokcham_rust_fixtures
module Patch = Yeokcham_textual_patch

let default_seed = 20_260_805

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let adapter_path () =
  match Sys.getenv_opt "YEOKCHAM_RUST_ADAPTER" with
  | Some path when Sys.file_exists path -> path
  | Some _ | None ->
      "tools/yeokcham-rust-adapter/target/release/yeokcham-rust-adapter"

let configuration =
  Adapter.configuration_with ~adapter_path:(adapter_path ())
    Adapter.default_configuration

let snapshot_id = String.make 64 '4'

let generated_renames_preserve_exact_byte_oracles =
  QCheck2.Test.make ~count:40
    ~name:
      "generated Rust rename shifts retain exact byte oracle and no fallback"
    QCheck2.Gen.(int_range 0 32)
    (fun prefix_lines ->
      let fixture = Dataset.find "rename-after-insertion" |> Option.get in
      let target =
        String.concat "" (List.init prefix_lines (fun _ -> "// filler\n"))
        ^ "pub fn greet(value: &str) -> &str { value }\n"
      in
      let expected =
        String.concat "" (List.init prefix_lines (fun _ -> "// filler\n"))
        ^ "pub fn welcome(value: &str) -> &str { value }\n"
      in
      match Dataset.textual_patch fixture with
      | Error _ -> false
      | Ok operation -> (
          match
            ( Patch.apply ~source:target operation,
              Adapter.inspect_fallback_files configuration ~snapshot_id
                ~files:
                  [
                    Adapter.Protocol.make_source_file ~path:"src/lib.rs"
                      ~contents:target;
                  ] )
          with
          | Patch.Applied applied, Adapter.Available assessment ->
              String.equal expected applied.contents
              && Adapter.Protocol.fallback_assessment_parser_complete assessment
              && (not
                    (Adapter.Protocol
                     .fallback_assessment_textual_fallback_required assessment))
              && Adapter.Protocol.fallback_assessment_facts assessment = []
          | (Patch.Already_satisfied _ | Patch.Conflict _), _
          | _, Adapter.Unavailable _ ->
              false))

let () =
  Printf.printf "Rust retarget fixture property base seed: %d\n%!" base_seed;
  Alcotest.run "Rust retarget fixture properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed |])
            generated_renames_preserve_exact_byte_oracles;
        ] );
    ]
