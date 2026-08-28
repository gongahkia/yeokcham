(** Canonical BIP-39 English mnemonic encoding for random V4 recovery secrets
    and human comparison phrases. It is not a password KDF. *)

type error =
  | Unsupported_entropy_length of int
  | Invalid_word_count of int
  | Unknown_word of string
  | Invalid_checksum
  | Noncanonical_phrase

val error_to_string : error -> string

val encode : string -> (string, error) result
(** Encodes exactly 16 or 32 entropy bytes as a 12- or 24-word phrase. *)

val decode : string -> (string, error) result
(** Decodes a single-space-separated canonical 12- or 24-word English phrase. *)
