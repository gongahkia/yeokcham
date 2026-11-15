module Core = Yeokcham_v1_model.Core
module Plan = Yeokcham_v1_integration

type version = {
  version_id : string;
  name : string;
  snapshot : Core.Object_id.t;
  entry : Yeokcham_v1_composition.entry option;
  preview_escaped : string option;
  preview_truncated : bool;
}

type conflict = {
  conflict_id : Core.Digest.t;
  source_plan : Core.Plan_id.t;
  path : string list;
  private_workspace : bool;
  versions : version list;
}

type inspection = { plans : Plan.t list; conflicts : conflict list }

val inspect :
  root:string ->
  plan:Core.Plan_id.t option ->
  (inspection, Native_integration.error) result
(** Revalidates current retained alternatives, or prepares the eligible exact
    shared revisions for inspection. Does not accept work or change files. *)

type choice = Use of string | File of string | Defer

type outcome = {
  source : Core.Plan_id.t;
  conflict : Core.Digest.t;
  prepared : Plan.t;
  deferred : bool;
  public_resolution : Core.Record_id.t option;
  retained : bool;
  retention_error : string option;
}

val resolve :
  root:string ->
  plan:Core.Plan_id.t option ->
  conflict:Core.Digest.t ->
  choice:choice ->
  signer:(unit -> (Yeokcham_v1_trust.signing_capability, string) result) ->
  (outcome, Native_integration.error) result
(** Exact path choice followed by a fresh retained proposal. A shared choice
    publishes only its scoped authenticated resolution proposal. A workspace
    choice remains private plan data. Neither action accepts work, moves the
    cursor or rewrites ordinary files. The signer runs outside the writer lock.
    A published proposal whose alias could not be retained returns
    retained=false with exact retry identities, rather than claiming completed
    preparation. Use "resolution:RECORD_ID" reuses a matching authenticated
    proposal without a signer or the original replacement file. *)
