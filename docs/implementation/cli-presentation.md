# Compact local CLI output

The November 16, 2026 dogfooding session exposed ordinary commands printing
full device/workspace/snapshot identities and restore internals. The user's
request was to make essential state and actions readable at a glance.

The earlier HTML prototype was removed in `fba3daa`. The follow-up changes
the actual CLI from the user's second round of screenshots.

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
Local history  (* current)
* #3  note.txt  21:25
| o #2  note.txt  21:24
|/
o #1  note.txt  21:23
o #0  Initial capture
```

`*` marks the current saved version. Local version numbers remain directly
selectable with existing undo/redo/restore commands. Connections show real local
parents: #2 and #3 both follow #1 above. These are local undo alternatives,
not shared branches. Open lanes end at `: #N (earlier history)` when the parent
is outside the page. `X` means a crossing, not a common parent. Exceptionally
wide graphs fall back to explicit parent numbers. Missing/unretained contents
remain explicit. Times in this compact view are local; full UTC capture times remain
in `history --details`. `M`, `A`, `D` and `T` mark modified, added, deleted and
type-changed paths. Mode/symlink/directory and opaque differences remain visible.

Diff headers show added/removed line counts. At 100 columns or wider, numbered
`Before` and `After` columns pair change blocks, preserving separate numbering
and empty sides for unmatched additions/deletions. Narrower terminals use
numbered unified rows. Long source lines wrap with `>` continuation markers;
they are not elided. Tabs expand to four-column stops for display; CR, terminal
controls and missing final newlines remain explicit. This is the bounded display
diff, not the composition/acceptance proof. Binary/display-limit cases stay
explicit rather than presenting guessed text.

`status --details`, `history --details`, `diff --details`, `save --details` and
navigation `--details` expose the previous full diagnostic identities. JSON
retains its schema and domain fields. JSON is indented when its actual output
descriptor is a terminal; pipes/files retain the existing compact encoding.
No ANSI is added to JSON. These are presentation changes; capture,
selection, trust, journals and recovery proofs use the existing services.
An interrupted operation still exposes the exact ID and applicable action needed
to recover it. A failed observation is never presented as matching saved files.

Initialization shows a short project summary and the one-time recovery words,
grouped into readable rows. It still refuses JSON before creating custody.
The public root-verification phrase is available later through `device show`;
`init --details` preserves the complete diagnostic ceremony for explicit use.
The recovery package remains `.yeokcham/recovery-v1.cbor`. No recovery secret is
stored in this document.

Semantic ANSI colors follow existing `--color`, `NO_COLOR`, TTY and machine-output
rules. UTF-8 terminals can show a check mark; redirected/dumb/non-UTF-8 output
uses ASCII. Native stdout terminal size is queried with `TIOCGWINSZ`; a positive
`COLUMNS` (bounded to 1000) is the fallback for redirected output, then 80.
This affects labels, recovery-word grouping, paths and diff layout. Width comes
from the current terminal at each invocation/render boundary, not a cached
startup width. Completed CLI scrollback is managed by the terminal; this is not
a full-screen application that redraws old output. POSIX UTF-8 `wcwidth` measures
non-ASCII code points without changing the process locale; ANSI has zero width.
Complex emoji clusters can vary by terminal/font. Secondary text uses the
terminal's default foreground instead of dark gray or dim ANSI. Path/control-byte
escaping remains mandatory. Existing
diagnostic fixtures explicitly request `--details`; ordinary first-use and
error/TTY/JSON journeys have separate process-level tests.

Verification uses `test/test_cli_presentation.py`, existing CLI/inspection/
selection/watch/runtime regressions and the common build/lint/CI commands.
The new layout suite checks graph edges against actual parents in 500 generated
histories. Process/PTY tests cover real resize at 24–140 columns, wide/narrow
diff reconstruction, JSON/ANSI boundaries and unavailable alternatives.
Exact outcomes and source revisions are recorded in the progress
ledger. This work does not close all
native/participant/performance gates for P4 or any original full-design phase.


First-pass verified implementation: `8693ff36dc7d27230df3d1b6cdaa745442719115`. Build, lint,
CI, focused process/TTY tests and browser checks pass. Final CI reused matching
successful Dune actions. The [verification receipt](results/cli-presentation-20261116.json)
records exact commands, source/log hashes, corrected initial failures, unavailable
container execution and the full-slice rollback order. P4 remains unstarted.
