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
  (t, string) result

val digest : t -> string

val load :
  root:string ->
  operation:string ->
  digest:string ->
  safety:Yeokcham_snapshot.Snapshot.id ->
  target:Yeokcham_snapshot.Snapshot.id ->
  (t, string) result

val apply : root:string -> t -> (unit, string) result
val retained_directory : root:string -> operation:string -> string

module For_test : sig
  val apply :
    observe:(boundary -> string list -> unit) ->
    root:string ->
    t ->
    (unit, string) result
end
