module Encoding = Yeokcham_encoding
module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

type provider =
  | Ssh_agent of { public_key : string }
  | Pkcs11 of {
      module_path : string;
      token_label : string;
      key_id : string;
      public_key : string;
    }

type profile = { device : Model.Device_id.t; provider : provider }

type error =
  | Profile_missing
  | Profile_exists
  | Invalid_profile of string
  | Io_error of { path : string; operation : string; message : string }
  | Ssh_agent_unavailable of string
  | Ssh_agent_key_missing
  | Ssh_agent_protocol of string
  | Pkcs11_unavailable of string
  | Pkcs11_key_missing
  | Pkcs11_locked
  | Pkcs11_unsupported of string
  | Public_key_mismatch
  | Trust_error of Trust.error

let ( let* ) = Result.bind
let schema_version = 1L
let directory_name = "custody-v1"

let error_to_string = function
  | Profile_missing -> "V4 local custody profile is missing"
  | Profile_exists -> "V4 local custody profile already exists"
  | Invalid_profile detail -> "invalid V4 local custody profile: " ^ detail
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 custody %s %s: %s" operation path message
  | Ssh_agent_unavailable detail -> "V4 SSH agent is unavailable: " ^ detail
  | Ssh_agent_key_missing -> "configured V4 SSH agent key is unavailable"
  | Ssh_agent_protocol detail -> "invalid SSH agent response: " ^ detail
  | Pkcs11_unavailable detail -> "V4 PKCS#11 provider is unavailable: " ^ detail
  | Pkcs11_key_missing -> "configured V4 PKCS#11 key is unavailable"
  | Pkcs11_locked -> "V4 PKCS#11 token is locked or denied signing"
  | Pkcs11_unsupported detail -> "unsupported V4 PKCS#11 capability: " ^ detail
  | Public_key_mismatch -> "custody provider public key does not match device"
  | Trust_error error -> Trust.error_to_string error

let profile_directory root = Filename.concat (Filename.concat root ".yeokcham") directory_name

let profile_path ~root device =
  Filename.concat (profile_directory root)
    (Model.Device_id.to_string device ^ ".cbor")

let configured ~root device = Sys.file_exists (profile_path ~root device)

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
         Invalid_profile (Encoding.construction_error_to_string error))

let bytes value = Ok (Encoding.bytes value)

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
         Invalid_profile (Encoding.construction_error_to_string error))

let provider_public_key = function
  | Ssh_agent { public_key } | Pkcs11 { public_key; _ } -> public_key

let valid_plain value =
  String.length value > 0
  && not
       (String.exists
          (function '\000' | '\r' | '\n' -> true | _ -> false)
          value)

let encode_provider = function
  | Ssh_agent { public_key } ->
      let* public_key = bytes public_key in
      array [ Encoding.integer 1L; public_key ]
  | Pkcs11 { module_path; token_label; key_id; public_key } ->
      let* module_path = text module_path in
      let* token_label = text token_label in
      let* key_id = bytes key_id in
      let* public_key = bytes public_key in
      array [ Encoding.integer 2L; module_path; token_label; key_id; public_key ]

let encode profile =
  let* device = text (Model.Device_id.to_string profile.device) in
  let* provider = encode_provider profile.provider in
  array [ Encoding.integer schema_version; device; provider ]
  |> Result.map Encoding.encode

let array_fields name = function
  | Encoding.Array fields -> Ok fields
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_profile (name ^ " must be an array"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_profile (name ^ " must be an integer"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_profile (name ^ " must be text"))

let bytes_field name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_profile (name ^ " must be bytes"))

let decode_provider = function
  | Encoding.Array [ tag; Encoding.Bytes public_key ] ->
      let* tag = integer_field "provider tag" tag in
      if Int64.equal tag 1L && String.length public_key = 32 then
        Ok (Ssh_agent { public_key })
      else Error (Invalid_profile "invalid SSH agent provider")
  | Encoding.Array [ tag; module_path; token_label; key_id; public_key ] ->
      let* tag = integer_field "provider tag" tag in
      let* module_path = text_field "PKCS#11 module" module_path in
      let* token_label = text_field "PKCS#11 token label" token_label in
      let* key_id = bytes_field "PKCS#11 key ID" key_id in
      let* public_key = bytes_field "PKCS#11 public key" public_key in
      if
        Int64.equal tag 2L
        && Filename.is_relative module_path |> not
        && valid_plain token_label
        && String.length key_id > 0
        && String.length public_key = 32
      then Ok (Pkcs11 { module_path; token_label; key_id; public_key })
      else Error (Invalid_profile "invalid PKCS#11 provider")
  | Encoding.Array _ | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
  | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_profile "provider has the wrong field count")

let decode bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
           Invalid_profile (Encoding.decode_error_to_string error))
  in
  let* fields = array_fields "custody profile" value in
  match fields with
  | [ version; device; provider ] ->
      let* version = integer_field "custody profile version" version in
      if not (Int64.equal version schema_version) then
        Error (Invalid_profile "unsupported profile version")
      else
        let* device = text_field "device" device in
        let* device =
          Model.Device_id.of_string device
          |> Result.map_error (fun _ -> Invalid_profile "invalid device ID")
        in
        let* provider = decode_provider provider in
        let* actual =
          Trust.device_of_public_key (provider_public_key provider)
          |> Result.map_error (fun error -> Trust_error error)
        in
        if not (Model.Device_id.equal device (Trust.device_id actual)) then
          Error Public_key_mismatch
        else
          let profile = { device; provider } in
          let* canonical = encode profile in
          if String.equal canonical bytes then Ok profile
          else Error (Invalid_profile "profile is not canonical")
  | _ -> Error (Invalid_profile "profile has the wrong field count")

let write_all descriptor path bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count = Unix.write_substring descriptor bytes offset (String.length bytes - offset) in
        if count = 0 then
          Error (Io_error { path; operation = "write"; message = "write returned zero" })
        else loop (offset + count)
      with Unix.Unix_error (error, operation, _) ->
        Error
          (Io_error
             { path; operation; message = Unix.error_message error })
  in
  loop 0

let save ~root profile =
  let* actual =
    Trust.device_of_public_key (provider_public_key profile.provider)
    |> Result.map_error (fun error -> Trust_error error)
  in
  if not (Model.Device_id.equal profile.device (Trust.device_id actual)) then
    Error Public_key_mismatch
  else
    let* contents = encode profile in
    let directory = profile_directory root in
    let target = profile_path ~root profile.device in
    try
      if not (Sys.file_exists directory) then Unix.mkdir directory 0o700;
      if Sys.file_exists target then Error Profile_exists
      else
        let temporary = Filename.temp_file ~temp_dir:directory ".custody-" ".tmp" in
        let descriptor = Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
        let result =
          Fun.protect
            ~finally:(fun () -> try Unix.close descriptor with Unix.Unix_error _ -> ())
            (fun () -> write_all descriptor temporary contents)
        in
        match result with
        | Error error ->
            (try Unix.unlink temporary with Unix.Unix_error _ -> ());
            Error error
        | Ok () ->
            Unix.rename temporary target;
            Ok ()
    with Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path = target; operation; message = Unix.error_message error })

let find ~root device =
  let target = profile_path ~root device in
  try
    if not (Sys.file_exists target) then Error Profile_missing
    else
      let info = Unix.lstat target in
      if info.Unix.st_kind <> Unix.S_REG then
        Error (Invalid_profile "profile path is not a regular file")
      else
        let* profile = In_channel.with_open_bin target In_channel.input_all |> decode in
        if Model.Device_id.equal profile.device device then Ok profile
        else Error Public_key_mismatch
  with
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path = target; operation; message = Unix.error_message error })
  | Sys_error message -> Error (Io_error { path = target; operation = "read"; message })

let inspect = find

let u32 value =
  if value < 0 || value > 0x3fff_ffff then invalid_arg "u32";
  let bytes = Bytes.create 4 in
  Bytes.set bytes 0 (Char.chr (value lsr 24));
  Bytes.set bytes 1 (Char.chr ((value lsr 16) land 255));
  Bytes.set bytes 2 (Char.chr ((value lsr 8) land 255));
  Bytes.set bytes 3 (Char.chr (value land 255));
  Bytes.unsafe_to_string bytes

let read_u32 bytes offset =
  if offset < 0 || offset + 4 > String.length bytes then None
  else
    let byte index = Char.code bytes.[offset + index] in
    Some ((byte 0 lsl 24) lor (byte 1 lsl 16) lor (byte 2 lsl 8) lor byte 3)

let ssh_string value = u32 (String.length value) ^ value

let rec write_all_socket descriptor bytes offset =
  if offset = String.length bytes then Ok ()
  else
    try
      let count = Unix.write_substring descriptor bytes offset (String.length bytes - offset) in
      if count = 0 then Error (Ssh_agent_unavailable "socket write returned zero")
      else write_all_socket descriptor bytes (offset + count)
    with Unix.Unix_error (error, _, _) -> Error (Ssh_agent_unavailable (Unix.error_message error))

let read_exact descriptor length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset = length then Ok (Bytes.unsafe_to_string bytes)
    else
      try
        let count = Unix.read descriptor bytes offset (length - offset) in
        if count = 0 then Error (Ssh_agent_unavailable "socket closed")
        else loop (offset + count)
      with Unix.Unix_error (error, _, _) -> Error (Ssh_agent_unavailable (Unix.error_message error))
  in
  loop 0

let agent_request payload =
  match Sys.getenv_opt "SSH_AUTH_SOCK" with
  | None -> Error (Ssh_agent_unavailable "SSH_AUTH_SOCK is unset")
  | Some socket_path ->
      if String.length socket_path = 0 then Error (Ssh_agent_unavailable "SSH_AUTH_SOCK is empty")
      else
        let descriptor = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
        Fun.protect
          ~finally:(fun () -> try Unix.close descriptor with Unix.Unix_error _ -> ())
          (fun () ->
            try
              Unix.connect descriptor (Unix.ADDR_UNIX socket_path);
              let* () = write_all_socket descriptor (u32 (String.length payload) ^ payload) 0 in
              let* length_bytes = read_exact descriptor 4 in
              match read_u32 length_bytes 0 with
              | None -> Error (Ssh_agent_protocol "invalid response length")
              | Some length when length <= 0 || length > 1_048_576 ->
                  Error (Ssh_agent_protocol "response exceeds limit")
              | Some length -> read_exact descriptor length
            with Unix.Unix_error (error, _, _) ->
              Error (Ssh_agent_unavailable (Unix.error_message error)))

let read_ssh_string bytes offset =
  match read_u32 bytes offset with
  | None -> None
  | Some length when length < 0 || offset + 4 + length > String.length bytes -> None
  | Some length ->
      Some (String.sub bytes (offset + 4) length, offset + 4 + length)

let agent_identities () =
  let* payload = agent_request "\011" in
  if String.length payload < 5 || Char.code payload.[0] <> 12 then
    Error (Ssh_agent_protocol "expected identity list")
  else
    match read_u32 payload 1 with
    | None -> Error (Ssh_agent_protocol "invalid identity count")
    | Some count when count > 1024 ->
        Error (Ssh_agent_protocol "invalid identity count")
    | Some count ->
        let rec loop index offset reversed =
          if index = count then
            if offset = String.length payload then Ok (List.rev reversed)
            else Error (Ssh_agent_protocol "trailing identity bytes")
          else
            match read_ssh_string payload offset with
            | None -> Error (Ssh_agent_protocol "invalid identity key")
            | Some (key, offset) -> (
                match read_ssh_string payload offset with
                | None -> Error (Ssh_agent_protocol "invalid identity comment")
                | Some (_, offset) -> loop (index + 1) offset (key :: reversed))
        in
        loop 0 5 []

let raw_ed25519_public_key ssh_key =
  match read_ssh_string ssh_key 0 with
  | Some (algorithm, offset) when String.equal algorithm "ssh-ed25519" -> (
      match read_ssh_string ssh_key offset with
      | Some (public_key, end_offset)
        when end_offset = String.length ssh_key && String.length public_key = 32 ->
          Ok public_key
      | _ -> Error (Ssh_agent_protocol "invalid Ed25519 public key"))
  | _ -> Error (Ssh_agent_protocol "key is not ssh-ed25519")

let ssh_agent_available ~public_key =
  let* identities = agent_identities () in
  let rec find = function
    | [] -> Error Ssh_agent_key_missing
    | identity :: rest -> (
        match raw_ed25519_public_key identity with
        | Ok candidate when String.equal candidate public_key -> Ok ()
        | Ok _ | Error _ -> find rest)
  in
  find identities

let agent_sign ~public_key ~domain bytes =
  let* identities = agent_identities () in
  let rec select = function
    | [] -> Error Ssh_agent_key_missing
    | identity :: rest -> (
        match raw_ed25519_public_key identity with
        | Ok candidate when String.equal candidate public_key -> Ok identity
        | Ok _ | Error _ -> select rest)
  in
  let* identity = select identities in
  let payload = "\013" ^ ssh_string identity ^ ssh_string (domain ^ bytes) ^ u32 0 in
  let* response = agent_request payload in
  if String.length response < 1 || Char.code response.[0] <> 14 then
    Error (Ssh_agent_protocol "agent refused signing")
  else
    match read_ssh_string response 1 with
    | Some (signature, end_offset) when end_offset = String.length response -> (
        match read_ssh_string signature 0 with
        | Some (algorithm, offset) when String.equal algorithm "ssh-ed25519" -> (
            match read_ssh_string signature offset with
            | Some (signature, end_offset)
              when end_offset = String.length signature
                   && String.length signature = 64 -> Ok signature
            | _ -> Error (Ssh_agent_protocol "invalid Ed25519 signature"))
        | _ -> Error (Ssh_agent_protocol "unexpected signature algorithm"))
    | _ -> Error (Ssh_agent_protocol "invalid signature response")

let base64_value character =
  match character with
  | 'A' .. 'Z' -> Some (Char.code character - Char.code 'A')
  | 'a' .. 'z' -> Some (26 + Char.code character - Char.code 'a')
  | '0' .. '9' -> Some (52 + Char.code character - Char.code '0')
  | '+' -> Some 62
  | '/' -> Some 63
  | '=' -> Some (-1)
  | _ -> None

let decode_base64 input =
  if String.length input = 0 || String.length input mod 4 <> 0 then
    Error (Invalid_profile "invalid SSH public-key base64")
  else
    let output = Buffer.create ((String.length input / 4) * 3) in
    let rec loop offset =
      if offset = String.length input then Ok (Buffer.contents output)
      else
        match
          ( base64_value input.[offset],
            base64_value input.[offset + 1],
            base64_value input.[offset + 2],
            base64_value input.[offset + 3] )
        with
        | Some first, Some second, Some third, Some fourth
          when first >= 0 && second >= 0 && third >= -1 && fourth >= -1 ->
            if third = -1 && fourth <> -1 then
              Error (Invalid_profile "invalid SSH public-key base64 padding")
            else if (third = -1 || fourth = -1) && offset + 4 <> String.length input then
              Error (Invalid_profile "invalid SSH public-key base64 padding")
            else (
              Buffer.add_char output (Char.chr ((first lsl 2) lor (second lsr 4)));
              if third >= 0 then
                Buffer.add_char output
                  (Char.chr (((second land 15) lsl 4) lor (third lsr 2)));
              if fourth >= 0 then
                Buffer.add_char output
                  (Char.chr (((third land 3) lsl 6) lor fourth));
              loop (offset + 4))
        | _ -> Error (Invalid_profile "invalid SSH public-key base64")
    in
    loop 0

let ssh_public_key_file path =
  try
    let fields = In_channel.with_open_bin path In_channel.input_all |> String.split_on_char ' ' in
    match List.filter (fun value -> String.length value > 0) fields with
    | "ssh-ed25519" :: encoded :: _ ->
        let* wire = decode_base64 encoded in
        raw_ed25519_public_key wire
    | _ -> Error (Invalid_profile "public key must be one ssh-ed25519 line")
  with Sys_error message -> Error (Io_error { path; operation = "read"; message })

let attach_ssh_agent ~root ~public_key =
  let* () = ssh_agent_available ~public_key in
  let* device =
    Trust.device_of_public_key public_key
    |> Result.map_error (fun error -> Trust_error error)
  in
  let profile = { device = Trust.device_id device; provider = Ssh_agent { public_key } } in
  let* () = save ~root profile in
  Ok profile.device

external pkcs11_public_raw : string -> string -> string -> int * string option
  = "caml_yeokcham_v4_pkcs11_public"

external pkcs11_sign_raw :
  string -> string -> string -> string -> string -> int * string option
  = "caml_yeokcham_v4_pkcs11_sign"

external pkcs11_create_raw :
  string -> string -> string -> string -> string -> int * string option
  = "caml_yeokcham_v4_pkcs11_create"

let pkcs11_result = function
  | 0, Some bytes -> Ok bytes
  | 1, _ -> Error (Pkcs11_unavailable "module or token could not be opened")
  | 2, _ -> Error Pkcs11_key_missing
  | 3, _ -> Error Pkcs11_locked
  | 4, _ -> Error (Pkcs11_unsupported "token does not support Ed25519 signing")
  | 5, _ -> Error (Pkcs11_unsupported "token returned invalid Ed25519 bytes")
  | _, _ -> Error (Pkcs11_unavailable "unknown provider status")

let pkcs11_public_key ~module_path ~token_label ~key_id =
  let* public_key = pkcs11_public_raw module_path token_label key_id |> pkcs11_result in
  if String.length public_key = 32 then Ok public_key
  else Error (Pkcs11_unsupported "public key does not contain 32 bytes")

let attach_pkcs11 ~root ~module_path ~token_label ~key_id ~public_key =
  if Filename.is_relative module_path || not (valid_plain token_label) || String.length key_id = 0 then
    Error (Invalid_profile "invalid PKCS#11 selector")
  else
    let* discovered = pkcs11_public_key ~module_path ~token_label ~key_id in
    if not (String.equal discovered public_key) then Error Public_key_mismatch
    else
    let* device =
      Trust.device_of_public_key public_key
      |> Result.map_error (fun error -> Trust_error error)
    in
    let profile =
      {
        device = Trust.device_id device;
        provider = Pkcs11 { module_path; token_label; key_id; public_key };
      }
    in
    let* () = save ~root profile in
    Ok profile.device

let read_pin () =
  let path = "/dev/tty" in
  try
    let descriptor = Unix.openfile path [ Unix.O_RDWR ] 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        let attributes = Unix.tcgetattr descriptor in
        let noecho = { attributes with Unix.c_echo = false } in
        Unix.tcsetattr descriptor Unix.TCSADRAIN noecho;
        Fun.protect
          ~finally:(fun () ->
            Unix.tcsetattr descriptor Unix.TCSADRAIN attributes)
          (fun () ->
            ignore (Unix.write_substring descriptor "PKCS#11 PIN: " 0 13);
            let byte = Bytes.create 1 in
            let value = Buffer.create 32 in
            let rec loop () =
              match Unix.read descriptor byte 0 1 with
              | 0 -> Error (Pkcs11_unavailable "controlling terminal closed")
              | _ ->
                  let character = Bytes.get byte 0 in
                  if character = '\n' || character = '\r' then (
                    ignore (Unix.write_substring descriptor "\n" 0 1);
                    if Buffer.length value = 0 then Error Pkcs11_locked
                    else Ok (Buffer.contents value))
                  else (
                    Buffer.add_char value character;
                    loop ())
            in
            loop ()))
  with Unix.Unix_error (error, _, _) ->
    Error (Pkcs11_unavailable ("cannot read controlling terminal: " ^ Unix.error_message error))

let create_pkcs11 ~root ~module_path ~token_label ~key_label ~key_id =
  if
    Filename.is_relative module_path || not (valid_plain token_label)
    || not (valid_plain key_label) || String.length key_id = 0
  then Error (Invalid_profile "invalid PKCS#11 creation selector")
  else
    let* pin = read_pin () in
    let* public_key =
      pkcs11_create_raw module_path token_label key_id key_label pin
      |> pkcs11_result
    in
    if String.length public_key <> 32 then
      Error (Pkcs11_unsupported "token generated an invalid Ed25519 public key")
    else
      attach_pkcs11 ~root ~module_path ~token_label ~key_id ~public_key

let signed_result ~public_key ~domain bytes result =
  let* signature = result in
  let* device =
    Trust.device_of_public_key public_key
    |> Result.map_error (fun error -> Trust_error error)
  in
  Trust.verify_detached ~device ~domain ~signature bytes
  |> Result.map_error (fun error -> Trust_error error)
  |> Result.map (fun () -> signature)

let load_with_pin ~root ~pin device =
  let* profile = find ~root device in
  let* capability =
    match profile.provider with
    | Ssh_agent { public_key } ->
        Trust.signing_capability_of_external_signer ~public_key
          ~sign:(fun ~domain bytes ->
            signed_result ~public_key ~domain bytes
              (agent_sign ~public_key ~domain bytes)
            |> Result.map_error error_to_string)
        |> Result.map_error (fun error -> Trust_error error)
    | Pkcs11 { module_path; token_label; key_id; public_key } ->
        Trust.signing_capability_of_external_signer ~public_key
          ~sign:(fun ~domain bytes ->
            signed_result ~public_key ~domain bytes
              (pkcs11_sign_raw module_path token_label key_id pin (domain ^ bytes)
              |> pkcs11_result)
            |> Result.map_error error_to_string)
        |> Result.map_error (fun error -> Trust_error error)
  in
  let* actual =
    Trust.device_of_public_key (Trust.signing_public_key capability)
    |> Result.map_error (fun error -> Trust_error error)
  in
  if Model.Device_id.equal device (Trust.device_id actual) then Ok capability
  else Error Public_key_mismatch

let load ~root device =
  let* profile = find ~root device in
  match profile.provider with
  | Ssh_agent _ -> load_with_pin ~root ~pin:"" device
  | Pkcs11 _ ->
      let* pin = read_pin () in
      load_with_pin ~root ~pin device
