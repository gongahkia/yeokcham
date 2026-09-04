(** Conservative V4 repair adapters.

    The backup adapter treats its explicit path as an existing V4 object-store
    root. Planning reads both roots and writes only a create-only local repair
    plan. Applying rechecks the selected envelope and current closure while
    holding the target state-head lock, then delegates publication to the
    immutable object store's add-if-missing primitive. Neither operation
    materialises an ordinary source file. *)

type error =
  | Health_error of Yeokcham_v4_health.refusal
  | Health_store_error of Yeokcham_v4_health_store.error
  | Store_error of Yeokcham_store.error
  | V4_store_error of Yeokcham_v4_store.error
  | Missing_state_head
  | Invalid_backup of { path : string; detail : string }

type apply_result =
  | Applied of Yeokcham_v4_health.repair_candidate
  | Refused of Yeokcham_v4_health.refusal

val error_to_string : error -> string

val plan_from_backup :
  root:string ->
  backup:string ->
  created_at:int64 ->
  expires_at:int64 ->
  (Yeokcham_v4_health.repair_plan, error) result
(** Enumerates only exact missing-object candidates readable from [backup]. An
    absent backup object is not a candidate; malformed or mismatched backup
    bytes refuse planning rather than becoming visible in [root]. *)

val apply_from_backup :
  root:string ->
  plan_id:string ->
  selection:Yeokcham_v4_health.selection ->
  now:int64 ->
  (apply_result, error) result
(** Rechecks the named local plan and explicit backup candidate. An expiry,
    state-head, diagnosis, source, candidate, or destination change returns
    [Refused]. [Applied] publishes at most the selected immutable object. *)
