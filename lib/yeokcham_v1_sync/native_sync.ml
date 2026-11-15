module Core = Yeokcham_v1_model.Core
module Package = Yeokcham_v1_package
module Service = Yeokcham_v1_local_service
module Store = Yeokcham_v1_store
module Raw = Yeokcham_store
module Envelope = Yeokcham_envelope
module Snapshot = Yeokcham_snapshot
module Pages = Yeokcham_v1_pages
module Transport = Yeokcham_v1_transport
module Config = Yeokcham_v1_transport_config
module Credential = Yeokcham_v1_transport_credential
module Http = Yeokcham_v1_transport_http
module Trust = Yeokcham_v1_trust
module Outbound = Service.Core_outbound
module Outbox = Transport.Core_outbox

[@@@warning "-42"]

type upload =
  | No_outgoing
  | Acknowledged of {
      publication : string;
      manifest : string;
      objects_offered : int;
      reused : bool;
    }
  | Pending of string

type report = {
  remote_publications : int;
  received_publications : int;
  received_records : int;
  received_branches : int;
  legacy_received_revisions : int;
  local_shared_records : int;
  selected_branch : Core.Branch_id.t;
  working_basis : Core.Record_id.t;
  cursor : Core.History_id.t;
  upload : upload;
}

type error =
  | Http_error of Http.error
  | Package_error of Package.error
  | Receipt_error of Service.Core_receive.error
  | Outbound_error of Outbound.error
  | Service_error of Service.error
  | Store_error of Store.error
  | Raw_error of Raw.error
  | Transport_error of Transport.error
  | Invalid of string

let error_to_string = function
  | Http_error e -> Http.error_to_string e
  | Package_error e -> Package.error_to_string e
  | Receipt_error e -> Service.Core_receive.error_to_string e
  | Outbound_error e -> Outbound.error_to_string e
  | Service_error e -> Service.error_to_string e
  | Store_error e -> Store.error_to_string e
  | Raw_error e -> Raw.error_to_string e
  | Transport_error e -> Transport.error_to_string e
  | Invalid s -> s

let ( let* ) = Result.bind
let http r = Result.map_error (fun e -> Http_error e) r
let package r = Result.map_error (fun e -> Package_error e) r
let store r = Result.map_error (fun e -> Store_error e) r
let raw r = Result.map_error (fun e -> Raw_error e) r
let transport r = Result.map_error (fun e -> Transport_error e) r
let service r = Result.map_error (fun e -> Service_error e) r
let invalid r = Result.map_error (fun s -> Invalid s) r

let snapshot r =
  Result.map_error (fun e -> Invalid (Snapshot.error_to_string e)) r

let pages r = Result.map_error (fun e -> Invalid (Pages.error_to_string e)) r

type boundary =
  | Object_offered of string
  | Manifest_sent of string
  | Courier_sent of string
  | Acknowledgement_recorded of string

let each action values =
  List.fold_left
    (fun result value ->
      let* () = result in
      action value)
    (Ok ()) values

let context loaded =
  let* local =
    loaded.Store.local
    |> Option.to_result
         ~none:(Invalid "native exchange requires authenticated local branches")
  in
  let* collaboration =
    loaded.Store.collaboration
    |> Option.to_result
         ~none:(Invalid "native exchange requires verified collaboration")
  in
  let* authority =
    Store.authority collaboration
    |> Option.to_result
         ~none:(Invalid "native exchange requires verified authority")
  in
  Ok (local, collaboration, authority)

let inventory client project =
  let rec scan cursor collected count =
    let* ids, next =
      Http.list_publications client ~project ~cursor ~limit:128 |> http
    in
    let sorted = List.sort_uniq String.compare ids in
    if
      List.length ids > 128
      || ids <> sorted
      || Option.exists
           (fun cursor -> List.exists (fun id -> id <= cursor) ids)
           cursor
    then Error (Invalid "relay inventory is not a bounded, increasing page")
    else if count + List.length ids > 100000 then
      Error
        (Invalid
           "relay inventory exceeds 100000 couriers; coverage is incomplete")
    else
      let collected = List.rev_append ids collected in
      match next with
      | None -> Ok (List.rev collected)
      | Some next ->
          if ids = [] || List.hd (List.rev ids) <> next then
            Error
              (Invalid
                 "relay inventory cursor did not advance to its last entry")
          else scan (Some next) collected (count + List.length ids)
  in
  (* relay cursors order hashes, not arrivals; every foreground run rescans. *)
  scan None [] 0

let fetch_publication client project id =
  let* bytes =
    Http.get
      ~max_bytes:(8 * 1024 * 1024)
      client ~project ~kind:Http.Publication ~id
    |> http
  in
  let* publication = Transport.decode_publication bytes |> transport in
  if Transport.publication_id publication = id then Ok publication
  else
    Error (Invalid "relay courier route does not match its canonical identity")

let order_feed ~known publications =
  let* () = Transport.validate_feed ~known publications |> transport in
  let rec order reversed pending =
    match pending with
    | [] -> Ok (List.rev reversed)
    | _ ->
        let ids = List.map Transport.publication_id pending in
        let ready, remaining =
          List.partition
            (fun p ->
              List.for_all
                (fun parent -> not (List.mem parent ids))
                (Transport.publication_parents p))
            pending
        in
        if ready = [] then
          Error (Invalid "relay courier feed cannot make causal progress")
        else order (List.rev_append ready reversed) remaining
  in
  order [] publications

let rec remove_owned path =
  try
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
      Array.iter
        (fun name -> remove_owned (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  with Unix.Unix_error _ | Sys_error _ -> ()

let with_package root action =
  try
    let directory =
      Filename.temp_file
        ~temp_dir:(Filename.concat root ".yeokcham")
        "core-receive-" ".tmp"
    in
    Unix.unlink directory;
    Unix.mkdir directory 0o700;
    Unix.mkdir (Filename.concat directory "objects") 0o700;
    Fun.protect
      ~finally:(fun () -> remove_owned directory)
      (fun () -> action directory)
  with Unix.Unix_error (e, operation, path) ->
    Error
      (Invalid
         (Printf.sprintf "native exchange staging %s %s: %s" operation path
            (Unix.error_message e)))

let write path bytes =
  Raw.publish_file_create_only ~path ~bytes |> raw |> Result.map (fun _ -> ())

module Id_map = Map.Make (struct
  type t = Raw.Stored_object_id.t

  let compare = Raw.Stored_object_id.compare
end)

let[@warning "-4"] fetch_core client project source local authority directory
    manifest_bytes =
  let* scope =
    Core.Repository_id.of_hex project
    |> Result.map_error Core.error_to_string
    |> invalid
  in
  let* manifest =
    Package.Core.decode_manifest ~repository:scope manifest_bytes |> package
  in
  let* reusable =
    Package.Core.public_object_ids ~source ~authority
      ~records:(Store.Local.record_objects local)
    |> package
  in
  let reusable =
    List.fold_left (fun map id -> Id_map.add id () map) Id_map.empty reusable
  in
  let downloaded = Hashtbl.create 256 in
  let ensure ~limit ?exact id =
    let* () =
      if Hashtbl.length downloaded > 1000000 then
        Error (Invalid "public object transfer exceeds its object bound")
      else Ok ()
    in
    if Hashtbl.mem downloaded id then Ok ()
    else
      let path = Raw.object_path source id in
      let* cached =
        try
          let _ = Unix.lstat path in
          Ok true
        with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
        | Unix.Unix_error (e, operation, _) ->
            Error
              (Invalid
                 (Printf.sprintf "native cache %s: %s" operation
                    (Unix.error_message e)))
      in
      let* envelope =
        if cached && (Option.is_none exact || Id_map.mem id reusable) then
          Raw.get ~max_bytes:limit source id |> raw
        else
          let id_text = Raw.Stored_object_id.to_hex id in
          let* bytes =
            match exact with
            | None ->
                Http.get ~max_bytes:limit client ~project ~kind:Http.Object
                  ~id:id_text
                |> http
            | Some raw_size -> (
                match
                  Http.V2.download_object client ~project ~object_id:id_text
                    ~raw_size
                with
                | Ok bytes -> Ok bytes
                | Error Http.V2.V2_unavailable ->
                    Http.get ~max_bytes:limit client ~project ~kind:Http.Object
                      ~id:id_text
                    |> http
                | Error e -> Error (Invalid (Http.V2.error_to_string e)))
          in
          let* envelope =
            Envelope.decode bytes
            |> Result.map_error Envelope.decode_error_to_string
            |> invalid
          in
          if not (Raw.Stored_object_id.equal id (Raw.id_of_envelope envelope))
          then Error (Invalid "downloaded public object identity mismatch")
          else
            let* _ = Raw.put source envelope |> raw in
            Ok envelope
      in
      let bytes = Envelope.encode envelope in
      if
        String.length bytes > limit
        || Option.exists (fun size -> String.length bytes <> size) exact
      then
        Error
          (Invalid
             "downloaded public object size differs from its bounded inventory")
      else
        let* () =
          write
            (Filename.concat
               (Filename.concat directory "objects")
               (Raw.Stored_object_id.to_hex id))
            bytes
        in
        Hashtbl.add downloaded id ();
        Ok ()
  in
  let metadata_seen = Hashtbl.create 32 in
  let rec metadata namespace depth id =
    if depth > 32 then Error (Invalid "public metadata exceeds its depth bound")
    else if Hashtbl.mem metadata_seen (namespace, id) then Ok ()
    else
      let* () = ensure ~limit:Pages.max_page_bytes id in
      let* envelope =
        Raw.get ~max_bytes:Pages.max_page_bytes source id |> raw
      in
      let* references =
        Pages.page_references ~namespace ~expected:id (Envelope.encode envelope)
        |> pages
      in
      Hashtbl.add metadata_seen (namespace, id) ();
      each (metadata namespace (depth + 1)) references
  in
  let* () =
    each
      (fun (namespace, id) -> metadata namespace 0 id)
      (Package.Core.metadata_roots manifest)
  in
  let* objects = Package.Core.inventory source manifest |> package in
  let sizes =
    List.fold_left
      (fun map (id, size) -> Id_map.add id size map)
      Id_map.empty objects
  in
  let ensure_public id =
    match Id_map.find_opt id sizes with
    | None ->
        Error
          (Invalid
             "public target references an object outside the declared inventory")
    | Some size -> ensure ~limit:size ~exact:size id
  in
  let* records = Package.Core.record_inventory source manifest |> package in
  let* () = each (fun (_, id) -> ensure_public id) records in
  let* selected =
    Package.Core.declared_selected_snapshots source manifest
      ~known_authority:(Some authority)
    |> package
  in
  let visited = Hashtbl.create 256 in
  let rec target depth id =
    if depth > 1024 then
      Error (Invalid "public target exceeds its traversal depth")
    else if Hashtbl.mem visited id then Ok ()
    else
      let* () = ensure_public id in
      Hashtbl.add visited id ();
      let* envelope = Raw.get source id |> raw in
      match Envelope.object_type envelope with
      | Envelope.Snapshot ->
          let* value =
            Snapshot.Snapshot.load_metadata source
              (Snapshot.Snapshot.of_stored_object_id id)
            |> snapshot
          in
          target (depth + 1)
            (Snapshot.Tree.stored_object_id (Snapshot.Snapshot.root value))
      | Envelope.Tree ->
          let* value =
            Snapshot.Tree.load_metadata source
              (Snapshot.Tree.of_stored_object_id id)
            |> snapshot
          in
          each
            (fun (_, entry) ->
              match entry with
              | Snapshot.Tree.Directory id ->
                  target (depth + 1) (Snapshot.Tree.stored_object_id id)
              | Snapshot.Tree.File { content; _ } ->
                  target (depth + 1) (Snapshot.Content.stored_object_id content))
            (Snapshot.Tree.entries value)
      | Envelope.File_manifest ->
          let* value =
            Snapshot.Manifest.load_metadata source
              (Snapshot.Manifest.of_stored_object_id id)
            |> snapshot
          in
          each
            (fun (id, _) ->
              target (depth + 1) (Snapshot.Chunk.stored_object_id id))
            (Snapshot.Manifest.chunks value)
      | Envelope.Content | Envelope.Chunk -> Ok ()
      | _ ->
          Error
            (Invalid "public target references an unsupported contents kind")
  in
  let* () =
    each
      (fun id ->
        target 0
          (Option.get
             (Raw.Stored_object_id.of_raw_bytes (Core.Object_id.to_raw id))))
      selected
  in
  let* () = each (fun (id, _) -> ensure_public id) objects in
  write (Filename.concat directory "manifest.cbor") manifest_bytes

let fetch_legacy client project directory manifest =
  let* objects = Package.manifest_object_ids manifest |> package in
  let* () = write (Filename.concat directory "manifest.cbor") manifest in
  each
    (fun object_id ->
      let id = Raw.Stored_object_id.to_hex object_id in
      let* bytes = Http.get client ~project ~kind:Http.Object ~id |> http in
      write (Filename.concat (Filename.concat directory "objects") id) bytes)
    objects

let[@warning "-4"] receive client project root remote endpoint repository
    publication =
  let id = Transport.publication_manifest publication in
  let* manifest =
    Http.get
      ~max_bytes:(8 * 1024 * 1024)
      client ~project ~kind:Http.Manifest ~id
    |> http
  in
  if Transport.sha256 manifest <> id then
    Error (Invalid "relay manifest route does not match its courier")
  else
    let* value =
      Yeokcham_encoding.decode manifest
      |> Result.map_error Yeokcham_encoding.decode_error_to_string
      |> invalid
    in
    with_package root (fun directory ->
        match value with
        | Yeokcham_encoding.Array (Yeokcham_encoding.Integer 2L :: _) ->
            let* loaded = Store.load repository |> store in
            let* local, _, authority = context loaded in
            let* () =
              fetch_core client project
                (Store.underlying_store repository)
                local authority directory manifest
            in
            let* received =
              Service.Core_receive.receive_publication ~root ~remote ~endpoint
                ~cursor:None ~publication ~package:directory
              |> Result.map_error (fun e -> Receipt_error e)
            in
            Ok
              ( received.Service.Core_receive.records_added,
                received.Service.Core_receive.branches_added,
                0 )
        | Yeokcham_encoding.Array (Yeokcham_encoding.Integer 1L :: _) ->
            let* () = fetch_legacy client project directory manifest in
            let* received =
              Service.receive_transport_batch ~root ~remote ~cursor:None
                [ { Service.publication; package = directory } ]
              |> service
            in
            Ok (0, 0, received.Service.received_revisions)
        | _ ->
            Error
              (Invalid
                 "relay manifest uses an unsupported mandatory package version"))

let[@warning "-4"] upload ~observe client project root remote endpoint identity
    ~load_signing_capability =
  let* prepared =
    match Outbound.prepare ~root ~remote ~endpoint ~signing_capability:None with
    | Ok prepared -> Ok prepared
    | Error Outbound.Signer_required ->
        let* capability =
          load_signing_capability (Trust.device_id identity.Service.device)
          |> invalid
        in
        Outbound.prepare ~root ~remote ~endpoint
          ~signing_capability:(Some capability)
        |> Result.map_error (fun e -> Outbound_error e)
    | Error e -> Error (Outbound_error e)
  in
  match prepared with
  | None -> Ok No_outgoing
  | Some outgoing ->
      Fun.protect
        ~finally:(fun () -> Package.dispose_artifact outgoing.Outbound.artifact)
        (fun () ->
          let offered = ref 0 in
          let failure = ref None in
          let result =
            Package.iter_artifact_objects outgoing.Outbound.artifact
              ~f:(fun object_id bytes ->
                let id = Raw.Stored_object_id.to_hex object_id in
                match Http.put client ~project ~kind:Http.Object ~id ~bytes with
                | Error e ->
                    failure := Some e;
                    Error
                      (Package.Invalid_package
                         "native outbound object transfer is pending")
                | Ok () ->
                    incr offered;
                    observe (Object_offered id);
                    Ok ())
          in
          let* () =
            match !failure with
            | Some e -> Error (Http_error e)
            | None -> result |> package
          in
          let manifest = Outbox.manifest outgoing.Outbound.batch in
          let manifest_id = Transport.sha256 manifest in
          let* () =
            Http.put client ~project ~kind:Http.Manifest ~id:manifest_id
              ~bytes:manifest
            |> http
          in
          observe (Manifest_sent manifest_id);
          let courier = Outbox.publication outgoing.Outbound.batch in
          let publication = Transport.publication_id courier in
          let* () =
            Http.put client ~project ~kind:Http.Publication ~id:publication
              ~bytes:(Transport.encode_publication courier)
            |> http
          in
          observe (Courier_sent publication);
          let* () =
            Outbound.acknowledge ~root ~remote ~endpoint ~publication
            |> Result.map_error (fun e -> Outbound_error e)
          in
          observe (Acknowledgement_recorded publication);
          Ok
            (Acknowledged
               {
                 publication;
                 manifest = manifest_id;
                 objects_offered = !offered;
                 reused = outgoing.Outbound.reused;
               }))

let run_with ~observe ~root ~remote ~load_signing_capability =
  let* config =
    Config.find ~root ~name:remote
    |> Result.map_error Config.error_to_string
    |> invalid
  in
  let endpoint = Transport.sha256 config.Config.url in
  let* repository = Store.open_repository ~root |> store in
  let* loaded = Store.load repository |> store in
  let* _, collaboration, _ = context loaded in
  let* _ =
    Outbox.find (Store.transport collaboration) ~remote ~endpoint |> transport
  in
  let* token =
    Credential.load_for_repository ~url:config.Config.url
      ~repository:(Core.Repository_id.to_hex (Core.pool_repository (Store.Local.pool (Option.get loaded.Store.local))))
    |> Result.map_error Credential.error_to_string
    |> invalid
  in
  let* client = Http.create ~url:config.Config.url ~token |> http in
  let* identity = Service.identity ~root |> service in
  let project = Trust.Repository_id.to_string identity.Service.repository in
  let* ids = inventory client project in
  let known =
    Option.fold ~none:[] ~some:Transport.remote_known_publications
      (Transport.find_remote (Store.transport collaboration) ~name:remote)
  in
  let known_ids = List.map Transport.reference_id known in
  let* publications =
    List.fold_left
      (fun result id ->
        let* publications = result in
        if List.mem id known_ids then Ok publications
        else
          let* publication = fetch_publication client project id in
          Ok (publication :: publications))
      (Ok []) ids
  in
  let* publications = order_feed ~known (List.rev publications) in
  let* records, branches, legacy =
    List.fold_left
      (fun result publication ->
        let* records, branches, legacy = result in
        let* more, added, old =
          receive client project root remote endpoint repository publication
        in
        Ok (records + more, branches + added, legacy + old))
      (Ok (0, 0, 0))
      publications
  in
  let upload =
    match
      upload ~observe client project root remote endpoint identity
        ~load_signing_capability
    with
    | Ok result -> result
    | Error e -> Pending (error_to_string e)
  in
  let* after = Store.load repository |> store in
  let* local, _, _ = context after in
  let* cursor =
    Yeokcham_v1_undo.identity after.Store.history
      (Yeokcham_v1_undo.current after.Store.history)
    |> invalid
  in
  let position = Store.Local.selected local in
  Ok
    {
      remote_publications = List.length ids;
      received_publications = List.length publications;
      received_records = records;
      received_branches = branches;
      legacy_received_revisions = legacy;
      local_shared_records = List.length (Store.Local.record_objects local);
      selected_branch = position.Store.Local.branch;
      working_basis = position.Store.Local.basis;
      cursor;
      upload;
    }

let run = run_with ~observe:(fun _ -> ())

module For_test = struct
  let run = run_with
end
