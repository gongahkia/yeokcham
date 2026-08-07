module Hash = Yeokcham_hash.Sha256
module Repository_id = Yeokcham_v2_model.Repository_id
module Opaque_object_ref = Yeokcham_v2_model.Opaque_object_ref
module Envelope = Yeokcham_v2_envelope

type key = string

type error =
  | Invalid_key_length of int
  | Address_mismatch of {
      expected : Opaque_object_ref.t;
      actual : Opaque_object_ref.t;
    }

let key_size = 32
let hmac_block_size = 64
let address_domain = "yeokcham:v2:opaque-object-address:1\000"

let error_to_string = function
  | Invalid_key_length length ->
      Printf.sprintf "v2 object-address key must contain 32 bytes, got %d"
        length
  | Address_mismatch { expected; actual } ->
      Printf.sprintf "v2 opaque object address mismatch: expected %s, got %s"
        (Opaque_object_ref.to_hex expected)
        (Opaque_object_ref.to_hex actual)

let key_of_bytes bytes =
  if String.length bytes = key_size then Ok bytes
  else Error (Invalid_key_length (String.length bytes))

let key_to_bytes key = key

let xor_pad key byte =
  Bytes.init hmac_block_size (fun index ->
      let source =
        if index < String.length key then Char.code key.[index] else 0
      in
      Char.chr (source lxor byte))
  |> Bytes.unsafe_to_string

let hmac_sha256 ~key chunks =
  let inner =
    List.fold_left
      (fun context chunk -> Hash.feed_string context chunk)
      (Hash.feed_string Hash.empty (xor_pad key 0x36))
      chunks
    |> Hash.get |> Hash.to_raw_string
  in
  Hash.feed_string Hash.empty (xor_pad key 0x5c) |> fun outer ->
  Hash.feed_string outer inner |> Hash.get |> Hash.to_raw_string

let derive ~repository_id ~key ~envelope =
  let digest =
    hmac_sha256 ~key
      [
        address_domain;
        Repository_id.to_bytes repository_id;
        Envelope.encode envelope;
      ]
  in
  match Opaque_object_ref.of_bytes digest with
  | Ok address -> address
  | Error _ -> assert false

let verify ~repository_id ~key ~address ~envelope =
  let expected = derive ~repository_id ~key ~envelope in
  if Opaque_object_ref.equal expected address then Ok ()
  else Error (Address_mismatch { expected; actual = address })
