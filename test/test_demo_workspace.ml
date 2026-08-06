let require condition message = if not condition then Alcotest.fail message

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun n -> remove_tree (Filename.concat path n));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let find label candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail (label ^ " unavailable")

let script name =
  let cwd = Sys.getcwd () in
  find name
    [
      Filename.concat cwd ("tools/demo/" ^ name);
      Filename.concat cwd ("../tools/demo/" ^ name);
    ]

let binary name =
  let cwd = Sys.getcwd () in
  find name
    [
      Filename.concat cwd ("../bin/" ^ name);
      Filename.concat cwd ("../tools/" ^ name);
      Filename.concat cwd ("_build/default/bin/" ^ name);
      Filename.concat cwd ("_build/default/tools/" ^ name);
    ]

let environment entries =
  Unix.environment () |> Array.to_list
  |> List.filter (fun entry ->
      not
        (List.exists
           (fun (key, _) -> String.starts_with ~prefix:(key ^ "=") entry)
           entries))
  |> fun inherited ->
  Array.of_list
    (List.map (fun (key, value) -> key ^ "=" ^ value) entries @ inherited)

let run ~environment program arguments =
  let output = Filename.temp_file "yeokcham-demo-workspace-output-" "" in
  Fun.protect
    (fun () ->
      let descriptor =
        Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let status =
            Unix.create_process_env program
              (Array.of_list (program :: arguments))
              environment Unix.stdin descriptor descriptor
            |> Unix.waitpid [] |> snd
          in
          (status, In_channel.with_open_bin output In_channel.input_all)))
    ~finally:(fun () -> remove_tree output)

let exited = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let read path = In_channel.with_open_bin path In_channel.input_all

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > text_length then false
    else if String.sub text index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let entries path = Sys.readdir path |> Array.to_list |> List.sort String.compare

let capsule_revision ~capsule output =
  let prefix = "capsule=" ^ capsule ^ " revision=" in
  require
    (String.starts_with ~prefix output)
    "capsule creation output is invalid";
  String.sub output (String.length prefix)
    (String.length output - String.length prefix)
  |> String.split_on_char ' ' |> List.hd

let count_lines prefix output =
  String.split_on_char '\n' output
  |> List.filter (String.starts_with ~prefix)
  |> List.length

let workspace_selection_is_deterministic_and_independent () =
  let parent = Filename.temp_file "yeokcham-demo-workspace-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let environment =
        environment
          [
            ("YEOKCHAM_BIN", binary "yeokcham.exe");
            ("YEOKCHAM_WORKSPACE_BASE_BIN", binary "workspace_base_v1.exe");
          ]
      in
      require
        (run ~environment "sh"
           [ script "create-repository-v1.sh"; "--root"; root ]
        |> fst |> exited)
        "fixture creation failed";
      let checkpoint =
        read (Filename.concat root ".yeokcham/demo-v1-change-checkpoint")
        |> String.trim
      in
      let yeokcham_directory = Filename.concat root ".yeokcham" in
      let before_helper = entries yeokcham_directory in
      let helper_status, snapshot =
        run ~environment
          (binary "workspace_base_v1.exe")
          [ "--root"; root; "--checkpoint"; checkpoint ]
      in
      require (exited helper_status) "checkpoint helper failed";
      Alcotest.(check int)
        "snapshot object ID length" 64
        (String.length (String.trim snapshot));
      Alcotest.(check (list string))
        "checkpoint helper is read-only" before_helper
        (entries yeokcham_directory);
      require
        (run ~environment "sh"
           [ script "demonstrate-workspace-v1.sh"; "--root"; root ]
        |> fst |> exited)
        "workspace demo failed";
      let first_capsule =
        "4444444444444444444444444444444444444444444444444444444444444444"
      in
      let second_capsule =
        "5555555555555555555555555555555555555555555555555555555555555555"
      in
      let first_revision =
        read (Filename.concat root ".yeokcham/demo-v1-workspace-capsule-first")
        |> capsule_revision ~capsule:first_capsule
      in
      let second_revision =
        read (Filename.concat root ".yeokcham/demo-v1-workspace-capsule-second")
        |> capsule_revision ~capsule:second_capsule
      in
      let disabled =
        read (Filename.concat root ".yeokcham/demo-v1-workspace-disabled")
      in
      let final_order =
        read (Filename.concat root ".yeokcham/demo-v1-workspace-order-final")
      in
      require
        (count_lines "selected[" disabled = 1)
        "disable did not leave one selection";
      require
        (contains disabled
           ("selected[0] capsule=" ^ first_capsule ^ " revision="
          ^ first_revision))
        "disable did not retain the first capsule";
      require
        (not (contains disabled second_capsule))
        "disable retained the second capsule";
      require
        (count_lines "order[" final_order = 2)
        "final order lacks two revisions";
      require
        (contains final_order
           ("order[0] capsule=" ^ first_capsule ^ " revision=" ^ first_revision))
        "final order changed the first explicit selection";
      require
        (contains final_order
           ("order[1] capsule=" ^ second_capsule ^ " revision="
          ^ second_revision))
        "final order changed the second explicit selection")

let () =
  Alcotest.run "multiple enabled capsules demonstration"
    [
      ( "workspace",
        [
          Alcotest.test_case "deterministic order and independent selection"
            `Quick workspace_selection_is_deterministic_and_independent;
        ] );
    ]
