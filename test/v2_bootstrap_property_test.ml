module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let state_for name =
  let seed = ref base_seed in
  String.iter
    (fun character ->
      seed := !seed * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !seed |]

let require = function Ok value -> value | Error _ -> assert false

let capability =
  let encryption = String.make 32 'e' |> Envelope.key_of_bytes |> require in
  let address = String.make 32 'a' |> Address.key_of_bytes |> require in
  let signing =
    String.make 32 's' |> Mirage_crypto_ec.Ed25519.priv_of_octets |> require
  in
  Bootstrap.make_capability ~encryption_key:encryption ~address_key:address
    ~signing_key:signing
  |> require

let raw_identity = QCheck2.Gen.string_size (QCheck2.Gen.return 32)

let round_trip =
  QCheck2.Test.make ~count:200
    ~name:"V2 local bootstrap canonical decode re-encodes arbitrary IDs exactly"
    (QCheck2.Gen.pair raw_identity raw_identity)
    (fun (repository_bytes, device_bytes) ->
      match
        ( Model.Repository_id.of_bytes repository_bytes,
          Model.Device_id.of_bytes device_bytes )
      with
      | Ok repository_id, Ok device_id -> (
          match
            Bootstrap.make ~repository_id ~device_id ~capability
              ~mandatory_features:0L
          with
          | Error _ -> false
          | Ok bootstrap -> (
              match Bootstrap.decode (Bootstrap.encode bootstrap) with
              | Error _ -> false
              | Ok decoded ->
                  String.equal (Bootstrap.encode bootstrap) (Bootstrap.encode decoded)))
      | Error _, _ | _, Error _ -> false)

let () =
  Alcotest.run "V2 local bootstrap properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "bootstrap-round-trip") round_trip;
        ] );
    ]
