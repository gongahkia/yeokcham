module Encoding = Yeokcham_encoding
module Hash = Yeokcham_hash.Sha256

type scope = Read | Write
type status = Active | Revoked

type credential = {
  credential_id : string;
  repository : string;
  scopes : scope list;
  issued_at : int64;
  expires_at : int64;
  status : status;
  revoked_at : int64 option;
}

type registry = { credentials_value : credential list }

type grant = {
  grant_credential_id : string;
  grant_secret : string;
  grant_expires_at : int64;
}

type error =
  | Invalid_repository
  | Invalid_credential_id
  | Invalid_scope
  | Invalid_lifetime
  | Unknown_credential
  | Credential_inactive
  | Entropy_failure
  | Invalid_registry of string
  | Noncanonical_registry
  | Registry_too_large
  | Io_error of { path : string; operation : string; message : string }

type authorization_error =
  | Invalid_secret
  | Unknown_secret
  | Expired_secret
  | Revoked_secret
  | Wrong_repository
  | Insufficient_scope

let schema_version = 1L
let seconds days = Int64.mul days 86_400L
let default_lifetime_seconds = seconds 30L
let max_lifetime_seconds = seconds 365L
let max_credentials = 4096
let max_registry_bytes = 1024 * 1024
let secret_prefix = "v4ra1_"
let registry_name = ".relay-access-v1.cbor"
let lock_name = ".relay-access-v1.lock"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_repository -> "invalid V4 relay access repository ID"
  | Invalid_credential_id -> "invalid V4 relay access credential ID"
  | Invalid_scope -> "invalid V4 relay access scope"
  | Invalid_lifetime -> "invalid V4 relay access lifetime"
  | Unknown_credential -> "unknown V4 relay access credential"
  | Credential_inactive -> "V4 relay access credential is inactive"
  | Entropy_failure -> "V4 relay access OS CSPRNG is unavailable"
  | Invalid_registry detail -> "invalid V4 relay access registry: " ^ detail
  | Noncanonical_registry -> "V4 relay access registry is not canonical"
  | Registry_too_large ->
      "V4 relay access registry exceeds its configured limit"
  | Io_error { path; operation; message } ->
      Printf.sprintf "V4 relay access %s %s: %s" operation path message

let authorization_error_to_string = function
  | Invalid_secret -> "invalid relay access secret"
  | Unknown_secret -> "unknown relay access secret"
  | Expired_secret -> "expired relay access secret"
  | Revoked_secret -> "revoked relay access secret"
  | Wrong_repository -> "relay access secret is not valid for this repository"
  | Insufficient_scope -> "relay access secret lacks this permission"

let scope_to_string = function Read -> "read" | Write -> "write"

let scopes_to_string scopes =
  scopes |> List.map scope_to_string |> String.concat ","

let credential_id (credential : credential) = credential.credential_id
let credential_repository (credential : credential) = credential.repository
let credential_scopes (credential : credential) = credential.scopes
let credential_issued_at (credential : credential) = credential.issued_at
let credential_expires_at (credential : credential) = credential.expires_at
let credential_status (credential : credential) = credential.status
let credential_revoked_at (credential : credential) = credential.revoked_at
let empty = { credentials_value = [] }
let credentials registry = registry.credentials_value

let valid_hex value =
  String.length value = 64
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       value

let valid_secret secret =
  String.length secret = String.length secret_prefix + 64
  && String.starts_with ~prefix:secret_prefix secret
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       (String.sub secret (String.length secret_prefix) 64)

let hex bytes =
  let alphabet = "0123456789abcdef" in
  String.init
    (String.length bytes * 2)
    (fun index ->
      let value = Char.code bytes.[index / 2] in
      if index mod 2 = 0 then alphabet.[value lsr 4]
      else alphabet.[value land 0x0f])

let verifier secret = Hash.digest_string secret |> Hash.to_raw_string |> hex
let scope_code = function Read -> 0L | Write -> 1L

let scope_of_code = function
  | 0L -> Ok Read
  | 1L -> Ok Write
  | _ -> Error Invalid_scope

let sorted_scopes scopes =
  List.sort_uniq
    (fun left right -> Int64.compare (scope_code left) (scope_code right))
    scopes

let valid_scopes scopes = scopes <> [] && scopes = sorted_scopes scopes

let text value =
  Encoding.text value
  |> Result.map_error (fun error ->
      Invalid_registry (Encoding.construction_error_to_string error))

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_registry (Encoding.construction_error_to_string error))

let encode_credential (credential : credential) =
  let* credential_id = text credential.credential_id in
  let* repository = text credential.repository in
  let* scopes =
    credential.scopes
    |> List.map (fun scope -> Encoding.integer (scope_code scope))
    |> array
  in
  let status =
    match credential.status with
    | Active -> Encoding.integer 0L
    | Revoked -> Encoding.integer 1L
  in
  let revoked_at =
    match credential.revoked_at with
    | None -> Encoding.null
    | Some value -> Encoding.integer value
  in
  array
    [
      credential_id;
      repository;
      scopes;
      Encoding.integer credential.issued_at;
      Encoding.integer credential.expires_at;
      status;
      revoked_at;
    ]

let encode registry =
  if List.length registry.credentials_value > max_credentials then
    Error Registry_too_large
  else
    let rec loop reversed = function
      | [] -> Ok (List.rev reversed)
      | credential :: rest ->
          let* encoded = encode_credential credential in
          loop (encoded :: reversed) rest
    in
    let* entries = loop [] registry.credentials_value in
    let* entries = array entries in
    array [ Encoding.integer schema_version; entries ]
    |> Result.map Encoding.encode

let exact_array name count = function
  | Encoding.Array values when List.length values = count -> Ok values
  | Encoding.Array _ ->
      Error (Invalid_registry (name ^ " has the wrong field count"))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_registry (name ^ " must be an array"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_registry (name ^ " must be text"))

let integer_field name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_registry (name ^ " must be an integer"))

let decode_scopes = function
  | Encoding.Array values ->
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* code = integer_field "credential scope" value in
            let* scope = scope_of_code code in
            loop (scope :: reversed) rest
      in
      let* scopes = loop [] values in
      if valid_scopes scopes then Ok scopes else Error Invalid_scope
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_registry "credential scopes must be an array")

let[@warning "-4"] decode_status = function
  | Encoding.Integer 0L -> Ok Active
  | Encoding.Integer 1L -> Ok Revoked
  | Encoding.Integer _ ->
      Error (Invalid_registry "credential status is unsupported")
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_registry "credential status must be an integer")

let decode_optional_integer name = function
  | Encoding.Null -> Ok None
  | Encoding.Integer value -> Ok (Some value)
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ ->
      Error (Invalid_registry (name ^ " must be an integer or null"))

let decode_credential value =
  let* fields = exact_array "credential" 7 value in
  match fields with
  | [
   credential_id; repository; scopes; issued_at; expires_at; status; revoked_at;
  ] ->
      let* credential_id = text_field "credential ID" credential_id in
      let* repository = text_field "credential repository" repository in
      let* scopes = decode_scopes scopes in
      let* issued_at = integer_field "credential issued time" issued_at in
      let* expires_at = integer_field "credential expiry time" expires_at in
      let* status = decode_status status in
      let* revoked_at =
        decode_optional_integer "credential revocation time" revoked_at
      in
      if not (valid_hex credential_id) then Error Invalid_credential_id
      else if not (valid_hex repository) then Error Invalid_repository
      else if Int64.compare expires_at issued_at <= 0 then
        Error (Invalid_registry "credential expiry must follow issuance")
      else
        let[@warning "-4"] valid_status =
          match (status, revoked_at) with
          | Active, None | Revoked, Some _ -> true
          | Active, Some _ | Revoked, None -> false
        in
        if valid_status then
          Ok
            {
              credential_id;
              repository;
              scopes;
              issued_at;
              expires_at;
              status;
              revoked_at;
            }
        else
          Error (Invalid_registry "credential status and revocation disagree")
  | _ -> Error (Invalid_registry "credential has the wrong field count")

let decode bytes =
  if String.length bytes > max_registry_bytes then Error Registry_too_large
  else
    let* value =
      Encoding.decode bytes
      |> Result.map_error (fun error ->
          Invalid_registry (Encoding.decode_error_to_string error))
    in
    let* fields = exact_array "registry" 2 value in
    match fields with
    | [ version; entries ] ->
        let* version = integer_field "registry version" version in
        if not (Int64.equal version schema_version) then
          Error (Invalid_registry "unsupported registry version")
        else
          let* entries =
            match entries with
            | Encoding.Array values -> Ok values
            | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
                Error (Invalid_registry "registry credentials must be an array")
          in
          let rec loop reversed = function
            | [] -> Ok (List.rev reversed)
            | entry :: rest ->
                let* credential = decode_credential entry in
                loop (credential :: reversed) rest
          in
          let* credentials_value = loop [] entries in
          if List.length credentials_value > max_credentials then
            Error Registry_too_large
          else
            let sorted =
              List.sort
                (fun left right ->
                  String.compare left.credential_id right.credential_id)
                credentials_value
            in
            let unique =
              List.length sorted
              = List.length
                  (List.sort_uniq
                     (fun left right ->
                       String.compare left.credential_id right.credential_id)
                     credentials_value)
            in
            if (not unique) || credentials_value <> sorted then
              Error (Invalid_registry "credentials must be sorted and unique")
            else
              let registry = { credentials_value } in
              let* canonical = encode registry in
              if String.equal canonical bytes then Ok registry
              else Error Noncanonical_registry
    | _ -> Error (Invalid_registry "registry has the wrong field count")

let valid_lifetime value =
  Int64.compare value 0L > 0 && Int64.compare value max_lifetime_seconds <= 0

let issue_with_secret ~now ~repository ~scopes ~expires_in ~secret registry =
  if not (valid_hex repository) then Error Invalid_repository
  else if not (valid_scopes scopes) then Error Invalid_scope
  else if not (valid_lifetime expires_in) then Error Invalid_lifetime
  else if not (valid_secret secret) then Error Entropy_failure
  else
    let credential_id = verifier secret in
    if
      List.exists
        (fun credential -> String.equal credential.credential_id credential_id)
        registry.credentials_value
    then Error Entropy_failure
    else if List.length registry.credentials_value >= max_credentials then
      Error Registry_too_large
    else
      let expires_at = Int64.add now expires_in in
      if Int64.compare expires_at now <= 0 then Error Invalid_lifetime
      else
        let credential =
          {
            credential_id;
            repository;
            scopes;
            issued_at = now;
            expires_at;
            status = Active;
            revoked_at = None;
          }
        in
        let credentials_value =
          List.sort
            (fun left right ->
              String.compare left.credential_id right.credential_id)
            (credential :: registry.credentials_value)
        in
        Ok
          ( { credentials_value },
            {
              grant_credential_id = credential_id;
              grant_secret = secret;
              grant_expires_at = expires_at;
            } )

let generate_secret () =
  try
    Mirage_crypto_rng_unix.use_default ();
    Ok (secret_prefix ^ hex (Mirage_crypto_rng.generate 32))
  with _ -> Error Entropy_failure

let issue ~now ~repository ~scopes ~expires_in registry =
  let* secret = generate_secret () in
  issue_with_secret ~now ~repository ~scopes ~expires_in ~secret registry

let find_credential credential_id registry =
  List.find_opt
    (fun credential -> String.equal credential.credential_id credential_id)
    registry.credentials_value

let revoke ~now ~credential_id registry =
  if not (valid_hex credential_id) then Error Invalid_credential_id
  else
    match find_credential credential_id registry with
    | None -> Error Unknown_credential
    | Some credential when credential.status = Revoked -> Ok registry
    | Some _ ->
        let credentials_value =
          List.map
            (fun credential ->
              if String.equal credential.credential_id credential_id then
                { credential with status = Revoked; revoked_at = Some now }
              else credential)
            registry.credentials_value
        in
        Ok { credentials_value }

let rotate ~now ~credential_id ~expires_in registry =
  if not (valid_hex credential_id) then Error Invalid_credential_id
  else
    match find_credential credential_id registry with
    | None -> Error Unknown_credential
    | Some credential when credential.status = Revoked ->
        Error Credential_inactive
    | Some credential ->
        let* revoked = revoke ~now ~credential_id registry in
        issue ~now ~repository:credential.repository ~scopes:credential.scopes
          ~expires_in revoked

let authorize_credential ~now ~secret ~repository ~scope registry =
  if not (valid_secret secret) then Error Invalid_secret
  else
    match find_credential (verifier secret) registry with
    | None -> Error Unknown_secret
    | Some credential when credential.status = Revoked -> Error Revoked_secret
    | Some credential when Int64.compare now credential.expires_at >= 0 ->
        Error Expired_secret
    | Some credential when not (String.equal repository credential.repository)
      ->
        Error Wrong_repository
    | Some credential when not (List.mem scope credential.scopes) ->
        Error Insufficient_scope
    | Some credential -> Ok credential

let authorize ~now ~secret ~repository ~scope registry =
  authorize_credential ~now ~secret ~repository ~scope registry
  |> Result.map (fun _ -> ())

let registry_path root = Filename.concat root registry_name
let lock_path root = Filename.concat root lock_name

let ensure_root root =
  if Sys.file_exists root then
    try
      if (Unix.lstat root).Unix.st_kind = Unix.S_DIR then Ok ()
      else
        Error
          (Io_error
             { path = root; operation = "open"; message = "not a directory" })
    with Unix.Unix_error (error, operation, _) ->
      Error
        (Io_error { path = root; operation; message = Unix.error_message error })
  else
    try
      Unix.mkdir root 0o700;
      Ok ()
    with Unix.Unix_error (error, operation, _) ->
      Error
        (Io_error { path = root; operation; message = Unix.error_message error })

let read_registry path =
  try
    let info = Unix.lstat path in
    if info.Unix.st_kind <> Unix.S_REG then
      Error (Invalid_registry "registry is not a regular file")
    else if info.Unix.st_size > max_registry_bytes then Error Registry_too_large
    else In_channel.with_open_bin path In_channel.input_all |> decode
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok empty
  | Unix.Unix_error (error, operation, _) ->
      Error (Io_error { path; operation; message = Unix.error_message error })
  | Sys_error message -> Error (Io_error { path; operation = "read"; message })

let load ~root =
  let* () = ensure_root root in
  read_registry (registry_path root)

let write_all descriptor path bytes =
  let rec loop offset =
    if offset = String.length bytes then Ok ()
    else
      try
        let count =
          Unix.write_substring descriptor bytes offset
            (String.length bytes - offset)
        in
        if count = 0 then
          Error
            (Io_error
               { path; operation = "write"; message = "write returned zero" })
        else loop (offset + count)
      with Unix.Unix_error (error, operation, _) ->
        Error (Io_error { path; operation; message = Unix.error_message error })
  in
  loop 0

let write_registry ~root registry =
  let* bytes = encode registry in
  let target = registry_path root in
  let temporary = Filename.temp_file ~temp_dir:root ".relay-access-" ".tmp" in
  try
    let descriptor =
      Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
    in
    let result =
      Fun.protect
        ~finally:(fun () ->
          try Unix.close descriptor with Unix.Unix_error _ -> ())
        (fun () ->
          let* () = write_all descriptor temporary bytes in
          try
            Unix.fsync descriptor;
            Ok ()
          with Unix.Unix_error (error, operation, _) ->
            Error
              (Io_error
                 {
                   path = temporary;
                   operation;
                   message = Unix.error_message error;
                 }))
    in
    match result with
    | Error error ->
        (try Unix.unlink temporary with Unix.Unix_error _ -> ());
        Error error
    | Ok () ->
        Unix.rename temporary target;
        Ok ()
  with Unix.Unix_error (error, operation, _) ->
    (try Unix.unlink temporary with Unix.Unix_error _ -> ());
    Error
      (Io_error { path = target; operation; message = Unix.error_message error })

let update ~root change =
  let* () = ensure_root root in
  let path = lock_path root in
  try
    let descriptor = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close descriptor with Unix.Unix_error _ -> ())
      (fun () ->
        try
          Unix.lockf descriptor Unix.F_LOCK 0;
          let* registry = read_registry (registry_path root) in
          let* next, value = change registry in
          let* () = write_registry ~root next in
          Ok value
        with Unix.Unix_error (error, operation, _) ->
          Error
            (Io_error { path; operation; message = Unix.error_message error }))
  with Unix.Unix_error (error, operation, _) ->
    Error (Io_error { path; operation; message = Unix.error_message error })
