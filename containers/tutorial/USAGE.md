# Local Docker tutorial

This container gives you a disposable Yeokcham V1 command without installing
OCaml, opam, or Yeokcham on the host. It is for the local recovery lesson only:
it does not create a relay, clone a repository, or configure collaboration.

Build it from the repository root:

```sh
docker build --tag yeokcham-tutorial --file containers/tutorial/Containerfile .
```

Start an interactive teaching session:

```sh
docker run --rm --interactive --tty yeokcham-tutorial
```

The container opens in `/workspace`. It provides a mock source project at
`/workspace/yeokcham` containing `note.txt` with `first note`, and an empty
`/workspace/recovered` directory for a safe destination restore.

```sh
cd /workspace/yeokcham
yeokcham --version
yeokcham init --username alice --draft first-task --title "first task"
printf '%s\n' 'second note' >>note.txt
yeokcham changes
yeokcham save
yeokcham timeline
```

Record the real recovery mnemonic that `init` displays if you need it during
the session. Copy the checkpoint ID for the saved two-line note from
`timeline`, make an unsaved edit, then prove the recovery boundary:

```sh
printf '%s\n' 'unsaved line' >>note.txt
yeokcham changes
yeokcham restore --checkpoint CHECKPOINT --destination ../recovered
cat ../recovered/note.txt
cat note.txt
```

The restored file has the saved two lines while `note.txt` retains the unsaved
line. This mirrors the `YEOKCHAM_GUIDE.md` local flow: `changes` observes exact
entries, `save` creates a local checkpoint, and destination `restore` leaves
the live working tree alone.

The image starts an isolated D-Bus and GNOME Keyring session so the production
Linux Secret Service signer can perform `init` and other signed commands. Its
default collection is the in-memory session collection; when the container
stops, the mock repository and its signing key disappear. Do not bind-mount a
real project or use this image for material you need to retain. Exit the shell
when the lesson is complete; `--rm` removes the teaching container.

To run an individual command in a fresh disposable session, pass it after the
image name:

```sh
docker run --rm yeokcham-tutorial yeokcham --help
```
