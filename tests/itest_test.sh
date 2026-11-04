#!/usr/bin/env bash
# The test half of a rules_itest service_test: flagd_server ran as an
# itest_service and its health check passed, so its env file is there.
set -euo pipefail
set -a; source "$TEST_TMPDIR/itest_server.env"; set +a
# service_test runs this without the sh_test's args; find the helper in runfiles.
got=$(python3 "$TEST_SRCDIR/_main/private/testlib.py" value color)
[[ "$got" == "#00ff00" ]] || { echo "FAIL: color=$got" >&2; exit 1; }
echo "PASS"
