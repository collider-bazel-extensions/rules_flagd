#!/usr/bin/env bash
# The README's install snippet names the version MODULE.bazel declares
# (rules_flagd#3: v0.2.0 shipped with a 0.1.0 snippet).
#
# Argv: <MODULE.bazel> <README.md>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
M="$TEST_SRCDIR/_main/$1"; R="$TEST_SRCDIR/_main/$2"
v=$(awk '/^module\(/{m=1} m && /^    version = /{gsub(/[",]/,"",$3); print $3; exit}' "$M")
[[ -n "$v" ]] || fail "no version in MODULE.bazel"
grep -qx "bazel_dep(name = \"rules_flagd\", version = \"$v\")" "$R" || fail "README bazel_dep is not $v: $(grep 'name = "rules_flagd"' "$R")"
grep -qx "    tag = \"v$v\"," "$R" || fail "README git_override tag is not v$v"
echo "PASS: README installs $v"
