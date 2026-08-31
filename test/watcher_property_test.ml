module Watcher = Yeokcham_watcher

let components =
  QCheck2.Gen.oneof_list [ "a"; "src"; "main.ml"; "renamed"; "unicode-λ" ]

let paths = QCheck2.Gen.(list_size (int_range 1 4) components)

let events =
  let open QCheck2.Gen in
  map
    (fun (kind, path) ->
      match kind with
      | 0 -> Watcher.Macos.Item_created path
      | 1 -> Watcher.Macos.Item_modified path
      | 2 -> Watcher.Macos.Item_removed path
      | 3 -> Watcher.Macos.Item_renamed path
      | 4 -> Watcher.Macos.Must_scan_subdirs
      | 5 -> Watcher.Macos.Kernel_dropped
      | 6 -> Watcher.Macos.User_dropped
      | 7 -> Watcher.Macos.Client_overflow
      | 8 -> Watcher.Macos.Event_ids_wrapped
      | 9 -> Watcher.Macos.Root_changed
      | _ -> Watcher.Macos.Unmounted)
    (pair (int_range 0 10) paths)

let uncertainty =
  List.exists (function
    | Watcher.Macos.Must_scan_subdirs | Watcher.Macos.Kernel_dropped
    | Watcher.Macos.User_dropped | Watcher.Macos.Client_overflow
    | Watcher.Macos.Event_ids_wrapped | Watcher.Macos.Root_changed
    | Watcher.Macos.Unmounted ->
        true
    | Watcher.Macos.Item_created _ | Watcher.Macos.Item_modified _
    | Watcher.Macos.Item_removed _ | Watcher.Macos.Item_renamed _ ->
        false)

let safe_path path =
  path <> []
  && List.for_all
       (fun component ->
         component <> "" && component <> "." && component <> ".."
         && (not (String.contains component '/'))
         && not (String.contains component '\000'))
       path

let macos_uncertainty_never_narrows_a_scan =
  QCheck2.Test.make ~count:500
    ~name:"macOS watcher uncertainty always broadens to a whole-root scan"
    QCheck2.Gen.(list_size (int_range 0 64) events)
    (fun events ->
      match Watcher.Macos.normalize events with
      | Error _ -> false
      | Ok None -> not (uncertainty events)
      | Ok (Some request) -> (
          if uncertainty events then request.Watcher.target = Watcher.Whole_root
          else
            match request.Watcher.target with
            | Watcher.Whole_root -> false
            | Watcher.Paths paths ->
                List.for_all safe_path paths
                && paths = List.sort_uniq Stdlib.compare paths))

let () =
  Alcotest.run "watcher properties"
    [
      ( "macOS",
        [ QCheck_alcotest.to_alcotest macos_uncertainty_never_narrows_a_scan ]
      );
    ]
