module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Hash = Yeokcham_hash.Sha256
module Opaque_object_ref = Yeokcham_v2_model.Opaque_object_ref
module Repository_id = Yeokcham_v2_model.Repository_id
module Transaction_id = Yeokcham_v2_model.Transaction_id

type staged = { object_ref : Opaque_object_ref.t; envelope : Envelope.t }

type prepare = {
  repository_id : Repository_id.t;
  prepare_transaction : Transaction_id.t;
  mandatory_features : int64;
  staged : staged list;
}

type commit = { commit_transaction : Transaction_id.t; prepare_digest : string }

type journal_file =
  | Prepare_file of Transaction_id.t
  | Commit_file of Transaction_id.t

type error =
  | Empty_staged_objects
  | Too_many_staged_objects of int
  | Prepare_too_large of int
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_prepare_schema_version of int64
  | Unsupported_commit_schema_version of int64
  | Invalid_payload of string
  | Envelope_error of Envelope.error
  | Duplicate_object_ref of Opaque_object_ref.t
  | Noncanonical_object_ref_order of {
      previous : Opaque_object_ref.t;
      current : Opaque_object_ref.t;
    }
  | Noncanonical_prepare
  | Noncanonical_commit
  | Invalid_prepare_digest_length of int
  | Commit_transaction_mismatch of {
      commit : Transaction_id.t;
      prepare : Transaction_id.t;
    }
  | Commit_prepare_mismatch
  | Invalid_journal_filename of string

let current_schema_version = 1L
let supported_mandatory_features = 0L
let max_staged_objects = 64
let max_prepare_bytes = 128 * 1024 * 1024
let max_commit_bytes = 4096
let prepare_digest_size = 32
let prepare_digest_domain = "yeokcham:v2:transaction-prepare:1\000"
let prepare_suffix = ".prepare"
let commit_suffix = ".commit"
let ( let* ) = Result.bind

let error_to_string = function
  | Empty_staged_objects -> "V2 transaction must stage at least one object"
  | Too_many_staged_objects count ->
      Printf.sprintf "V2 transaction stages %d objects; limit is %d" count
        max_staged_objects
  | Prepare_too_large size ->
      Printf.sprintf "V2 transaction prepare is %d bytes; limit is %d" size
        max_prepare_bytes
  | Invalid_mandatory_features features ->
      Printf.sprintf "invalid V2 transaction mandatory feature bits: %Ld"
        features
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported V2 transaction mandatory feature bits: %Ld"
        features
  | Unsupported_prepare_schema_version version ->
      Printf.sprintf "unsupported V2 transaction prepare version: %Ld" version
  | Unsupported_commit_schema_version version ->
      Printf.sprintf "unsupported V2 transaction commit version: %Ld" version
  | Invalid_payload detail -> "invalid V2 transaction record: " ^ detail
  | Envelope_error error -> Envelope.error_to_string error
  | Duplicate_object_ref object_ref ->
      "duplicate V2 transaction object reference: "
      ^ Opaque_object_ref.to_hex object_ref
  | Noncanonical_object_ref_order { previous; current } ->
      Printf.sprintf
        "V2 transaction object references are not in canonical order: %s >= %s"
        (Opaque_object_ref.to_hex previous)
        (Opaque_object_ref.to_hex current)
  | Noncanonical_prepare -> "V2 transaction prepare is noncanonical"
  | Noncanonical_commit -> "V2 transaction commit is noncanonical"
  | Invalid_prepare_digest_length length ->
      Printf.sprintf
        "V2 transaction prepare digest must contain 32 bytes, got %d" length
  | Commit_transaction_mismatch { commit; prepare } ->
      Printf.sprintf "V2 transaction commit %s does not name prepare %s"
        (Transaction_id.to_hex commit)
        (Transaction_id.to_hex prepare)
  | Commit_prepare_mismatch ->
      "V2 transaction commit does not bind the exact prepare bytes"
  | Invalid_journal_filename name ->
      "invalid V2 transaction journal name: " ^ name

let check_mandatory_features features =
  if Int64.compare features 0L < 0 then
    Error (Invalid_mandatory_features features)
  else
    let unsupported =
      Int64.logand features (Int64.lognot supported_mandatory_features)
    in
    if Int64.equal unsupported 0L then Ok ()
    else Error (Unsupported_mandatory_features unsupported)

let array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Invalid_payload (Encoding.construction_error_to_string error))

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ ->
      Error
        (Invalid_payload (Printf.sprintf "%s has the wrong field count" name))
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

let stage ~object_ref ~envelope = { object_ref; envelope }
let staged_object_ref staged = staged.object_ref
let staged_envelope staged = staged.envelope

let rec validate_staged = function
  | [] | [ _ ] -> Ok ()
  | previous :: (current :: _ as rest) ->
      let comparison =
        Opaque_object_ref.compare previous.object_ref current.object_ref
      in
      if comparison = 0 then Error (Duplicate_object_ref current.object_ref)
      else if comparison > 0 then
        Error
          (Noncanonical_object_ref_order
             { previous = previous.object_ref; current = current.object_ref })
      else validate_staged rest

let stage_value staged =
  array
    [
      Encoding.bytes (Opaque_object_ref.to_bytes staged.object_ref);
      Encoding.bytes (Envelope.encode staged.envelope);
    ]

let rec collect_stage_values result = function
  | [] -> Ok (List.rev result)
  | staged :: rest ->
      let* value = stage_value staged in
      collect_stage_values (value :: result) rest

let prepare_value prepare =
  let* staged = collect_stage_values [] prepare.staged in
  let* staged = array staged in
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Repository_id.to_bytes prepare.repository_id);
      Encoding.bytes (Transaction_id.to_bytes prepare.prepare_transaction);
      Encoding.integer prepare.mandatory_features;
      staged;
    ]

let encode_prepare prepare =
  match prepare_value prepare with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let make_prepare ~repository_id ~transaction_id ~mandatory_features staged =
  let count = List.length staged in
  if count = 0 then Error Empty_staged_objects
  else if count > max_staged_objects then Error (Too_many_staged_objects count)
  else
    let* () = check_mandatory_features mandatory_features in
    let* () = validate_staged staged in
    let prepare =
      {
        repository_id;
        prepare_transaction = transaction_id;
        mandatory_features;
        staged;
      }
    in
    let size = String.length (encode_prepare prepare) in
    if size > max_prepare_bytes then Error (Prepare_too_large size)
    else Ok prepare

let prepare_repository_id prepare = prepare.repository_id
let prepare_transaction_id prepare = prepare.prepare_transaction
let prepare_staged prepare = prepare.staged

let decode_stage value =
  let* values = fields "V2 transaction staged object" 2 value in
  match values with
  | [ object_ref; envelope ] ->
      let* object_ref = bytes "V2 transaction object reference" object_ref in
      let* object_ref =
        Opaque_object_ref.of_bytes object_ref
        |> Result.map_error (fun _ ->
            Invalid_payload "V2 transaction object reference has invalid length")
      in
      let* envelope = bytes "V2 transaction encrypted envelope" envelope in
      let* envelope =
        Envelope.decode envelope
        |> Result.map_error (fun error -> Envelope_error error)
      in
      Ok (stage ~object_ref ~envelope)
  | _ -> assert false

let rec decode_staged result = function
  | [] -> Ok (List.rev result)
  | value :: rest ->
      let* staged = decode_stage value in
      decode_staged (staged :: result) rest

let decode_prepare encoded =
  let size = String.length encoded in
  if size > max_prepare_bytes then Error (Prepare_too_large size)
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "V2 transaction prepare" 5 value in
    match values with
    | [ version; repository_id; transaction_id; mandatory_features; staged ] ->
        let* version = integer "V2 transaction prepare version" version in
        if not (Int64.equal version current_schema_version) then
          Error (Unsupported_prepare_schema_version version)
        else
          let* repository_id =
            bytes "V2 transaction prepare repository ID" repository_id
          in
          let* repository_id =
            Repository_id.of_bytes repository_id
            |> Result.map_error (fun _ ->
                Invalid_payload
                  "V2 transaction prepare repository ID has invalid length")
          in
          let* transaction_id =
            bytes "V2 transaction prepare transaction ID" transaction_id
          in
          let* transaction_id =
            Transaction_id.of_bytes transaction_id
            |> Result.map_error (fun _ ->
                Invalid_payload
                  "V2 transaction prepare transaction ID has invalid length")
          in
          let* mandatory_features =
            integer "V2 transaction prepare mandatory features"
              mandatory_features
          in
          let* () = check_mandatory_features mandatory_features in
          let* staged =
            match staged with
            | Encoding.Array values
              when List.length values <= max_staged_objects ->
                decode_staged [] values
            | Encoding.Array values ->
                Error (Too_many_staged_objects (List.length values))
            | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ->
                Error
                  (Invalid_payload
                     "V2 transaction staged objects must be an array")
          in
          let* prepare =
            make_prepare ~repository_id ~transaction_id ~mandatory_features
              staged
          in
          if String.equal encoded (encode_prepare prepare) then Ok prepare
          else Error Noncanonical_prepare
    | _ -> assert false

let prepare_digest prepare =
  Hash.feed_string Hash.empty prepare_digest_domain |> fun context ->
  Hash.feed_string context (encode_prepare prepare)
  |> Hash.get |> Hash.to_raw_string

let commit_value commit =
  array
    [
      Encoding.integer current_schema_version;
      Encoding.bytes (Transaction_id.to_bytes commit.commit_transaction);
      Encoding.bytes commit.prepare_digest;
    ]

let encode_commit commit =
  match commit_value commit with
  | Ok value -> Encoding.encode value
  | Error error -> invalid_arg (error_to_string error)

let make_commit prepare =
  {
    commit_transaction = prepare_transaction_id prepare;
    prepare_digest = prepare_digest prepare;
  }

let commit_transaction_id commit = commit.commit_transaction
let commit_prepare_digest commit = commit.prepare_digest

let decode_commit encoded =
  if String.length encoded > max_commit_bytes then
    Error (Invalid_payload "V2 transaction commit exceeds its bounded size")
  else
    let* value =
      Encoding.decode encoded
      |> Result.map_error (fun error ->
          Invalid_payload (Encoding.decode_error_to_string error))
    in
    let* values = fields "V2 transaction commit" 3 value in
    match values with
    | [ version; transaction_id; prepare_digest ] ->
        let* version = integer "V2 transaction commit version" version in
        if not (Int64.equal version current_schema_version) then
          Error (Unsupported_commit_schema_version version)
        else
          let* transaction_id =
            bytes "V2 transaction commit transaction ID" transaction_id
          in
          let* transaction_id =
            Transaction_id.of_bytes transaction_id
            |> Result.map_error (fun _ ->
                Invalid_payload
                  "V2 transaction commit transaction ID has invalid length")
          in
          let* prepare_digest =
            bytes "V2 transaction commit prepare digest" prepare_digest
          in
          if String.length prepare_digest <> prepare_digest_size then
            Error (Invalid_prepare_digest_length (String.length prepare_digest))
          else
            let commit =
              { commit_transaction = transaction_id; prepare_digest }
            in
            if String.equal encoded (encode_commit commit) then Ok commit
            else Error Noncanonical_commit
    | _ -> assert false

let validate_commit ~prepare commit =
  let prepare_id = prepare_transaction_id prepare in
  if not (Transaction_id.equal prepare_id commit.commit_transaction) then
    Error
      (Commit_transaction_mismatch
         { commit = commit.commit_transaction; prepare = prepare_id })
  else if String.equal (prepare_digest prepare) commit.prepare_digest then Ok ()
  else Error Commit_prepare_mismatch

let prepare_filename transaction_id =
  Transaction_id.to_hex transaction_id ^ prepare_suffix

let commit_filename transaction_id =
  Transaction_id.to_hex transaction_id ^ commit_suffix

let parse_journal_filename name =
  let parse suffix constructor =
    let hex_length = String.length name - String.length suffix in
    if hex_length <> Transaction_id.byte_length * 2 then
      Error (Invalid_journal_filename name)
    else
      let encoded = String.sub name 0 hex_length in
      Transaction_id.of_hex encoded
      |> Result.map constructor
      |> Result.map_error (fun _ -> Invalid_journal_filename name)
  in
  if String.ends_with ~suffix:prepare_suffix name then
    parse prepare_suffix (fun id -> Prepare_file id)
  else if String.ends_with ~suffix:commit_suffix name then
    parse commit_suffix (fun id -> Commit_file id)
  else Error (Invalid_journal_filename name)

let is_decimal value =
  String.length value > 0
  && String.for_all (function '0' .. '9' -> true | _ -> false) value

let is_temporary_journal_filename name =
  match String.split_on_char '.' name with
  | [ ""; transaction_id; kind; temporary ] -> (
      (String.equal kind "prepare" || String.equal kind "commit")
      && (match Transaction_id.of_hex transaction_id with
        | Ok _ -> true
        | Error _ -> false)
      && String.starts_with ~prefix:"tmp-" temporary
      &&
      match
        String.split_on_char '-'
          (String.sub temporary 4 (String.length temporary - 4))
      with
      | [ process; attempt ] -> is_decimal process && is_decimal attempt
      | _ -> false)
  | _ -> false
