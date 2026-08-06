module Benchmark = Yeokcham_compaction_benchmark

let default_seed = 20_260_806

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let ordered_summary =
  QCheck.Test.make ~count:100
    QCheck.(list (int_range 0 1_000_000))
    (fun values ->
      match List.map Int64.of_int values |> Benchmark.summarize with
      | Error _ -> values = []
      | Ok timing ->
          List.length timing.Benchmark.samples_ns = List.length values
          && Int64.compare timing.Benchmark.min_ns timing.Benchmark.median_ns
             <= 0
          && Int64.compare timing.Benchmark.median_ns timing.Benchmark.max_ns
             <= 0)

let () =
  Printf.printf "compaction benchmark property base seed: %d\n%!" base_seed;
  Alcotest.run "scratch retention benchmark properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed |])
            ordered_summary;
        ] );
    ]
