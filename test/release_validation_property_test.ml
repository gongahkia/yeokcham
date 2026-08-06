module Capsule_store = Yeokcham_capsule_store
module Id = Yeokcham_id
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Validation = Yeokcham_validation
module Workspace_store = Yeokcham_workspace_store

let default_seed = 20_260_731

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

let state =
  Random.State.make [| stable_seed "release-validation-state-machine" |]

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok
let workspace_id seed = Id.Workspace_id.of_bytes (raw_id seed) |> Result.get_ok

let rec remove path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_repository run =
  let root = Filename.temp_file "yeokcham-release-validation-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let checkpoint scratch snapshot timestamp =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:timestamp ~created_at:timestamp
  |> Result.get_ok
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

module Passing_runner : Validation.Process_runner = struct
  let run _ ~working_directory:_ =
    let empty =
      {
        Validation.digest =
          Yeokcham_hash.Sha256.digest_string ""
          |> Yeokcham_hash.Sha256.to_raw_string;
        retained = "";
        truncated = false;
      }
    in
    {
      Validation.runner_status = Validation.Passed;
      runner_exit_code = Some 0;
      runner_signal = None;
      runner_execution_error = None;
      runner_duration_ms = 0L;
      runner_stdout = empty;
      runner_stderr = empty;
      runner_environment_fingerprint = None;
    }
end

let command =
  {
    Validation.executable = "/usr/bin/true";
    arguments = [];
    working_directory = [];
    timeout_ms = 1000L;
    max_stdout_bytes = 32;
    max_stderr_bytes = 32;
    environment_policy = Validation.Empty;
    environment = [];
    retain_output = false;
    format_version = 1L;
    mandatory_features = 0L;
  }

let release_state_machine_survives_reopen =
  QCheck2.Test.make ~count:20
    ~name:"validate/create/reopen/verify/parent-release state machine survives"
    QCheck2.Gen.(int_range 0 255)
    (fun salt ->
      try
        with_repository (fun root ->
            let store = Store.init ~root |> Result.get_ok in
            let scratch = Scratch.open_repository store in
            write_file (Filename.concat root "tracked") "base";
            let base, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            let initial =
              Scratch.create_initial scratch ~snapshot:base ~created_at:0L
              |> Result.get_ok |> Scratch.Checkpoint.id
            in
            write_file (Filename.concat root "tracked") "release";
            let target, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            let target_checkpoint = checkpoint scratch target 1L in
            let capsule = capsule_id (10 + salt) in
            ignore
              (Capsule_store.Durable.create_from_checkpoints ~store ~scratch
                 ~id:capsule ~title:"state" ~description:"state"
                 ~dependencies:[] ~evidence:[] ~from:initial
                 ~target:target_checkpoint ~created_at:2L ~changed_at:2L ()
              |> Result.get_ok);
            let workspace = workspace_id (300 + salt) in
            ignore
              (Workspace_store.Durable.create ~store ~id:workspace ~base
                 ~name:None ~description:None ~created_at:3L
              |> Result.get_ok);
            ignore
              (Workspace_store.Durable.enable_current_capsule ~store ~workspace
                 ~capsule ~expected_generation:None ~created_at:4L
              |> Result.get_ok);
            let materialised =
              Workspace_store.Durable.materialise ~store ~scratch ~root
                ~workspace ~observed_at:5L ~created_at:5L ~dry_run:false ()
              |> Result.get_ok
            in
            if materialised.Workspace_store.Durable.partial then false
            else
              let parent =
                Release.Durable.create
                  ~runner:(module Passing_runner)
                  ~store ~workspace ~parents:[] ~commands:[ command ]
                  ~message:(Some "parent") ~observed_at:6L ~created_at:6L ()
                |> Result.get_ok
              in
              let child =
                Release.Durable.create
                  ~runner:(module Passing_runner)
                  ~store ~workspace
                  ~parents:[ Release.release_id parent ]
                  ~commands:[ command ] ~message:(Some "child") ~observed_at:7L
                  ~created_at:7L ()
                |> Result.get_ok
              in
              let reopened = Store.open_repository ~root |> Result.get_ok in
              let verified =
                Release.Durable.verify reopened (Release.release_id child)
                |> Result.get_ok
              in
              let resolver id =
                Release.Durable.read reopened id
                |> Result.map Release.release_parents
                |> Result.map_error Release.error_to_string
              in
              Id.Release_id.equal (Release.release_id child)
                (Release.release_id verified)
              && Release.Parent_resolver.contains resolver
                   ~base:(Release.release_id child)
                   ~required:(Release.release_id parent)
                 |> Result.get_ok)
      with _ -> false)

let () =
  Printf.printf "release validation property base seed: %d\n%!" base_seed;
  Alcotest.run "release validation properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick ~rand:state
            release_state_machine_survives_reopen;
        ] );
    ]
