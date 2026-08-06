module Divergence = Paengi_divergence
module Divergence_store = Paengi_divergence_store
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Event = Paengi_ref_event
module Event_store = Paengi_ref_event_store
module Exchange = Paengi_exchange
module Exchange_store = Paengi_exchange_store
module Store = Paengi_store

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Event.signer_key_id;
}

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_envelope result = require Envelope.creation_error_to_string result
let require_event result = require Event.error_to_string result
let require_event_store result = require Event_store.error_to_string result
let require_exchange result = require Exchange_store.error_to_string result
let require_divergence result = require Divergence_store.error_to_string result
let require_store result = require Store.error_to_string result

let signer seed =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr ((seed + index) land 255)))
    |> require (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let key_id = Event.signer_key_id_of_public_key public_key |> require_event in
  { private_key; public_key; key_id }

let left_signer = signer 1
let right_signer = signer 97

let trusted =
  [
    { Event.key_id = left_signer.key_id; public_key = left_signer.public_key };
    { Event.key_id = right_signer.key_id; public_key = right_signer.public_key };
  ]

let payload =
  Encoding.array [ Encoding.integer 1L ]
  |> require Encoding.construction_error_to_string

let stored_envelope object_type =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> require_envelope

let state generation target =
  Event.make_ref_state ~generation ~target |> require_event

let event signer ~ref_name ~target =
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format ~ref_name
      ~signer_key_id:signer.key_id ~signer_sequence:0L ~previous:None
      ~observed:(state 0L None) ~proposed:(state 1L (Some target))
      ~mandatory_features:0L
    |> require_event
  in
  let signature =
    Event.signing_bytes unsigned
    |> require_event
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require_event

let verify value =
  match
    Event.verify_for_device ~repository_format:Store.repository_format
      ~trusted_keys:trusted value
    |> require_event
  with
  | Some verified -> verified
  | None -> Alcotest.fail "trusted event is untrusted"

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
  let root = Filename.temp_file "paengi-workspace-release-divergence-" "" in
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

let transfer source destination seed object_ids =
  let session =
    Exchange.session_id_of_bytes
      (String.init 16 (fun index -> Char.chr ((seed + index) land 255)))
    |> require Exchange.error_to_string
  in
  Exchange_store.transfer ~source ~destination ~session_id:session
    ~object_ids:(List.sort Store.Stored_object_id.compare object_ids)
    ()
  |> require_exchange |> ignore

let preserves_ref_kind ref_name object_type () =
  with_repositories (fun left right ->
      let left_target =
        Store.put left (stored_envelope object_type) |> require_store
      in
      let right_target =
        Store.put right (stored_envelope object_type) |> require_store
      in
      let left_retained =
        Store.put left (stored_envelope Envelope.Content) |> require_store
      in
      let right_retained =
        Store.put right (stored_envelope Envelope.Content) |> require_store
      in
      let left_ref =
        Store.compare_and_swap_ref left ~name:ref_name ~expected:None
          ~target:(Some left_retained)
        |> require_store
      in
      let right_ref =
        Store.compare_and_swap_ref right ~name:ref_name ~expected:None
          ~target:(Some right_retained)
        |> require_store
      in
      let left_event = event left_signer ~ref_name ~target:left_target in
      let right_event = event right_signer ~ref_name ~target:right_target in
      let left_event_id =
        Event_store.store_event left left_event |> require_event_store
      in
      let right_event_id =
        Event_store.store_event right right_event |> require_event_store
      in
      transfer left right 1 [ left_target; left_event_id ];
      transfer right left 33 [ right_target; right_event_id ];
      let entries repository =
        [
          Divergence.entry_of_verified ~object_id:left_event_id
            (Event_store.load_event repository left_event_id
            |> require_event_store |> verify);
          Divergence.entry_of_verified ~object_id:right_event_id
            (Event_store.load_event repository right_event_id
            |> require_event_store |> verify);
        ]
      in
      let left_set =
        Divergence_store.publish left ~trusted_keys:trusted (entries left)
        |> require_divergence
      in
      let right_set =
        Divergence_store.publish right ~trusted_keys:trusted (entries right)
        |> require_divergence
      in
      Alcotest.(check bool)
        "both devices retain one exact candidate set" true
        (Store.Stored_object_id.equal left_set right_set);
      let reopened =
        Store.open_repository ~root:(Store.root left) |> require_store
      in
      Alcotest.(check int)
        "both divergent histories remain inspectable" 2
        (Divergence_store.load_published reopened ~trusted_keys:trusted
           ~ref_name
        |> require_divergence |> Option.get |> Divergence.entries |> List.length
        );
      Alcotest.(check bool)
        "left ref is unchanged" true
        (Store.read_ref reopened ~name:ref_name
        |> require_store
        |> Option.exists (Store.Mutable_ref.equal left_ref));
      Alcotest.(check bool)
        "right ref is unchanged" true
        (Store.read_ref right ~name:ref_name
        |> require_store
        |> Option.exists (Store.Mutable_ref.equal right_ref)))

let () =
  Alcotest.run "workspace and release divergence"
    [
      ( "divergence",
        [
          Alcotest.test_case "workspace refs retain both histories" `Quick
            (preserves_ref_kind "workspace-head" Envelope.Workspace);
          Alcotest.test_case "release refs retain both histories" `Quick
            (preserves_ref_kind "release-head" Envelope.Release);
        ] );
    ]
