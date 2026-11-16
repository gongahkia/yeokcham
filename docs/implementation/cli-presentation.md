# Compact local CLI output

The November 16, 2026 dogfooding session exposed ordinary commands printing
full device/workspace/snapshot identities and restore internals. The user's
request was to make essential state and actions readable at a glance.

The [interactive prototype](../prototypes/cli-output.html) previews first run,
status, diff, save, history and undo/redo, with color, narrow-width and diagnostic
controls. Its recovery words and identities are synthetic placeholders.

Normal local text now uses this shape:

```text
main / saved #0
1 path to save
  M note.txt

Next  yeokcham diff / yeokcham save
Private backup: not configured
```

```text
+ Saved on this device
```

```text
Local history
* #1  note.txt  21:25
o #0  Initial capture
```

`*` marks the current saved version. Local version numbers remain directly
selectable with existing undo/redo/restore commands. Alternative continuations
show their parent and alternative numbers; missing/unretained contents remain
explicit. Times in this compact view are local; full UTC capture times remain
in `history --details`. `M`, `A`, `D` and `T` mark modified, added, deleted and
type-changed paths. Mode/symlink/directory and opaque differences remain visible.

`status --details`, `history --details`, `diff --details`, `save --details` and
navigation `--details` expose the previous full diagnostic identities. JSON
retains its schema and domain fields. These are presentation changes; capture,
selection, trust, journals and recovery proofs use the existing services.
An interrupted operation still exposes the exact ID and applicable action needed
to recover it. A failed observation is never presented as matching saved files.

Initialization shows a short project summary and the one-time recovery words,
grouped into readable rows. It still refuses JSON before creating custody.
The public root-verification phrase is available later through `device show`;
`init --details` preserves the complete diagnostic ceremony for explicit use.
The recovery package remains `.yeokcham/recovery-v1.cbor`. No recovery secret is
stored in the prototype or this document.

Semantic ANSI colors follow existing `--color`, `NO_COLOR`, TTY and machine-output
rules. UTF-8 terminals can show a check mark; redirected/dumb/non-UTF-8 output
uses ASCII. `COLUMNS` bounds compact labels and recovery-word grouping, with an
80-column fallback. Path/control-byte escaping remains mandatory. Existing
diagnostic fixtures explicitly request `--details`; ordinary first-use and
error/TTY/JSON journeys have separate process-level tests.

Verification uses `test/test_cli_presentation.py`, existing CLI/inspection/
selection/watch/runtime regressions and the common build/lint/CI commands.
The browser preview is checked at 320, 375 and 1100 pixels, with its controls
exercised. Exact outcomes and source revisions are recorded in the progress
ledger. This fixes the observed presentation problem; it does not close all
native/participant/performance gates for P4 or any original full-design phase.
