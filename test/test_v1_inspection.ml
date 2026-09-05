module Inspection = Yeokcham_v1_inspection
module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let model_id parser value = parser value |> require_ok Model.error_to_string
let snapshot value = model_id Model.Snapshot_id.of_string value
let draft value = model_id Model.Draft_id.of_string value
let change value = model_id Model.Change_id.of_string value
let revision value = model_id Model.Revision_id.of_string value
let delivery value = model_id Model.Delivery_id.of_string value
let device value = model_id Model.Device_id.of_string value
let username value = model_id Model.Username.of_string value

let path value =
  Model.Path.of_components [ value ] |> require_ok Model.error_to_string

let edit ?(start_byte = 0) ?(end_byte = 1) name =
  let span =
    Model.make_span ~start_byte ~end_byte |> require_ok Model.error_to_string
  in
  Model.{ edit_path = path name; edit_kind = Text span }

let revision_record ?parent ~change_id ~revision_id ~author ~base ~result edits
    =
  Model.make_change_revision ~change:(change change_id)
    ~revision:(revision revision_id) ~parent ~author ~base ~result ~edits
  |> require_ok Model.error_to_string

let project ?(creator = device "device-alice") ?(user = username "alice") () =
  Model.init ~creator ~username:user
    ~initial_snapshot:(snapshot "snapshot-base")
    ~initial_draft:(draft "draft-one") ~title:"inspection"

let inspection ?authority ?(signed_revisions = []) ?(reviews = []) project =
  Inspection.state ~project ~signed_revisions ~authority
    ~review_publications:reviews

let linear_project ?(long_path = false) () =
  let first =
    revision_record ~change_id:"change-alpha" ~revision_id:"revision-alpha"
      ~author:(device "device-bob") ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-alpha")
      [ edit (if long_path then String.make 96 'p' else "alpha.ml") ]
  in
  let second =
    revision_record ~change_id:"change-beta" ~revision_id:"revision-beta"
      ~author:(device "device-carol") ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-beta")
      [ edit "beta.ml" ]
  in
  project () |> fun state ->
  Model.receive state second |> require_ok Model.error_to_string |> fun state ->
  Model.receive state first |> require_ok Model.error_to_string

let decision_project () =
  let first =
    revision_record ~change_id:"change-alpha" ~revision_id:"revision-alpha"
      ~author:(device "device-bob") ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-alpha")
      [ edit ~start_byte:0 ~end_byte:4 "same.ml" ]
  in
  let second =
    revision_record ~change_id:"change-beta" ~revision_id:"revision-beta"
      ~author:(device "device-carol") ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-beta")
      [ edit ~start_byte:2 ~end_byte:6 "same.ml" ]
  in
  project () |> fun state ->
  Model.receive state first |> require_ok Model.error_to_string |> fun state ->
  Model.receive state second |> require_ok Model.error_to_string

type authority_context = {
  capability : Trust.signing_capability;
  root_device : Trust.device;
  root_certificate : Trust.certificate;
  member_device : Trust.device;
  membership : Trust.membership;
  authority : Trust.authority;
  root_epoch : Trust.epoch;
  recovery_device : Trust.device;
}

let authority_context () =
  let repository =
    Trust.Repository_id.of_string
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> require_ok Fun.id
  in
  let capability =
    Trust.signing_capability_of_private_key (String.make 32 'a')
    |> require_ok Trust.error_to_string
  in
  let root_device =
    Trust.signing_public_key capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let root_certificate =
    Trust.root_certificate ~repository ~device:root_device capability
    |> require_ok Trust.error_to_string
  in
  let initial_membership =
    Trust.verify_membership ~repository [ root_certificate ]
    |> require_ok Trust.error_to_string
  in
  let member_capability =
    Trust.signing_capability_of_private_key (String.make 32 'b')
    |> require_ok Trust.error_to_string
  in
  let member_device =
    Trust.signing_public_key member_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let member_certificate =
    Trust.enroll initial_membership
      ~issuer:(Trust.certificate_id root_certificate)
      capability ~subject:member_device ~role:Trust.Member
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.extend_membership initial_membership [ member_certificate ]
    |> require_ok Trust.error_to_string
  in
  let recovery_capability =
    Trust.signing_capability_of_private_key (String.make 32 'r')
    |> require_ok Trust.error_to_string
  in
  let recovery_device =
    Trust.signing_public_key recovery_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  {
    capability;
    root_device;
    root_certificate;
    member_device;
    membership;
    authority;
    root_epoch;
    recovery_device;
  }

let resolution_state () =
  let context = authority_context () in
  let creator = Trust.device_id context.root_device in
  let initial = project ~creator ~user:(username "root") () in
  let first =
    revision_record ~change_id:"change-alpha" ~revision_id:"revision-alpha"
      ~author:creator ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-alpha")
      [ edit ~start_byte:0 ~end_byte:4 "same.ml" ]
  in
  let second =
    revision_record ~change_id:"change-beta" ~revision_id:"revision-beta"
      ~author:creator ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-beta")
      [ edit ~start_byte:2 ~end_byte:6 "same.ml" ]
  in
  let project =
    Model.receive initial first |> require_ok Model.error_to_string
  in
  let project =
    Model.receive project second |> require_ok Model.error_to_string
  in
  let decision = List.hd (Model.projection project).Model.decisions in
  let replacement =
    revision_record ~change_id:"change-resolution"
      ~revision_id:"revision-resolution" ~author:creator
      ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-resolution")
      [ edit ~start_byte:0 ~end_byte:6 "same.ml" ]
  in
  let signed =
    Trust.sign_resolution_at context.authority
      ~epoch:(Trust.epoch_id context.root_epoch)
      ~certificate:(Trust.certificate_id context.root_certificate)
      context.capability ~decision:decision.Model.decision_id replacement
    |> require_ok Trust.error_to_string
  in
  let project =
    Model.resolve project ~decision:decision.Model.decision_id ~replacement
    |> require_ok Model.error_to_string
  in
  inspection ~authority:context.authority ~signed_revisions:[ signed ] project

let delivery_project () =
  let author = device "device-alice" in
  let first =
    revision_record ~change_id:"change-alpha" ~revision_id:"revision-alpha"
      ~author ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-alpha")
      [ edit "alpha.ml" ]
  in
  let project =
    Model.share_active (project ~creator:author ()) first
    |> require_ok Model.error_to_string
  in
  let project =
    Model.deliver project ~id:(delivery "delivery-one") ~author
      ~snapshot:(snapshot "snapshot-delivery-one")
      ~included:[ revision "revision-alpha" ]
      ~next_draft:(draft "draft-two") ~next_title:"second" ~created_at:10L
    |> require_ok Model.error_to_string
  in
  let second =
    revision_record ~change_id:"change-beta" ~revision_id:"revision-beta"
      ~author
      ~base:(snapshot "snapshot-delivery-one")
      ~result:(snapshot "snapshot-beta")
      [ edit "beta.ml" ]
  in
  let project =
    Model.share_active project second |> require_ok Model.error_to_string
  in
  Model.deliver project ~id:(delivery "delivery-two") ~author
    ~snapshot:(snapshot "snapshot-delivery-two")
    ~included:[ revision "revision-beta" ]
    ~next_draft:(draft "draft-three") ~next_title:"third" ~created_at:20L
  |> require_ok Model.error_to_string

let authority_state () =
  let context = authority_context () in
  let certificates = Trust.certificates context.membership in
  let member = Trust.device_id context.member_device in
  let parent = Trust.epoch_id context.root_epoch in
  let first =
    Trust.successor_epoch context.authority ~parents:[ parent ] ~certificates
      ~revoked:[ member ]
      ~frontier:[ revision "revision-alpha" ]
      ~recovery_device:context.recovery_device
      ~issuer:(Trust.certificate_id context.root_certificate)
      context.capability
    |> require_ok Trust.error_to_string
  in
  let second =
    Trust.successor_epoch context.authority ~parents:[ parent ] ~certificates
      ~revoked:[]
      ~frontier:[ revision "revision-beta" ]
      ~recovery_device:context.recovery_device
      ~issuer:(Trust.certificate_id context.root_certificate)
      context.capability
    |> require_ok Trust.error_to_string
  in
  let forked =
    Trust.extend_authority context.authority [ first; second ]
    |> require_ok Trust.error_to_string
  in
  let parents =
    List.sort String.compare [ Trust.epoch_id first; Trust.epoch_id second ]
  in
  let reconciled =
    Trust.successor_epoch forked ~parents ~certificates ~revoked:[ member ]
      ~frontier:[ revision "revision-alpha"; revision "revision-beta" ]
      ~recovery_device:context.recovery_device
      ~issuer:(Trust.certificate_id context.root_certificate)
      context.capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.extend_authority forked [ reconciled ]
    |> require_ok Trust.error_to_string
  in
  inspection ~authority (project ())

let authority_fork_state () =
  let context = authority_context () in
  let certificates = Trust.certificates context.membership in
  let member = Trust.device_id context.member_device in
  let parent = Trust.epoch_id context.root_epoch in
  let first =
    Trust.successor_epoch context.authority ~parents:[ parent ] ~certificates
      ~revoked:[ member ]
      ~frontier:[ revision "revision-alpha" ]
      ~recovery_device:context.recovery_device
      ~issuer:(Trust.certificate_id context.root_certificate)
      context.capability
    |> require_ok Trust.error_to_string
  in
  let second =
    Trust.successor_epoch context.authority ~parents:[ parent ] ~certificates
      ~revoked:[]
      ~frontier:[ revision "revision-beta" ]
      ~recovery_device:context.recovery_device
      ~issuer:(Trust.certificate_id context.root_certificate)
      context.capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.extend_authority context.authority [ first; second ]
    |> require_ok Trust.error_to_string
  in
  inspection ~authority (project ())

let golden_path name =
  let local = Filename.concat "golden/inspection" name in
  if Sys.file_exists local then local
  else Filename.concat "test/golden/inspection" name

let golden name output =
  let path = golden_path name in
  let expected =
    match Sys.getenv_opt "YEOKCHAM_REFRESH_GOLDENS" with
    | Some "1" ->
        Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel output);
        output
    | Some _ | None -> In_channel.with_open_bin path In_channel.input_all
  in
  Alcotest.(check string) name expected output

let golden_outputs_are_stable () =
  golden "empty.log.txt"
    (Inspection.render_log ~width:80 (inspection (project ())));
  golden "empty.graph.txt"
    (Inspection.render_work_graph ~width:80 (inspection (project ())));
  golden "linear.log.txt"
    (Inspection.render_log ~width:80 (inspection (linear_project ())));
  golden "decision.graph.txt"
    (Inspection.render_work_graph ~width:80 (inspection (decision_project ())));
  golden "resolution.log.txt"
    (Inspection.render_log ~width:80 (resolution_state ()));
  golden "delivery.log.txt"
    (Inspection.render_log ~width:80 (inspection (delivery_project ())));
  golden "authority.graph.txt"
    (Inspection.render_authority_graph ~width:80 (authority_state ())
    |> Option.value ~default:"authority unavailable\n");
  golden "authority-fork.graph.txt"
    (Inspection.render_authority_graph ~width:80 (authority_fork_state ())
    |> Option.value ~default:"authority unavailable\n");
  golden "narrow.log.txt"
    (Inspection.render_log ~width:40
       (inspection (linear_project ~long_path:true ())));
  golden "review.graph.txt"
    (Inspection.render_work_graph ~width:80
       (inspection
          ~reviews:[ "publication-z"; "publication-a"; "publication-a" ]
          (project ())))

let authority_graph_refuses_absent_authority () =
  Alcotest.(check bool)
    "no authority graph is invented" true
    (Option.is_none
       (Inspection.render_authority_graph ~width:80 (inspection (project ()))))

let output_is_permutation_invariant_and_read_only =
  QCheck2.Test.make ~count:100
    ~name:"V1 inspection is deterministic and does not mutate its model input"
    QCheck2.Gen.bool (fun reverse ->
      let first =
        revision_record ~change_id:"change-alpha" ~revision_id:"revision-alpha"
          ~author:(device "device-bob") ~base:(snapshot "snapshot-base")
          ~result:(snapshot "snapshot-alpha")
          [ edit "alpha.ml" ]
      in
      let second =
        revision_record ~change_id:"change-beta" ~revision_id:"revision-beta"
          ~author:(device "device-carol") ~base:(snapshot "snapshot-base")
          ~result:(snapshot "snapshot-beta")
          [ edit "beta.ml" ]
      in
      let receive incoming =
        List.fold_left
          (fun state revision ->
            Model.receive state revision |> require_ok Model.error_to_string)
          (project ()) incoming
      in
      let left = receive [ first; second ] in
      let right =
        receive (if reverse then [ second; first ] else [ first; second ])
      in
      let before = Model.export left in
      let left_output =
        Inspection.render_work_graph ~width:80
          (inspection ~reviews:[ "publication-b"; "publication-a" ] left)
      in
      let after = Model.export left in
      String.equal left_output
        (Inspection.render_work_graph ~width:80
           (inspection ~reviews:[ "publication-a"; "publication-b" ] right))
      && before = after)

let () =
  Alcotest.run "V1 inspection"
    [
      ( "projection",
        [
          Alcotest.test_case "golden output contract" `Quick
            golden_outputs_are_stable;
          Alcotest.test_case "authority graph requires authority state" `Quick
            authority_graph_refuses_absent_authority;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            output_is_permutation_invariant_and_read_only;
        ] );
    ]
