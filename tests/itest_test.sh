#!/usr/bin/env bash
# The test half of a rules_itest service_test: flagd_server ran as two
# itest_services (the second with FLAGD_INSTANCE=b) and both health checks
# passed, so both env files are there.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
# service_test runs this without the sh_test's args; find the helper in runfiles.
lib="$TEST_SRCDIR/_main/private/testlib.py"
a=$( set -a; source "$TEST_TMPDIR/itest_server.env"; set +a; echo "$FLAGD_PORT $(python3 "$lib" value color) $(python3 "$lib" variant rollout '{"targetingKey":"u1"}')")
b=$( set -a; source "$TEST_TMPDIR/itest_server@b.env"; set +a; echo "$FLAGD_PORT $(python3 "$lib" value color) $(python3 "$lib" variant rollout '{"targetingKey":"u1"}')")
read -r pa ca va <<<"$a"; read -r pb cb vb <<<"$b"
[[ "$ca" == "#00ff00" && "$cb" == "#00ff00" ]] || fail "color: $ca / $cb"
[[ "$pa" != "$pb" ]] || fail "both replicas on port $pa"
[[ "$va" == "$vb" ]] || fail "u1: $va vs $vb"
echo "PASS"
