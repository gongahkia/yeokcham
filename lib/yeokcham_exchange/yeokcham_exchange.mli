module Object_id = Yeokcham_store.Stored_object_id

type session_id
type end_status = Complete | Incomplete

type message =
  | Hello of {
      repository_format : string;
      supported_versions : int list;
      required_features : int64;
    }
  | Inventory of {
      session_id : session_id;
      sequence : int64;
      final : bool;
      object_ids : Object_id.t list;
      required_features : int64;
    }
  | Want of {
      session_id : session_id;
      sequence : int64;
      object_ids : Object_id.t list;
      required_features : int64;
    }
  | Object of {
      session_id : session_id;
      sequence : int64;
      object_id : Object_id.t;
      envelope_bytes : string;
      required_features : int64;
    }
  | End of {
      session_id : session_id;
      status : end_status;
      required_features : int64;
    }
  | Error_message of {
      session_id : session_id option;
      code : string;
      detail : string;
      required_features : int64;
    }

type error =
  | Invalid_session_id of int
  | Truncated_frame of int
  | Frame_length_mismatch of { declared : int64; actual : int }
  | Frame_too_large of int64
  | Invalid_cbor of string
  | Noncanonical_cbor
  | Invalid_message of string
  | Unsupported_version of int64
  | Unsupported_features of int64
  | Message_too_large of { size : int; limit : int }
  | Object_too_large of { size : int; limit : int }
  | Hello_required
  | Duplicate_hello
  | Incompatible_repository_format
  | No_compatible_version
  | Session_mismatch
  | Session_closed
  | Out_of_order_sequence of { previous : int64; current : int64 }
  | Inventory_closed
  | Unknown_inventory_sequence of int64
  | Unoffered_object of Object_id.t
  | Unrequested_object of Object_id.t
  | Duplicate_request of Object_id.t
  | Requested_object_limit_exceeded of { count : int; limit : int }
  | Transferred_object_limit_exceeded of { count : int; limit : int }
  | Control_budget_exceeded of { used : int; limit : int }
  | Object_budget_exceeded of { used : int; limit : int }
  | End_with_pending_requests of int
  | Peer_error of { code : string; detail : string }

type receiver
type received_object

val protocol_version : int
val supported_required_features : int64
val max_control_message_bytes : int
val max_ids_per_page : int
val max_session_control_bytes : int
val max_session_object_ids : int
val max_total_object_bytes : int
val error_to_string : error -> string
val session_id_of_bytes : string -> (session_id, error) result
val session_id_to_bytes : session_id -> string
val encode : message -> (string, error) result
val decode : string -> (message, error) result
val initial_receiver : object_byte_budget:int -> (receiver, error) result
val accept_hello : receiver -> message -> (receiver, error) result

val accept_inventory :
  receiver -> message -> (receiver * Object_id.t list, error) result

val register_want :
  receiver ->
  sequence:int64 ->
  Object_id.t list ->
  (receiver * message, error) result

val accept_object :
  receiver -> message -> (receiver * received_object, error) result

val accept_end : receiver -> message -> (receiver, error) result
val accept_error : receiver -> message -> (error, error) result
val received_object_id : received_object -> Object_id.t
val received_object_bytes : received_object -> string
