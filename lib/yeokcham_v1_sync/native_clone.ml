module Core = Yeokcham_v1_model.Core
module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust
module Raw = Yeokcham_store
module Store = Yeokcham_v1_store
module Local = Store.Local
module Transport = Yeokcham_v1_transport
module Intent = Transport.Core_clone
module Package = Yeokcham_v1_package
module Service = Yeokcham_v1_local_service
module Plan = Yeokcham_v1_integration
module Snapshot = Yeokcham_snapshot
module Fs = Snapshot.Filesystem
module Http = Yeokcham_v1_transport_http
module Config = Yeokcham_v1_transport_config
module Credential = Yeokcham_v1_transport_credential
module Recovery = Yeokcham_v1_recovery
module History = Yeokcham_v1_undo

[@@@warning "-42"]

type source = { url : string; repository : Core.Repository_id.t }

type error =
  | Invalid of string
  | Blocked of string
  | Choice of string
  | Exchange_error of Native_sync.error
  | Store_error of Store.error
  | Integration_error of Service.Integrate.error

let error_to_string = function
  | Invalid s | Blocked s | Choice s -> s
  | Exchange_error e -> Native_sync.error_to_string e
  | Store_error e -> Store.error_to_string e
  | Integration_error e -> Service.Integrate.error_to_string e

let ( let* ) = Result.bind
let invalid r = Result.map_error (fun s -> Invalid s) r
let store r = Result.map_error (fun e -> Store_error e) r

let transport r =
  Result.map_error (fun e -> Invalid (Transport.error_to_string e)) r

let raw r = Result.map_error (fun e -> Invalid (Raw.error_to_string e)) r

let package r =
  Result.map_error (fun e -> Exchange_error (Native_sync.Package_error e)) r

let exchange r = Result.map_error (fun e -> Exchange_error e) r
let integrate r = Result.map_error (fun e -> Integration_error e) r
let model r = Result.map_error (fun e -> Invalid (Core.error_to_string e)) r

let source text =
  match List.rev (String.split_on_char '/' text) with
  | repository :: "repositories" :: "v1" :: reversed ->
      let url = String.concat "/" (List.rev reversed) in
      let* repository = Core.Repository_id.of_hex repository |> model in
      let* _ =
        Credential.native_scope ~url
          ~repository:(Core.Repository_id.to_hex repository)
        |> Result.map_error (fun e -> Invalid (Credential.error_to_string e))
      in
      Ok { url; repository }
  | _ ->
      Error
        (Invalid "clone URL must be https://RELAY/v1/repositories/REPOSITORY_ID")

let default_directory source =
  "yeokcham-" ^ String.sub (Core.Repository_id.to_hex source.repository) 0 12

let check_new_destination path =
  try
    let path =
      if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
      else path
    in
    let existing =
      try Some (Unix.lstat path)
      with Unix.Unix_error (Unix.ENOENT, _, _) -> None
    in
    match existing with
    | Some stat when stat.Unix.st_kind <> Unix.S_DIR ->
        Error
          (Choice
             "clone destination must be a new or empty directory, without a \
              symlink")
    | Some _ when Array.length (Sys.readdir path) <> 0 ->
        Error
          (Choice
             "clone destination is not empty; use clone --resume DIRECTORY \
              only for its existing clone")
    | Some _ -> Ok (Unix.realpath path)
    | None ->
        Ok
          (Filename.concat
             (Unix.realpath (Filename.dirname path))
             (Filename.basename path))
  with
  | Unix.Unix_error (e, _, _) ->
      Error (Invalid ("clone destination: " ^ Unix.error_message e))
  | Sys_error s -> Error (Invalid s)

type outcome = {
  root : string;
  request : string;
  repository : Core.Repository_id.t;
  branch : Core.Branch_id.t;
  accepted : Core.Record_id.t;
  snapshot : Core.Object_id.t;
  records : int;
  branches : int;
  preview : bool;
  resumed : bool;
  cursor : Core.History_id.t option;
  operation : Core.Operation_id.t option;
  uncaptured : bool option;
}

type boundary =
  | Verified
  | Before_metadata_attach
  | After_metadata_attach
  | Before_plan_bind
  | After_plan_bind
  | Application of Service.Integrate.boundary
  | Before_complete
  | After_complete

let rec remove_owned path =
  try
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
      Array.iter
        (fun name -> remove_owned (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  with Unix.Unix_error _ | Sys_error _ -> ()

let with_temporary ?parent ?(metadata_may_move = false) action =
  try
    let path = Filename.temp_file ?temp_dir:parent "yeokcham-clone-" ".tmp" in
    Unix.unlink path;
    Unix.mkdir path 0o700;
    Fun.protect
      ~finally:(fun () ->
        if
          metadata_may_move
          && not (Sys.file_exists (Filename.concat path ".yeokcham"))
        then try Unix.rmdir path with Unix.Unix_error _ -> ()
        else remove_owned path)
      (fun () -> action path)
  with Unix.Unix_error (e, operation, _) ->
    Error (Invalid ("clone " ^ operation ^ ": " ^ Unix.error_message e))

let root_certificate authority =
  Trust.certificates (Trust.authority_membership authority)
  |> List.find_opt (fun c -> Trust.certificate_issuer c = None)
  |> Option.to_result
       ~none:(Blocked "verified authority has no repository root certificate")

module Ids = Map.Make (struct
  type t = Core.Record_id.t

  let compare = Core.Record_id.compare
end)

module Objects = Set.Make (struct
  type t = Raw.Stored_object_id.t

  let compare = Raw.Stored_object_id.compare
end)

type dataset = {
  authority : Trust.authority;
  records_map : (Core.Record_id.t * Raw.Stored_object_id.t) list;
  pool : Core.pool;
  objects : Objects.t;
  couriers : (Transport.publication * string) list;
}

let download source token verify_phrase stage =
  let* raw_store = Raw.init ~root:stage |> raw in
  let* client =
    Http.create ~url:source.url ~token
    |> Result.map_error (fun e -> Exchange_error (Native_sync.Http_error e))
  in
  let project = Core.Repository_id.to_hex source.repository in
  let* ids = Native_sync.Fetch.inventory client project |> exchange in
  if ids = [] then
    Error
      (Choice
         "relay has no shared native version; publish an accepted version first")
  else
    let* couriers =
      Native_sync.Fetch.publications ~known:[] client project ids |> exchange
    in
    let* couriers =
      Native_sync.Fetch.order_feed ~known:[] couriers |> exchange
    in
    let check_authority authority =
      match root_certificate authority with
      | Error e -> Error (Native_sync.Authority_error (error_to_string e))
      | Ok certificate ->
          if
            Recovery.verification_phrase certificate = String.trim verify_phrase
          then Ok ()
          else
            Error
              (Native_sync.Authority_error
                 "repository verification phrase does not match the signed root")
    in
    let* authority, records_map, objects, saved, _ =
      List.fold_left
        (fun result courier ->
          let* known, records, objects, saved, catalogue = result in
          let id = Transport.publication_manifest courier in
          let* manifest =
            Http.get
              ~max_bytes:(8 * 1024 * 1024)
              client ~project ~kind:Http.Manifest ~id
            |> Result.map_error (fun e ->
                Exchange_error (Native_sync.Http_error e))
          in
          if Transport.sha256 manifest <> id then
            Error (Invalid "clone manifest does not match its courier")
          else
            let* catalogue =
              Transport.Core_inbox.receive catalogue ~remote:"origin"
                ~endpoint:(Transport.sha256 source.url)
                ~cursor:None ~manifest ~publication:courier
              |> transport
            in
            let* reusable =
              match known with
              | None -> Ok []
              | Some authority ->
                  Package.Core.public_object_ids ~source:raw_store ~authority
                    ~records:(Ids.bindings records)
                  |> package
            in
            Native_sync.Fetch.with_core ~root:stage ~client
              ~repository:source.repository ~source:raw_store
              ~known_authority:known ~reusable ~check_authority ~manifest
              (fun ~package:_ prepared ->
                let* records =
                  List.fold_left
                    (fun result (id, stored) ->
                      let* records = result in
                      match Ids.find_opt id records with
                      | Some old
                        when not (Raw.Stored_object_id.equal old stored) ->
                          Error
                            (Native_sync.Invalid
                               "clone record identity collision")
                      | None | Some _ -> Ok (Ids.add id stored records))
                    (Ok records)
                    (Package.Core.prepared_records prepared)
                in
                let objects = ref objects in
                let* () =
                  Package.iter_artifact_objects
                    (Package.Core.prepared_artifact prepared) ~f:(fun id _ ->
                      objects := Objects.add id !objects;
                      Ok ())
                  |> Result.map_error (fun e -> Native_sync.Package_error e)
                in
                if
                  Ids.cardinal records > 100000
                  || Objects.cardinal !objects > 1000000
                then
                  Error
                    (Native_sync.Invalid
                       "clone exceeds its bounded record/object inventory; \
                        coverage is incomplete")
                else
                  Ok
                    ( Some (Package.Core.prepared_authority prepared),
                      records,
                      !objects,
                      (courier, manifest) :: saved,
                      catalogue ))
            |> exchange)
        (Ok (None, Ids.empty, Objects.empty, [], Transport.empty_local_state))
        couriers
    in
    let* authority =
      authority
      |> Option.to_result ~none:(Invalid "clone has no verified authority")
    in
    let* () =
      List.fold_left
        (fun result (courier, _) ->
          let* () = result in
          Transport.verify_publication ~authority courier |> transport)
        (Ok ()) saved
    in
    let records_map = Ids.bindings records_map in
    let* pool =
      Package.Core.verify_public_records ~source:raw_store ~authority
        ~records:records_map
      |> package
    in
    Ok
      ( raw_store,
        { authority; records_map; pool; objects; couriers = List.rev saved } )

let[@warning "-4"] choose dataset name =
  let rows =
    Core.branch_states dataset.pool
    |> List.filter (fun row -> List.mem name row.Core.display_names)
  in
  match rows with
  | [ row ] -> (
      match (row.Core.accepted_heads, row.Core.event_heads) with
      | [ accepted ], [ _ ] -> (
          match Core.find dataset.pool accepted with
          | Some { Core.payload = Core.Accepted_version version; _ } ->
              Ok (row, accepted, version.Core.result_snapshot)
          | _ -> Error (Invalid "clone selected version is unavailable"))
      | _ ->
          Error
            (Choice
               "selected branch has incomparable heads; an existing member \
                must reconcile them before clone"))
  | [] ->
      Error
        (Choice
           (Printf.sprintf "no unique shared branch named %S is available" name))
  | _ ->
      Error
        (Choice
           (Printf.sprintf "shared branch name %S identifies multiple branches"
              name))

let member authority capability =
  let* device =
    Trust.device_of_public_key (Trust.signing_public_key capability)
    |> Result.map_error (fun e -> Blocked (Trust.error_to_string e))
  in
  let* certificate =
    Trust.certificates (Trust.authority_membership authority)
    |> List.find_opt (fun c ->
        Trust.device_equal device (Trust.certificate_subject c))
    |> Option.to_result
         ~none:
           (Blocked
              "local device is not enrolled; relay access does not enroll a \
               member")
  in
  match Trust.authority_heads authority with
  | [ epoch ] when Trust.authority_device_active authority ~epoch device ->
      Ok (device, Trust.certificate_id certificate)
  | [ _ ] -> Error (Blocked "local enrolled device is revoked")
  | _ -> Error (Choice "clone requires a reconciled current authority head")

let context loaded =
  let* local =
    loaded.Store.local
    |> Option.to_result ~none:(Invalid "clone lacks local branch state")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result ~none:(Invalid "clone lacks collaboration")
  in
  let* intent =
    Intent.find (Store.transport collaboration)
    |> Option.to_result ~none:(Invalid "workspace has no clone intent")
  in
  Ok (local, collaboration, intent)

let with_writer root action =
  try
    let fd =
      Unix.openfile
        (root ^ "/.yeokcham/local-worktree.lock")
        [ Unix.O_RDWR; Unix.O_CLOEXEC ]
        0
    in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.lockf fd Unix.F_TLOCK 0;
        action ())
  with Unix.Unix_error (e, _, _) ->
    Error (Invalid ("clone writer unavailable: " ^ Unix.error_message e))

let publish_transport ~observe ~before ~after root change =
  with_writer root (fun () ->
      let* repository = Store.open_repository ~root |> store in
      let* loaded = Store.load repository |> store in
      let* local, collaboration, _ = context loaded in
      let* state = change loaded (Store.transport collaboration) in
      let* authority =
        Store.authority collaboration
        |> Option.to_result ~none:(Invalid "clone authority is unavailable")
      in
      let* collaboration =
        Store.collaboration_with_authority_transport ~transport:state ~authority
          ~revisions:(Store.signed_revisions collaboration)
          ~local_certificate:(Store.local_certificate collaboration)
          ~authorizations:(Store.authorizations collaboration)
          ~adoptions:(Store.adoptions collaboration)
        |> store
      in
      Store.For_test.save_collaborative
        ~before_publish:(fun () -> observe before)
        ~after_publish:(fun () -> observe after)
        ~local ~history:loaded.Store.history repository
        ~expected:loaded.Store.head ~project:loaded.Store.project ~collaboration
      |> store
      |> Result.map (fun _ -> ()))

let[@warning "-4"] report ~root ~preview ~resumed loaded =
  let* local, _, intent = context loaded in
  let* request = Intent.id intent |> transport in
  let* snapshot =
    match Core.find (Local.pool local) (Intent.accepted intent) with
    | Some { Core.payload = Core.Accepted_version version; _ } ->
        Ok version.Core.result_snapshot
    | _ -> Error (Invalid "clone's recorded accepted version is unavailable")
  in
  let* cursor =
    History.identity loaded.Store.history (History.current loaded.Store.history)
    |> invalid
  in
  let operation =
    Option.bind (Intent.plan intent) (fun plan ->
        Local.find_operation local ~plan)
    |> Option.map (fun operation -> operation.Local.Operation.token)
  in
  let uncaptured =
    match Service.inspect_local_status ~root with
    | Ok status -> (
        match status.Service.capture_observation with
        | Ok observation -> Some (observation.Service.differences <> [])
        | Error _ -> None)
    | Error _ -> None
  in
  Ok
    {
      root;
      request;
      repository = Intent.repository intent;
      branch = Intent.branch intent;
      accepted = Intent.accepted intent;
      snapshot;
      records = List.length (Local.record_objects local);
      branches = List.length (Local.branches local);
      preview;
      resumed;
      cursor = Some cursor;
      operation;
      uncaptured;
    }

let resume_ready ~observe ~root =
  let* repository = Store.open_repository ~root |> store in
  let* loaded = Store.load repository |> store in
  let* local, collaboration, intent = context loaded in
  if Service.Clone_state.recovered loaded intent then
    Error
      (Choice
         "clone application was explicitly recovered; retain this workspace \
          and inspect status rather than restarting the closed operation")
  else if Intent.complete intent then
    let* () =
      match Intent.plan intent with
      | None -> Ok ()
      | Some plan ->
          Plan.forget ~store:(Store.underlying_store repository) plan
          |> Result.map_error (fun e ->
              Integration_error (Service.Integrate.Plan_error e))
    in
    report ~root ~preview:false ~resumed:true loaded
  else
    let* authority =
      Store.authority collaboration
      |> Option.to_result ~none:(Invalid "clone authority is unavailable")
    in
    let* root_certificate = root_certificate authority in
    let* root_id =
      Core.Digest.of_hex (Trust.certificate_id root_certificate) |> model
    in
    if not (Core.Digest.equal root_id (Intent.root intent)) then
      Error (Blocked "clone authority root changed")
    else
      let* plan =
        match Intent.plan intent with
        | Some plan when Option.is_some (Local.find_operation local ~plan) ->
            Ok plan
        | _ ->
            let* request = Intent.id intent |> transport in
            let* request = Core.Digest.of_hex request |> model in
            let* plan =
              Service.Integrate.prepare_clone ~root ~request |> integrate
            in
            let id = Plan.id plan in
            let* () =
              publish_transport ~observe ~before:Before_plan_bind
                ~after:After_plan_bind root (fun _ state ->
                  Intent.bind_plan state ~plan:id |> transport)
            in
            Ok id
      in
      let* _ =
        Service.Integrate.For_test.apply ~root ~plan ~signing_capability:None
          ~observe:(fun boundary -> observe (Application boundary))
        |> integrate
      in
      let* () =
        publish_transport ~observe ~before:Before_complete ~after:After_complete
          root (fun loaded state ->
            let* local, _, current = context loaded in
            if
              not
                (Core.Record_id.equal (Local.selected local).Local.basis
                   (Intent.accepted current))
            then
              Error
                (Invalid
                   "clone application did not select the recorded accepted \
                    version")
            else Intent.finish state |> transport)
      in
      let* loaded = Store.load repository |> store in
      let* () =
        Plan.forget ~store:(Store.underlying_store repository) plan
        |> Result.map_error (fun e ->
            Integration_error (Service.Integrate.Plan_error e))
      in
      report ~root ~preview:false ~resumed:true loaded

let attach ~observe ~stage ~destination =
  try
    let input = Fs.open_at None stage true in
    Fun.protect
      ~finally:(fun () -> Unix.close input)
      (fun () ->
        let output = Fs.open_at None destination true in
        Fun.protect
          ~finally:(fun () -> Unix.close output)
          (fun () ->
            if Fs.names output <> [] then
              Error
                (Choice "clone destination changed before metadata publication")
            else (
              observe Before_metadata_attach;
              Fs.rename_at input ".yeokcham" output ".yeokcham" false;
              Unix.fsync output;
              Unix.fsync input;
              observe After_metadata_attach;
              Unix.rmdir stage;
              Ok ())))
  with Unix.Unix_error (e, operation, _) ->
    Error
      (Invalid ("clone metadata " ^ operation ^ ": " ^ Unix.error_message e))

let ensure_attached root =
  if Sys.file_exists (root ^ "/.yeokcham") then Ok ()
  else
    Error
      (Choice
         "clone has no published workspace metadata; rerun the original clone \
          URL DIRECTORY command")

let resume_with ~observe ~root =
  let* () = ensure_attached root in
  resume_ready ~observe ~root

let run_with ~observe ~source ~destination ~branch ~token ~signing_capability
    ~verify_phrase ~expected_request ~preview =
  let* destination = check_new_destination destination in
  with_temporary (fun fetch_root ->
      let* raw_source, dataset =
        download source token verify_phrase fetch_root
      in
      let* selected, accepted, snapshot = choose dataset branch in
      let* device, certificate = member dataset.authority signing_capability in
      let* root_certificate = root_certificate dataset.authority in
      let* root =
        Core.Digest.of_hex (Trust.certificate_id root_certificate) |> model
      in
      let* intent =
        Intent.create ~url:source.url ~repository:source.repository ~root
          ~device:(Trust.device_id device) ~branch:selected.Core.branch_id
          ~accepted ~events:selected.Core.event_heads
        |> transport
      in
      let* request = Intent.id intent |> transport in
      let* () =
        if
          Option.exists
            (fun expected -> Core.Digest.to_hex expected <> request)
            expected_request
        then
          Error
            (Choice "clone source selection changed; inspect a fresh preview")
        else Ok ()
      in
      let target =
        Snapshot.Snapshot.of_stored_object_id
          (Option.get
             (Raw.Stored_object_id.of_raw_bytes
                (Core.Object_id.to_raw snapshot)))
      in
      let* () =
        Service.Safe_apply.check_target ~store:raw_source ~target
        |> Result.map_error (fun e ->
            Invalid (Service.Safe_apply.error_to_string e))
      in
      observe Verified;
      if preview then
        Ok
          {
            root = destination;
            request;
            repository = source.repository;
            branch = selected.Core.branch_id;
            accepted;
            snapshot;
            records = List.length dataset.records_map;
            branches = List.length (Core.branch_states dataset.pool);
            preview = true;
            resumed = false;
            cursor = None;
            operation = None;
            uncaptured = None;
          }
      else
        let* () =
          Credential.save_for_repository ~url:source.url
            ~repository:(Core.Repository_id.to_hex source.repository)
            ~token
          |> Result.map_error (fun e -> Blocked (Credential.error_to_string e))
        in
        let* _ = check_new_destination destination in
        let* () =
          try
            if not (Sys.file_exists destination) then (
              Unix.mkdir destination 0o700;
              let parent =
                Fs.open_at None (Filename.dirname destination) true
              in
              Fun.protect
                ~finally:(fun () -> Unix.close parent)
                (fun () -> Unix.fsync parent));
            Ok ()
          with Unix.Unix_error (e, _, _) ->
            Error (Invalid ("clone destination: " ^ Unix.error_message e))
        in
        with_temporary ~parent:(Filename.dirname destination)
          ~metadata_may_move:true (fun ready_root ->
            let endpoint = Transport.sha256 source.url in
            let* state =
              List.fold_left
                (fun result (publication, manifest) ->
                  let* state = result in
                  Transport.Core_inbox.receive state ~remote:"origin" ~endpoint
                    ~cursor:None ~manifest ~publication
                  |> transport)
                (Ok Transport.empty_local_state) dataset.couriers
            in
            let* state = Intent.initialize state intent |> transport in
            let* _ =
              Store.init_local_collaborative_with ~root:ready_root
                ~bootstrap:(fun raw_destination ->
                  let result =
                    let* () =
                      Objects.fold
                        (fun id result ->
                          let* () = result in
                          let* envelope = Raw.get raw_source id |> raw in
                          let* _ = Raw.put raw_destination envelope |> raw in
                          Ok ())
                        dataset.objects (Ok ())
                    in
                    let* local =
                      Local.initialize_received ~store:raw_destination
                        ~authority:dataset.authority
                        ~records:dataset.records_map
                        ~selected_branch:selected.Core.branch_id ~cursor:0L
                      |> Result.map_error (fun e ->
                          Blocked (Local.receive_error_to_string e))
                    in
                    let* initial_snapshot =
                      Model.Snapshot_id.of_string
                        (Core.Object_id.to_hex (Local.empty_snapshot local))
                      |> Result.map_error Model.error_to_string
                      |> invalid
                    in
                    let* username =
                      Model.Username.of_string
                        ("member-"
                        ^ String.sub
                            (Model.Device_id.to_string (Trust.device_id device))
                            0 12)
                      |> Result.map_error Model.error_to_string
                      |> invalid
                    in
                    let* draft =
                      Model.Draft_id.of_string "work"
                      |> Result.map_error Model.error_to_string
                      |> invalid
                    in
                    let project =
                      Model.init ~creator:(Trust.device_id device) ~username
                        ~initial_snapshot ~initial_draft:draft
                        ~title:"Private work"
                    in
                    let* collaboration =
                      Store.collaboration_with_authority_transport
                        ~transport:state ~authority:dataset.authority
                        ~revisions:[] ~local_certificate:certificate
                        ~authorizations:[] ~adoptions:[]
                      |> store
                    in
                    Ok (project, collaboration, local)
                  in
                  Result.map_error error_to_string result)
              |> store
            in
            let* () =
              Config.add ~root:ready_root ~name:"origin" ~url:source.url
              |> Result.map_error (fun e -> Invalid (Config.error_to_string e))
            in
            let* () = attach ~observe ~stage:ready_root ~destination in
            let* outcome = resume_with ~observe ~root:destination in
            Ok { outcome with resumed = false }))

let run = run_with ~observe:(fun _ -> ())
let resume = resume_with ~observe:(fun _ -> ())

module For_test = struct
  let run = run_with
  let resume = resume_with
end
