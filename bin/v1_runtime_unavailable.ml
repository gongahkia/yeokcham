let unavailable () =
  prerr_endline "V1 background runtime is only supported on Linux";
  exit 2

let start ~root:_ = unavailable ()
let status ~root:_ = unavailable ()
let stop ~root:_ = unavailable ()
let sync ~root:_ ~remote:_ = unavailable ()
let run ~root:_ = unavailable ()
