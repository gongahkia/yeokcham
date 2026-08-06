module Comparison = Yeokcham_rust_retarget_comparison

let usage () =
  invalid_arg
    "usage: rust_typescript_retargeting_comparison (--stdout | --output PATH)"

let () =
  match Array.to_list Sys.argv with
  | [ _; "--stdout" ] ->
      Comparison.run () |> Comparison.report_to_json |> print_string
  | [ _; "--output"; path ] -> Comparison.run () |> Comparison.write ~path
  | _ -> usage ()
