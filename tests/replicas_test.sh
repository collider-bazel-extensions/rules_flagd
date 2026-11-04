#!/usr/bin/env bash
# flagd_stop / flagd_start restart flagd on the same ports with the same
# overrides; flagd_start_instance runs a second replica of this target.
# Fractional assignment is stable for a subject across both.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$FLAGD_TESTLIB"

ctx='{"targetingKey": "user-42"}'
before=$(flagd_variant rollout "$ctx")
port=$FLAGD_PORT ofrep=$FLAGD_OFREP_PORT
configured_banner=$(flagd_value banner)
flagd_set_flag banner '{"state": "ENABLED", "variants": {"on": true, "off": false}, "defaultVariant": "on"}'
[[ "$(flagd_value banner)" == true ]] || fail "override not served"

flagd_stop
if flagd_eval rollout >/dev/null 2>&1; then fail "flagd still answering after flagd_stop"; fi
flagd_start
flagd_start   # already running: no-op
[[ "$FLAGD_PORT" == "$port" && "$FLAGD_OFREP_PORT" == "$ofrep" ]] || fail "ports changed"
[[ "$(flagd_variant rollout "$ctx")" == "$before" ]] || fail "subject changed variant across a restart"
[[ "$(flagd_value banner)" == true ]] || fail "override lost across a restart"
echo "ok: restart on the same ports, override kept, $before for user-42"

b=$(flagd_start_instance b)
[[ "$b" == "$TEST_TMPDIR/replicas_test_flagd@b.env" ]] || fail "replica env file: $b"
[[ "$(flagd_on "$b" flagd_variant rollout "$ctx")" == "$before" ]] || fail "replica gives a different variant"
[[ "$(flagd_on "$b" flagd_value banner)" == "$configured_banner" ]] || fail "replica shares the first one's overrides"
b_port=$(flagd_on "$b" bash -c 'echo $FLAGD_PORT')
[[ "$b_port" != "$FLAGD_PORT" ]] || fail "replica on the same port"
# 50/50 split: some subject lands on each variant, identically on both.
for i in $(seq 1 20); do
  c="{\"targetingKey\": \"user-$i\"}"
  [[ "$(flagd_variant rollout "$c")" == "$(flagd_on "$b" flagd_variant rollout "$c")" ]] || fail "user-$i differs"
done
flagd_use "$b"
[[ "$FLAGD_PORT" == "$b_port" ]] || fail "flagd_use"
flagd_stop && flagd_start
[[ "$(flagd_variant rollout "$ctx")" == "$before" ]] || fail "replica restart"
flagd_use "$FLAGD_MAIN_ENV_FILE"
[[ "$FLAGD_PORT" == "$port" ]] || fail "flagd_use back to the main server"
echo "ok: a second replica (own ports and overrides), same assignments, restartable"
echo "PASS"
