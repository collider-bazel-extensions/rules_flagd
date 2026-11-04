#!/usr/bin/env bash
# flagd_flags_test body: evaluates every case in the given files against
# the auto-launched flagd; JUnit XML to Bazel's test results.
set -euo pipefail
exec python3 "$FLAGD_TESTLIB_PY" run-cases --junit "${XML_OUTPUT_FILE:-}" "$@"
