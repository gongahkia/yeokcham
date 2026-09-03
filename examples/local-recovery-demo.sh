#!/bin/sh
# Run after building Yeokcham. This fixture deliberately stops at the recovery
# ceremony: it neither stores nor echoes a real mnemonic.
set -eu

: "${YEOKCHAM:=./_build/default/bin/yeokcham_v4.exe}"

if ! command -v "$YEOKCHAM" >/dev/null 2>&1 && [ ! -x "$YEOKCHAM" ]; then
  printf '%s\n' "Yeokcham command is unavailable: $YEOKCHAM" >&2
  printf '%s\n' "Build it first; see docs/INSTALL.md." >&2
  exit 2
fi

demo_root=$(mktemp -d "${TMPDIR:-/tmp}/yeokcham-local-recovery.XXXXXX")
mkdir "$demo_root/work" "$demo_root/recovered"
printf '%s\n' 'first note' >"$demo_root/work/note.txt"

printf '%s\n' "Demo directory: $demo_root"
printf '%s\n' "The next command prints a real recovery mnemonic once."
printf '%s\n' "Record it offline before continuing, or stop now with Ctrl-C."
"$YEOKCHAM" init --root "$demo_root/work" \
  --username alice --draft first-task --title "first task"

printf '%s\n' ""
printf '%s\n' "Continue with the documented exact inspection:"
printf '%s\n' "  printf '%s\\n' 'second note' >>'$demo_root/work/note.txt'"
printf '%s\n' "  '$YEOKCHAM' changes --root '$demo_root/work'"
printf '%s\n' "  '$YEOKCHAM' save --root '$demo_root/work'"
printf '%s\n' "  '$YEOKCHAM' timeline --root '$demo_root/work'"
printf '%s\n' "Then use docs/GETTING_STARTED.md to restore a copied checkpoint into:"
printf '%s\n' "  $demo_root/recovered"
