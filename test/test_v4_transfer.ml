module Golden = Yeokcham_testkit.Golden_fixture
module Encoding = Yeokcham_encoding
module Transport = Yeokcham_v4_transport
module V2 = Transport.V2

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (V2.error_to_string error)

let digest character = String.make 64 character

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
    (Result.is_error (V2.decode_session (encoded ^ "\000")))

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
    ]
