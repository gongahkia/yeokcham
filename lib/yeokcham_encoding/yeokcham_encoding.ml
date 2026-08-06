let profile_version = 1
let max_nesting = 64

type t =
  | Integer of int64
  | Bytes of string
  | Text of string
  | Array of t list
  | Map of (int64 * t) list
  | Bool of bool
  | Null

type construction_error =
  | Invalid_text_utf8 of int
  | Negative_map_key of int64
  | Duplicate_map_key of int64
  | Nesting_limit_exceeded of int

let construction_error_to_string = function
  | Invalid_text_utf8 offset -> Printf.sprintf "invalid UTF-8 at byte %d" offset
  | Negative_map_key key -> Printf.sprintf "map key is negative: %Ld" key
  | Duplicate_map_key key -> Printf.sprintf "duplicate map key: %Ld" key
  | Nesting_limit_exceeded depth ->
      Printf.sprintf "nesting limit exceeded: %d" depth

let byte input offset = Char.code input.[offset]
let is_continuation value = value >= 0x80 && value <= 0xbf
let in_range value lower upper = value >= lower && value <= upper

let validate_utf8 input =
  let length = String.length input in
  let rec scan offset =
    if offset = length then Ok ()
    else
      match byte input offset with
      | value when value <= 0x7f -> scan (offset + 1)
      | value when value >= 0xc2 && value <= 0xdf ->
          if offset + 1 < length && is_continuation (byte input (offset + 1))
          then scan (offset + 2)
          else Error offset
      | 0xe0 ->
          if
            offset + 2 < length
            && in_range (byte input (offset + 1)) 0xa0 0xbf
            && is_continuation (byte input (offset + 2))
          then scan (offset + 3)
          else Error offset
      | value when value >= 0xe1 && value <= 0xec ->
          if
            offset + 2 < length
            && is_continuation (byte input (offset + 1))
            && is_continuation (byte input (offset + 2))
          then scan (offset + 3)
          else Error offset
      | 0xed ->
          if
            offset + 2 < length
            && in_range (byte input (offset + 1)) 0x80 0x9f
            && is_continuation (byte input (offset + 2))
          then scan (offset + 3)
          else Error offset
      | value when value >= 0xee && value <= 0xef ->
          if
            offset + 2 < length
            && is_continuation (byte input (offset + 1))
            && is_continuation (byte input (offset + 2))
          then scan (offset + 3)
          else Error offset
      | 0xf0 ->
          if
            offset + 3 < length
            && in_range (byte input (offset + 1)) 0x90 0xbf
            && is_continuation (byte input (offset + 2))
            && is_continuation (byte input (offset + 3))
          then scan (offset + 4)
          else Error offset
      | value when value >= 0xf1 && value <= 0xf3 ->
          if
            offset + 3 < length
            && is_continuation (byte input (offset + 1))
            && is_continuation (byte input (offset + 2))
            && is_continuation (byte input (offset + 3))
          then scan (offset + 4)
          else Error offset
      | 0xf4 ->
          if
            offset + 3 < length
            && in_range (byte input (offset + 1)) 0x80 0x8f
            && is_continuation (byte input (offset + 2))
            && is_continuation (byte input (offset + 3))
          then scan (offset + 4)
          else Error offset
      | _ -> Error offset
  in
  scan 0

let rec nesting = function
  | Integer _ | Bytes _ | Text _ | Bool _ | Null -> 0
  | Array values ->
      1
      + List.fold_left
          (fun maximum value -> max maximum (nesting value))
          0 values
  | Map entries ->
      1
      + List.fold_left
          (fun maximum (_, value) -> max maximum (nesting value))
          0 entries

let ensure_nesting value =
  let depth = nesting value in
  if depth > max_nesting then Error (Nesting_limit_exceeded depth) else Ok value

let integer value = Integer value
let bytes value = Bytes value

let text value =
  match validate_utf8 value with
  | Ok () -> Ok (Text value)
  | Error offset -> Error (Invalid_text_utf8 offset)

let array values = ensure_nesting (Array values)

let map entries =
  match List.find_opt (fun (key, _) -> Int64.compare key 0L < 0) entries with
  | Some (key, _) -> Error (Negative_map_key key)
  | None -> (
      let sorted =
        List.sort (fun (left, _) (right, _) -> Int64.compare left right) entries
      in
      let rec find_duplicate = function
        | (left, _) :: (right, _) :: _ when Int64.equal left right -> Some left
        | _ :: rest -> find_duplicate rest
        | [] -> None
      in
      match find_duplicate sorted with
      | Some key -> Error (Duplicate_map_key key)
      | None -> ensure_nesting (Map sorted))

let bool value = Bool value
let null = Null
let equal = ( = )

type limits = { max_depth : int; max_items : int option }
type limit_error = Invalid_max_depth of int | Invalid_max_items of int

let limit_error_to_string = function
  | Invalid_max_depth value -> Printf.sprintf "invalid maximum depth: %d" value
  | Invalid_max_items value -> Printf.sprintf "invalid maximum items: %d" value

let make_limits ?(max_depth = max_nesting) ?max_items () =
  if max_depth < 0 || max_depth > max_nesting then
    Error (Invalid_max_depth max_depth)
  else
    match max_items with
    | Some value when value < 0 -> Error (Invalid_max_items value)
    | _ -> Ok { max_depth; max_items }

let default_limits =
  match make_limits () with Ok limits -> limits | Error _ -> assert false

type decode_error_kind =
  | Empty_input
  | Truncated of int
  | Trailing_bytes of int
  | Reserved_additional_information of int
  | Indefinite_length
  | Non_minimal_argument of int64
  | Argument_out_of_range
  | Unsupported_major_type of int
  | Unsupported_simple_value of int
  | Invalid_utf8_text
  | Non_integer_map_key
  | Negative_decoded_map_key of int64
  | Duplicate_decoded_map_key of int64
  | Non_increasing_map_key of { previous : int64; current : int64 }
  | Declared_length_exceeds_input of int64
  | Declared_items_exceed_input of int64
  | Depth_limit_exceeded of int
  | Work_limit_exceeded

type decode_error = { offset : int; kind : decode_error_kind }

let decode_error_to_string { offset; kind } =
  let message =
    match kind with
    | Empty_input -> "empty input"
    | Truncated needed -> Printf.sprintf "truncated input; need %d bytes" needed
    | Trailing_bytes remaining -> Printf.sprintf "trailing bytes: %d" remaining
    | Reserved_additional_information value ->
        Printf.sprintf "reserved additional information: %d" value
    | Indefinite_length -> "indefinite length is not permitted"
    | Non_minimal_argument value ->
        Printf.sprintf "non-minimal argument: %Ld" value
    | Argument_out_of_range -> "argument exceeds signed 64-bit range"
    | Unsupported_major_type value ->
        Printf.sprintf "unsupported major type: %d" value
    | Unsupported_simple_value value ->
        Printf.sprintf "unsupported simple value: %d" value
    | Invalid_utf8_text -> "invalid UTF-8 text"
    | Non_integer_map_key -> "map key is not an integer"
    | Negative_decoded_map_key key ->
        Printf.sprintf "map key is negative: %Ld" key
    | Duplicate_decoded_map_key key ->
        Printf.sprintf "duplicate map key: %Ld" key
    | Non_increasing_map_key { previous; current } ->
        Printf.sprintf "map keys are not increasing: %Ld then %Ld" previous
          current
    | Declared_length_exceeds_input value ->
        Printf.sprintf "declared length exceeds input: %Ld" value
    | Declared_items_exceed_input value ->
        Printf.sprintf "declared item count exceeds input: %Ld" value
    | Depth_limit_exceeded value ->
        Printf.sprintf "depth limit exceeded: %d" value
    | Work_limit_exceeded -> "item work limit exceeded"
  in
  Printf.sprintf "byte %d: %s" offset message

let uint32_max = 4_294_967_295L
let write_byte buffer value = Buffer.add_char buffer (Char.chr value)

let write_uint buffer width value =
  for index = width - 1 downto 0 do
    let shift = index * 8 in
    let byte = Int64.(to_int (logand (shift_right_logical value shift) 255L)) in
    write_byte buffer byte
  done

let write_head buffer major argument =
  if Int64.compare argument 0L < 0 then invalid_arg "negative CBOR argument";
  if Int64.compare argument 24L < 0 then
    write_byte buffer ((major lsl 5) lor Int64.to_int argument)
  else if Int64.compare argument 255L <= 0 then (
    write_byte buffer ((major lsl 5) lor 24);
    write_uint buffer 1 argument)
  else if Int64.compare argument 65_535L <= 0 then (
    write_byte buffer ((major lsl 5) lor 25);
    write_uint buffer 2 argument)
  else if Int64.compare argument uint32_max <= 0 then (
    write_byte buffer ((major lsl 5) lor 26);
    write_uint buffer 4 argument)
  else (
    write_byte buffer ((major lsl 5) lor 27);
    write_uint buffer 8 argument)

let rec write_value buffer = function
  | Integer value ->
      if Int64.compare value 0L >= 0 then write_head buffer 0 value
      else write_head buffer 1 Int64.(sub (-1L) value)
  | Bytes value ->
      write_head buffer 2 (Int64.of_int (String.length value));
      Buffer.add_string buffer value
  | Text value ->
      write_head buffer 3 (Int64.of_int (String.length value));
      Buffer.add_string buffer value
  | Array values ->
      write_head buffer 4 (Int64.of_int (List.length values));
      List.iter (write_value buffer) values
  | Map entries ->
      write_head buffer 5 (Int64.of_int (List.length entries));
      List.iter
        (fun (key, value) ->
          write_head buffer 0 key;
          write_value buffer value)
        entries
  | Bool false -> write_byte buffer 0xf4
  | Bool true -> write_byte buffer 0xf5
  | Null -> write_byte buffer 0xf6

let encode value =
  let buffer = Buffer.create 128 in
  write_value buffer value;
  Buffer.contents buffer

type reader = {
  input : string;
  limits : limits;
  mutable position : int;
  mutable remaining_items : int;
}

let error offset kind = Error ({ offset; kind } : decode_error)
let ( let* ) result continuation = Result.bind result continuation

let take_byte reader =
  if reader.position = String.length reader.input then
    error reader.position (Truncated 1)
  else
    let value = byte reader.input reader.position in
    reader.position <- reader.position + 1;
    Ok value

let take_string reader length =
  let remaining = String.length reader.input - reader.position in
  if length > remaining then error reader.position (Truncated length)
  else
    let value = String.sub reader.input reader.position length in
    reader.position <- reader.position + length;
    Ok value

let consume_item reader =
  if reader.remaining_items = 0 then error reader.position Work_limit_exceeded
  else (
    reader.remaining_items <- reader.remaining_items - 1;
    Ok ())

let read_uint reader width =
  let rec loop remaining value =
    if remaining = 0 then Ok value
    else
      let* next = take_byte reader in
      loop (remaining - 1) Int64.(logor (shift_left value 8) (of_int next))
  in
  let* value = loop width 0L in
  if width = 8 && Int64.compare value 0L < 0 then
    error reader.position Argument_out_of_range
  else Ok value

let minimal_width argument =
  if Int64.compare argument 24L < 0 then 0
  else if Int64.compare argument 255L <= 0 then 1
  else if Int64.compare argument 65_535L <= 0 then 2
  else if Int64.compare argument uint32_max <= 0 then 4
  else 8

let read_argument reader start additional =
  let width =
    match additional with
    | 24 -> Some 1
    | 25 -> Some 2
    | 26 -> Some 4
    | 27 -> Some 8
    | 28 | 29 | 30 -> None
    | 31 -> None
    | value when value < 24 -> Some 0
    | _ -> assert false
  in
  if additional = 31 then error start Indefinite_length
  else if additional >= 28 then
    error start (Reserved_additional_information additional)
  else if additional < 24 then Ok (Int64.of_int additional)
  else
    match width with
    | Some width -> (
        match read_uint reader width with
        | Error failure -> Error failure
        | Ok argument ->
            if width <> minimal_width argument then
              error start (Non_minimal_argument argument)
            else Ok argument)
    | None -> assert false

let length_from_argument reader start argument =
  let remaining = String.length reader.input - reader.position in
  if Int64.compare argument (Int64.of_int remaining) > 0 then
    error start (Declared_length_exceeds_input argument)
  else Ok (Int64.to_int argument)

let array_count_from_argument reader start argument =
  let remaining = String.length reader.input - reader.position in
  if Int64.compare argument (Int64.of_int remaining) > 0 then
    error start (Declared_items_exceed_input argument)
  else Ok (Int64.to_int argument)

let map_count_from_argument reader start argument =
  let remaining = String.length reader.input - reader.position in
  if Int64.compare argument (Int64.of_int (remaining / 2)) > 0 then
    error start (Declared_items_exceed_input argument)
  else Ok (Int64.to_int argument)

let decode ?(limits = default_limits) input =
  if String.is_empty input then error 0 Empty_input
  else
    let item_budget =
      match limits.max_items with
      | None -> String.length input
      | Some maximum -> min maximum (String.length input)
    in
    let reader =
      { input; limits; position = 0; remaining_items = item_budget }
    in
    let rec read_value depth =
      let start = reader.position in
      let* () = consume_item reader in
      let* initial = take_byte reader in
      let major = initial lsr 5 in
      let additional = initial land 0x1f in
      match major with
      | 0 ->
          let* argument = read_argument reader start additional in
          Ok (Integer argument)
      | 1 ->
          let* argument = read_argument reader start additional in
          Ok (Integer Int64.(sub (-1L) argument))
      | 2 ->
          let* argument = read_argument reader start additional in
          let* length = length_from_argument reader start argument in
          let* value = take_string reader length in
          Ok (Bytes value)
      | 3 -> (
          let* argument = read_argument reader start additional in
          let* length = length_from_argument reader start argument in
          let text_start = reader.position in
          let* value = take_string reader length in
          match validate_utf8 value with
          | Ok () -> Ok (Text value)
          | Error offset -> error (text_start + offset) Invalid_utf8_text)
      | 4 ->
          if depth >= reader.limits.max_depth then
            error start (Depth_limit_exceeded (depth + 1))
          else
            let* argument = read_argument reader start additional in
            let* count = array_count_from_argument reader start argument in
            let rec elements remaining reversed =
              if remaining = 0 then Ok (Array (List.rev reversed))
              else
                let* value = read_value (depth + 1) in
                elements (remaining - 1) (value :: reversed)
            in
            elements count []
      | 5 ->
          if depth >= reader.limits.max_depth then
            error start (Depth_limit_exceeded (depth + 1))
          else
            let* argument = read_argument reader start additional in
            let* count = map_count_from_argument reader start argument in
            let rec entries remaining previous reversed =
              if remaining = 0 then Ok (Map (List.rev reversed))
              else
                let key_start = reader.position in
                let* key_value = read_value (depth + 1) in
                match key_value with
                | Integer key when Int64.compare key 0L < 0 ->
                    error key_start (Negative_decoded_map_key key)
                | Integer key -> (
                    match previous with
                    | Some prior when Int64.equal prior key ->
                        error key_start (Duplicate_decoded_map_key key)
                    | Some prior when Int64.compare prior key > 0 ->
                        error key_start
                          (Non_increasing_map_key
                             { previous = prior; current = key })
                    | _ ->
                        let* value = read_value (depth + 1) in
                        entries (remaining - 1) (Some key)
                          ((key, value) :: reversed))
                | Bytes _ | Text _ | Array _ | Map _ | Bool _ | Null ->
                    error key_start Non_integer_map_key
            in
            entries count None []
      | 6 -> error start (Unsupported_major_type major)
      | 7 -> (
          match additional with
          | 20 -> Ok (Bool false)
          | 21 -> Ok (Bool true)
          | 22 -> Ok Null
          | 31 -> error start Indefinite_length
          | 28 | 29 | 30 ->
              error start (Reserved_additional_information additional)
          | value -> error start (Unsupported_simple_value value))
      | _ -> assert false
    in
    match read_value 0 with
    | Error failure -> Error failure
    | Ok value ->
        let remaining = String.length input - reader.position in
        if remaining = 0 then Ok value
        else error reader.position (Trailing_bytes remaining)
