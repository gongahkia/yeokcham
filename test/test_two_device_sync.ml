module Device = Paengi_device
module Device_store = Paengi_device_store
module Divergence = Paengi_divergence
module Divergence_store = Paengi_divergence_store
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Event = Paengi_ref_event
module Event_store = Paengi_ref_event_store
module Exchange = Paengi_exchange
module Exchange_store = Paengi_exchange_store
module Store = Paengi_store

type participant = {
  identity : Device.t;
  private_key : Mirage_crypto_ec.Ed25519.priv;
}

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_device result = require Device.error_to_string result
let require_device_store result = require Device_store.error_to_string result

let require_divergence_store result =
  require Divergence_store.error_to_string result

let require_envelope result = require Envelope.creation_error_to_string result
let require_event result = require Event.error_to_string result
let require_event_store result = require Event_store.error_to_string result
let require_exchange result = require Exchange_store.error_to_string result
let require_store result = require Store.error_to_string result

let participant seed =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr ((seed + index) land 255)))
    |> require (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  let device_id =
    Device.device_id_of_bytes
      (String.init 32 (fun index -> Char.chr ((seed + index + 64) land 255)))
    |> require_device
  in
  let generated =
    Device.make_generated ~device_id ~private_key ~mandatory_features:0L
    |> require_device
  in
  { identity = Device.generated_identity generated; private_key }

let left_device = participant 1
let right_device = participant 97

let trusted participants =
  List.map
    (fun participant ->
      {
        Event.key_id = Device.signer_key_id participant.identity;
        public_key = Device.public_key participant.identity;
      })
    participants

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let state generation target =
  Event.make_ref_state ~generation ~target |> require_event

let signed_event participant ~target =
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format
      ~ref_name:"scratch-head"
      ~signer_key_id:(Device.signer_key_id participant.identity)
      ~signer_sequence:0L ~previous:None ~observed:(state 0L None)
      ~proposed:(state 1L (Some target)) ~mandatory_features:0L
    |> require_event
  in
  let signature =
    Event.signing_bytes unsigned
    |> require_event
    |> Mirage_crypto_ec.Ed25519.sign ~key:participant.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require_event

let verify trusted_keys event =
  match
    Event.verify_for_device ~repository_format:Store.repository_format
      ~trusted_keys event
    |> require_event
  with
  | Some verified -> verified
  | None -> Alcotest.fail "trusted test event is untrusted"

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
  let root = Filename.temp_file "paengi-two-device-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let left_root = Filename.concat root "left" in
  let right_root = Filename.concat root "right" in
  Unix.mkdir left_root 0o700;
  Unix.mkdir right_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let left = Store.init ~root:left_root |> require_store in
      let right = Store.init ~root:right_root |> require_store in
      run left right)

let sorted = List.sort Store.Stored_object_id.compare

let session seed =
  Exchange.session_id_of_bytes
    (String.init 16 (fun index -> Char.chr ((seed + index) land 255)))
  |> require Exchange.error_to_string

let transfer ~source ~destination ~seed object_ids =
  Exchange_store.transfer ~source ~destination ~session_id:(session seed)
    ~object_ids:(sorted object_ids) ()
  |> require_exchange

let set_ref repository target =
  Store.compare_and_swap_ref repository ~name:"scratch-head" ~expected:None
    ~target:(Some target)
  |> require_store

let assert_ref repository expected =
  Alcotest.(check bool)
    "application ref is unchanged" true
    (Option.exists
       (Store.Mutable_ref.equal expected)
       (Store.read_ref repository ~name:"scratch-head" |> require_store))

let retained_competing_events_without_a_service () =
  with_repositories (fun left right ->
      let trusted_keys = trusted [ left_device; right_device ] in
      let left_target =
        Store.put left (content "left-target") |> require_store
      in
      let right_target =
        Store.put right (content "right-target") |> require_store
      in
      let left_ref =
        Store.put left (content "left-retained")
        |> require_store |> set_ref left
      in
      let right_ref =
        Store.put right (content "right-retained")
        |> require_store |> set_ref right
      in
      let left_identity =
        Device_store.store_identity left left_device.identity
        |> require_device_store
      in
      let right_identity =
        Device_store.store_identity right right_device.identity
        |> require_device_store
      in
      let left_event = signed_event left_device ~target:left_target in
      let right_event = signed_event right_device ~target:right_target in
      let left_event_id =
        Event_store.store_event left left_event |> require_event_store
      in
      let right_event_id =
        Event_store.store_event right right_event |> require_event_store
      in
      Alcotest.(check bool)
        "right initially lacks left target" true
        (Result.is_error (Store.get right left_target));
      transfer ~source:left ~destination:right ~seed:1
        [ left_identity; left_target; left_event_id ]
      |> ignore;
      transfer ~source:right ~destination:left ~seed:33
        [ right_identity; right_target; right_event_id ]
      |> ignore;
      let left_verified =
        Event_store.load_event left left_event_id
        |> require_event_store |> verify trusted_keys
      in
      let right_verified =
        Event_store.load_event left right_event_id
        |> require_event_store |> verify trusted_keys
      in
      let registry =
        Device_store.registry_of_objects left [ left_identity; right_identity ]
        |> require_device_store
      in
      let resolved = Device.resolve_verified registry right_verified in
      Alcotest.(check bool)
        "remote event resolves to a transferred device" true
        (match resolved with
        | Device.Device_resolved { object_id; _ } ->
            Store.Stored_object_id.equal object_id right_identity
        | Device.Device_unmapped _ | Device.Device_ambiguous _ -> false);
      let left_entry =
        Divergence.entry_of_verified ~object_id:left_event_id left_verified
      in
      let right_entry =
        Divergence.entry_of_verified ~object_id:right_event_id right_verified
      in
      let left_set =
        Divergence_store.publish left ~trusted_keys [ left_entry; right_entry ]
        |> require_divergence_store
      in
      let right_set =
        Divergence_store.publish right ~trusted_keys [ left_entry; right_entry ]
        |> require_divergence_store
      in
      Alcotest.(check bool)
        "both devices retain one divergence set" true
        (Store.Stored_object_id.equal left_set right_set);
      Alcotest.(check int)
        "competing events remain explicit" 2
        (Divergence_store.load_published left ~trusted_keys
           ~ref_name:"scratch-head"
        |> require_divergence_store |> Option.get |> Divergence.entries
        |> List.length);
      assert_ref left left_ref;
      assert_ref right right_ref)

let restart_and_corruption_are_local_and_structured () =
  with_repositories (fun left right ->
      let objects =
        [ "one"; "two"; "three" ]
        |> List.map (fun payload ->
            Store.put left (content payload) |> require_store)
        |> sorted
      in
      let retained =
        Store.put right (content "right-retained") |> require_store
      in
      let reference = set_ref right retained in
      Alcotest.(check bool)
        "interruption is structured" true
        (Result.is_error
           (Exchange_store.transfer ~interrupt_after:1 ~source:left
              ~destination:right ~session_id:(session 65) ~object_ids:objects ()));
      assert_ref right reference;
      let right =
        Store.open_repository ~root:(Store.root right) |> require_store
      in
      transfer ~source:left ~destination:right ~seed:97 objects |> ignore;
      List.iter
        (fun object_id -> ignore (Store.get right object_id |> require_store))
        objects;
      assert_ref right reference;
      let corrupted = List.hd objects in
      let output = open_out_bin (Store.object_path left corrupted) in
      Fun.protect
        ~finally:(fun () -> close_out_noerr output)
        (fun () -> output_string output "corrupt");
      let fresh_root = Filename.temp_file "paengi-two-device-corrupt-" "" in
      Unix.unlink fresh_root;
      Unix.mkdir fresh_root 0o700;
      Fun.protect
        ~finally:(fun () -> remove_tree fresh_root)
        (fun () ->
          let fresh = Store.init ~root:fresh_root |> require_store in
          let fresh_retained =
            Store.put fresh (content "fresh-retained") |> require_store
          in
          let fresh_ref = set_ref fresh fresh_retained in
          Alcotest.(check bool)
            "corrupt source object rejects" true
            (Result.is_error
               (Exchange_store.transfer ~source:left ~destination:fresh
                  ~session_id:(session 129) ~object_ids:objects ()));
          Alcotest.(check bool)
            "corrupt object is not published" true
            (Result.is_error (Store.get fresh corrupted));
          assert_ref fresh fresh_ref))

let () =
  Alcotest.run "two-device synchronisation"
    [
      ( "integration",
        [
          Alcotest.test_case "retains competing events without a service" `Quick
            retained_competing_events_without_a_service;
          Alcotest.test_case "restart and corruption stay local" `Quick
            restart_and_corruption_are_local_and_structured;
        ] );
    ]
