#!/usr/bin/env bash
# A flagd_flags_test with a wrong expectation fails, names the case and
# shows want / got, and writes a JUnit failure; the other case passes.
#
# Argv: <trampoline> <wrong_flags_test server> <inner> <testlib.sh> <testlib.py> <wrong_test.json>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
xml="$TEST_TMPDIR/junit.xml"
rc=0
out=$(TEST_TMPDIR="$inner_tmp" XML_OUTPUT_FILE="$xml" \
      "$TEST_SRCDIR/_main/$1" "$2" "$3" wrong_flags_test_flagd "$4" "$5" "$6" 2>&1) || rc=$?
[[ "$rc" != 0 ]] || fail "wrong expectation passed: $out"
grep -q "FAIL wrong_test.json: deliberately wrong expectation" <<<"$out" || fail "case not named: $out"
grep -q "value: want 5, got 20" <<<"$out" || fail "want/got not shown: $out"
grep -q "ok   wrong_test.json: this one passes" <<<"$out" || fail "passing case not reported: $out"
grep -q "1/2 flag evaluation cases passed" <<<"$out" || fail "summary: $out"
grep -q '<testsuite name="wrong_test.json" tests="2" failures="1">' "$xml" || fail "JUnit summary: $(cat "$xml")"
grep -q '<failure message="value: want 5, got 20">' "$xml" || fail "JUnit failure: $(cat "$xml")"
echo "PASS"
