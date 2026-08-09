let hex_value = function
  | '0' .. '9' as character -> Ok (Char.code character - Char.code '0')
  | 'a' .. 'f' as character -> Ok (Char.code character - Char.code 'a' + 10)
  | character ->
      Error
        (Printf.sprintf
           "fixture hex has invalid character %C; use lowercase hex" character)

let ( let* ) = Result.bind

let decode_lower_hex encoded =
  let length = String.length encoded in
  if length = 0 then Error "fixture hex is empty"
  else if length mod 2 <> 0 then
    Error (Printf.sprintf "fixture hex has odd length: %d" length)
  else
    let decoded = Bytes.create (length / 2) in
    let rec decode_pair offset =
      if offset = length then Ok (Bytes.unsafe_to_string decoded)
      else
        match hex_value encoded.[offset] with
        | Error message ->
            Error (Printf.sprintf "%s at offset %d" message offset)
        | Ok high -> (
            match hex_value encoded.[offset + 1] with
            | Error message ->
                Error (Printf.sprintf "%s at offset %d" message (offset + 1))
            | Ok low ->
                Bytes.set decoded (offset / 2) (Char.chr ((high lsl 4) lor low));
                decode_pair (offset + 2))
    in
    decode_pair 0

let read_lower_hex_file path =
  try
    let contents = In_channel.with_open_bin path In_channel.input_all in
    let length = String.length contents in
    if length = 0 then Error (Printf.sprintf "%s: fixture is empty" path)
    else if contents.[length - 1] <> '\n' then
      Error (Printf.sprintf "%s: fixture must end with one LF" path)
    else
      let encoded = String.sub contents 0 (length - 1) in
      if String.contains encoded '\n' || String.contains encoded '\r' then
        Error (Printf.sprintf "%s: fixture must contain one line" path)
      else
        decode_lower_hex encoded
        |> Result.map_error (fun message ->
            Printf.sprintf "%s: %s" path message)
  with Sys_error message -> Error message

let decode_canonical_lower_hex_file ~path ~decode ~encode ~error_to_string =
  let* bytes = read_lower_hex_file path in
  let* value = decode bytes |> Result.map_error error_to_string in
  if String.equal bytes (encode value) then Ok value
  else
    Error (Printf.sprintf "%s: decoder re-encoding differs from fixture" path)

let truncate bytes ~length =
  let actual = String.length bytes in
  if length < 0 || length >= actual then
    Error
      (Printf.sprintf
         "fixture truncation length %d is outside the proper range 0..%d" length
         (actual - 1))
  else Ok (String.sub bytes 0 length)

let xor_byte bytes ~offset ~mask =
  let length = String.length bytes in
  if offset < 0 || offset >= length then
    Error
      (Printf.sprintf "fixture byte offset %d is outside the range 0..%d" offset
         (length - 1))
  else if mask <= 0 || mask > 255 then
    Error (Printf.sprintf "fixture byte XOR mask %d is outside 1..255" mask)
  else
    let mutated = Bytes.of_string bytes in
    Bytes.set mutated offset
      (Char.chr (Char.code (Bytes.get mutated offset) lxor mask));
    Ok (Bytes.unsafe_to_string mutated)

let lower_hex bytes =
  let hex = "0123456789abcdef" in
  let encoded = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set encoded (index * 2) hex.[value lsr 4];
      Bytes.set encoded ((index * 2) + 1) hex.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string encoded

let source_path path =
  match Sys.getenv_opt "YEOKCHAM_GOLDEN_ROOT" with
  | Some root -> Filename.concat root (Filename.concat "test" path)
  | None ->
      if Sys.file_exists path then path
      else
        let from_root = Filename.concat "test" path in
        if Sys.file_exists from_root then from_root else path

let refresh_lower_hex_file path actual =
  let path = source_path path in
  match Sys.getenv_opt "YEOKCHAM_REFRESH_GOLDENS" with
  | Some "1" -> (
      try
        Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel (lower_hex actual);
            Out_channel.output_char channel '\n');
        Ok actual
      with Sys_error message -> Error message)
  | Some _ | None -> read_lower_hex_file path
