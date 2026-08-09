module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Transaction = Yeokcham_v2_transaction

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "v2 transaction property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository_id =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let transaction_id value =
  Model.Transaction_id.of_bytes
    (String.init 32 (fun index -> Char.chr ((value + index) land 255)))
  |> require_ok Model.identity_error_to_string

let staged value =
  let object_ref =
    Model.Opaque_object_ref.of_bytes
      (String.init 32 (fun index -> Char.chr ((value + index) land 255)))
    |> require_ok Model.identity_error_to_string
  in
  let nonce =
    Envelope.nonce_of_bytes
      (String.init 12 (fun index -> Char.chr ((value + index + 64) land 255)))
    |> require_ok Envelope.error_to_string
  in
  let envelope =
    Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
      (String.make 1 (Char.chr value))
    |> require_ok Envelope.error_to_string
  in
  Transaction.stage ~object_ref ~envelope

let bounded_counts = QCheck2.Gen.(int_range 1 Transaction.max_staged_objects)

let canonical_round_trips =
  QCheck2.Test.make ~count:100
    ~name:"generated bounded canonical transaction prepare/commit round trips"
    bounded_counts (fun count ->
      let staged = List.init count staged in
      match
        Transaction.make_prepare ~repository_id
          ~transaction_id:(transaction_id count) ~mandatory_features:0L staged
      with
      | Error _ -> false
      | Ok prepare -> (
          let commit = Transaction.make_commit prepare in
          match
            ( Transaction.decode_prepare (Transaction.encode_prepare prepare),
              Transaction.decode_commit (Transaction.encode_commit commit) )
          with
          | Ok decoded_prepare, Ok decoded_commit ->
              Result.is_ok
                (Transaction.validate_commit ~prepare:decoded_prepare
                   decoded_commit)
          | Error _, Ok _ | Ok _, Error _ | Error _, Error _ -> false))

let () =
  Alcotest.run "V2 durable object transaction properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "canonical-round-trips")
            canonical_round_trips;
        ] );
    ]
