module Watcher = Yeokcham_watcher

let default_seed = 20_260_809

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let () = Printf.printf "watcher property base seed: %d\n%!" base_seed

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Watcher.error_to_string error)

let path components = components

let rename_and_burst_are_ordered_and_shared () =
  let linux =
    Watcher.Linux.normalize
      [
        Watcher.Linux.Changed (path [ "z" ]);
        Watcher.Linux.Moved
          { source = path [ "b" ]; destination = path [ "a" ] };
        Watcher.Linux.Created (path [ "a" ]);
      ]
    |> require_ok
  in
  let macos =
    Watcher.Macos.normalize
      [
        Watcher.Macos.Item_modified (path [ "z" ]);
        Watcher.Macos.Item_renamed
          { source = path [ "b" ]; destination = path [ "a" ] };
        Watcher.Macos.Item_created (path [ "a" ]);
      ]
    |> require_ok
  in
  Alcotest.(check bool) "platform fixtures agree" true (linux = macos);
  Alcotest.(check bool)
    "rename keeps sorted unique paths" true
    (linux
    = Some
        {
          Watcher.reason = Watcher.Rename;
          target = Watcher.Paths [ [ "a" ]; [ "b" ]; [ "z" ] ];
        })

let overflow_and_loss_request_full_rescans () =
  let linux_overflow =
    Watcher.Linux.normalize
      [ Watcher.Linux.Changed [ "a" ]; Watcher.Linux.Queue_overflow ]
    |> require_ok
  in
  let macos_overflow =
    Watcher.Macos.normalize
      [ Watcher.Macos.Item_modified [ "a" ]; Watcher.Macos.Kernel_dropped ]
    |> require_ok
  in
  let linux_loss =
    Watcher.Linux.normalize [ Watcher.Linux.Watch_lost ] |> require_ok
  in
  let macos_loss =
    Watcher.Macos.normalize [ Watcher.Macos.Root_changed ] |> require_ok
  in
  Alcotest.(check bool)
    "Linux and macOS overflow fixtures agree" true
    (linux_overflow = macos_overflow);
  Alcotest.(check bool)
    "overflow is full rescan" true
    (linux_overflow
    = Some { Watcher.reason = Watcher.Overflow; target = Watcher.Whole_root });
  Alcotest.(check bool)
    "Linux and macOS watcher-loss fixtures agree" true (linux_loss = macos_loss);
  Alcotest.(check bool)
    "loss is full rescan" true
    (linux_loss
    = Some
        { Watcher.reason = Watcher.Watcher_lost; target = Watcher.Whole_root })

let invalid_observations_do_not_request_scans () =
  Alcotest.(check bool)
    "parent traversal rejects" true
    (Result.is_error
       (Watcher.Linux.normalize [ Watcher.Linux.Changed [ ".." ] ]));
  Alcotest.(check bool)
    "NUL path rejects" true
    (Result.is_error
       (Watcher.Linux.normalize [ Watcher.Linux.Changed [ "nul\000byte" ] ]))

let watcher_failures_take_precedence_over_path_errors () =
  let result =
    Watcher.Linux.normalize
      [ Watcher.Linux.Changed [ ".." ]; Watcher.Linux.Watch_lost ]
  in
  Alcotest.(check bool)
    "watch loss requests a full rescan" true
    (result
    = Ok
        (Some
           {
             Watcher.reason = Watcher.Watcher_lost;
             target = Watcher.Whole_root;
           }))

let generated_bursts_are_bounded_and_ordered =
  QCheck2.Test.make ~count:200 ~name:"generated watcher bursts are bounded"
    QCheck2.Gen.(
      map (List.map string_of_int)
        (list_size (int_range 0 400) (int_range 0 400)))
    (fun names ->
      let events =
        List.map (fun name -> Watcher.Linux.Changed [ name ]) names
      in
      let paths = List.sort_uniq String.compare names in
      let expected =
        if paths = [] then None
        else if List.length paths > Watcher.max_paths_per_request then
          Some
            {
              Watcher.reason = Watcher.Path_budget_exceeded;
              target = Watcher.Whole_root;
            }
        else
          Some
            {
              Watcher.reason = Watcher.Path_change;
              target = Watcher.Paths (List.map (fun path -> [ path ]) paths);
            }
      in
      Watcher.Linux.normalize events = Ok expected)

let () =
  Alcotest.run "watcher normalization"
    [
      ( "unit",
        [
          Alcotest.test_case "rename and burst fixtures agree" `Quick
            rename_and_burst_are_ordered_and_shared;
          Alcotest.test_case "overflow and loss request full rescans" `Quick
            overflow_and_loss_request_full_rescans;
          Alcotest.test_case "invalid observations do not scan" `Quick
            invalid_observations_do_not_request_scans;
          Alcotest.test_case "watcher failures take precedence" `Quick
            watcher_failures_take_precedence_over_path_errors;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed |])
            generated_bursts_are_bounded_and_ordered;
        ] );
    ]
