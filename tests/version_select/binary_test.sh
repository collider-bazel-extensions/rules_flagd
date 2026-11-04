#!/usr/bin/env bash
set -euo pipefail
source "$FLAGD_TESTLIB"
v=$("$FLAGD" version 2>&1)
[[ "$v" == *"v0.17.1"* ]] || { echo "FAIL: toolchain flagd is not 0.17.1: $v" >&2; exit 1; }
[[ "$(flagd_value greeting)" == hello ]] || { echo "FAIL: not serving" >&2; exit 1; }
echo "PASS: $v"
