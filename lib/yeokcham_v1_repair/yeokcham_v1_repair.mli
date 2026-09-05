(** Conservative V1 repair adapters.

    The backup adapter treats its explicit path as an existing V1 object-store
    root. Planning reads both roots and writes only a create-only local repair
    plan. Applying rechecks the selected envelope and current closure while
    holding the target state-head lock, then delegates publication to the
    immutable object store's add-if-missing primitive. Neither operation
    materialises an ordinary source file. *)

type error =
  | Health_error of Yeokcham_v1_health.refusal
  | Health_store_error of Yeokcham_v1_health_store.error
  | Store_error of Yeokcham_store.error
  | V1_store_error of Yeokcham_v1_store.error
  | Gc_error of Yeokcham_v1_gc.error
  | Package_error of Yeokcham_v1_package.error
  | Transport_config_error of Yeokcham_v1_transport_config.error
  | Transport_credential_error of Yeokcham_v1_transport_credential.error
  | Transport_http_error of Yeokcham_v1_transport_http.error
  | No_configured_relay_repository
  | Bootstrap_error of Yeokcham_v1_bootstrap.error
  | Invalid_bootstrap_artifact of { path : string; detail : string }
  | Missing_state_head
  | Invalid_backup of { path : string; detail : string }

type apply_result =
  | Applied of Yeokcham_v1_health.repair_candidate
  | Refused of Yeokcham_v1_health.refusal

val error_to_string : error -> string

val plan_from_backup :
  root:string ->
  backup:string ->
  created_at:int64 ->
  expires_at:int64 ->
  (Yeokcham_v1_health.repair_plan, error) result
(** Enumerates only exact missing-object candidates readable from [backup]. An
    absent backup object is not a candidate; malformed or mismatched backup
    bytes refuse planning rather than becoming visible in [root]. *)

val plan_from_gc_quarantine :
  root:string ->
  transaction_id:string ->
  created_at:int64 ->
  expires_at:int64 ->
  (Yeokcham_v1_health.repair_plan, error) result
(** Enumerates only fully revalidated staged objects from one named existing GC
    transaction. It neither restores, purges, changes, nor creates a GC
    transaction. *)

val plan_from_offline_package :
  root:string ->
  package:string ->
  created_at:int64 ->
  expires_at:int64 ->
  (Yeokcham_v1_health.repair_plan, error) result
(** Reads the existing package manifest and every object through the package's
    canonical artifact reader. It is not package receipt or import. *)

val plan_from_configured_relay :
  root:string ->
  remote:string ->
  created_at:int64 ->
  expires_at:int64 ->
  (Yeokcham_v1_health.repair_plan, error) result
(** Fetches exact raw object bytes only through an existing local relay alias
    and its custodial credential. It creates neither a receipt nor a transport
    session, and requires a verified collaborative repository identity. *)

val plan_from_bootstrap_artifact :
  root:string ->
  artifact:string ->
  created_at:int64 ->
  expires_at:int64 ->
  (Yeokcham_v1_health.repair_plan, error) result
(** [artifact] is an existing package directory whose regular
    [bootstrap-basis-v1.cbor] is a separately signed existing Bootstrap record.
    Planning verifies the basis and exact package closure but does not perform
    bootstrap, receipt, project-state, or ordinary-source work. *)

val apply_from_backup :
  root:string ->
  plan_id:string ->
  selection:Yeokcham_v1_health.selection ->
  now:int64 ->
  (apply_result, error) result
(** Rechecks the named local plan and explicit backup candidate. An expiry,
    state-head, diagnosis, source, candidate, or destination change returns
    [Refused]. [Applied] publishes at most the selected immutable object. *)

val apply_from_gc_quarantine :
  root:string ->
  plan_id:string ->
  selection:Yeokcham_v1_health.selection ->
  now:int64 ->
  (apply_result, error) result

val apply_from_offline_package :
  root:string ->
  plan_id:string ->
  selection:Yeokcham_v1_health.selection ->
  now:int64 ->
  (apply_result, error) result

val apply_from_configured_relay :
  root:string ->
  plan_id:string ->
  selection:Yeokcham_v1_health.selection ->
  now:int64 ->
  (apply_result, error) result

val apply_from_bootstrap_artifact :
  root:string ->
  plan_id:string ->
  selection:Yeokcham_v1_health.selection ->
  now:int64 ->
  (apply_result, error) result
