module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Model = Yeokcham_model
open Model

let iterations = 10_000

let fail_result render = function
  | Ok value -> value
  | Error error -> failwith (render error)

let require_path components =
  Path.of_components components |> fail_result Path.error_to_string

let require_snapshot entries =
  Snapshot.of_entries entries |> fail_result construction_error_to_string

let file ?(mode = Regular) content = { mode; content }

let fixture_snapshot () =
  let bin = require_path [ "bin" ] in
  let docs = require_path [ "docs" ] in
  let guides = require_path [ "docs"; "guides" ] in
  require_snapshot
    [
      File_path
        (require_path [ "latest" ], file ~mode:Symlink "docs/guides/guide.txt");
      File_path (require_path [ "docs"; "guides"; "guide.txt" ], file "guide\n");
      Directory_path guides;
      File_path
        ( require_path [ "bin"; "run" ],
          file ~mode:Executable "#!/bin/sh\necho yeokcham\n" );
      Directory_path docs;
      Directory_path bin;
    ]

let encoded_object snapshot =
  let payload = Snapshot.canonical_bytes snapshot in
  let payload =
    Encoding.decode payload |> fail_result Encoding.decode_error_to_string
  in
  Envelope.create ~object_type:Envelope.Snapshot
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> fail_result Envelope.creation_error_to_string
  |> Envelope.encode

let decode_object bytes =
  let envelope =
    Envelope.decode bytes |> fail_result Envelope.decode_error_to_string
  in
  let payload = Encoding.encode (Envelope.payload envelope) in
  Snapshot.decode_canonical_bytes payload
  |> fail_result canonical_decode_error_to_string

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
      | '\t' -> Buffer.add_string escaped "\\t"
      | character when Char.code character < 0x20 ->
          Printf.bprintf escaped "\\u%04x" (Char.code character)
      | character -> Buffer.add_char escaped character)
    value;
  Buffer.add_char escaped '"';
  Buffer.contents escaped

let utc_timestamp () =
  let timestamp = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (timestamp.Unix.tm_year + 1900)
    (timestamp.Unix.tm_mon + 1)
    timestamp.Unix.tm_mday timestamp.Unix.tm_hour timestamp.Unix.tm_min
    timestamp.Unix.tm_sec

let trim value = String.trim value

let command_output command =
  try
    let channel = Unix.open_process_in command in
    let output = In_channel.input_all channel |> trim in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 -> Some output
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None
  with Unix.Unix_error _ -> None

let yeokcham_revision () =
  match command_output "git rev-parse HEAD" with
  | Some revision ->
      if String.is_empty revision then "unavailable" else revision
  | None -> "unavailable"

let working_tree_state () =
  match command_output "git status --porcelain" with
  | Some "" -> "clean"
  | Some _ -> "dirty"
  | None -> "unavailable"

let dune_profile () =
  match Sys.getenv_opt "BENCHMARK_DUNE_PROFILE" with
  | Some profile -> profile
  | None -> "unspecified"

let write_result ~output ~fixture_checksum ~encoded_size ~elapsed_ns =
  let result =
    Printf.sprintf
      "{\n\
      \  \"schema_version\": 1,\n\
      \  \"benchmark_id\": \"canonical-codec-v1\",\n\
      \  \"recorded_at_utc\": %s,\n\
      \  \"purpose\": \"baseline_not_performance_claim\",\n\
      \  \"fixture\": {\n\
      \    \"name\": \"nested-snapshot-v1\",\n\
      \    \"sha256\": %s\n\
      \  },\n\
      \  \"codec\": {\n\
      \    \"profile_version\": %d,\n\
      \    \"envelope_version\": %d,\n\
      \    \"object_format_version\": %d\n\
      \  },\n\
      \  \"iterations\": %d,\n\
      \  \"operation_count\": %d,\n\
      \  \"encoded_size_bytes\": %d,\n\
      \  \"elapsed_ns\": %Ld,\n\
      \  \"metadata\": {\n\
      \    \"ocaml_version\": %s,\n\
      \    \"dune_profile\": %s,\n\
      \    \"yeokcham_revision\": %s,\n\
      \    \"working_tree_state\": %s\n\
      \  }\n\
       }\n"
      (json_string (utc_timestamp ()))
      (json_string fixture_checksum)
      Encoding.profile_version Envelope.envelope_version
      Envelope.current_object_format_version iterations (iterations * 2)
      encoded_size elapsed_ns
      (json_string Sys.ocaml_version)
      (json_string (dune_profile ()))
      (json_string (yeokcham_revision ()))
      (json_string (working_tree_state ()))
  in
  Out_channel.with_open_bin output (fun channel -> output_string channel result)

let output_path () =
  match Array.to_list Sys.argv with
  | [ _; "--output"; path ] -> path
  | _ -> invalid_arg "usage: encoding_benchmark --output PATH"

let hex_of_bytes bytes =
  String.to_seq bytes
  |> Seq.map (fun byte -> Printf.sprintf "%02x" (Char.code byte))
  |> List.of_seq |> String.concat ""

let () =
  let output = output_path () in
  let snapshot = fixture_snapshot () in
  let initial_bytes = encoded_object snapshot in
  let fixture_checksum =
    Yeokcham_hash.Sha256.digest_string initial_bytes
    |> Yeokcham_hash.Sha256.to_raw_string |> hex_of_bytes
  in
  let started_at = Unix.gettimeofday () in
  for _ = 1 to iterations do
    let bytes = encoded_object snapshot in
    if not (String.equal initial_bytes bytes) then failwith "encoder drifted";
    let decoded = decode_object bytes in
    if not (Snapshot.equal snapshot decoded) then failwith "decoder drifted"
  done;
  let elapsed_ns =
    Int64.of_float ((Unix.gettimeofday () -. started_at) *. 1_000_000_000.)
  in
  write_result ~output ~fixture_checksum
    ~encoded_size:(String.length initial_bytes)
    ~elapsed_ns
