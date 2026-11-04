#!/usr/bin/env bash
# flagd_test trampoline — starts flagd, then runs the user's test.
#
# Argv: <server> <inner> <server_name> <testlib.sh> <testlib.py> [user args...]
set -euo pipefail

SERVER_SHORT="$1"; INNER_SHORT="$2"; SERVER_NAME="$3"; LIB_SHORT="$4"; LIBPY_SHORT="$5"
shift 5

: "${TEST_TMPDIR:?flagd_test: TEST_TMPDIR not set (expected under bazel test)}"
if [[ -z "${RUNFILES_DIR:-}" ]]; then
  RUNFILES_DIR="${TEST_SRCDIR:-$0.runfiles}"
  export RUNFILES_DIR
fi

resolve() {
  local p="$1"
  for c in "${RUNFILES_DIR}/_main/${p}" "${RUNFILES_DIR}/${p}" "${RUNFILES_DIR}/${p#../}"; do
    [[ -e "$c" ]] && { printf '%s\n' "$c"; return; }
  done
  echo "flagd_test: not in runfiles: ${p}" >&2
  exit 1
}

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

env_file="$TEST_TMPDIR/${SERVER_NAME}.env"
rm -f "$env_file"
"$(resolve "$SERVER_SHORT")" &
server_pid=$!
# The server enforces its own ready_timeout; this outer bound only guards
# against a hung launcher or setup script.
deadline=$(( $(date +%s) + 600 ))
until [[ -f "$env_file" ]]; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid" && rc=0 || rc=$?
    server_pid=""
    echo "flagd_test: flagd server exited (status $rc) before it was ready; see [flagd] lines above" >&2
    exit 1
  fi
  (( $(date +%s) < deadline )) || { echo "flagd_test: timed out waiting for $env_file" >&2; exit 1; }
  sleep 0.1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
FLAGD_TESTLIB="$(resolve "$LIB_SHORT")"
FLAGD_TESTLIB_PY="$(resolve "$LIBPY_SHORT")"
export FLAGD_TESTLIB FLAGD_TESTLIB_PY

# Not exec: the trap must stop flagd when the test ends.
"$(resolve "$INNER_SHORT")" "$@"
