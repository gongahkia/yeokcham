# Immutable release creation and verification demonstration

## M11-08 vertical slice

`tools/demo/demonstrate-release-v1.sh` composes the M11-05 two-capsule
workspace, materialises it without conflict, and creates one release with an
exact validation command: `/usr/bin/true`. It records the release ID, final
snapshot ID, and the immutable validation-evidence ID/object link. A standalone
validation over that exact final snapshot resolves to the same logical evidence
ID, while its separately observed physical evidence object can differ.

The script then rejects a missing release parent without changing the visible
release list, records a later scratch checkpoint, and verifies that both the
release display and verification result remain byte-identical. Release identity,
validation evidence identity, and evidence object identity are distinct typed
values; the script prints each separately. The release remains bound to its
recorded evidence object; a later equivalent observation does not rewrite it.

`/usr/bin/true` is deliberate test evidence only: it proves that this bounded
command exited successfully over the materialised release snapshot. It is not a
cryptographic signature, attestation, author identity, reproducible-build
claim, or general test/quality guarantee.

## Run and inspect

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/yeokcham-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
sh tools/demo/demonstrate-release-v1.sh --root "$demo_root"
```

Run this demonstration from a freshly created fixture. It is not composable
with the recovery, capsule, or other stateful demonstration scripts on the
same root: those scripts intentionally advance scratch state, while this one
constructs and materialises its own workspace from the original setup fixture.
If it follows the capsule demonstration on the same root,
`release workspace materialisation is partial` is the intended safe refusal to
materialise a composition whose declared base no longer matches scratch.

The script invokes the M11-05 workspace demonstration itself. Its evidence is
kept under `.yeokcham/`: `demo-v1-release-create`,
`demo-v1-release-evidence`, `demo-v1-release-validation`, and the before/after
show and verify records. The later `release-after.txt` is deliberately outside
the release; the release remains tied to its recorded final snapshot.

Bad roots, unowned fixtures, repeated runs, partial workspace composition,
malformed IDs, failed validation, a missing parent accepted as valid, or a
visible release-list change after the rejected parent all reject nonzero. The
missing parent is a structured release error and does not publish a release.

No model type, persistent format, ADR, `yeokcham` CLI behavior, signing,
attestation policy, materialisation guarantee, release parent policy, Git
export, sync state, or performance claim is added.

## Verification

`test_demo_release` checks complete materialisation, one immutable release,
logical evidence-ID equality with standalone validation, failed-parent
non-publication, exact verification after a later scratch checkpoint, and
unowned-root rejection. `make check` runs the focused test.
