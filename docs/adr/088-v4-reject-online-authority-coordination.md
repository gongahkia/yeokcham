# ADR-088 — V4 rejects online authority coordination

- Status: Accepted
- Date: 2026-08-30
- Implements: GitHub issue #259

## Context

V4 authority is a locally verified, immutable graph of signed authority epochs.
An active administrator may enrol, revoke, rotate, or sign work from a current
epoch while disconnected. Concurrent actions remain separate visible heads;
they are reconciled only by an explicit signed multi-parent epoch. Recovery is
also an explicit, locally held authority and never a network service.

The relay introduced by ADR-085 stores and lists immutable bytes. Its access
registry is operator-local storage policy. Neither is an authority source or a
source of intent. A remote observation is therefore useful courier evidence,
but it cannot select an epoch, invalidate a locally valid authority action, or
turn one branch into an implied winner.

This ADR evaluates whether V4 should replace or supplement that model with
online coordination to avoid authority forks. The alternatives considered were
a central coordinator, a replicated consensus quorum, threshold co-signing,
and an append-only witness/transparency service.

## Decision

V4 rejects online authority coordination. No network service, quorum, lease,
threshold signature, witness receipt, timestamp, or observed remote state may
approve, serialize, select, reject, or make an authority action conditional on
network reachability.

The existing rule is absolute: an administrator active in a verified current
epoch may perform V4 authority actions while disconnected. Concurrent results
remain explicit authority heads. A normal successor must name one selected
parent; a reconciliation must name every selected head and satisfy the existing
common-administrator or recovery rule. No service may synthesize that parent
selection or reconciliation.

An optional future network service may transport signed records, expose an
advisory observation, or provide audit evidence, but it is outside authority
semantics. Its absence, refusal, stale response, equivocation, or partition
cannot make a locally valid V4 transition invalid or unavailable. It must not
be a required prerequisite for enrolment, revocation, rotation, recovery,
sharing, resolution, adoption, receipt, or delivery.

## Alternatives rejected

### Central coordinator

A central authority endpoint could serialize requests while it was reachable,
but it would become a party able to censor, reorder, or equivocate about
membership and recovery. Treating its response as required would make its
availability and operator trust part of every authority action. That contradicts
local verification and the explicit recovery design.

### Replicated consensus quorum

A quorum can produce one committed sequence only when the required members can
communicate. A partitioned minority must wait, so an enrolment, revocation,
rotation, or recovery would become unavailable precisely when V4 currently
records the action as a visible fork. It also requires a new quorum membership,
reconfiguration, bootstrap, recovery, and operator model. The existing relay
cannot supply this role: it is deliberately an untrusted byte courier.

### Threshold co-signing

Threshold signing distributes one signing key; it does not decide which people
participate, how the group changes, when a missing participant blocks progress,
or how recovery replaces a share. Making a threshold signature authoritative
would add all of those policies and turn individually inspectable V4 authority
actions into a new shared-key authority system. It is not a signer-custody
adapter and is not implied by future hardware-key work.

### Witness or transparency service

An append-only log can give evidence that a record was observed and can help
detect equivocation after clients compare views. It cannot prevent concurrent
offline actions, determine the valid reconciliation, or make one head the
authority without becoming a coordinator. V4 may consider such audit evidence
separately, but it has no authority effect.

## Invariants

1. V4 authority validity is determined solely by locally verified canonical
   certificates, epoch records, signed work records, and recovery material.
   Network reachability, wall-clock time, and service responses are not inputs
   to authority validity.
2. A service cannot suppress, order, or select a valid epoch. Multiple valid
   successors of one parent remain explicit heads until a valid explicit
   reconciliation names selected parents.
3. An authority action that is valid under a local current epoch stays valid
   when its relay, coordinator-like service, or peer set is unreachable.
4. Relay access credentials, transport publications, runtime state, and any
   future audit receipt are not authority records and cannot grant, revoke, or
   constrain V4 authority.
5. Any proposal to supersede this decision must first define its changed
   safety, liveness, partition, recovery, revocation, key-custody, and
   operator-trust semantics; it must then receive a separate ADR and atomic
   implementation issues before code or persistent-format work begins.

## Consequences

V4 retains its present cost: administrator disagreement can create an authority
fork that humans must inspect and explicitly reconcile. This is durable process
state, not a transient network error. The benefit is that a partition, relay
outage, or service operator cannot silently remove a team's ability to protect
membership or recover authority.

There is no new type, command, persistent record, network endpoint, or test
fixture from this decision. Existing authority-fork, reconciliation, recovery,
package, and inspection tests remain the evidence for the preserved behaviour.
Future non-authoritative transport or audit work must state its limits without
calling itself authority coordination.

## References

- [Gilbert and Lynch, Brewer's Conjecture and the Feasibility of Consistent,
  Available, Partition-Tolerant Web Services](https://www.cs.princeton.edu/courses/archive/spr22/cos418/papers/cap.pdf)
- [Ongaro and Ousterhout, In Search of an Understandable Consensus
  Algorithm](https://raft.github.io/raft.pdf)
- [RFC 9591: The Flexible Round-Optimized Schnorr Threshold (FROST)
  Protocol](https://www.rfc-editor.org/rfc/rfc9591.html)
- [RFC 9162: Certificate Transparency Version 2.0](https://www.rfc-editor.org/rfc/rfc9162.html)
