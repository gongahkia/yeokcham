module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> require_ok Fun.id

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

let authority_for_membership ~membership ~root_capability ~root_certificate =
  let recovery_device = device_from_capability (capability 'r') in
  let root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device root_capability
    |> require_ok Trust.error_to_string
  in
  let root_authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  let active_epoch =
    Trust.successor_epoch root_authority
      ~parents:[ Trust.epoch_id root_epoch ]
      ~certificates:(Trust.certificates membership)
      ~revoked:[] ~frontier:[] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.extend_authority root_authority [ active_epoch ]
    |> require_ok Trust.error_to_string
  in
  (authority, Trust.epoch_id active_epoch)

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
    (Trust.certificate_id decoded);
  Alcotest.(check string)
    "certificate bytes retain their golden encoding"
    (read_golden "v1/certificate-v1.cbor.hex")
    (Trust.encode_certificate root_certificate)

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
        "V1 certificate issuer is not an administrator"
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
  let authority, epoch =
    authority_for_membership ~membership ~root_capability ~root_certificate
  in
  let signed =
    Trust.sign_revision_at authority ~epoch
      ~certificate:(Trust.certificate_id author_certificate)
      author_capability
      (sample_revision (Trust.device_id author))
    |> require_ok Trust.error_to_string
  in
  let encoded = Trust.encode_signed_revision signed in
  Alcotest.(check string)
    "signed revision bytes retain their golden encoding"
    (read_golden "v1/signed-revision-v1.cbor.hex")
    encoded;
  Trust.verify_signed_revision_at authority signed
  |> require_ok Trust.error_to_string;
  let decoded =
    signed |> Trust.encode_signed_revision |> Trust.decode_signed_revision
    |> require_ok Trust.error_to_string
  in
  Trust.verify_signed_revision_at authority decoded
  |> require_ok Trust.error_to_string;
  let tampered_bytes = Bytes.of_string (Trust.encode_signed_revision decoded) in
  let last = Bytes.length tampered_bytes - 1 in
  Bytes.set tampered_bytes last
    (Char.chr (Char.code (Bytes.get tampered_bytes last) lxor 1));
  let tampered =
    Trust.decode_signed_revision (Bytes.to_string tampered_bytes)
    |> require_ok Trust.error_to_string
  in
  (match Trust.verify_signed_revision_at authority tampered with
  | Error error ->
      Alcotest.(check string)
        "tampered signature is rejected" "V1 Ed25519 signature is invalid"
        (Trust.error_to_string error)
  | Ok () -> Alcotest.fail "tampered signed revision verified");
  let root_only =
    Trust.verify_membership ~repository [ root_certificate ]
    |> require_ok Trust.error_to_string
  in
  let root_only_authority, _ =
    authority_for_membership ~membership:root_only ~root_capability
      ~root_certificate
  in
  match Trust.verify_signed_revision_at root_only_authority decoded with
  | Error error ->
      Alcotest.(check string)
        "missing author certificate is rejected" "V1 authority epoch is unknown"
        (Trust.error_to_string error)
  | Ok () -> Alcotest.fail "missing author certificate verified a revision"

let signed_resolution_binds_its_target_decision () =
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
  let authority, epoch =
    authority_for_membership ~membership ~root_capability ~root_certificate
  in
  let decision = id Model.Decision_id.of_string "decision-resolution" in
  let signed =
    Trust.sign_resolution_at authority ~epoch
      ~certificate:(Trust.certificate_id author_certificate)
      author_capability ~decision
      (sample_revision (Trust.device_id author))
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check (option string))
    "the signed record carries its resolution decision"
    (Some (Model.Decision_id.to_string decision))
    (Trust.signed_revision_resolution signed
    |> Option.map Model.Decision_id.to_string);
  let encoded = Trust.encode_signed_revision signed in
  Alcotest.(check string)
    "signed resolution bytes retain their golden encoding"
    (read_golden "v1/signed-resolution-v1.cbor.hex")
    encoded;
  Trust.verify_signed_revision_at authority signed
  |> require_ok Trust.error_to_string;
  let decoded =
    encoded |> Trust.decode_signed_revision |> require_ok Trust.error_to_string
  in
  Alcotest.(check (option string))
    "the resolution decision survives a canonical round trip"
    (Some (Model.Decision_id.to_string decision))
    (Trust.signed_revision_resolution decoded
    |> Option.map Model.Decision_id.to_string);
  Trust.verify_signed_revision_at authority decoded
  |> require_ok Trust.error_to_string

let authority_root () =
  let repository, root_capability, root_device, root_certificate, membership =
    root_and_membership ()
  in
  let recovery_capability = capability 'r' in
  let recovery_device = device_from_capability recovery_capability in
  let root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device root_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check string)
    "root authority epoch retains its golden encoding"
    (read_golden "v1/authority-epoch-v1.cbor.hex")
    (Trust.encode_epoch root_epoch);
  ( repository,
    root_capability,
    root_device,
    root_certificate,
    membership,
    recovery_capability,
    recovery_device,
    root_epoch,
    authority )

let authority_epochs_are_branch_scoped_and_reconcilable () =
  let ( repository,
        root_capability,
        root_device,
        root_certificate,
        membership,
        _,
        recovery_device,
        root_epoch,
        _root_authority ) =
    authority_root ()
  in
  let member_capability = capability 'b' in
  let member_device = device_from_capability member_capability in
  let member_certificate =
    Trust.enroll membership
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~subject:member_device ~role:Trust.Member
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.extend_membership membership [ member_certificate ]
    |> require_ok Trust.error_to_string
  in
  let root_authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  let certificates = Trust.certificates membership in
  let enrolled_epoch =
    Trust.successor_epoch root_authority
      ~parents:[ Trust.epoch_id root_epoch ]
      ~certificates ~revoked:[] ~frontier:[] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.extend_authority root_authority [ enrolled_epoch ]
    |> require_ok Trust.error_to_string
  in
  let signed =
    Trust.sign_revision_at authority
      ~epoch:(Trust.epoch_id enrolled_epoch)
      ~certificate:(Trust.certificate_id member_certificate)
      member_capability
      (sample_revision (Trust.device_id member_device))
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check (option string))
    "new signed record names its authority epoch"
    (Some (Trust.epoch_id enrolled_epoch))
    (Trust.signed_revision_epoch signed);
  Alcotest.(check string)
    "epoch-bound signed record retains its golden encoding"
    (read_golden "v1/signed-revision-v1.cbor.hex")
    (Trust.encode_signed_revision signed);
  Trust.verify_signed_revision_at authority signed
  |> require_ok Trust.error_to_string;
  let first_branch =
    Trust.successor_epoch authority
      ~parents:[ Trust.epoch_id enrolled_epoch ]
      ~certificates ~revoked:[]
      ~frontier:[ revision "revision-one" ]
      ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let second_branch =
    Trust.successor_epoch authority
      ~parents:[ Trust.epoch_id enrolled_epoch ]
      ~certificates ~revoked:[]
      ~frontier:[ revision "revision-two" ]
      ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let forked =
    Trust.extend_authority authority [ first_branch; second_branch ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check int)
    "both authority heads remain active until explicit reconciliation" 2
    (List.length (Trust.authority_heads forked));
  Alcotest.(check bool)
    "member remains active in the first branch" true
    (Trust.authority_device_active forked
       ~epoch:(Trust.epoch_id first_branch)
       member_device);
  let reconciled =
    Trust.successor_epoch forked
      ~parents:
        (List.sort String.compare
           [ Trust.epoch_id first_branch; Trust.epoch_id second_branch ])
      ~certificates ~revoked:[]
      ~frontier:[ revision "revision-one"; revision "revision-two" ]
      ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let reconciled_authority =
    Trust.extend_authority forked [ reconciled ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check int)
    "reconciliation names both parents and closes the fork" 1
    (List.length (Trust.authority_heads reconciled_authority));
  Alcotest.(check bool)
    "root remains administrator after reconciliation" true
    (Trust.authority_device_administrator reconciled_authority
       ~epoch:(Trust.epoch_id reconciled)
       root_device);
  ignore repository

let revocation_recovery_and_exact_exceptions_are_verified () =
  let ( _repository,
        root_capability,
        root_device,
        root_certificate,
        membership,
        recovery_capability,
        recovery_device,
        root_epoch,
        _root_authority ) =
    authority_root ()
  in
  let member_capability = capability 'b' in
  let member_device = device_from_capability member_capability in
  let member_certificate =
    Trust.enroll membership
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~subject:member_device ~role:Trust.Member
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.extend_membership membership [ member_certificate ]
    |> require_ok Trust.error_to_string
  in
  let root_authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  let certificates = Trust.certificates membership in
  let enrolled_epoch =
    Trust.successor_epoch root_authority
      ~parents:[ Trust.epoch_id root_epoch ]
      ~certificates ~revoked:[] ~frontier:[] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.extend_authority root_authority [ enrolled_epoch ]
    |> require_ok Trust.error_to_string
  in
  let signed =
    Trust.sign_revision_at authority
      ~epoch:(Trust.epoch_id enrolled_epoch)
      ~certificate:(Trust.certificate_id member_certificate)
      member_capability
      (sample_revision (Trust.device_id member_device))
    |> require_ok Trust.error_to_string
  in
  let authorization =
    Trust.make_authorization authority
      ~epoch:(Trust.epoch_id enrolled_epoch)
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~device:member_device
      ~revision:(Trust.signed_revision_id signed)
      ~change:(change "change-one")
    |> require_ok Trust.error_to_string
  in
  Trust.verify_authorization authority authorization
  |> require_ok Trust.error_to_string;
  Alcotest.(check string)
    "one-time authorization retains its golden encoding"
    (read_golden "v1/authorization-v1.cbor.hex")
    (Trust.encode_authorization authorization);
  let adoption =
    Trust.make_adoption authority
      ~epoch:(Trust.epoch_id enrolled_epoch)
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~signed_revision:signed
    |> require_ok Trust.error_to_string
  in
  Trust.verify_adoption authority adoption |> require_ok Trust.error_to_string;
  Alcotest.(check string)
    "one-time adoption retains its golden encoding"
    (read_golden "v1/adoption-v1.cbor.hex")
    (Trust.encode_adoption adoption);
  let revoked_epoch =
    Trust.successor_epoch authority
      ~parents:[ Trust.epoch_id enrolled_epoch ]
      ~certificates
      ~revoked:[ Trust.device_id member_device ]
      ~frontier:[] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
    |> require_ok Trust.error_to_string
  in
  let revoked_authority =
    Trust.extend_authority authority [ revoked_epoch ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check bool)
    "a historical record from the now-revoked device needs explicit review" true
    (Trust.requires_late_review revoked_authority signed
    |> require_ok Trust.error_to_string);
  let post_revocation_adoption =
    Trust.make_adoption revoked_authority
      ~epoch:(Trust.epoch_id revoked_epoch)
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability ~signed_revision:signed
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check bool)
    "the later adoption is issued at the active authority head" true
    (Trust.authority_epoch_is_head revoked_authority
       (Trust.adoption_epoch post_revocation_adoption));
  (match
     Trust.sign_revision_at revoked_authority
       ~epoch:(Trust.epoch_id revoked_epoch)
       ~certificate:(Trust.certificate_id member_certificate)
       member_capability
       (sample_revision (Trust.device_id member_device))
   with
  | Error error ->
      Alcotest.(check string)
        "revoked device cannot sign at a newer epoch"
        "V1 device is revoked in this authority epoch"
        (Trust.error_to_string error)
  | Ok _ -> Alcotest.fail "revoked device signed at the newer epoch");
  let replacement_recovery_capability = capability 's' in
  let replacement_recovery_device =
    device_from_capability replacement_recovery_capability
  in
  let replacement_administrator_capability = capability 'c' in
  let replacement_administrator =
    device_from_capability replacement_administrator_capability
  in
  let recovery_certificate =
    Trust.recover_enroll revoked_authority
      ~parents:[ Trust.epoch_id revoked_epoch ]
      ~subject:replacement_administrator ~role:Trust.Administrator
      recovery_capability
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.extend_membership
      (Trust.authority_membership revoked_authority)
      [ recovery_certificate ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check bool)
    "a recovery-issued certificate has no legacy membership authority" false
    (Trust.is_authorized membership replacement_administrator);
  (match
     Trust.sign_revision membership
       ~certificate:(Trust.certificate_id recovery_certificate)
       replacement_administrator_capability
       (sample_revision (Trust.device_id replacement_administrator))
   with
  | Error error ->
      Alcotest.(check string)
        "recovery certificate cannot use a retired signing path"
        "invalid V1 authority epoch: V1 signed revisions require an authority \
         epoch"
        (Trust.error_to_string error)
  | Ok _ ->
      Alcotest.fail "recovery certificate signed through legacy membership");
  let revoked_authority =
    Trust.verify_authority ~membership
      (Trust.authority_epochs revoked_authority)
    |> require_ok Trust.error_to_string
  in
  let certificates = Trust.certificates membership in
  let final_revocations =
    [ Trust.device_id member_device; Trust.device_id root_device ]
    |> List.sort_uniq Model.Device_id.compare
  in
  let recovered_epoch =
    Trust.recover_epoch revoked_authority
      ~parents:[ Trust.epoch_id revoked_epoch ]
      ~certificates ~revoked:final_revocations ~frontier:[]
      ~recovery_device:replacement_recovery_device recovery_capability
    |> require_ok Trust.error_to_string
  in
  let recovered_authority =
    Trust.extend_authority revoked_authority [ recovered_epoch ]
    |> require_ok Trust.error_to_string
  in
  Alcotest.(check int)
    "recovery advances the authority graph" 1
    (List.length (Trust.authority_heads recovered_authority));
  Alcotest.(check bool)
    "recovery rotates to the replacement key" true
    (Trust.device_equal replacement_recovery_device
       (Trust.epoch_recovery_device recovered_epoch));
  Alcotest.(check bool)
    "recovery can admit a replacement administrator while the old one is \
     revoked"
    true
    (Trust.authority_device_administrator recovered_authority
       ~epoch:(Trust.epoch_id recovered_epoch)
       replacement_administrator);
  Alcotest.(check string)
    "authorization survives a canonical round trip"
    (Trust.encode_authorization authorization)
    (authorization |> Trust.encode_authorization |> Trust.decode_authorization
    |> require_ok Trust.error_to_string
    |> Trust.encode_authorization);
  Alcotest.(check string)
    "adoption binds the exact signed revision bytes"
    (Trust.encode_adoption adoption)
    (adoption |> Trust.encode_adoption |> Trust.decode_adoption
    |> require_ok Trust.error_to_string
    |> Trust.encode_adoption)

let () =
  Alcotest.run "V1 trust"
    [
      ( "identity",
        [
          Alcotest.test_case "root certificate is self-certifying" `Quick
            root_certificate_is_self_certifying;
          Alcotest.test_case "administrator enrols a causal member" `Quick
            administrator_enrols_a_member_in_causal_order;
          Alcotest.test_case "signed revision binds author and membership"
            `Quick signed_revision_binds_author_and_membership;
          Alcotest.test_case "signed resolution binds its target decision"
            `Quick signed_resolution_binds_its_target_decision;
          Alcotest.test_case "authority epochs keep forks explicit" `Quick
            authority_epochs_are_branch_scoped_and_reconcilable;
          Alcotest.test_case "revocation, recovery, and exact exceptions" `Quick
            revocation_recovery_and_exact_exceptions_are_verified;
        ] );
    ]
