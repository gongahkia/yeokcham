module M = Yeokcham_v1_model.Core
module R = Yeokcham_v1_record.Core
module T = Yeokcham_v1_trust
module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture

[@@@warning "-42"]

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)
let model result = ok M.error_to_string result
let record result = ok R.error_to_string result
let trust result = ok T.error_to_string result
let rejects label = function Error _ -> () | Ok _ -> Alcotest.fail label
let r c = M.Record_id.of_raw (String.make 32 c) |> model
let d c = M.Digest.of_raw (String.make 32 c) |> model
let o c = M.Object_id.of_raw (String.make 32 c) |> model
let branch = M.Branch_id.of_raw (String.make 16 'm') |> model
let repository = M.Repository_id.of_raw (String.make 32 'q') |> model
let change = M.Change_id.of_raw (String.make 16 'c') |> model

let capability =
  T.signing_capability_of_private_key (String.make 32 'a') |> trust

let device = T.device_of_public_key (T.signing_public_key capability) |> trust
let array v = E.array v |> Result.get_ok
let encoded v = E.encode (array v)

let fixture_context () =
  M.make_context ~repository ~author_certificate:(d 'c')
    ~authority_heads:[ d 'h'; d 'i' ]
    ~display_time:(Some 1234L)
  |> model

let fixture_payloads () =
  [
    M.Shared_revision
      (M.make_shared_revision ~change
         ~previous_revisions:[ r 'p' ]
         ~base_snapshot:(o 'b') ~result_snapshot:(o 'r')
         ~edit_scope_root:(o 's')
         ~dependencies:[ r 'd'; r 'e' ]
      |> model);
    M.Accepted_version
      (M.make_accepted_version ~branch
         ~accepted_parents:[ r 'a'; r 'b' ]
         ~chosen_revisions:[ r 'r' ]
         ~resolutions:[] ~result_snapshot:(o 'z')
         ~composition_profile:"line-hunks-v1" ~policy_heads:[]
         ~review_evidence:[]
      |> model);
    M.Branch_event
      (M.make_branch_event ~branch
         ~previous_events:[ r 'a'; r 'b' ]
         ~action:M.Reconcile
         ~targets:[ r 'v' ]
         ~display_name:None
      |> model);
  ]

let fixtures () =
  List.map
    (fun payload -> M.make_body ~context:(fixture_context ()) ~payload)
    (fixture_payloads ())

let golden name =
  let path = "golden/core/" ^ name ^ ".hex" in
  let path = if Sys.file_exists path then path else "test/" ^ path in
  Golden.read_lower_hex_file path |> ok Fun.id

let sign_unchecked body =
  let bytes = R.encode_body body |> record in
  let signature =
    T.sign_detached capability
      ~domain:(R.signature_domain (M.kind body.M.payload))
      bytes
    |> trust
  in
  R.attach_signature body ~signature |> record

let golden_vectors () =
  List.iter
    (fun body ->
      let kind = M.kind body.M.payload in
      let name = M.kind_name kind in
      let signed = sign_unchecked body in
      Alcotest.(check string)
        (name ^ " body")
        (golden (name ^ "-body"))
        (R.encode_body body |> record);
      Alcotest.(check string)
        (name ^ " Ed25519 input")
        (golden (name ^ "-signing-input"))
        (R.signing_input body |> record);
      let envelope = R.encode signed |> record in
      Alcotest.(check string)
        (name ^ " envelope/OpenSSL signature")
        (golden (name ^ "-envelope"))
        envelope;
      Alcotest.(check string)
        (name ^ " immutable identity")
        (golden (name ^ "-id"))
        (R.id signed |> record |> M.Record_id.to_raw);
      let decoded = R.decode ~repository envelope |> record in
      Alcotest.(check bool) "decoded body" true (R.body decoded = body);
      T.verify_detached ~device ~domain:(R.signature_domain kind)
        ~signature:(R.signature decoded)
        (R.encode_body (R.body decoded) |> record)
      |> trust;
      rejects "a different protocol domain cannot verify the same signature"
        (T.verify_detached ~device ~domain:"yeokcham/record/other/v1"
           ~signature:(R.signature decoded)
           (R.encode_body body |> record)))
    (fixtures ());
  let workspace = M.Workspace_id.of_raw (String.init 16 Char.chr) |> model in
  let history = M.History_id.make ~workspace ~sequence:Int64.max_int |> model in
  Alcotest.(check string)
    "history namespace/int64 bytes" (golden "history-id")
    (R.encode_history_id history);
  Alcotest.(check bool)
    "history vector decodes" true
    (M.History_id.equal history
       (R.decode_history_id (golden "history-id") |> record))

let value body = R.encode_body body |> record |> E.decode |> Result.get_ok

let replace index replacement = function
  | E.Array values ->
      array (List.mapi (fun i v -> if i = index then replacement else v) values)
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Map _ | E.Bool _ | E.Null ->
      Alcotest.fail "expected body"

let map_field key replacement = function
  | E.Map pairs ->
      E.map
        (List.map (fun (k, v) -> (k, if k = key then replacement else v)) pairs)
      |> Result.get_ok
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Array _ | E.Bool _ | E.Null ->
      Alcotest.fail "expected payload"

let replace_payload key replacement = function
  | E.Array values as body ->
      replace 6 (map_field key replacement (List.nth values 6)) body
  | E.Integer _ | E.Bytes _ | E.Text _ | E.Map _ | E.Bool _ | E.Null ->
      Alcotest.fail "expected body"

let malformed_bodies () =
  let shared, accepted, event =
    match fixtures () with
    | [ a; b; c ] -> (value a, value b, value c)
    | _ -> assert false
  in
  let bad label v = rejects label (R.decode_body ~repository (E.encode v)) in
  bad "unknown schema" (replace 1 (E.integer 2L) shared);
  bad "wrong scope" (replace 2 (E.bytes (String.make 32 'x')) shared);
  bad "short repository" (replace 2 (E.bytes "q") shared);
  bad "short certificate" (replace 4 (E.bytes "c") shared);
  bad "unknown kind" (replace 0 (E.text "future" |> Result.get_ok) shared);
  bad "negative display time" (replace 7 (E.integer (-1L)) shared);
  bad "empty authority" (replace 5 (array []) shared);
  bad "unsorted authority"
    (replace 5
       (array [ E.bytes (String.make 32 'i'); E.bytes (String.make 32 'h') ])
       shared);
  bad "duplicate authority"
    (replace 5
       (array [ E.bytes (String.make 32 'h'); E.bytes (String.make 32 'h') ])
       shared);
  bad "parents disagree with payload" (replace 3 (array []) shared);
  bad "malformed snapshot" (replace_payload 2L (E.bytes "short") shared);
  bad "duplicate dependencies"
    (replace_payload 5L
       (array [ E.bytes (String.make 32 'd'); E.bytes (String.make 32 'd') ])
       shared);
  bad "unsorted accepted parents"
    (replace_payload 1L
       (array [ E.bytes (String.make 32 'b'); E.bytes (String.make 32 'a') ])
       accepted);
  bad "unknown composition profile"
    (replace_payload 5L (E.text "future" |> Result.get_ok) accepted);
  bad "unknown action" (replace_payload 2L (E.integer 4L) event);
  bad "branch action mismatch" (replace_payload 2L (E.integer 0L) event);
  bad "invalid name" (replace_payload 4L (E.bytes "main") event);
  bad "extra payload fields"
    (replace 6 (E.map [ (0L, E.bytes "x") ] |> Result.get_ok) shared);
  bad "oversized set"
    (replace 5
       (array
          (List.init (M.max_references + 1) (fun _ ->
               E.bytes (String.make 32 'h'))))
       shared);
  let raw = E.encode shared in
  rejects "nonminimal CBOR array length"
    (R.decode_body ~repository
       ("\x98\x08" ^ String.sub raw 1 (String.length raw - 1)));
  rejects "trailing bytes" (R.decode_body ~repository (raw ^ "\x00"));
  rejects "oversized bytes"
    (R.decode_body ~repository (String.make (R.max_record_bytes + 1) 'x'));
  rejects "indefinite CBOR" (R.decode_body ~repository "\x9f\xff");
  rejects "huge declared collection"
    (R.decode_body ~repository "\x9b\x7f\xff\xff\xff\xff\xff\xff\xff");
  rejects "bounded nesting"
    (R.decode_body ~repository (String.make 20 '\x81' ^ "\xf6"));
  rejects "bounded parser work"
    (R.decode_body ~repository
       ("\x9a\x00\x02\x00\x81" ^ String.make 131201 '\xf6'));
  rejects "negative history sequence"
    (R.decode_history_id
       (encoded [ E.bytes (String.make 16 'w'); E.integer (-1L) ]));
  rejects "short history namespace"
    (R.decode_history_id (encoded [ E.bytes "w"; E.integer 0L ]));
  rejects "unsigned int64 overflow"
    (R.decode_history_id
       ("\x82\x50" ^ String.make 16 'w' ^ "\x1b\x80\x00\x00\x00\x00\x00\x00\x00"))

let envelope_for object_type body signature =
  Envelope.create ~object_type ~object_format_version:1 ~mandatory_features:0L
    ~payload:(array [ body; E.bytes signature ])
    ()
  |> Result.get_ok |> Envelope.encode

let header_change offset byte raw =
  let bytes = Bytes.of_string raw in
  Bytes.set bytes offset (Char.chr byte);
  let raw = Bytes.to_string bytes in
  let checksum =
    Yeokcham_hash.Sha256.(
      digest_string
        (String.sub raw 0 25 ^ String.sub raw 57 (String.length raw - 57))
      |> to_raw_string)
  in
  String.sub raw 0 25 ^ checksum ^ String.sub raw 57 (String.length raw - 57)

let malformed_envelopes () =
  let body = List.hd (fixtures ()) in
  let signed = sign_unchecked body in
  let raw = R.encode signed |> record in
  let bad label raw = rejects label (R.decode ~repository raw) in
  bad "wrong envelope kind"
    (envelope_for Envelope.Core_accepted_version (value body)
       (R.signature signed));
  bad "wrong signature size"
    (envelope_for Envelope.Core_shared_revision (value body) "short");
  bad "object version" (header_change 7 2 raw);
  bad "mandatory feature" (header_change 15 1 raw);
  bad "unknown object code" (header_change 5 255 raw);
  bad "unknown envelope version" (header_change 4 2 raw);
  let corrupt = Bytes.of_string raw in
  Bytes.set corrupt (String.length raw - 1) '\000';
  bad "checksum" (Bytes.to_string corrupt);
  bad "oversized envelope" (String.make (R.max_record_bytes + 1) 'x');
  for length = 0 to String.length raw - 1 do
    bad "truncated signed record" (String.sub raw 0 length)
  done;
  rejects "cannot attach short signature"
    (R.attach_signature body ~signature:"")

let properties =
  let open QCheck2 in
  [
    Test.make ~name:"history int64 namespace round trip" ~count:300
      (Gen.pair (Gen.string_size ~gen:Gen.char (Gen.return 16)) Gen.int64)
      (fun (raw, n) ->
        let workspace = M.Workspace_id.of_raw raw |> model in
        let id =
          M.History_id.make ~workspace ~sequence:(Int64.logand n Int64.max_int)
          |> model
        in
        M.History_id.equal id
          (R.decode_history_id (R.encode_history_id id) |> record));
    Test.make ~name:"malformed record decoding remains bounded and total"
      ~count:500
      (Gen.string_size ~gen:Gen.char (Gen.int_range 0 4096))
      (fun raw ->
        match R.decode ~repository raw with
        | Error _ -> true
        | Ok s -> R.encode s = Ok raw);
    Test.make
      ~name:"all body byte mutations either reject or reencode canonically"
      ~count:500
      (Gen.pair (Gen.int_range 0 500) (Gen.int_range 1 255))
      (fun (index, mask) ->
        let raw = golden "shared-revision-body" |> Bytes.of_string in
        let index = index mod Bytes.length raw in
        Bytes.set raw index
          (Char.chr (Char.code (Bytes.get raw index) lxor mask));
        let raw = Bytes.to_string raw in
        match R.decode_body ~repository raw with
        | Error _ -> true
        | Ok b -> R.encode_body b = Ok raw);
  ]
  |> List.map (fun test -> QCheck_alcotest.to_alcotest test)

let () =
  Alcotest.run "Core records"
    [
      ( "vectors",
        [
          Alcotest.test_case "independent CBOR/OpenSSL/identity fixtures" `Quick
            golden_vectors;
        ] );
      ( "negative",
        [
          Alcotest.test_case "body and history validation" `Quick
            malformed_bodies;
          Alcotest.test_case "envelope and mandatory features" `Quick
            malformed_envelopes;
        ] );
      ("properties", properties);
    ]
