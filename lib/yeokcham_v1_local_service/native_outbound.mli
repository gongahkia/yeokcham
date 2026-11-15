module Transport = Yeokcham_v1_transport

type error =
  | Package_error of Yeokcham_v1_package.error
  | Store_error of Yeokcham_v1_store.error
  | Transport_error of Transport.error
  | Signer_required
  | Metadata of string

val error_to_string : error -> string

type outbound = {
  batch : Transport.Core_outbox.batch;
  artifact : Yeokcham_v1_package.artifact;
  reused : bool;
}

val prepare :
  root:string ->
  remote:string ->
  endpoint:string ->
  signing_capability:Yeokcham_v1_trust.signing_capability option ->
  (outbound option, error) result
(** Freezes a complete public Core manifest and signed courier under the sole
    state root before network requests. A pending batch is reconstructed exactly
    without another signature. Caller disposes the returned temporary artifact.
    Endpoint is the SHA-256 of the configured HTTPS URL. *)

val acknowledge :
  root:string ->
  remote:string ->
  endpoint:string ->
  publication:string ->
  (unit, error) result
(** Call only after relay acknowledgement of the exact immutable courier. This
    records a transfer fact; it never performs capture or acceptance. *)

type boundary =
  | Freeze_before
  | Freeze_after
  | Acknowledge_before
  | Acknowledge_after

module For_test : sig
  val prepare :
    observe:(boundary -> unit) ->
    root:string ->
    remote:string ->
    endpoint:string ->
    signing_capability:Yeokcham_v1_trust.signing_capability option ->
    (outbound option, error) result

  val acknowledge :
    observe:(boundary -> unit) ->
    root:string ->
    remote:string ->
    endpoint:string ->
    publication:string ->
    (unit, error) result
end
