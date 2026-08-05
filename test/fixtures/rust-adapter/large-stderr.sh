#!/bin/sh
i=0
while [ "$i" -lt 512 ]; do
  printf x >&2
  i=$((i + 1))
done
