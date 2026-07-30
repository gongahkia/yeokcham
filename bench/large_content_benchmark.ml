module Chunking = Paengi_chunking
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Hash = Paengi_hash.Sha256

let repetitions = 5
let inline_candidates = [ 8 * 1024; 64 * 1024; 256 * 1024 ]
let object_domain = "paengi:object:v1\000"
let content_domain = "paengi:content:v1\000"

type configuration = {
  name : string;
  inline_threshold : int;
  chunking : Chunking.t;
}

type stored = { id : string; bytes : string; plaintext_length : int }
type encoded_file = { objects : stored list; root : string; inline : bool }

let require render = function
  | Ok value -> value
  | Error error -> failwith (render error)

let hex bytes =
  let table = "0123456789abcdef" in
  let output = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun offset character ->
      let value = Char.code character in
      Bytes.set output (offset * 2) table.[value lsr 4];
      Bytes.set output ((offset * 2) + 1) table.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string output

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let stored_id bytes = digest object_domain bytes
let content_id bytes = digest content_domain bytes

let envelope object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> require Envelope.creation_error_to_string
  |> Envelope.encode

let content_payload bytes =
  Encoding.array [ Encoding.integer 1L; Encoding.bytes bytes ]
  |> require Encoding.construction_error_to_string

let manifest_parameters = function
  | Chunking.Fixed { chunk_size } -> (0L, 0, chunk_size, chunk_size, chunk_size)
  | Chunking.Buzhash_v1 { window_size; min_size; average_size; max_size } ->
      (1L, window_size, min_size, average_size, max_size)

let chunk_object bytes =
  let plaintext_length = String.length bytes in
  let bytes = envelope Envelope.Chunk (content_payload bytes) in
  { id = stored_id bytes; bytes; plaintext_length }

let inline_object bytes =
  let plaintext_length = String.length bytes in
  let bytes = envelope Envelope.Content (content_payload bytes) in
  { id = stored_id bytes; bytes; plaintext_length }

let manifest_object chunking bytes chunks =
  let algorithm, window, minimum, average, maximum =
    manifest_parameters chunking
  in
  let refs =
    List.map
      (fun chunk ->
        Encoding.array
          [
            Encoding.bytes chunk.id;
            Encoding.integer (Int64.of_int chunk.plaintext_length);
          ]
        |> require Encoding.construction_error_to_string)
      chunks
  in
  let refs =
    Encoding.array refs |> require Encoding.construction_error_to_string
  in
  let payload =
    Encoding.array
      [
        Encoding.integer 1L;
        Encoding.integer (Int64.of_int (String.length bytes));
        Encoding.integer algorithm;
        Encoding.integer (Int64.of_int window);
        Encoding.integer (Int64.of_int minimum);
        Encoding.integer (Int64.of_int average);
        Encoding.integer (Int64.of_int maximum);
        Encoding.bytes (content_id bytes);
        refs;
      ]
    |> require Encoding.construction_error_to_string
  in
  let bytes = envelope Envelope.File_manifest payload in
  { id = stored_id bytes; bytes; plaintext_length = 0 }

let encode_file configuration bytes =
  if String.length bytes <= configuration.inline_threshold then
    let object_ = inline_object bytes in
    { objects = [ object_ ]; root = object_.id; inline = true }
  else
    let chunks =
      Chunking.split configuration.chunking bytes
      |> require Chunking.error_to_string
    in
    let chunks = List.map chunk_object chunks in
    let manifest = manifest_object configuration.chunking bytes chunks in
    { objects = chunks @ [ manifest ]; root = manifest.id; inline = false }

let decode_content bytes =
  let envelope =
    Envelope.decode bytes |> require Envelope.decode_error_to_string
  in
  match Envelope.payload envelope with
  | Encoding.Array [ Encoding.Integer 1L; Encoding.Bytes contents ] -> contents
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      failwith "benchmark candidate content schema changed"

let find_object objects id =
  match List.find_opt (fun object_ -> String.equal object_.id id) objects with
  | Some object_ -> object_
  | None -> failwith "benchmark manifest refers to a missing chunk"

let decode_file encoded =
  let root = find_object encoded.objects encoded.root in
  if encoded.inline then decode_content root.bytes
  else
    let manifest =
      Envelope.decode root.bytes |> require Envelope.decode_error_to_string
    in
    match Envelope.payload manifest with
    | Encoding.Array
        [
          Encoding.Integer 1L;
          Encoding.Integer length;
          Encoding.Integer _;
          Encoding.Integer _;
          Encoding.Integer _;
          Encoding.Integer _;
          Encoding.Integer _;
          Encoding.Bytes expected_content_id;
          Encoding.Array refs;
        ] ->
        let output = Buffer.create (Int64.to_int length) in
        List.iter
          (function
            | Encoding.Array
                [ Encoding.Bytes id; Encoding.Integer expected_length ] ->
                let chunk =
                  find_object encoded.objects id |> fun object_ ->
                  decode_content object_.bytes
                in
                if String.length chunk <> Int64.to_int expected_length then
                  failwith "benchmark manifest chunk length changed";
                Buffer.add_string output chunk
            | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _
            | Encoding.Null ->
                failwith "benchmark manifest reference schema changed")
          refs;
        let output = Buffer.contents output in
        if String.length output <> Int64.to_int length then
          failwith "benchmark manifest length changed";
        if not (String.equal (content_id output) expected_content_id) then
          failwith "benchmark manifest content identity changed";
        output
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
        failwith "benchmark candidate manifest schema changed"

let unique_objects encoded =
  List.fold_left
    (fun unique object_ ->
      if List.exists (fun prior -> String.equal prior.id object_.id) unique then
        unique
      else object_ :: unique)
    [] encoded.objects

let union_objects files =
  List.fold_left
    (fun unique file ->
      List.fold_left
        (fun unique object_ ->
          if List.exists (fun prior -> String.equal prior.id object_.id) unique
          then unique
          else object_ :: unique)
        unique (unique_objects file))
    [] files

let elapsed_ns run =
  let started = Unix.gettimeofday () in
  let value = run () in
  let elapsed =
    Int64.of_float ((Unix.gettimeofday () -. started) *. 1_000_000_000.)
  in
  (value, elapsed)

let median values =
  let sorted = List.sort Int64.compare values in
  List.nth sorted (List.length sorted / 2)

let measure configuration bytes =
  let encoded, encoding_samples =
    let samples = ref [] in
    let result = ref None in
    for _ = 1 to repetitions do
      let file, sample =
        elapsed_ns (fun () -> encode_file configuration bytes)
      in
      result := Some file;
      samples := sample :: !samples
    done;
    (Option.get !result, List.rev !samples)
  in
  let decoding_samples = ref [] in
  for _ = 1 to repetitions do
    let decoded, sample = elapsed_ns (fun () -> decode_file encoded) in
    if not (String.equal decoded bytes) then failwith "benchmark decode drifted";
    decoding_samples := sample :: !decoding_samples
  done;
  let objects = unique_objects encoded in
  let stored_bytes =
    List.fold_left
      (fun total object_ -> total + String.length object_.bytes)
      0 objects
  in
  let max_chunk =
    List.fold_left
      (fun largest object_ -> max largest (String.length object_.bytes))
      0 objects
  in
  let approximate_allocation =
    if encoded.inline then (2 * String.length bytes) + max_chunk
    else String.length bytes + max_chunk + (2 * 128 * 1024)
  in
  ( encoded,
    stored_bytes,
    List.length objects,
    max_chunk,
    approximate_allocation,
    median encoding_samples,
    median (List.rev !decoding_samples) )

let deterministic_bytes seed length =
  let state = ref (Int64.of_int seed) in
  let bytes = Bytes.create length in
  for index = 0 to length - 1 do
    state := Int64.add (Int64.mul !state 2862933555777941757L) 3037000493L;
    Bytes.set bytes index
      (Char.chr Int64.(to_int (logand (shift_right_logical !state 32) 255L)))
  done;
  Bytes.unsafe_to_string bytes

let repeated pattern length =
  let bytes = Bytes.create length in
  for index = 0 to length - 1 do
    Bytes.set bytes index pattern.[index mod String.length pattern]
  done;
  Bytes.unsafe_to_string bytes

let replace_at bytes offset replacement =
  String.sub bytes 0 offset ^ replacement
  ^ String.sub bytes
      (offset + String.length replacement)
      (String.length bytes - offset - String.length replacement)

let insert_at_start prefix bytes = prefix ^ bytes

let fixtures () =
  let medium = deterministic_bytes 17 (512 * 1024) in
  let large = repeated "paengi-large-content\000" (2 * 1024 * 1024) in
  let high_entropy = deterministic_bytes 29 (2 * 1024 * 1024) in
  let gzip_like =
    "\031\139\008\000\000\000\000\000\000\003"
    ^ deterministic_bytes 43 ((2 * 1024 * 1024) - 10)
  in
  let local_base = deterministic_bytes 71 (1024 * 1024) in
  let insertion_base = deterministic_bytes 113 (1024 * 1024) in
  let boundary_fixtures =
    List.concat_map
      (fun threshold ->
        [
          ( Printf.sprintf "threshold-%d-minus-1" threshold,
            deterministic_bytes (threshold + 3) (threshold - 1) );
          ( Printf.sprintf "threshold-%d" threshold,
            deterministic_bytes (threshold + 5) threshold );
          ( Printf.sprintf "threshold-%d-plus-1" threshold,
            deterministic_bytes (threshold + 7) (threshold + 1) );
        ])
      inline_candidates
  in
  [ ("empty", ""); ("tiny", "paengi\000tiny\255") ]
  @ boundary_fixtures
  @ [
      ("medium", medium);
      ("large-low-entropy", large);
      ("large-high-entropy", high_entropy);
      ("large-gzip-like-binary", gzip_like);
      ("localized-v1", local_base);
      ("localized-v2", replace_at local_base 524_288 (deterministic_bytes 97 64));
      ("insertion-v1", insertion_base);
      ( "insertion-v2",
        insert_at_start (deterministic_bytes 101 257) insertion_base );
    ]

let json value =
  let output = Buffer.create (String.length value + 2) in
  Buffer.add_char output '"';
  String.iter
    (function
      | '"' -> Buffer.add_string output "\\\""
      | '\\' -> Buffer.add_string output "\\\\"
      | '\n' -> Buffer.add_string output "\\n"
      | '\r' -> Buffer.add_string output "\\r"
      | '\t' -> Buffer.add_string output "\\t"
      | character when Char.code character < 0x20 ->
          Printf.bprintf output "\\u%04x" (Char.code character)
      | character -> Buffer.add_char output character)
    value;
  Buffer.add_char output '"';
  Buffer.contents output

let strategy_name = function
  | Chunking.Fixed { chunk_size } -> Printf.sprintf "fixed-%d" chunk_size
  | Chunking.Buzhash_v1 { window_size; min_size; average_size; max_size } ->
      Printf.sprintf "buzhash-v1-%d-%d-%d-%d" window_size min_size average_size
        max_size

let output_path () =
  match Array.to_list Sys.argv with
  | [ _; "--output"; path ] -> path
  | _ -> invalid_arg "usage: large_content_benchmark --output PATH"

let command_output command =
  try
    let channel = Unix.open_process_in command in
    let output = In_channel.input_all channel |> String.trim in
    match Unix.close_process_in channel with
    | Unix.WEXITED 0 when not (String.is_empty output) -> output
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> "unavailable"
  with Unix.Unix_error _ -> "unavailable"

let utc_timestamp () =
  let timestamp = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (timestamp.Unix.tm_year + 1900)
    (timestamp.Unix.tm_mon + 1)
    timestamp.Unix.tm_mday timestamp.Unix.tm_hour timestamp.Unix.tm_min
    timestamp.Unix.tm_sec

let dune_profile () =
  match Sys.getenv_opt "BENCHMARK_DUNE_PROFILE" with
  | Some profile -> profile
  | None -> "unspecified"

let write_row output configuration name bytes =
  let ( _,
        stored_bytes,
        object_count,
        max_chunk,
        approximate_allocation,
        encoding_ns,
        decoding_ns ) =
    measure configuration bytes
  in
  Printf.fprintf output
    "    \
     {\"configuration\":%s,\"inline_threshold_bytes\":%d,\"chunking\":%s,\"fixture\":%s,\"fixture_sha256\":%s,\"plaintext_bytes\":%d,\"encoded_bytes_stored\":%d,\"object_count\":%d,\"max_encoded_object_bytes\":%d,\"encoding_median_ns\":%Ld,\"decoding_materialisation_median_ns\":%Ld,\"approximate_allocation_bytes\":%d}"
    (json configuration.name) configuration.inline_threshold
    (json (strategy_name configuration.chunking))
    (json name)
    (json (hex (Hash.digest_string bytes |> Hash.to_raw_string)))
    (String.length bytes) stored_bytes object_count max_chunk encoding_ns
    decoding_ns approximate_allocation

let write_version_set output configuration name left right =
  let first = encode_file configuration left in
  let second = encode_file configuration right in
  let first_unique = unique_objects first in
  let second_unique = unique_objects second in
  let shared =
    List.filter
      (fun object_ ->
        List.exists (fun prior -> String.equal prior.id object_.id) first_unique)
      second_unique
  in
  let union = union_objects [ first; second ] in
  let bytes objects =
    List.fold_left
      (fun total object_ -> total + String.length object_.bytes)
      0 objects
  in
  Printf.fprintf output
    "    \
     {\"configuration\":%s,\"set\":%s,\"first_plaintext_bytes\":%d,\"second_plaintext_bytes\":%d,\"unique_encoded_bytes\":%d,\"unique_object_count\":%d,\"deduplicated_bytes_reused_across_versions\":%d,\"reused_object_count\":%d}"
    (json configuration.name) (json name) (String.length left)
    (String.length right) (bytes union) (List.length union) (bytes shared)
    (List.length shared)

let () =
  let output_path = output_path () in
  let configurations =
    [
      {
        name = "inline-8192-buzhash";
        inline_threshold = List.nth inline_candidates 0;
        chunking = Chunking.default;
      };
      {
        name = "inline-65536-fixed";
        inline_threshold = List.nth inline_candidates 1;
        chunking = Chunking.fixed_64k;
      };
      {
        name = "inline-65536-buzhash";
        inline_threshold = List.nth inline_candidates 1;
        chunking = Chunking.default;
      };
      {
        name = "inline-262144-buzhash";
        inline_threshold = List.nth inline_candidates 2;
        chunking = Chunking.default;
      };
    ]
  in
  let fixtures = fixtures () in
  Out_channel.with_open_bin output_path (fun output ->
      Printf.fprintf output
        "{\n\
        \  \"schema_version\":1,\n\
        \  \"benchmark_id\":\"large-content-v1\",\n\
        \  \
         \"purpose\":\"host_specific_format_decision_evidence_not_performance_claim\",\n\
        \  \"recorded_at_utc\":%s,\n\
        \  \
         \"host\":{\"os\":%s,\"architecture\":%s,\"cpu_model\":%s,\"memory_bytes\":%s,\"filesystem\":%s},\n\
        \  \"toolchain\":{\"ocaml_version\":%s,\"dune_profile\":%s},\n\
        \  \"fixed_seed\":20260730,\n\
        \  \"repetitions\":%d,\n\
        \  \"candidate_inline_thresholds_bytes\":[8192,65536,262144],\n\
        \  \
         \"candidate_chunking\":[\"fixed-65536\",\"buzhash-v1-64-16384-65536-131072\"],\n\
        \  \"allocation_metric\":\"approximate_working_set_bytes_not_peak_rss\",\n\
        \  \"fixtures\":[\n"
        (json (utc_timestamp ()))
        (json Sys.os_type)
        (json (command_output "uname -m"))
        (json (command_output "sysctl -n machdep.cpu.brand_string"))
        (json (command_output "sysctl -n hw.memsize"))
        (json (command_output "stat -f %T ."))
        (json Sys.ocaml_version)
        (json (dune_profile ()))
        repetitions;
      let first = ref true in
      List.iter
        (fun configuration ->
          List.iter
            (fun (name, bytes) ->
              if !first then first := false else Printf.fprintf output ",\n";
              write_row output configuration name bytes)
            fixtures)
        configurations;
      Printf.fprintf output "\n  ],\n  \"version_sets\":[\n";
      let first = ref true in
      List.iter
        (fun configuration ->
          let pairs =
            [
              ( "localized-modification",
                List.assoc "localized-v1" fixtures,
                List.assoc "localized-v2" fixtures );
              ( "insertion-near-beginning",
                List.assoc "insertion-v1" fixtures,
                List.assoc "insertion-v2" fixtures );
            ]
          in
          List.iter
            (fun (name, left, right) ->
              if !first then first := false else Printf.fprintf output ",\n";
              write_version_set output configuration name left right)
            pairs)
        configurations;
      Printf.fprintf output "\n  ]\n}\n")
