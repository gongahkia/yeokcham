module Output = V1_cli_output

let run ~root:_ =
  Output.print_error "watcher capture is supported only on Linux and macOS";
  exit 2
