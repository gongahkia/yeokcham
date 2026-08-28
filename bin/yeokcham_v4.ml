module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service
module Trust = Yeokcham_v4_trust
module Package = Yeokcham_v4_package
module Recovery = Yeokcham_v4_recovery

let fail message =
  prerr_endline message;
  exit 2

let usage () =
  fail
    "usage:\n\
    \  yeokcham init [--root PATH] --username NAME --draft ID --title TITLE\n\
    \  yeokcham join [--root PATH] --username NAME --draft ID --title TITLE \\\n\
    \     --device ID --from PATH --verify-phrase \"TWELVE WORDS\"\n\
    \  yeokcham save [--root PATH]\n\
    \  yeokcham status [--root PATH]\n\
    \  yeokcham device create\n\
    \  yeokcham device show [--root PATH]\n\
    \  yeokcham device enroll [--root PATH] --device ID --public-key HEX \
     --username NAME [--administrator] [--parent EPOCH]\n\
    \  yeokcham device revoke [--root PATH] --device ID [--parent EPOCH]\n\
    \  yeokcham device rotate [--root PATH] --device ID --public-key HEX \
     [--parent EPOCH]\n\
    \  yeokcham authority heads [--root PATH]\n\
    \  yeokcham authority reconcile [--root PATH] --parents EPOCH,EPOCH[,EPOCH]\n\
    \  yeokcham recovery use [--root PATH] --package PATH --mnemonic \"TWENTY \
     FOUR WORDS\" --replacement ID --replaced ID --output PATH\n\
    \  yeokcham recovery refresh [--root PATH] --package PATH --mnemonic \
     \"TWENTY FOUR WORDS\" --output PATH\n\
    \  yeokcham user register [--root PATH] --device ID --username NAME\n\
    \  yeokcham timeline [--root PATH]\n\
    \  yeokcham restore [--root PATH] --checkpoint ID [--destination PATH]\n\
    \  yeokcham draft new [--root PATH] --id ID --title TITLE\n\
    \  yeokcham share [--root PATH] --change ID --revision ID [--authority \
     EPOCH]\n\
    \  yeokcham withdraw [--root PATH] --change ID\n\
    \  yeokcham resolve [--root PATH] --decision ID --change ID --revision ID \
     [--tree PATH] [--authority EPOCH]\n\
    \  yeokcham decision show [--root PATH] --decision ID\n\
    \  yeokcham decision inspect [--root PATH] --decision ID\n\
    \  yeokcham decision diff [--root PATH] --decision ID --candidate REV \
     [--against base|REV]\n\
    \  yeokcham decision materialize [--root PATH] --decision ID --destination \
     PATH\n\
    \  yeokcham package create [--root PATH] --destination PATH\n\
    \  yeokcham package adopt [--root PATH] --from PATH --revision ID \
     [--authority EPOCH]\n\
    \  yeokcham receive [--root PATH] --from PATH [--review]\n\
    \  yeokcham deliver [--root PATH] --id ID --draft ID --title TITLE\n\
    \  yeokcham pin [--root PATH] --checkpoint ID\n\
    \  yeokcham unpin [--root PATH] --checkpoint ID\n\
    \  yeokcham compact [--root PATH] [--keep N] [--dry-run] [--explain]\n\
    \  yeokcham watch [--root PATH]"

let require_ok render = function
  | Ok value -> value
  | Error error -> fail (render error)

let default_root = Sys.getcwd ()

let parse_root = function
  | [] -> default_root
  | [ "--root"; root ] -> root
  | _ -> usage ()

let parse_identifier name parser value =
  parser value
  |> require_ok (fun error -> name ^ ": " ^ Model.error_to_string error)

let hex_of_bytes bytes =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length bytes * 2)
    (fun index ->
      let value = Char.code bytes.[index / 2] in
      if index mod 2 = 0 then alphabet.[value lsr 4]
      else alphabet.[value land 0x0f])

let bytes_of_hex value =
  let nibble = function
    | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
    | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
    | _ -> None
  in
  if String.length value mod 2 <> 0 then
    fail "public key must be lowercase hexadecimal"
  else
    let bytes = Bytes.create (String.length value / 2) in
    let rec decode offset =
      if offset = String.length value then Bytes.unsafe_to_string bytes
      else
        match (nibble value.[offset], nibble value.[offset + 1]) with
        | Some high, Some low ->
            Bytes.set bytes (offset / 2) (Char.chr ((high lsl 4) lor low));
            decode (offset + 2)
        | None, _ | _, None -> fail "public key must be lowercase hexadecimal"
    in
    decode 0

let render_status status =
  Printf.printf "device %s\n" (Model.Device_id.to_string status.Service.creator);
  Printf.printf "saved %s\n"
    (Model.Snapshot_id.to_string status.Service.checkpoint);
  Printf.printf "draft %s %s\n"
    (Model.Draft_id.to_string status.Service.active_draft.Model.draft_id)
    status.Service.active_draft.Model.title;
  Printf.printf "shared %d\n" status.Service.shared_change_count;
  List.iter
    (fun change ->
      Printf.printf "change %s\n"
        (Model.Change_id.to_string change.Model.change_id))
    status.Service.shared_changes;
  Printf.printf "needs-decision %d\n"
    (List.length status.Service.open_decisions);
  List.iter
    (fun decision ->
      Printf.printf "decision %s\n"
        (Model.Decision_id.to_string decision.Model.decision_id))
    status.Service.open_decisions;
  Printf.printf "delivered %d\n" status.Service.delivery_count;
  List.iter
    (fun delivery ->
      Printf.printf "delivery %s\n"
        (Model.Delivery_id.to_string delivery.Model.delivery_id))
    status.Service.deliveries;
  Printf.printf "users %d\n" (List.length status.Service.usernames);
  status.Service.usernames
  |> List.sort (fun left right ->
      Model.Device_id.compare left.Model.username_device
        right.Model.username_device)
  |> List.iter (fun registration ->
      Printf.printf "user %s %s\n"
        (Model.Device_id.to_string registration.Model.username_device)
        (Model.Username.to_string registration.Model.username));
  print_endline "capture command";
  Printf.printf "uncaptured %s\n"
    (if status.Service.uncaptured then "yes" else "no")

let parse_init arguments =
  let rec loop root username draft title = function
    | [] -> (
        match (username, draft, title) with
        | Some username, Some draft, Some title ->
            (Option.value root ~default:default_root, username, draft, title)
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) username draft title rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root (Some value) draft title rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root username (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root username draft (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let parse_new_draft arguments =
  let rec loop root id title = function
    | [] -> (
        match (id, title) with
        | Some id, Some title ->
            (Option.value root ~default:default_root, id, title)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id title rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root id (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let parse_restore arguments =
  let rec loop root checkpoint destination = function
    | [] -> (
        match checkpoint with
        | Some checkpoint ->
            (Option.value root ~default:default_root, checkpoint, destination)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) checkpoint destination rest
    | "--checkpoint" :: value :: rest when Option.is_none checkpoint ->
        loop root (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root checkpoint (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_init arguments =
  let root, username, draft, title = parse_init arguments in
  let initial_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  let repository =
    Trust.Repository_id.generate ()
    |> require_ok (fun error ->
        "could not generate V4 repository identity: " ^ error)
  in
  let device, signing_capability =
    V4_signer.create () |> require_ok V4_signer.error_to_string
  in
  let recovery = Trust.generate_device () |> require_ok Trust.error_to_string in
  let recovery_device = Trust.generated_identity recovery in
  let recovery_capability = Trust.generated_signing_capability recovery in
  let root_certificate =
    Trust.root_certificate ~repository ~device signing_capability
    |> require_ok Trust.error_to_string
  in
  let status, ceremony =
    Service.init_signed_with_recovery ~root ~username ~initial_draft ~title
      ~repository ~device ~signing_capability ~recovery_device
      ~recovery_capability
    |> require_ok Service.error_to_string
  in
  render_status status;
  print_endline "root-verification-phrase (compare during device join)";
  Printf.printf "%s\n" (Recovery.verification_phrase root_certificate);
  Printf.printf "recovery-package %s\n" (Service.recovery_package_path root);
  print_endline "recovery-mnemonic (record offline; it is shown only now)";
  Printf.printf "%s\n" ceremony.Yeokcham_v4_recovery.mnemonic

let parse_join arguments =
  let rec loop root username draft title device package phrase = function
    | [] -> (
        match (username, draft, title, device, package, phrase) with
        | ( Some username,
            Some draft,
            Some title,
            Some device,
            Some package,
            Some phrase ) ->
            ( Option.value root ~default:default_root,
              username,
              draft,
              title,
              device,
              package,
              phrase )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) username draft title device package phrase rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root (Some value) draft title device package phrase rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root username (Some value) title device package phrase rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root username draft (Some value) device package phrase rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root username draft title (Some value) package phrase rest
    | "--from" :: value :: rest when Option.is_none package ->
        loop root username draft title device (Some value) phrase rest
    | "--verify-phrase" :: value :: rest when Option.is_none phrase ->
        loop root username draft title device package (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None None arguments

let run_join arguments =
  let root, username, draft, title, device, package, phrase =
    parse_join arguments
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  let initial_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  let device_id =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let authority =
    Package.inspect_authority ~package |> require_ok Package.error_to_string
  in
  let root_certificate =
    match
      Trust.certificates (Trust.authority_membership authority)
      |> List.find_opt (fun certificate ->
          Trust.certificate_issuer certificate = None)
    with
    | Some certificate -> certificate
    | None -> fail "authority closure has no root certificate"
  in
  if not (String.equal phrase (Recovery.verification_phrase root_certificate))
  then fail "root verification phrase does not match the authority closure";
  let signing_capability =
    V4_signer.load device_id |> require_ok V4_signer.error_to_string
  in
  let local_device =
    Trust.signing_public_key signing_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal device_id (Trust.device_id local_device)) then
    fail "local signing capability does not match --device";
  let local_certificate =
    match
      Trust.certificates (Trust.authority_membership authority)
      |> List.find_opt (fun certificate ->
          Model.Device_id.equal
            (Trust.device_id (Trust.certificate_subject certificate))
            device_id)
    with
    | Some certificate -> Trust.certificate_id certificate
    | None -> fail "device is not enrolled in the authority closure"
  in
  Service.init_authority_collaboration ~root ~username ~initial_draft ~title
    ~device:local_device ~authority ~local_certificate
  |> require_ok Service.error_to_string
  |> render_status;
  print_endline
    "join verified authority closure; receive the package separately"

let local_signing_capability root =
  let identity = Service.identity ~root |> require_ok Service.error_to_string in
  V4_signer.load (Trust.device_id identity.Service.device)
  |> require_ok V4_signer.error_to_string

let parse_user_register arguments =
  let rec loop root device username = function
    | [] -> (
        match (device, username) with
        | Some device, Some username ->
            (Option.value root ~default:default_root, device, username)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device username rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) username rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root device (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_user_register arguments =
  let root, device, username = parse_user_register arguments in
  let device =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  Service.register_username ~root ~device ~username
  |> require_ok Service.error_to_string
  |> render_status

let run_save arguments =
  let root = parse_root arguments in
  Service.save ~root |> require_ok Service.error_to_string |> function
  | Service.Unchanged status ->
      print_endline "save unchanged";
      render_status status
  | Service.Saved status ->
      print_endline "save recorded";
      render_status status

let run_status arguments =
  let root = parse_root arguments in
  Service.status ~root |> require_ok Service.error_to_string |> render_status

let run_device_create arguments =
  match arguments with
  | [] ->
      let device, _ =
        V4_signer.create () |> require_ok V4_signer.error_to_string
      in
      Printf.printf "device %s\n"
        (Model.Device_id.to_string (Trust.device_id device));
      Printf.printf "public-key %s\n"
        (hex_of_bytes (Trust.device_public_key device))
  | _ -> usage ()

let run_device_show arguments =
  let root = parse_root arguments in
  let identity = Service.identity ~root |> require_ok Service.error_to_string in
  Printf.printf "repository %s\n"
    (Trust.Repository_id.to_string identity.Service.repository);
  Printf.printf "device %s\n"
    (Model.Device_id.to_string (Trust.device_id identity.Service.device));
  Printf.printf "public-key %s\n"
    (hex_of_bytes (Trust.device_public_key identity.Service.device));
  Printf.printf "role %s\n"
    (match identity.Service.role with
    | Trust.Member -> "member"
    | Trust.Administrator -> "administrator")

let parse_device_enroll arguments =
  let rec loop root device public_key username administrator parent = function
    | [] -> (
        match (device, public_key, username) with
        | Some device, Some public_key, Some username ->
            ( Option.value root ~default:default_root,
              device,
              public_key,
              username,
              administrator,
              parent )
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device public_key username administrator parent rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) public_key username administrator parent rest
    | "--public-key" :: value :: rest when Option.is_none public_key ->
        loop root device (Some value) username administrator parent rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root device public_key (Some value) administrator parent rest
    | "--administrator" :: rest when not administrator ->
        loop root device public_key username true parent rest
    | "--parent" :: value :: rest when Option.is_none parent ->
        loop root device public_key username administrator (Some value) rest
    | _ -> usage ()
  in
  loop None None None None false None arguments

let run_device_enroll arguments =
  let root, device, public_key, username, administrator, parent =
    parse_device_enroll arguments
  in
  let expected =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let subject =
    bytes_of_hex public_key |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal expected (Trust.device_id subject)) then
    fail "device identifier does not match public key";
  let username =
    parse_identifier "invalid username" Model.Username.of_string username
  in
  let signing_capability = local_signing_capability root in
  let role = if administrator then Trust.Administrator else Trust.Member in
  Service.enroll_device ~parent ~root ~subject ~role ~username
    ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_device_only arguments =
  let rec loop root device parent = function
    | [] -> (
        match device with
        | Some device ->
            (Option.value root ~default:default_root, device, parent)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device parent rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) parent rest
    | "--parent" :: value :: rest when Option.is_none parent ->
        loop root device (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_device_revoke arguments =
  let root, device, parent = parse_device_only arguments in
  let device =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let signing_capability = local_signing_capability root in
  Service.revoke_device ~parent ~root ~device ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_device_key arguments =
  let rec loop root device public_key parent = function
    | [] -> (
        match (device, public_key) with
        | Some device, Some public_key ->
            (Option.value root ~default:default_root, device, public_key, parent)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) device public_key parent rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root (Some value) public_key parent rest
    | "--public-key" :: value :: rest when Option.is_none public_key ->
        loop root device (Some value) parent rest
    | "--parent" :: value :: rest when Option.is_none parent ->
        loop root device public_key (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_device_rotate arguments =
  let root, device, public_key, parent = parse_device_key arguments in
  let expected =
    parse_identifier "invalid device identifier" Model.Device_id.of_string
      device
  in
  let replacement =
    bytes_of_hex public_key |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal expected (Trust.device_id replacement)) then
    fail "device identifier does not match public key";
  let signing_capability = local_signing_capability root in
  Service.rotate_local_device ~parent ~root ~replacement ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let run_authority_heads arguments =
  let root = parse_root arguments in
  Service.authority_heads ~root
  |> require_ok Service.error_to_string
  |> List.iter (fun epoch -> Printf.printf "authority-head %s\n" epoch)

let parse_authority_reconcile arguments =
  let rec loop root parents = function
    | [] -> (
        match parents with
        | Some parents -> (Option.value root ~default:default_root, parents)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) parents rest
    | "--parents" :: value :: rest when Option.is_none parents ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_authority_reconcile arguments =
  let root, parents = parse_authority_reconcile arguments in
  let parents =
    if String.equal parents "" then
      fail "--parents must name at least two authority heads"
    else String.split_on_char ',' parents
  in
  let signing_capability = local_signing_capability root in
  Service.reconcile_authority ~root ~parents ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_recovery_use arguments =
  let rec loop root package mnemonic replacement replaced output = function
    | [] -> (
        match (package, mnemonic, replacement, replaced, output) with
        | ( Some package,
            Some mnemonic,
            Some replacement,
            Some replaced,
            Some output ) ->
            ( Option.value root ~default:default_root,
              package,
              mnemonic,
              replacement,
              replaced,
              output )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package mnemonic replacement replaced output rest
    | "--package" :: value :: rest when Option.is_none package ->
        loop root (Some value) mnemonic replacement replaced output rest
    | "--mnemonic" :: value :: rest when Option.is_none mnemonic ->
        loop root package (Some value) replacement replaced output rest
    | "--replacement" :: value :: rest when Option.is_none replacement ->
        loop root package mnemonic (Some value) replaced output rest
    | "--replaced" :: value :: rest when Option.is_none replaced ->
        loop root package mnemonic replacement (Some value) output rest
    | "--output" :: value :: rest when Option.is_none output ->
        loop root package mnemonic replacement replaced (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None arguments

let run_recovery_use arguments =
  let root, package, mnemonic, replacement, replaced, output =
    parse_recovery_use arguments
  in
  let replacement_id =
    parse_identifier "invalid replacement device identifier"
      Model.Device_id.of_string replacement
  in
  let replaced =
    parse_identifier "invalid replaced device identifier"
      Model.Device_id.of_string replaced
  in
  let replacement_capability =
    V4_signer.load replacement_id |> require_ok V4_signer.error_to_string
  in
  let replacement_device =
    Trust.signing_public_key replacement_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let status, ceremony =
    Service.recover_authority ~root ~package ~mnemonic ~output
      ~replacement:replacement_device ~replaced
    |> require_ok Service.error_to_string
  in
  render_status status;
  Printf.printf "recovery-package %s\n" output;
  print_endline "recovery-mnemonic (record offline; it is shown only now)";
  Printf.printf "%s\n" ceremony.Recovery.mnemonic

let parse_recovery_refresh arguments =
  let rec loop root package mnemonic output = function
    | [] -> (
        match (package, mnemonic, output) with
        | Some package, Some mnemonic, Some output ->
            (Option.value root ~default:default_root, package, mnemonic, output)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package mnemonic output rest
    | "--package" :: value :: rest when Option.is_none package ->
        loop root (Some value) mnemonic output rest
    | "--mnemonic" :: value :: rest when Option.is_none mnemonic ->
        loop root package (Some value) output rest
    | "--output" :: value :: rest when Option.is_none output ->
        loop root package mnemonic (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_recovery_refresh arguments =
  let root, package, mnemonic, output = parse_recovery_refresh arguments in
  Service.refresh_recovery_package ~root ~package ~mnemonic ~output
  |> require_ok Service.error_to_string;
  Printf.printf "recovery-package %s\n" output

let run_timeline arguments =
  let root = parse_root arguments in
  Service.status ~root |> require_ok Service.error_to_string |> fun status ->
  List.iter
    (fun checkpoint ->
      Printf.printf "checkpoint %s\n"
        (Model.Snapshot_id.to_string checkpoint.Model.checkpoint_snapshot))
    status.Service.checkpoints

let run_restore arguments =
  let root, checkpoint, destination = parse_restore arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  match destination with
  | Some destination ->
      Service.restore ~root ~checkpoint ~destination
      |> require_ok Service.error_to_string;
      Printf.printf "restored %s to %s\n"
        (Model.Snapshot_id.to_string checkpoint)
        destination
  | None ->
      let restored =
        Service.restore_in_place ~root ~checkpoint
        |> require_ok Service.error_to_string
      in
      Printf.printf "safety %s\n"
        (Model.Snapshot_id.to_string restored.Service.safety_checkpoint);
      Printf.printf "restored %s in-place%s\n"
        (Model.Snapshot_id.to_string restored.Service.restored_checkpoint)
        (if restored.Service.resumed then " (resumed)" else "")

let parse_share arguments =
  let rec loop root change revision authority = function
    | [] -> (
        match (change, revision) with
        | Some change, Some revision ->
            ( Option.value root ~default:default_root,
              change,
              revision,
              authority )
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) change revision authority rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root (Some value) revision authority rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root change (Some value) authority rest
    | "--authority" :: value :: rest when Option.is_none authority ->
        loop root change revision (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let parse_withdraw arguments =
  let rec loop root change = function
    | [] -> (
        match change with
        | Some change -> (Option.value root ~default:default_root, change)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) change rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_resolve arguments =
  let rec loop root decision change revision tree authority = function
    | [] -> (
        match (decision, change, revision) with
        | Some decision, Some change, Some revision ->
            ( Option.value root ~default:default_root,
              decision,
              change,
              revision,
              tree,
              authority )
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision change revision tree authority rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) change revision tree authority rest
    | "--change" :: value :: rest when Option.is_none change ->
        loop root decision (Some value) revision tree authority rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root decision change (Some value) tree authority rest
    | "--tree" :: value :: rest when Option.is_none tree ->
        loop root decision change revision (Some value) authority rest
    | "--authority" :: value :: rest when Option.is_none authority ->
        loop root decision change revision tree (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None arguments

let parse_decision_show arguments =
  let rec loop root decision = function
    | [] -> (
        match decision with
        | Some decision -> (Option.value root ~default:default_root, decision)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_decision_materialize arguments =
  let rec loop root decision destination = function
    | [] -> (
        match (decision, destination) with
        | Some decision, Some destination ->
            (Option.value root ~default:default_root, decision, destination)
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision destination rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root decision (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let parse_decision_diff arguments =
  let rec loop root decision candidate against = function
    | [] -> (
        match (decision, candidate) with
        | Some decision, Some candidate ->
            ( Option.value root ~default:default_root,
              decision,
              candidate,
              Option.value against ~default:"base" )
        | None, _ | _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision candidate against rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) candidate against rest
    | "--candidate" :: value :: rest when Option.is_none candidate ->
        loop root decision (Some value) against rest
    | "--against" :: value :: rest when Option.is_none against ->
        loop root decision candidate (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let decision_kind_name = function
  | Model.Stale_base -> "stale-base"
  | Model.Edit_overlap -> "edit-overlap"

let edit_kind_name = function
  | Model.Whole_path -> "whole-path"
  | Model.Text span ->
      Printf.sprintf "text:%d-%d" span.Model.start_byte span.Model.end_byte

let render_decision (inspection : Service.decision_inspection) =
  let decision = inspection.Service.inspected_decision in
  Printf.printf "decision %s\n"
    (Model.Decision_id.to_string decision.Model.decision_id);
  Printf.printf "kind %s\n" (decision_kind_name decision.Model.decision_kind);
  List.iter
    (fun path -> Printf.printf "path %s\n" (Model.Path.to_string path))
    decision.Model.decision_paths;
  List.iter
    (fun candidate ->
      let revision = candidate.Service.inspected_revision in
      let username =
        match candidate.Service.inspected_username with
        | None -> "unregistered"
        | Some username -> Model.Username.to_string username
      in
      Printf.printf
        "candidate %s change %s author %s username %s base %s snapshot %s\n"
        (Model.Revision_id.to_string revision.Model.revision)
        (Model.Change_id.to_string revision.Model.change)
        (Model.Device_id.to_string revision.Model.revision_author)
        username
        (Model.Snapshot_id.to_string revision.Model.base_snapshot)
        (Model.Snapshot_id.to_string revision.Model.result_snapshot))
    inspection.Service.inspected_candidates;
  List.iter
    (fun candidate ->
      let revision = candidate.Model.candidate_revision in
      Printf.printf "edit %s %d %s %s\n"
        (Model.Revision_id.to_string revision.Model.revision)
        candidate.Model.candidate_edit_index
        (Model.Path.to_string candidate.Model.candidate_edit.Model.edit_path)
        (edit_kind_name candidate.Model.candidate_edit.Model.edit_kind))
    decision.Model.candidates

let run_decision_show arguments =
  let root, decision = parse_decision_show arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  Service.inspect_decision ~root ~decision
  |> require_ok Service.error_to_string
  |> render_decision

let snapshot_entry_kind_name = function
  | Service.File -> "file"
  | Service.Directory -> "directory"

let snapshot_mode_name = function
  | Yeokcham_snapshot.Regular -> "regular"
  | Yeokcham_snapshot.Executable -> "executable"
  | Yeokcham_snapshot.Symlink -> "symlink"

let render_snapshot_entry = function
  | None -> "missing"
  | Some entry -> (
      let kind = snapshot_entry_kind_name entry.Service.kind in
      let mode = Option.map snapshot_mode_name entry.Service.mode in
      match (mode, entry.Service.content) with
      | None, None -> kind
      | Some mode, Some content -> kind ^ " " ^ mode ^ " " ^ content
      | Some mode, None -> kind ^ " " ^ mode
      | None, Some content -> kind ^ " " ^ content)

let run_decision_diff arguments =
  let root, decision, candidate, against = parse_decision_diff arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let candidate =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      candidate
  in
  let against =
    if String.equal against "base" then Service.Baseline
    else
      Service.Candidate
        (parse_identifier "invalid revision identifier"
           Model.Revision_id.of_string against)
  in
  let comparison =
    Service.compare_decision ~root ~decision ~candidate ~against
    |> require_ok Service.error_to_string
  in
  Printf.printf "decision %s\n"
    (Model.Decision_id.to_string
       comparison.Service.compared_decision.Model.decision_id);
  Printf.printf "candidate %s\n"
    (Model.Revision_id.to_string
       comparison.Service.compared_candidate.Model.revision);
  Printf.printf "against %s\n"
    (Model.Snapshot_id.to_string comparison.Service.against);
  List.iter
    (fun difference ->
      Printf.printf "diff %s before %s after %s\n"
        (Model.Path.to_string difference.Service.path)
        (render_snapshot_entry difference.Service.before)
        (render_snapshot_entry difference.Service.after))
    comparison.Service.differences

let run_decision_materialize arguments =
  let root, decision, destination = parse_decision_materialize arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let candidates =
    Service.materialize_decision ~root ~decision ~destination
    |> require_ok Service.error_to_string
  in
  List.iter
    (fun candidate ->
      let username =
        match candidate.Service.username with
        | Some username -> Model.Username.to_string username
        | None -> "unregistered"
      in
      Printf.printf "materialized %s author %s username %s tree %s\n"
        (Model.Revision_id.to_string candidate.Service.revision)
        (Model.Device_id.to_string candidate.Service.author)
        username candidate.Service.directory)
    candidates

let run_resolve arguments =
  let root, decision, change, revision, tree, authority_epoch =
    parse_resolve arguments
  in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  let signing_capability = local_signing_capability root in
  Service.resolve_signed ~authority_epoch ~root ~decision ~change ~revision
    ~tree ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_deliver arguments =
  let rec loop root id draft title = function
    | [] -> (
        match (id, draft, title) with
        | Some id, Some draft, Some title ->
            (Option.value root ~default:default_root, id, draft, title)
        | None, _, _ | _, None, _ | _, _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id draft title rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) draft title rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root id (Some value) title rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root id draft (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_new_draft arguments =
  let root, id, title = parse_new_draft arguments in
  let id =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string id
  in
  Service.new_draft ~root ~id ~title
  |> require_ok Service.error_to_string
  |> render_status

let run_share arguments =
  let root, change, revision, authority_epoch = parse_share arguments in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  let signing_capability = local_signing_capability root in
  Service.share_signed ~authority_epoch ~root ~change ~revision
    ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let parse_package_create arguments =
  let rec loop root destination = function
    | [] -> (
        match destination with
        | Some destination ->
            (Option.value root ~default:default_root, destination)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_package_create arguments =
  let root, destination = parse_package_create arguments in
  Service.create_package ~root ~destination
  |> require_ok Service.error_to_string;
  Printf.printf "package %s\n" destination

let parse_receive arguments =
  let rec loop root package review = function
    | [] -> (
        match package with
        | Some package ->
            (Option.value root ~default:default_root, package, review)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package review rest
    | "--from" :: value :: rest when Option.is_none package ->
        loop root (Some value) review rest
    | "--review" :: rest when not review -> loop root package true rest
    | _ -> usage ()
  in
  loop None None false arguments

let run_receive arguments =
  let root, package, review = parse_receive arguments in
  if review then
    Service.review_package ~root ~package
    |> require_ok Service.error_to_string
    |> List.iter (fun candidate ->
        Printf.printf "review %s author %s adoption %s\n"
          (Model.Revision_id.to_string candidate.Service.review_revision)
          (Model.Device_id.to_string candidate.Service.review_author)
          (if candidate.Service.requires_adoption then "required"
           else "not-required"))
  else
    Service.receive_package ~root ~package
    |> require_ok Service.error_to_string
    |> render_status

let parse_package_adopt arguments =
  let rec loop root package revision authority = function
    | [] -> (
        match (package, revision) with
        | Some package, Some revision ->
            ( Option.value root ~default:default_root,
              package,
              revision,
              authority )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) package revision authority rest
    | "--from" :: value :: rest when Option.is_none package ->
        loop root (Some value) revision authority rest
    | "--revision" :: value :: rest when Option.is_none revision ->
        loop root package (Some value) authority rest
    | "--authority" :: value :: rest when Option.is_none authority ->
        loop root package revision (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_package_adopt arguments =
  let root, package, revision, authority_epoch =
    parse_package_adopt arguments
  in
  let revision =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      revision
  in
  let signing_capability = local_signing_capability root in
  Service.adopt_package_revision ~authority_epoch ~root ~package ~revision
    ~signing_capability
  |> require_ok Service.error_to_string
  |> render_status

let run_withdraw arguments =
  let root, change = parse_withdraw arguments in
  let change =
    parse_identifier "invalid change identifier" Model.Change_id.of_string
      change
  in
  Service.withdraw ~root ~change
  |> require_ok Service.error_to_string
  |> render_status

let run_deliver arguments =
  let root, id, draft, title = parse_deliver arguments in
  let id =
    parse_identifier "invalid delivery identifier" Model.Delivery_id.of_string
      id
  in
  let next_draft =
    parse_identifier "invalid draft identifier" Model.Draft_id.of_string draft
  in
  Service.deliver ~root ~id ~next_draft ~next_title:title
  |> require_ok Service.error_to_string
  |> render_status

let parse_pin arguments =
  let rec loop root checkpoint = function
    | [] -> (
        match checkpoint with
        | Some checkpoint ->
            (Option.value root ~default:default_root, checkpoint)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) checkpoint rest
    | "--checkpoint" :: value :: rest when Option.is_none checkpoint ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let parse_compact arguments =
  let rec loop root keep dry_run explain = function
    | [] -> (Option.value root ~default:default_root, keep, dry_run, explain)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) keep dry_run explain rest
    | "--keep" :: value :: rest when Option.is_none keep -> (
        match int_of_string_opt value with
        | Some parsed when parsed >= 0 ->
            loop root (Some parsed) dry_run explain rest
        | Some _ | None -> usage ())
    | "--dry-run" :: rest when not dry_run -> loop root keep true explain rest
    | "--explain" :: rest when not explain -> loop root keep dry_run true rest
    | _ -> usage ()
  in
  loop None None false false arguments

let run_pin arguments =
  let root, checkpoint = parse_pin arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  Service.pin ~root ~checkpoint
  |> require_ok Service.error_to_string
  |> render_status

let run_unpin arguments =
  let root, checkpoint = parse_pin arguments in
  let checkpoint =
    parse_identifier "invalid checkpoint identifier" Model.Snapshot_id.of_string
      checkpoint
  in
  Service.unpin ~root ~checkpoint
  |> require_ok Service.error_to_string
  |> render_status

let render_compact report explain =
  if explain then (
    List.iter
      (fun keep ->
        Printf.printf "keep %s %s\n"
          (Model.Snapshot_id.to_string keep.Model.snapshot)
          (keep.Model.reasons
          |> List.map Model.protection_reason_to_string
          |> String.concat ","))
      report.Service.kept;
    List.iter
      (fun snapshot ->
        Printf.printf "drop %s\n" (Model.Snapshot_id.to_string snapshot))
      report.Service.dropped;
    List.iter
      (fun operation -> Printf.printf "journal-prune %s\n" operation)
      report.Service.pruned_journals);
  Printf.printf "kept %d\n" (List.length report.Service.kept);
  Printf.printf "dropped %d\n" (List.length report.Service.dropped);
  render_status report.Service.status

let run_compact arguments =
  let root, keep, dry_run, explain = parse_compact arguments in
  let keep_recent = Option.value keep ~default:Model.default_keep_recent in
  Service.compact ~root ~keep_recent ~dry_run
  |> require_ok Service.error_to_string
  |> fun report -> render_compact report explain

let run_watch arguments =
  let root = parse_root arguments in
  V4_watch.run ~root

let () =
  match Array.to_list Sys.argv with
  | _ :: "init" :: arguments -> run_init arguments
  | _ :: "join" :: arguments -> run_join arguments
  | _ :: "save" :: arguments -> run_save arguments
  | _ :: "status" :: arguments -> run_status arguments
  | _ :: "device" :: "create" :: arguments -> run_device_create arguments
  | _ :: "device" :: "show" :: arguments -> run_device_show arguments
  | _ :: "device" :: "enroll" :: arguments -> run_device_enroll arguments
  | _ :: "device" :: "revoke" :: arguments -> run_device_revoke arguments
  | _ :: "device" :: "rotate" :: arguments -> run_device_rotate arguments
  | _ :: "authority" :: "heads" :: arguments -> run_authority_heads arguments
  | _ :: "authority" :: "reconcile" :: arguments ->
      run_authority_reconcile arguments
  | _ :: "recovery" :: "use" :: arguments -> run_recovery_use arguments
  | _ :: "recovery" :: "refresh" :: arguments -> run_recovery_refresh arguments
  | _ :: "user" :: "register" :: arguments -> run_user_register arguments
  | _ :: "timeline" :: arguments -> run_timeline arguments
  | _ :: "restore" :: arguments -> run_restore arguments
  | _ :: "draft" :: "new" :: arguments -> run_new_draft arguments
  | _ :: "share" :: arguments -> run_share arguments
  | _ :: "withdraw" :: arguments -> run_withdraw arguments
  | _ :: "resolve" :: arguments -> run_resolve arguments
  | _ :: "decision" :: "show" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "inspect" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "diff" :: arguments -> run_decision_diff arguments
  | _ :: "decision" :: "materialize" :: arguments ->
      run_decision_materialize arguments
  | _ :: "package" :: "create" :: arguments -> run_package_create arguments
  | _ :: "package" :: "adopt" :: arguments -> run_package_adopt arguments
  | _ :: "receive" :: arguments -> run_receive arguments
  | _ :: "deliver" :: arguments -> run_deliver arguments
  | _ :: "pin" :: arguments -> run_pin arguments
  | _ :: "unpin" :: arguments -> run_unpin arguments
  | _ :: "compact" :: arguments -> run_compact arguments
  | _ :: "watch" :: arguments -> run_watch arguments
  | _ -> usage ()
