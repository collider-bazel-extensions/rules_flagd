#!/usr/bin/env bash
# Helpers for flagd_test scripts:  source "$FLAGD_TESTLIB"
#
#   flagd_eval FLAG [CONTEXT_JSON]        OFREP evaluation as JSON (value, variant,
#                                         reason, or errorCode)
#   flagd_value FLAG [CONTEXT_JSON]       the value: strings raw, others as JSON
#                                         (true, 3, {"a":1}); fails on an error
#   flagd_variant FLAG [CONTEXT_JSON]     the variant
#   flagd_wait_value FLAG EXPECTED [CONTEXT_JSON] [TIMEOUT_S]
#                                         wait until flagd_value prints EXPECTED (30 s)
#   flagd_set_flags FILE.json             replace the runtime overrides with FILE's flags
#   flagd_set_flag KEY FLAG_JSON          add or replace one override
#   flagd_clear_flags                     remove every override
#
#   flagd_stop / flagd_start              stop flagd; start it again on the same
#                                         ports, with the same overrides (waits
#                                         until ready)
#   flagd_start_instance ID               start another replica of this test's
#                                         flagd_server; prints its env file
#   flagd_use ENV_FILE                    point these helpers (and FLAGD_*) at a
#                                         replica; flagd_use "$FLAGD_MAIN_ENV_FILE"
#                                         goes back
#   flagd_on ENV_FILE CMD...              run one command against a replica
#
# Overrides take precedence over the configured flags; the set/clear
# helpers return once flagd serves the change. Each replica has its own
# overrides file.

_flagd_py() { python3 "$FLAGD_TESTLIB_PY" "$@"; }

flagd_eval()        { _flagd_py eval "$@"; }
flagd_value()       { _flagd_py value "$@"; }
flagd_variant()     { _flagd_py variant "$@"; }
flagd_wait_value()  { _flagd_py wait-value "$@"; }
flagd_set_flags()   { _flagd_py set-flags "$1"; }
flagd_set_flag()    { _flagd_py set-flag "$1" "$2"; }
flagd_clear_flags() { _flagd_py clear-flags; }

flagd_stop()  { _flagd_py control /stop; }
flagd_start() { _flagd_py control /start; }

flagd_start_instance() {
  local id="${1:?flagd_start_instance: an instance id}"
  : "${FLAGD_SERVER_BIN:?flagd_start_instance: only inside a flagd_test}"
  local env_file="$TEST_TMPDIR/${FLAGD_SERVER_NAME}@${id}.env" pid
  rm -f "$env_file"
  FLAGD_INSTANCE="$id" "$FLAGD_SERVER_BIN" >&2 &
  pid=$!
  echo "$pid" >> "$FLAGD_INSTANCE_PIDS"
  local deadline=$(( $(date +%s) + 120 ))
  until [[ -f "$env_file" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "flagd_start_instance $id: the server exited before it was ready; see [flagd] lines above" >&2
      return 1
    fi
    if (( $(date +%s) >= deadline )); then
      echo "flagd_start_instance $id: no env file after 120 s" >&2
      return 1
    fi
    sleep 0.05
  done
  printf '%s\n' "$env_file"
}

flagd_use() { set -a; source "${1:?flagd_use: an env file}"; set +a; }
flagd_on()  { local f="${1:?flagd_on: an env file}"; shift; ( flagd_use "$f"; "$@" ); }
