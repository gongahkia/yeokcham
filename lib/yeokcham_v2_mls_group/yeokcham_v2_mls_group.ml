module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Hash = Yeokcham_hash.Sha256
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type t = {
  state_repository_id : Model.Repository_id.t;
  state_group_id : Model.Mls_group_id.t;
  state_device_id : Model.Device_id.t;
  state_runtime_bytes : string;
  state_mandatory_features : int64;
}

type error =
  | Invalid_runtime_state of string
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_state
  | Group_binding_mismatch of string
  | Runtime_error of Runtime.error
  | Envelope_error of Envelope.error
  | Entropy_failure

let current_schema_version = 1L
let supported_mandatory_features = 0L
let metadata_plaintext_limit = 48 * 1024
let group_id_domain = "yeokcham:v2:mls-group:1\000"
let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_runtime_state detail -> "invalid MLS runtime state: " ^ detail
  | Invalid_payload detail -> "invalid V2 MLS group state: " ^ detail
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported MLS group state schema version: %Ld" version
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid MLS group state mandatory feature bits: %Ld"
        features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported MLS group state mandatory feature bits: %Ld"
        features
  | Noncanonical_state -> "MLS group state bytes are noncanonical"
  | Group_binding_mismatch detail ->
      "MLS group state binding mismatch: " ^ detail
  | Runtime_error error -> Runtime.error_to_string error
  | Envelope_error error -> Envelope.error_to_string error
  | Entropy_failure -> "OS CSPRNG unavailable while encrypting MLS state"

let digest domain bytes =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context bytes |> Hash.get |> Hash.to_raw_string

let group_id_for_repository repository_id =
  digest group_id_domain (Model.Repository_id.to_bytes repository_id)
  |> Model.Mls_group_id.of_bytes
  |> function
  | Ok group_id -> group_id
  | Error _ -> assert false

let check_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let check_runtime_state state =
  let length = String.length state in
  if length = 0 then Error (Invalid_runtime_state "must not be empty")
  else if length > Runtime.max_runtime_state_bytes then
    Error
      (Invalid_runtime_state
         (Printf.sprintf "exceeds %d bytes" Runtime.max_runtime_state_bytes))
  else Ok ()

let value_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let fields name count = function
  | Encoding.Array values when List.length values = count -> Ok values
  | Encoding.Array _ ->
      Error (Invalid_payload (Printf.sprintf "%s has wrong field count" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be an integer"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Invalid_payload (name ^ " must be bytes"))

let state_value state =
  value_array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Model.Repository_id.to_bytes state.state_repository_id);
      Encoding.bytes (Model.Mls_group_id.to_bytes state.state_group_id);
      Encoding.bytes (Model.Device_id.to_bytes state.state_device_id);
      Encoding.bytes state.state_runtime_bytes;
      Encoding.integer state.state_mandatory_features;
    ]

let encode state =
  match state_value state with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let make ~repository_id ~group_id ~device_id ~runtime_state ~mandatory_features
    =
  let* () = check_features mandatory_features in
  let* () = check_runtime_state runtime_state in
  if
    not
      (Model.Mls_group_id.equal group_id
         (group_id_for_repository repository_id))
  then Error (Group_binding_mismatch "repository-derived group ID")
  else
    Ok
      {
        state_repository_id = repository_id;
        state_group_id = group_id;
        state_device_id = device_id;
        state_runtime_bytes = runtime_state;
        state_mandatory_features = mandatory_features;
      }

let create ~runtime ~repository_id ~device_id =
  let group_id = group_id_for_repository repository_id in
  let* runtime_state =
    Runtime.bootstrap runtime ~group_id ~device_id
    |> Result.map_error (fun error -> Runtime_error error)
  in
  make ~repository_id ~group_id ~device_id ~runtime_state ~mandatory_features:0L

let decode encoded =
  let* value =
    Encoding.decode encoded
    |> Result.map_error (fun error ->
        Invalid_payload (Encoding.decode_error_to_string error))
  in
  let* values = fields "MLS group state" 6 value in
  match values with
  | [ version; repository; group; device; runtime_state; features ] ->
      let* version = integer "MLS group state version" version in
      if not (Int64.equal version current_schema_version) then
        Error (Unsupported_schema_version version)
      else
        let* repository = bytes "MLS group repository ID" repository in
        let* repository_id =
          Model.Repository_id.of_bytes repository
          |> Result.map_error (fun error ->
              Invalid_payload (Model.identity_error_to_string error))
        in
        let* group = bytes "MLS group ID" group in
        let* group_id =
          Model.Mls_group_id.of_bytes group
          |> Result.map_error (fun error ->
              Invalid_payload (Model.identity_error_to_string error))
        in
        let* device = bytes "MLS group device ID" device in
        let* device_id =
          Model.Device_id.of_bytes device
          |> Result.map_error (fun error ->
              Invalid_payload (Model.identity_error_to_string error))
        in
        let* runtime_state = bytes "MLS runtime state" runtime_state in
        let* features = integer "MLS group mandatory features" features in
        let* state =
          make ~repository_id ~group_id ~device_id ~runtime_state
            ~mandatory_features:features
        in
        if String.equal encoded (encode state) then Ok state
        else Error Noncanonical_state
  | _ -> assert false

let repository_id state = state.state_repository_id
let device_id state = state.state_device_id
let group_id state = state.state_group_id

let seal_state ~key ~nonce state =
  Envelope.seal ~key ~nonce ~mandatory_features:state.state_mandatory_features
    (encode state)
  |> Result.map_error (fun error -> Envelope_error error)

let open_state ~key envelope =
  let* plaintext =
    Envelope.open_envelope ~key envelope
    |> Result.map_error (fun error -> Envelope_error error)
  in
  let* state = decode plaintext in
  if
    not
      (Int64.equal
         (Envelope.mandatory_features envelope)
         state.state_mandatory_features)
  then Error (Group_binding_mismatch "envelope mandatory features")
  else Ok state

let metadata_key ~runtime state =
  Runtime.derive_metadata_key runtime ~group_id:state.state_group_id
    ~device_id:state.state_device_id ~runtime_state:state.state_runtime_bytes
  |> Result.map_error (fun error -> Runtime_error error)

let verify ~runtime state =
  metadata_key ~runtime state |> Result.map (fun _ -> ())

let encrypt_metadata ~runtime ~state ~nonce plaintext =
  if String.length plaintext > metadata_plaintext_limit then
    Error (Invalid_payload "metadata plaintext exceeds IPC payload bound")
  else
    let* key = metadata_key ~runtime state in
    Envelope.seal ~key ~nonce ~mandatory_features:state.state_mandatory_features
      plaintext
    |> Result.map_error (fun error -> Envelope_error error)

let decrypt_metadata ~runtime ~state envelope =
  let* key = metadata_key ~runtime state in
  Envelope.open_envelope ~key envelope
  |> Result.map_error (fun error -> Envelope_error error)
