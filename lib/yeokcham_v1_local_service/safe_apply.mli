type error =
  | Conflict of string
  | Unavailable of string
  | Invalid_plan of string

val error_to_string : error -> string

val check :
  root:string ->
  store:Yeokcham_store.repository ->
  safety:Yeokcham_snapshot.Snapshot.id ->
  target:Yeokcham_snapshot.Snapshot.id ->
  Yeokcham_snapshot.Observation.t ->
  (unit, error) result

(* read-only preflight: no staging, source writes, journal or history updates.
    Actual application also probes/stages native representations before mutation. *)
type t
(** Local filesystem application plans. Displaced nodes remain in private
    staging. Conflicts never trigger an automatic rollback over live files. *)

type boundary = Before_mutation | After_mutation | After_sync

val prepare :
  root:string ->
  store:Yeokcham_store.repository ->
  operation:string ->
  safety:Yeokcham_snapshot.Snapshot.id ->
  target:Yeokcham_snapshot.Snapshot.id ->
  Yeokcham_snapshot.Observation.t ->
  (t, error) result

val digest : t -> string

val load :
  root:string ->
  operation:string ->
  digest:string ->
  safety:Yeokcham_snapshot.Snapshot.id ->
  target:Yeokcham_snapshot.Snapshot.id ->
  (t, error) result

val apply :
  root:string -> store:Yeokcham_store.repository -> t -> (unit, error) result

val retained_directory : root:string -> operation:string -> string

module For_test : sig
  val apply :
    observe:(boundary -> string list -> unit) ->
    store:Yeokcham_store.repository ->
    root:string ->
    t ->
    (unit, error) result
end

val check_copyout :
  root:string ->
  store:Yeokcham_store.repository ->
  target:Yeokcham_snapshot.Snapshot.id ->
  destination:string ->
  (string * string, error) result

val prepare_copyout :
  root:string ->
  store:Yeokcham_store.repository ->
  operation:string ->
  target:Yeokcham_snapshot.Snapshot.id ->
  destination:string ->
  (t, error) result

val destination : t -> string option
val copyout_token : t -> string
