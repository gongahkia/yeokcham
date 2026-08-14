module Authority = Yeokcham_v2_authority
module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Invitation = Yeokcham_v2_mls_invitation
module Invitation_store = Yeokcham_v2_mls_invitation_store
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository byte =
  Model.Repository_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let device byte =
  Model.Device_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let key byte =
  Envelope.key_of_bytes (String.make 32 byte)
  |> require_ok Envelope.error_to_string

let nonce byte =
  Envelope.nonce_of_bytes (String.make 12 byte)
  |> require_ok Envelope.error_to_string

let root seed =
  String.init 32 (fun index -> Char.chr ((seed + index) land 255))
  |> Authority.root_signing_capability_of_private_key
  |> require_ok Authority.error_to_string

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_root run =
  let root = Filename.temp_file "yeokcham-v2-mls-invitation-store-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let fixture () =
  let repository_id = repository 'r' in
  let root = root 7 in
  let authority =
    Authority.make_repository_authority ~repository_id ~root
      ~mandatory_features:0L
    |> require_ok Authority.error_to_string
  in
  let runtime = Runtime.default_configuration in
  let issuer_state =
    Group.create ~runtime ~repository_id ~device_id:(device 'i')
    |> require_ok Group.error_to_string
  in
  let issue =
    Invitation.issue ~runtime ~authority ~root ~issuer_state
      ~recipient_device_id:(device 'r') ~issued_at:10L ~expires_at:20L
      ~invitation_key:(key 'k') ~invitation_nonce:(nonce 'n')
      ~event_nonce:(nonce 'e')
    |> require_ok Invitation.error_to_string
  in
  (authority, issue)

let records_publish_create_only_and_corruption_refuses () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let authority, issue = fixture () in
      let invitation = issue.Invitation.invitation in
      let issued_event = issue.Invitation.issued_event in
      Alcotest.(check bool)
        "first invitation publication" true
        (Invitation_store.write_invitation ~root ~authority invitation
        |> require_ok Invitation_store.error_to_string
        = Invitation_store.Published);
      Alcotest.(check bool)
        "exact invitation retry" true
        (Invitation_store.write_invitation ~root ~authority invitation
        |> require_ok Invitation_store.error_to_string
        = Invitation_store.Already_published);
      Alcotest.(check bool)
        "issued event publication" true
        (Invitation_store.write_membership_event ~root ~authority issued_event
        |> require_ok Invitation_store.error_to_string
        = Invitation_store.Published);
      let reopened =
        Invitation_store.read_invitation ~root ~authority
          (Invitation.invitation_id invitation)
        |> require_ok Invitation_store.error_to_string
      in
      Alcotest.(check string)
        "canonical invitation reopens"
        (Invitation.encode_invitation invitation)
        (Invitation.encode_invitation reopened);
      let events =
        Invitation_store.read_membership_events ~root ~authority
        |> require_ok Invitation_store.error_to_string
      in
      Alcotest.(check int) "one canonical event reopens" 1 (List.length events);
      let path =
        Invitation_store.invitation_path ~root
          (Invitation.invitation_id invitation)
      in
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          ignore (Unix.write descriptor (Bytes.of_string "corrupt") 0 7));
      Alcotest.(check bool)
        "corruption is not overwritten" true
        (Result.is_error
           (Invitation_store.write_invitation ~root ~authority invitation));
      Alcotest.(check bool)
        "corruption refuses reopening" true
        (Result.is_error
           (Invitation_store.read_invitation ~root ~authority
              (Invitation.invitation_id invitation))))

let unknown_records_fail_closed () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let authority, issue = fixture () in
      ignore
        (Invitation_store.write_membership_event ~root ~authority
           issue.Invitation.issued_event
        |> require_ok Invitation_store.error_to_string);
      let unknown =
        Filename.concat
          (Invitation_store.membership_event_directory ~root)
          "not-a-record"
      in
      let descriptor =
        Unix.openfile unknown [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "unknown durable entry refuses enumeration" true
        (Result.is_error
           (Invitation_store.read_membership_events ~root ~authority)))

let () =
  Alcotest.run "V2 MLS invitation store"
    [
      ( "persistence",
        [
          Alcotest.test_case "create-only records survive exact retries" `Slow
            records_publish_create_only_and_corruption_refuses;
          Alcotest.test_case "unknown records fail closed" `Slow
            unknown_records_fail_closed;
        ] );
    ]
