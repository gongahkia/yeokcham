module Encoding = Yeokcham_encoding
module Golden = Yeokcham_testkit.Golden_fixture
module Object = Yeokcham_v2_object
module Reclamation = Yeokcham_v2_reclamation
module V2_model = Yeokcham_v2_model

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let opaque_ref value =
  V2_model.Opaque_object_ref.of_hex (Printf.sprintf "%064x" value)
  |> require_ok V2_model.identity_error_to_string

let entry ?(links = []) value kind bytes =
  Reclamation.object_entry ~object_ref:(opaque_ref value) ~object_kind:kind
    ~stored_bytes:bytes
    ~direct_links:(List.map opaque_ref links)
  |> require_ok Reclamation.error_to_string

let candidate_ids plan =
  Reclamation.candidates plan
  |> List.map (fun candidate ->
      V2_model.Opaque_object_ref.to_hex
        (Reclamation.candidate_object_ref candidate))

let mark_and_quota_are_deterministic () =
  let objects =
    [
      entry ~links:[ 2; 3 ] 1 Object.Ledger_event 9L;
      entry 2 Object.Scratch_snapshot 35L;
      entry 3 Object.Capsule 21L;
      entry 4 Object.Validation_evidence 13L;
      entry 5 Object.Release 17L;
    ]
  in
  let plan =
    Reclamation.make_plan ~objects
      ~roots:[ opaque_ref 1 ]
      ~cache_budget_bytes:70L
    |> require_ok Reclamation.error_to_string
  in
  Alcotest.(check (list string))
    "marked closure retains roots and links"
    [
      V2_model.Opaque_object_ref.to_hex (opaque_ref 1);
      V2_model.Opaque_object_ref.to_hex (opaque_ref 2);
      V2_model.Opaque_object_ref.to_hex (opaque_ref 3);
    ]
    (List.map V2_model.Opaque_object_ref.to_hex (Reclamation.marked plan));
  Alcotest.(check (list string))
    "opaque order determines eviction"
    [
      V2_model.Opaque_object_ref.to_hex (opaque_ref 4);
      V2_model.Opaque_object_ref.to_hex (opaque_ref 5);
    ]
    (candidate_ids plan);
  Alcotest.(check int64)
    "projected bytes fit budget" 65L
    (Reclamation.projected_bytes plan);
  let reversed =
    Reclamation.make_plan ~objects:(List.rev objects)
      ~roots:[ opaque_ref 1 ]
      ~cache_budget_bytes:70L
    |> require_ok Reclamation.error_to_string
  in
  Alcotest.(check string)
    "permuted inventory has same manifest"
    (Reclamation.encode_manifest plan)
    (Reclamation.encode_manifest reversed)

let required_overrun_has_no_candidates () =
  let plan =
    Reclamation.make_plan
      ~objects:
        [ entry 1 Object.Scratch_snapshot 101L; entry 2 Object.Release 5L ]
      ~roots:[ opaque_ref 1 ]
      ~cache_budget_bytes:100L
    |> require_ok Reclamation.error_to_string
  in
  Alcotest.(check (option int64))
    "root overrun remains visible" (Some 1L)
    (Reclamation.required_overrun plan);
  Alcotest.(check int)
    "required overrun does not evict" 0
    (List.length (Reclamation.candidates plan))

let manifest_is_canonical_and_identity_checked () =
  let plan =
    Reclamation.make_plan
      ~objects:
        [
          entry ~links:[ 2 ] 1 Object.Ledger_event 8L;
          entry 2 Object.Release 11L;
        ]
      ~roots:[ opaque_ref 1 ]
      ~cache_budget_bytes:10L
    |> require_ok Reclamation.error_to_string
  in
  let encoded = Reclamation.encode_manifest plan in
  let decoded =
    Reclamation.decode_manifest encoded
    |> require_ok Reclamation.error_to_string
  in
  Alcotest.(check string)
    "manifest round trips exactly" encoded
    (Reclamation.encode_manifest decoded);
  let value =
    Encoding.decode encoded |> require_ok Encoding.decode_error_to_string
  in
  let malformed =
    match value with
    | Encoding.Array [ version; _id; body ] ->
        Encoding.array [ version; Encoding.bytes (String.make 32 '\000'); body ]
        |> require_ok Encoding.construction_error_to_string
        |> Encoding.encode
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
        Alcotest.fail "manifest has unexpected shape"
  in
  match Reclamation.decode_manifest malformed with
  | Error Reclamation.Invalid_plan_id -> ()
  | Error
      (( Reclamation.Duplicate_object _ | Reclamation.Missing_object _
       | Reclamation.Negative_stored_bytes _ | Reclamation.Size_overflow
       | Reclamation.Negative_cache_budget _
       | Reclamation.Invalid_digest_length _ | Reclamation.Invalid_payload _
       | Reclamation.Unsupported_schema_version _
       | Reclamation.Invalid_mandatory_features _
       | Reclamation.Unsupported_mandatory_features _
       | Reclamation.Noncanonical_manifest ) as error) ->
      Alcotest.failf "wrong malformed-manifest error: %s"
        (Reclamation.error_to_string error)
  | Ok _ -> Alcotest.fail "manifest accepted mismatched plan ID"

let manifest_golden_is_exact_and_canonical () =
  let plan =
    Reclamation.make_plan
      ~objects:
        [
          entry ~links:[ 2 ] 1 Object.Ledger_event 8L;
          entry 2 Object.Release 11L;
          entry 3 Object.Validation_evidence 13L;
        ]
      ~roots:[ opaque_ref 1 ]
      ~cache_budget_bytes:20L
    |> require_ok Reclamation.error_to_string
  in
  let encoded = Reclamation.encode_manifest plan in
  let fixture =
    Golden.refresh_lower_hex_file
      (Filename.concat "golden" "v2-cache-reclamation-v1.cbor.hex")
      encoded
    |> require_ok Fun.id
  in
  Alcotest.(check string) "canonical cache-reclamation-v1 bytes" fixture encoded;
  let decoded =
    Reclamation.decode_manifest fixture
    |> require_ok Reclamation.error_to_string
  in
  Alcotest.(check string)
    "golden re-encodes exactly" fixture
    (Reclamation.encode_manifest decoded)

let no_marked_object_is_a_candidate =
  QCheck2.Test.make ~count:120
    ~name:"V2 reclamation never selects a marked object"
    QCheck2.Gen.(int_range 1 48)
    (fun count ->
      let objects =
        List.init count (fun index ->
            let value = index + 1 in
            let links = if index = 0 && count > 1 then [ 2 ] else [] in
            entry ~links value Object.Scratch_snapshot
              (Int64.of_int ((value mod 19) + 1)))
      in
      let plan =
        Reclamation.make_plan ~objects
          ~roots:[ opaque_ref 1 ]
          ~cache_budget_bytes:(Int64.of_int count)
        |> require_ok Reclamation.error_to_string
      in
      List.for_all
        (fun candidate ->
          not
            (List.exists
               (fun marked ->
                 V2_model.Opaque_object_ref.equal marked
                   (Reclamation.candidate_object_ref candidate))
               (Reclamation.marked plan)))
        (Reclamation.candidates plan))

let () =
  Alcotest.run "V2 cache reclamation"
    [
      ( "unit",
        [
          Alcotest.test_case "complete mark and deterministic quota" `Quick
            mark_and_quota_are_deterministic;
          Alcotest.test_case "required overrun preserves roots" `Quick
            required_overrun_has_no_candidates;
          Alcotest.test_case "canonical manifest rejects mismatched identity"
            `Quick manifest_is_canonical_and_identity_checked;
          Alcotest.test_case "cache-reclamation-v1 golden is canonical" `Quick
            manifest_golden_is_exact_and_canonical;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            no_marked_object_is_a_candidate;
        ] );
    ]
