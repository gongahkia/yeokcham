module Event = Yeokcham_ref_event
module Store = Yeokcham_store

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Event.signer_key_id;
}

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
let () = Printf.printf "ref-event property base seed: %d\n%!" base_seed

let require = function
  | Ok value -> value
  | Error _ -> failwith "ref-event property setup failed"

let signer =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr (index + 1)))
    |> require
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let key_id = Event.signer_key_id_of_public_key public_key |> require in
  { private_key; public_key; key_id }

let target index =
  let bytes = Bytes.make 32 '\000' in
  Bytes.set bytes 0 (Char.chr (index lsr 8));
  Bytes.set bytes 1 (Char.chr (index land 255));
  match Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string bytes) with
  | Some object_id -> object_id
  | None -> failwith "invalid generated object ID"

let state generation target =
  Event.make_ref_state ~generation ~target |> require

let signed_event ~sequence ~previous ~observed ~proposed =
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format
      ~ref_name:"scratch-head" ~signer_key_id:signer.key_id
      ~signer_sequence:sequence ~previous ~observed ~proposed
      ~mandatory_features:0L
    |> require
  in
  let signature =
    Event.signing_bytes unsigned
    |> require
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require

let trusted_keys =
  [ { Event.key_id = signer.key_id; public_key = signer.public_key } ]

let verifies event =
  match
    Event.verify ~repository_format:Store.repository_format ~trusted_keys event
  with
  | Ok verification ->
      String.equal (Event.verification_to_string verification) "verified"
  | Error _ -> false

let ready current known event =
  match Event.evaluate_verified ~current ~known event with
  | Ok evaluation ->
      String.equal (Event.evaluation_to_string evaluation) "ready"
  | Error _ -> false

let chain_restart_and_corruption =
  let generator =
    QCheck2.Gen.pair
      (QCheck2.Gen.list_size
         (QCheck2.Gen.int_range 0 24)
         (QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 32)))
      QCheck2.Gen.bool
  in
  QCheck2.Test.make ~count:100
    ~name:"ref-event signed chains survive replay and reject corruption"
    generator (fun (labels, corrupt_last) ->
      let rec create current previous sequence known = function
        | [] -> Some (current, List.rev known)
        | _label :: rest ->
            let proposed =
              state
                Int64.(add sequence 1L)
                (Some (target (Int64.to_int sequence + 1)))
            in
            let event =
              signed_event ~sequence ~previous ~observed:current ~proposed
            in
            if not (verifies event && ready current known event) then None
            else
              create proposed
                (Some (Event.unsigned_event_id (Event.event_unsigned event)))
                Int64.(add sequence 1L)
                (event :: known) rest
      in
      match create (state 0L None) None 0L [] labels with
      | None -> false
      | Some (_final, events) ->
          let replay_ok =
            List.for_all
              (fun event ->
                Result.bind
                  (Event.event_payload event)
                  Event.decode_event_payload
                |> Result.fold ~ok:verifies ~error:(fun _ -> false))
              events
          in
          let duplicate_ok =
            match events with
            | [] -> true
            | first :: _ ->
                Event.evaluate_verified ~current:(state 0L None)
                  ~known:[ first ] first
                |> Result.fold
                     ~ok:(fun evaluation ->
                       String.starts_with ~prefix:"replayed:"
                         (Event.evaluation_to_string evaluation))
                     ~error:(fun _ -> false)
          in
          let corruption_ok =
            match (corrupt_last, List.rev events) with
            | false, _ | true, [] -> true
            | true, last :: _ ->
                let signature = Bytes.of_string (Event.event_signature last) in
                Bytes.set signature 0
                  (Char.chr (Char.code (Bytes.get signature 0) lxor 1));
                let corrupted =
                  Event.make
                    ~unsigned:(Event.event_unsigned last)
                    ~algorithm:Event.algorithm
                    ~signature:(Bytes.unsafe_to_string signature)
                  |> require
                in
                Result.is_error
                  (Event.verify ~repository_format:Store.repository_format
                     ~trusted_keys corrupted)
          in
          replay_ok && duplicate_ok && corruption_ok)

let () =
  Alcotest.run "ref-event properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "chain-restart-corruption")
            chain_restart_and_corruption;
        ] );
    ]
