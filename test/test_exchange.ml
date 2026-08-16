module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
module Golden = Yeokcham_testkit.Golden_fixture
module Store = Yeokcham_store

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_protocol result = require Exchange.error_to_string result
let require_store result = require Store.error_to_string result
let require_envelope result = require Envelope.creation_error_to_string result
let require_adapter result = require Exchange_store.error_to_string result

let session =
  Exchange.session_id_of_bytes "0123456789abcdef" |> require_protocol

let alternate_session =
  Exchange.session_id_of_bytes "abcdefghijklmnop" |> require_protocol

let id byte =
  match Store.Stored_object_id.of_raw_bytes (String.make 32 byte) with
  | Some value -> value
  | None -> Alcotest.fail "test object ID is invalid"

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let indexed_id index =
  let bytes = Bytes.make 32 '\000' in
  Bytes.set bytes 0 (Char.chr (index lsr 8));
  Bytes.set bytes 1 (Char.chr (index land 255));
  match Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string bytes) with
  | Some value -> value
  | None -> Alcotest.fail "indexed test object ID is invalid"

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

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

let with_repositories run =
  let root = Filename.temp_file "yeokcham-exchange-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require_store in
      let destination = Store.init ~root:destination_root |> require_store in
      run source destination)

let frame payload =
  let output = Bytes.create (String.length payload + 8) in
  let length = Int64.of_int (String.length payload) in
  for index = 0 to 7 do
    let shift = (7 - index) * 8 in
    let byte =
      Int64.(to_int (logand (shift_right_logical length shift) 255L))
    in
    Bytes.set output index (Char.chr byte)
  done;
  Bytes.blit_string payload 0 output 8 (String.length payload);
  Bytes.unsafe_to_string output

let require_encoding = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Encoding.construction_error_to_string error)

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require Fun.id

let expect_protocol_failure name result =
  Alcotest.(check bool) name true (Result.is_error result)

let expect_adapter_failure name result =
  Alcotest.(check bool) name true (Result.is_error result)

let samples =
  let object_id = id '\001' in
  [
    ( "exchange-v1-hello.frame.hex",
      Exchange.Hello
        {
          repository_format = Store.repository_format;
          supported_versions = [ 1 ];
          required_features = 0L;
        } );
    ( "exchange-v1-inventory.frame.hex",
      Exchange.Inventory
        {
          session_id = session;
          sequence = 7L;
          final = false;
          object_ids = [ object_id ];
          required_features = 0L;
        } );
    ( "exchange-v1-want.frame.hex",
      Exchange.Want
        {
          session_id = session;
          sequence = 7L;
          object_ids = [ object_id ];
          required_features = 0L;
        } );
    ( "exchange-v1-object.frame.hex",
      Exchange.Object
        {
          session_id = session;
          sequence = 0L;
          object_id;
          envelope_bytes = "\000\001\255";
          required_features = 0L;
        } );
    ( "exchange-v1-end.frame.hex",
      Exchange.End
        {
          session_id = session;
          status = Exchange.Complete;
          required_features = 0L;
        } );
    ( "exchange-v1-error.frame.hex",
      Exchange.Error_message
        {
          session_id = None;
          code = "incomplete";
          detail = "peer lost";
          required_features = 0L;
        } );
  ]

let golden_frames_are_exact () =
  List.iter
    (fun (name, message) ->
      let actual = Exchange.encode message |> require_protocol in
      let expected = refreshed_golden name actual in
      Alcotest.(check string) name expected actual;
      let decoded = Exchange.decode expected |> require_protocol in
      let reencoded = Exchange.encode decoded |> require_protocol in
      Alcotest.(check string) (name ^ " round trip") expected reencoded)
    samples

let malformed_frames_are_rejected () =
  expect_protocol_failure "truncated frame"
    (Exchange.decode (String.make 7 '\000'));
  expect_protocol_failure "bad frame length"
    (Exchange.decode (String.make 8 '\000' ^ "\000"));
  let noncanonical = frame "\x18\x01" in
  expect_protocol_failure "noncanonical CBOR" (Exchange.decode noncanonical);
  let payload =
    Encoding.array
      [
        Encoding.integer 1L;
        Encoding.integer 0L;
        Encoding.integer 1L;
        Encoding.bytes Store.repository_format;
        require_encoding (Encoding.array [ Encoding.integer 1L ]);
      ]
    |> require_encoding |> Encoding.encode
  in
  expect_protocol_failure "unknown required feature"
    (Exchange.decode (frame payload));
  let unsupported_version =
    Encoding.array
      [
        Encoding.integer 2L;
        Encoding.integer 0L;
        Encoding.integer 0L;
        Encoding.bytes Store.repository_format;
        require_encoding (Encoding.array [ Encoding.integer 1L ]);
      ]
    |> require_encoding |> Encoding.encode
  in
  expect_protocol_failure "unsupported protocol version"
    (Exchange.decode (frame unsupported_version))

let hello_and_ordering_are_enforced () =
  let receiver =
    Exchange.initial_receiver ~object_byte_budget:1024 |> require_protocol
  in
  let inventory =
    Exchange.Inventory
      {
        session_id = session;
        sequence = 0L;
        final = true;
        object_ids = [ id '\001' ];
        required_features = 0L;
      }
  in
  expect_protocol_failure "inventory before Hello"
    (Exchange.accept_inventory receiver inventory);
  let incompatible =
    Exchange.Hello
      {
        repository_format = "other";
        supported_versions = [ 1 ];
        required_features = 0L;
      }
  in
  expect_protocol_failure "incompatible Hello"
    (Exchange.accept_hello receiver incompatible);
  let unsorted =
    Exchange.Inventory
      {
        session_id = session;
        sequence = 0L;
        final = true;
        object_ids = [ id '\002'; id '\001' ];
        required_features = 0L;
      }
  in
  expect_protocol_failure "unsorted inventory" (Exchange.encode unsorted)

let limits_session_sequence_and_membership_are_enforced () =
  let page = List.init (Exchange.max_ids_per_page + 1) indexed_id in
  let oversized =
    Exchange.Inventory
      {
        session_id = session;
        sequence = 0L;
        final = false;
        object_ids = page;
        required_features = 0L;
      }
  in
  expect_protocol_failure "oversized inventory page" (Exchange.encode oversized);
  let receiver =
    Exchange.initial_receiver ~object_byte_budget:0 |> require_protocol
  in
  let hello =
    Exchange.Hello
      {
        repository_format = Store.repository_format;
        supported_versions = [ 1 ];
        required_features = 0L;
      }
  in
  let receiver = Exchange.accept_hello receiver hello |> require_protocol in
  let object_id = id '\003' in
  let inventory =
    Exchange.Inventory
      {
        session_id = session;
        sequence = 2L;
        final = false;
        object_ids = [ object_id ];
        required_features = 0L;
      }
  in
  let receiver, _ =
    Exchange.accept_inventory receiver inventory |> require_protocol
  in
  expect_protocol_failure "duplicate inventory sequence"
    (Exchange.accept_inventory receiver inventory);
  expect_protocol_failure "unoffered want"
    (Exchange.register_want receiver ~sequence:2L [ id '\004' ]);
  let wrong_session =
    Exchange.Object
      {
        session_id = alternate_session;
        sequence = 0L;
        object_id;
        envelope_bytes = "x";
        required_features = 0L;
      }
  in
  expect_protocol_failure "wrong object session"
    (Exchange.accept_object receiver wrong_session);
  expect_protocol_failure "unrequested object"
    (Exchange.accept_object receiver
       (Exchange.Object
          {
            session_id = session;
            sequence = 0L;
            object_id;
            envelope_bytes = "x";
            required_features = 0L;
          }));
  let receiver, _ =
    Exchange.register_want receiver ~sequence:2L [ object_id ]
    |> require_protocol
  in
  let limited_object =
    Exchange.Object
      {
        session_id = session;
        sequence = 0L;
        object_id;
        envelope_bytes = "x";
        required_features = 0L;
      }
  in
  expect_protocol_failure "object budget"
    (Exchange.accept_object receiver limited_object);
  expect_protocol_failure "complete end with pending want"
    (Exchange.accept_end receiver
       (Exchange.End
          {
            session_id = session;
            status = Exchange.Complete;
            required_features = 0L;
          }))

let setup_requested_object source object_id =
  let receiver =
    Exchange.initial_receiver ~object_byte_budget:1024 |> require_protocol
  in
  let hello =
    Exchange.Hello
      {
        repository_format = Store.repository_format;
        supported_versions = [ 1 ];
        required_features = 0L;
      }
  in
  let receiver = Exchange.accept_hello receiver hello |> require_protocol in
  let inventory =
    Exchange.Inventory
      {
        session_id = session;
        sequence = 4L;
        final = true;
        object_ids = [ object_id ];
        required_features = 0L;
      }
  in
  let receiver, _ =
    Exchange.accept_inventory receiver inventory |> require_protocol
  in
  let receiver, _ =
    Exchange.register_want receiver ~sequence:4L [ object_id ]
    |> require_protocol
  in
  (receiver, source)

let bad_identity_and_sequence_do_not_publish () =
  with_repositories (fun source destination ->
      let envelope = content "verified" in
      let source_id = Store.put source envelope |> require_store in
      let wrong_id = id '\007' in
      let receiver, _ = setup_requested_object source wrong_id in
      let object_message =
        Exchange.Object
          {
            session_id = session;
            sequence = 0L;
            object_id = wrong_id;
            envelope_bytes = Envelope.encode envelope;
            required_features = 0L;
          }
      in
      expect_adapter_failure "wrong object ID"
        (Exchange_store.receive_object destination receiver object_message);
      Alcotest.(check bool)
        "wrong object ID has no final file" false
        (Sys.file_exists (Store.object_path destination wrong_id));
      let receiver, _ = setup_requested_object source source_id in
      let invalid =
        Exchange.Object
          {
            session_id = session;
            sequence = 0L;
            object_id = source_id;
            envelope_bytes = "invalid";
            required_features = 0L;
          }
      in
      expect_adapter_failure "invalid envelope"
        (Exchange_store.receive_object destination receiver invalid);
      Alcotest.(check bool)
        "invalid envelope has no final file" false
        (Sys.file_exists (Store.object_path destination source_id));
      ignore (Store.put destination envelope |> require_store);
      let collision_path = Store.object_path destination source_id in
      write_file collision_path "corrupt";
      let receiver, _ = setup_requested_object source source_id in
      let valid =
        Exchange.Object
          {
            session_id = session;
            sequence = 0L;
            object_id = source_id;
            envelope_bytes = Envelope.encode envelope;
            required_features = 0L;
          }
      in
      expect_adapter_failure "collision refusal"
        (Exchange_store.receive_object destination receiver valid);
      Alcotest.(check string)
        "collision bytes remain untouched" "corrupt" (read_file collision_path))

let local_transfer_is_idempotent_and_leaves_refs () =
  with_repositories (fun source destination ->
      let source_id = Store.put source (content "source") |> require_store in
      let destination_id =
        Store.put destination (content "destination") |> require_store
      in
      let source_ref =
        Store.compare_and_swap_ref source ~name:"scratch-head" ~expected:None
          ~target:(Some source_id)
        |> require_store
      in
      let destination_ref =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some destination_id)
        |> require_store
      in
      let outcome : Exchange_store.outcome =
        Exchange_store.transfer ~source ~destination ~session_id:session
          ~object_ids:[ source_id ] ()
        |> require_adapter
      in
      let requested = outcome.Exchange_store.requested in
      let transferred = outcome.Exchange_store.transferred in
      Alcotest.(check int) "one requested" 1 requested;
      Alcotest.(check int) "one transferred" 1 (List.length transferred);
      ignore (Store.get destination source_id |> require_store);
      let repeated : Exchange_store.outcome =
        Exchange_store.transfer ~source ~destination
          ~session_id:alternate_session ~object_ids:[ source_id ] ()
        |> require_adapter
      in
      let requested = repeated.Exchange_store.requested in
      let transferred = repeated.Exchange_store.transferred in
      Alcotest.(check int) "existing object is not requested" 0 requested;
      Alcotest.(check (list string))
        "existing object is not transferred" []
        (List.map Store.Stored_object_id.to_hex transferred);
      let actual_source =
        Store.read_ref source ~name:"scratch-head" |> require_store
      in
      let actual_destination =
        Store.read_ref destination ~name:"scratch-head" |> require_store
      in
      Alcotest.(check bool)
        "source ref unchanged" true
        (Option.exists (Store.Mutable_ref.equal source_ref) actual_source);
      Alcotest.(check bool)
        "destination ref unchanged" true
        (Option.exists
           (Store.Mutable_ref.equal destination_ref)
           actual_destination))

let local_transfer_reports_reconciled_object_progress () =
  with_repositories (fun source destination ->
      let object_ids =
        [ "first"; "second" ]
        |> List.map (fun bytes ->
            Store.put source (content bytes) |> require_store)
        |> List.sort Store.Stored_object_id.compare
      in
      let observed = ref [] in
      ignore
        (Exchange_store.transfer
           ~on_progress:(fun ~completed ~total ->
             observed := (completed, total) :: !observed)
           ~source ~destination ~session_id:session ~object_ids ()
        |> require_adapter);
      Alcotest.(check (list (pair int int)))
        "transfer reconciles the exact offered inventory"
        [ (0, 2); (2, 2) ]
        (List.rev !observed))

let restart_after_interruption_preserves_refs () =
  with_repositories (fun source destination ->
      let ids =
        [ "a"; "b"; "c" ]
        |> List.map (fun bytes ->
            Store.put source (content bytes) |> require_store)
        |> List.sort Store.Stored_object_id.compare
      in
      let destination_ref_id =
        Store.put destination (content "local") |> require_store
      in
      let destination_ref =
        Store.compare_and_swap_ref destination ~name:"retention-head"
          ~expected:None ~target:(Some destination_ref_id)
        |> require_store
      in
      expect_adapter_failure "interrupted transfer"
        (Exchange_store.transfer ~interrupt_after:1 ~source ~destination
           ~session_id:session ~object_ids:ids ());
      let actual_ref =
        Store.read_ref destination ~name:"retention-head" |> require_store
      in
      Alcotest.(check bool)
        "interruption leaves ref unchanged" true
        (Option.exists (Store.Mutable_ref.equal destination_ref) actual_ref);
      ignore
        (Exchange_store.transfer ~source ~destination
           ~session_id:alternate_session ~object_ids:ids ()
        |> require_adapter);
      List.iter
        (fun object_id ->
          ignore (Store.get destination object_id |> require_store))
        ids)

let () =
  Alcotest.run "immutable object exchange"
    [
      ( "protocol",
        [
          Alcotest.test_case "golden frames are exact" `Quick
            golden_frames_are_exact;
          Alcotest.test_case "malformed frames are rejected" `Quick
            malformed_frames_are_rejected;
          Alcotest.test_case "Hello and ordering are enforced" `Quick
            hello_and_ordering_are_enforced;
          Alcotest.test_case
            "limits, session, sequence, and membership are enforced" `Quick
            limits_session_sequence_and_membership_are_enforced;
        ] );
      ( "local adapter",
        [
          Alcotest.test_case "bad identity and sequence do not publish" `Quick
            bad_identity_and_sequence_do_not_publish;
          Alcotest.test_case "transfer is idempotent and leaves refs" `Quick
            local_transfer_is_idempotent_and_leaves_refs;
          Alcotest.test_case "transfer reports reconciled object progress"
            `Quick local_transfer_reports_reconciled_object_progress;
          Alcotest.test_case "restart preserves refs" `Quick
            restart_after_interruption_preserves_refs;
        ] );
    ]
