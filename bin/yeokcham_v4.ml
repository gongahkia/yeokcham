module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service
module Trust = Yeokcham_v4_trust
module Package = Yeokcham_v4_package
module Bootstrap = Yeokcham_v4_bootstrap
module Inspection = Yeokcham_v4_inspection
module Gc = Yeokcham_v4_gc
module Proposal = Yeokcham_v4_proposal
module Recovery = Yeokcham_v4_recovery
module Runtime = V4_runtime
module Sync = Yeokcham_v4_sync
module Transport = Yeokcham_v4_transport
module Transport_config = Yeokcham_v4_transport_config
module Transport_credential = Yeokcham_v4_transport_credential
module Transport_http = Yeokcham_v4_transport_http
module Relay_http = Yeokcham_v4_relay_http
module Relay_access = Yeokcham_v4_relay_access

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
    \  yeokcham log [--root PATH]\n\
    \  yeokcham graph [--root PATH] [--authority]\n\
    \  yeokcham daemon start [--root PATH]\n\
    \  yeokcham daemon status [--root PATH]\n\
    \  yeokcham daemon stop [--root PATH]\n\
    \  yeokcham daemon sync [--root PATH] REMOTE\n\
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
    \  yeokcham restore proofs [--root PATH]\n\
    \  yeokcham restore retain [--root PATH] --operation ID\n\
    \  yeokcham restore forget [--root PATH] --operation ID\n\
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
    \  yeokcham decision propose [--root PATH] --decision ID [--left REV \
     --right REV]\n\
    \  yeokcham decision materialize-proposal [--root PATH] --decision ID \
     --left REV --right REV --destination PATH\n\
    \  yeokcham decision materialize [--root PATH] --decision ID --destination \
     PATH\n\
    \  yeokcham package create [--root PATH] --destination PATH\n\
    \  yeokcham package adopt [--root PATH] --from PATH --revision ID \
     [--authority EPOCH]\n\
    \  yeokcham receive [--root PATH] --from PATH [--review]\n\
    \  yeokcham bootstrap publish [--root PATH] REMOTE\n\
    \  yeokcham bootstrap [--root PATH] --remote NAME --url HTTPS_URL \
     --repository ID --basis ID --username NAME --draft ID --title TITLE \
     --device ID --verify-phrase \"TWELVE WORDS\"\n\
    \  receipt rule: receive, sync, and bootstrap never scan or materialize\n\
    \     the working tree; restore is explicit\n\
    \  yeokcham remote add [--root PATH] NAME URL\n\
    \  yeokcham remote remove [--root PATH] NAME\n\
    \  yeokcham remote login [--root PATH] NAME\n\
    \  yeokcham sync [--root PATH] NAME\n\
    \  yeokcham relay serve --storage PATH --listen ADDRESS:PORT\n\
    \  yeokcham relay access issue --storage PATH --repository ID --scope \
     read,write [--expires-in SECONDS]\n\
    \  yeokcham relay access rotate --storage PATH --id ID [--expires-in \
     SECONDS]\n\
    \  yeokcham relay access revoke --storage PATH --id ID\n\
    \  yeokcham relay access list --storage PATH [--repository ID]\n\
    \  yeokcham deliver [--root PATH] --id ID --draft ID --title TITLE\n\
    \  yeokcham pin [--root PATH] --checkpoint ID\n\
    \  yeokcham unpin [--root PATH] --checkpoint ID\n\
    \  yeokcham compact [--root PATH] [--keep N] [--dry-run] [--explain]\n\
    \  yeokcham storage roots [--root PATH]\n\
    \  yeokcham storage gc [--root PATH] [--dry-run] [--explain]\n\
    \  yeokcham storage gc --root PATH --apply\n\
    \  yeokcham storage gc status [--root PATH]\n\
    \  yeokcham storage gc resume|restore|purge [--root PATH] --id ID\n\
    \  yeokcham watch [--root PATH]"

let require_ok render = function
  | Ok value -> value
  | Error error -> fail (render error)

let default_root = Sys.getcwd ()
let ( let* ) = Result.bind

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
    V4_signer.load_native device_id |> require_ok V4_signer.error_to_string
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
  V4_signer.load ~root (Trust.device_id identity.Service.device)
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

let inspection_width () =
  match Option.bind (Sys.getenv_opt "COLUMNS") int_of_string_opt with
  | Some width when width >= 40 -> width
  | Some _ | None -> 80

let inspection_state root =
  let state =
    Service.inspection_state ~root |> require_ok Service.error_to_string
  in
  Inspection.state ~project:state.Service.inspection_project
    ~signed_revisions:state.Service.inspection_signed_revisions
    ~authority:state.Service.inspection_authority
    ~review_publications:state.Service.inspection_review_publications

let run_log arguments =
  let root = parse_root arguments in
  inspection_state root
  |> Inspection.render_log ~width:(inspection_width ())
  |> print_string

let parse_graph arguments =
  let rec loop root authority = function
    | [] -> (Option.value root ~default:default_root, authority)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) authority rest
    | "--authority" :: rest when not authority -> loop root true rest
    | _ -> usage ()
  in
  loop None false arguments

let run_graph arguments =
  let root, authority = parse_graph arguments in
  let state = inspection_state root in
  let width = inspection_width () in
  if authority then
    match Inspection.render_authority_graph ~width state with
    | Some output -> print_string output
    | None -> fail "authority graph requires signed authority state"
  else Inspection.render_work_graph ~width state |> print_string

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
    V4_signer.load ~root replacement_id |> require_ok V4_signer.error_to_string
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
      Printf.printf "restore-proof %s\n" restored.Service.restore_operation;
      Printf.printf "safety %s\n"
        (Model.Snapshot_id.to_string restored.Service.safety_checkpoint);
      Printf.printf "restored %s in-place%s\n"
        (Model.Snapshot_id.to_string restored.Service.restored_checkpoint)
        (if restored.Service.resumed then " (resumed)" else "")

let parse_restore_operation arguments =
  let rec loop root operation = function
    | [] -> (
        match operation with
        | Some operation -> (Option.value root ~default:default_root, operation)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) operation rest
    | "--operation" :: value :: rest when Option.is_none operation ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_restore_proofs arguments =
  Service.restore_proofs ~root:(parse_root arguments)
  |> require_ok Service.error_to_string
  |> List.iter (fun proof ->
      Printf.printf "restore-proof %s safety %s target %s\n"
        proof.Service.proof_operation
        (Model.Snapshot_id.to_string proof.Service.proof_safety)
        (Model.Snapshot_id.to_string proof.Service.proof_target))

let run_restore_retain arguments =
  let root, operation = parse_restore_operation arguments in
  let proof =
    Service.retain_restore_proof ~root ~operation
    |> require_ok Service.error_to_string
  in
  Printf.printf "restore-proof %s safety %s target %s\n"
    proof.Service.proof_operation
    (Model.Snapshot_id.to_string proof.Service.proof_safety)
    (Model.Snapshot_id.to_string proof.Service.proof_target)

let run_restore_forget arguments =
  let root, operation = parse_restore_operation arguments in
  Service.forget_restore_proof ~root ~operation
  |> require_ok Service.error_to_string;
  Printf.printf "restore-proof forgotten %s\n" operation

let run_storage_roots arguments =
  Service.storage_roots ~root:(parse_root arguments)
  |> require_ok Service.error_to_string
  |> List.iter (fun root ->
      Printf.printf "root %s %s\n"
        (Model.Snapshot_id.to_string root.Service.root_snapshot)
        (root.Service.root_reasons
        |> List.map Model.protection_reason_to_string
        |> String.concat ","))

let render_gc_plan plan explain =
  if explain then
    List.iter
      (fun object_ ->
        let object_id =
          Yeokcham_store.Stored_object_id.to_hex object_.Gc.object_id
        in
        match object_.Gc.disposition with
        | Gc.Retain reasons ->
            Printf.printf "retain %s type:%d bytes:%d %s\n" object_id
              (Yeokcham_envelope.object_type_code object_.Gc.object_type)
              object_.Gc.stored_bytes
              (reasons |> List.map Gc.root_reason_to_string |> String.concat ",")
        | Gc.Collect ->
            Printf.printf "collect %s type:%d bytes:%d\n" object_id
              (Yeokcham_envelope.object_type_code object_.Gc.object_type)
              object_.Gc.stored_bytes)
      plan.Gc.objects;
  let retained_objects =
    List.length
      (List.filter
         (fun object_ ->
           match object_.Gc.disposition with
           | Gc.Retain _ -> true
           | Gc.Collect -> false)
         plan.Gc.objects)
  in
  let collectible_objects = List.length plan.Gc.objects - retained_objects in
  Printf.printf "retain-objects %d\n" retained_objects;
  Printf.printf "retain-bytes %d\n" plan.Gc.retained_bytes;
  Printf.printf "collect-objects %d\n" collectible_objects;
  Printf.printf "collect-bytes %d\n" plan.Gc.collectible_bytes

let parse_storage_gc arguments =
  let rec loop root dry_run apply explain = function
    | [] ->
        if dry_run && apply then usage ()
        else (Option.value root ~default:default_root, apply, explain)
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) dry_run apply explain rest
    | "--dry-run" :: rest when not dry_run -> loop root true apply explain rest
    | "--apply" :: rest when not apply -> loop root dry_run true explain rest
    | "--explain" :: rest when not explain -> loop root dry_run apply true rest
    | _ -> usage ()
  in
  loop None false false false arguments

let parse_storage_gc_id arguments =
  let rec loop root id = function
    | [] -> (
        match id with
        | Some id -> (Option.value root ~default:default_root, id)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) id rest
    | "--id" :: value :: rest when Option.is_none id ->
        loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let render_gc_progress progress =
  let transaction = progress.Gc.progress_transaction in
  Printf.printf "gc-transaction %s\n" (Gc.transaction_id transaction);
  Printf.printf "staged-objects %d\n" (List.length progress.Gc.staged_objects);
  Printf.printf "active-objects %d\n" (List.length progress.Gc.active_objects);
  Printf.printf "purged-objects %d\n" (List.length progress.Gc.purged_objects);
  Printf.printf "purge-started %s\n"
    (if progress.Gc.purge_started then "yes" else "no")

let run_storage_gc = function
  | "status" :: arguments ->
      Gc.transactions ~root:(parse_root arguments)
      |> require_ok Gc.error_to_string
      |> List.iter render_gc_progress
  | "resume" :: arguments ->
      let root, id = parse_storage_gc_id arguments in
      Gc.resume ~root ~id |> require_ok Gc.error_to_string |> render_gc_progress
  | "restore" :: arguments ->
      let root, id = parse_storage_gc_id arguments in
      Gc.restore ~root ~id |> require_ok Gc.error_to_string;
      Printf.printf "gc-restored %s\n" id
  | "purge" :: arguments ->
      let root, id = parse_storage_gc_id arguments in
      let reclaimed = Gc.purge ~root ~id |> require_ok Gc.error_to_string in
      Printf.printf "gc-purged %s bytes:%d\n" id reclaimed
  | arguments ->
      let root, apply, explain = parse_storage_gc arguments in
      if apply then (
        if explain then usage ();
        Gc.apply ~root |> require_ok Gc.error_to_string |> render_gc_progress)
      else
        Gc.plan ~root |> require_ok Gc.error_to_string |> fun plan ->
        render_gc_plan plan explain

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

let parse_decision_propose arguments =
  let rec loop root decision left right = function
    | [] -> (
        match (decision, left, right) with
        | Some decision, None, None ->
            (Option.value root ~default:default_root, decision, None)
        | Some decision, Some left, Some right ->
            ( Option.value root ~default:default_root,
              decision,
              Some (left, right) )
        | None, _, _ | Some _, None, Some _ | Some _, Some _, None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision left right rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) left right rest
    | "--left" :: value :: rest when Option.is_none left ->
        loop root decision (Some value) right rest
    | "--right" :: value :: rest when Option.is_none right ->
        loop root decision left (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let parse_decision_materialize_proposal arguments =
  let rec loop root decision left right destination = function
    | [] -> (
        match (decision, left, right, destination) with
        | Some decision, Some left, Some right, Some destination ->
            ( Option.value root ~default:default_root,
              decision,
              left,
              right,
              destination )
        | None, _, _, _ | _, None, _, _ | _, _, None, _ | _, _, _, None ->
            usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) decision left right destination rest
    | "--decision" :: value :: rest when Option.is_none decision ->
        loop root (Some value) left right destination rest
    | "--left" :: value :: rest when Option.is_none left ->
        loop root decision (Some value) right destination rest
    | "--right" :: value :: rest when Option.is_none right ->
        loop root decision left (Some value) destination rest
    | "--destination" :: value :: rest when Option.is_none destination ->
        loop root decision left right (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None arguments

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

let render_proposal_entry = function
  | None -> "missing"
  | Some Proposal.Directory -> "directory"
  | Some (Proposal.File { mode; content }) ->
      "file " ^ snapshot_mode_name mode ^ " " ^ content

let render_decision_proposal (proposal : Proposal.t) =
  let provenance = proposal.Proposal.provenance in
  Printf.printf "proposal decision %s\n"
    (Model.Decision_id.to_string provenance.Proposal.decision);
  Printf.printf "baseline %s\n"
    (Model.Snapshot_id.to_string provenance.Proposal.current_baseline);
  Printf.printf "left revision %s base %s snapshot %s\n"
    (Model.Revision_id.to_string provenance.Proposal.left_revision)
    (Model.Snapshot_id.to_string provenance.Proposal.left_base)
    (Model.Snapshot_id.to_string provenance.Proposal.left_result);
  Printf.printf "right revision %s base %s snapshot %s\n"
    (Model.Revision_id.to_string provenance.Proposal.right_revision)
    (Model.Snapshot_id.to_string provenance.Proposal.right_base)
    (Model.Snapshot_id.to_string provenance.Proposal.right_result);
  Printf.printf "confidence %s\n"
    (match proposal.Proposal.confidence with
    | Proposal.Exact_source -> "exact-source"
    | Proposal.No_confidence -> "none");
  (match proposal.Proposal.readiness with
  | Proposal.Ready -> Printf.printf "status ready-exact\n"
  | Proposal.Refused refusals ->
      Printf.printf "status refused\n";
      List.iter
        (fun refusal ->
          Printf.printf "refusal %s\n" (Proposal.refusal_to_string refusal))
        refusals);
  List.iter
    (fun path ->
      let outcome =
        match path.Proposal.outcome with
        | Proposal.Select { source; _ } ->
            "select-" ^ Proposal.source_to_string source
        | Proposal.Conflict conflict ->
            "conflict-" ^ Proposal.conflict_to_string conflict
        | Proposal.Unassessed_without_common_base ->
            "unassessed-without-common-base"
      in
      Printf.printf "path %s outcome %s base %s left %s right %s\n"
        (Model.Path.to_string path.Proposal.path)
        outcome
        (render_proposal_entry path.Proposal.base)
        (render_proposal_entry path.Proposal.left)
        (render_proposal_entry path.Proposal.right))
    proposal.Proposal.paths

let run_decision_propose arguments =
  let root, decision, pair = parse_decision_propose arguments in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  match pair with
  | None ->
      let pairs =
        Service.proposal_pairs ~root ~decision
        |> require_ok Service.error_to_string
      in
      Printf.printf "decision %s\n" (Model.Decision_id.to_string decision);
      Printf.printf "proposal-pairs %d\n" (List.length pairs);
      List.iter
        (fun (left, right) ->
          Printf.printf "proposal-pair %s %s\n"
            (Model.Revision_id.to_string left)
            (Model.Revision_id.to_string right))
        pairs
  | Some (left, right) ->
      let left =
        parse_identifier "invalid revision identifier"
          Model.Revision_id.of_string left
      in
      let right =
        parse_identifier "invalid revision identifier"
          Model.Revision_id.of_string right
      in
      Service.propose_decision ~root ~decision ~left ~right
      |> require_ok Service.error_to_string
      |> render_decision_proposal

let run_decision_materialize_proposal arguments =
  let root, decision, left, right, destination =
    parse_decision_materialize_proposal arguments
  in
  let decision =
    parse_identifier "invalid decision identifier" Model.Decision_id.of_string
      decision
  in
  let left =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      left
  in
  let right =
    parse_identifier "invalid revision identifier" Model.Revision_id.of_string
      right
  in
  let materialized =
    Service.materialize_decision_proposal ~root ~decision ~left ~right
      ~destination
    |> require_ok Service.error_to_string
  in
  Printf.printf "proposal-materialized %s\n"
    materialized.Service.proposal_directory;
  print_endline
    "proposal remains unaccepted; inspect it, then resolve explicitly if you \
     choose it"

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

let parse_remote_add arguments =
  let rec loop root values = function
    | [] -> (
        match List.rev values with
        | [ name; url ] -> (Option.value root ~default:default_root, name, url)
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) values rest
    | value :: rest -> loop root (value :: values) rest
  in
  loop None [] arguments

let parse_remote_name arguments =
  let rec loop root name = function
    | [] -> (
        match name with
        | Some name -> (Option.value root ~default:default_root, name)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) name rest
    | value :: rest when Option.is_none name -> loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_remote_add arguments =
  let root, name, url = parse_remote_add arguments in
  Transport_config.add ~root ~name ~url
  |> require_ok Transport_config.error_to_string;
  Printf.printf "remote %s %s\n" name url

let run_remote_remove arguments =
  let root, name = parse_remote_name arguments in
  Transport_config.remove ~root ~name
  |> require_ok Transport_config.error_to_string;
  Printf.printf "remote removed %s\n" name

let read_bearer_token () =
  let attributes =
    try Unix.tcgetattr Unix.stdin
    with Unix.Unix_error _ ->
      fail "remote login requires an interactive terminal"
  in
  let hidden = { attributes with Unix.c_echo = false } in
  print_string "relay access secret: ";
  flush stdout;
  let token =
    Fun.protect
      ~finally:(fun () ->
        (try Unix.tcsetattr Unix.stdin Unix.TCSANOW attributes
         with Unix.Unix_error _ -> ());
        print_newline ())
      (fun () ->
        Unix.tcsetattr Unix.stdin Unix.TCSANOW hidden;
        try Ok (read_line ()) with End_of_file -> Error ())
  in
  match token with
  | Ok token -> token
  | Error () -> fail "no relay access secret was provided"

let run_remote_login arguments =
  let root, name = parse_remote_name arguments in
  let _ =
    Transport_config.find ~root ~name
    |> require_ok Transport_config.error_to_string
  in
  let token = read_bearer_token () in
  Transport_credential.save ~remote:name ~token
  |> require_ok Transport_credential.error_to_string;
  Printf.printf "credential saved for remote %s\n" name

let parse_relay_serve arguments =
  let rec loop storage listen = function
    | [] -> (
        match (storage, listen) with
        | Some storage, Some listen -> (storage, listen)
        | _ -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) listen rest
    | "--listen" :: value :: rest when Option.is_none listen ->
        loop storage (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_relay_serve arguments =
  let storage, listen = parse_relay_serve arguments in
  Relay_http.serve ~root:storage ~listen
  |> require_ok Relay_http.error_to_string

let relay_now () = Int64.of_float (Unix.gettimeofday ())

let parse_relay_repository value =
  Trust.Repository_id.of_string value
  |> require_ok (fun error -> "invalid relay repository ID: " ^ error)
  |> Trust.Repository_id.to_string

let parse_relay_access_scope value =
  let scopes =
    value |> String.split_on_char ','
    |> List.map (function
      | "read" -> Relay_access.Read
      | "write" -> Relay_access.Write
      | _ -> fail "relay access scope must contain only read and write")
  in
  if scopes = [] then fail "relay access scope must not be empty" else scopes

let parse_relay_access_lifetime = function
  | None -> Relay_access.default_lifetime_seconds
  | Some value -> (
      match Int64.of_string_opt value with
      | Some value
        when Int64.compare value 0L > 0
             && Int64.compare value Relay_access.max_lifetime_seconds <= 0 ->
          value
      | _ ->
          fail
            "relay access lifetime must be a positive number of seconds no \
             greater than one year")

let with_controlling_tty run =
  try
    let descriptor = Unix.openfile "/dev/tty" [ Unix.O_WRONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () -> run descriptor)
  with Unix.Unix_error _ ->
    fail
      "relay access issue and rotate require an interactive controlling \
       terminal"

let write_tty descriptor value =
  let rec loop offset =
    if offset <> String.length value then
      try
        let count =
          Unix.write_substring descriptor value offset
            (String.length value - offset)
        in
        if count = 0 then fail "could not display relay access secret"
        else loop (offset + count)
      with Unix.Unix_error _ -> fail "could not display relay access secret"
  in
  loop 0

let display_relay_access_secret descriptor grant =
  write_tty descriptor
    ("relay access secret (record now; shown once): "
   ^ grant.Relay_access.grant_secret ^ "\n")

let parse_relay_access_issue arguments =
  let rec loop storage repository scope expires_in = function
    | [] -> (
        match (storage, repository, scope) with
        | Some storage, Some repository, Some scope ->
            (storage, repository, scope, parse_relay_access_lifetime expires_in)
        | _ -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) repository scope expires_in rest
    | "--repository" :: value :: rest when Option.is_none repository ->
        loop storage (Some value) scope expires_in rest
    | "--scope" :: value :: rest when Option.is_none scope ->
        loop storage repository (Some value) expires_in rest
    | "--expires-in" :: value :: rest when Option.is_none expires_in ->
        loop storage repository scope (Some value) rest
    | _ -> usage ()
  in
  loop None None None None arguments

let run_relay_access_issue arguments =
  let storage, repository, scope, expires_in =
    parse_relay_access_issue arguments
  in
  let repository = parse_relay_repository repository in
  let scopes = parse_relay_access_scope scope in
  with_controlling_tty (fun tty ->
      let grant =
        Relay_access.update ~root:storage (fun registry ->
            Relay_access.issue ~now:(relay_now ()) ~repository ~scopes
              ~expires_in registry)
        |> require_ok Relay_access.error_to_string
      in
      Printf.printf "credential %s\n" grant.Relay_access.grant_credential_id;
      Printf.printf "expires-at %Ld\n" grant.Relay_access.grant_expires_at;
      display_relay_access_secret tty grant)

let parse_relay_access_rotate arguments =
  let rec loop storage credential_id expires_in = function
    | [] -> (
        match (storage, credential_id) with
        | Some storage, Some credential_id ->
            (storage, credential_id, parse_relay_access_lifetime expires_in)
        | _ -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) credential_id expires_in rest
    | "--id" :: value :: rest when Option.is_none credential_id ->
        loop storage (Some value) expires_in rest
    | "--expires-in" :: value :: rest when Option.is_none expires_in ->
        loop storage credential_id (Some value) rest
    | _ -> usage ()
  in
  loop None None None arguments

let run_relay_access_rotate arguments =
  let storage, credential_id, expires_in =
    parse_relay_access_rotate arguments
  in
  with_controlling_tty (fun tty ->
      let grant =
        Relay_access.update ~root:storage (fun registry ->
            Relay_access.rotate ~now:(relay_now ()) ~credential_id ~expires_in
              registry)
        |> require_ok Relay_access.error_to_string
      in
      Printf.printf "credential %s\n" grant.Relay_access.grant_credential_id;
      Printf.printf "expires-at %Ld\n" grant.Relay_access.grant_expires_at;
      display_relay_access_secret tty grant)

let parse_relay_access_revoke arguments =
  let rec loop storage credential_id = function
    | [] -> (
        match (storage, credential_id) with
        | Some storage, Some credential_id -> (storage, credential_id)
        | _ -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) credential_id rest
    | "--id" :: value :: rest when Option.is_none credential_id ->
        loop storage (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_relay_access_revoke arguments =
  let storage, credential_id = parse_relay_access_revoke arguments in
  Relay_access.update ~root:storage (fun registry ->
      Relay_access.revoke ~now:(relay_now ()) ~credential_id registry
      |> Result.map (fun registry -> (registry, ())))
  |> require_ok Relay_access.error_to_string;
  Printf.printf "credential revoked %s\n" credential_id

let parse_relay_access_list arguments =
  let rec loop storage repository = function
    | [] -> (
        match storage with
        | Some storage -> (storage, repository)
        | None -> usage ())
    | "--storage" :: value :: rest when Option.is_none storage ->
        loop (Some value) repository rest
    | "--repository" :: value :: rest when Option.is_none repository ->
        loop storage (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_relay_access_list arguments =
  let storage, repository = parse_relay_access_list arguments in
  let repository = Option.map parse_relay_repository repository in
  Relay_access.load ~root:storage
  |> require_ok Relay_access.error_to_string
  |> Relay_access.credentials
  |> List.filter (fun credential ->
      Option.fold ~none:true
        ~some:(String.equal (Relay_access.credential_repository credential))
        repository)
  |> List.iter (fun credential ->
      let status =
        match Relay_access.credential_status credential with
        | Relay_access.Active -> "active"
        | Relay_access.Revoked -> "revoked"
      in
      Printf.printf "credential %s\n" (Relay_access.credential_id credential);
      Printf.printf "repository %s\n"
        (Relay_access.credential_repository credential);
      Printf.printf "scope %s\n"
        (Relay_access.scopes_to_string
           (Relay_access.credential_scopes credential));
      Printf.printf "issued-at %Ld\n"
        (Relay_access.credential_issued_at credential);
      Printf.printf "expires-at %Ld\n"
        (Relay_access.credential_expires_at credential);
      Printf.printf "status %s\n" status)

let fetch_artifact_for_manifest client ~project manifest_id =
  let manifest =
    Transport_http.get client ~project ~kind:Transport_http.Manifest
      ~id:manifest_id
    |> require_ok Transport_http.error_to_string
  in
  let object_ids =
    Package.manifest_object_ids manifest |> require_ok Package.error_to_string
  in
  let objects =
    object_ids
    |> List.map (fun id ->
        let id_text = Yeokcham_store.Stored_object_id.to_hex id in
        let bytes =
          Transport_http.get client ~project ~kind:Transport_http.Object
            ~id:id_text
          |> require_ok Transport_http.error_to_string
        in
        (id, bytes))
  in
  Package.artifact_of_bytes ~manifest ~objects
  |> require_ok Package.error_to_string

let remove_staged_package destination =
  let objects = Filename.concat destination "objects" in
  (try
     Sys.readdir objects
     |> Array.iter (fun name ->
         try Unix.unlink (Filename.concat objects name)
         with Unix.Unix_error _ -> ());
     Unix.rmdir objects
   with Unix.Unix_error _ | Sys_error _ -> ());
  (try Unix.unlink (Filename.concat destination "manifest.cbor")
   with Unix.Unix_error _ -> ());
  try Unix.rmdir destination with Unix.Unix_error _ -> ()

let with_transport_staging ~root run =
  try
    let staging =
      Filename.temp_file ~temp_dir:root ".yeokcham-v4-transport-receive-" ".tmp"
    in
    Unix.unlink staging;
    Unix.mkdir staging 0o700;
    Fun.protect
      ~finally:(fun () ->
        try
          Sys.readdir staging
          |> Array.iter (fun name ->
              remove_staged_package (Filename.concat staging name));
          Unix.rmdir staging
        with Unix.Unix_error _ | Sys_error _ -> ())
      (fun () -> run staging)
  with Unix.Unix_error (error, operation, _) ->
    Error
      (Printf.sprintf "transport staging %s %s: %s" operation root
         (Unix.error_message error))

let run_bootstrap_publish arguments =
  let root, remote_name = parse_remote_name arguments in
  let remote =
    Transport_config.find ~root ~name:remote_name
    |> require_ok Transport_config.error_to_string
  in
  let token =
    Transport_credential.load ~remote:remote_name
    |> require_ok Transport_credential.error_to_string
  in
  let client =
    Transport_http.create ~url:remote.Transport_config.url ~token
    |> require_ok Transport_http.error_to_string
  in
  let identity = Service.identity ~root |> require_ok Service.error_to_string in
  let project = Trust.Repository_id.to_string identity.Service.repository in
  let signing_capability = local_signing_capability root in
  let outbound =
    Service.prepare_bootstrap_outbound ~root ~signing_capability
    |> require_ok Service.error_to_string
  in
  let rec upload_objects count = function
    | [] -> count
    | (id, bytes) :: rest ->
        let id = Yeokcham_store.Stored_object_id.to_hex id in
        Transport_http.put client ~project ~kind:Transport_http.Object ~id
          ~bytes
        |> require_ok Transport_http.error_to_string;
        upload_objects (count + 1) rest
  in
  let uploaded =
    upload_objects 0
      (Package.artifact_objects outbound.Service.bootstrap_artifact)
  in
  let manifest =
    Package.artifact_manifest outbound.Service.bootstrap_artifact
  in
  let manifest_id = Transport.sha256 manifest in
  Transport_http.put client ~project ~kind:Transport_http.Manifest
    ~id:manifest_id ~bytes:manifest
  |> require_ok Transport_http.error_to_string;
  let basis = Bootstrap.encode outbound.Service.bootstrap_basis in
  let basis_id = Bootstrap.id outbound.Service.bootstrap_basis in
  Transport_http.put client ~project ~kind:Transport_http.Bootstrap ~id:basis_id
    ~bytes:basis
  |> require_ok Transport_http.error_to_string;
  Printf.printf "bootstrap basis %s\n" basis_id;
  Printf.printf "uploaded artifacts %d\n" (uploaded + 2)

let parse_bootstrap arguments =
  let rec loop root remote url repository basis username draft title device
      phrase = function
    | [] -> (
        match
          ( remote,
            url,
            repository,
            basis,
            username,
            draft,
            title,
            device,
            phrase )
        with
        | ( Some remote,
            Some url,
            Some repository,
            Some basis,
            Some username,
            Some draft,
            Some title,
            Some device,
            Some phrase ) ->
            ( Option.value root ~default:default_root,
              remote,
              url,
              repository,
              basis,
              username,
              draft,
              title,
              device,
              phrase )
        | _ -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) remote url repository basis username draft title
          device phrase rest
    | "--remote" :: value :: rest when Option.is_none remote ->
        loop root (Some value) url repository basis username draft title device
          phrase rest
    | "--url" :: value :: rest when Option.is_none url ->
        loop root remote (Some value) repository basis username draft title
          device phrase rest
    | "--repository" :: value :: rest when Option.is_none repository ->
        loop root remote url (Some value) basis username draft title device
          phrase rest
    | "--basis" :: value :: rest when Option.is_none basis ->
        loop root remote url repository (Some value) username draft title device
          phrase rest
    | "--username" :: value :: rest when Option.is_none username ->
        loop root remote url repository basis (Some value) draft title device
          phrase rest
    | "--draft" :: value :: rest when Option.is_none draft ->
        loop root remote url repository basis username (Some value) title device
          phrase rest
    | "--title" :: value :: rest when Option.is_none title ->
        loop root remote url repository basis username draft (Some value) device
          phrase rest
    | "--device" :: value :: rest when Option.is_none device ->
        loop root remote url repository basis username draft title (Some value)
          phrase rest
    | "--verify-phrase" :: value :: rest when Option.is_none phrase ->
        loop root remote url repository basis username draft title device
          (Some value) rest
    | _ -> usage ()
  in
  loop None None None None None None None None None None arguments

let run_bootstrap arguments =
  let ( root,
        remote_name,
        url,
        repository,
        basis_id,
        username,
        draft,
        title,
        device,
        phrase ) =
    parse_bootstrap arguments
  in
  let repository =
    Trust.Repository_id.of_string repository
    |> require_ok (fun detail -> "invalid repository identifier: " ^ detail)
  in
  if not (Transport.valid_digest basis_id) then
    fail "invalid bootstrap basis identifier";
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
  let signing_capability =
    V4_signer.load_native device_id |> require_ok V4_signer.error_to_string
  in
  let local_device =
    Trust.signing_public_key signing_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  if not (Model.Device_id.equal device_id (Trust.device_id local_device)) then
    fail "local signing capability does not match --device";
  let token = read_bearer_token () in
  let client =
    Transport_http.create ~url ~token
    |> require_ok Transport_http.error_to_string
  in
  let project = Trust.Repository_id.to_string repository in
  let basis =
    Transport_http.get client ~project ~kind:Transport_http.Bootstrap
      ~id:basis_id
    |> require_ok Transport_http.error_to_string
  in
  if not (String.equal basis_id (Transport.sha256 basis)) then
    fail "bootstrap basis route ID does not match canonical bytes";
  let decoded_basis =
    Bootstrap.decode basis |> require_ok Bootstrap.error_to_string
  in
  if not (String.equal basis_id (Bootstrap.id decoded_basis)) then
    fail "bootstrap basis ID does not match canonical bytes";
  let artifact =
    fetch_artifact_for_manifest client ~project
      (Bootstrap.manifest decoded_basis)
  in
  let status =
    with_transport_staging ~root (fun staging ->
        let package = Filename.concat staging basis_id in
        let* () =
          Package.materialize_artifact ~destination:package artifact
          |> Result.map_error Package.error_to_string
        in
        let* verified =
          Bootstrap.verify ~repository ~package ~bytes:basis
          |> Result.map_error Bootstrap.error_to_string
        in
        let local_certificate =
          Trust.certificates
            (Trust.authority_membership (Bootstrap.authority verified))
          |> List.find_opt (fun certificate ->
              Model.Device_id.equal
                (Trust.device_id (Trust.certificate_subject certificate))
                device_id)
        in
        let* local_certificate =
          match local_certificate with
          | Some certificate -> Ok (Trust.certificate_id certificate)
          | None ->
              Error "device is not enrolled in the bootstrap authority closure"
        in
        Service.bootstrap_from_package ~root ~repository ~package ~basis
          ~verify_phrase:phrase ~username ~initial_draft ~title
          ~device:local_device ~local_certificate
        |> Result.map_error Service.error_to_string)
    |> require_ok Fun.id
  in
  Transport_config.add ~root ~name:remote_name ~url
  |> require_ok Transport_config.error_to_string;
  Transport_credential.save ~remote:remote_name ~token
  |> require_ok Transport_credential.error_to_string;
  render_status status;
  Printf.printf
    "bootstrap verified %s; no working-tree materialization occurred\n" basis_id

let run_sync arguments =
  let root, remote_name = parse_remote_name arguments in
  let report =
    Sync.run ~root ~remote:remote_name ~load_signing_capability:(fun device ->
        V4_signer.load ~root device
        |> Result.map_error V4_signer.error_to_string)
    |> require_ok Sync.error_to_string
  in
  Printf.printf "received publications %d\n" report.Sync.discovered_publications;
  Printf.printf "received revisions %d\n" report.Sync.received_revisions;
  Printf.printf "deferred publications %d\n" report.Sync.deferred_publications;
  Printf.printf "created decisions %d\n" report.Sync.created_decisions;
  match report.Sync.upload with
  | Sync.Uploaded uploaded -> Printf.printf "uploaded artifacts %d\n" uploaded
  | Sync.Pending detail ->
      Printf.printf "upload pending %s\n" detail;
      print_endline "receive completed; rerun sync to retry upload"

let run_watch arguments =
  let root = parse_root arguments in
  V4_watch.run ~root

let parse_daemon_sync arguments =
  let rec loop root remote = function
    | [] -> (
        match remote with
        | Some remote -> (Option.value root ~default:default_root, remote)
        | None -> usage ())
    | "--root" :: value :: rest when Option.is_none root ->
        loop (Some value) remote rest
    | value :: rest when Option.is_none remote -> loop root (Some value) rest
    | _ -> usage ()
  in
  loop None None arguments

let run_daemon = function
  | "start" :: arguments -> Runtime.start ~root:(parse_root arguments)
  | "status" :: arguments -> Runtime.status ~root:(parse_root arguments)
  | "stop" :: arguments -> Runtime.stop ~root:(parse_root arguments)
  | "sync" :: arguments ->
      let root, remote = parse_daemon_sync arguments in
      Runtime.sync ~root ~remote
  | "run" :: arguments -> Runtime.run ~root:(parse_root arguments)
  | _ -> usage ()

let () =
  match Array.to_list Sys.argv with
  | _ :: "init" :: arguments -> run_init arguments
  | _ :: "join" :: arguments -> run_join arguments
  | _ :: "save" :: arguments -> run_save arguments
  | _ :: "status" :: arguments -> run_status arguments
  | _ :: "log" :: arguments -> run_log arguments
  | _ :: "graph" :: arguments -> run_graph arguments
  | _ :: "daemon" :: arguments -> run_daemon arguments
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
  | _ :: "restore" :: "proofs" :: arguments -> run_restore_proofs arguments
  | _ :: "restore" :: "retain" :: arguments -> run_restore_retain arguments
  | _ :: "restore" :: "forget" :: arguments -> run_restore_forget arguments
  | _ :: "restore" :: arguments -> run_restore arguments
  | _ :: "draft" :: "new" :: arguments -> run_new_draft arguments
  | _ :: "share" :: arguments -> run_share arguments
  | _ :: "withdraw" :: arguments -> run_withdraw arguments
  | _ :: "resolve" :: arguments -> run_resolve arguments
  | _ :: "decision" :: "show" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "inspect" :: arguments -> run_decision_show arguments
  | _ :: "decision" :: "diff" :: arguments -> run_decision_diff arguments
  | _ :: "decision" :: "propose" :: arguments -> run_decision_propose arguments
  | _ :: "decision" :: "materialize-proposal" :: arguments ->
      run_decision_materialize_proposal arguments
  | _ :: "decision" :: "materialize" :: arguments ->
      run_decision_materialize arguments
  | _ :: "package" :: "create" :: arguments -> run_package_create arguments
  | _ :: "package" :: "adopt" :: arguments -> run_package_adopt arguments
  | _ :: "receive" :: arguments -> run_receive arguments
  | _ :: "bootstrap" :: "publish" :: arguments ->
      run_bootstrap_publish arguments
  | _ :: "bootstrap" :: arguments -> run_bootstrap arguments
  | _ :: "remote" :: "add" :: arguments -> run_remote_add arguments
  | _ :: "remote" :: "remove" :: arguments -> run_remote_remove arguments
  | _ :: "remote" :: "login" :: arguments -> run_remote_login arguments
  | _ :: "sync" :: arguments -> run_sync arguments
  | _ :: "relay" :: "access" :: "issue" :: arguments ->
      run_relay_access_issue arguments
  | _ :: "relay" :: "access" :: "rotate" :: arguments ->
      run_relay_access_rotate arguments
  | _ :: "relay" :: "access" :: "revoke" :: arguments ->
      run_relay_access_revoke arguments
  | _ :: "relay" :: "access" :: "list" :: arguments ->
      run_relay_access_list arguments
  | _ :: "relay" :: "serve" :: arguments -> run_relay_serve arguments
  | _ :: "deliver" :: arguments -> run_deliver arguments
  | _ :: "pin" :: arguments -> run_pin arguments
  | _ :: "unpin" :: arguments -> run_unpin arguments
  | _ :: "compact" :: arguments -> run_compact arguments
  | _ :: "storage" :: "gc" :: arguments -> run_storage_gc arguments
  | _ :: "storage" :: "roots" :: arguments -> run_storage_roots arguments
  | _ :: "watch" :: arguments -> run_watch arguments
  | _ -> usage ()
