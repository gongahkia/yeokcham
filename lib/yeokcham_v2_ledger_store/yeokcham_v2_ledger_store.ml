module Address = Yeokcham_v2_address
module Cutover = Yeokcham_cutover
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

type repository = {
  root : string;
  objects : string;
  repository_id : Model.Repository_id.t;
  address_key : Address.key;
  encryption_key : Envelope.key;
  public_keys : Ledger.public_key_registry;
}

type publication =
  | Published of {
      object_ref : Model.Opaque_object_ref.t;
      event_id : Ledger.Event_id.t;
    }
  | Already_published of {
      object_ref : Model.Opaque_object_ref.t;
      event_id : Ledger.Event_id.t;
    }

type error =
  | Cutover_error of Cutover.error
  | Not_v2_root of Cutover.classification
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_object_path of string
  | Envelope_error of Envelope.error
  | Address_error of Address.error
  | Ledger_error of Ledger.error
  | Unknown_signer of Ledger.Signer_key_id.t
  | Object_collision of Model.Opaque_object_ref.t

let max_object_bytes = Envelope.max_ciphertext_bytes + 128
let max_temporary_attempts = 32
let ( let* ) = Result.bind

let error_to_string = function
  | Cutover_error error -> Cutover.error_to_string error
  | Not_v2_root classification ->
      "V2 ledger storage requires a V2-only root, found "
      ^ Cutover.classification_to_string classification
  | Io_error { operation; path; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Invalid_object_path path -> "invalid V2 opaque object path: " ^ path
  | Envelope_error error -> Envelope.error_to_string error
  | Address_error error -> Address.error_to_string error
  | Ledger_error error -> Ledger.error_to_string error
  | Unknown_signer key ->
      "ref-ledger signer is unavailable: " ^ Ledger.Signer_key_id.to_hex key
  | Object_collision object_ref ->
      "opaque object address already contains different bytes: "
      ^ Model.Opaque_object_ref.to_hex object_ref

let io_error ~operation ~path error =
  Io_error { operation; path; message = Unix.error_message error }

let check_v2_root root =
  let* classification =
    Cutover.detect ~root |> Result.map_error (fun error -> Cutover_error error)
  in
  match classification with
  | Cutover.V2 -> Ok ()
  | ( Cutover.Empty | Cutover.Legacy | Cutover.Mixed_or_unknown _
    | Cutover.Incomplete _ ) as classification ->
      Error (Not_v2_root classification)

let open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys =
  let* () = check_v2_root root in
  Ok
    {
      root;
      objects = Filename.concat root ".yeokcham/objects";
      repository_id;
      address_key;
      encryption_key;
      public_keys;
    }

let repository_id repository = repository.repository_id

let object_path repository object_ref =
  let hex = Model.Opaque_object_ref.to_hex object_ref in
  Filename.concat repository.objects
    (Filename.concat (String.sub hex 0 2)
       (Filename.concat (String.sub hex 2 2) (String.sub hex 4 60)))

let fsync_directory path =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () ->
        Unix.fsync descriptor;
        Ok ())
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"fsync" ~path error)

let rec ensure_directory path =
  let* () =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR -> Ok ()
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Error (Invalid_object_path path)
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> (
        try
          Unix.mkdir path 0o700;
          Ok ()
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> ensure_directory path
        | Unix.Unix_error (error, _, _) ->
            Error (io_error ~operation:"mkdir" ~path error))
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"lstat" ~path error)
  in
  fsync_directory (Filename.dirname path)

let ensure_object_shard repository object_ref =
  let path = object_path repository object_ref in
  let first = Filename.dirname (Filename.dirname path) in
  let second = Filename.dirname path in
  let* () = ensure_directory first in
  ensure_directory second

let write_all descriptor bytes =
  let rec write offset =
    if offset = Bytes.length bytes then Ok ()
    else
      try
        let written =
          Unix.write descriptor bytes offset (Bytes.length bytes - offset)
        in
        if written = 0 then Error "write returned zero bytes"
        else write (offset + written)
      with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  in
  write 0

let temporary_path directory final attempt =
  Filename.concat directory
    (Printf.sprintf ".%s.ledger-%d-%d" (Filename.basename final)
       (Unix.getpid ()) attempt)

let create_temporary directory final bytes =
  let rec create attempt =
    if attempt = max_temporary_attempts then
      Error
        (Io_error
           {
             operation = "create temporary object";
             path = directory;
             message = "temporary name space exhausted";
           })
    else
      let path = temporary_path directory final attempt in
      try
        let descriptor =
          Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
        in
        let result =
          Fun.protect
            ~finally:(fun () -> Unix.close descriptor)
            (fun () ->
              let* () =
                write_all descriptor (Bytes.unsafe_of_string bytes)
                |> Result.map_error (fun message ->
                    Io_error { operation = "write"; path; message })
              in
              try
                Unix.fsync descriptor;
                Ok path
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"fsync" ~path error))
        in
        match result with
        | Ok _ -> result
        | Error _ ->
            (try Unix.unlink path with Unix.Unix_error _ -> ());
            result
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> create (attempt + 1)
      | Unix.Unix_error (error, _, _) ->
          Error (io_error ~operation:"create" ~path error)
  in
  create 0

let read_regular_file path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then Error (Invalid_object_path path)
    else if stat.Unix.st_size > max_object_bytes then
      Error
        (Io_error
           {
             operation = "read";
             path;
             message = "object exceeds the V2 envelope size limit";
           })
    else
      let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let bytes = Bytes.create stat.Unix.st_size in
          let rec read offset =
            if offset = Bytes.length bytes then
              Ok (Bytes.unsafe_to_string bytes)
            else
              try
                let count =
                  Unix.read descriptor bytes offset (Bytes.length bytes - offset)
                in
                if count = 0 then
                  Error
                    (Io_error
                       {
                         operation = "read";
                         path;
                         message = "object changed while being read";
                       })
                else read (offset + count)
              with Unix.Unix_error (error, _, _) ->
                Error (io_error ~operation:"read" ~path error)
          in
          read 0)
  with Unix.Unix_error (error, _, _) ->
    Error (io_error ~operation:"lstat" ~path error)

let verified_envelope repository envelope =
  let object_ref =
    Address.derive ~repository_id:repository.repository_id
      ~key:repository.address_key ~envelope
  in
  let* plaintext =
    Envelope.open_envelope ~key:repository.encryption_key envelope
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* event =
    Ledger.decode plaintext
    |> Result.map_error (fun error -> Ledger_error error)
  in
  let* verification =
    Ledger.verify ~public_keys:repository.public_keys event
    |> Result.map_error (fun error -> Ledger_error error)
  in
  match verification with
  | Ledger.Cryptographically_valid verified -> Ok (object_ref, verified)
  | Ledger.Unknown_signer key -> Error (Unknown_signer key)

let validate_envelope repository ~envelope =
  let* () = check_v2_root repository.root in
  let* object_ref, verified = verified_envelope repository envelope in
  Ok (object_ref, Ledger.event_id (Ledger.verified_event verified))

let publish repository ~envelope =
  let* () = check_v2_root repository.root in
  let* object_ref, verified = verified_envelope repository envelope in
  let* () = ensure_object_shard repository object_ref in
  let final = object_path repository object_ref in
  let directory = Filename.dirname final in
  let bytes = Envelope.encode envelope in
  let* temporary = create_temporary directory final bytes in
  let linked =
    try
      Unix.link temporary final;
      Ok true
    with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok false
    | Unix.Unix_error (error, _, _) ->
        Error (io_error ~operation:"link" ~path:final error)
  in
  let cleanup () = try Unix.unlink temporary with Unix.Unix_error _ -> () in
  match linked with
  | Error error ->
      cleanup ();
      Error error
  | Ok true ->
      let* () = fsync_directory directory in
      cleanup ();
      let* () = fsync_directory directory in
      Ok
        (Published
           {
             object_ref;
             event_id = Ledger.event_id (Ledger.verified_event verified);
           })
  | Ok false ->
      cleanup ();
      let* existing = read_regular_file final in
      if String.equal existing bytes then
        Ok
          (Already_published
             {
               object_ref;
               event_id = Ledger.event_id (Ledger.verified_event verified);
             })
      else Error (Object_collision object_ref)

let load repository ~object_ref =
  let* () = check_v2_root repository.root in
  let path = object_path repository object_ref in
  let* bytes = read_regular_file path in
  let* envelope =
    Envelope.decode bytes
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* () =
    Address.verify ~repository_id:repository.repository_id
      ~key:repository.address_key ~address:object_ref ~envelope
    |> Result.map_error (fun error -> Address_error error)
  in
  let* actual_ref, verified = verified_envelope repository envelope in
  if Model.Opaque_object_ref.equal object_ref actual_ref then Ok verified
  else Error (Object_collision object_ref)
