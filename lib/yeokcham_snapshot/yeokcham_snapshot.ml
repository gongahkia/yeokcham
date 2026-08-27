module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Store = Yeokcham_store
module Hash = Yeokcham_hash.Sha256

type file_mode = Regular | Executable | Symlink

type error =
  | Store_error of Store.error
  | Encoding_error of Encoding.construction_error
  | Envelope_creation_error of Envelope.creation_error
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Invalid_name of string
  | Duplicate_name of string
  | Unordered_name of { previous : string; current : string }
  | Invalid_mode of int64
  | Invalid_object_id_length of int
  | Invalid_content_id_length of int
  | Noncanonical_schema_bytes
  | Noncanonical_content_representation of { length : int; limit : int }
  | Unsupported_chunking_algorithm of int64
  | Unsupported_chunking_parameters of string
  | Invalid_chunk_length of int64
  | Manifest_length_mismatch of { declared : int; actual : int }
  | Manifest_content_identity_mismatch
  | Noncanonical_chunk_boundaries
  | File_too_large of { path : string; size : int; limit : int }
  | Scan_error of { path : string; operation : string; message : string }
  | Unsupported_file_type of { path : string; kind : string }
  | Invalid_ignore_path of { line : int; path : string }

let object_type_name object_type =
  Printf.sprintf "object type %d" (Envelope.object_type_code object_type)

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Envelope_creation_error error -> Envelope.creation_error_to_string error
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "expected %s, got %s"
        (object_type_name expected)
        (object_type_name actual)
  | Invalid_schema message ->
      Printf.sprintf "invalid persisted snapshot schema: %s" message
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported persisted snapshot schema version: %Ld"
        version
  | Invalid_name name -> Printf.sprintf "invalid tree entry name: %S" name
  | Duplicate_name name -> Printf.sprintf "duplicate tree entry name: %S" name
  | Unordered_name { previous; current } ->
      Printf.sprintf "tree names are not strictly ordered: %S then %S" previous
        current
  | Invalid_mode mode -> Printf.sprintf "invalid persisted file mode: %Ld" mode
  | Invalid_object_id_length length ->
      Printf.sprintf "stored object ID must be 32 bytes, got %d" length
  | Invalid_content_id_length length ->
      Printf.sprintf "content identity must be 32 bytes, got %d" length
  | Noncanonical_schema_bytes ->
      "persisted snapshot schema bytes are noncanonical"
  | Noncanonical_content_representation { length; limit } ->
      Printf.sprintf
        "file manifest is noncanonical for %d bytes; inline limit is %d" length
        limit
  | Unsupported_chunking_algorithm algorithm ->
      Printf.sprintf "unsupported manifest chunking algorithm: %Ld" algorithm
  | Unsupported_chunking_parameters parameters ->
      Printf.sprintf "unsupported manifest chunking parameters: %s" parameters
  | Invalid_chunk_length length ->
      Printf.sprintf "invalid manifest chunk length: %Ld" length
  | Manifest_length_mismatch { declared; actual } ->
      Printf.sprintf "manifest length mismatch: declared %d bytes, got %d"
        declared actual
  | Manifest_content_identity_mismatch ->
      "manifest full-content identity does not match reconstructed bytes"
  | Noncanonical_chunk_boundaries ->
      "manifest chunks do not match the declared canonical boundaries"
  | File_too_large { path; size; limit } ->
      Printf.sprintf "file exceeds inline storage limit (%d > %d bytes): %s"
        size limit path
  | Scan_error { path; operation; message } ->
      Printf.sprintf "%s failed for %s: %s" operation path message
  | Unsupported_file_type { path; kind } ->
      Printf.sprintf "unsupported filesystem node (%s): %s" kind path
  | Invalid_ignore_path { line; path } ->
      Printf.sprintf "invalid .yeokchamignore path on line %d: %S" line path

let ( let* ) = Result.bind

let encoding_array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let exact_array name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_schema (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_schema (name ^ " must be bytes"))

let raw_object_id value =
  let* raw = bytes "stored object ID" value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None -> Error (Invalid_object_id_length (String.length raw))

let raw_content_id value =
  let* raw = bytes "content identity" value in
  if String.length raw = 32 then Ok raw
  else Error (Invalid_content_id_length (String.length raw))

let envelope object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error -> Envelope_creation_error error)

let inline_file_limit = 64 * 1024
let content_domain = "yeokcham:content:v1\000"

let content_identity bytes =
  Hash.feed_string Hash.empty content_domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let canonical_payload_matches expected payload =
  if String.equal expected (Encoding.encode payload) then Ok ()
  else Error Noncanonical_schema_bytes

let valid_name name =
  (not (String.is_empty name))
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let mode_code = function Regular -> 0L | Executable -> 1L | Symlink -> 2L

let mode_of_code = function
  | 0L -> Ok Regular
  | 1L -> Ok Executable
  | 2L -> Ok Symlink
  | value -> Error (Invalid_mode value)

module Chunk = struct
  type id = Store.Stored_object_id.t

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal

  let payload value =
    encoding_array [ Encoding.integer 1L; Encoding.bytes value ]

  let store repository value =
    let* payload = payload value in
    let* object_ = envelope Envelope.Chunk payload in
    Store.put repository object_
    |> Result.map_error (fun error -> Store_error error)

  let decode payload_value =
    let* fields = exact_array "chunk" 2 payload_value in
    match fields with
    | [ version; value ] ->
        let* version = integer "chunk version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* value = bytes "chunk value" value in
          let* canonical = payload value in
          let* () =
            canonical_payload_matches (Encoding.encode canonical) payload_value
          in
          Ok value
    | _ -> Error (Invalid_schema "chunk must contain two values")

  let load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Chunk then
      Error
        (Unexpected_object_type
           { expected = Envelope.Chunk; actual = Envelope.object_type object_ })
    else decode (Envelope.payload object_)
end

module Manifest = struct
  type id = Store.Stored_object_id.t

  type t = {
    total_length : int;
    full_content_id : string;
    chunks : (Chunk.id * int) list;
  }

  let schema_version = 1L
  let algorithm = 1L
  let window_size = 64L
  let min_size = 16_384L
  let average_size = 65_536L
  let max_size = 131_072L
  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal
  let total_length manifest = manifest.total_length
  let chunks manifest = manifest.chunks

  let chunk_ref_value (chunk, length) =
    encoding_array
      [
        Encoding.bytes (Store.Stored_object_id.to_raw_bytes chunk);
        Encoding.integer (Int64.of_int length);
      ]

  let payload manifest =
    let rec encode reversed = function
      | [] -> Ok (List.rev reversed)
      | reference :: rest ->
          let* encoded = chunk_ref_value reference in
          encode (encoded :: reversed) rest
    in
    let* references = encode [] manifest.chunks in
    let* references = encoding_array references in
    encoding_array
      [
        Encoding.integer schema_version;
        Encoding.integer (Int64.of_int manifest.total_length);
        Encoding.integer algorithm;
        Encoding.integer window_size;
        Encoding.integer min_size;
        Encoding.integer average_size;
        Encoding.integer max_size;
        Encoding.bytes manifest.full_content_id;
        references;
      ]

  let check_representation manifest =
    if manifest.total_length <= inline_file_limit then
      Error
        (Noncanonical_content_representation
           { length = manifest.total_length; limit = inline_file_limit })
    else if String.length manifest.full_content_id <> 32 then
      Error (Invalid_content_id_length (String.length manifest.full_content_id))
    else
      let total =
        List.fold_left
          (fun total (_, length) ->
            if length <= 0 then
              Error (Invalid_chunk_length (Int64.of_int length))
            else
              match total with
              | Error _ as error -> error
              | Ok total ->
                  if total > max_int - length then
                    Error (Invalid_chunk_length (Int64.of_int length))
                  else Ok (total + length))
          (Ok 0) manifest.chunks
      in
      let* total = total in
      if manifest.chunks = [] then
        Error (Invalid_schema "manifest has no chunks")
      else if total <> manifest.total_length then
        Error
          (Manifest_length_mismatch
             { declared = manifest.total_length; actual = total })
      else Ok ()

  let store_manifest repository manifest =
    let* () = check_representation manifest in
    let* payload = payload manifest in
    let* object_ = envelope Envelope.File_manifest payload in
    Store.put repository object_
    |> Result.map_error (fun error -> Store_error error)

  let store_chunks repository ~total_length ~full_content_id chunks =
    store_manifest repository { total_length; full_content_id; chunks }

  let store_bytes repository value =
    if String.length value <= inline_file_limit then
      Error
        (Noncanonical_content_representation
           { length = String.length value; limit = inline_file_limit })
    else
      let* chunks =
        Yeokcham_chunking.split Yeokcham_chunking.default value
        |> Result.map_error (fun error ->
            Unsupported_chunking_parameters
              (Yeokcham_chunking.error_to_string error))
      in
      let rec store_chunk_objects reversed = function
        | [] -> Ok (List.rev reversed)
        | chunk :: rest ->
            let* identity = Chunk.store repository chunk in
            store_chunk_objects
              ((identity, String.length chunk) :: reversed)
              rest
      in
      let* chunks = store_chunk_objects [] chunks in
      store_chunks repository ~total_length:(String.length value)
        ~full_content_id:(content_identity value) chunks

  let decode_chunk_ref value =
    let* fields = exact_array "manifest chunk reference" 2 value in
    match fields with
    | [ identity; length ] ->
        let* identity = raw_object_id identity in
        let* length = integer "manifest chunk length" length in
        if
          Int64.compare length 0L <= 0
          || Int64.compare length (Int64.of_int max_int) > 0
        then Error (Invalid_chunk_length length)
        else Ok (Chunk.of_stored_object_id identity, Int64.to_int length)
    | _ ->
        Error
          (Invalid_schema "manifest chunk reference must contain two values")

  let exact_parameters values =
    match values with
    | [ algorithm_value; window_value; minimum; average; maximum ] ->
        let* algorithm_value = integer "manifest algorithm" algorithm_value in
        if not (Int64.equal algorithm_value algorithm) then
          Error (Unsupported_chunking_algorithm algorithm_value)
        else
          let* window_value = integer "manifest window size" window_value in
          let* minimum = integer "manifest minimum chunk size" minimum in
          let* average = integer "manifest average chunk size" average in
          let* maximum = integer "manifest maximum chunk size" maximum in
          if
            Int64.equal window_value window_size
            && Int64.equal minimum min_size
            && Int64.equal average average_size
            && Int64.equal maximum max_size
          then Ok ()
          else
            Error
              (Unsupported_chunking_parameters
                 (Printf.sprintf "window=%Ld min=%Ld average=%Ld max=%Ld"
                    window_value minimum average maximum))
    | _ -> Error (Invalid_schema "manifest parameters are missing")

  let decode payload_value =
    let* fields = exact_array "file manifest" 9 payload_value in
    match fields with
    | [
     version;
     total;
     algorithm_value;
     window_value;
     minimum;
     average;
     maximum;
     full_id;
     references;
    ] ->
        let* version = integer "file manifest version" version in
        if not (Int64.equal version schema_version) then
          Error (Unsupported_schema_version version)
        else
          let* total = integer "manifest total length" total in
          if
            Int64.compare total 0L <= 0
            || Int64.compare total (Int64.of_int max_int) > 0
          then Error (Invalid_chunk_length total)
          else
            let* () =
              exact_parameters
                [ algorithm_value; window_value; minimum; average; maximum ]
            in
            let* full_content_id = raw_content_id full_id in
            let* references =
              array_values "manifest chunk references" references
            in
            let rec decode_references reversed = function
              | [] -> Ok (List.rev reversed)
              | reference :: rest ->
                  let* reference = decode_chunk_ref reference in
                  decode_references (reference :: reversed) rest
            in
            let* chunks = decode_references [] references in
            let manifest =
              { total_length = Int64.to_int total; full_content_id; chunks }
            in
            let* () = check_representation manifest in
            let* canonical = payload manifest in
            let* () =
              canonical_payload_matches
                (Encoding.encode canonical)
                payload_value
            in
            Ok manifest
    | _ -> Error (Invalid_schema "file manifest must contain nine values")

  let contents repository manifest =
    let rec load_chunks reversed actual_length = function
      | [] -> Ok (List.rev reversed, actual_length)
      | (identity, declared_length) :: rest ->
          let* chunk = Chunk.load repository identity in
          let actual_chunk_length = String.length chunk in
          if actual_chunk_length <> declared_length then
            Error
              (Manifest_length_mismatch
                 { declared = declared_length; actual = actual_chunk_length })
          else if actual_length > max_int - actual_chunk_length then
            Error (Invalid_chunk_length (Int64.of_int actual_chunk_length))
          else
            load_chunks (chunk :: reversed)
              (actual_length + actual_chunk_length)
              rest
    in
    let* chunks, actual_length = load_chunks [] 0 manifest.chunks in
    if actual_length <> manifest.total_length then
      Error
        (Manifest_length_mismatch
           { declared = manifest.total_length; actual = actual_length })
    else if
      not
        (Yeokcham_chunking.chunks_are_canonical Yeokcham_chunking.default chunks)
    then Error Noncanonical_chunk_boundaries
    else
      let contents = String.concat "" chunks in
      if not (String.equal (content_identity contents) manifest.full_content_id)
      then Error Manifest_content_identity_mismatch
      else Ok contents

  let load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.File_manifest then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.File_manifest;
             actual = Envelope.object_type object_;
           })
    else
      let* manifest = decode (Envelope.payload object_) in
      let* _ = contents repository manifest in
      Ok manifest
end

module Content = struct
  type id = Store.Stored_object_id.t
  type identity = string

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal
  let identity_of_bytes = content_identity
  let identity_to_raw_bytes identity = identity

  let payload value =
    encoding_array [ Encoding.integer 1L; Encoding.bytes value ]

  let store repository value =
    if String.length value <= inline_file_limit then
      let* payload = payload value in
      let* object_ = envelope Envelope.Content payload in
      Store.put repository object_
      |> Result.map_error (fun error -> Store_error error)
    else Manifest.store_bytes repository value

  let decode payload_value =
    let* fields = exact_array "content" 2 payload_value in
    match fields with
    | [ version; value ] ->
        let* version = integer "content version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* value = bytes "content value" value in
          let* canonical = payload value in
          let* () =
            canonical_payload_matches (Encoding.encode canonical) payload_value
          in
          Ok value
    | _ -> Error (Invalid_schema "content must contain two values")

  let load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    let actual = Envelope.object_type object_ in
    if actual = Envelope.Content then decode (Envelope.payload object_)
    else if actual = Envelope.File_manifest then
      let manifest = Manifest.of_stored_object_id identity in
      let* manifest = Manifest.load repository manifest in
      Manifest.contents repository manifest
    else Error (Unexpected_object_type { expected = Envelope.Content; actual })
end

module Tree = struct
  type id = Store.Stored_object_id.t

  type entry =
    | File of { mode : file_mode; content : Content.id }
    | Directory of id

  type t = (string * entry) list

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal
  let entries tree = tree

  let create entries =
    let sorted =
      List.sort (fun (left, _) (right, _) -> String.compare left right) entries
    in
    let rec validate previous = function
      | [] -> Ok sorted
      | (name, _) :: rest ->
          if not (valid_name name) then Error (Invalid_name name)
          else
            let* () =
              match previous with
              | None -> Ok ()
              | Some prior ->
                  let comparison = String.compare prior name in
                  if comparison = 0 then Error (Duplicate_name name) else Ok ()
            in
            validate (Some name) rest
    in
    validate None sorted

  let entry_value (name, entry) =
    match entry with
    | File { mode; content } ->
        encoding_array
          [
            Encoding.integer 0L;
            Encoding.bytes name;
            Encoding.integer (mode_code mode);
            Encoding.bytes (Store.Stored_object_id.to_raw_bytes content);
          ]
    | Directory child ->
        encoding_array
          [
            Encoding.integer 1L;
            Encoding.bytes name;
            Encoding.bytes (Store.Stored_object_id.to_raw_bytes child);
          ]

  let payload entries =
    let rec encode reversed = function
      | [] -> Ok (List.rev reversed)
      | entry :: rest ->
          let* encoded = entry_value entry in
          encode (encoded :: reversed) rest
    in
    let* values = encode [] entries in
    let* entries = encoding_array values in
    encoding_array [ Encoding.integer 1L; entries ]

  let id tree =
    let* payload = payload tree in
    let* object_ = envelope Envelope.Tree payload in
    Ok (Store.id_of_envelope object_)

  let store repository tree =
    let* payload = payload tree in
    let* object_ = envelope Envelope.Tree payload in
    Store.put repository object_
    |> Result.map_error (fun error -> Store_error error)

  let decode_entry value =
    let* fields = array_values "tree entry" value in
    match fields with
    | tag :: fields ->
        let* tag = integer "tree entry tag" tag in
        if Int64.equal tag 0L then
          match fields with
          | [ name; mode; content ] ->
              let* name = bytes "tree file name" name in
              let* mode = integer "tree file mode" mode in
              let* mode = mode_of_code mode in
              let* content = raw_object_id content in
              Ok (name, File { mode; content })
          | _ ->
              Error (Invalid_schema "file tree entry must contain four values")
        else if Int64.equal tag 1L then
          match fields with
          | [ name; child ] ->
              let* name = bytes "tree directory name" name in
              let* child = raw_object_id child in
              Ok (name, Directory child)
          | _ ->
              Error
                (Invalid_schema "directory tree entry must contain three values")
        else
          Error
            (Invalid_schema (Printf.sprintf "unknown tree entry tag: %Ld" tag))
    | [] -> Error (Invalid_schema "tree entry is empty")

  let ensure_input_order entries =
    let rec ordered previous = function
      | [] -> Ok ()
      | (name, _) :: rest ->
          let* () =
            match previous with
            | None -> Ok ()
            | Some prior ->
                let comparison = String.compare prior name in
                if comparison = 0 then Error (Duplicate_name name)
                else if comparison > 0 then
                  Error (Unordered_name { previous = prior; current = name })
                else Ok ()
          in
          ordered (Some name) rest
    in
    ordered None entries

  let decode payload_value =
    let* fields = exact_array "tree" 2 payload_value in
    match fields with
    | [ version; entries_value ] ->
        let* version = integer "tree version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* entries_value = array_values "tree entries" entries_value in
          let rec decode_entries reversed = function
            | [] -> Ok (List.rev reversed)
            | value :: rest ->
                let* entry = decode_entry value in
                decode_entries (entry :: reversed) rest
          in
          let* entries = decode_entries [] entries_value in
          let* () = ensure_input_order entries in
          let* tree = create entries in
          let* canonical = payload tree in
          let* () =
            canonical_payload_matches (Encoding.encode canonical) payload_value
          in
          Ok tree
    | _ -> Error (Invalid_schema "tree must contain two values")

  let rec load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Tree then
      Error
        (Unexpected_object_type
           { expected = Envelope.Tree; actual = Envelope.object_type object_ })
    else
      let* tree = decode (Envelope.payload object_) in
      let rec validate_references = function
        | [] -> Ok ()
        | (_, File { content; _ }) :: rest ->
            let* _ = Content.load repository content in
            validate_references rest
        | (_, Directory child) :: rest ->
            let* _ = load repository child in
            validate_references rest
      in
      let* () = validate_references tree in
      Ok tree
end

module Snapshot = struct
  type id = Store.Stored_object_id.t
  type t = { root : Tree.id }

  let of_stored_object_id identity = identity
  let stored_object_id identity = identity
  let equal_id = Store.Stored_object_id.equal
  let create ~root = { root }
  let root snapshot = snapshot.root

  let payload snapshot =
    encoding_array
      [
        Encoding.integer 1L;
        Encoding.bytes (Store.Stored_object_id.to_raw_bytes snapshot.root);
      ]

  let id snapshot =
    let* payload = payload snapshot in
    let* object_ = envelope Envelope.Snapshot payload in
    Ok (Store.id_of_envelope object_)

  let store repository snapshot =
    let* payload = payload snapshot in
    let* object_ = envelope Envelope.Snapshot payload in
    Store.put repository object_
    |> Result.map_error (fun error -> Store_error error)

  let decode payload_value =
    let* fields = exact_array "snapshot" 2 payload_value in
    match fields with
    | [ version; root ] ->
        let* version = integer "snapshot version" version in
        if not (Int64.equal version 1L) then
          Error (Unsupported_schema_version version)
        else
          let* root = raw_object_id root in
          let snapshot = create ~root in
          let* canonical = payload snapshot in
          let* () =
            canonical_payload_matches (Encoding.encode canonical) payload_value
          in
          Ok snapshot
    | _ -> Error (Invalid_schema "snapshot must contain two values")

  let load repository identity =
    let* object_ =
      Store.get repository (stored_object_id identity)
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type object_ <> Envelope.Snapshot then
      Error
        (Unexpected_object_type
           {
             expected = Envelope.Snapshot;
             actual = Envelope.object_type object_;
           })
    else
      let* snapshot = decode (Envelope.payload object_) in
      let* _ = Tree.load repository snapshot.root in
      Ok snapshot
end

let snapshot_error_to_string = error_to_string

type snapshot_model_error = error

module Materialize = struct
  type action =
    | Create_directory of string list
    | Write_file of {
        path : string list;
        content : Content.id;
        mode : file_mode;
      }
    | Create_symlink of { path : string list; target : Content.id }

  type error =
    | Snapshot_error of snapshot_model_error
    | Destination_not_directory of string
    | Destination_not_empty of string
    | Unsafe_destination_path of string list
    | Invalid_symlink_target of string list
    | Io_error of { path : string; operation : string; message : string }

  let error_to_string = function
    | Snapshot_error error -> snapshot_error_to_string error
    | Destination_not_directory path ->
        Printf.sprintf "materialisation destination is not a directory: %s" path
    | Destination_not_empty path ->
        Printf.sprintf "materialisation destination is not empty: %s" path
    | Unsafe_destination_path components ->
        Printf.sprintf "unsafe materialisation path: %s"
          (String.concat "/" components)
    | Invalid_symlink_target components ->
        Printf.sprintf "symlink target contains NUL bytes: %s"
          (String.concat "/" components)
    | Io_error { path; operation; message } ->
        Printf.sprintf "%s failed for %s: %s" operation path message

  let io_error operation path error =
    Io_error { path; operation; message = Unix.error_message error }

  let safe_output_path destination components =
    if List.for_all valid_name components then
      Ok (List.fold_left Filename.concat destination components)
    else Error (Unsafe_destination_path components)

  let plan repository snapshot =
    let rec plan_tree prefix identity =
      let* tree =
        Tree.load repository identity
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let rec plan_entries reversed = function
        | [] -> Ok (List.rev reversed)
        | (name, entry) :: rest ->
            let path = prefix @ [ name ] in
            let* actions =
              match entry with
              | Tree.File { mode = Symlink; content } ->
                  Ok [ Create_symlink { path; target = content } ]
              | Tree.File { mode = (Regular | Executable) as mode; content } ->
                  Ok [ Write_file { path; content; mode } ]
              | Tree.Directory child ->
                  let* descendants = plan_tree path child in
                  Ok (Create_directory path :: descendants)
            in
            plan_entries (List.rev_append actions reversed) rest
      in
      plan_entries [] (Tree.entries tree)
    in
    plan_tree [] (Snapshot.root snapshot)

  let validate_destination destination =
    try
      let stat = Unix.lstat destination in
      if stat.Unix.st_kind <> Unix.S_DIR then
        Error (Destination_not_directory destination)
      else
        try
          if Array.length (Sys.readdir destination) = 0 then Ok ()
          else Error (Destination_not_empty destination)
        with Sys_error message ->
          Error
            (Io_error { path = destination; operation = "readdir"; message })
    with Unix.Unix_error (error, _, _) ->
      Error (io_error "lstat" destination error)

  let write_all descriptor path bytes =
    let length = Bytes.length bytes in
    let rec write offset =
      if offset = length then Ok ()
      else
        try
          match Unix.write descriptor bytes offset (length - offset) with
          | 0 ->
              Error
                (Io_error
                   {
                     path;
                     operation = "write";
                     message = "write returned zero before completion";
                   })
          | count -> write (offset + count)
        with Unix.Unix_error (error, _, _) ->
          Error (io_error "write" path error)
    in
    write 0

  let close descriptor path =
    try
      Unix.close descriptor;
      Ok ()
    with Unix.Unix_error (error, _, _) -> Error (io_error "close" path error)

  let write_file path contents mode =
    try
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      let write_result = write_all descriptor path (Bytes.of_string contents) in
      let close_result = close descriptor path in
      let* () = write_result in
      let* () = close_result in
      let permissions = if mode = Executable then 0o755 else 0o644 in
      try
        Unix.chmod path permissions;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "chmod" path error)
    with Unix.Unix_error (error, _, _) -> Error (io_error "create" path error)

  let create_directory path =
    try
      Unix.mkdir path 0o700;
      Ok ()
    with Unix.Unix_error (error, _, _) -> Error (io_error "mkdir" path error)

  let create_symlink path target components =
    if String.contains target '\000' then
      Error (Invalid_symlink_target components)
    else
      try
        Unix.symlink target path;
        Ok ()
      with Unix.Unix_error (error, _, _) ->
        Error (io_error "symlink" path error)

  let apply_actions ~destination repository actions =
    let rec apply = function
      | [] -> Ok ()
      | action :: rest ->
          let* () =
            match action with
            | Create_directory components ->
                let* path = safe_output_path destination components in
                create_directory path
            | Write_file { path = components; content; mode } ->
                let* path = safe_output_path destination components in
                let* contents =
                  Content.load repository content
                  |> Result.map_error (fun error -> Snapshot_error error)
                in
                write_file path contents mode
            | Create_symlink { path = components; target } ->
                let* path = safe_output_path destination components in
                let* target =
                  Content.load repository target
                  |> Result.map_error (fun error -> Snapshot_error error)
                in
                create_symlink path target components
          in
          apply rest
    in
    apply actions

  let write ~destination repository snapshot =
    let* () = validate_destination destination in
    let* actions = plan repository snapshot in
    apply_actions ~destination repository actions

  let rec remove_tree path =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR -> (
          let entries =
            try Ok (Sys.readdir path)
            with Sys_error message ->
              Error (Io_error { path; operation = "readdir"; message })
          in
          let* entries = entries in
          let* () =
            Array.fold_left
              (fun result name ->
                let* () = result in
                remove_tree (Filename.concat path name))
              (Ok ()) entries
          in
          try
            Unix.rmdir path;
            Ok ()
          with Unix.Unix_error (error, _, _) ->
            Error (io_error "rmdir" path error))
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK -> (
          try
            Unix.unlink path;
            Ok ()
          with Unix.Unix_error (error, _, _) ->
            Error (io_error "unlink" path error))
    with Unix.Unix_error (error, _, _) -> Error (io_error "lstat" path error)

  let write_replacing ~destination ~preserved_root_names repository snapshot =
    let* actions = plan repository snapshot in
    let* entries =
      try Ok (Sys.readdir destination)
      with Sys_error message ->
        Error (Io_error { path = destination; operation = "readdir"; message })
    in
    let* () =
      Array.fold_left
        (fun result name ->
          let* () = result in
          if List.exists (String.equal name) preserved_root_names then Ok ()
          else remove_tree (Filename.concat destination name))
        (Ok ()) entries
    in
    apply_actions ~destination repository actions
end

let scan_error operation path error =
  Scan_error { path; operation; message = Unix.error_message error }

let same_file_identity expected actual =
  expected.Unix.st_kind = actual.Unix.st_kind
  && expected.Unix.st_dev = actual.Unix.st_dev
  && expected.Unix.st_ino = actual.Unix.st_ino

let read_file path expected =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        let stat = Unix.fstat descriptor in
        if stat.Unix.st_kind <> Unix.S_REG then
          Error (Unsupported_file_type { path; kind = "non-regular file" })
        else if not (same_file_identity expected stat) then
          Error
            (Scan_error
               {
                 path;
                 operation = "open";
                 message = "file identity changed while it was scanned";
               })
        else
          let size = expected.Unix.st_size in
          let bytes = Bytes.create size in
          let rec read offset =
            if offset = size then Ok ()
            else
              try
                match Unix.read descriptor bytes offset (size - offset) with
                | 0 ->
                    Error
                      (Scan_error
                         {
                           path;
                           operation = "read";
                           message = "file ended before its recorded size";
                         })
                | count -> read (offset + count)
              with Unix.Unix_error (error, _, _) ->
                Error (scan_error "read" path error)
          in
          let* () = read 0 in
          let probe = Bytes.create 1 in
          let* extra =
            try Ok (Unix.read descriptor probe 0 1)
            with Unix.Unix_error (error, _, _) ->
              Error (scan_error "read" path error)
          in
          if extra = 0 then Ok (Bytes.unsafe_to_string bytes)
          else
            Error
              (Scan_error
                 {
                   path;
                   operation = "read";
                   message = "file grew while it was scanned";
                 }))
  with Unix.Unix_error (error, _, _) -> Error (scan_error "open" path error)

let store_large_file repository path expected =
  try
    let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        let stat = Unix.fstat descriptor in
        if stat.Unix.st_kind <> Unix.S_REG then
          Error (Unsupported_file_type { path; kind = "non-regular file" })
        else if not (same_file_identity expected stat) then
          Error
            (Scan_error
               {
                 path;
                 operation = "open";
                 message = "file identity changed while it was scanned";
               })
        else
          let* splitter =
            Yeokcham_chunking.create_splitter Yeokcham_chunking.default
            |> Result.map_error (fun error ->
                Unsupported_chunking_parameters
                  (Yeokcham_chunking.error_to_string error))
          in
          let buffer = Bytes.create (32 * 1024) in
          let full_content_hash =
            ref (Hash.feed_string Hash.empty content_domain)
          in
          let total = ref 0 in
          let chunk_references = ref [] in
          let store_chunks chunks =
            let rec persist reversed = function
              | [] -> Ok (List.rev reversed)
              | chunk :: rest ->
                  let* identity = Chunk.store repository chunk in
                  persist ((identity, String.length chunk) :: reversed) rest
            in
            let* stored = persist [] chunks in
            chunk_references := List.rev_append stored !chunk_references;
            Ok ()
          in
          let rec read () =
            let* count =
              try Ok (Unix.read descriptor buffer 0 (Bytes.length buffer))
              with Unix.Unix_error (error, _, _) ->
                Error (scan_error "read" path error)
            in
            if count = 0 then Ok ()
            else
              let bytes = Bytes.sub_string buffer 0 count in
              full_content_hash := Hash.feed_string !full_content_hash bytes;
              total := !total + count;
              let* () = store_chunks (Yeokcham_chunking.feed splitter bytes) in
              read ()
          in
          let* () = read () in
          let* () = store_chunks (Yeokcham_chunking.finish splitter) in
          let final_stat = Unix.fstat descriptor in
          if
            !total <> expected.Unix.st_size
            || final_stat.Unix.st_size <> expected.Unix.st_size
            || not (same_file_identity expected final_stat)
          then
            Error
              (Scan_error
                 {
                   path;
                   operation = "read";
                   message = "file size changed while it was scanned";
                 })
          else
            let full_content_id =
              Hash.get !full_content_hash |> Hash.to_raw_string
            in
            let* manifest =
              Manifest.store_chunks repository ~total_length:!total
                ~full_content_id
                (List.rev !chunk_references)
            in
            Ok
              (Content.of_stored_object_id (Manifest.stored_object_id manifest)))
  with Unix.Unix_error (error, _, _) -> Error (scan_error "open" path error)

let store_regular_file repository path stat =
  if stat.Unix.st_size <= inline_file_limit then
    let* contents = read_file path stat in
    Content.store repository contents
  else store_large_file repository path stat

let unsupported_node_kind = function
  | Unix.S_SOCK -> "socket"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_CHR -> "character-device"
  | Unix.S_BLK -> "block-device"
  | Unix.S_DIR -> "directory"
  | Unix.S_REG -> "regular-file"
  | Unix.S_LNK -> "symlink"

let safe_ignore_components path =
  if String.is_empty path || String.starts_with ~prefix:"/" path then None
  else
    let components = String.split_on_char '/' path in
    if List.for_all valid_name components then Some components else None

let read_ignore_file root =
  let path = Filename.concat root ".yeokchamignore" in
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG then
      Error (Invalid_ignore_path { line = 0; path = ".yeokchamignore" })
    else if stat.Unix.st_size > inline_file_limit then
      Error
        (File_too_large
           { path; size = stat.Unix.st_size; limit = inline_file_limit })
    else
      let* contents = read_file path stat in
      let lines = String.split_on_char '\n' contents in
      let rec parse line_number reversed = function
        | [] -> Ok (List.rev reversed)
        | line :: rest -> (
            let line =
              if String.ends_with ~suffix:"\r" line then
                String.sub line 0 (String.length line - 1)
              else line
            in
            if String.is_empty line || String.starts_with ~prefix:"#" line then
              parse (line_number + 1) reversed rest
            else
              match safe_ignore_components line with
              | Some components ->
                  parse (line_number + 1) (components :: reversed) rest
              | None ->
                  Error
                    (Invalid_ignore_path { line = line_number; path = line }))
      in
      parse 1 [] lines
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | Unix.Unix_error (error, _, _) -> Error (scan_error "lstat" path error)

let rec is_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | left :: left_rest, right :: right_rest ->
      String.equal left right && is_prefix left_rest right_rest

let is_ignored rules components =
  List.exists (fun rule -> is_prefix rule components) rules

let scan_excluding_root_names ~excluded_root_names ~root ~store =
  let* root_stat =
    try Ok (Unix.lstat root)
    with Unix.Unix_error (error, _, _) ->
      Error (scan_error "lstat" root error)
  in
  if root_stat.Unix.st_kind <> Unix.S_DIR then
    Error (Unsupported_file_type { path = root; kind = "not a directory" })
  else
    let* ignore_rules = read_ignore_file root in
    let rec scan_directory relative path =
      let names =
        try Ok (Sys.readdir path |> Array.to_list |> List.sort String.compare)
        with Sys_error message ->
          Error (Scan_error { path; operation = "readdir"; message })
      in
      let* names = names in
      let rec scan_entries reversed = function
        | [] -> Tree.create (List.rev reversed)
        | name :: rest ->
            let child_relative = relative @ [ name ] in
            if
              (relative = [] && List.mem name excluded_root_names)
              || is_ignored ignore_rules child_relative
            then scan_entries reversed rest
            else
              let child_path = Filename.concat path name in
              let* stat =
                try Ok (Unix.lstat child_path)
                with Unix.Unix_error (error, _, _) ->
                  Error (scan_error "lstat" child_path error)
              in
              let* entry =
                if stat.Unix.st_kind = Unix.S_DIR then
                  let* child = scan_directory child_relative child_path in
                  Ok (Tree.Directory child)
                else if stat.Unix.st_kind = Unix.S_REG then
                  let* content = store_regular_file store child_path stat in
                  let mode =
                    if stat.Unix.st_perm land 0o111 = 0 then Regular
                    else Executable
                  in
                  Ok (Tree.File { mode; content })
                else if stat.Unix.st_kind = Unix.S_LNK then
                  let* target =
                    try Ok (Unix.readlink child_path)
                    with Unix.Unix_error (error, _, _) ->
                      Error (scan_error "readlink" child_path error)
                  in
                  let* content = Content.store store target in
                  Ok (Tree.File { mode = Symlink; content })
                else
                  Error
                    (Unsupported_file_type
                       {
                         path = child_path;
                         kind = unsupported_node_kind stat.Unix.st_kind;
                       })
              in
              scan_entries ((name, entry) :: reversed) rest
      in
      let* tree = scan_entries [] names in
      Tree.store store tree
    in
    let* root_tree = scan_directory [] root in
    let snapshot = Snapshot.create ~root:root_tree in
    let* identity = Snapshot.store store snapshot in
    Ok (identity, snapshot)

let scan ~root ~store =
  scan_excluding_root_names ~excluded_root_names:[ ".yeokcham" ] ~root ~store
