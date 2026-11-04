#!/usr/bin/env bash
# flagd_flags_test(require_coverage = True) fails when a configured flag
# has no case, naming each one, with a JUnit "coverage" failure.
#
# Argv: <trampoline> <server> <inner> <testlib.sh> <testlib.py> --require-coverage <one_flag.json>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
xml="$TEST_TMPDIR/junit.xml"
rc=0
out=$(TEST_TMPDIR="$inner_tmp" XML_OUTPUT_FILE="$xml" \
      "$TEST_SRCDIR/_main/$1" "$2" "$3" uncovered_flags_test_flagd "$4" "$5" "$6" "$7" 2>&1) || rc=$?
echo "$out"
[[ "$rc" != 0 ]] || fail "uncovered flags passed"
grep -q "ok   one_flag.json: banner is off by default" <<<"$out" || fail "the case itself should pass"
grep -q "FAIL coverage: 5 configured flag(s) untested: color, discount, new-checkout, retired, rollout" <<<"$out" \
  || fail "untested flags not named"
grep -q "1/2 flag evaluation cases passed" <<<"$out" || fail "summary"
grep -q '<testsuite name="coverage" tests="1" failures="1">' "$xml" || fail "JUnit: $(cat "$xml")"
echo "PASS"
