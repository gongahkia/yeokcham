(** Canonical TC06 core records. The envelope module owns object type codes.
    This codec validates syntax, canonical ordering, scope and bounds. A
    syntactically signed record still requires the trust boundary. *)

type error =
  | Model_error of Yeokcham_v1_model.Core.error
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of Yeokcham_encoding.decode_error
  | Envelope_error of Yeokcham_envelope.decode_error
  | Invalid_schema of string
  | Unsupported_schema_version of int64
  | Wrong_object_type
  | Noncanonical_bytes
  | Oversized_record of int
  | Invalid_signature_length of int

val error_to_string : error -> string
val schema_version : int64
val max_record_bytes : int
val object_type : Yeokcham_v1_model.Core.kind -> Yeokcham_envelope.object_type
val signature_domain : Yeokcham_v1_model.Core.kind -> string
val encode_body : Yeokcham_v1_model.Core.body -> (string, error) result

val decode_body :
  repository:Yeokcham_v1_model.Core.Repository_id.t ->
  string ->
  (Yeokcham_v1_model.Core.body, error) result

val signing_input : Yeokcham_v1_model.Core.body -> (string, error) result
(** Exact Ed25519 message: fixed kind-specific domain followed by canonical
    body. Existing trust sign_detached takes domain and body as separate
    arguments. *)

type signed

val body : signed -> Yeokcham_v1_model.Core.body
val signature : signed -> string

val attach_signature :
  Yeokcham_v1_model.Core.body -> signature:string -> (signed, error) result

val encode : signed -> (string, error) result

val decode :
  repository:Yeokcham_v1_model.Core.Repository_id.t ->
  string ->
  (signed, error) result

val id : signed -> (Yeokcham_v1_model.Core.Record_id.t, error) result
(** SHA-256 of the complete canonical typed envelope, including its signature.
*)

val encode_history_id : Yeokcham_v1_model.Core.History_id.t -> string

val decode_history_id :
  string -> (Yeokcham_v1_model.Core.History_id.t, error) result
(** Canonical private pair [workspace bytes, sequence]. Not a signed public ID.
*)
