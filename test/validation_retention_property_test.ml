module Retention = Yeokcham_validation_retention
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Validation = Yeokcham_validation

let default_seed = 20_260_806

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let raw value =
  let bytes = Bytes.make 32 '\000' in
  Bytes.set bytes 0 (Char.chr (value land 0xff));
  Bytes.unsafe_to_string bytes

let checkpoint value =
  raw value |> Store.Stored_object_id.of_raw_bytes |> Option.get
  |> Scratch.Checkpoint_id.of_stored_object_id

let snapshot value =
  raw value |> Store.Stored_object_id.of_raw_bytes |> Option.get
  |> Snapshot.Snapshot.of_stored_object_id

let command =
  {
    Validation.executable = "/usr/bin/true";
    arguments = [];
    working_directory = [];
    timeout_ms = 1L;
    max_stdout_bytes = 0;
    max_stderr_bytes = 0;
    environment_policy = Validation.Empty;
    environment = [];
    retain_output = false;
    format_version = 1L;
    mandatory_features = 0L;
  }

let passed_evidence target =
  let empty =
    {
      Validation.digest =
        Yeokcham_hash.Sha256.digest_string "" |> Yeokcham_hash.Sha256.to_raw_string;
      retained = "";
      truncated = false;
    }
  in
  Validation.create_evidence ~snapshot:target ~command ~command_index:0
    ~result:
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
    ~stdout_output:None ~stderr_output:None ~observed_at:0L
  |> Result.get_ok

let compare_checkpoint left right =
  Store.Stored_object_id.compare
    (Scratch.Checkpoint_id.stored_object_id left)
    (Scratch.Checkpoint_id.stored_object_id right)

let exact_snapshot_candidates_are_selected_once =
  QCheck.Test.make ~count:100
    QCheck.(list bool)
    (fun matches ->
      let target = snapshot 1 in
      let candidates =
        matches
        |> List.mapi (fun index matches ->
            (checkpoint (index + 2), if matches then target else snapshot 2))
      in
      let decision =
        Retention.decide Retention.Pin_all_exact_snapshot_checkpoints
          ~evidence:(passed_evidence target) ~candidates
      in
      match decision with
      | Retention.Evidence_not_passed -> false
      | Retention.No_matching_checkpoint -> not (List.exists Fun.id matches)
      | Retention.Retain checkpoints ->
          let expected =
            candidates
            |> List.filter_map (fun (checkpoint, candidate) ->
                if Snapshot.Snapshot.equal_id candidate target then
                  Some checkpoint
                else None)
            |> List.sort_uniq compare_checkpoint
          in
          List.length checkpoints = List.length expected
          && List.for_all2
               (fun left right -> Scratch.Checkpoint_id.equal left right)
               checkpoints expected)

let () =
  Printf.printf "validation retention property base seed: %d\n%!" base_seed;
  Alcotest.run "validation retention properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| base_seed |])
            exact_snapshot_candidates_are_selected_once;
        ] );
    ]
