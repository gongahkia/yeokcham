# Collaboration and relay operations

This guide is for a small trusted team using V4's explicit authority and
transfer boundaries. It is not a Git migration, a general clone recipe, or an
online membership workflow. Start with the local recovery tutorial before
adding another person.

## Two people, offline package

Assume Alice already owns an initial V4 repository and Bob will use a separate
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

   `receive` is history receipt, not working-tree population. V4 has no command
   that materialises a received revision as a clone. Bob can inspect received
   history with `log` and `graph`; destination restore remains available only
   for a checkpoint in Bob's own local recovery history.

If authority has concurrent epoch heads, an administrator must inspect
`authority heads` and explicitly reconcile selected heads. V4 never lets relay
ordering choose policy.

## Relay operator runbook

The operator supplies storage and HTTPS transport, but does not become V4
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

The relay sees stored payloads; V4 does not claim end-to-end payload encryption.
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
materialise ordinary files. See `yeokcham help bootstrap` and the full contract
before operating this path.
