module Golden = Yeokcham_testkit.Golden_fixture
module Custody = Yeokcham_v4_custody
module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let id parser value = parser value |> Result.get_ok
let change value = id Model.Change_id.of_string value
let revision value = id Model.Revision_id.of_string value
let snapshot value = id Model.Snapshot_id.of_string value

let rec remove_tree path =
  if Sys.file_exists path then
    Sys.readdir path
    |> Array.iter (fun child ->
        let child = Filename.concat path child in
        if (Unix.lstat child).Unix.st_kind = Unix.S_DIR then remove_tree child
        else Unix.unlink child);
  if Sys.file_exists path then Unix.rmdir path

let with_repository callback =
  let root = Filename.temp_file "yeokcham-v4-custody-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root ".yeokcham") 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> callback root)

let bytes_hex bytes =
  let output = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index byte ->
      Bytes.set output (index * 2) "0123456789abcdef".[Char.code byte lsr 4];
      Bytes.set output
        ((index * 2) + 1)
        "0123456789abcdef".[Char.code byte land 15])
    bytes;
  Bytes.unsafe_to_string output

let fixture_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let software_capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let device capability =
  Trust.signing_public_key capability
  |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let custody_profile_is_canonical_and_local () =
  with_repository (fun root ->
      let public_key = String.make 32 'a' in
      let device =
        Trust.device_of_public_key public_key
        |> require_ok Trust.error_to_string
      in
      let profile =
        {
          Custody.device = Trust.device_id device;
          provider = Custody.Ssh_agent { public_key };
        }
      in
      Custody.save ~root profile |> require_ok Custody.error_to_string;
      let path = Custody.profile_path ~root profile.Custody.device in
      let bytes = In_channel.with_open_bin path In_channel.input_all in
      let fixture = fixture_path "v4/custody-profile-v1.cbor.hex" in
      let expected =
        if Sys.file_exists fixture then
          Golden.read_lower_hex_file fixture |> require_ok Fun.id
        else Alcotest.fail ("missing custody fixture: " ^ bytes_hex bytes)
      in
      Alcotest.(check string) "canonical profile fixture" expected bytes;
      Alcotest.(check int)
        "profile mode" 0o600
        ((Unix.stat path).Unix.st_perm land 0o777);
      let loaded =
        Custody.find ~root profile.Custody.device
        |> require_ok Custody.error_to_string
      in
      Alcotest.(check bool)
        "profile is local exact device" true
        (Model.Device_id.equal loaded.Custody.device profile.Custody.device);
      match Custody.save ~root profile with
      | Error error ->
          Alcotest.(check string)
            "profile overwrite refused"
            "V4 local custody profile already exists"
            (Custody.error_to_string error)
      | Ok () -> Alcotest.fail "custody profile overwrite succeeded")

let denied_signer_cannot_create_a_record () =
  let source = software_capability 'a' in
  let public_key = Trust.signing_public_key source in
  let denied =
    Trust.signing_capability_of_external_signer ~public_key
      ~sign:(fun ~domain:_ _ -> Error "user denied signing")
    |> require_ok Trust.error_to_string
  in
  let device = device denied in
  let repository =
    Trust.Repository_id.of_string
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> Result.get_ok
  in
  match Trust.root_certificate ~repository ~device denied with
  | Error error ->
      Alcotest.(check string)
        "user denial reaches the trust boundary"
        "V4 signer failed: user denied signing"
        (Trust.error_to_string error)
  | Ok _ -> Alcotest.fail "denied external signer created a root certificate"

let execute program arguments =
  let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close null)
    (fun () ->
      let pid = Unix.create_process program arguments Unix.stdin null null in
      match Unix.waitpid [] pid with
      | _, Unix.WEXITED 0 -> ()
      | _, Unix.WEXITED status ->
          Alcotest.fail (Printf.sprintf "%s exited %d" program status)
      | _, Unix.WSIGNALED signal | _, Unix.WSTOPPED signal ->
          Alcotest.fail (Printf.sprintf "%s stopped with %d" program signal))

let wait_for_socket socket =
  let rec loop remaining =
    if Sys.file_exists socket then ()
    else if remaining = 0 then
      Alcotest.fail "ssh-agent did not create its socket"
    else (
      Unix.sleepf 0.02;
      loop (remaining - 1))
  in
  loop 100

let with_ssh_agent root callback =
  let socket =
    Filename.temp_file ~temp_dir:"/tmp" "yeokcham-v4-agent-" ".sock"
  in
  Unix.unlink socket;
  let private_key = Filename.concat root "agent-key" in
  execute "/usr/bin/ssh-keygen"
    [|
      "/usr/bin/ssh-keygen"; "-q"; "-t"; "ed25519"; "-N"; ""; "-f"; private_key;
    |];
  let agent =
    let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close null)
      (fun () ->
        Unix.create_process "/usr/bin/ssh-agent"
          [| "/usr/bin/ssh-agent"; "-D"; "-a"; socket |]
          Unix.stdin null null)
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill agent Sys.sigterm with Unix.Unix_error _ -> ());
      ignore (Unix.waitpid [] agent);
      try Unix.unlink socket with Unix.Unix_error _ -> ())
    (fun () ->
      wait_for_socket socket;
      Unix.putenv "SSH_AUTH_SOCK" socket;
      execute "/usr/bin/ssh-add" [| "/usr/bin/ssh-add"; private_key |];
      callback (private_key ^ ".pub"))

let ssh_agent_signs_only_for_its_explicit_key () =
  with_repository (fun root ->
      with_ssh_agent root (fun public_key_path ->
          let public_key =
            Custody.ssh_public_key_file public_key_path
            |> require_ok Custody.error_to_string
          in
          let device_id =
            Custody.attach_ssh_agent ~root ~public_key
            |> require_ok Custody.error_to_string
          in
          let capability =
            Custody.load ~root device_id |> require_ok Custody.error_to_string
          in
          let device = device capability in
          let signature =
            Trust.sign_detached capability ~domain:"yeokcham:test:agent:\000"
              "exact bytes"
            |> require_ok Trust.error_to_string
          in
          Trust.verify_detached ~device ~domain:"yeokcham:test:agent:\000"
            ~signature "exact bytes"
          |> require_ok Trust.error_to_string;
          Alcotest.(check (result string string))
            "non-exportable agent key"
            (Error
               "V4 signer is non-exportable and cannot provide private key \
                bytes")
            (Trust.signing_private_key_bytes capability
            |> Result.map_error Trust.error_to_string)))

let sample_revision author =
  Model.make_change_revision ~change:(change "custody-change")
    ~revision:(revision "custody-revision")
    ~parent:None ~author ~base:(snapshot "custody-base")
    ~result:(snapshot "custody-result")
    ~edits:
      [
        {
          Model.edit_path =
            Model.Path.of_components [ "main.ml" ] |> Result.get_ok;
          edit_kind = Model.Whole_path;
        };
      ]
  |> require_ok Model.error_to_string

let pkcs11_signs_every_v4_action () =
  match Sys.getenv_opt "YEOKCHAM_V4_TEST_PKCS11_MODULE" with
  | None -> Alcotest.skip ()
  | Some module_path ->
      with_repository (fun root ->
          let pin = "1234" in
          let token_label = "yeokcham-v4-test" in
          let key_id =
            "yeokcham-v4-custody-" ^ string_of_int (Unix.getpid ())
          in
          let device_id =
            Custody.create_pkcs11_with_pin ~root ~module_path ~token_label
              ~key_label:
                ("yeokcham-v4-test-key-" ^ string_of_int (Unix.getpid ()))
              ~key_id ~pin
            |> require_ok Custody.error_to_string
          in
          let capability =
            Custody.load_with_pin ~root ~pin device_id
            |> require_ok Custody.error_to_string
          in
          let root_device = device capability in
          (match Trust.signing_private_key_bytes capability with
          | Error error ->
              Alcotest.(check string)
                "PKCS#11 capability is non-exportable"
                "V4 signer is non-exportable and cannot provide private key \
                 bytes"
                (Trust.error_to_string error)
          | Ok _ -> Alcotest.fail "PKCS#11 capability exported a private key");
          let repository =
            Trust.Repository_id.of_string
              "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            |> Result.get_ok
          in
          let root_certificate =
            Trust.root_certificate ~repository ~device:root_device capability
            |> require_ok Trust.error_to_string
          in
          let membership =
            Trust.verify_membership ~repository [ root_certificate ]
            |> require_ok Trust.error_to_string
          in
          let enrolled_device = device (software_capability 'e') in
          Trust.enroll membership
            ~issuer:(Trust.certificate_id root_certificate)
            capability ~subject:enrolled_device ~role:Trust.Member
          |> require_ok Trust.error_to_string
          |> ignore;
          let recovery = device (software_capability 'r') in
          let epoch =
            Trust.root_epoch ~membership
              ~root_certificate:(Trust.certificate_id root_certificate)
              ~recovery_device:recovery capability
            |> require_ok Trust.error_to_string
          in
          let authority =
            Trust.verify_authority ~membership [ epoch ]
            |> require_ok Trust.error_to_string
          in
          let revision = sample_revision (Trust.device_id root_device) in
          let signed =
            Trust.sign_revision_at authority ~epoch:(Trust.epoch_id epoch)
              ~certificate:(Trust.certificate_id root_certificate)
              capability revision
            |> require_ok Trust.error_to_string
          in
          let decision = id Model.Decision_id.of_string "custody-decision" in
          let resolution =
            Trust.sign_resolution_at authority ~epoch:(Trust.epoch_id epoch)
              ~certificate:(Trust.certificate_id root_certificate)
              capability ~decision revision
            |> require_ok Trust.error_to_string
          in
          ignore resolution;
          Trust.make_authorization authority ~epoch:(Trust.epoch_id epoch)
            ~issuer:(Trust.certificate_id root_certificate)
            capability ~device:root_device ~revision:revision.Model.revision
            ~change:revision.Model.change
          |> require_ok Trust.error_to_string
          |> ignore;
          Trust.make_adoption authority ~epoch:(Trust.epoch_id epoch)
            ~issuer:(Trust.certificate_id root_certificate)
            capability ~signed_revision:signed
          |> require_ok Trust.error_to_string
          |> ignore;
          let profile_path = Custody.profile_path ~root device_id in
          let before =
            In_channel.with_open_bin profile_path In_channel.input_all
          in
          let denied_capability =
            Custody.load_with_pin ~root ~pin:"wrong-pin" device_id
            |> require_ok Custody.error_to_string
          in
          (match
             Trust.root_certificate ~repository ~device:root_device
               denied_capability
           with
          | Error error ->
              Alcotest.(check string)
                "wrong token PIN crosses no signing boundary"
                "V4 signer failed: V4 PKCS#11 token is locked or denied signing"
                (Trust.error_to_string error)
          | Ok _ -> Alcotest.fail "wrong token PIN created a root certificate");
          let after =
            In_channel.with_open_bin profile_path In_channel.input_all
          in
          Alcotest.(check string)
            "PIN denial leaves local custody profile unchanged" before after;
          let mismatched_public_key = String.make 32 'x' in
          let mismatched_device =
            Trust.device_of_public_key mismatched_public_key
            |> require_ok Trust.error_to_string
          in
          (match
             Custody.attach_pkcs11 ~root ~module_path ~token_label ~key_id
               ~public_key:mismatched_public_key
           with
          | Error error ->
              Alcotest.(check string)
                "token key mismatch is explicit"
                "custody provider public key does not match device"
                (Custody.error_to_string error)
          | Ok _ -> Alcotest.fail "mismatched PKCS#11 public key was attached");
          Alcotest.(check bool)
            "mismatched key creates no local profile" false
            (Sys.file_exists
               (Custody.profile_path ~root (Trust.device_id mismatched_device)));
          match
            Custody.attach_pkcs11 ~root
              ~module_path:"/definitely/not/a/yeokcham-pkcs11-module.so"
              ~token_label ~key_id
              ~public_key:(Trust.device_public_key root_device)
          with
          | Error error ->
              Alcotest.(check string)
                "absent provider is explicit"
                "V4 PKCS#11 provider is unavailable: module or token could not \
                 be opened"
                (Custody.error_to_string error)
          | Ok _ -> Alcotest.fail "unavailable PKCS#11 provider was attached")

let () =
  Alcotest.run "V4 custody"
    [
      ( "profiles",
        [
          Alcotest.test_case "profile is canonical and local" `Quick
            custody_profile_is_canonical_and_local;
          Alcotest.test_case "denied provider leaves no signed record" `Quick
            denied_signer_cannot_create_a_record;
          Alcotest.test_case "SSH agent signs for explicit key only" `Quick
            ssh_agent_signs_only_for_its_explicit_key;
          Alcotest.test_case "PKCS#11 token signs V4 actions" `Slow
            pkcs11_signs_every_v4_action;
        ] );
    ]
