#!/usr/bin/env bash
# A server that can't start or isn't ready in time exits non-zero, names
# flagd and the cause, shows its log, and writes no env file; flagd_test
# fails before running the test body.
#
# Argv: <bad_flag server> <slow server> <trampoline> <failing_flagd_test server>
#       <failing_flagd_test inner> <testlib.sh> <testlib.py>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

run() {
  local name="$1" path="$TEST_SRCDIR/_main/$2" rc=0
  out=$(timeout 120 "$path" 2>&1) || rc=$?
  [[ "$rc" != 0 ]] || fail "$name: exited 0. Output: $out"
  [[ "$rc" != 124 ]] || fail "$name: hung. Output: $out"
  [[ ! -f "$TEST_TMPDIR/$name.env" ]] || fail "$name: env file written"
}

run bad_flag_server "$1"
grep -q "flagd exited with status" <<<"$out" || fail "bad_flag: cause not named: $out"
grep -q "unknown flag: --no-such-flag" <<<"$out" || fail "bad_flag: flagd log not shown: $out"
echo "ok: flagd that can't start"

run slow_server "$2"
grep -q "flagd was not ready (GET /readyz and every port answering) within 0.001s" <<<"$out" || fail "slow: cause not named: $out"
echo "ok: readiness timeout"

inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
rc=0
out=$(TEST_TMPDIR="$inner_tmp" timeout 120 "$TEST_SRCDIR/_main/$3" "$4" "$5" failing_flagd_test_flagd "$6" "$7" 2>&1) || rc=$?
[[ "$rc" != 0 && "$rc" != 124 ]] || fail "failing flagd_test: status $rc: $out"
grep -q "flagd_test: flagd server exited" <<<"$out" || fail "flagd_test: cause not named: $out"
if grep -q "TEST BODY RAN" <<<"$out"; then fail "flagd_test ran the test body"; fi
echo "ok: flagd_test fails before the test runs"
echo "PASS"
