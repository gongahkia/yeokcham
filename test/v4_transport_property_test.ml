module Transport = Yeokcham_v4_transport
module Trust = Yeokcham_v4_trust
module V2 = Transport.V2

let capability =
  Trust.signing_capability_of_private_key (String.make 32 'a') |> Result.get_ok

let publisher =
  Trust.signing_public_key capability
  |> Trust.device_of_public_key |> Result.get_ok

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let certificate =
  Trust.root_certificate ~repository ~device:publisher capability
  |> Result.get_ok |> Trust.certificate_id

let generated_linear_feeds_preserve_parent_availability =
  QCheck2.Test.make ~count:200
    ~name:"generated canonical relay feeds retain every parent before receipt"
    QCheck2.Gen.(int_range 0 40)
    (fun length ->
      let rec build parent reversed index =
        if index = length then List.rev reversed
        else
          let publication =
            Transport.create_publication ~repository ~publisher ~certificate
              ~parents:(Option.to_list parent)
              ~manifest:(Transport.sha256 ("manifest-" ^ string_of_int index))
              ~signing_capability:capability
            |> Result.get_ok
          in
          build
            (Some (Transport.publication_id publication))
            (publication :: reversed) (index + 1)
      in
      Transport.validate_feed ~known:[] (build None [] 0) |> Result.is_ok)

let digest character = String.make 64 character

let partition_covers_exact_raw_bytes_without_overlap =
  QCheck2.Test.make ~count:300
    ~name:"V2 raw range partitions cover exactly once with bounded segments"
    QCheck2.Gen.(int_range 0 ((V2.segment_bytes * 4) + 137))
    (fun raw_size ->
      let offer =
        V2.object_offer ~project:(digest 'a') ~object_id:(digest 'b') ~raw_size
        |> Result.get_ok
      in
      let ranges = V2.partition offer |> Result.get_ok in
      let final_offset, valid =
        List.fold_left
          (fun (offset, valid) range ->
            let range_offset = V2.range_offset range in
            let length = V2.range_length range in
            ( range_offset + length,
              valid && range_offset = offset && length > 0
              && length <= V2.segment_bytes ))
          (0, true) ranges
      in
      valid && final_offset = raw_size)

let repeated_receipt_is_idempotent_and_progress_is_monotonic =
  QCheck2.Test.make ~count:300
    ~name:"V2 arbitrary segment order retains only a monotonic exact bitmap"
    QCheck2.Gen.(
      pair (int_range 1 7) (list_size (int_range 0 32) (int_range 0 6)))
    (fun (segment_count, indexes) ->
      let raw_size = (segment_count * V2.segment_bytes) - 11 in
      let offer =
        V2.object_offer ~project:(digest 'a') ~object_id:(digest 'b') ~raw_size
        |> Result.get_ok
      in
      let initial =
        V2.session ~id:(digest 'c') ~offer ~credential_id:(digest 'd')
          ~scope:V2.Upload ~expires_at:100L ~quota_bytes:raw_size
          ~credential_session_count:0
        |> Result.get_ok
      in
      let ranges = V2.partition offer |> Result.get_ok in
      let indexes =
        indexes |> List.map (fun index -> index mod List.length ranges)
      in
      let final, monotonic =
        List.fold_left
          (fun (session, monotonic) index ->
            let segment =
              V2.segment ~range:(List.nth ranges index) ~raw_sha256:(digest 'e')
              |> Result.get_ok
            in
            let before =
              V2.session_progress session |> V2.progress_ranges |> List.length
            in
            let next =
              V2.receive_segment ~now:1L ~session segment |> Result.get_ok
            in
            let after =
              V2.session_progress next |> V2.progress_ranges |> List.length
            in
            (next, monotonic && after >= before))
          (initial, true) indexes
      in
      let expected = List.sort_uniq Int.compare indexes |> List.length in
      monotonic
      && List.length (V2.progress_ranges (V2.session_progress final)) = expected)

let () =
  Alcotest.run "V4 transport properties"
    [
      ( "feed",
        [
          QCheck_alcotest.to_alcotest
            generated_linear_feeds_preserve_parent_availability;
        ] );
      ( "V2 transfer core",
        [
          QCheck_alcotest.to_alcotest
            partition_covers_exact_raw_bytes_without_overlap;
          QCheck_alcotest.to_alcotest
            repeated_receipt_is_idempotent_and_progress_is_monotonic;
        ] );
    ]
