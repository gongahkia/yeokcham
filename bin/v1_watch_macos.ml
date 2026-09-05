module Macos_watcher = Yeokcham_macos_watcher

module Runner = V1_watch_runner.Make (struct
  include Macos_watcher
end)

let run = Runner.run
