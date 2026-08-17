(** Unix-only runtime scheduler for explicitly configured peer-sync transports.
    Its socket, capability, schedule, and status files are private runtime data,
    never canonical Yeokcham objects or refs. *)

type transport =
  | Local of {
      source_root : string;
      source_key : string;
      head : Yeokcham_id.Peer_sync_node_id.t;
    }
  | Relay of { relay : string }
  | Ssh of {
      known_hosts : string;
      ssh_config : string option;
      head : Yeokcham_id.Peer_sync_node_id.t;
    }

type configuration
type daemon

type poll_status =
  | Waiting
  | No_current_update
  | Tracking_advanced
  | Tracking_already_current
  | Tracking_diverged
  | Failed
  | Stopped

type status

type error =
  | Invalid_configuration of string
  | Private_key_error of string
  | Local_daemon_error of Yeokcham_local_daemon.error
  | Peer_error of Yeokcham_peer_sync.error
  | Relay_error of Yeokcham_peer_sync_relay.error
  | Ssh_error of Yeokcham_peer_sync_ssh.error
  | Store_error of Yeokcham_store.error
  | Status_error of string
  | Io_error of string

val error_to_string : error -> string
val max_retry_delay_seconds : float

val make_configuration :
  root:string ->
  runtime_dir:string ->
  contact:Yeokcham_id.Peer_contact_id.t ->
  identity:Yeokcham_id.Peer_id.t ->
  tracking_name:string ->
  transport:transport ->
  (configuration, error) result

val start : configuration -> (daemon, error) result
val run : daemon -> idle_timeout:float -> (unit, error) result
val close : daemon -> unit
val poll_once : daemon -> (poll_status, error) result
val endpoint : daemon -> Yeokcham_local_daemon.endpoint
val status_path : root:string -> runtime_dir:string -> (string, error) result
val read_status : root:string -> runtime_dir:string -> (status, error) result
val status_kind : status -> poll_status
val poll_status_to_string : poll_status -> string
val status_attempts : status -> int
val status_detail : status -> string
val status_next_retry_at : status -> float option
val ping : root:string -> runtime_dir:string -> (unit, error) result
val shutdown : root:string -> runtime_dir:string -> (unit, error) result
val recover_stale : root:string -> runtime_dir:string -> (unit, error) result
