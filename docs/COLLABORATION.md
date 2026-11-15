# Collaboration and relay operations

This guide is for a small trusted team using V1's explicit authority and
transfer boundaries. Native clone requires prior enrollment; it does not perform
online membership enrollment or Git migration. Start with the local recovery tutorial before
adding another person.

## Selected native publication (P3 in progress)

Ordinary sharing now generates its change/revision identities and captures disk
contents without a separate save:

```sh
yeokcham share notes.txt images/ --preview
yeokcham share notes.txt images/ --title "Update project notes"
yeokcham share notes.txt --update CHANGE_ID --title "Revise project notes"
yeokcham status
```

Paths are relative to the workspace root. With no paths (or `.`), select all
included changes. Native captured ignore rules apply; explicitly selecting an
excluded path refuses and points to `ignore explain`. Preview publishes no
history or signed revision and does not require the signing provider. The actual
command authorizes the selected publication; it does not ask again. Unselected
contents stay in private local capture/history. Sharing does not accept work or
change ordinary files. A recorded identical request reuses its revision and
operation identities. An explicit update with changed inputs creates another
immutable version, including equal contents with a changed title.
Signing-provider interaction occurs outside the workspace writer lock. If files
or saved state change while the provider is active, sharing refuses and asks for
a fresh preview/retry instead of publishing the older capture.

Status shows native revision identities, the private working basis and local
publication receipts separately from accepted heads. Transfer remains pending
until an exact native courier is acknowledged by a configured relay. Status lists
the acknowledging remotes and preserves those facts when newer work is pending.
The legacy package journeys below carry the earlier V1 record family. Native
conflict journeys remain required before P3 is complete. Native clone is described below.

## Foreground native exchange (P3 in progress)

For an existing authenticated Core workspace with an already enrolled member and
device, configure the relay and exchange explicitly:

```sh
yeokcham remote add team https://YOUR_RELAY
yeokcham remote login team
yeokcham exchange team --format json
yeokcham exchange team
```

Remote login uses the existing credential adapter and binds native credentials
to the exact endpoint and repository. An old alias-only credential needs another
login before native exchange; credentials from another workspace's equal alias
are not a fallback. A relay bearer token grants
byte-storage access; membership still requires the verified repository authority.
The sender signs a courier with its enrolled local device. A pending frozen
courier can resume without another signature. The repository identity and known
authority root remain pinned throughout receipt.

Exchange receives complete verified shared packages first, without scanning or
rewriting working files, moving private history, integrating, or running project
commands. It prioritizes declared selected contents, then verifies all advertised
closure. Missing contents refuse receipt before publishing that package. Existing
verified public contents may be reused; matching private cached bytes alone do
not satisfy an incoming advertisement. The relay must supply new contents.

Outgoing work freezes exact public manifest/courier bytes before network writes.
Retrying after interruption or a lost acknowledgement resends the same courier;
later work stays available for a later batch. Transfers use existing bounded V2
missing-object/range mechanisms, with explicit V1 fallback when V2 is unavailable.
Receiving succeeds independently of a later outgoing failure: JSON reports an
incomplete outcome and exit 5 with retry instructions when sending remains pending.

Coverage describes verified locally known shared closure and the relay inventory
checked in that foreground run. It cannot prove the relay disclosed every remote
record. No managed background downloads or backup success is claimed. The client
rescans the bounded relay inventory because its hash-order cursor is not an
arrival high-water mark.

If admitted public contents later become missing/corrupt, `status` and `history`
can show checked signed declarations and private history without capturing disk
contents or changing the state root. Missing content returns exit 5; corruption
or a failed accepted-result proof returns exit 6. JSON keeps the actual domain
data and marks the state unverified; signatures alone are not content proof.
Transfer/recovery state remains unknown. Writers and native exchange still
require complete validation; inspection does not re-fetch missing objects or
repair corruption. Preserve current files/store/recovery roots and inspect the
failure with `verify`; remote repair remains unfinished P3 work.

## Verified native clone (P3 in progress)

Obtain a repository URL, independently compare the public root-verification
phrase, and enroll the local device through the existing membership ceremony
before cloning. Relay access alone cannot enroll a device. HTTPS trust and the
local signing provider must already work. Use the device ID printed by that
ceremony; workspace, draft, branch selection and history identities are generated.

```sh
yeokcham clone https://YOUR_RELAY/v1/repositories/REPOSITORY_ID my-project \
  --device DEVICE_ID --verify-phrase "PUBLIC ROOT WORDS" --preview
yeokcham clone https://YOUR_RELAY/v1/repositories/REPOSITORY_ID my-project \
  --device DEVICE_ID --verify-phrase "PUBLIC ROOT WORDS" --request REQUEST_ID
yeokcham status --root my-project
yeokcham exchange --root my-project origin
```

The default directory is `yeokcham-` plus the repository ID's first twelve hex
digits. The default branch is `main`; `--branch NAME` selects an unambiguous
shared name. Incomparable heads require reconciliation by an existing member.
Clone does not choose a divergent head. It selects the branch's unique accepted
version; pending shared revisions remain available for later explicit integration.

Tokens come from the endpoint/repository credential scope or a text-mode terminal
prompt. Noninteractive callers can pass `--token-stdin` and supply one secret line
through standard input. Never put a bearer in URL/arguments. Actual clone stores
the scoped credential before workspace initialization; unavailable custody blocks
it. Preview does not save credentials or create a destination, history or operation.
Its request ID binds the verified source selection; a changed selection refuses
`--request` and needs another preview.

Clone downloads and verifies complete advertised native closure, authority and
root identity before initializing a new/empty destination. It copies only that
verified public closure, creates fresh private empty history, and materializes the
selected accepted version with the existing safe integration engine. It signs no
new shared genesis/acceptance and copies no source private history, files or keys.
Other received branches remain known-only until explicit local selection below.

```sh
yeokcham clone --resume my-project
yeokcham operation show --root my-project OPERATION_ID
```

After workspace metadata is attached, resume uses the frozen local selection and
closure without network access or another signer. Ordinary save/capture is blocked
until completion or explicit operation recovery. File replacement uses the same
identity checks, protected safety contents and interrupted-operation protocol as
integration. Changes made after materialization remain private disk edits. A
recovered clone operation is closed and cannot be restarted by clone resume.

Before metadata attachment, an interruption may leave an empty destination and an
orphaned sibling staging directory. Rerun the original URL/directory command; no
workspace was activated. Attachment uses an exclusive native rename and refuses
replacement. A destination on a filesystem different from its parent may refuse
that rename before ordinary-file application; no cross-filesystem copy fallback
is provided. Preserve unexpected staging contents for inspection.

All transfers run in the foreground. Reported closure covers verified locally
known shared work, not proof that a relay disclosed every remote record. Automated
TLS tests use disposable explicit signing capabilities; they do not qualify native
custody onboarding or human usability. Complete conflict resolution and the
remaining P3 audit are still outstanding.

## Select a received branch (P3 in progress)

```sh
yeokcham branch list
yeokcham switch feature --preview
yeokcham switch feature --yes --plan PLAN_ID
yeokcham switch main --yes
```

Names come from branch listing. A first selection uses the branch's unique verified
accepted version, preserving the source branch's unsaved work as a private history
alternative before replacement. Preview allocates no history or position; JSON marks
proposed target identities provisional. Incomparable heads or duplicate names need
an explicit decision and are never chosen by `--yes`. No signer or network is needed
for selection of already verified local contents.

Returning to a saved branch restores that branch's private position. Newer known
shared heads stay visible separately; use `integrate --preview` to inspect catch-up.
Switching does not integrate or publish private work. A new named branch forks the
current private working basis, including when a newer shared head has arrived.

An interrupted switch reuses the recorded target and private basis rather than a
later received head. Existing local selection journals, safety roots and recovery
commands apply. Late external edits after materialization remain private disk
changes. See [local undo](LOCAL_UNDO.md) for exact history selection and copy-out.

## Local shared acceptance (P3 in progress)

The selected Core work recorded above can now be accepted locally:

```sh
yeokcham integrate CHANGE_ID --preview
yeokcham integrate CHANGE_ID --yes
yeokcham integrate --all --preview
yeokcham integrate --plan PLAN_ID --yes
yeokcham operation show OPERATION_ID
yeokcham operation resume OPERATION_ID
```

With no selection, a sole eligible change is selected; multiple choices are
listed and require explicit selection or `--all`. IDs come from `share`, `status`
and preview. Accepted and private workspace results are shown separately, with
readable text differences and explicit opaque/type/mode changes. Compatible
private edits after sharing remain private: accepting shared D retains later E
without publishing E. Integration creates its accepted record and local history
atomically and records pending outbound work; it needs no separate `deliver`.
It does not claim transfer acknowledgement or managed background exchange.

Preview requires no signer and leaves accepted/history refs and ordinary files
unchanged. Confirmation defaults to cancel; noninteractive or JSON application
requires `--yes`. A saved `--plan` binds exact inputs and refuses stale work.
Repeating a completed plan reuses the operation; already accepted selections
report no-op. `operation show` inspects durable facts, and `operation resume`
continues the previously confirmed operation without another signer or identity.
After Materialized, resume publishes the verified result without replaying files,
so later external edits survive. Unexpected edits during Applying pause instead
of triggering rollback. Incomplete integration blocks ordinary capture/navigation
and keeps its safety/target roots protected.

Divergent branch histories require explicitly naming every event and accepted
head with repeated `--reconcile ID`; `--yes` alone never selects a winner. Required
unsupported policy refuses explicitly. Native Core required-review policy and
adoption remain unsupported and refuse; the earlier V1 review/adoption commands
do not authorize these Core records.

## Preparing exact conflict choices

```sh
yeokcham conflicts
yeokcham conflicts --plan PLAN_ID
yeokcham resolve CONFLICT_ID --defer
yeokcham resolve CONFLICT_ID --use VERSION_ID
yeokcham resolve CONFLICT_ID --file /path/to/combined-contents
yeokcham conflicts --plan NEW_PLAN_ID
yeokcham integrate --plan NEW_PLAN_ID --preview
yeokcham integrate --plan NEW_PLAN_ID --yes
```

`conflicts` shows exact shared/private paths and named versions, including
absence, type/mode/content identities and an escaped preview up to 8192 bytes.
Use the printed version identity, such as `revision:RECORD_ID`, to select exact
contents. For an overlapping private conflict, `working` retains private disk
contents while `accepted` selects the proposed shared result. Shared and private
choices stay distinct: a shared choice records a scoped authenticated resolution
proposal; a private choice belongs only to the new local plan. Neither accepts
work, advances private history or changes ordinary files. Deferral preserves the
proposal. Explicit replacement files must be stable regular files; capture streams
large bytes, preserves the executable distinction and refuses symlinks/special files.

Resolution prints a fresh plan ID for further inspection and explicit integration.
Default inspection retains incomparable plan alternatives rather than selecting
an arrival-order winner. Stale inputs require fresh preparation; a recorded exact
shared choice can be retried without another signature. Signing never holds the
worktree writer lock. If a shared proposal was recorded but its local plan alias
could not be retained, the command reports incomplete preparation and an exact
retry action, with no acceptance or ordinary-file change.

`status` reports `resolution_proposals` with exact IDs, comparison/replacement
snapshots and `accepted_by` references. A recorded proposal alone is not an
acceptance or transfer acknowledgement. A paused integration blocks a new
conflict preparation with exit 8 and the original operation/recovery actions.
Unavailable or corrupt saved public contents refuse through the read-only
metadata view; neither ordinary files nor history are repaired from live bytes.

These native commands are distinct from the earlier V1 `resolve --decision` and
package flows below. Automated Alice/Bob tests now exercise verified native clone,
concurrent updates, text/opaque decisions, deferral, preview, private E, accepted
exchange and signer-free catch-up through actual controlled TLS. Actual relay
closure is checked for private sentinels/plans. These tests use explicit disposable
signers and do not establish native custody onboarding or human usability.

Foreground clone/exchange first verify maximal native courier closures, fetching
the requested/locally selected branch before other content in those closures;
older feed receipts still follow causal order. All advertised shared branches/
history remain included. Only complete remotely obtained, signature/scope-verified
public closure can warm subsequent receipt; matching private cached hashes alone
never qualify. Ambiguous names/heads are not resolved by download ordering.
V2 404 can use the explicit V1 object path; other permission/format failures do
not become fallback success. Empty error responses retain their HTTP status:
access refusal is exit 7, malformed/checksum data exit 6, unavailable data exit 5.

## Recovering a pending integration

```sh
yeokcham operation recover OPERATION_ID --preview
yeokcham operation recover OPERATION_ID --plan RECOVERY_PLAN_ID --yes
yeokcham operation recover OPERATION_ID --replan --keep-current --preview
yeokcham operation show OPERATION_ID
```

Recovery restores the saved private safety tree and retains the current observed
tree separately. It closes the uncommitted integration without accepting its
staged shared result. `--keep-current` explicitly chooses the observed tree as
private work instead. Neither choice needs a signing provider. Preview and
cancellation leave files/history unchanged; automation supplies `--yes`, with
the exact recovery plan from preview when confirmation must be bound to it.

If another edit pauses recovery, inspect it before resuming. `--replan` prepares
a new observation and choice while retaining earlier attempts. Resume never
replays files after Materialized. Recovery cannot undo a committed shared
acceptance; use private undo/restore for that case. A closed old integration plan
stays closed; prepare a fresh integration to accept its shared work later.

`operation show` lists observed snapshots and prior observations. Inspect them
with `diff`, or use `restore SNAPSHOT --to NEW_DIRECTORY --yes` to recover a
separate copy. Extra recovery alternatives remain GC roots until explicitly
released with `operation forget OPERATION_ID --preview` followed by `--yes`.
Release leaves live files, private history and accepted records in place;
unreferenced alternatives can subsequently become unavailable. Do not delete
staging or journals to clear a paused operation.

## Two people, offline package

Assume Alice already owns an initial V1 repository and Bob will use a separate
machine or user session.

1. Bob creates a native device before joining and sends Alice only its printed
   device ID and public key. This creates local custody; it grants no role.

   ```sh
   yeokcham device create
   # record: device DEVICE_ID
   # record: public-key PUBLIC_KEY_HEX
   ```

2. Alice explicitly enrols the device. Omit `--administrator` for an ordinary
   member. The username is display data only.

   ```sh
   yeokcham device enroll --root ALICE_PROJECT \
     --device DEVICE_ID --public-key PUBLIC_KEY_HEX --username bob
   ```

3. Alice makes any intended shared revisions explicitly, then creates an
   offline package in a new destination directory.

   ```sh
   yeokcham save --root ALICE_PROJECT
   yeokcham share --root ALICE_PROJECT --change change-1 --revision r1
   yeokcham package create --root ALICE_PROJECT --destination OUTGOING_PACKAGE
   ```

   The package contains public authority and selected immutable work; it never
   contains Alice's private key, local draft, scratch checkpoints, pins, or
   relay credential.

4. Alice gives Bob the package by a channel appropriate for the team's data
   and independently communicates the exact public root-verification phrase
   printed at Alice's `init`. Bob compares it, rather than trusting the phrase
   that arrived beside the package.

5. Bob joins an empty local work directory using the device created in step 1.
   `join` verifies authority but neither imports package objects nor writes
   ordinary files.

   ```sh
   yeokcham join --root BOB_PROJECT --username bob --draft bob-work \
     --title "Bob work" --device DEVICE_ID --from OUTGOING_PACKAGE \
     --verify-phrase "TWELVE WORDS COMPARED OUT OF BAND"
   ```

6. Bob receives the package separately. This verifies all package closure and
   state before one state-head update, and still does not materialise a working
   tree.

   ```sh
   yeokcham receive --root BOB_PROJECT --from OUTGOING_PACKAGE
   yeokcham log --root BOB_PROJECT
   yeokcham graph --root BOB_PROJECT
   ```

   `receive` is history receipt, not working-tree population. V1 has no command
   that materialises a received revision as a clone. Bob can inspect received
   history with `log` and `graph`; destination restore remains available only
   for a checkpoint in Bob's own local recovery history.

If authority has concurrent epoch heads, an administrator must inspect
`authority heads` and explicitly reconcile selected heads. V1 never lets relay
ordering choose policy.

## Relay operator runbook

The operator supplies storage and HTTPS transport, but does not become V1
authority. Run the backend on a loopback or private address and terminate TLS
in an independently managed reverse proxy:

```sh
yeokcham relay serve --storage RELAY_STORAGE --listen 127.0.0.1:8080
```

Issue a narrowly scoped, repository-specific credential for each client or
automation context:

```sh
yeokcham relay access issue --storage RELAY_STORAGE \
  --repository REPOSITORY_ID --scope read,write
```

The command displays the bearer secret once only to a controlling terminal.
Deliver it over an appropriate secure channel. A user then configures the
HTTPS URL and enters the secret locally:

```sh
yeokcham remote add --root PROJECT team https://relay.example.invalid
yeokcham remote login --root PROJECT team
yeokcham sync --root PROJECT team
```

The relay sees stored payloads; V1 does not claim end-to-end payload encryption.
It cannot enrol a device, sign a revision, choose an authority branch, resolve
a decision, deliver work, or materialise a client working tree. Rotate or revoke
credentials with `relay access rotate` and `relay access revoke`; that changes
relay access only, not membership.

## Earlier V1 bootstrap through a relay

The native Core clone above is distinct from this earlier V1 record family.
For this bootstrap path, an existing equivalent replica explicitly runs
`bootstrap publish REMOTE`. A new, already-enrolled device receives the public
repository ID, named immutable basis ID, HTTPS URL, and independently compared
root phrase, then uses `bootstrap`. Bootstrap verifies the signed basis before
creating `.yeokcham`; it imports no private key or scratch state and does not
materialise ordinary files. In a deliberately empty bootstrapped root, the
person then explicitly runs `yeokcham workspace activate`. Later `workspace
update` refuses local edits unless `--replace` is selected; that selection
prints a regular safety checkpoint and restore proof. See `yeokcham help
bootstrap`, `yeokcham help workspace`, and the full contract before operating
this path.
