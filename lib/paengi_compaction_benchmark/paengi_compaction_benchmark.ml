module Compaction = Paengi_compaction
module Hash = Paengi_hash
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

type policy = {
  name : string;
  recent_window_seconds : int64;
  periodic_interval_seconds : int64;
  storage_budget_bytes : int64 option;
}

type timing = {
  samples_ns : int64 list;
  min_ns : int64;
  median_ns : int64;
  max_ns : int64;
}

type sample = {
  restore_ns : int64;
  active_object_store_bytes : int64;
  retained_checkpoint_count : int;
  max_physical_event_depth : int;
  restored_pinned_target : bool;
}

type policy_result = {
  policy : policy;
  samples : sample list;
  restore : timing;
}

type environment = {
  os : string;
  word_size_bits : int;
  ocaml_version : string;
  dune_profile : string;
  filesystem_scope : string;
}

type report = {
  schema_version : int;
  benchmark_id : string;
  recorded_at_utc : string;
  fixture_name : string;
  fixture_checkpoint_count : int;
  fixture_checksum : string;
  repetitions : int;
  environment : environment;
  results : policy_result list;
}

type error =
  | Invalid_repetitions of int
  | Empty_timing_samples
  | Unexpected_unchanged_checkpoint
  | Io_error of string
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Scratch_error of Scratch.error
  | Policy_error of Compaction.Policy.error
  | Compaction_error of Compaction.error
  | Generation_missing
  | Pinned_target_not_retained
  | Restore_mismatch

let error_to_string = function
  | Invalid_repetitions repetitions ->
      Printf.sprintf "repetitions must be positive: %d" repetitions
  | Empty_timing_samples -> "cannot summarize an empty timing sample list"
  | Unexpected_unchanged_checkpoint ->
      "fixture scan unexpectedly produced an unchanged checkpoint"
  | Io_error message -> "benchmark I/O error: " ^ message
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Scratch_error error -> Scratch.error_to_string error
  | Policy_error error -> Compaction.Policy.error_to_string error
  | Compaction_error error -> Compaction.error_to_string error
  | Generation_missing -> "compaction did not publish an active generation"
  | Pinned_target_not_retained ->
      "benchmark pinned target was not retained by the configured policy"
  | Restore_mismatch -> "restore did not reproduce the pinned fixture bytes"

let ( let* ) = Result.bind
let checkpoint_count = 25
let pinned_checkpoint_index = 8
let now = 30L

let fixture_contents =
  List.init checkpoint_count (fun index -> Printf.sprintf "state-%02d\n" index)

let fixture_descriptor () =
  fixture_contents
  |> List.mapi (fun index contents -> Printf.sprintf "%d:%s" index contents)
  |> String.concat ""
  |> fun values -> "scratch-retention-linear-v1\n" ^ values

let hex_of_raw raw =
  String.to_seq raw
  |> Seq.map (fun byte -> Printf.sprintf "%02x" (Char.code byte))
  |> List.of_seq |> String.concat ""

let fixture_checksum () =
  fixture_descriptor () |> Hash.Sha256.digest_string
  |> Hash.Sha256.to_raw_string |> hex_of_raw

let policies =
  [
    {
      name = "keep-all";
      recent_window_seconds = 30L;
      periodic_interval_seconds = 0L;
      storage_budget_bytes = None;
    };
    {
      name = "recent-window";
      recent_window_seconds = 6L;
      periodic_interval_seconds = 0L;
      storage_budget_bytes = None;
    };
    {
      name = "periodic";
      recent_window_seconds = 0L;
      periodic_interval_seconds = 6L;
      storage_budget_bytes = None;
    };
    {
      name = "storage-budget";
      recent_window_seconds = 30L;
      periodic_interval_seconds = 0L;
      storage_budget_bytes = Some 1_200L;
    };
  ]

let timing_of_samples samples =
  match List.sort Int64.compare samples with
  | [] -> Error Empty_timing_samples
  | sorted ->
      let count = List.length sorted in
      Ok
        {
          samples_ns = samples;
          min_ns = List.hd sorted;
          median_ns = List.nth sorted ((count - 1) / 2);
          max_ns = List.hd (List.rev sorted);
        }

let summarize = timing_of_samples

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

let with_temporary_directory run =
  let root = Filename.temp_file "paengi-retention-benchmark-" "" in
  try
    Unix.unlink root;
    Unix.mkdir root 0o700;
    Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)
  with
  | Unix.Unix_error (error, operation, path) ->
      Error
        (Io_error
           (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error)))
  | Sys_error message -> Error (Io_error message)

let write_file path contents =
  try
    Out_channel.with_open_bin path (fun channel ->
        Out_channel.output_string channel contents);
    Ok ()
  with Sys_error message -> Error (Io_error message)

let created_checkpoint = function
  | Scratch.Created checkpoint -> Ok checkpoint
  | Scratch.Unchanged _ -> Error Unexpected_unchanged_checkpoint

let scan_checkpoint store scratch root ~contents ~timestamp =
  let* () = write_file (Filename.concat root "trace.txt") contents in
  let* snapshot, _ =
    Snapshot.scan ~root ~store
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* result =
    Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
      ~observed_at:timestamp ~created_at:timestamp
    |> Result.map_error (fun error -> Scratch_error error)
  in
  created_checkpoint result

type fixture = {
  store : Store.repository;
  scratch : Scratch.repository;
  pinned_target : Scratch.Checkpoint_id.t;
  pinned_contents : string;
}

let create_fixture root =
  let* () =
    write_file (Filename.concat root "trace.txt") (List.hd fixture_contents)
  in
  let* store =
    Store.init ~root |> Result.map_error (fun error -> Store_error error)
  in
  let scratch = Scratch.open_repository store in
  let* initial_snapshot, _ =
    Snapshot.scan ~root ~store
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* initial =
    Scratch.create_initial scratch ~snapshot:initial_snapshot ~created_at:0L
    |> Result.map_error (fun error -> Scratch_error error)
  in
  let rec checkpoints reversed index =
    if index = checkpoint_count then Ok (List.rev reversed)
    else
      let* checkpoint =
        scan_checkpoint store scratch root
          ~contents:(List.nth fixture_contents index)
          ~timestamp:(Int64.of_int index)
      in
      checkpoints (checkpoint :: reversed) (index + 1)
  in
  let* later = checkpoints [] 1 in
  let all = initial :: later in
  let pinned = List.nth all pinned_checkpoint_index in
  let* () =
    Scratch.pin scratch (Scratch.Checkpoint.id pinned) ~changed_at:100L
    |> Result.map_error (fun error -> Scratch_error error)
  in
  Ok
    {
      store;
      scratch;
      pinned_target = Scratch.Checkpoint.id pinned;
      pinned_contents = List.nth fixture_contents pinned_checkpoint_index;
    }

let rec regular_file_bytes path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path |> Array.to_list
        |> List.fold_left
             (fun total name ->
               let* total = total in
               let* bytes = regular_file_bytes (Filename.concat path name) in
               Ok (Int64.add total bytes))
             (Ok 0L)
    | Unix.S_REG -> Ok (Int64.of_int (Unix.stat path).Unix.st_size)
    | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Ok 0L
  with
  | Unix.Unix_error (error, operation, target) ->
      Error
        (Io_error
           (Printf.sprintf "%s %s: %s" operation target
              (Unix.error_message error)))
  | Sys_error message -> Error (Io_error message)

let selected_count plan =
  Compaction.selections plan
  |> List.filter Compaction.Policy.retained
  |> List.length

let generation_depth scratch =
  let* generation =
    Scratch.active_generation scratch
    |> Result.map_error (fun error -> Scratch_error error)
  in
  match generation with
  | None -> Error Generation_missing
  | Some generation ->
      Ok (max 0 (List.length (Scratch.Generation.entries generation) - 1))

let target_is_retained plan target =
  Compaction.selections plan
  |> List.exists (fun selection ->
      Compaction.Policy.retained selection
      && Scratch.Checkpoint_id.equal
           (Compaction.Policy.checkpoint selection).Compaction.Policy.id target)

let run_sample policy =
  with_temporary_directory (fun root ->
      let* fixture = create_fixture root in
      let* compaction_policy =
        Compaction.Policy.create
          ~recent_window_seconds:policy.recent_window_seconds
          ~periodic_interval_seconds:policy.periodic_interval_seconds
          ~storage_budget_bytes:policy.storage_budget_bytes
        |> Result.map_error (fun error -> Policy_error error)
      in
      let* plan =
        Compaction.analyze ~store:fixture.store fixture.scratch
          ~policy:compaction_policy ~now
        |> Result.map_error (fun error -> Compaction_error error)
      in
      if not (target_is_retained plan fixture.pinned_target) then
        Error Pinned_target_not_retained
      else
        let* execution =
          Compaction.activate ~store:fixture.store fixture.scratch
            ~policy:compaction_policy ~now
          |> Result.map_error (fun error -> Compaction_error error)
        in
        let generation = Compaction.execution_generation execution in
        let* _ =
          Compaction.prune ~expected_generation:generation ~store:fixture.store
            fixture.scratch
          |> Result.map_error (fun error -> Compaction_error error)
        in
        let* active_object_store_bytes =
          regular_file_bytes
            (Filename.concat (Store.root fixture.store) ".paengi/objects")
        in
        let* max_physical_event_depth = generation_depth fixture.scratch in
        let started = Unix.gettimeofday () in
        let* _ =
          Scratch.Restore.restore fixture.scratch ~root
            ~target:fixture.pinned_target ~observed_at:1_000L ~created_at:1_000L
          |> Result.map_error (fun error -> Scratch_error error)
        in
        let restore_ns =
          Int64.of_float ((Unix.gettimeofday () -. started) *. 1_000_000_000.)
        in
        let* restored =
          try
            In_channel.with_open_bin
              (Filename.concat root "trace.txt")
              In_channel.input_all
            |> Result.ok
          with Sys_error message -> Error (Io_error message)
        in
        if not (String.equal restored fixture.pinned_contents) then
          Error Restore_mismatch
        else
          Ok
            {
              restore_ns;
              active_object_store_bytes;
              retained_checkpoint_count = selected_count plan;
              max_physical_event_depth;
              restored_pinned_target = true;
            })

let environment () =
  {
    os = Sys.os_type;
    word_size_bits = Sys.word_size;
    ocaml_version = Sys.ocaml_version;
    dune_profile =
      Option.value
        (Sys.getenv_opt "BENCHMARK_DUNE_PROFILE")
        ~default:"unspecified";
    filesystem_scope = "temporary local directory";
  }

let utc_timestamp () =
  let timestamp = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (timestamp.Unix.tm_year + 1900)
    (timestamp.Unix.tm_mon + 1)
    timestamp.Unix.tm_mday timestamp.Unix.tm_hour timestamp.Unix.tm_min
    timestamp.Unix.tm_sec

let run ~repetitions =
  if repetitions <= 0 then Error (Invalid_repetitions repetitions)
  else
    let sample_policy policy =
      let rec collect reversed remaining =
        if remaining = 0 then Ok (List.rev reversed)
        else
          let* sample = run_sample policy in
          collect (sample :: reversed) (remaining - 1)
      in
      let* samples = collect [] repetitions in
      let* restore =
        samples
        |> List.map (fun sample -> sample.restore_ns)
        |> timing_of_samples
      in
      Ok { policy; samples; restore }
    in
    let rec collect_results reversed = function
      | [] -> Ok (List.rev reversed)
      | policy :: rest ->
          let* result = sample_policy policy in
          collect_results (result :: reversed) rest
    in
    let* results = collect_results [] policies in
    Ok
      {
        schema_version = 1;
        benchmark_id = "scratch-retention-policies-v1";
        recorded_at_utc = utc_timestamp ();
        fixture_name = "scratch-retention-linear-v1";
        fixture_checkpoint_count = checkpoint_count;
        fixture_checksum = fixture_checksum ();
        repetitions;
        environment = environment ();
        results;
      }

let json_string value =
  let escaped = Buffer.create (String.length value + 2) in
  Buffer.add_char escaped '"';
  String.iter
    (fun character ->
      match character with
      | '"' -> Buffer.add_string escaped "\\\""
      | '\\' -> Buffer.add_string escaped "\\\\"
      | '\b' -> Buffer.add_string escaped "\\b"
      | '\012' -> Buffer.add_string escaped "\\f"
      | '\n' -> Buffer.add_string escaped "\\n"
      | '\r' -> Buffer.add_string escaped "\\r"
      | character when Char.code character < 0x20 ->
          Printf.bprintf escaped "\\u%04x" (Char.code character)
      | character -> Buffer.add_char escaped character)
    value;
  Buffer.add_char escaped '"';
  Buffer.contents escaped

let json_int64 value = Int64.to_string value

let json_option_int64 = function
  | None -> "null"
  | Some value -> json_int64 value

let json_sample sample =
  Printf.sprintf
    "{\"restore_ns\":%s,\"active_object_store_bytes\":%s,\"retained_checkpoint_count\":%d,\"max_physical_event_depth\":%d,\"restored_pinned_target\":%b}"
    (json_int64 sample.restore_ns)
    (json_int64 sample.active_object_store_bytes)
    sample.retained_checkpoint_count sample.max_physical_event_depth
    sample.restored_pinned_target

let json_timing timing =
  let samples = timing.samples_ns |> List.map json_int64 |> String.concat "," in
  Printf.sprintf
    "{\"samples_ns\":[%s],\"min_ns\":%s,\"median_ns\":%s,\"max_ns\":%s}" samples
    (json_int64 timing.min_ns)
    (json_int64 timing.median_ns)
    (json_int64 timing.max_ns)

let json_result result =
  let policy = result.policy in
  let samples = result.samples |> List.map json_sample |> String.concat "," in
  Printf.sprintf
    "{\"name\":%s,\"policy\":{\"recent_window_seconds\":%s,\"periodic_interval_seconds\":%s,\"storage_budget_bytes\":%s},\"samples\":[%s],\"restore_latency\":%s}"
    (json_string policy.name)
    (json_int64 policy.recent_window_seconds)
    (json_int64 policy.periodic_interval_seconds)
    (json_option_int64 policy.storage_budget_bytes)
    samples
    (json_timing result.restore)

let report_to_json report =
  let environment = report.environment in
  let results =
    report.results |> List.map json_result |> String.concat ",\n    "
  in
  Printf.sprintf
    "{\n\
     \"schema_version\":%d,\n\
     \"benchmark_id\":%s,\n\
     \"purpose\":\"host_specific_retention_policy_evidence_not_performance_claim\",\n\
     \"recorded_at_utc\":%s,\n\
     \"fixture\":{\"name\":%s,\"checkpoint_count\":%d,\"checksum\":{\"algorithm\":\"sha256\",\"value\":%s}},\n\
     \"execution\":{\"repetitions\":%d,\"warmup_runs\":0,\"concurrency\":1,\"cache_state\":\"mixed\"},\n\
     \"environment\":{\"os\":%s,\"word_size_bits\":%d,\"ocaml_version\":%s,\"dune_profile\":%s,\"filesystem_scope\":%s},\n\
     \"policies\":[\n\
    \    %s\n\
     ],\n\
     \"notes\":\"active_object_store_bytes excludes temporary quarantine after \
     prune; restore timings include guarded safety-checkpoint handling and are \
     host-specific evidence only.\"\n\
     }\n"
    report.schema_version
    (json_string report.benchmark_id)
    (json_string report.recorded_at_utc)
    (json_string report.fixture_name)
    report.fixture_checkpoint_count
    (json_string report.fixture_checksum)
    report.repetitions
    (json_string environment.os)
    environment.word_size_bits
    (json_string environment.ocaml_version)
    (json_string environment.dune_profile)
    (json_string environment.filesystem_scope)
    results

let write ~path report =
  try
    Out_channel.with_open_bin path (fun channel ->
        Out_channel.output_string channel (report_to_json report));
    Ok ()
  with Sys_error message -> Error (Io_error message)
