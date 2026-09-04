module Golden = Yeokcham_testkit.Golden_fixture
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Object_store = Yeokcham_store
module Relay = Yeokcham_v4_relay
module Transport = Yeokcham_v4_transport
module V2 = Transport.V2
module Wire = Transport.V2_wire

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (V2.error_to_string error)

let digest character = String.make 64 character

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

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let raw_object () =
  let payload = Encoding.text "resumable relay object" |> Result.get_ok in
  let envelope =
    Envelope.create ~object_type:Envelope.Content
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.get_ok
  in
  let bytes = Envelope.encode envelope in
  let object_id =
    Object_store.id_of_envelope envelope |> Object_store.Stored_object_id.to_hex
  in
  (bytes, object_id)

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> Result.get_ok

let capability () =
  V2.capability ~versions:[ V2.protocol_version ] ~zstd:true
    ~max_segment_bytes:V2.segment_bytes ~max_in_flight:4
    ~missing:[ digest 'e' ]
  |> require_ok

let offer raw_size =
  V2.object_offer ~project:(digest 'b') ~object_id:(digest 'c') ~raw_size
  |> require_ok

let session () =
  V2.session ~id:(digest 'a')
    ~offer:(offer (V2.segment_bytes + 19))
    ~credential_id:(digest 'd') ~scope:V2.Upload ~expires_at:12_345L
    ~quota_bytes:(V2.segment_bytes + 19) ~credential_session_count:0
  |> require_ok

let capability_round_trip_and_golden () =
  let encoded = V2.encode_capability (capability ()) |> require_ok in
  Alcotest.(check string)
    "capability uses the versioned canonical fixture"
    (read_golden "v4/transfer-capability-v1.cbor.hex")
    encoded;
  let decoded = V2.decode_capability encoded |> require_ok in
  Alcotest.(check (list int))
    "V2 is advertised" [ 2 ]
    (V2.capability_versions decoded);
  Alcotest.(check bool) "zstd is explicit" true (V2.capability_zstd decoded);
  Alcotest.(check (list string))
    "missing IDs survive"
    [ digest 'e' ]
    (V2.missing_ids (V2.missing_objects decoded))

let session_round_trip_progress_and_golden () =
  let initial = session () in
  let first_range =
    V2.partition (V2.session_offer initial) |> require_ok |> List.hd
  in
  let first =
    V2.segment ~range:first_range ~raw_sha256:(digest 'e') |> require_ok
  in
  let progressed =
    V2.receive_segment ~now:1L ~session:initial first |> require_ok
  in
  let encoded = V2.encode_session progressed |> require_ok in
  Alcotest.(check string)
    "session uses the versioned canonical fixture"
    (read_golden "v4/transfer-session-v1.cbor.hex")
    encoded;
  let duplicate =
    V2.receive_segment ~now:2L ~session:progressed first |> require_ok
  in
  Alcotest.(check string)
    "duplicate receipt is idempotent" encoded
    (V2.encode_session duplicate |> require_ok);
  let decoded = V2.decode_session encoded |> require_ok in
  Alcotest.(check int)
    "one range is durably present" 1
    (List.length (V2.progress_ranges (V2.session_progress decoded)));
  Alcotest.(check bool)
    "incomplete session cannot publish" true
    (Result.is_error (V2.completion_eligible ~now:2L decoded))

let decoders_reject_version_mismatch_noncanonical_and_bad_bitmap () =
  let encoded = V2.encode_capability (capability ()) |> require_ok in
  Alcotest.(check bool)
    "capability trailing bytes are rejected" true
    (Result.is_error (V2.decode_capability (encoded ^ "\000")));
  let unknown_capability =
    Encoding.array
      [
        Encoding.integer 2L;
        Encoding.array [ Encoding.integer 2L ] |> Result.get_ok;
        Encoding.bool true;
        Encoding.integer (Int64.of_int V2.segment_bytes);
        Encoding.integer 4L;
        Encoding.array [] |> Result.get_ok;
      ]
    |> Result.get_ok |> Encoding.encode
  in
  Alcotest.(check bool)
    "unknown capability version is rejected" true
    (Result.is_error (V2.decode_capability unknown_capability));
  let encoded = V2.encode_session (session ()) |> require_ok in
  Alcotest.(check bool)
    "session trailing bytes are rejected" true
    (Result.is_error (V2.decode_session (encoded ^ "\000")));
  let initial = session () in
  let first =
    V2.partition (V2.session_offer initial) |> require_ok |> List.hd
  in
  let progressed =
    V2.receive_segment ~now:1L ~session:initial
      (V2.segment ~range:first ~raw_sha256:(digest 'e') |> require_ok)
    |> require_ok
  in
  let malformed_bitmap =
    Bytes.of_string (V2.encode_session progressed |> require_ok)
  in
  Bytes.set malformed_bitmap (Bytes.length malformed_bitmap - 1) (Char.chr 24);
  Alcotest.(check bool)
    "out-of-range canonical bitmap index is rejected" true
    (Result.is_error
       (V2.decode_session (Bytes.unsafe_to_string malformed_bitmap)))

let negotiation_missing_planning_and_retry_boundaries () =
  let receiver = capability () in
  let sender =
    V2.capability ~versions:[ 1; 2 ] ~zstd:true
      ~max_segment_bytes:(V2.segment_bytes * 2) ~max_in_flight:7 ~missing:[]
    |> require_ok
  in
  let negotiated = V2.intersect_capability ~sender ~receiver |> require_ok in
  Alcotest.(check int)
    "the protocol fixes independent frame size" V2.segment_bytes
    (V2.capability_max_segment_bytes negotiated);
  Alcotest.(check int)
    "the lower concurrency cap wins" 4
    (V2.capability_max_in_flight negotiated);
  Alcotest.(check (list string))
    "only offered missing IDs are planned"
    [ digest 'e' ]
    (V2.plan_missing
       ~offered:[ digest 'd'; digest 'e' ]
       (V2.missing_objects receiver)
    |> require_ok);
  Alcotest.(
    check
      (of_pp (fun formatter -> function
        | V2.Retry_after_ms milliseconds ->
            Format.fprintf formatter "%d" milliseconds
        | V2.Do_not_retry -> Format.fprintf formatter "none")))
    "the fourth retry delay is bounded" (V2.Retry_after_ms 10_000)
    (V2.retry ~attempt:3 V2.Transient_network);
  Alcotest.(check bool)
    "a fifth attempt is refused" true
    (match V2.retry ~attempt:4 V2.Transient_network with
    | V2.Do_not_retry -> true
    | V2.Retry_after_ms _ -> false);
  Alcotest.(check bool)
    "auth failure is never retryable" true
    (match V2.retry ~attempt:0 V2.Authentication_failure with
    | V2.Do_not_retry -> true
    | V2.Retry_after_ms _ -> false)

let independently_compressed_segments_are_exact_and_bounded () =
  let raw = String.init 65_537 (fun index -> Char.chr (index land 0xff)) in
  let compressed = Wire.compress raw |> Result.get_ok in
  Alcotest.(check bool)
    "compressed segment stays under the wire cap" true
    (String.length compressed <= Wire.max_compressed_segment_bytes);
  Alcotest.(check string)
    "decoded segment is byte-exact" raw
    (Wire.decompress ~raw_length:(String.length raw) compressed |> Result.get_ok);
  Alcotest.(check bool)
    "corrupt zstd bytes are rejected" true
    (Result.is_error (Wire.decompress ~raw_length:(String.length raw) "bad"));
  Alcotest.(check bool)
    "claimed expansion is rejected before allocation" true
    (Result.is_error
       (Wire.decompress ~raw_length:(V2.segment_bytes + 1) compressed));
  Alcotest.(check bool)
    "oversized raw segment is rejected" true
    (Result.is_error (Wire.compress (String.make (V2.segment_bytes + 1) 'x')))

let upload_session_persists_resumes_and_publishes_once () =
  with_directory "yeokcham-v4-transfer-session-" (fun root ->
      let relay = Relay.open_repository ~root |> Result.get_ok in
      let project = digest 'a' in
      let bytes, object_id = raw_object () in
      let session =
        Relay.V2.start_upload relay ~now:0L ~project ~object_id
          ~raw_size:(String.length bytes) ~credential_id:(digest 'b')
          ~expires_in:60L
          ~project_quota_bytes:Relay.V2.default_project_quota_bytes
        |> Result.get_ok
      in
      let session_id = V2.session_id session in
      Alcotest.(check bool)
        "incomplete bytes cannot be fetched" true
        (Result.is_error
           (Relay.get relay ~project ~kind:Relay.Object ~id:object_id));
      Relay.V2.receive_upload_segment relay ~now:1L ~project ~session_id
        ~credential_id:(digest 'b') ~offset:0 ~length:(String.length bytes)
        ~raw_sha256:(Transport.sha256 bytes) ~bytes
      |> Result.get_ok |> ignore;
      let resumed =
        Relay.V2.resume_upload relay ~now:2L ~project ~session_id
          ~credential_id:(digest 'b')
        |> Result.get_ok
      in
      Alcotest.(check bool)
        "restart-visible bitmap is complete" true
        (V2.progress_complete (V2.session_progress resumed));
      Relay.V2.complete_upload relay ~now:2L ~project ~session_id
        ~credential_id:(digest 'b')
      |> Result.get_ok;
      Alcotest.(check string)
        "only complete canonical bytes publish" bytes
        (Relay.get relay ~project ~kind:Relay.Object ~id:object_id
        |> Result.get_ok);
      Alcotest.(check bool)
        "published session metadata is removed" true
        (Result.is_error
           (Relay.V2.resume_upload relay ~now:2L ~project ~session_id
              ~credential_id:(digest 'b'))))

let upload_session_rejects_quota_expiry_and_changed_duplicates () =
  with_directory "yeokcham-v4-transfer-refusal-" (fun root ->
      let relay = Relay.open_repository ~root |> Result.get_ok in
      let project = digest 'a' in
      let bytes, object_id = raw_object () in
      let quota_refusal =
        Relay.V2.start_upload relay ~now:0L ~project ~object_id
          ~raw_size:(String.length bytes) ~credential_id:(digest 'b')
          ~expires_in:60L
          ~project_quota_bytes:(String.length bytes - 1)
      in
      Alcotest.(check bool)
        "quota is enforced before temp-file creation" true
        (Result.is_error quota_refusal);
      let session =
        Relay.V2.start_upload relay ~now:0L ~project ~object_id
          ~raw_size:(String.length bytes) ~credential_id:(digest 'b')
          ~expires_in:1L
          ~project_quota_bytes:Relay.V2.default_project_quota_bytes
        |> Result.get_ok
      in
      let session_id = V2.session_id session in
      let expired =
        Relay.V2.resume_upload relay ~now:1L ~project ~session_id
          ~credential_id:(digest 'b')
      in
      Alcotest.(check bool)
        "expiry refuses resume" true (Result.is_error expired);
      let cleanup = Relay.V2.cleanup_expired relay ~now:1L |> Result.get_ok in
      Alcotest.(check int)
        "expiry cleanup is observable" 1 cleanup.Relay.V2.expired_sessions;
      let session =
        Relay.V2.start_upload relay ~now:2L ~project ~object_id
          ~raw_size:(String.length bytes) ~credential_id:(digest 'b')
          ~expires_in:60L
          ~project_quota_bytes:Relay.V2.default_project_quota_bytes
        |> Result.get_ok
      in
      let session_id = V2.session_id session in
      Alcotest.(check bool)
        "wrong claimed length is rejected before bitmap update" true
        (Result.is_error
           (Relay.V2.receive_upload_segment relay ~now:2L ~project ~session_id
              ~credential_id:(digest 'b') ~offset:0
              ~length:(String.length bytes - 1)
              ~raw_sha256:(Transport.sha256 bytes) ~bytes));
      let overlapping = String.sub bytes 1 (String.length bytes - 1) in
      Alcotest.(check bool)
        "overlapping non-offered range is rejected" true
        (Result.is_error
           (Relay.V2.receive_upload_segment relay ~now:2L ~project ~session_id
              ~credential_id:(digest 'b') ~offset:1
              ~length:(String.length overlapping)
              ~raw_sha256:(Transport.sha256 overlapping)
              ~bytes:overlapping));
      Relay.V2.receive_upload_segment relay ~now:2L ~project ~session_id
        ~credential_id:(digest 'b') ~offset:0 ~length:(String.length bytes)
        ~raw_sha256:(Transport.sha256 bytes) ~bytes
      |> Result.get_ok |> ignore;
      let altered = Bytes.of_string bytes in
      Bytes.set altered 0 (if Bytes.get altered 0 = 'x' then 'y' else 'x');
      let altered = Bytes.unsafe_to_string altered in
      Alcotest.(check bool)
        "changed duplicate is rejected" true
        (Result.is_error
           (Relay.V2.receive_upload_segment relay ~now:3L ~project ~session_id
              ~credential_id:(digest 'b') ~offset:0
              ~length:(String.length altered)
              ~raw_sha256:(Transport.sha256 altered) ~bytes:altered));
      Alcotest.(check bool)
        "refusals never publish an incomplete session" true
        (Result.is_error
           (Relay.get relay ~project ~kind:Relay.Object ~id:object_id)))

let session_cap_is_per_safe_credential_and_cleanup_reclaims_allocation () =
  with_directory "yeokcham-v4-transfer-session-cap-" (fun root ->
      let relay = Relay.open_repository ~root |> Result.get_ok in
      let project = digest 'a' in
      let bytes, object_id = raw_object () in
      let create () =
        Relay.V2.start_upload relay ~now:0L ~project ~object_id
          ~raw_size:(String.length bytes) ~credential_id:(digest 'b')
          ~expires_in:1L
          ~project_quota_bytes:Relay.V2.default_project_quota_bytes
      in
      List.init V2.max_parallelism (fun _ -> create ())
      |> List.iter (fun result -> ignore (Result.get_ok result));
      Alcotest.(check bool)
        "ninth live session for one credential is refused" true
        (Result.is_error (create ()));
      let cleanup = Relay.V2.cleanup_expired relay ~now:1L |> Result.get_ok in
      Alcotest.(check int)
        "every expired credential session is observed" V2.max_parallelism
        cleanup.Relay.V2.expired_sessions;
      Alcotest.(check bool)
        "cleanup reports reclaimed temporary bytes" true
        (cleanup.Relay.V2.reclaimed_bytes
        >= V2.max_parallelism * String.length bytes))

let () =
  Alcotest.run "V4 transfer core"
    [
      ( "canonical records",
        [
          Alcotest.test_case "capability round trip and golden" `Quick
            capability_round_trip_and_golden;
          Alcotest.test_case "session round trip and monotonic progress" `Quick
            session_round_trip_progress_and_golden;
          Alcotest.test_case "negative decodes" `Quick
            decoders_reject_version_mismatch_noncanonical_and_bad_bitmap;
        ] );
      ( "planning",
        [
          Alcotest.test_case "negotiation, missing set, and retries" `Quick
            negotiation_missing_planning_and_retry_boundaries;
        ] );
      ( "relay session adapter",
        [
          Alcotest.test_case "persist, resume, and publish complete bytes"
            `Quick upload_session_persists_resumes_and_publishes_once;
          Alcotest.test_case "refuse quota, expiry, and changed duplicates"
            `Quick upload_session_rejects_quota_expiry_and_changed_duplicates;
          Alcotest.test_case "credential cap and expiry cleanup" `Quick
            session_cap_is_per_safe_credential_and_cleanup_reclaims_allocation;
        ] );
      ( "zstd wire adapter",
        [
          Alcotest.test_case "exact bounded independent segments" `Quick
            independently_compressed_segments_are_exact_and_bounded;
        ] );
    ]
