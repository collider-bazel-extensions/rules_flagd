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
# Replicas started by flagd_start_instance record their pids here.
export FLAGD_INSTANCE_PIDS="$TEST_TMPDIR/.flagd_instance_pids"
: > "$FLAGD_INSTANCE_PIDS"
cleanup() {
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
  done < "$FLAGD_INSTANCE_PIDS"
  if [[ -n "$server_pid" ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  done < "$FLAGD_INSTANCE_PIDS"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

env_file="$TEST_TMPDIR/${SERVER_NAME}.env"
rm -f "$env_file"
FLAGD_SERVER_BIN="$(resolve "$SERVER_SHORT")"
FLAGD_SERVER_NAME="$SERVER_NAME"
export FLAGD_SERVER_BIN FLAGD_SERVER_NAME
unset FLAGD_INSTANCE
"$FLAGD_SERVER_BIN" &
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
FLAGD_MAIN_ENV_FILE="$env_file"   # flagd_use goes back to it after a replica
FLAGD_TESTLIB="$(resolve "$LIB_SHORT")"
FLAGD_TESTLIB_PY="$(resolve "$LIBPY_SHORT")"
export FLAGD_MAIN_ENV_FILE FLAGD_TESTLIB FLAGD_TESTLIB_PY

# Not exec: the trap must stop flagd when the test ends.
"$(resolve "$INNER_SHORT")" "$@"
