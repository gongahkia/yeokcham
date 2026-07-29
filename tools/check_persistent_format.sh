#!/bin/sh
set -eu

# all production library sources are persistent-capable.
if grep -R -n -E '(^|[^[:alnum:]_])(Marshal|input_value|output_value)([^[:alnum:]_]|$)' lib; then
  printf '%s\n' 'persistent-capable library code must not use OCaml runtime serialization' >&2
  exit 1
fi
