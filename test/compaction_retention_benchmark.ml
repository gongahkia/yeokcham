module Benchmark = Paengi_compaction_benchmark

let usage () =
  invalid_arg
    "usage: compaction_retention_benchmark (--stdout | --output PATH) \
     [--repetitions N]"

let parse arguments =
  let rec loop output repetitions = function
    | [] -> (output, repetitions)
    | "--stdout" :: rest -> loop (`Stdout :: output) repetitions rest
    | "--output" :: path :: rest ->
        loop (`Output path :: output) repetitions rest
    | "--repetitions" :: value :: rest -> (
        match int_of_string_opt value with
        | Some repetitions -> loop output repetitions rest
        | None -> usage ())
    | _ -> usage ()
  in
  match loop [] 5 arguments with
  | [ `Stdout ], repetitions -> (`Stdout, repetitions)
  | [ `Output path ], repetitions -> (`Output path, repetitions)
  | _ -> usage ()

let () =
  let output, repetitions = parse (List.tl (Array.to_list Sys.argv)) in
  match Benchmark.run ~repetitions with
  | Error error ->
      prerr_endline (Benchmark.error_to_string error);
      exit 2
  | Ok report -> (
      match output with
      | `Stdout -> print_string (Benchmark.report_to_json report)
      | `Output path -> (
          match Benchmark.write ~path report with
          | Ok () -> ()
          | Error error ->
              prerr_endline (Benchmark.error_to_string error);
              exit 2))
