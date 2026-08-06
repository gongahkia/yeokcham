module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let default_seed = 20_260_730

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let () = Printf.printf "scratch property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_store run =
  let root = Filename.temp_file "yeokcham-scratch-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let require = function Ok value -> value | Error _ -> raise Exit

let state_for_flags store (left, directory, child, executable) =
  let one = Snapshot.Content.store store "one" |> require in
  let two = Snapshot.Content.store store "two" |> require in
  let mode = if executable then Snapshot.Executable else Snapshot.Regular in
  let entries =
    (if left then [ ([ "left" ], Scratch.File { mode; content = one }) ] else [])
    @
    if directory then
      [ ([ "dir" ], Scratch.Directory) ]
      @
      if child then
        [ ([ "dir"; "child" ], Scratch.File { mode; content = two }) ]
      else []
    else []
  in
  Scratch.State.create entries |> require

let flags = QCheck2.Gen.(quad bool bool bool bool)

let diff_replays_to_target =
  QCheck2.Test.make ~count:100 ~name:"scratch diff replay reaches exact target"
    QCheck2.Gen.(pair flags flags)
    (fun (from_flags, to_flags) ->
      try
        with_store (fun root ->
            let store = Store.init ~root |> require in
            let from = state_for_flags store from_flags in
            let to_ = state_for_flags store to_flags in
            let operations = Scratch.State.diff ~from ~to_ in
            match Scratch.State.apply from operations with
            | Ok replayed -> Scratch.State.equal replayed to_
            | Error _ -> false)
      with Exit -> false)

let checkpoint_restore_state_machine =
  QCheck2.Test.make ~count:30
    ~name:"edit checkpoint restore sequences retain the model head"
    QCheck2.Gen.(list_size (int_range 1 12) (int_range 0 1_000_000))
    (fun commands ->
      try
        with_store (fun source ->
            with_store (fun store_root ->
                let file = Filename.concat source "file" in
                write_file file "base";
                let store = Store.init ~root:store_root |> require in
                let scratch = Scratch.open_repository store in
                let base, _ = Snapshot.scan ~root:source ~store |> require in
                let initial =
                  Scratch.create_initial scratch ~snapshot:base ~created_at:0L
                  |> require
                in
                let checkpoints = ref [ (initial, "base") ] in
                let head = ref initial in
                List.iteri
                  (fun step command ->
                    match command mod 4 with
                    | 0 ->
                        write_file file
                          (Printf.sprintf "edit-%d-%d" step command)
                    | 1 -> (
                        let snapshot, _ =
                          Snapshot.scan ~root:source ~store |> require
                        in
                        match
                          Scratch.checkpoint scratch ~snapshot
                            ~source:Scratch.Explicit
                            ~observed_at:(Int64.of_int step)
                            ~created_at:(Int64.of_int step)
                          |> require
                        with
                        | Scratch.Created checkpoint ->
                            checkpoints :=
                              (checkpoint, read_file file) :: !checkpoints;
                            head := checkpoint
                        | Scratch.Unchanged checkpoint -> head := checkpoint)
                    | 2 ->
                        let checkpoint, expected =
                          List.nth !checkpoints
                            (command mod List.length !checkpoints)
                        in
                        ignore
                          (Scratch.Restore.restore scratch ~root:source
                             ~target:(Scratch.Checkpoint.id checkpoint)
                             ~observed_at:(Int64.of_int (step + 100))
                             ~created_at:(Int64.of_int (step + 100))
                          |> require);
                        if not (String.equal (read_file file) expected) then
                          raise Exit;
                        head := checkpoint
                    | _ -> (
                        let snapshot, _ =
                          Snapshot.scan ~root:source ~store |> require
                        in
                        match
                          Scratch.checkpoint scratch ~snapshot
                            ~source:Scratch.Scan
                            ~observed_at:(Int64.of_int (step + 200))
                            ~created_at:(Int64.of_int (step + 200))
                          |> require
                        with
                        | Scratch.Created checkpoint ->
                            checkpoints :=
                              (checkpoint, read_file file) :: !checkpoints;
                            head := checkpoint
                        | Scratch.Unchanged checkpoint -> head := checkpoint))
                  commands;
                match Scratch.head scratch |> require with
                | Some actual ->
                    Scratch.Checkpoint_id.equal
                      (Scratch.Checkpoint.id actual)
                      (Scratch.Checkpoint.id !head)
                | None -> false))
      with Exit -> false)

let () =
  Alcotest.run "scratch properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "diff-replay") diff_replays_to_target;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "checkpoint-restore-state-machine")
            checkpoint_restore_state_machine;
        ] );
    ]
