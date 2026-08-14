module Hash = Yeokcham_hash.Sha256
module Encoding = Yeokcham_encoding

let envelope_version = 1
let header_size = 57
let prefix_size = 25
let checksum_algorithm_code = 1
let current_object_format_version = 1
let supported_mandatory_features = 0L
let magic = "YEOK"

type object_type =
  | Content
  | Tree
  | Snapshot
  | Scratch_event
  | Checkpoint
  | Capsule
  | Capsule_revision
  | Release
  | Conflict
  | Validation
  | Resolution
  | Repository_config
  | Chunk
  | File_manifest
  | Retention_change
  | Scratch_generation_segment
  | Scratch_generation
  | Scratch_cleanup_manifest
  | Workspace
  | Workspace_revision
  | Workspace_attempt
  | Release_attestation
  | Git_mapping
  | Imported_transition
  | Imported_tag
  | Ref_event
  | Device_identity
  | Divergent_ref_set
  | Git_archive

let object_type_code = function
  | Content -> 1
  | Tree -> 2
  | Snapshot -> 3
  | Scratch_event -> 4
  | Checkpoint -> 5
  | Capsule -> 6
  | Capsule_revision -> 7
  | Release -> 8
  | Conflict -> 9
  | Validation -> 10
  | Resolution -> 11
  | Repository_config -> 12
  | Chunk -> 13
  | File_manifest -> 14
  | Retention_change -> 15
  | Scratch_generation_segment -> 16
  | Scratch_generation -> 17
  | Scratch_cleanup_manifest -> 18
  | Workspace -> 19
  | Workspace_revision -> 20
  | Workspace_attempt -> 21
  | Release_attestation -> 22
  | Git_mapping -> 23
  | Imported_transition -> 24
  | Imported_tag -> 25
  | Ref_event -> 26
  | Device_identity -> 27
  | Divergent_ref_set -> 28
  | Git_archive -> 29

let object_type_of_code = function
  | 1 -> Some Content
  | 2 -> Some Tree
  | 3 -> Some Snapshot
  | 4 -> Some Scratch_event
  | 5 -> Some Checkpoint
  | 6 -> Some Capsule
  | 7 -> Some Capsule_revision
  | 8 -> Some Release
  | 9 -> Some Conflict
  | 10 -> Some Validation
  | 11 -> Some Resolution
  | 12 -> Some Repository_config
  | 13 -> Some Chunk
  | 14 -> Some File_manifest
  | 15 -> Some Retention_change
  | 16 -> Some Scratch_generation_segment
  | 17 -> Some Scratch_generation
  | 18 -> Some Scratch_cleanup_manifest
  | 19 -> Some Workspace
  | 20 -> Some Workspace_revision
  | 21 -> Some Workspace_attempt
  | 22 -> Some Release_attestation
  | 23 -> Some Git_mapping
  | 24 -> Some Imported_transition
  | 25 -> Some Imported_tag
  | 26 -> Some Ref_event
  | 27 -> Some Device_identity
  | 28 -> Some Divergent_ref_set
  | 29 -> Some Git_archive
  | _ -> None

type creation_error =
  | Invalid_object_format_version of int
  | Unsupported_mandatory_features of int64

let creation_error_to_string = function
  | Invalid_object_format_version version ->
      Printf.sprintf "unsupported object format version: %d" version
  | Unsupported_mandatory_features features ->
      Printf.sprintf "unsupported mandatory features: 0x%Lx" features

type 'payload envelope = {
  object_type : object_type;
  object_format_version : int;
  mandatory_features : int64;
  checksum : string;
  payload : 'payload;
}

type t = Encoding.t envelope

let object_type envelope = envelope.object_type
let object_format_version envelope = envelope.object_format_version
let mandatory_features envelope = envelope.mandatory_features
let checksum envelope = envelope.checksum
let payload envelope = envelope.payload

let unknown_mandatory_features features =
  Int64.logand features (Int64.lognot supported_mandatory_features)

let set_byte bytes offset value = Bytes.set bytes offset (Char.chr value)

let set_uint16 bytes offset value =
  set_byte bytes offset (value lsr 8);
  set_byte bytes (offset + 1) (value land 0xff)

let set_uint64 bytes offset value =
  for index = 0 to 7 do
    let shift = (7 - index) * 8 in
    let byte = Int64.(to_int (logand (shift_right_logical value shift) 255L)) in
    set_byte bytes (offset + index) byte
  done

let make_prefix ~object_type ~object_format_version ~mandatory_features
    ~payload_length =
  let bytes = Bytes.make prefix_size '\000' in
  Bytes.blit_string magic 0 bytes 0 (String.length magic);
  set_byte bytes 4 envelope_version;
  set_byte bytes 5 (object_type_code object_type);
  set_uint16 bytes 6 object_format_version;
  set_uint64 bytes 8 mandatory_features;
  set_byte bytes 16 checksum_algorithm_code;
  set_uint64 bytes 17 (Int64.of_int payload_length);
  Bytes.unsafe_to_string bytes

let calculate_checksum prefix payload =
  Hash.feed_string Hash.empty prefix |> fun context ->
  Hash.feed_string context payload |> Hash.get |> Hash.to_raw_string

let create ~object_type ~object_format_version ~mandatory_features ~payload () =
  if object_format_version <> current_object_format_version then
    Error (Invalid_object_format_version object_format_version)
  else
    let unsupported = unknown_mandatory_features mandatory_features in
    if not (Int64.equal unsupported 0L) then
      Error (Unsupported_mandatory_features unsupported)
    else
      let encoded_payload = Encoding.encode payload in
      let prefix =
        make_prefix ~object_type ~object_format_version ~mandatory_features
          ~payload_length:(String.length encoded_payload)
      in
      let checksum = calculate_checksum prefix encoded_payload in
      Ok
        {
          object_type;
          object_format_version;
          mandatory_features;
          checksum;
          payload;
        }

type decode_error_kind =
  | Truncated_header of int
  | Invalid_magic
  | Unsupported_envelope_version of int
  | Unknown_checksum_algorithm of int
  | Payload_length_out_of_range
  | Length_mismatch of { declared : int64; actual : int }
  | Checksum_mismatch
  | Unknown_object_type of int
  | Unsupported_object_format_version of int
  | Unknown_mandatory_features of int64
  | Invalid_payload of string

type decode_error = { offset : int; kind : decode_error_kind }

let decode_error_to_string { offset; kind } =
  let message =
    match kind with
    | Truncated_header available ->
        Printf.sprintf "truncated header: %d of %d bytes" available header_size
    | Invalid_magic -> "invalid envelope magic"
    | Unsupported_envelope_version version ->
        Printf.sprintf "unsupported envelope version: %d" version
    | Unknown_checksum_algorithm algorithm ->
        Printf.sprintf "unknown checksum algorithm: %d" algorithm
    | Payload_length_out_of_range -> "payload length exceeds supported range"
    | Length_mismatch { declared; actual } ->
        Printf.sprintf "payload length mismatch: declared %Ld, actual %d"
          declared actual
    | Checksum_mismatch -> "checksum mismatch"
    | Unknown_object_type code -> Printf.sprintf "unknown object type: %d" code
    | Unsupported_object_format_version version ->
        Printf.sprintf "unsupported object format version: %d" version
    | Unknown_mandatory_features features ->
        Printf.sprintf "unknown mandatory features: 0x%Lx" features
    | Invalid_payload message -> Printf.sprintf "invalid payload: %s" message
  in
  Printf.sprintf "byte %d: %s" offset message

let error offset kind = Error ({ offset; kind } : decode_error)
let ( let* ) result continuation = Result.bind result continuation
let read_byte input offset = Char.code input.[offset]

let read_uint16 input offset =
  (read_byte input offset lsl 8) lor read_byte input (offset + 1)

let read_uint64 input offset =
  let value = ref 0L in
  for index = 0 to 7 do
    value :=
      Int64.(
        logor (shift_left !value 8) (of_int (read_byte input (offset + index))))
  done;
  !value

let decode_payload_length input =
  let value = read_uint64 input 17 in
  if Int64.compare value 0L < 0 then Error () else Ok value

let encode envelope =
  let encoded_payload = Encoding.encode envelope.payload in
  let prefix =
    make_prefix ~object_type:envelope.object_type
      ~object_format_version:envelope.object_format_version
      ~mandatory_features:envelope.mandatory_features
      ~payload_length:(String.length encoded_payload)
  in
  prefix ^ envelope.checksum ^ encoded_payload

let verify input =
  let length = String.length input in
  if length < header_size then error 0 (Truncated_header length)
  else if not (String.equal (String.sub input 0 4) magic) then
    error 0 Invalid_magic
  else
    let version = read_byte input 4 in
    if version <> envelope_version then
      error 4 (Unsupported_envelope_version version)
    else
      let algorithm = read_byte input 16 in
      if algorithm <> checksum_algorithm_code then
        error 16 (Unknown_checksum_algorithm algorithm)
      else
        match decode_payload_length input with
        | Error () -> error 17 Payload_length_out_of_range
        | Ok declared_length -> (
            let actual_length = length - header_size in
            if Int64.compare declared_length (Int64.of_int actual_length) <> 0
            then
              error 17
                (Length_mismatch
                   { declared = declared_length; actual = actual_length })
            else
              let prefix = String.sub input 0 prefix_size in
              let stored_checksum =
                String.sub input prefix_size Hash.digest_size
              in
              let raw_payload = String.sub input header_size actual_length in
              let calculated_checksum = calculate_checksum prefix raw_payload in
              match Hash.of_raw_string stored_checksum with
              | None -> assert false
              | Some stored -> (
                  let calculated =
                    match Hash.of_raw_string calculated_checksum with
                    | Some digest -> digest
                    | None -> assert false
                  in
                  if not (Hash.equal stored calculated) then
                    error 25 Checksum_mismatch
                  else
                    let object_type_code = read_byte input 5 in
                    match object_type_of_code object_type_code with
                    | None -> error 5 (Unknown_object_type object_type_code)
                    | Some object_type ->
                        let object_format_version = read_uint16 input 6 in
                        if
                          object_format_version <> current_object_format_version
                        then
                          error 6
                            (Unsupported_object_format_version
                               object_format_version)
                        else
                          let mandatory_features = read_uint64 input 8 in
                          let unknown =
                            unknown_mandatory_features mandatory_features
                          in
                          if not (Int64.equal unknown 0L) then
                            error 8 (Unknown_mandatory_features unknown)
                          else
                            Ok
                              {
                                object_type;
                                object_format_version;
                                mandatory_features;
                                checksum = stored_checksum;
                                payload = raw_payload;
                              }))

let decode_with ~payload_decoder input =
  let* verified = verify input in
  match payload_decoder verified.payload with
  | Ok payload ->
      Ok
        {
          object_type = verified.object_type;
          object_format_version = verified.object_format_version;
          mandatory_features = verified.mandatory_features;
          checksum = verified.checksum;
          payload;
        }
  | Error message -> error header_size (Invalid_payload message)

let decode input =
  decode_with
    ~payload_decoder:(fun raw ->
      match Encoding.decode raw with
      | Ok value -> Ok value
      | Error failure -> Error (Encoding.decode_error_to_string failure))
    input
