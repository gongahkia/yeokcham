module Experiment = Yeokcham_semantic_experiment

let usage () =
  invalid_arg
    "usage: semantic_retargeting_experiment (--stdout | --output PATH)"

let () =
  match Array.to_list Sys.argv with
  | [ _; "--stdout" ] ->
      Experiment.run () |> Experiment.report_to_json |> print_string
  | [ _; "--output"; path ] -> Experiment.run () |> Experiment.write ~path
  | _ -> usage ()
