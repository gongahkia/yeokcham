module Authority = Yeokcham_v2_authority
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Recovery = Yeokcham_v2_recovery

let require = function Ok value -> value | Error _ -> assert false

let seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:17
  | None -> 17

let raw = QCheck2.Gen.string_size (QCheck2.Gen.return 32)
let nonce_raw = QCheck2.Gen.string_size (QCheck2.Gen.return 12)

let property =
  QCheck2.Test.make ~count:120
    ~name:"only matching secret and phrase recover varied authority packages"
    (QCheck2.Gen.pair (QCheck2.Gen.quad raw raw raw raw) nonce_raw)
    (fun ( (secret_bytes, package_bytes, root_bytes, repository_bytes),
           nonce_bytes )
       ->
      match
        ( Recovery.recovery_secret_of_bytes secret_bytes,
          Model.Recovery_package_id.of_bytes package_bytes,
          Authority.root_signing_capability_of_private_key root_bytes,
          Model.Repository_id.of_bytes repository_bytes,
          Envelope.nonce_of_bytes nonce_bytes )
      with
      | Ok secret, Ok package_id, Ok root, Ok repository, Ok nonce -> (
          let authority =
            Authority.make_repository_authority ~repository_id:repository ~root
              ~mandatory_features:0L
            |> require
          in
          match
            Recovery.make ~secret ~package_id ~nonce ~authority ~root
              ~mandatory_features:0L
          with
          | Error _ -> false
          | Ok package ->
              let wrong_secret_bytes = Bytes.of_string secret_bytes in
              Bytes.set wrong_secret_bytes 0
                (Char.chr (Char.code (Bytes.get wrong_secret_bytes 0) lxor 1));
              let wrong_secret =
                Recovery.recovery_secret_of_bytes
                  (Bytes.unsafe_to_string wrong_secret_bytes)
                |> require
              in
              Result.is_ok
                (Recovery.recover ~secret
                   ~verification_phrase:(Recovery.verification_phrase secret)
                   ~package)
              && Result.is_error
                   (Recovery.recover ~secret:wrong_secret
                      ~verification_phrase:
                        (Recovery.verification_phrase wrong_secret)
                      ~package))
      | Error _, _, _, _, _
      | _, Error _, _, _, _
      | _, _, Error _, _, _
      | _, _, _, Error _, _
      | _, _, _, _, Error _ ->
          false)

let () =
  Alcotest.run "V2 recovery properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| seed |])
            property;
        ] );
    ]
