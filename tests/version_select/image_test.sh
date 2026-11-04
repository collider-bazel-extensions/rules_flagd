#!/usr/bin/env bash
set -euo pipefail
img=$(sed -n 's/^ *image: //p' "$TEST_SRCDIR/_main/$1")
[[ "$img" == ghcr.io/open-feature/flagd:v0.17.1@sha256:* ]] || { echo "FAIL: image $img" >&2; exit 1; }
echo "PASS: $img"
