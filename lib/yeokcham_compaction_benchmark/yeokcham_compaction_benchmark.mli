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

type error

val error_to_string : error -> string
val fixture_checksum : unit -> string
val summarize : int64 list -> (timing, error) result
val run : repetitions:int -> (report, error) result
val report_to_json : report -> string
val write : path:string -> report -> (unit, error) result
