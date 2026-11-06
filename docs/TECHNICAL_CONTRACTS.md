# Technical contracts and implementation defaults

Status: design baseline, November 6, 2026. TC01/TC02 behavior is explicitly agreed.
The user subsequently authorized choosing logical defaults for the remaining
audit items. TC03-TC08 and the concrete defaults in the linked CLI/review/benchmark
documents are decisions made under that delegation, not individually answered
preferences or implemented features. See the [product design](PRODUCT_DESIGN.md).

Implementers should use these defaults without another preference questionnaire.
Numeric scheduling/resource values are initial tunable settings, not measured
performance promises. A change to a correctness/privacy boundary requires a
recorded design revision; tuning within those boundaries requires measurements.
Byte-level schemas and test vectors are the first implementation deliverable
before dependent consumers, not a reason to leave the behavior undecided.

A contract states what a component receives, what it produces, what remains
true, and how interruption or conflicting work is handled. Components may be
implemented separately only after their shared contracts are sufficiently
specified. Logical record types do not imply separate services, storage files,
or additional user commands.

## Contract map

1. History and identity of work: snapshots, local ancestry, published revisions,
   accepted versions, and reviews. TC01 agreed; encoding defaults are in TC06.
2. Integration execution: exact preview binding, approval checks, deterministic
   composition, concurrent heads, and recoverable application to working files.
   TC02 behavior agreed; composition and journal defaults are in TC06.
3. Private account and archive: device enrollment/recovery, encryption boundaries,
   complete backup acknowledgement, restoration, retention, and quota accounting.
4. Background service: capture scheduling, transfer retry, and platform lifecycle.
5. Storage: incremental persistence, compression/packing, and collection.
6. Record formats, composition, review policy, and recoverable application.
7. Native ignore matching, capture consistency, and filesystem portability.
8. Validation and implementation dependencies. Use the
   [benchmark design](BENCHMARK_DESIGN.md) for evidence.

The [CLI design](CLI_DESIGN.md) applies to every contract: expose enough domain
information to explain outcomes, preserved work, and next actions in plain
language. User comprehension is an implementation requirement from the start.

## TC01: identity and history of work

Status: agreed at the logical-model and behavior level. Concrete encodings and
API signatures follow TC06's defaults and the schema-first handoff in TC08;
this agreement does not imply they already exist in the implementation.

### Agreed logical records

| Record | Meaning | Identity and change rules |
| --- | --- | --- |
| Snapshot | Exact recorded project contents within the documented filesystem/ignore scope. | Immutable content identity. Storage compression or packing must not change its logical identity. |
| Local history node | A position in one workspace's editing history, referring to a snapshot and parent. | Distinct from content identity: identical contents can occur at multiple positions. Preserve ancestry and alternate continuations. |
| Shared revision | One explicitly published version of a named change, with its base, result, author, and declared edit scope. | Immutable and authenticated. Updating the change creates another revision; it does not mutate a reviewed version. |
| Accepted version | The exact result of an explicit integration, with its accepted parent version(s), included revisions/resolutions, and relevant policy/review evidence. | Immutable and authenticated. Its result must match the validated integration plan. |
| Review request/version and review event | A request to inspect selected published work, and a comment/approval/change request about a particular version. | A stable request groups immutable versions and events. Approval covers exact work and context, never a floating latest label. |

Mutable convenience state, such as the current local cursor or a selected branch
head, refers to these records. Moving a pointer does not rewrite its previous
target. A shared branch is not the same object as a local undo branch or a draft
title. Their representation and concurrent-update rules are part of TC02.

These records are internal bookkeeping. The user's normal flow remains editing,
explicit sharing/review where desired, and previewed integration; there is no
new command for manually creating each record type.

### Local ancestry and multiple devices

Each workspace has its own history and current position. Receiving private
history from another enrolled device must not move that position or replace
working files. Resuming another workspace's recorded state is an explicit
selection/restoration operation.

The present undo node IDs are local integers. A private archive combining
workspaces needs a stable namespace, such as a workspace identity plus a local
node identifier, so two different node `7` values cannot be confused. TC06 fixes
that namespace and the duplicate/retry rules for exported private history.
Do not infer ancestry merely from equal snapshots, timestamps, or device names.

### Publishing is a stable boundary

Publishing revision R1 fixes the contents being shared. Subsequent captures of
unfinished local work do not change R1, an approval of R1, or the result of an
integration that names R1. Publishing updated work produces R2 explicitly.

Export only the declared published records and the content dependencies needed
for them. Private undo metadata, unselected private versions, account secrets,
and recovery material must not be included merely because they are in the same
local store. A public revision's declared scope and result must agree; the
composition/export contracts must prevent an unrelated private edit from being
smuggled into a supposedly narrower shared result.

### Accepted contents and current working files can differ

An accepted version records the chosen integration result, not whatever happens
to be in the integrator's working directory at that instant. The workspace may
still contain later private edits. Preserve those edits or require explicit
conflict handling rather than silently publishing or discarding them.

Example:

1. The user captures states B, C, returns to B, and develops D. Both C and D
   remain in the local undo tree while their contents are retained.
2. The user shares D as revision R1 and then edits E privately.
3. A teammate approves the exact version R1.
4. Integrating R1 against its unchanged base accepts D; it does not include E
   simply because E is now present in the working files. E stays recoverable as
   unfinished local work. If a different base requires a different result, the
   revised composition/review/preview rules apply to that result explicitly.

This addresses a real current boundary: V1 delivery records an observed working
snapshot and included revision IDs without proving that the two describe the
same composition. The replacement must not inherit that ambiguity by merely
renaming delivery.

### Offline acceptance preserves competing histories

An integration performed offline records its known accepted parent(s), exact
result, and the authority/policy/reviews available locally. It cannot claim that
all other devices have observed or accepted it.

If two members independently integrate different work from the same accepted
version, retain both resulting records after synchronization. Arrival time does
not decide which contents survive. A new reconciliation result must name the
histories it combines and obey the usual review and preview requirements.
Synchronization can discover and prepare that reconciliation; receipt alone
does not authorize applying a newly composed result.

### Contract checks

- Equal contents can have different local history node IDs; repeated transfer
  of an existing record does not create a new edit or duplicate acceptance.
- New private edits do not mutate a previously shared or reviewed revision.
- A shared export contains no unrelated private ancestry or unselected content.
- Integrating a reviewed version does not accidentally include later local edits.
- Confirmed result identity equals recorded accepted snapshot identity.
- Concurrent offline accepted versions survive synchronization in either order.
- Receiving history never silently moves another workspace's local cursor.
- Review decisions remain attached to their actual immutable version/context.

## TC02: integration planning and execution

Status: agreed at the behavior and invariant level, including D27's configurable
renewed-review requirement. This gives D18's preview/confirmation and D21's
offline integration concrete boundaries, while preserving TC01's separation of
accepted contents from private working edits. TC06 supplies the chosen encoding,
composition, and journal defaults; TC08 orders the remaining implementation work.

### An integration is one exact plan

Preparing an integration resolves floating names to exact records and constructs
an immutable plan. The logical inputs and outputs are:

| Part | Required information |
| --- | --- |
| Repository and target | Repository identity, target shared branch, and locally known accepted parent/head identities. |
| Chosen work | Exact shared revision IDs, dependency/base records, and any explicit resolution revisions. |
| Authorization and review | Relevant authority and repository-policy identities, review request version, and approval evidence when required. |
| Workspace context | Workspace identity, local history position, recorded working basis, and an exact observation of current disk contents. |
| Accepted result | Deterministically composed snapshot of the selected shared work, excluding unrelated private edits. |
| Workspace result | Proposed post-integration working snapshot preserving private edits, or explicit conflicts preventing safe application. |
| Plan identity | A canonical identity binding these inputs, outputs, conflicts, and the composition-rule version. |

TC06 defines encoding defaults; concrete function signatures follow those records.
The interface must distinguish ready plans from missing contents, unresolved
conflicts, invalid authority, or missing required approval. Preparation can stage
immutable objects and read local state, but cannot advance accepted history,
publish acceptance, or modify ordinary files.

Human confirmation authorizes this plan identity. When confirmation is disabled
by an explicit preference or invocation, the same plan, validation, and policy
checks still apply. Disabling confirmation is not authority to change its inputs
while applying it.

### Composition is deterministic and scope-checked

Construct the accepted result from the named accepted base(s), selected published
revisions, and explicit resolutions. Identical canonical inputs must produce the
same result or the same unresolved decisions, regardless of relay arrival order.
Do not substitute a fresh scan of the live workspace for the accepted result.

Dependencies and incompatible overlapping edits must be explicit. Compatible
changes can be combined by the specified composition algorithm; opaque-file
conflicts require an exact version or explicit replacement, not a guessed byte
merge. Source revisions whose declared edit scope and base/result contents
disagree must be rejected before their contents can be accepted or exported.
No runtime AI service is needed to decide these mechanical conditions.

TC06 fixes the initial text-composition profile and deterministic limits. Clients
must not choose different merge algorithms for the same accepted record.

### Two outputs preserve private work

The accepted snapshot and working snapshot can differ. Use the recorded workspace
basis, local ancestry, and known correspondence to selected shared revisions to
preserve later private edits. Do not naively replay an already-present shared
edit twice or count the entire working-tree difference as newly accepted work.

For the TC01 example, accepting shared D while the user has privately edited E
records D as accepted and retains E in the workspace when their relationship is
known and compatible. If incoming changes conflict with private edits, show that
as a workspace conflict and stop the default application before writes. Preserve
both the private state and proposed accepted result for explicit resolution;
do not silently publish, discard, or temporarily hide the private work.

The preview shows both effects: what enters accepted history and what changes
in the current files. Requiring a conflict to be resolved is separate from a
review approval or confirmation preference.

### Review approval across target advances

Agreed default rule: approval remains approval of the exact submitted revision
and its reviewed file-level context. An unrelated accepted change elsewhere in
the repository need not force another review when the submitted revision and
the preconditions/contents on every affected path remain unchanged. Still
regenerate the integration preview when its target head changes.

Changing submitted contents, manually resolving a conflict, or changing relevant
file/path context means the prior approval does not cover the new composition.
Approval does not certify semantic compatibility with every other file in the repository.
The mechanical coverage check must be explicit and conservative, including
ancestor path/type changes; ambiguous coverage requires review again by default
when the repository enforces approval. Unrelated target changes do not force
another review when the stated coverage remains unchanged.

### Two independent safeguards and their opt-outs

Both safeguards are enabled by default and may be disabled after a warning:

- Integration preview confirmation (D18) is a personal account/repository
  preference. Its warning explains that future explicit integration requests
  can apply without a confirmation pause. It does not disable team review rules.
- Requiring renewed approval after relevant changes (D27) is a repository review
  policy. Authorized repository policy changes can disable it, with a warning
  that later content or conflict resolutions may be integrated without anyone
  reviewing those changes. Personal preferences cannot override this policy.

Required reviews themselves remain opt-in (D25). In an advisory repository,
review freshness is reported but does not introduce a mandatory approval gate.
When required reviews are enabled and renewed approval is disabled, the policy
may permit proceeding on evidence of an earlier review. The old approval stays
bound to its exact version/context; never label the new content as reviewed or
fabricate approval of it. Expose the effective policy and the uncovered changes
in inspection and record the policy/evidence used for acceptance.

Disabling either or both settings never disables conflict detection/resolution,
plan revalidation, authorization, exact-result verification, or preservation of
private work. Reduced review can allow mistakes or semantic incompatibilities
through; it does not authorize silently choosing a side of a detected conflict.
Re-enabling renewed approval requires current coverage for future integrations;
it does not rewrite earlier accepted history or old approval records.

The [review workflow](REVIEW_WORKFLOW_DESIGN.md) specifies the chosen eligibility
rules for earlier-review evidence; TC06 defines the policy/evaluation defaults.
Warn at opt-out with the affected scope, show the active
setting in status/inspection, and avoid replacing the opted-out pause with an
equivalent warning prompt on every operation.

### Revalidate after confirmation

Before applying, verify that the plan's relevant inputs are still current and
that all required result objects are present and valid. A changed working tree,
local cursor/basis, target head, chosen review version, or relevant authorization
and approval state makes the plan stale. Show a new plan and obtain confirmation
again under the active preference rather than applying an unseen replacement.

Unrelated background receipts or comments should not by themselves invalidate
the plan. Check the inputs it actually depends on, then publish metadata against
the latest consistent local state so independent incoming records are preserved.
Serialize Yeokcham's own application/state writers around the critical section;
do not hold that lock while waiting for a human or performing network transfers.

### Recoverable application and publication

The agreed logical sequence is:

1. Validate the selected plan and all needed objects, preserve the exact current
   workspace in a durable recovery root, and write an operation journal binding
   the plan, old local state, accepted result, and workspace target.
2. Apply the working-file changes through the journaled materialization path.
   While incomplete, ordinary watcher capture must not record the partially
   applied tree as a normal editing state.
3. Verify the materialized workspace and atomically publish one local state
   update containing the accepted-version record, relevant local references,
   undo/recovery references, and durable outbound work for synchronization.
4. Mark the journal completed. The daemon sends only acceptance records exposed
   by committed local state; a staged or merely previewed record is not public.

The journal and local commit must make retry idempotent. A crash before the
local commit resumes the same confirmed operation; a crash after it recognizes
that operation as already committed. Neither case creates a second acceptance,
takes an additional undo step, or authorizes a different integration result.
Receipt failure or a lost network acknowledgement leaves the same outbound work
retryable. Remote availability is not part of the local commit condition.

This sequence is not an atomic filesystem transaction visible to editors or
other processes. TC06 defines path-level checks, interruption states, and
recovery defaults. Unexpected external edits must not be silently overwritten
by a retry; TC07 states the filesystem observation limits honestly.

### Concurrent offline results

Local integration records known parents and local authority/review context.
Synchronization transfers immutable records without declaring the last upload
to be the unique accepted head. If two members accepted different descendants,
preserve both and present their divergence for reconciliation. A newly composed
result follows ordinary review and preview rules; simple receipt does not merge
it into the working files or grant approval for its contents.

If newly received authority or policy makes admission of a local operation
questionable, retain the local work and expose the discrepancy. Do not invent
retroactive global approval from local success. TC06 reuses the explicit trust
model for admission and concurrent branch/policy references.

### Contract checks

- A previewed integration creates no accepted head or outgoing acceptance.
- A changed workspace or relevant shared head invalidates prior confirmation;
  unrelated receipt does not erase state or force unnecessary confirmation.
- Accepted output excludes later private edits while the workspace preserves them.
- Incompatible private edits block default application before file replacement.
- Required review cannot be bypassed by disabling preview confirmation.
- Unrelated target changes preserve eligible approval under the stated coverage
  rule; changed submitted work or relevant context does not inherit approval.
- Both safeguards default on and can be disabled independently with a scoped
  warning. A repository-authorized freshness opt-out is distinguished from a
  personal confirmation preference and from actually reviewing the new version.
- With renewed approval disabled, only eligible earlier-review evidence can
  satisfy the configured policy; missing/withdrawn approval and other policy
  blockers are not bypassed. Both settings off still block unresolved conflicts.
- Failures at each journal/metadata transition resume or recover the same
  operation without losing private data or creating duplicate acceptance.
- A failed upload retries the already-recorded acceptance rather than creating
  a new accepted version with new provenance.
- Concurrent offline integrations survive receipt in either order and require
  a separately authorized reconciliation result when contents change.

## TC03: private account, devices, and archive

Status: default decisions selected under the user's delegation. One personal
account belongs to one self-hosted deployment initially; multiple repositories
can use it. Team repository membership and private-account access are separate.

### Setup, enrollment, and recovery

- Local `init` works offline and starts local capture. Account/remote setup is
  optional until backup or collaboration is wanted. No hosted signup is needed.
- A self-hosted operator provisions account access with a one-use invitation;
  invitations expire after one hour and public registration is off. The client
  generates account keys, a new
  256-bit recovery secret, and a separate device identity. Reuse the existing
  24-word encoding, not the existing project-authority secret. Show the phrase
  in a private terminal ceremony and verify three requested words before marking
  recovery setup complete. Capture can continue if that ceremony is deferred.
- A new device generates its own signing and encryption keys. An enrolled device
  explicitly approves a pairing request after both terminals display the same
  fingerprint. Requests expire after ten minutes and are single-use. Relay tokens
  alone cannot approve a device or unlock history.
- Native project invitations carry repository identity and authority-root
  fingerprint. Verify and pin them when joining; a bare URL without a prior pin
  requires a one-time root confirmation. A changed pinned root blocks access.
  Private-account pairing does not itself grant team signing authority; preserve
  explicit repository enrollment and explain any needed invitation.
- If no enrolled device remains, the phrase recreates the account recovery
  capability, verifies the account identity, enrolls the replacement, and retrieves
  encrypted history. Server access and retained archive data are also necessary.
  Recovery defaults to revoking old devices after showing which devices are
  affected; it never silently resets a team repository's authority.
- Any current enrolled owner device can enroll or revoke another. Revocation
  creates a signed account-policy epoch and rotates keys for future private
  uploads; retain old epoch keys for historical restoration. Removed devices
  cannot receive new keys. Previously downloaded plaintext or keys cannot be
  recalled. Offline devices must refresh the account epoch before uploading.
- Credential custody defaults to the OS secret store, outside repository files.
  If locked/unavailable, keep capturing locally and report backup as waiting for
  account unlock; no daemon prompt or silent plaintext-key fallback. A headless
  deployment uses an explicitly configured credential provider. Recovery phrases
  never enter command arguments, logs, JSON output, or ordinary configuration.

### Encryption and identity defaults

Keep Ed25519 for signed device/control records. Give each device a separate
X25519 encryption key; account recovery signing and encryption keys are derived
from the high-entropy recovery secret using HKDF-SHA-256, fixed salt
`yeokcham/private-account/v1`, and distinct `recovery-signing` and
`recovery-encryption` info labels. The account ID hashes the canonical tuple of
protocol version and those two public keys, so the phrase can reconstruct the
account locator without an old device. Keep the server address in the recovery
instructions; the phrase cannot discover which self-hosted server was used.
Use the established [HKDF construction](https://www.rfc-editor.org/rfc/rfc5869).

Choose libsodium as the additional private-archive crypto provider. Encrypt each
compressed object/index page using a per-repository, per-epoch random 256-bit key
and XChaCha20-Poly1305 with a fresh random 24-byte nonce. Authenticated header data
binds the format, account, repository, epoch, object kind, and declared lengths.
Store the plaintext content identity inside the encryption. These nonce/key
choices follow the [libsodium AEAD interface](https://doc.libsodium.org/secret-key_cryptography/aead/chacha20-poly1305/xchacha20-poly1305_construction).

Wrap epoch keys separately for every enrolled device and the recovery public key
using libsodium sealed boxes. Sign the complete recipient/key-envelope record
under the account epoch: sealed boxes do not authenticate the sender on their
own. Bind recipient, repository, epoch, and key purpose inside the sealed payload.
See the [sealed-box interface](https://doc.libsodium.org/public-key_cryptography/sealed_boxes).
Library/binding integration and protocol test vectors are implementation work;
do not substitute handwritten cryptography or silently downgrade a provider.

Private object IDs on the server are hashes of ciphertext envelopes. An encrypted
per-repository index maps canonical plaintext IDs to these envelopes. Reuse an
existing verified envelope for unchanged content; independent concurrent uploads
may temporarily duplicate ciphertext and are reconciled without losing either
index. No convergent encryption or cross-account content deduplication. Names,
paths, and private ancestry stay encrypted; the server can observe account/repo
identifiers, object sizes, timings, and traffic volume. Public team exchange keeps
its existing visibility; private-backup encryption does not imply team E2EE.

### Backup completion, restoration, and cleanup

Use an idempotent object-upload protocol with a separate manifest commit:

1. The client builds an encrypted immutable manifest containing workspace/node
   ancestry, snapshots, the content index, and required key-envelope references.
   Keep all local roots protected while this manifest is pending.
2. Send a transport inventory of opaque ciphertext IDs/lengths, and upload missing
   objects with resumable verified ranges. The inventory reveals no filenames.
3. The server checks the entire inventory exists, flushes objects and indexes,
   and atomically commits the manifest and retention roots before acknowledging.
   Its receipt binds account/repository, manifest and inventory IDs, lengths,
   storage generation, and the server identity. A duplicate commit returns the
   same result; partial uploads are never reported as completed backups.
4. The client verifies the receipt and reads back/verifies newly uploaded objects
   and recovery envelopes before allowing their sole local copies to be evicted.
   Reused objects require existing verification records and current server
   inventory confirmation. Persist completion and dependency coverage locally.

This is a completeness/durability contract for the configured server, not a claim
that a server cannot subsequently lose or delete data. Missing/corrupt archive
objects revoke local eviction eligibility for affected history, trigger repair
from any remaining local copy, and appear as actionable backup failures.

Persist last-seen account epochs and archive roots to detect rollback relative
to a device's known state. A fresh recovery device cannot prove an untrusted
server disclosed every later record; show verified restored coverage without
claiming global freshness. Recovery authentication and completeness are distinct.

Restore downloads and verifies all required contents before workspace writes.
Recover the index and all retained epoch keys from the recovery envelopes on a
fresh device, without relying on the old device's local database. New devices
fetch the private history index automatically; fetch old private contents on
demand, plus current/pinned states for repositories registered on that device.

Use D15's 30-day / 5-GiB / 20-GiB limits unchanged. Evict only verified archived,
unprotected contents, oldest last-used state first; consider older-than-30-day
states first, then younger eligible states under pressure. Account limits apply
per device. Pins synchronize across the owner's devices for the same repository;
report pending pin downloads accurately. Current work, pending backups, shared
offline coverage, and recovery roots always override private capacity targets.
Remote automatic expiry remains off; quotas stop uploads rather than deleting
retained history. Permanent remote deletion is an explicit owner-authorized,
previewed operation, never implicit maintenance in the first implementation.

Personal settings use immutable signed per-key events with causal parents.
Merge independent keys; identical concurrent values coalesce. Concurrent edits
to the same key preserve both values and the last agreed effective value, and
show one setting conflict. Until resolved, do not evict on a disputed retention
setting, and keep confirmation enabled if either candidate enables it. Remote
credentials and local paths are device-local. Team policy is a separate record.

## TC04: managed background service

One process per signed-in OS user manages registered repositories, with a
per-repository writer lock and fair scheduling. Registration by `init`/`clone`
starts and enables the user service by default and reports what was enabled.
Use a macOS LaunchAgent and Linux systemd user service; a foreground `service run`
adapter supports environments without those managers. Windows follows with a
per-user login-started adapter. No root service or implied work while powered off.
See the platform [launchd](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
and [systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
interfaces. A failed installation is visible; never report a watcher as running
merely because registration succeeded.

Initial tunable defaults:

| Setting | Default |
| --- | --- |
| Capture debounce | 500 ms after a write burst; attempt capture at least every 5 seconds during continuous activity. |
| Reconciliation | Startup, wake, overflow/lost watcher events, and a metadata reconciliation every 60 seconds; rotate full content audits at least daily. |
| Outgoing transfer | Queue immediately after durable capture/publication; coalesce private backup manifests for at most 5 seconds. |
| Incoming changes | Long-poll when supported, with 30-second polling fallback. |
| Retry | Exponential delay from 1 second to 5 minutes, with 20% jitter; reset after progress/reconnect. Honor longer server retry instructions. |
| Concurrency | One workspace writer per repository, two background CPU workers and four transfer requests per process. |
| Background buffers/cache | 256 MiB process-wide target; stream large objects and use disk-backed indexes. This is not a maximum total RSS claim. |
| Maintenance | After 60 seconds without foreground work; yield on foreground requests and defer optional repacking on battery power. |

These intervals schedule attempts, not guaranteed durable capture of an unstable
file. Foreground inspection/restore and local capture take priority over uploads,
prefetch, and packing. No default bandwidth throttle on an ordinary connection;
permit an explicit per-device limit. Known metered connections defer automatic
bulk downloads and private uploads, while local capture and small control updates
continue; show deferred coverage. Explicit foreground requests can proceed after
showing their scope. Unknown connection cost behaves as an ordinary connection.

`pause` pauses this repository's network work, leaving local capture active;
`pause --all` also pauses capture. Both persist across restart until `resume`.
`--all-repos` selects every registered repository. No periodic nagging during an
intentional pause. Health/status always distinguishes paused, offline, locked,
retrying, blocked, and running. Never run hooks or arbitrary project-supplied
commands merely because remote data arrived.

On disk pressure, stop optional prefetch/repacking first and reclaim only eligible
archived data. Reserve existing recovery/temp space before materialization and
preflight the remaining needed space; a disk-full failure cannot report success.
If local capture cannot finish, retain the last durable state and pending dirty
paths, report that new edits are not yet captured, and retry after space returns.

## TC05: storage, compression, and transfer

- Preserve the existing canonical snapshot/object SHA-256 identities. Hash the
  canonical uncompressed envelope; physical compression and pack placement are
  storage wrappers. Verify decoded bytes, lengths, type, and ID on retrieval.
- Keep current Buzhash-v1 chunking initially: 64-byte window, 16-KiB minimum,
  64-KiB target, and 128-KiB maximum chunks. Stream files without a total-file-size
  exclusion. Text-merge limits do not limit capture/backup of large assets.
- Use Zstandard level 3 initially; store compressed bytes only when the saving is
  at least 64 bytes and at least 5%, otherwise keep raw bytes. Compress
  before private encryption. Pack small objects into immutable packs targeting
  64 MiB with indexed object boundaries; independently decompressible objects
  avoid reading an entire pack to restore one chunk. The existing
  [Zstandard library interface](https://raw.githubusercontent.com/facebook/zstd/dev/lib/zstd.h)
  supplies the codec; these settings are our initial defaults.
- Do not add inter-version delta chains or a new compression algorithm initially.
  Measure chunk reuse, packing, and Zstandard first. Any later delta proposal
  needs bounded dependencies and cold-restore evidence before becoming a default.
- Maintain content references and local undo history incrementally. Use bounded
  immutable history/index pages (at most 1 MiB), a rebuildable on-disk lookup
  index, and the existing compare-and-swap root pattern. Appending an edit updates
  bounded pages and ancestor indexes, never re-encodes the entire undo history.
- Physical deduplication is per repository initially. Cross-repository/account
  sharing is not needed for correctness. Count allocated private store/metadata
  bytes against private budgets, excluding shared-only objects; classify an
  object needed by shared coverage as protected shared storage. Report working
  files, shared data, private data, and maintenance overhead separately.
- Pack replacement writes and verifies new packs/indexes, atomically publishes
  their root, then reclaims superseded storage after readers/recovery roots are
  clear. Never delete old packs first. Collection uses a fixed root generation
  and rechecks under the writer lock before removal; new/pending roots are safe.
- Use the existing 1-MiB resumable transfer ranges with bounded streaming buffers,
  missing-object inventory, and persisted acknowledgements. Retry the same
  operation/ranges; do not compress encrypted bytes a second time. Download all
  shared branches/history by default, prioritizing the selected working version.
  Mark each scope available only after its complete dependency closure verifies.
- Retain existing explicit purge safeguards. Automatic cleanup removes eligible
  local archived copies or unreachable staging data; it does not silently expire
  private ancestry, promised shared coverage, or the only recoverable copy.

## TC06: records, composition, policy, and application defaults

### Canonical records and identities

Reuse `Yeokcham_encoding`'s canonical integer-keyed CBOR profile and the canonical
envelope/hash machinery. Do not sign JSON, host-language serialization, or
compressed bytes. New format/type codes are allocated once by the schema owner
and checked into the registry with golden vectors before consumers are assigned.
Unsupported mandatory versions fail explicitly; D10 permits replacing development
formats and fixtures without maintaining historical readers.

Signed record bodies use the ordered tuple `(kind, version, scope, parents,
author_certificate, authority_heads, payload, display_time)`. Sign the canonical
tuple with the fixed domain `yeokcham/record/<kind>/v1`; include certificate and
authority context in the signed bytes. Store body/signature in the canonical
typed envelope, whose SHA-256 is the immutable record ID. Unsigned local plans
use their own typed envelope/ID and cannot be published as signed acceptances.
Display time may be absent and never establishes authority or conflict ordering.
Parent/head sets are sorted by raw ID bytes and contain no duplicates.

Payload maps use consecutive integer keys in the following field order. Optional
values are explicit nulls; ordered sequences retain order and sets sort by raw ID.
The schema owner mechanically assigns field/type constants from this table and
checks cross-record constraints; no consumer invents a parallel encoding.

| Kind | Payload fields in order |
| --- | --- |
| Shared revision | change ID, previous revision IDs, base snapshot, result snapshot, declared edit-scope root, dependency revision IDs |
| Accepted version | branch ID, accepted parent IDs, chosen revision IDs, resolution IDs, result snapshot, composition profile, policy heads, review-evidence IDs |
| Branch event | branch ID, previous branch-event IDs, action, target accepted IDs, display name |
| Review version | request ID, previous request-version IDs, target branch ID, submitted revision IDs, comparison snapshot, affected-path context root, title, description |
| Review event | request-version ID, previous events by this reviewer, action, text, related event IDs |
| Repository policy | previous policy IDs, reviews-required flag, minimum approvals, renewed-approval flag |
| Account epoch | previous epochs, enrolled device keys/permissions, revoked device IDs, key-envelope inventory root |
| Personal setting | setting key, scope, previous events for this key, value |
| Archive manifest | workspace ID, history root, snapshot/index roots, epoch-key inventory root, previous archive manifest IDs |

Use random 128-bit IDs for workspaces, branches, changes, requests, and local
operation tokens. Private history node identity is `(workspace ID, sequence)`;
use a nonnegative signed-int64 sequence to fit the existing encoding. Allocate
under the writer lock and persist the sequence with its history append. Refuse
sequence exhaustion rather than wrapping or reusing an identity. Cloning/copying a workspace for concurrent use creates a
new workspace ID and records the ancestry link. Repeated identical records are
no-ops; the same node/operation ID with different payloads is an integrity error.
Public revision and accepted-version IDs are hashes, not local counters.

Page unbounded collections into immutable trees; control records are at most
8 MiB and collection/index pages at most 1 MiB. Reject overlong/malformed records
before expensive allocation. Limits apply to individual records, not repository
history or file size. Large titles/comments need a documented bounded input
error rather than silently truncating signed contents.

### Branches and policy under concurrency

The initial branch is `main`, starting from an authenticated empty accepted
snapshot. `init` captures existing files privately; they do not become public
merely by being present at initialization. Branch identity is independent of its
display name. Concurrent identical updates coalesce; incomparable branch heads
remain a set. Identical resulting contents alone do not discard distinct history.
An integration on a diverged branch names all heads it reconciles; default
integration does not conceal an unselected competing head. Duplicate names are
shown with short IDs, not silently retargeted.

Version repository policies using existing administrator authority. On a policy
fork, evaluate all causally maximal known policies: required review wins over
optional, renewed approval wins over its opt-out, and the greatest approval
count applies. Display the fork; an administrator explicitly reconciles policy
parents. Authority forks retain the existing explicit reconciliation requirement.
Account-enrollment forks block new key grants/uploads until reconciled; local
capture and already-decryptable restoration continue. Ordinary per-key personal
settings follow TC03 instead of team-policy rules.

Offline acceptance records the policy/authority actually known. Already-admitted
history stays identifiable. Late arrivals under superseded/revoked authority,
or newly discovered stricter policy they fail, are retained but withheld from
new team acceptance until explicit authorized adoption or a newly compliant
integration. Reuse the existing exact late-arrival authorization/adoption model;
do not trust backdated timestamps or make receipt a new authority decision.
Authority adoption does not waive review policy: the result must also satisfy
the effective repository review rules before becoming a newly admitted head.

### Deterministic composition profile: line-hunks-v1

First apply exact whole-path rules: one changed side wins over an unchanged side;
identical changes coalesce; different additions, delete-versus-edit, and
incompatible type changes conflict. Treat renames as deletion plus addition in
this first profile; rename detection is a display aid, not semantic authority.
Directory structure and executable-bit changes participate in the same checks.

For regular UTF-8 text without NUL bytes, derive base-to-result line hunks, keeping
line endings and final-newline bytes exact. Trim equal prefix/suffix lines, then
compute a longest-common-subsequence alignment for the remaining lines. On equal
alignment scores, consume a base deletion before a result insertion; consume
equal lines immediately. Coalesce adjacent edits into base-indexed hunks.
Nonoverlapping hunks combine; identical hunks coalesce. Different insertions at
the same boundary, overlapping replacements, or insertions touching a replacement
boundary conflict rather than depending on application order.

Initial deterministic bounds are 2 MiB per input file and 4,000,000 alignment
cells per base/result comparison after trimming. Beyond these bounds, or for
opaque files, apply only whole-path equality/unchanged rules and otherwise request
explicit resolution. These are limits on automatic composition, not on storage
or sharing. A faster implementation must produce the same canonical hunks and
limit decisions; changed semantics require a new composition profile. Test
repeated lines, empty files, CRLF, and insert/delete boundaries with golden vectors.

Resolve revision dependencies before composition and express independent edits
against their common recorded base. If ancestry provides multiple incomparable
merge bases or an edit cannot be mapped unambiguously to the selected base,
return a decision instead of synthesizing a hidden base. Combine independent
edits as a set; sorting IDs stabilizes output, never chooses a conflict winner.
Explicit resolutions name all superseded variants and exact replacement bytes.
Apply the same rules when joining concurrent accepted histories.

Publishing records the correspondence between a shared revision and its local
history node. To preserve private work, select the most recent ancestor node
whose shared contents are represented in the accepted plan, then compose its
private continuation with the accepted result. Thus shared D plus private E
accepts D and keeps E. If correspondence is absent/ambiguous, require a decision;
never treat the whole live tree as accepted or replay already-present work twice.
After successful application, atomically record the new working basis and a
local history node parented to the pre-application cursor, retaining its branch.

### Review evaluator defaults

Required mode needs one approving trusted member whose repository principal is
distinct from the submitted work's authors, with no unresolved applicable change
request. Bind devices to stable member principals through administrator-signed
membership, with proof of the principal key; multiple devices are not extra
reviewers. A display name is not identity. This is identity-level separation,
not proof that two independently admitted accounts belong to different humans.

An approval covers the exact request version, revision IDs, relevant path contents
and kinds, and ancestor-directory kinds. Unrelated changes preserve coverage.
With renewed approval disabled, a valid approval on the same request version or
its explicit version ancestors can meet the prior-review requirement. It cannot
cross requests, a change of author principal set, or an unresolved version fork.
Label uncovered later changes truthfully.

Reviewer events supersede their causal predecessors, not whichever arrived last.
Concurrent inconsistent decisions by the same principal are unresolved and do
not count as approval. Withdrawals remove the approval they name. A blocking
change request survives descendant updates until its reviewer clears it, or an
administrator dismisses it explicitly with a recorded reason. Missing approval,
invalid authority, and blockers still apply under the renewed-approval opt-out.

### Journal state machine and filesystem writes

| Phase | Durable fact and restart behavior |
| --- | --- |
| Prepared | Exact plan, workspace safety root, expected metadata generation, pre/post path identities, and operation token exist. No working-file writes yet; cancellation can remove pending intent while retaining the safety root. |
| Applying | Each path has a recorded intent, staged target, and preservation location before replacement. Resume only when the observed path matches its expected preimage or verified postimage. |
| Materialized | All expected target paths verify. Publish accepted record, working basis/history, and outbox with one metadata-root compare-and-swap. Recheck relevant policy/plan inputs; retain independent incoming records on a retry. |
| Committed | The metadata root contains the operation token and exact result. Never reapply file writes or create another acceptance; finish cleanup and outbound transfer bookkeeping. |
| Completed | Journal is closed. Retain safety/undo roots under ordinary retention, and reclaim only staging data not referenced elsewhere. |
| Paused | A path changed unexpectedly, required data/space is missing, or relevant authority changed. Preserve safety, target, displaced files, and observed external edits; explain how to resume/replan or restore. |

Use same-filesystem staged writes and platform primitives that preserve the
displaced entry during replacement. An unexpected displaced preimage is retained
and pauses the operation, including when a race happened after preflight. Never
blindly replay a write or rollback over newer external edits. If a platform cannot
provide the required preservation, reject before replacement and offer a separate
destination. Track directory/symlink changes without following links outside the
workspace. Cancel after writes means a journaled recovery choice, not deleting the
journal. Copy-out and in-place recovery reuse the same identity checks.

Persist the prepared-plan-to-operation-token association before the first write.
Retrying the same plan resumes or reports that same committed operation. A fresh
request whose selected work is already accepted reports a no-op rather than
creating duplicate acceptance merely to acknowledge the command again.

Receipt can continue to stage immutable data while application runs; publication
of metadata is serialized. If current policy invalidates a materialized plan,
pause with its preserved roots instead of publishing acceptance or blindly undoing
the files. Never hold the writer lock over a network request or human decision.

## TC07: native ignore and filesystem scope

Choose a native `.yeokchamignore` pattern language with root and nested files.
Evaluate ancestor files before descendant files, and lines in order with the
last applicable match winning. Empty lines and unescaped leading `#` are comments;
leading `!` re-includes. `/` anchors to the directory containing that ignore file;
patterns containing `/` are relative to that directory; bare names match any
descendant basename. Trailing `/` matches directories and their descendants.
`*`, `?`, and bracket classes match within one path component; a whole `**`
component matches zero or more directories. Backslash quotes the next pattern
byte, including spaces, `#`, and `!`; trim only unescaped trailing spaces.
To re-include a child of an excluded directory, re-include the parent first.
Malformed syntax blocks capture with its file/line and preserves the last state.
No Git process or Git ignore configuration participates.

Always exclude Yeokcham metadata directories and the workspace-root `.git` entry;
negation cannot re-include them. No default file-extension exclusions. Capture
ignore files themselves unless an explicit rule excludes them. `ignore explain
PATH` reports the exact winning file/line or mandatory exclusion. Rule changes
trigger a rescan and affect future captures, never delete old history or live files.

In-place operations leave ignored/untracked paths alone. If the requested target
would overwrite, delete, or require changing a currently ignored path or an
untracked obstruction, stop before writes and offer copy-out or an explicit rule/
file change. Do not silently skip part of a requested restore and call it exact.

Capture regular bytes, executable distinction, empty directories, and symlink
target bytes. Continue to exclude timestamps, ownership, arbitrary permissions,
ACLs, and extended attributes from the fidelity promise. Never follow symlinks
while scanning; unsupported special files produce a path-specific incomplete
capture result rather than being silently skipped. There is no total-file-size
cutoff for source, document, media, archive, or dataset files.

For each file, open without following symlinks, verify identity/type before and
after streaming, and recheck directory membership and changed paths before
publishing the snapshot. Retry observed instability up to three times per pass,
then leave the last complete capture current and schedule another attempt.
Retain verified staged chunks for reuse, without calling the unstable pass saved.
Events optimize scans; they are not proof of contents. Explicit publication and
destructive plans verify the included/current contents, not just cached mtimes.
Capture represents observed disk contents, not unsaved buffers or a transactional
snapshot of an application writing several files. State this limitation in help.

Store path components losslessly, without case folding, Unicode normalization,
line-ending conversion, or changing executable bits based on file extension.
Before materialization, check the actual destination filesystem for name collisions,
reserved names, representability, symlink support, and executable-bit fidelity.
Downloaded objects can remain inspectable even if this machine cannot faithfully
materialize them. Fail before writes with affected paths; never silently rename,
drop files, replace a symlink with a text file, or claim complete materialization.
This check is required for macOS/Linux too, and Windows's later adapter must use
the same logical contract. Expose downloaded versus materializable scope separately.

## TC08: validation and implementation sequence

Defaults above settle the previous audit's design choices. Remaining work is
implementing shared schemas, collecting evidence, and validating the chosen
contracts. The [CLI design](CLI_DESIGN.md) fixes command families, prompts, and
structured outcomes; the [benchmark design](BENCHMARK_DESIGN.md) fixes workload
defaults and comparison gates. No further preference round is required.

The user has now selected a sequential `/goal` handoff workflow. Follow
[Implementation workflow](IMPLEMENTATION_WORKFLOW.md) and maintain
[Implementation progress](IMPLEMENTATION_PROGRESS.md). The G01-G20 prompts split
the architectural stages below into bounded tasks, with reports, evidence gates,
atomic Git commits on `main`, and the user's current README constraint. Preparing
these prompts does not start an implementation goal automatically.

| Stage | Owned deliverable and dependency |
| --- | --- |
| S0: schema foundation | One owner for the record registry, canonical encoders, pure record types, logical IDs, crypto-provider boundary, composition vectors, and policy evaluator. Freeze exported interfaces and malformed-input cases before consumers. |
| A: baseline evidence | Run the existing implementation on the chosen source/monorepo/asset fixtures and capture resource/latency reports. Can precede S0; optimization uses this baseline. |
| B: capture/storage | Own snapshot/ignore/chunk/store/history persistence and pack/collection interfaces under S0/TC05/TC07. Add native filesystem adapter contracts for all three OS targets. |
| P: account/archive | Own private identity, key custody, device/account epochs, encrypted archive manifests, remote completion, and recovery against S0 and B's object interface. |
| E/R: integration/reviews | Own plan/composition/journal execution and review request/event services against S0/B. Share the pure policy evaluator rather than implementing review checks twice. |
| C: background service | Own scheduling, durable transfer queues, registration, and OS service adapters, consuming B/P/E/R interfaces. macOS/Linux first, Windows next. |
| D/F: CLI and end-to-end experience | Own command dispatch/rendering and integrated journeys against each service interface as it lands. Work from the first stage; final verification checks complete workflows. |

Explicit file/module ownership and build targets belong in each future task when
assigned; do not authorize concurrent edits to a shared schema merely because
two features need it. Existing module interfaces are the starting point, not a
requirement to retain monolithic state rewrites or delivery semantics. No goal
or implementation agent is started by recording these defaults.

Required validation includes:

- Golden canonical/signature/composition vectors and independent arrival-order
  tests; no different accepted result for identical inputs.
- Fault injection before/after every journal transition, metadata commit, archive
  acknowledgement, and pack-index publication; retries must be idempotent.
- Edits during capture/application, ignored-file obstructions, disk-full failures,
  missing/corrupt chunks, and platform-specific filename/symlink cases.
- Wrong recovery phrase, missing old device, revoked device, account/policy forks,
  and a server credential attempting private decryption or unauthorized enrollment.
- Offline integrations, stale policy, lost acknowledgements, full remote quota,
  pending private uploads, protected-root overages, and exact archived restore.
- Both safeguard toggles independently and together; no bypass of conflict or
  authority checks and no fabricated approval of changed contents.
- CLI text/JSON/noninteractive journeys, then comprehension checks with people
  unfamiliar with VCS terminology. Record actual observations, not assumed success.

Run focused module/property/journey tests as components land, the repository's
required build/lint/test checks before merging, and extended workload/platform
validation before performance or portability claims. Do not pretend runtime
tests or benchmarks were executed during documentation-only work.

## Current implementation and remaining execution work

The current [model](../lib/yeokcham_v1_model/yeokcham_v1_model.mli) already separates
snapshot IDs, drafts, shared changes, and immutable revisions with base/result
snapshots. The [undo model](../lib/yeokcham_v1_undo/yeokcham_v1_undo.mli) separates
node and snapshot identities. The [trust interface](../lib/yeokcham_v1_trust/yeokcham_v1_trust.mli)
authenticates revisions under explicit authority context.

The repository does not yet implement the new account/archive, managed service,
review, composition, packing, or CLI defaults merely because they are documented.
TC03-TC07 select their behavior and interfaces. S0 turns the specified record
layouts and rules into concrete module APIs, registered type codes, and golden
vectors before dependent feature work. Performance and usability evidence is
collected under TC08 and the linked plans.

No old-development-format compatibility layer is required (D10). Exact
current-format recovery, bounded decoding, durable retry, and preservation of
current work remain required. Retain the explicit distinction between an agreed
product requirement, a delegated default, and an implemented/measured result.

## Implementation-readiness audit: November 6, 2026

The earlier audit identified six areas needing defaults. The user's subsequent
instruction authorized making logical assumptions and recording the decisions;
that instruction supersedes the recommendation to ask another round of questions.

| Audit area | Default decision now recorded | Remaining execution/evidence |
| --- | --- | --- |
| Private account/archive | TC03: owner-approved pairing, separate phrase recovery, encrypted per-repository epochs, verified manifest completion before eviction. | Implement provider/protocol adapters, canonical vectors, recovery and missing-object fault scenarios. |
| Background/storage | TC04/TC05: per-user service, explicit pause scopes, bounded scheduling, existing chunks plus Zstandard and indexed packs. | OS adapters, incremental persistence, measurements and tuning. |
| Shared records/integration | TC06: canonical record layout, causal heads/policies, deterministic composition, review evaluator, and journal states. | S0 schema constants/APIs/vectors, then service implementations and race/fault validation. |
| Capture/filesystem scope | TC07: native nested ignore rules, instability retries, exact supported attributes, portability preflight failures. | Matchers, scanners, platform adapters, and cross-platform fixtures. |
| CLI/reviews | CLI design: command families, complete journeys, confirmation and JSON/exit semantics. Review design: one independent approver and explicit stale-review policy. | Implement contextual actions/messages; evaluate actual comprehension. |
| Validation/handoffs | TC08 and benchmark design: ownership/dependency order, fault matrix, selected fixtures, sampling and regression thresholds. | Assign concrete files/tasks when implementation is requested and collect real results. |

Readiness is per work package: baseline measurements and S0 can be scoped first;
consumers wait for their shared interfaces. A broad new product questionnaire is
unnecessary. Record any material deviation from these defaults rather than
silently changing an agreed behavior. This audit starts no implementation or
agent delegation and claims no benchmark or usability results.

## Discussion record

- November 6, 2026: the user agreed to TC01's logical records, immutability,
  distinction between reviewed/shared work and private edits, and preservation
  of concurrent histories. Concrete encodings remain engineering work.
- November 6, 2026: drafted TC02 for the next discussion, including exact plans,
  separate accepted/workspace results, approval coverage, interruption handling,
  and local commit before asynchronous publication. At that point TC02 was proposed.
- November 6, 2026: the user agreed to all six integration behavior points and
  clarified that both preview confirmation and renewed approval after relevant
  changes should default on with warned opt-outs. Recorded the distinct personal
  and repository-policy scopes without weakening immutable review identity or
  conflict/integrity checks. Added the CLI comprehension requirement; no runtime
  implementation was authorized or performed by this design update.
- November 6, 2026: audited remaining design and handoff gaps after the user
  accepted the CLI direction. Recorded the areas above; private account/archive
  setup and recovery remain the next technical discussion. Documentation checks
  do not establish runtime correctness, performance, or usability results.
- November 6, 2026, delegated defaults: the user asked Codex to make logical
  assumptions for the remaining audit items. Added TC03-TC08 and concrete CLI,
  review, and benchmark defaults; superseded the pending-question audit with
  their disposition. Existing product choices remain binding. No runtime changes.
- November 6, 2026, implementation handoff authorization: prepared the sequential
  goal/report/progress workflow and G01-G20 prompts. The design baseline is
  `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`. User instructions require atomic
  commits on `main` and README edits limited to accurate additions or corrections
  of obvious outdated/wrong content. Runtime work starts when a goal is invoked.
