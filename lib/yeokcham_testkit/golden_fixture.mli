val decode_lower_hex : string -> (string, string) result
val read_lower_hex_file : string -> (string, string) result

val decode_canonical_lower_hex_file :
  path:string ->
  decode:(string -> ('a, 'error) result) ->
  encode:('a -> string) ->
  error_to_string:('error -> string) ->
  ('a, string) result

val truncate : string -> length:int -> (string, string) result
val xor_byte : string -> offset:int -> mask:int -> (string, string) result
val refresh_lower_hex_file : string -> string -> (string, string) result
