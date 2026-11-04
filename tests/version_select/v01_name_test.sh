#!/usr/bin/env bash
set -euo pipefail
p="$1"; f="$TEST_SRCDIR/${p#../}"; [[ -e "$f" ]] || f="$TEST_SRCDIR/_main/$p"
v=$("$f" version 2>&1)
[[ "$v" == *v0.17.1* ]] || { echo "FAIL: $v" >&2; exit 1; }
echo "PASS: v0.1 name serves flagd 0.17.1"
