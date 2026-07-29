let hex_value = function
  | '0' .. '9' as character -> Ok (Char.code character - Char.code '0')
  | 'a' .. 'f' as character -> Ok (Char.code character - Char.code 'a' + 10)
  | character ->
      Error
        (Printf.sprintf
           "fixture hex has invalid character %C; use lowercase hex" character)

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
