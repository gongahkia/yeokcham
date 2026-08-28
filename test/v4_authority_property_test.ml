module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

let capability byte =
  Trust.signing_capability_of_private_key (String.make 32 byte)

let device capability =
  Trust.signing_public_key capability |> Trust.device_of_public_key

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

let fork_reconciliation_preserves_a_single_explicit_head suffix =
  let ( let* ) = Result.bind in
  let repository = Result.get_ok repository in
  let* root_capability = capability 'a' in
  let* root_device = device root_capability in
  let* root_certificate =
    Trust.root_certificate ~repository ~device:root_device root_capability
  in
  let* membership = Trust.verify_membership ~repository [ root_certificate ] in
  let* recovery_capability = capability 'r' in
  let* recovery_device = device recovery_capability in
  let* root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device root_capability
  in
  let* authority = Trust.verify_authority ~membership [ root_epoch ] in
  let certificates = Trust.certificates membership in
  let revision_a =
    Model.Revision_id.of_string (Printf.sprintf "revision-a-%d" suffix)
    |> Result.get_ok
  in
  let revision_b =
    Model.Revision_id.of_string (Printf.sprintf "revision-b-%d" suffix)
    |> Result.get_ok
  in
  let* first =
    Trust.successor_epoch authority
      ~parents:[ Trust.epoch_id root_epoch ]
      ~certificates ~revoked:[] ~frontier:[ revision_a ] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
  in
  let* second =
    Trust.successor_epoch authority
      ~parents:[ Trust.epoch_id root_epoch ]
      ~certificates ~revoked:[] ~frontier:[ revision_b ] ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
  in
  let* forked = Trust.extend_authority authority [ first; second ] in
  let parents =
    List.sort String.compare [ Trust.epoch_id first; Trust.epoch_id second ]
  in
  let frontier =
    List.sort Model.Revision_id.compare [ revision_a; revision_b ]
  in
  let* reconciled =
    Trust.successor_epoch forked ~parents ~certificates ~revoked:[] ~frontier
      ~recovery_device
      ~issuer:(Trust.certificate_id root_certificate)
      root_capability
  in
  let* final_authority = Trust.extend_authority forked [ reconciled ] in
  Ok
    (Trust.authority_heads final_authority = [ Trust.epoch_id reconciled ]
    && Trust.authority_device_administrator final_authority
         ~epoch:(Trust.epoch_id reconciled)
         root_device)

let property =
  QCheck2.Test.make ~count:100
    ~name:"explicit authority reconciliation preserves the sole resulting head"
    QCheck2.Gen.(int_range 0 999_999)
    (fun suffix ->
      match fork_reconciliation_preserves_a_single_explicit_head suffix with
      | Ok value -> value
      | Error _ -> false)

let () =
  Alcotest.run "V4 authority properties"
    [
      ("authority", [ QCheck_alcotest.to_alcotest ~speed_level:`Quick property ]);
    ]
