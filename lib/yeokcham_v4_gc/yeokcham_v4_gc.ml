module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash
module Journal = Yeokcham_v4_restore_journal
module Model = Yeokcham_v4_model
module Proof = Yeokcham_v4_restore_proof
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module V4_store = Yeokcham_v4_store

type root_reason =
  | State_head
  | Checkpoint of {
      snapshot : Model.Snapshot_id.t;
      reasons : Model.protection_reason list;
    }
  | Unsupported_object_type of Envelope.object_type

type disposition = Retain of root_reason list | Collect

type planned_object = {
  object_id : Store.Stored_object_id.t;
  object_type : Envelope.object_type;
  stored_bytes : int;
  disposition : disposition;
}

type plan = {
  state_head : Store.Stored_object_id.t;
  objects : planned_object list;
  retained_bytes : int;
  collectible_bytes : int;
}

type transaction = {
  transaction_id : string;
  transaction_state_head : Store.Stored_object_id.t;
  transaction_objects : planned_object list;
}

type transaction_progress = {
  progress_transaction : transaction;
  staged_objects : Store.Stored_object_id.t list;
  active_objects : Store.Stored_object_id.t list;
  purged_objects : Store.Stored_object_id.t list;
  purge_started : bool;
}

type error =
  | Store_error of Store.error
  | V4_store_error of V4_store.error
  | Snapshot_error of Snapshot.error
  | Model_error of Model.error
  | Journal_error of Journal.error
  | Proof_error of Proof.error
  | Invalid_snapshot_id of string
  | Missing_reachable_object of Store.Stored_object_id.t
  | Duplicate_object of Store.Stored_object_id.t
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Noncanonical_bytes
  | No_collectible_objects
  | Transaction_not_found of string
  | Transaction_collision of string
  | Incomplete_transaction of string
  | Stale_transaction_object of Store.Stored_object_id.t
  | Transaction_object_missing of Store.Stored_object_id.t
  | Quarantine_collision of string
  | Io_error of { operation : string; path : string; message : string }

let schema_version = 1L
let max_transaction_bytes = 32 * 1024 * 1024
let ( let* ) = Result.bind

let root_reason_to_string = function
  | State_head -> "state-head"
  | Checkpoint { snapshot; reasons = [] } ->
      "checkpoint " ^ Model.Snapshot_id.to_string snapshot
  | Checkpoint { snapshot; reasons } ->
      "checkpoint "
      ^ Model.Snapshot_id.to_string snapshot
      ^ " ("
      ^ String.concat "," (List.map Model.protection_reason_to_string reasons)
      ^ ")"
  | Unsupported_object_type object_type ->
      Printf.sprintf "unsupported-object-type:%d"
        (Envelope.object_type_code object_type)

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | V4_store_error error -> V4_store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Model_error error -> Model.error_to_string error
  | Journal_error error -> Journal.error_to_string error
  | Proof_error error -> Proof.error_to_string error
  | Invalid_snapshot_id value -> "invalid V4 snapshot object identity: " ^ value
  | Missing_reachable_object id ->
      "V4 GC reachable object is missing: " ^ Store.Stored_object_id.to_hex id
  | Duplicate_object id ->
      "V4 GC object list contains a duplicate: "
      ^ Store.Stored_object_id.to_hex id
  | Invalid_schema detail -> "invalid V4 GC transaction: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported V4 GC transaction version: %Ld" version
  | Noncanonical_bytes -> "V4 GC transaction is not canonically encoded"
  | No_collectible_objects -> "V4 GC found no collectible objects"
  | Transaction_not_found id -> "V4 GC transaction not found: " ^ id
  | Transaction_collision path ->
      "V4 GC transaction path contains different bytes: " ^ path
  | Incomplete_transaction id ->
      "V4 GC transaction needs explicit resume, restore, or purge: " ^ id
  | Stale_transaction_object id ->
      "V4 GC transaction object is now reachable: "
      ^ Store.Stored_object_id.to_hex id
  | Transaction_object_missing id ->
      "V4 GC transaction object is absent from active and quarantine storage: "
      ^ Store.Stored_object_id.to_hex id
  | Quarantine_collision path ->
      "V4 GC quarantine path contains unexpected data: " ^ path
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message

let transaction_id transaction = transaction.transaction_id
let transaction_state_head transaction = transaction.transaction_state_head
let transaction_objects transaction = transaction.transaction_objects

let io_error operation path error =
  Io_error { operation; path; message = Unix.error_message error }

let hex_of_raw raw =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length raw * 2)
    (fun index ->
      let byte = Char.code raw.[index / 2] in
      if index mod 2 = 0 then alphabet.[byte lsr 4]
      else alphabet.[byte land 0x0f])

let valid_transaction_id value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

module Object_map = Map.Make (struct
  type t = Store.Stored_object_id.t

  let compare = Store.Stored_object_id.compare
end)

let sort_reasons reasons =
  List.sort_uniq
    (fun left right ->
      String.compare (root_reason_to_string left) (root_reason_to_string right))
    reasons

let add_reasons object_id reasons table =
  Object_map.update object_id
    (function
      | None -> Some (sort_reasons reasons)
      | Some existing -> Some (sort_reasons (existing @ reasons)))
    table

let is_collectible_type = function
  | Envelope.Content | Envelope.Tree | Envelope.Snapshot | Envelope.Chunk
  | Envelope.File_manifest | Envelope.V4_project_state ->
      true
  | Envelope.Scratch_event | Envelope.Checkpoint | Envelope.Capsule
  | Envelope.Capsule_revision | Envelope.Release | Envelope.Conflict
  | Envelope.Validation | Envelope.Resolution | Envelope.Repository_config
  | Envelope.Retention_change | Envelope.Scratch_generation_segment
  | Envelope.Scratch_generation | Envelope.Scratch_cleanup_manifest
  | Envelope.Workspace | Envelope.Workspace_revision
  | Envelope.Workspace_attempt | Envelope.Release_attestation
  | Envelope.Git_mapping | Envelope.Imported_transition | Envelope.Imported_tag
  | Envelope.Ref_event | Envelope.Device_identity | Envelope.Divergent_ref_set
  | Envelope.Git_archive | Envelope.Git_adoption | Envelope.Peer_publication
  | Envelope.Peer_integration | Envelope.Git_lineage_node | Envelope.Git_lineage
  | Envelope.Peer_identity | Envelope.Peer_contact | Envelope.Peer_advertisement
  | Envelope.Peer_sync_node | Envelope.Peer_sync_conflict ->
      false

let classify ~state_head ~objects ~reachable =
  let rec object_table table = function
    | [] -> Ok table
    | info :: rest ->
        if Object_map.mem info.Store.id table then
          Error (Duplicate_object info.Store.id)
        else object_table (Object_map.add info.Store.id info table) rest
  in
  let* object_table = object_table Object_map.empty objects in
  let reachable =
    List.fold_left
      (fun table (object_id, reasons) -> add_reasons object_id reasons table)
      Object_map.empty
      ((state_head, [ State_head ]) :: reachable)
  in
  let* () =
    Object_map.fold
      (fun object_id _ result ->
        let* () = result in
        if Object_map.mem object_id object_table then Ok ()
        else Error (Missing_reachable_object object_id))
      reachable (Ok ())
  in
  let objects =
    objects
    |> List.sort (fun left right ->
        Store.Stored_object_id.compare left.Store.id right.Store.id)
    |> List.map (fun info ->
        let disposition =
          match Object_map.find_opt info.Store.id reachable with
          | Some reasons -> Retain reasons
          | None when is_collectible_type info.Store.object_type -> Collect
          | None -> Retain [ Unsupported_object_type info.Store.object_type ]
        in
        {
          object_id = info.Store.id;
          object_type = info.Store.object_type;
          stored_bytes = info.Store.stored_bytes;
          disposition;
        })
  in
  let retained_bytes, collectible_bytes =
    List.fold_left
      (fun (retained, collectible) object_ ->
        match object_.disposition with
        | Retain _ -> (retained + object_.stored_bytes, collectible)
        | Collect -> (retained, collectible + object_.stored_bytes))
      (0, 0) objects
  in
  Ok { state_head; objects; retained_bytes; collectible_bytes }

let construction value =
  value
  |> Result.map_error (fun error ->
      Invalid_schema (Encoding.construction_error_to_string error))

let text value = Encoding.text value |> construction
let array value = Encoding.array value |> construction

let encode_transaction_payload transaction =
  let* state_head =
    text (Store.Stored_object_id.to_hex transaction.transaction_state_head)
  in
  let rec encode_objects reversed = function
    | [] -> array (List.rev reversed)
    | object_ :: rest ->
        let* id = text (Store.Stored_object_id.to_hex object_.object_id) in
        let object_type =
          Encoding.integer
            (Int64.of_int (Envelope.object_type_code object_.object_type))
        in
        let bytes = Encoding.integer (Int64.of_int object_.stored_bytes) in
        let* record = array [ id; object_type; bytes ] in
        encode_objects (record :: reversed) rest
  in
  let* objects = encode_objects [] transaction.transaction_objects in
  array [ Encoding.integer schema_version; state_head; objects ]

let encode_transaction transaction =
  encode_transaction_payload transaction |> Result.map Encoding.encode

let decoded_array name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let decoded_text name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be text"))

let decoded_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an integer"))

let decode_object = function
  | [ id; object_type; bytes ] ->
      let* id = decoded_text "object ID" id in
      let* object_id =
        Store.Stored_object_id.of_hex id
        |> Result.map_error (fun _ -> Invalid_schema "object ID is not SHA-256")
      in
      let* object_type = decoded_integer "object type" object_type in
      let* object_type =
        if
          Int64.compare object_type 0L < 0 || Int64.compare object_type 255L > 0
        then Error (Invalid_schema "object type is out of range")
        else
          match Envelope.object_type_of_code (Int64.to_int object_type) with
          | Some object_type -> Ok object_type
          | None -> Error (Invalid_schema "unknown object type")
      in
      let* stored_bytes = decoded_integer "stored bytes" bytes in
      if
        Int64.compare stored_bytes 0L < 0
        || Int64.compare stored_bytes (Int64.of_int max_int) > 0
      then Error (Invalid_schema "stored bytes are out of range")
      else
        Ok
          {
            object_id;
            object_type;
            stored_bytes = Int64.to_int stored_bytes;
            disposition = Collect;
          }
  | _ -> Error (Invalid_schema "transaction object must contain three fields")

let transaction_digest payload =
  Hash.Sha256.digest_string payload |> Hash.Sha256.to_raw_string |> hex_of_raw

let make_transaction plan =
  let transaction_objects =
    List.filter (fun object_ -> object_.disposition = Collect) plan.objects
  in
  if transaction_objects = [] then Error No_collectible_objects
  else
    let provisional =
      {
        transaction_id = String.make 64 '0';
        transaction_state_head = plan.state_head;
        transaction_objects;
      }
    in
    let* payload = encode_transaction provisional in
    Ok { provisional with transaction_id = transaction_digest payload }

let decode_transaction bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Invalid_schema (Encoding.decode_error_to_string error))
  in
  let* fields = decoded_array "transaction record" value in
  match fields with
  | [ version; state_head; objects ] ->
      let* version = decoded_integer "version" version in
      if not (Int64.equal version schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* state_head = decoded_text "state head" state_head in
        let* transaction_state_head =
          Store.Stored_object_id.of_hex state_head
          |> Result.map_error (fun _ ->
              Invalid_schema "state head is not SHA-256")
        in
        let* objects = decoded_array "objects" objects in
        let rec decode_objects reversed = function
          | [] -> Ok (List.rev reversed)
          | value :: rest ->
              let* fields = decoded_array "transaction object" value in
              let* object_ = decode_object fields in
              decode_objects (object_ :: reversed) rest
        in
        let* transaction_objects = decode_objects [] objects in
        if transaction_objects = [] then
          Error (Invalid_schema "objects must not be empty")
        else
          let ordered =
            List.sort
              (fun left right ->
                Store.Stored_object_id.compare left.object_id right.object_id)
              transaction_objects
          in
          if ordered <> transaction_objects then
            Error (Invalid_schema "objects must be strictly sorted")
          else
            let rec unique = function
              | left :: right :: _
                when Store.Stored_object_id.equal left.object_id right.object_id
                ->
                  Error (Invalid_schema "objects must not repeat an ID")
              | _ :: rest -> unique rest
              | [] -> Ok ()
            in
            let* () = unique transaction_objects in
            let provisional =
              {
                transaction_id = String.make 64 '0';
                transaction_state_head;
                transaction_objects;
              }
            in
            let* canonical = encode_transaction provisional in
            if not (String.equal canonical bytes) then Error Noncanonical_bytes
            else
              Ok
                {
                  provisional with
                  transaction_id = transaction_digest canonical;
                }
  | _ -> Error (Invalid_schema "record must contain three fields")

let snapshot_object_id snapshot =
  let value = Model.Snapshot_id.to_string snapshot in
  Store.Stored_object_id.of_hex value
  |> Result.map_error (fun _ -> Invalid_snapshot_id value)

let latest_journals journals =
  List.fold_left
    (fun latest journal ->
      match List.assoc_opt (Journal.operation_id journal) latest with
      | Some current
        when Int64.compare
               (Journal.generation current)
               (Journal.generation journal)
             >= 0 ->
          latest
      | Some _ ->
          (Journal.operation_id journal, journal)
          :: List.remove_assoc (Journal.operation_id journal) latest
      | None -> (Journal.operation_id journal, journal) :: latest)
    [] journals

let proof_matches_journal proof journal =
  String.equal (Proof.operation_id proof) (Journal.operation_id journal)
  && Model.Snapshot_id.equal (Proof.safety proof) (Journal.safety journal)
  && Model.Snapshot_id.equal (Proof.target proof) (Journal.target journal)

let retention_snapshots ~root project =
  let* journals =
    Journal.scan ~root |> Result.map_error (fun error -> Journal_error error)
  in
  let* proofs =
    Proof.scan ~root |> Result.map_error (fun error -> Proof_error error)
  in
  let latest = latest_journals journals |> List.map snd in
  let journal_snapshots =
    latest
    |> List.filter (fun journal ->
        Journal.phase journal <> Journal.Published
        || not
             (List.exists
                (fun proof -> proof_matches_journal proof journal)
                proofs))
    |> List.concat_map (fun journal ->
        [ Journal.safety journal; Journal.target journal ])
    |> List.sort_uniq Model.Snapshot_id.compare
  in
  let proof_snapshots = Proof.snapshots proofs in
  let retained snapshot =
    List.exists
      (fun checkpoint ->
        Model.Snapshot_id.equal checkpoint.Model.checkpoint_snapshot snapshot)
      (Model.checkpoints project)
  in
  let* () =
    List.fold_left
      (fun result snapshot ->
        let* () = result in
        if retained snapshot then Ok ()
        else
          Error
            (Invalid_schema "journal or proof names an unretained checkpoint"))
      (Ok ())
      (journal_snapshots @ proof_snapshots)
  in
  Ok (journal_snapshots, proof_snapshots)

let checkpoint_roots project ~journal_snapshots ~proof_snapshots =
  let* compacted =
    Model.compact project ~keep_recent:0 ~journal_snapshots ~proof_snapshots
    |> Result.map_error (fun error -> Model_error error)
  in
  let* named =
    List.fold_left
      (fun result keep ->
        let* table = result in
        let* object_id = snapshot_object_id keep.Model.snapshot in
        Ok (Object_map.add object_id keep.Model.reasons table))
      (Ok Object_map.empty) compacted.Model.kept
  in
  let rec roots reversed = function
    | [] -> Ok (List.rev reversed)
    | checkpoint :: rest ->
        let snapshot = checkpoint.Model.checkpoint_snapshot in
        let* object_id = snapshot_object_id snapshot in
        let reasons =
          Option.value (Object_map.find_opt object_id named) ~default:[]
        in
        roots
          ((object_id, [ Checkpoint { snapshot; reasons } ]) :: reversed)
          rest
  in
  roots [] (Model.checkpoints project)

let add_reachable object_id reasons reachable =
  add_reasons object_id reasons reachable

let traverse_content store reasons content_id reachable =
  let object_id = Snapshot.Content.stored_object_id content_id in
  let reachable = add_reachable object_id reasons reachable in
  let* object_ =
    Store.get store object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  match Envelope.object_type object_ with
  | Envelope.Content ->
      let* _ =
        Snapshot.Content.load store content_id
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      Ok reachable
  | Envelope.File_manifest ->
      let manifest_id = Snapshot.Manifest.of_stored_object_id object_id in
      let* manifest =
        Snapshot.Manifest.load store manifest_id
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let rec chunks reachable = function
        | [] -> Ok reachable
        | (chunk, _) :: rest ->
            let chunk_id = Snapshot.Chunk.stored_object_id chunk in
            let reachable = add_reachable chunk_id reasons reachable in
            let* _ =
              Snapshot.Chunk.load store chunk
              |> Result.map_error (fun error -> Snapshot_error error)
            in
            chunks reachable rest
      in
      chunks reachable (Snapshot.Manifest.chunks manifest)
  | ( Envelope.Tree | Envelope.Snapshot | Envelope.Scratch_event
    | Envelope.Checkpoint | Envelope.Capsule | Envelope.Capsule_revision
    | Envelope.Release | Envelope.Conflict | Envelope.Validation
    | Envelope.Resolution | Envelope.Repository_config | Envelope.Chunk
    | Envelope.Retention_change | Envelope.Scratch_generation_segment
    | Envelope.Scratch_generation | Envelope.Scratch_cleanup_manifest
    | Envelope.Workspace | Envelope.Workspace_revision
    | Envelope.Workspace_attempt | Envelope.Release_attestation
    | Envelope.Git_mapping | Envelope.Imported_transition
    | Envelope.Imported_tag | Envelope.Ref_event | Envelope.Device_identity
    | Envelope.Divergent_ref_set | Envelope.Git_archive | Envelope.Git_adoption
    | Envelope.Peer_publication | Envelope.Peer_integration
    | Envelope.Git_lineage_node | Envelope.Git_lineage | Envelope.Peer_identity
    | Envelope.Peer_contact | Envelope.Peer_advertisement
    | Envelope.Peer_sync_node | Envelope.Peer_sync_conflict
    | Envelope.V4_project_state ) as object_type ->
      Error
        (Invalid_schema
           (Printf.sprintf "tree file refers to object type %d"
              (Envelope.object_type_code object_type)))

let rec traverse_tree store reasons tree_id reachable =
  let object_id = Snapshot.Tree.stored_object_id tree_id in
  let reachable = add_reachable object_id reasons reachable in
  let* tree =
    Snapshot.Tree.load store tree_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let rec entries reachable = function
    | [] -> Ok reachable
    | (_, Snapshot.Tree.File { content; _ }) :: rest ->
        let* reachable = traverse_content store reasons content reachable in
        entries reachable rest
    | (_, Snapshot.Tree.Directory child) :: rest ->
        let* reachable = traverse_tree store reasons child reachable in
        entries reachable rest
  in
  entries reachable (Snapshot.Tree.entries tree)

let traverse_snapshot store reasons snapshot_id reachable =
  let object_id = Snapshot.Snapshot.stored_object_id snapshot_id in
  let reachable = add_reachable object_id reasons reachable in
  let* snapshot =
    Snapshot.Snapshot.load store snapshot_id
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  traverse_tree store reasons (Snapshot.Snapshot.root snapshot) reachable

let plan_from_loaded ~root store loaded =
  let* journal_snapshots, proof_snapshots =
    retention_snapshots ~root loaded.V4_store.project
  in
  let* roots =
    checkpoint_roots loaded.V4_store.project ~journal_snapshots ~proof_snapshots
  in
  let* reachable =
    List.fold_left
      (fun result (object_id, reasons) ->
        let* reachable = result in
        let snapshot_id = Snapshot.Snapshot.of_stored_object_id object_id in
        traverse_snapshot store reasons snapshot_id reachable)
      (Ok Object_map.empty) roots
  in
  let* objects =
    Store.list_objects store
    |> Result.map_error (fun error -> Store_error error)
  in
  classify ~state_head:loaded.V4_store.object_id ~objects
    ~reachable:(Object_map.bindings reachable)

let with_consistent_repository ~root action =
  let* repository =
    V4_store.open_repository ~root
    |> Result.map_error (fun error -> V4_store_error error)
  in
  let store = V4_store.underlying_store repository in
  Store.with_lock store ~name:"restore-retention"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      Store.with_lock store ~name:V4_store.state_head_name
        ~on_error:(fun error -> Store_error error)
        (fun () ->
          let* loaded =
            V4_store.load repository
            |> Result.map_error (fun error -> V4_store_error error)
          in
          action repository store loaded))

let plan ~root =
  with_consistent_repository ~root (fun _repository store loaded ->
      plan_from_loaded ~root store loaded)

let gc_directory root = Filename.concat (Filename.concat root ".yeokcham") "gc"

let transaction_directory root id =
  Filename.concat (gc_directory root) ("v4-gc-" ^ id)

let manifest_path root id =
  Filename.concat (transaction_directory root id) "transaction.cbor"

let staged_path root transaction object_id =
  Filename.concat
    (transaction_directory root transaction.transaction_id)
    (Store.Stored_object_id.to_hex object_id)

let purge_directory root transaction =
  Filename.concat
    (transaction_directory root transaction.transaction_id)
    "purged"

let purge_marker_path root transaction object_id =
  Filename.concat
    (purge_directory root transaction)
    (Store.Stored_object_id.to_hex object_id)

let fsync_directory directory =
  try
    let descriptor = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () -> Unix.fsync descriptor);
    Ok ()
  with
  | Unix.Unix_error ((Unix.EINVAL | Unix.ENOSYS | Unix.EOPNOTSUPP), _, _) ->
      Ok ()
  | Unix.Unix_error (error, _, _) ->
      Error (io_error "fsync directory" directory error)

let lstat_or_missing path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

let ensure_directory directory =
  let rec create path =
    match lstat_or_missing path with
    | Error error -> Error error
    | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
    | Ok (Some _) -> Error (Quarantine_collision path)
    | Ok None -> (
        let parent = Filename.dirname path in
        let* () = create parent in
        try
          Unix.mkdir path 0o700;
          fsync_directory parent
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> create path
        | Unix.Unix_error (error, _, _) -> Error (io_error "mkdir" path error))
  in
  create directory

let read_regular_file ~limit path =
  let* stat =
    match lstat_or_missing path with
    | Ok (Some stat) when stat.Unix.st_kind = Unix.S_REG -> Ok stat
    | Ok (Some _) -> Error (Quarantine_collision path)
    | Ok None ->
        Error (Io_error { operation = "read"; path; message = "missing" })
    | Error error -> Error error
  in
  if stat.Unix.st_size > limit then
    Error (Invalid_schema "quarantine record exceeds its byte limit")
  else
    try Ok (In_channel.with_open_bin path In_channel.input_all)
    with Sys_error message ->
      Error (Io_error { operation = "read"; path; message })

let write_exclusive path bytes =
  try
    let descriptor =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    let channel = Unix.out_channel_of_descr descriptor in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        Out_channel.output_string channel bytes;
        Out_channel.flush channel;
        Unix.fsync descriptor);
    fsync_directory (Filename.dirname path)
  with
  | Unix.Unix_error (error, _, _) -> Error (io_error "create" path error)
  | Sys_error message -> Error (Io_error { operation = "write"; path; message })

let write_transaction ~root transaction =
  let* () = ensure_directory (gc_directory root) in
  let directory = transaction_directory root transaction.transaction_id in
  let* () =
    match lstat_or_missing directory with
    | Ok None -> (
        try
          Unix.mkdir directory 0o700;
          fsync_directory (gc_directory root)
        with Unix.Unix_error (error, _, _) ->
          Error (io_error "mkdir" directory error))
    | Ok (Some stat) when stat.Unix.st_kind = Unix.S_DIR -> Ok ()
    | Ok (Some _) -> Error (Quarantine_collision directory)
    | Error error -> Error error
  in
  let path = manifest_path root transaction.transaction_id in
  let* bytes = encode_transaction transaction in
  match lstat_or_missing path with
  | Error error -> Error error
  | Ok None -> write_exclusive path bytes
  | Ok (Some _) ->
      let* existing = read_regular_file ~limit:max_transaction_bytes path in
      if String.equal existing bytes then Ok ()
      else Error (Transaction_collision path)

let read_transaction ~root ~id =
  if not (valid_transaction_id id) then Error (Transaction_not_found id)
  else
    let path = manifest_path root id in
    match lstat_or_missing path with
    | Error error -> Error error
    | Ok None -> Error (Transaction_not_found id)
    | Ok (Some _) ->
        let* bytes = read_regular_file ~limit:max_transaction_bytes path in
        let* transaction = decode_transaction bytes in
        if String.equal transaction.transaction_id id then Ok transaction
        else
          Error
            (Invalid_schema "transaction directory does not match its record")

let verify_staged_file path object_ =
  let* bytes = read_regular_file ~limit:Store.max_object_bytes path in
  if String.length bytes <> object_.stored_bytes then
    Error (Quarantine_collision path)
  else
    let* envelope =
      Envelope.decode bytes
      |> Result.map_error (fun error ->
          Invalid_schema (Envelope.decode_error_to_string error))
    in
    let actual = Store.id_of_envelope envelope in
    if
      Store.Stored_object_id.equal object_.object_id actual
      && Envelope.object_type envelope = object_.object_type
    then Ok ()
    else Error (Quarantine_collision path)

let verify_active_object store object_ =
  let path = Store.object_path store object_.object_id in
  let* stat =
    match lstat_or_missing path with
    | Ok (Some stat) when stat.Unix.st_kind = Unix.S_REG -> Ok stat
    | Ok (Some _) -> Error (Quarantine_collision path)
    | Ok None -> Error (Transaction_object_missing object_.object_id)
    | Error error -> Error error
  in
  if stat.Unix.st_size <> object_.stored_bytes then
    Error (Quarantine_collision path)
  else
    let* envelope =
      Store.get store object_.object_id
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type envelope = object_.object_type then Ok ()
    else Error (Quarantine_collision path)

let purge_marker_exists path =
  match lstat_or_missing path with
  | Error error -> Error error
  | Ok None -> Ok false
  | Ok (Some stat) when stat.Unix.st_kind <> Unix.S_REG ->
      Error (Quarantine_collision path)
  | Ok (Some stat) when stat.Unix.st_size <> 0 ->
      Error (Quarantine_collision path)
  | Ok (Some _) -> Ok true

let progress_of_transaction ~root store transaction =
  let rec loop staged active purged purge_started = function
    | [] ->
        Ok
          {
            progress_transaction = transaction;
            staged_objects = List.rev staged;
            active_objects = List.rev active;
            purged_objects = List.rev purged;
            purge_started;
          }
    | object_ :: rest -> (
        let staged_path = staged_path root transaction object_.object_id in
        let active_path = Store.object_path store object_.object_id in
        let* staged_exists = lstat_or_missing staged_path in
        let* active_exists = lstat_or_missing active_path in
        let* purge_marker =
          purge_marker_exists
            (purge_marker_path root transaction object_.object_id)
        in
        match (staged_exists, active_exists, purge_marker) with
        | Some _, Some _, false ->
            let* () = verify_staged_file staged_path object_ in
            let* () = verify_active_object store object_ in
            loop
              (object_.object_id :: staged)
              (object_.object_id :: active)
              purged purge_started rest
        | Some _, Some _, true -> Error (Quarantine_collision staged_path)
        | Some _, None, purge_marker ->
            let* () = verify_staged_file staged_path object_ in
            loop
              (object_.object_id :: staged)
              active purged
              (purge_started || purge_marker)
              rest
        | None, Some _, false ->
            let* () = verify_active_object store object_ in
            loop staged (object_.object_id :: active) purged purge_started rest
        | None, Some _, true -> Error (Quarantine_collision active_path)
        | None, None, true ->
            loop staged active (object_.object_id :: purged) true rest
        | None, None, false ->
            Error (Transaction_object_missing object_.object_id))
  in
  loop [] [] [] false transaction.transaction_objects

let transactions_unlocked ~root store =
  let directory = gc_directory root in
  match lstat_or_missing directory with
  | Error error -> Error error
  | Ok None -> Ok []
  | Ok (Some stat) when stat.Unix.st_kind <> Unix.S_DIR ->
      Error (Quarantine_collision directory)
  | Ok (Some _) ->
      let* names =
        try
          Ok (Sys.readdir directory |> Array.to_list |> List.sort String.compare)
        with Sys_error message ->
          Error (Io_error { operation = "readdir"; path = directory; message })
      in
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | name :: rest when String.starts_with ~prefix:"." name ->
            loop reversed rest
        | name :: _ when not (String.starts_with ~prefix:"v4-gc-" name) ->
            Error (Invalid_schema "unknown entry in V4 GC directory")
        | name :: rest ->
            let id = String.sub name 6 (String.length name - 6) in
            let* transaction = read_transaction ~root ~id in
            let* progress = progress_of_transaction ~root store transaction in
            loop (progress :: reversed) rest
      in
      loop [] names

let transactions ~root =
  with_consistent_repository ~root (fun _repository store _loaded ->
      transactions_unlocked ~root store)

let ensure_collectible_now plan transaction =
  List.fold_left
    (fun result object_ ->
      let* () = result in
      match
        List.find_opt
          (fun planned ->
            Store.Stored_object_id.equal planned.object_id object_.object_id)
          plan.objects
      with
      | Some { disposition = Collect; _ } | None -> Ok ()
      | Some { disposition = Retain _; _ } ->
          Error (Stale_transaction_object object_.object_id))
    (Ok ()) transaction.transaction_objects

let move_to_quarantine ~root store transaction progress =
  let rec stage = function
    | [] -> progress_of_transaction ~root store transaction
    | object_id :: rest -> (
        let object_ =
          List.find
            (fun object_ ->
              Store.Stored_object_id.equal object_.object_id object_id)
            transaction.transaction_objects
        in
        let source = Store.object_path store object_id in
        let destination = staged_path root transaction object_id in
        let* destination_exists = lstat_or_missing destination in
        match destination_exists with
        | Some _ -> Error (Quarantine_collision destination)
        | None -> (
            let* () = verify_active_object store object_ in
            try
              Unix.rename source destination;
              let* () = fsync_directory (Filename.dirname source) in
              let* () = fsync_directory (Filename.dirname destination) in
              stage rest
            with Unix.Unix_error (error, _, _) ->
              Error (io_error "rename" destination error)))
  in
  stage progress.active_objects

let apply ~root =
  with_consistent_repository ~root (fun _repository store loaded ->
      let* existing = transactions_unlocked ~root store in
      match
        List.find_opt
          (fun progress ->
            progress.staged_objects <> [] || progress.active_objects <> [])
          existing
      with
      | Some progress ->
          Error
            (Incomplete_transaction progress.progress_transaction.transaction_id)
      | None ->
          let* plan = plan_from_loaded ~root store loaded in
          let* transaction = make_transaction plan in
          let* () = write_transaction ~root transaction in
          let* progress = progress_of_transaction ~root store transaction in
          move_to_quarantine ~root store transaction progress)

let resume ~root ~id =
  with_consistent_repository ~root (fun _repository store loaded ->
      let* transaction = read_transaction ~root ~id in
      let* plan = plan_from_loaded ~root store loaded in
      let* () = ensure_collectible_now plan transaction in
      let* progress = progress_of_transaction ~root store transaction in
      if progress.purge_started then Error (Incomplete_transaction id)
      else move_to_quarantine ~root store transaction progress)

let unlink path =
  try
    Unix.unlink path;
    fsync_directory (Filename.dirname path)
  with Unix.Unix_error (error, _, _) -> Error (io_error "unlink" path error)

let restore ~root ~id =
  with_consistent_repository ~root (fun _repository store _loaded ->
      let* transaction = read_transaction ~root ~id in
      let* progress = progress_of_transaction ~root store transaction in
      if progress.purge_started then Error (Incomplete_transaction id)
      else
        let rec move_back = function
          | [] -> Ok ()
          | object_id :: rest -> (
              let staged = staged_path root transaction object_id in
              let active = Store.object_path store object_id in
              let* active_exists = lstat_or_missing active in
              match active_exists with
              | None -> (
                  try
                    Unix.rename staged active;
                    let* () = fsync_directory (Filename.dirname staged) in
                    let* () = fsync_directory (Filename.dirname active) in
                    move_back rest
                  with Unix.Unix_error (error, _, _) ->
                    Error (io_error "rename" active error))
              | Some _ ->
                  let staged_object =
                    List.find
                      (fun object_ ->
                        Store.Stored_object_id.equal object_.object_id object_id)
                      transaction.transaction_objects
                  in
                  let* () = verify_staged_file staged staged_object in
                  let* object_ =
                    Store.get store object_id
                    |> Result.map_error (fun error -> Store_error error)
                  in
                  if
                    Store.Stored_object_id.equal object_id
                      (Store.id_of_envelope object_)
                  then
                    let* () = unlink staged in
                    move_back rest
                  else Error (Quarantine_collision active))
        in
        let* () = move_back progress.staged_objects in
        let* () = unlink (manifest_path root id) in
        let directory = transaction_directory root id in
        try
          Unix.rmdir directory;
          fsync_directory (gc_directory root)
        with Unix.Unix_error (error, _, _) ->
          Error (io_error "rmdir" directory error))

let purge ~root ~id =
  with_consistent_repository ~root (fun _repository store loaded ->
      let* transaction = read_transaction ~root ~id in
      let* plan = plan_from_loaded ~root store loaded in
      let* () = ensure_collectible_now plan transaction in
      let* progress = progress_of_transaction ~root store transaction in
      if progress.active_objects <> [] then Error (Incomplete_transaction id)
      else
        let reclaimed =
          List.fold_left
            (fun total object_id ->
              let object_ =
                List.find
                  (fun object_ ->
                    Store.Stored_object_id.equal object_.object_id object_id)
                  transaction.transaction_objects
              in
              total + object_.stored_bytes)
            0 progress.staged_objects
        in
        let* () = ensure_directory (purge_directory root transaction) in
        let* () =
          List.fold_left
            (fun result object_id ->
              let* () = result in
              let marker = purge_marker_path root transaction object_id in
              let* marked = purge_marker_exists marker in
              let* () = if marked then Ok () else write_exclusive marker "" in
              unlink (staged_path root transaction object_id))
            (Ok ()) progress.staged_objects
        in
        Ok reclaimed)
