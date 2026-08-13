module Authority = Yeokcham_v2_authority
module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Invitation = Yeokcham_v2_mls_invitation
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

let seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:17
  | None -> 17

let root =
  String.init 32 (fun index -> Char.chr ((71 + index) land 255))
  |> Authority.root_signing_capability_of_private_key
  |> Result.get_ok

let invitation_key = Envelope.key_of_bytes (String.make 32 'k') |> Result.get_ok
let invitation_nonce = Envelope.nonce_of_bytes (String.make 12 'n') |> Result.get_ok
let issued_nonce = Envelope.nonce_of_bytes (String.make 12 'e') |> Result.get_ok
let accepted_nonce = Envelope.nonce_of_bytes (String.make 12 'a') |> Result.get_ok
let raw = QCheck2.Gen.string_size (QCheck2.Gen.return 32)

let recipient_bytes bytes =
  if String.equal bytes (String.make 32 '\000') then String.make 32 '\001'
  else
    String.init 32 (fun offset ->
        if offset = 0 then Char.chr (Char.code bytes.[offset] lxor 1)
        else bytes.[offset])

let property =
  QCheck2.Test.make ~count:12
    ~name:"authorized MLS invitations replay to a verified distinct recipient state"
    (QCheck2.Gen.pair raw raw) (fun (repository_bytes, issuer_bytes) ->
      match
        ( Model.Repository_id.of_bytes repository_bytes,
          Model.Device_id.of_bytes issuer_bytes,
          Model.Device_id.of_bytes (recipient_bytes issuer_bytes) )
      with
      | Ok repository_id, Ok issuer_device_id, Ok recipient_device_id ->
          let runtime = Runtime.default_configuration in
          let authority =
            Authority.make_repository_authority ~repository_id ~root
              ~mandatory_features:0L
          in
          let issuer_state =
            Group.create ~runtime ~repository_id ~device_id:issuer_device_id
          in
          (match (authority, issuer_state) with
          | Ok authority, Ok issuer_state -> (
              match
                Invitation.issue ~runtime ~authority ~root ~issuer_state
                  ~recipient_device_id ~issued_at:1L ~expires_at:2L
                  ~invitation_key ~invitation_nonce ~event_nonce:issued_nonce
              with
              | Error _ -> false
              | Ok issue -> (
                  match
                    Invitation.accept ~runtime ~authority ~root
                      ~invitation:issue.Invitation.invitation
                      ~history:[ issue.Invitation.issued_event ] ~now:1L
                      ~invitation_key ~event_nonce:accepted_nonce
                  with
                  | Error _ -> false
                  | Ok acceptance ->
                      Group.verify ~runtime issue.Invitation.issuer_state = Ok ()
                      && Group.verify ~runtime acceptance.Invitation.recipient_state
                         = Ok ()))
          | Error _, _ | _, Error _ -> false)
      | Error _, _, _ | _, Error _, _ | _, _, Error _ -> false)

let () =
  Alcotest.run "V2 MLS invitation properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| seed |]) property;
        ] );
    ]
