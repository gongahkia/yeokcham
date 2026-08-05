module Adapter = Paengi_rust_adapter

let default_seed = 20_260_805

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let adapter_path () =
  match Sys.getenv_opt "PAENGI_RUST_ADAPTER" with
  | Some path when Sys.file_exists path -> path
  | Some _ | None ->
      "tools/paengi-rust-adapter/target/release/paengi-rust-adapter"

let configuration =
  Adapter.configuration_with ~adapter_path:(adapter_path ())
    Adapter.default_configuration

let snapshot_id = String.make 64 '2'

let generated_files_are_canonical =
  QCheck2.Test.make ~count:40
    ~name:"generated safe Rust maps retain bounded ordered spans"
    QCheck2.Gen.(int_range 1 32)
    (fun count ->
      let files =
        List.init count (fun index ->
            let path = Printf.sprintf "src/generated/%04d.rs" index in
            let contents = Printf.sprintf "pub fn item_%04d() {}\n" index in
            Adapter.Protocol.make_source_file ~path ~contents)
      in
      match Adapter.analyze_files configuration ~snapshot_id ~files with
      | Adapter.Unavailable _ -> false
      | Adapter.Available analysis ->
          Adapter.Protocol.analysis_parser_complete analysis
          && List.length (Adapter.Protocol.analysis_items analysis) = count
          && List.for_all
               (fun item ->
                 let span = Adapter.Protocol.item_span item in
                 Adapter.Protocol.span_start_byte span = 0
                 && Adapter.Protocol.span_end_byte span > 0
                 && String.equal "function_item"
                      (Adapter.Protocol.item_kind item))
               (Adapter.Protocol.analysis_items analysis))

let module_source_path index =
  let names = List.init (index + 1) (fun item -> Printf.sprintf "m%04d" item) in
  match List.rev names with
  | [] -> assert false
  | name :: parents ->
      let directory = "src" :: List.rev parents in
      String.concat "/" (directory @ [ name ^ ".rs" ])

let generated_module_maps_are_snapshot_local =
  QCheck2.Test.make ~count:40
    ~name:"generated nested module maps retain canonical parent evidence"
    QCheck2.Gen.(int_range 1 24)
    (fun count ->
      let root =
        Adapter.Protocol.make_source_file ~path:"src/lib.rs"
          ~contents:"mod m0000;\n"
      in
      let files =
        root
        :: List.init count (fun index ->
            let next =
              if index + 1 = count then ""
              else Printf.sprintf "mod m%04d;\n" (index + 1)
            in
            Adapter.Protocol.make_source_file ~path:(module_source_path index)
              ~contents:(Printf.sprintf "pub fn item_%04d() {}\n%s" index next))
      in
      match
        Adapter.resolve_module_paths_files configuration ~snapshot_id
          ~root_files:[ "src/lib.rs" ] ~files
      with
      | Adapter.Unavailable _ -> false
      | Adapter.Available analysis ->
          let modules =
            Adapter.Protocol.module_path_analysis_module_facts analysis
          in
          let external_sources =
            modules
            |> List.filter (fun fact ->
                String.equal "external" (Adapter.Protocol.module_fact_kind fact)
                && String.equal "resolved"
                     (Adapter.Protocol.module_fact_status fact))
            |> List.filter_map Adapter.Protocol.module_fact_source_path
            |> List.sort String.compare
          in
          Adapter.Protocol.module_path_analysis_parser_complete analysis
          && Adapter.Protocol.module_path_analysis_complete analysis
          && Adapter.Protocol.module_path_analysis_unreachable_sources analysis
             = []
          && List.length modules = count + 1
          && external_sources
             = (List.init count module_source_path |> List.sort String.compare)
          && List.for_all
               (fun fact ->
                 String.equal "src/lib.rs"
                   (Adapter.Protocol.module_fact_root_file fact)
                 && String.equal "resolved"
                      (Adapter.Protocol.module_fact_status fact))
               modules
          && List.for_all
               (fun fact ->
                 String.equal "resolved"
                   (Adapter.Protocol.item_path_fact_status fact)
                 && Option.is_some
                      (Adapter.Protocol.item_path_fact_segments fact))
               (Adapter.Protocol.module_path_analysis_item_path_facts analysis))

let () =
  Printf.printf "Rust adapter property base seed: %d\n%!" base_seed;
  Alcotest.run "Rust adapter properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed |])
            generated_files_are_canonical;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed + 1 |])
            generated_module_maps_are_snapshot_local;
        ] );
    ]
