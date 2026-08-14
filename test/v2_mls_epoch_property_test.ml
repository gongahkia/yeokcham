module Authority = Yeokcham_v2_authority
module Envelope = Yeokcham_v2_envelope
module Epoch = Yeokcham_v2_mls_epoch
module Group = Yeokcham_v2_mls_group
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

let seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:17
  | None -> 17

let root =
  String.init 32 (fun index -> Char.chr ((7 + index) land 255))
  |> Authority.root_signing_capability_of_private_key |> Result.get_ok

let state_key = Envelope.key_of_bytes (String.make 32 'k') |> Result.get_ok
let nonce byte = Envelope.nonce_of_bytes (String.make 12 byte) |> Result.get_ok
let raw = QCheck2.Gen.string_size (QCheck2.Gen.return 32)

let property =
  QCheck2.Test.make ~count:12
    ~name:"append-only MLS epoch transitions replay their unique successor"
    (QCheck2.Gen.triple raw raw raw)
    (fun (repository_bytes, issuer_bytes, member_bytes) ->
      match
        ( Model.Repository_id.of_bytes repository_bytes,
          Model.Device_id.of_bytes issuer_bytes,
          Model.Device_id.of_bytes member_bytes )
      with
      | Ok repository_id, Ok issuer_device_id, Ok member_device_id
        when not (Model.Device_id.equal issuer_device_id member_device_id) -> (
          let runtime = Runtime.default_configuration in
          let authority =
            Authority.make_repository_authority ~repository_id ~root
              ~mandatory_features:0L
          in
          match authority with
          | Error _ -> false
          | Ok authority -> (
              match
                Group.create ~runtime ~repository_id ~device_id:issuer_device_id
              with
              | Error _ -> false
              | Ok initial -> (
                  match
                    Epoch.advance_add ~runtime ~authority ~root ~parent_id:None
                      ~issuer_state:initial
                      ~recipient_device_id:member_device_id ~state_key
                      ~state_nonce:(nonce 'a')
                  with
                  | Error _ -> false
                  | Ok added -> (
                      match
                        Epoch.advance_removal ~runtime ~authority ~root
                          ~parent_id:
                            (Some
                               (Epoch.id added.Epoch.transition_result_record))
                          ~issuer_state:
                            added.Epoch.transition_result_successor_state
                          ~removed_device_id:member_device_id ~state_key
                          ~state_nonce:(nonce 'r')
                      with
                      | Error _ -> false
                      | Ok removed ->
                          Epoch.verify_chain ~runtime ~authority ~state_key
                            ~initial_state:initial
                            [
                              added.Epoch.transition_result_record;
                              removed.Epoch.transition_result_record;
                            ]
                          = Ok removed.Epoch.transition_result_successor_state))
              ))
      | Ok _, Ok _, Ok _ -> true
      | Error _, _, _ | _, Error _, _ | _, _, Error _ -> false)

let () =
  Alcotest.run "V2 MLS epoch properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| seed |])
            property;
        ] );
    ]
