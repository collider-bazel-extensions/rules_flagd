#!/usr/bin/env bash
# Fails when any entry in private/versions.bzl's FLAGD_VERSIONS
# lacks a 64-hex SHA-256. No network.
set -euo pipefail

f="${TEST_SRCDIR}/_main/private/versions.bzl"
urls=$(grep -cE '"url":' "$f" || true)
pinned=$(grep -cE '"sha256":[[:space:]]*"[0-9a-f]{64}"' "$f" || true)
echo "urls=$urls pinned=$pinned"
if [[ "$urls" -eq 0 || "$pinned" -ne "$urls" ]]; then
  echo "FAIL: every URL needs a 64-hex SHA-256 (tools/update_checksums.sh <version>)" >&2
  grep -nE '"sha256":' "$f" | grep -vE '"[0-9a-f]{64}"' >&2 || true
  exit 1
fi
echo "PASS"
