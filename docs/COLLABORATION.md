# Collaboration and relay operations

This guide is for a small trusted team using V1's explicit authority and
transfer boundaries. It is not a Git migration, a general clone recipe, or an
online membership workflow. Start with the local recovery tutorial before
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
clone and complete conflict journeys remain required before P3 is complete.

## Foreground native exchange (P3 in progress)

For an existing authenticated Core workspace with an already enrolled member and
device, configure the relay and exchange explicitly:

```sh
yeokcham remote add team https://YOUR_RELAY
yeokcham remote login team
yeokcham exchange team --format json
yeokcham exchange team
```

Remote login uses the existing credential adapter. A relay bearer token grants
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

Ordinary clone is still unfinished. Automated TLS tests create Bob's empty,
already enrolled replica through the library, then run fresh CLI sharing,
exchange and integration processes. That setup is not a supported clone command,
native custody onboarding, or human-usability evidence.

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
head with repeated `--reconcile ID`; `--yes` alone never selects a winner. Conflict
plans identify shared/private paths and exact variants. Complete native conflict
resolution is still P3 work; the older
`resolve --decision` and package flows below are a different record family.
Required unsupported policy refuses explicitly. These local commands do not yet
complete the two-person native clone/exchange pilot.

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

## A fresh replica through a relay

There is no general `clone`. An existing equivalent replica explicitly runs
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
