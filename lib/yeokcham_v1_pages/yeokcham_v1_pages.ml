module E = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Raw = Yeokcham_store
module Id = Raw.Stored_object_id

type error =
  | Invalid_input of string
  | Integrity of string
  | Store_error of Raw.error

let error_to_string = function
  | Invalid_input detail -> "invalid metadata collection: " ^ detail
  | Integrity detail -> "metadata integrity: " ^ detail
  | Store_error error -> Raw.error_to_string error

let ( let* ) = Result.bind
let max_page_bytes = 1024 * 1024
let max_value_bytes = 8 * 1024 * 1024
let chunk_bytes = 512 * 1024
let inline_bytes = 4096
let max_key_bytes = 1024
let fanout = 128
let stored value = Result.map_error (fun e -> Store_error e) value

let array values =
  E.array values
  |> Result.map_error (fun e -> Integrity (E.construction_error_to_string e))

let namespace_valid namespace =
  if namespace = "" || String.length namespace > 128 then
    Error (Invalid_input "namespace must contain 1 through 128 bytes")
  else Ok ()

let page namespace kind fields =
  let* payload =
    array (E.integer 1L :: E.bytes namespace :: E.integer kind :: fields)
  in
  let* envelope =
    Envelope.create ~object_type:Envelope.Core_metadata_page
      ~object_format_version:1 ~mandatory_features:0L ~payload ()
    |> Result.map_error (fun e ->
        Integrity (Envelope.creation_error_to_string e))
  in
  if String.length (Envelope.encode envelope) > max_page_bytes then
    Error (Invalid_input "page exceeds 1 MiB")
  else Ok envelope

let groups values =
  let rec loop pending count groups = function
    | [] ->
        List.rev (if pending = [] then groups else List.rev pending :: groups)
    | value :: rest when count = fanout ->
        loop [] 0 (List.rev pending :: groups) (value :: rest)
    | value :: rest -> loop (value :: pending) (count + 1) groups rest
  in
  match values with [] -> [ [] ] | values -> loop [] 0 [] values

let traverse f values =
  List.fold_left
    (fun acc value ->
      let* reversed = acc in
      let* value = f value in
      Ok (value :: reversed))
    (Ok []) values
  |> Result.map List.rev

let build intern ~namespace values =
  let* () = namespace_valid namespace in
  let values = List.sort (fun (a, _) (b, _) -> String.compare a b) values in
  let rec check previous = function
    | [] -> Ok ()
    | (key, value) :: rest ->
        if key = "" || String.length key > max_key_bytes then
          Error (Invalid_input "key must contain 1 through 1024 bytes")
        else if Option.equal String.equal previous (Some key) then
          Error (Invalid_input "duplicate key")
        else if String.length value > max_value_bytes then
          Error (Invalid_input "value exceeds 8 MiB")
        else check (Some key) rest
  in
  let* () = check None values in
  let value_reference value =
    if String.length value <= inline_bytes then
      array [ E.integer 0L; E.bytes value ]
    else
      let rec chunks offset reversed =
        if offset = String.length value then Ok (List.rev reversed)
        else
          let length = min chunk_bytes (String.length value - offset) in
          let* envelope =
            page namespace 2L [ E.bytes (String.sub value offset length) ]
          in
          let* id = intern envelope in
          chunks (offset + length) (E.bytes (Id.to_raw_bytes id) :: reversed)
      in
      let* chunks = chunks 0 [] in
      let* chunks = array chunks in
      let* envelope =
        page namespace 3L
          [ E.integer (Int64.of_int (String.length value)); chunks ]
      in
      let* id = intern envelope in
      array [ E.integer 1L; E.bytes (Id.to_raw_bytes id) ]
  in
  let* leaves =
    traverse
      (fun rows ->
        let* values =
          traverse
            (fun (key, value) ->
              let* reference = value_reference value in
              array [ E.bytes key; reference ])
            rows
        in
        let* values = array values in
        let* envelope = page namespace 0L [ values ] in
        let* id = intern envelope in
        let maximum =
          match List.rev rows with [] -> "" | (key, _) :: _ -> key
        in
        Ok (maximum, id))
      (groups values)
  in
  let rec index = function
    | [ (_, id) ] -> Ok id
    | [] -> assert false
    | nodes ->
        let* parents =
          traverse
            (fun children ->
              let* values =
                traverse
                  (fun (maximum, id) ->
                    array [ E.bytes maximum; E.bytes (Id.to_raw_bytes id) ])
                  children
              in
              let* values = array values in
              let* envelope = page namespace 1L [ values ] in
              let* id = intern envelope in
              Ok (fst (List.hd (List.rev children)), id))
            (groups nodes)
        in
        index parents
  in
  index leaves

let store repository ~namespace values =
  build
    (fun envelope -> Raw.put repository envelope |> stored)
    ~namespace values

let[@warning "-4"] read repository ~namespace root =
  let* () = namespace_valid namespace in
  let visited = Hashtbl.create 32 in
  let tree_pages = Hashtbl.create 32 in
  let read_page id =
    Hashtbl.replace visited id ();
    let* bytes =
      Raw.read_file_bounded
        ~path:(Raw.object_path repository id)
        ~max_bytes:max_page_bytes
      |> stored
    in
    let* envelope =
      Envelope.decode bytes
      |> Result.map_error (fun e ->
          Integrity (Envelope.decode_error_to_string e))
    in
    if
      Envelope.object_type envelope <> Envelope.Core_metadata_page
      || not (Id.equal id (Raw.id_of_envelope envelope))
    then Error (Integrity "wrong page type or identity")
    else
      match Envelope.payload envelope with
      | E.Array (E.Integer 1L :: E.Bytes scope :: E.Integer kind :: fields)
        when scope = namespace ->
          Ok (kind, fields)
      | _ -> Error (Integrity "unsupported page schema or wrong namespace")
  in
  let reference raw =
    Id.of_raw_bytes raw
    |> Option.to_result ~none:(Integrity "malformed page reference")
  in
  let load_value = function
    | E.Array [ E.Integer 0L; E.Bytes bytes ]
      when String.length bytes <= inline_bytes ->
        Ok bytes
    | E.Array [ E.Integer 1L; E.Bytes raw ] -> (
        let* id = reference raw in
        let* kind, fields = read_page id in
        match (kind, fields) with
        | 3L, [ E.Integer length; E.Array chunks ]
          when length > Int64.of_int inline_bytes
               && length <= Int64.of_int max_value_bytes
               && List.length chunks
                  = (Int64.to_int length + chunk_bytes - 1) / chunk_bytes ->
            let length = Int64.to_int length in
            let buffer = Buffer.create length in
            let* _ =
              List.fold_left
                (fun acc -> function
                  | E.Bytes raw -> (
                      let* remaining = acc in
                      let* id = reference raw in
                      let* kind, fields = read_page id in
                      match (kind, fields) with
                      | 2L, [ E.Bytes chunk ]
                        when String.length chunk = min remaining chunk_bytes ->
                          Buffer.add_string buffer chunk;
                          Ok (remaining - String.length chunk)
                      | _ -> Error (Integrity "invalid value chunk or boundary")
                      )
                  | _ -> Error (Integrity "malformed value chunk reference"))
                (Ok length) chunks
            in
            Ok (Buffer.contents buffer)
        | _ -> Error (Integrity "invalid value index"))
    | _ -> Error (Integrity "invalid inline or chunked value")
  in
  let rec walk depth id =
    if depth > 32 || Hashtbl.mem tree_pages id then
      Error (Integrity "repeated or excessively deep collection page")
    else (
      Hashtbl.add tree_pages id ();
      let* kind, fields = read_page id in
      match (kind, fields) with
      | 0L, [ E.Array rows ] when List.length rows <= fanout ->
          traverse
            (function
              | E.Array [ E.Bytes key; value ] ->
                  let* value = load_value value in
                  Ok (key, value)
              | _ -> Error (Integrity "invalid collection row"))
            rows
      | 1L, [ E.Array children ]
        when children <> [] && List.length children <= fanout ->
          let* rows =
            traverse
              (function
                | E.Array [ E.Bytes maximum; E.Bytes raw ] -> (
                    let* child = reference raw in
                    let* rows = walk (depth + 1) child in
                    match List.rev rows with
                    | (key, _) :: _ when key = maximum -> Ok rows
                    | _ -> Error (Integrity "incorrect child maximum key"))
                | _ -> Error (Integrity "invalid collection child"))
              children
          in
          Ok (List.concat rows)
      | _ -> Error (Integrity "invalid collection page"))
  in
  let* rows = walk 0 root in
  let* expected =
    build (fun envelope -> Ok (Raw.id_of_envelope envelope)) ~namespace rows
    |> Result.map_error (function Invalid_input s -> Integrity s | e -> e)
  in
  if not (Id.equal root expected) then
    Error (Integrity "noncanonical collection order or pagination")
  else
    Ok (rows, Hashtbl.to_seq_keys visited |> List.of_seq |> List.sort Id.compare)

let load repository ~namespace root =
  read repository ~namespace root |> Result.map fst

let closure repository ~namespace root =
  read repository ~namespace root |> Result.map snd
