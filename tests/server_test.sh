#!/usr/bin/env bash
# flagd_server run directly (as rules_itest would): env file, extra_args,
# caller FLAGD_* ignored, SIGTERM.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

SERVER="$TEST_SRCDIR/_main/$1"
env_file="$TEST_TMPDIR/test_server.env"
rm -f "$env_file"

# A consumer's FLAGD_* (an env file sourced earlier, provider settings)
# must not configure the server.
FLAGD_PORT=1 FLAGD_SOURCES='[{"uri":"/nonexistent","provider":"file"}]' FLAGD_DEBUG=true "$SERVER" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 300); do [[ -f "$env_file" ]] && break; sleep 0.1; done
[[ -f "$env_file" ]] || fail "env file not written"
set -a; source "$env_file"; set +a
[[ "$FLAGD_PORT" != 1 ]] || fail "caller FLAGD_PORT used"

FLAGD_TESTLIB_PY="$TEST_SRCDIR/_main/$2"
v() { python3 "$FLAGD_TESTLIB_PY" value "$@"; }
# extra_args = ["-X", "env=ci"]: a static context value targeting can use.
[[ "$(v by-env)" == ci-on ]] || fail "static context from extra_args not applied: $(v by-env)"
[[ "$(v new-checkout '{"email":"a@example.com"}')" == true ]] || fail "flags not served"
echo "ok: configured server"

kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
trap - EXIT
[[ "$rc" == 0 ]] || fail "SIGTERM exit status $rc"
[[ ! -f "$env_file" ]] || fail "env file left after SIGTERM"
for port in "$FLAGD_PORT" "$FLAGD_OFREP_PORT" "$FLAGD_MANAGEMENT_PORT" "$FLAGD_SYNC_PORT"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail "port $port still open"; fi
done
echo "ok: SIGTERM stops flagd, exit 0, env file removed"
echo "PASS"
