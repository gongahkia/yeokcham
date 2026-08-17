#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
cd "$root"

for file in site/index.html site/styles.css site/app.js site/README.md; do
  test -f "$file" || {
    printf '%s\n' "missing website asset: $file" >&2
    exit 1
  }
done

for marker in \
  '<main id="guide">' \
  'id="start"' \
  'id="recovery"' \
  'id="intent"' \
  'id="workspace"' \
  'id="release"' \
  'id="share"' \
  'id="inspect"' \
  'class="guide-panel' \
  'class="workflow-diagram"' \
  'data-copy' \
  'Skip to the guide'; do
  rg -Fq "$marker" site/index.html || {
    printf '%s\n' "website guide is missing required marker: $marker" >&2
    exit 1
  }
done

for command in \
  'yeokcham init' \
  'yeokcham checkpoint' \
  'yeokcham capsule create --current' \
  'yeokcham work create' \
  'yeokcham release create' \
  'yeokcham verify'; do
  rg -Fq "$command" site/index.html || {
    printf '%s\n' "website guide is missing documented command: $command" >&2
    exit 1
  }
done

rg -Fq 'href="styles.css"' site/index.html
rg -Fq 'src="app.js"' site/index.html
rg -Fq 'navigator.clipboard.writeText' site/app.js
rg -Fq '@media (max-width: 680px)' site/styles.css
rg -Fq 'prefers-reduced-motion' site/styles.css
rg -Fq 'no third-party font, script, image, tracker, or analytics' site/README.md
