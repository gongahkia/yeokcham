module Encoding = Yeokcham_encoding
module Transport = Yeokcham_v4_transport

type remote = { name : string; url : string }

type error =
  | Invalid_url of string
  | Duplicate_remote of string
  | Unknown_remote of string
  | Io_error of { path : string; operation : string; message : string }
  | Encoding_error of string

let file_name = "transport-remotes-v1.cbor"
let schema_version = 1L
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_url url -> "invalid V4 transport HTTPS URL: " ^ url
  | Duplicate_remote name -> "V4 transport remote already exists: " ^ name
  | Unknown_remote name -> "unknown V4 transport remote: " ^ name
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 transport config %s %s: %s" operation path message
  | Encoding_error detail -> "invalid V4 transport config: " ^ detail

let path ~root = Filename.concat (Filename.concat root ".yeokcham") file_name

let valid_url url =
  String.starts_with ~prefix:"https://" url
  && String.length url > String.length "https://"
  && not (String.exists (function '\000' | '\r' | '\n' | ' ' | '\t' -> true | _ -> false) url)
  && not (String.exists (fun character -> character = '@' || character = '?' || character = '#') url)

let text value =
  Encoding.text value
  |> Result.map_error (fun error -> Encoding_error (Encoding.construction_error_to_string error))

let array values =
  Encoding.array values
  |> Result.map_error (fun error -> Encoding_error (Encoding.construction_error_to_string error))

let encode_remote remote =
  let* name = text remote.name in
  let* url = text remote.url in
  array [ name; url ]

let encode remotes =
  let rec loop reversed = function
    | [] -> array (List.rev reversed)
    | remote :: rest ->
        let* remote = encode_remote remote in
        loop (remote :: reversed) rest
  in
  let* remotes = loop [] remotes in
  array [ Encoding.integer schema_version; remotes ] |> Result.map Encoding.encode

let array_values name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Encoding_error (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Encoding_error (name ^ " must be text"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null -> Error (Encoding_error (name ^ " must be an integer"))

let decode_remote value =
  let* fields = array_values "remote" value in
  match fields with
  | [ name; url ] ->
      let* name = text_field "remote name" name in
      let* () =
        Transport.remote_state ~name ~cursor:None ~known:[]
          ~announced_manifests:[] ~announced_revisions:[] ~review_inbox:[]
        |> Result.map_error (fun error -> Encoding_error (Transport.error_to_string error))
        |> Result.map (fun _ -> ())
      in
      let* url = text_field "remote URL" url in
      if valid_url url then Ok { name; url } else Error (Invalid_url url)
  | _ -> Error (Encoding_error "remote has the wrong field count")

let decode bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error -> Encoding_error (Encoding.decode_error_to_string error))
  in
  let* fields = array_values "transport config" value in
  match fields with
  | [ version; remotes ] ->
      let* version = integer_field "transport config version" version in
      if not (Int64.equal version schema_version) then Error (Encoding_error "unsupported config version")
      else
        let* remotes = array_values "transport remotes" remotes in
        let rec loop reversed = function
          | [] -> Ok (List.rev reversed)
          | remote :: rest ->
              let* remote = decode_remote remote in
              loop (remote :: reversed) rest
        in
        let* remotes = loop [] remotes in
        let sorted = List.sort (fun left right -> String.compare left.name right.name) remotes in
        let unique =
          List.length sorted
          = List.length (List.sort_uniq (fun left right -> String.compare left.name right.name) sorted)
        in
        if not unique || remotes <> sorted then Error (Encoding_error "remotes must be sorted and unique")
        else
          let* canonical = encode remotes in
          if String.equal canonical bytes then Ok remotes else Error (Encoding_error "config is not canonical")
  | _ -> Error (Encoding_error "config has the wrong field count")

let read_config ~root =
  let target = path ~root in
  try
    if Sys.file_exists target then In_channel.with_open_bin target In_channel.input_all |> decode
    else Ok []
  with Sys_error message -> Error (Io_error { path = target; operation = "read"; message })

let write_all descriptor target bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count = Unix.write_substring descriptor bytes offset (String.length bytes - offset) in
        if count = 0 then Error (Io_error { path = target; operation = "write"; message = "write returned zero" })
        else loop (offset + count)
      with Unix.Unix_error (error, operation, _) ->
        Error (Io_error { path = target; operation; message = Unix.error_message error })
  in
  loop 0

let write_config ~root remotes =
  let* bytes = encode remotes in
  let target = path ~root in
  let directory = Filename.dirname target in
  if not (Sys.file_exists directory) then
    Error (Io_error { path = directory; operation = "open"; message = "repository metadata directory is absent" })
  else
    let temporary = Filename.temp_file ~temp_dir:directory ".transport-remotes-" ".tmp" in
    try
      let descriptor = Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let result =
        Fun.protect
          ~finally:(fun () -> try Unix.close descriptor with Unix.Unix_error _ -> ())
          (fun () -> write_all descriptor temporary bytes)
      in
      (match result with
      | Error error ->
          (try Unix.unlink temporary with Unix.Unix_error _ -> ());
          Error error
      | Ok () ->
          Unix.rename temporary target;
          Ok ())
    with Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path = target; operation; message = Unix.error_message error })

let list ~root = read_config ~root

let find ~root ~name =
  let* remotes = read_config ~root in
  match List.find_opt (fun remote -> String.equal remote.name name) remotes with
  | Some remote -> Ok remote
  | None -> Error (Unknown_remote name)

let add ~root ~name ~url =
  if not (valid_url url) then Error (Invalid_url url)
  else
    let* state =
      Transport.remote_state ~name ~cursor:None ~known:[] ~announced_manifests:[]
        ~announced_revisions:[] ~review_inbox:[]
      |> Result.map_error (fun error -> Encoding_error (Transport.error_to_string error))
    in
    ignore state;
    let* remotes = read_config ~root in
    if List.exists (fun remote -> String.equal remote.name name) remotes then
      Error (Duplicate_remote name)
    else
      let remotes = List.sort (fun left right -> String.compare left.name right.name) ({ name; url } :: remotes) in
      write_config ~root remotes

let remove ~root ~name =
  let* remotes = read_config ~root in
  if not (List.exists (fun remote -> String.equal remote.name name) remotes) then Error (Unknown_remote name)
  else write_config ~root (List.filter (fun remote -> not (String.equal remote.name name)) remotes)
