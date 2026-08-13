module Authority = Yeokcham_v2_authority
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Group = Yeokcham_v2_mls_group
module Invitation = Yeokcham_v2_mls_invitation
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository byte =
  Model.Repository_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let device byte =
  Model.Device_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let nonce byte =
  Envelope.nonce_of_bytes (String.make 12 byte)
  |> require_ok Envelope.error_to_string

let key byte =
  Envelope.key_of_bytes (String.make 32 byte)
  |> require_ok Envelope.error_to_string

let root seed =
  String.init 32 (fun index -> Char.chr ((seed + index) land 255))
  |> Authority.root_signing_capability_of_private_key
  |> require_ok Authority.error_to_string

let authority repository_id root =
  Authority.make_repository_authority ~repository_id ~root
    ~mandatory_features:0L
  |> require_ok Authority.error_to_string

let issue ?(expires_at = 20L) () =
  let repository_id = repository 'r' in
  let root = root 7 in
  let authority = authority repository_id root in
  let runtime = Runtime.default_configuration in
  let issuer_state =
    Group.create ~runtime ~repository_id ~device_id:(device 'i')
    |> require_ok Group.error_to_string
  in
  let result =
    Invitation.issue ~runtime ~authority ~root ~issuer_state
      ~recipient_device_id:(device 'r') ~issued_at:10L ~expires_at
      ~invitation_key:(key 'k') ~invitation_nonce:(nonce 'n')
      ~event_nonce:(nonce 'e')
    |> require_ok Invitation.error_to_string
  in
  (runtime, root, authority, result)

let successful_join_is_signed_encrypted_and_single_use () =
  let runtime, root, authority, issue = issue () in
  let invitation_bytes =
    Invitation.encode_invitation issue.Invitation.invitation
  in
  let invitation =
    Invitation.decode_invitation ~authority invitation_bytes
    |> require_ok Invitation.error_to_string
  in
  let issued_event =
    Invitation.decode_membership_event ~authority
      (Invitation.encode_membership_event issue.Invitation.issued_event)
    |> require_ok Invitation.error_to_string
  in
  Group.verify ~runtime issue.Invitation.issuer_state
  |> require_ok Group.error_to_string;
  let acceptance =
    Invitation.accept ~runtime ~authority ~root ~invitation
      ~history:[ issued_event ] ~now:11L ~invitation_key:(key 'k')
      ~event_nonce:(nonce 'a')
    |> require_ok Invitation.error_to_string
  in
  Group.verify ~runtime acceptance.Invitation.recipient_state
  |> require_ok Group.error_to_string;
  let accepted_event =
    Invitation.decode_membership_event ~authority
      (Invitation.encode_membership_event acceptance.Invitation.accepted_event)
    |> require_ok Invitation.error_to_string
  in
  Alcotest.(check bool) "history is accepted" true
    (Invitation.lifecycle ~authority ~invitation
       [ issued_event; accepted_event ]
    |> require_ok Invitation.error_to_string
    = Invitation.Accepted);
  Alcotest.(check bool) "same invitation cannot be accepted twice" true
    (Result.is_error
       (Invitation.accept ~runtime ~authority ~root ~invitation
          ~history:[ issued_event; accepted_event ] ~now:12L
          ~invitation_key:(key 'k') ~event_nonce:(nonce 'b')))

let expiry_revocation_tampering_and_wrong_secrets_refuse () =
  let runtime, root, authority, issue = issue () in
  Alcotest.(check bool) "wrong invitation secret refuses" true
    (Result.is_error
       (Invitation.accept ~runtime ~authority ~root
          ~invitation:issue.Invitation.invitation
          ~history:[ issue.Invitation.issued_event ] ~now:11L ~invitation_key:(key 'x')
          ~event_nonce:(nonce 'a')));
  Alcotest.(check bool) "expiry refuses" true
    (Result.is_error
       (Invitation.accept ~runtime ~authority ~root
          ~invitation:issue.Invitation.invitation
          ~history:[ issue.Invitation.issued_event ] ~now:20L ~invitation_key:(key 'k')
          ~event_nonce:(nonce 'a')));
  let revoked =
    Invitation.revoke ~authority ~root ~invitation:issue.Invitation.invitation
      ~history:[ issue.Invitation.issued_event ] ~revoked_at:12L ~invitation_key:(key 'k')
      ~event_nonce:(nonce 'v')
    |> require_ok Invitation.error_to_string
  in
  Alcotest.(check bool) "revocation refuses acceptance" true
    (Result.is_error
       (Invitation.accept ~runtime ~authority ~root
          ~invitation:issue.Invitation.invitation
          ~history:[ issue.Invitation.issued_event; revoked ] ~now:13L
          ~invitation_key:(key 'k') ~event_nonce:(nonce 'a')));
  let encoded = Invitation.encode_invitation issue.Invitation.invitation in
  let tampered = Bytes.of_string encoded in
  Bytes.set tampered (Bytes.length tampered - 1)
    (Char.chr (Char.code (Bytes.get tampered (Bytes.length tampered - 1)) lxor 1));
  Alcotest.(check bool) "tampered signed invitation refuses" true
    (Result.is_error
       (Invitation.decode_invitation ~authority (Bytes.unsafe_to_string tampered)))

let unauthorized_root_cannot_issue () =
  let runtime, _, authority, issue = issue () in
  Alcotest.(check bool) "a non-authority root cannot invite" true
    (Result.is_error
       (Invitation.issue ~runtime ~authority ~root:(root 91)
          ~issuer_state:issue.Invitation.issuer_state ~recipient_device_id:(device 'z')
          ~issued_at:30L ~expires_at:40L ~invitation_key:(key 'k')
          ~invitation_nonce:(nonce 'n') ~event_nonce:(nonce 'e')))

let membership_event_fixture_is_canonical () =
  let repository_id = repository 'r' in
  let root = root 7 in
  let authority = authority repository_id root in
  let bytes =
    Golden.read_lower_hex_file "golden/v2-mls-membership-event-v1.cbor.hex"
    |> require_ok Fun.id
  in
  let event =
    Invitation.decode_membership_event ~authority bytes
    |> require_ok Invitation.error_to_string
  in
  Alcotest.(check string) "membership event fixture re-encodes exactly" bytes
    (Invitation.encode_membership_event event)

let () =
  Alcotest.run "V2 MLS invitations"
    [
      ( "unit",
        [
          Alcotest.test_case "root-signed encrypted MLS join is single-use" `Slow
            successful_join_is_signed_encrypted_and_single_use;
          Alcotest.test_case "expiry, revocation, tampering, and wrong secrets refuse" `Slow
            expiry_revocation_tampering_and_wrong_secrets_refuse;
          Alcotest.test_case "unauthorized roots cannot issue invitations" `Slow
            unauthorized_root_cannot_issue;
          Alcotest.test_case "membership event golden is canonical" `Quick
            membership_event_fixture_is_canonical;
        ] );
    ]
