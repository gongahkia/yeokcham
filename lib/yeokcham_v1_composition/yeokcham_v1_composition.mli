module Line_hunks = Line_hunks
module Core = Yeokcham_v1_model.Core

type path = string list

type entry =
  | Directory
  | File of {
      mode : Yeokcham_snapshot.file_mode;
      content : Yeokcham_snapshot.Content.id;
    }

type tree

type error =
  | Invalid_input of string
  | Unavailable of string
  | Integrity of string
  | Conflicts of path list

val error_to_string : error -> string
val entries : tree -> (path * entry) list
val tree : (path * entry) list -> (tree, error) result
val load : Yeokcham_store.repository -> Core.Object_id.t -> (tree, error) result

val store :
  Yeokcham_store.repository -> tree -> (Core.Object_id.t, error) result

val differences : tree -> tree -> path list

val overlay : base:tree -> (path * entry option) list -> (tree, error) result
(** Install already-proved scoped values/absence. Structural replacements remove
    descendants; the resulting parent/tree invariants are revalidated. *)

val select :
  base:tree ->
  observed:tree ->
  paths:path list ->
  excluded:path list ->
  (tree, error) result

val merge :
  Yeokcham_store.repository ->
  base:tree ->
  variants:tree list ->
  (tree, error) result
(** Only immutable content/tree objects can be staged. No working-file, state
    root, cursor, accepted-history or publication mutation. *)

module Scope : sig
  val max_page_bytes : int

  val store :
    Yeokcham_store.repository -> path list -> (Core.Object_id.t, error) result

  val load :
    Yeokcham_store.repository -> Core.Object_id.t -> (path list, error) result

  val closure :
    Yeokcham_store.repository ->
    Core.Object_id.t ->
    (Yeokcham_store.Stored_object_id.t list, error) result
end

val validate_revision :
  Yeokcham_store.repository -> Core.shared_revision -> (unit, error) result
(** Full base/result/scope validation. A declared scope must equal the actual
    changed path set; no metadata path or undeclared private difference. *)

module Witness : sig
  val inspect :
    Yeokcham_store.repository ->
    snapshot:Core.Object_id.t ->
    paths:path list ->
    ( (path * entry option) list * Yeokcham_store.Stored_object_id.t list,
      error )
    result
  (** Proves selected entries/absence using only snapshot and ancestor tree
      objects. Does not read or retain unrelated private content blobs. *)
end

module Graph : sig
  type failure =
    | Content_error of error
    | Invalid_graph of string
    | Decision of string

  val error_to_string : failure -> string

  val accepted :
    Core.pool -> Core.Record_id.t -> (Core.accepted_version, failure) result

  val represented :
    Core.pool ->
    Core.Record_id.t list ->
    (Core.Record_id.t list, failure) result

  val represented_revisions :
    Core.pool -> Core.Record_id.t list -> (Core.Record_id.t list, failure) result
  (** Exact revision ancestry through both previous versions and dependencies.
      Unlike pending composition, this includes superseded version witnesses. *)

  val common_base :
    Core.pool -> Core.Record_id.t list -> (Core.Record_id.t, failure) result

  val compose :
    Yeokcham_store.repository ->
    Core.pool ->
    parents:Core.Record_id.t list ->
    revisions:Core.Record_id.t list ->
    (tree, failure) result

  val validate :
    Yeokcham_store.repository -> Core.pool -> (unit, failure) result
  (** Verifies actual revision scopes and deterministic accepted results, then
      checks that branch advancement preserves every inherited accepted head.
      Signatures/current authority are the caller's separate trust boundary. *)
end
