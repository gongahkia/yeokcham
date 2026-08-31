module Watcher = Yeokcham_watcher

let require_request name = function
  | Ok (Some request) -> request
  | Ok None -> Alcotest.fail (name ^ " did not produce a scan request")
  | Error error -> Alcotest.fail (Watcher.error_to_string error)

let expect_whole_root name reason request =
  Alcotest.(check bool)
    (name ^ " has expected reason")
    true
    (request.Watcher.reason = reason);
  match request.Watcher.target with
  | Watcher.Whole_root -> ()
  | Watcher.Paths _ -> Alcotest.fail (name ^ " must scan the whole root")

let macos_rename_uses_only_the_observed_path () =
  let request =
    Watcher.Macos.normalize [ Watcher.Macos.Item_renamed [ "after" ] ]
    |> require_request "macOS rename"
  in
  Alcotest.(check bool)
    "rename is an advisory rename trigger" true
    (request.Watcher.reason = Watcher.Rename);
  match request.Watcher.target with
  | Watcher.Paths [ [ "after" ] ] -> ()
  | Watcher.Whole_root | Watcher.Paths _ ->
      Alcotest.fail "macOS rename invented or omitted a path"

let macos_coalescing_requests_an_exact_whole_root_rescan () =
  let request =
    Watcher.Macos.normalize
      [
        Watcher.Macos.Item_modified [ "src"; "main.ml" ];
        Watcher.Macos.Must_scan_subdirs;
      ]
    |> require_request "macOS coalescing"
  in
  expect_whole_root "macOS coalescing" Watcher.Rescan_required request

let macos_drops_and_loss_have_distinct_conservative_reasons () =
  let overflow event =
    Watcher.Macos.normalize [ event ]
    |> require_request "macOS overflow"
    |> expect_whole_root "macOS overflow" Watcher.Overflow
  in
  List.iter overflow
    [
      Watcher.Macos.Kernel_dropped;
      Watcher.Macos.User_dropped;
      Watcher.Macos.Client_overflow;
    ];
  let loss event =
    Watcher.Macos.normalize [ event ]
    |> require_request "macOS watcher loss"
    |> expect_whole_root "macOS watcher loss" Watcher.Watcher_lost
  in
  List.iter loss
    [
      Watcher.Macos.Event_ids_wrapped;
      Watcher.Macos.Root_changed;
      Watcher.Macos.Unmounted;
    ]

let stronger_uncertainty_wins_over_coalescing () =
  let request =
    Watcher.Macos.normalize
      [
        Watcher.Macos.Must_scan_subdirs;
        Watcher.Macos.Kernel_dropped;
        Watcher.Macos.Root_changed;
      ]
    |> require_request "macOS uncertainty ordering"
  in
  expect_whole_root "macOS loss precedence" Watcher.Watcher_lost request

let macos_rejects_an_unsafe_observed_path () =
  match Watcher.Macos.normalize [ Watcher.Macos.Item_modified [ ".." ] ] with
  | Error error ->
      Alcotest.(check bool)
        "unsafe path is explicit" true
        (error = Watcher.Invalid_path [ ".." ])
  | Ok _ -> Alcotest.fail "unsafe path was not rejected"

let () =
  Alcotest.run "watcher normalization"
    [
      ( "macOS",
        [
          Alcotest.test_case "rename has no invented source" `Quick
            macos_rename_uses_only_the_observed_path;
          Alcotest.test_case "coalescing rescans exactly" `Quick
            macos_coalescing_requests_an_exact_whole_root_rescan;
          Alcotest.test_case "drops and loss remain explicit" `Quick
            macos_drops_and_loss_have_distinct_conservative_reasons;
          Alcotest.test_case "loss dominates coalescing" `Quick
            stronger_uncertainty_wins_over_coalescing;
          Alcotest.test_case "unsafe observed paths are rejected" `Quick
            macos_rejects_an_unsafe_observed_path;
        ] );
    ]
