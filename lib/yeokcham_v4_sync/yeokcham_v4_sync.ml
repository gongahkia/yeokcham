module Package = Yeokcham_v4_package
module Service = Yeokcham_v4_local_service
module Store = Yeokcham_store
module Transport = Yeokcham_v4_transport
module Transport_config = Yeokcham_v4_transport_config
module Transport_credential = Yeokcham_v4_transport_credential
module Transport_http = Yeokcham_v4_transport_http
module Trust = Yeokcham_v4_trust

type upload = Uploaded of int | Pending of string

type report = {
  discovered_publications : int;
  received_revisions : int;
  deferred_publications : int;
  created_decisions : int;
  upload : upload;
}

type error = Sync_error of string

let error_to_string (Sync_error detail) = detail
let ( let* ) = Result.bind
let sync_error value = Sync_error value
let detail value = Result.Error (sync_error value)

let relay_project identity =
  Trust.Repository_id.to_string identity.Service.repository

let fetch_publication_ids client ~project ~cursor =
  let rec loop cursor seen collected last =
    let* ids, next =
      Transport_http.list_publications client ~project ~cursor ~limit:128
      |> Result.map_error (fun error ->
          sync_error (Transport_http.error_to_string error))
    in
    let last = match List.rev ids with [] -> last | id :: _ -> Some id in
    match next with
    | None -> Ok (collected @ ids, last)
    | Some next ->
        if List.mem next seen || ids = [] then
          detail "relay publication pagination did not make progress"
        else loop (Some next) (next :: seen) (collected @ ids) last
  in
  loop cursor (Option.to_list cursor) [] cursor

let fetch_publication client ~project id =
  let* bytes =
    Transport_http.get client ~project ~kind:Transport_http.Publication ~id
    |> Result.map_error (fun error ->
        sync_error (Transport_http.error_to_string error))
  in
  let* publication =
    Transport.decode_publication bytes
    |> Result.map_error (fun error ->
        sync_error (Transport.error_to_string error))
  in
  if String.equal id (Transport.publication_id publication) then Ok publication
  else detail "relay publication route ID does not match its canonical bytes"

let fetch_artifact_for_manifest client ~project manifest_id =
  let* manifest =
    Transport_http.get client ~project ~kind:Transport_http.Manifest
      ~id:manifest_id
    |> Result.map_error (fun error ->
        sync_error (Transport_http.error_to_string error))
  in
  let* object_ids =
    Package.manifest_object_ids manifest
    |> Result.map_error (fun error ->
        sync_error (Package.error_to_string error))
  in
  let rec objects reversed = function
    | [] -> Ok (List.rev reversed)
    | id :: rest ->
        let id_text = Store.Stored_object_id.to_hex id in
        let* bytes =
          Transport_http.get client ~project ~kind:Transport_http.Object
            ~id:id_text
          |> Result.map_error (fun error ->
              sync_error (Transport_http.error_to_string error))
        in
        objects ((id, bytes) :: reversed) rest
  in
  let* objects = objects [] object_ids in
  Package.artifact_of_bytes ~manifest ~objects
  |> Result.map_error (fun error -> sync_error (Package.error_to_string error))

let fetch_artifact client ~project publication =
  fetch_artifact_for_manifest client ~project
    (Transport.publication_manifest publication)

let sort_feed publications =
  let compare_publication left right =
    String.compare
      (Transport.publication_id left)
      (Transport.publication_id right)
  in
  let rec loop ordered pending =
    match pending with
    | [] -> ordered
    | _ ->
        let pending_ids = List.map Transport.publication_id pending in
        let ready, waiting =
          List.partition
            (fun publication ->
              Transport.publication_parents publication
              |> List.for_all (fun parent -> not (List.mem parent pending_ids)))
            pending
        in
        let ready = List.sort compare_publication ready in
        if ready = [] then ordered @ List.sort compare_publication waiting
        else loop (ordered @ ready) waiting
  in
  loop [] publications

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
    detail
      (Printf.sprintf "transport staging %s %s: %s" operation root
         (Unix.error_message error))

let receive_transport ~root ~remote ~cursor publications artifacts =
  with_transport_staging ~root (fun staging ->
      let rec materialize reversed = function
        | [] -> Ok (List.rev reversed)
        | (publication, artifact) :: rest ->
            let destination =
              Filename.concat staging (Transport.publication_id publication)
            in
            let* () =
              Package.materialize_artifact ~destination artifact
              |> Result.map_error (fun error ->
                  sync_error (Package.error_to_string error))
            in
            materialize
              ({ Service.publication; package = destination } :: reversed)
              rest
      in
      let* arrivals = materialize [] (List.combine publications artifacts) in
      Service.receive_transport_batch ~root ~remote ~cursor arrivals
      |> Result.map_error (fun error ->
          sync_error (Service.error_to_string error)))

let upload_outbound client ~project ~root ~remote identity
    ~load_signing_capability =
  let device = Trust.device_id identity.Service.device in
  let* signing_capability =
    load_signing_capability device |> Result.map_error sync_error
  in
  let* outbound =
    Service.prepare_transport_outbound ~root ~remote ~signing_capability
    |> Result.map_error (fun error ->
        sync_error (Service.error_to_string error))
  in
  match outbound with
  | None -> Ok 0
  | Some outbound ->
      let rec objects count = function
        | [] -> Ok count
        | (id, bytes) :: rest ->
            let id = Store.Stored_object_id.to_hex id in
            let* () =
              Transport_http.put client ~project ~kind:Transport_http.Object ~id
                ~bytes
              |> Result.map_error (fun error ->
                  sync_error (Transport_http.error_to_string error))
            in
            objects (count + 1) rest
      in
      let artifact = outbound.Service.outbound_artifact in
      let* uploaded = objects 0 (Package.artifact_objects artifact) in
      let manifest = Package.artifact_manifest artifact in
      let manifest_id = Transport.sha256 manifest in
      let* () =
        Transport_http.put client ~project ~kind:Transport_http.Manifest
          ~id:manifest_id ~bytes:manifest
        |> Result.map_error (fun error ->
            sync_error (Transport_http.error_to_string error))
      in
      let publication = outbound.Service.outbound_publication in
      let publication_bytes = Transport.encode_publication publication in
      let* () =
        Transport_http.put client ~project ~kind:Transport_http.Publication
          ~id:(Transport.publication_id publication)
          ~bytes:publication_bytes
        |> Result.map_error (fun error ->
            sync_error (Transport_http.error_to_string error))
      in
      let* () =
        Service.record_transport_outbound ~root ~remote ~publication
          ~revisions:outbound.Service.outbound_revisions
        |> Result.map_error (fun error ->
            sync_error (Service.error_to_string error))
      in
      Ok (uploaded + 2)

let run ~root ~remote ~load_signing_capability =
  let* remote_config =
    Transport_config.find ~root ~name:remote
    |> Result.map_error (fun error ->
        sync_error (Transport_config.error_to_string error))
  in
  let* token =
    Transport_credential.load ~remote
    |> Result.map_error (fun error ->
        sync_error (Transport_credential.error_to_string error))
  in
  let* client =
    Transport_http.create ~url:remote_config.Transport_config.url ~token
    |> Result.map_error (fun error ->
        sync_error (Transport_http.error_to_string error))
  in
  let* identity =
    Service.identity ~root
    |> Result.map_error (fun error ->
        sync_error (Service.error_to_string error))
  in
  let project = relay_project identity in
  let* cursor =
    Service.transport_cursor ~root ~remote
    |> Result.map_error (fun error ->
        sync_error (Service.error_to_string error))
  in
  let* publication_ids, next_cursor =
    fetch_publication_ids client ~project ~cursor
  in
  let* publications =
    let rec fetch reversed = function
      | [] -> Ok (List.rev reversed |> sort_feed)
      | id :: rest ->
          let* publication = fetch_publication client ~project id in
          fetch (publication :: reversed) rest
    in
    fetch [] publication_ids
  in
  let* artifacts =
    let rec fetch reversed = function
      | [] -> Ok (List.rev reversed)
      | publication :: rest ->
          let* artifact = fetch_artifact client ~project publication in
          fetch (artifact :: reversed) rest
    in
    fetch [] publications
  in
  let* received =
    receive_transport ~root ~remote ~cursor:next_cursor publications artifacts
  in
  let upload =
    match
      upload_outbound client ~project ~root ~remote identity
        ~load_signing_capability
    with
    | Ok count -> Uploaded count
    | Error error -> Pending (error_to_string error)
  in
  Ok
    {
      discovered_publications = received.Service.discovered_publications;
      received_revisions = received.Service.received_revisions;
      deferred_publications = received.Service.deferred_publications;
      created_decisions = received.Service.created_decisions;
      upload;
    }
