module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

let seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:17
  | None -> 17

let raw = QCheck2.Gen.string_size (QCheck2.Gen.return 32)

let property =
  QCheck2.Test.make ~count:24
    ~name:"created MLS state reloads and only its exporter decrypts metadata"
    (QCheck2.Gen.pair raw raw) (fun (repository_bytes, device_bytes) ->
      match
        ( Model.Repository_id.of_bytes repository_bytes,
          Model.Device_id.of_bytes device_bytes,
          Envelope.nonce_of_bytes (String.make 12 'n') )
      with
      | Ok repository_id, Ok device_id, Ok nonce -> (
          let runtime = Runtime.default_configuration in
          match Group.create ~runtime ~repository_id ~device_id with
          | Error _ -> false
          | Ok state -> (
              match
                Group.encrypt_metadata ~runtime ~state ~nonce "metadata"
              with
              | Error _ -> false
              | Ok encrypted ->
                  Group.verify ~runtime state = Ok ()
                  && Group.decrypt_metadata ~runtime ~state encrypted
                     = Ok "metadata"))
      | Error _, _, _ | _, Error _, _ | _, _, Error _ -> false)

let () =
  Alcotest.run "V2 MLS group properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| seed |])
            property;
        ] );
    ]
