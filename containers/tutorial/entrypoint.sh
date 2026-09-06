#!/bin/sh

set -eu

tutorial_root=/workspace
project_root=$tutorial_root/yeokcham
recovery_root=$tutorial_root/recovered

mkdir -p "$project_root" "$recovery_root"

if [ -z "$(find "$project_root" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  printf '%s\n' 'first note' >"$project_root/note.txt"
fi

if [ "$#" -eq 1 ] && [ "$1" = /bin/sh ] && [ -t 1 ]; then
  printf '%s\n' \
    'Yeokcham local-recovery tutorial' \
    '' \
    'The mock source project is /workspace/yeokcham.' \
    'Start with: cd /workspace/yeokcham && yeokcham --version' \
    'Then follow containers/tutorial/USAGE.md from the source checkout.' \
    '' \
    'This session is disposable. Its signing key is held only in this container session.'
fi

exec dbus-run-session -- /bin/sh -ec '
  eval "$(gnome-keyring-daemon --start --components=secrets)"
  busctl --user call \
    org.freedesktop.secrets \
    /org/freedesktop/secrets \
    org.freedesktop.Secret.Service \
    SetAlias so default /org/freedesktop/secrets/collection/session
  exec "$@"
' /bin/sh "$@"
