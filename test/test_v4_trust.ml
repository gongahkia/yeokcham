module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let id parser value = parser value |> Result.get_ok
let change value = id Model.Change_id.of_string value
let revision value = id Model.Revision_id.of_string value
let snapshot value = id Model.Snapshot_id.of_string value

let capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let device_from_capability capability =
  capability |> Trust.signing_public_key |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let sample_revision author =
  Model.make_change_revision ~change:(change "change-one")
    ~revision:(revision "revision-one") ~parent:None ~author
    ~base:(snapshot "snapshot-base")
    ~result:(snapshot "snapshot-result")
    ~edits:
      [
        {
          Model.edit_path =
            Model.Path.of_components [ "main.ml" ] |> Result.get_ok;
          edit_kind = Model.Whole_path;
        };
      ]
  |> require_ok Model.error_to_string

let root_and_membership () =
  let repository =
    Trust.Repository_id.of_string
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> Result.get_ok
  in
  let root_capability = capability 'a' in
  let root_device = device_from_capability root_capability in
  let root_certificate =
    Trust.root_certificate ~repository ~device:root_device root_capability
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.verify_membership ~repository [ root_certificate ]
    |> require_ok Trust.error_to_string
  in
  (repository, root_capability, root_device, root_certificate, membership)

let root_certificate_is_self_certifying () =
  let repository, _, root_device, root_certificate, membership =
    root_and_membership ()
  in
  Alcotest.(check bool)
    "root is authorized" true
    (Trust.is_authorized membership root_device);
  Alcotest.(check bool)
    "root is administrator" true
    (Trust.is_administrator membership root_device);
  Alcotest.(check string)
    "certificate repository binding"
    (Trust.Repository_id.to_string repository)
    (Trust.Repository_id.to_string
       (Trust.certificate_repository root_certificate));
  let decoded =
    root_certificate |> Trust.encode_certificate |> Trust.decode_certificate
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check string)
    "certificate bytes retain their derived identity"
    (Trust.certificate_id root_certificate)
    (Trust.certificate_id decoded)

let administrator_enrols_a_member_in_causal_order () =
  let repository, root_capability, _, root_certificate, membership =
    root_and_membership ()
  in
  let member_capability = capability 'b' in
  let member_device = device_from_capability member_capability in
  let member_certificate =
    Trust.enroll membership
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~subject:member_device ~role:Trust.Member
    |> require_ok Trust.error_to_string
  in
  let verified =
    Trust.verify_membership ~repository [ member_certificate; root_certificate ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check bool)
    "member is authorized after causal verification" true
    (Trust.is_authorized verified member_device);
  Alcotest.(check bool)
    "member is not silently an administrator" false
    (Trust.is_administrator verified member_device);
  let extended =
    Trust.extend_membership membership [ member_certificate ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check bool)
    "a causal certificate extends an existing membership" true
    (Trust.is_authorized extended member_device);
  let replay =
    Trust.enroll verified
      ~issuer:(Trust.certificate_id member_certificate)
      member_capability
      ~subject:(device_from_capability (capability 'c'))
      ~role:Trust.Member
  in
  match replay with
  | Error error ->
      Alcotest.(check string)
        "member cannot enrol another device"
        "V4 certificate issuer is not an administrator"
        (Trust.error_to_string error)
  | Ok _ -> Alcotest.fail "a member enrolled another device"

let signed_revision_binds_author_and_membership () =
  let repository, root_capability, _, root_certificate, membership =
    root_and_membership ()
  in
  let author_capability = capability 'b' in
  let author = device_from_capability author_capability in
  let author_certificate =
    Trust.enroll membership
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~subject:author ~role:Trust.Member
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.verify_membership ~repository [ root_certificate; author_certificate ]
    |> require_ok Trust.error_to_string
  in
  let signed =
    Trust.sign_revision membership
      ~certificate:(Trust.certificate_id author_certificate)
      author_capability
      (sample_revision (Trust.device_id author))
    |> require_ok Trust.error_to_string
  in
  Trust.verify_signed_revision membership signed
  |> require_ok Trust.error_to_string;
  let decoded =
    signed |> Trust.encode_signed_revision |> Trust.decode_signed_revision
    |> require_ok Trust.error_to_string
  in
  Trust.verify_signed_revision membership decoded
  |> require_ok Trust.error_to_string;
  let tampered_bytes = Bytes.of_string (Trust.encode_signed_revision decoded) in
  let last = Bytes.length tampered_bytes - 1 in
  Bytes.set tampered_bytes last
    (Char.chr (Char.code (Bytes.get tampered_bytes last) lxor 1));
  let tampered =
    Trust.decode_signed_revision (Bytes.to_string tampered_bytes)
    |> require_ok Trust.error_to_string
  in
  (match Trust.verify_signed_revision membership tampered with
  | Error error ->
      Alcotest.(check string)
        "tampered signature is rejected" "V4 Ed25519 signature is invalid"
        (Trust.error_to_string error)
  | Ok () -> Alcotest.fail "tampered signed revision verified");
  let root_only =
    Trust.verify_membership ~repository [ root_certificate ]
    |> require_ok Trust.error_to_string
  in
  match Trust.verify_signed_revision root_only decoded with
  | Error error ->
      Alcotest.(check string)
        "missing author certificate is rejected"
        "V4 revision author certificate is unknown"
        (Trust.error_to_string error)
  | Ok () -> Alcotest.fail "missing author certificate verified a revision"

let () =
  Alcotest.run "V4 trust"
    [
      ( "identity",
        [
          Alcotest.test_case "root certificate is self-certifying" `Quick
            root_certificate_is_self_certifying;
          Alcotest.test_case "administrator enrols a causal member" `Quick
            administrator_enrols_a_member_in_causal_order;
          Alcotest.test_case "signed revision binds author and membership"
            `Quick signed_revision_binds_author_and_membership;
        ] );
    ]
