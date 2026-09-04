#!/bin/sh

set -eu

exec "$YEOKCHAM_RELAY_TEST_CLIENT" bootstrap \
  --root "$YEOKCHAM_RELAY_TEST_TARGET_ROOT" \
  --remote relay \
  --url "$YEOKCHAM_RELAY_TEST_URL" \
  --repository "$YEOKCHAM_RELAY_TEST_REPOSITORY" \
  --basis "$YEOKCHAM_RELAY_TEST_BASIS" \
  --username alice \
  --draft relay-target \
  --title relay-bootstrap-target \
  --device "$YEOKCHAM_RELAY_TEST_DEVICE" \
  --verify-phrase "$YEOKCHAM_RELAY_TEST_PHRASE"
