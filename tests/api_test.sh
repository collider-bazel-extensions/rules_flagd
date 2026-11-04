#!/usr/bin/env bash
# flagd_test: environment, OFREP + Connect + sync endpoints, test helpers,
# runtime overrides, args forwarded.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$FLAGD_TESTLIB"

[[ $# -eq 2 && "$1" == one && "$2" == "two words" ]] || fail "args: $# [$*]"
for k in FLAGD_HOST FLAGD_PORT FLAGD_SYNC_PORT FLAGD_OFREP_PORT FLAGD_MANAGEMENT_PORT \
         FLAGD_URL FLAGD_OFREP_URL FLAGD_OVERRIDES_FILE FLAGD; do
  [[ -n "${!k:-}" ]] || fail "$k not set"
done
[[ "$FLAGD_URL" == "http://127.0.0.1:$FLAGD_PORT" ]] || fail "FLAGD_URL=$FLAGD_URL"
[[ "$("$FLAGD" version 2>&1)" == *"v0.18.2"* ]] || fail "FLAGD is not flagd 0.18.2"
echo "ok: environment"

# ---- helpers over OFREP ------------------------------------------------------
[[ "$(flagd_value new-checkout '{"email":"a@example.com"}')" == true ]] || fail "staff value"
[[ "$(flagd_variant new-checkout '{"email":"a@other.test"}')" == off ]] || fail "non-staff variant"
[[ "$(flagd_value color)" == "#00ff00" ]] || fail "merged color"
[[ "$(flagd_value discount '{"tier":"gold"}')" == 20 ]] || fail "number value"
[[ "$(flagd_value banner)" == '{"dismissible": true, "text": "Welcome"}' ]] || fail "object value: $(flagd_value banner)"
[[ "$(flagd_eval retired)" == *'"reason": "DISABLED"'* ]] || fail "disabled flag: $(flagd_eval retired)"
if out=$(flagd_value no-such-flag 2>&1); then fail "flagd_value succeeded for a missing flag"; fi
grep -q "FLAG_NOT_FOUND" <<<"$out" || fail "missing flag error: $out"
echo "ok: flagd_value / flagd_variant / flagd_eval"

# ---- the other endpoints -------------------------------------------------------
# Connect (what the OpenFeature flagd providers speak, RPC mode).
connect=$(python3 - <<'PY'
import json, os, urllib.request
req = urllib.request.Request(
    os.environ["FLAGD_URL"] + "/flagd.evaluation.v1.Service/ResolveBoolean",
    data=json.dumps({"flagKey": "new-checkout", "context": {"email": "x@example.com"}}).encode(),
    headers={"Content-Type": "application/json"})
print(json.load(urllib.request.urlopen(req, timeout=10)))
PY
)
[[ "$connect" == *"'value': True"* && "$connect" == *"'variant': 'on'"* ]] || fail "Connect ResolveBoolean: $connect"
# Sync (in-process providers) serves the merged flag set.
python3 -c "
import json, os, urllib.request
flags = json.load(urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"FLAGD_SYNC_PORT\"]}/v1/flags'))['flags']
assert flags['color']['defaultVariant'] == 'green', flags['color']
assert 'rollout' in flags
" || fail "sync /v1/flags"
python3 -c "
import os, urllib.request
body = urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"FLAGD_MANAGEMENT_PORT\"]}/metrics').read().decode()
assert 'http_server' in body or 'feature_flag' in body or 'go_' in body, body[:200]
" || fail "management /metrics"
echo "ok: Connect, sync, management endpoints"

# ---- runtime overrides --------------------------------------------------------
flagd_set_flag color '{"state":"ENABLED","variants":{"pink":"#ff00ff"},"defaultVariant":"pink"}'
[[ "$(flagd_value color)" == "#ff00ff" ]] || fail "set_flag not applied"
flagd_set_flag brand-new '{"state":"ENABLED","variants":{"y":"yes"},"defaultVariant":"y"}'
[[ "$(flagd_value brand-new)" == yes ]] || fail "new override flag"
[[ "$(flagd_value color)" == "#ff00ff" ]] || fail "second set_flag dropped the first"
echo "ok: flagd_set_flag (override + new flag)"

cat > "$TEST_TMPDIR/ov.json" <<'JSON'
{"flags": {"new-checkout": {"state": "ENABLED", "variants": {"on": true, "off": false}, "defaultVariant": "on"}}}
JSON
flagd_set_flags "$TEST_TMPDIR/ov.json"
[[ "$(flagd_value new-checkout '{"email":"a@other.test"}')" == true ]] || fail "set_flags not applied"
[[ "$(flagd_value color)" == "#00ff00" ]] || fail "set_flags did not replace earlier overrides"
if flagd_value brand-new >/dev/null 2>&1; then fail "set_flags left brand-new"; fi
echo "ok: flagd_set_flags replaces the overrides"

flagd_clear_flags
[[ "$(flagd_value new-checkout '{"email":"a@other.test"}')" == false ]] || fail "clear_flags"
echo "ok: flagd_clear_flags"

# flagd_wait_value for changes made some other way (e.g. by the code under test).
python3 - <<'PY'
import json, os
p = os.environ["FLAGD_OVERRIDES_FILE"]
doc = json.load(open(p))
doc["flags"] = {"color": {"state": "ENABLED", "variants": {"w": "white"}, "defaultVariant": "w"}}
open(p + ".tmp", "w").write(json.dumps(doc)); os.replace(p + ".tmp", p)
PY
flagd_wait_value color white '{}' 10 || fail "wait_value"
if flagd_wait_value color never '{}' 1 2>/dev/null; then fail "wait_value did not time out"; fi
echo "ok: flagd_wait_value"
echo "PASS"
