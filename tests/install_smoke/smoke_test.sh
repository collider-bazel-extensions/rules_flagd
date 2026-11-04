#!/usr/bin/env bash
# Full E2E install smoke for flagd_install in namespace `features`:
#
#   1. The itest chain (kind → flagd_install) has applied the manifest and
#      waited for deploy/flagd to roll out.
#   2. Through `kubectl port-forward svc/flagd`, evaluate over OFREP:
#      targeting, the merge order of the two flag files, an object flag.
#   3. The sync port serves the merged flag set (in-process providers).
#   4. The pod runs as the image's non-root user with a read-only root.
set -euo pipefail

env_file="$TEST_TMPDIR/cluster.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")
NS=features
fail() {
  echo "smoke: FAIL — $*" >&2
  "${KCTL[@]}" -n "$NS" get pods,svc -o wide >&2 || true
  "${KCTL[@]}" -n "$NS" logs deploy/flagd --tail=100 >&2 || true
  exit 1
}

"${KCTL[@]}" -n "$NS" get svc flagd >/dev/null || fail "no svc/flagd in $NS"

pf_log="$TEST_TMPDIR/port-forward.log"
"${KCTL[@]}" -n "$NS" port-forward svc/flagd :8016 :8015 > "$pf_log" 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
deadline=$(( $(date +%s) + 60 ))
until [[ $(grep -c '^Forwarding from 127.0.0.1:' "$pf_log") -ge 2 ]]; do
  kill -0 "$pf" 2>/dev/null || fail "port-forward exited: $(cat "$pf_log")"
  (( $(date +%s) < deadline )) || fail "port-forward not ready: $(cat "$pf_log")"
  sleep 0.5
done
ofrep_port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) -> 8016$/\1/p' "$pf_log")
sync_port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) -> 8015$/\1/p' "$pf_log")
echo "smoke: port-forward OFREP :$ofrep_port, sync :$sync_port"

python3 - "$ofrep_port" "$sync_port" <<'PY' || fail "evaluation checks"
import json, sys, urllib.error, urllib.request
ofrep, sync = sys.argv[1:]

def ev(flag, ctx):
    req = urllib.request.Request(
        f"http://127.0.0.1:{ofrep}/ofrep/v1/evaluate/flags/{flag}",
        data=json.dumps({"context": ctx}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=10))
    except urllib.error.HTTPError as e:
        return json.load(e)

checks = [
    (ev("new-checkout", {"email": "a@example.com"}), {"value": True, "variant": "on"}),
    (ev("new-checkout", {"email": "a@other.test"}), {"value": False}),
    (ev("color", {}), {"value": "#00ff00"}),          # overrides.yaml wins
    (ev("banner", {}), {"value": {"text": "Welcome", "dismissible": True}}),
    (ev("no-such-flag", {}), {"errorCode": "FLAG_NOT_FOUND"}),
]
for got, want in checks:
    for k, v in want.items():
        assert got.get(k) == v, f"{got} != {want}"
    print("smoke:", json.dumps(got, sort_keys=True))

flags = json.load(urllib.request.urlopen(f"http://127.0.0.1:{sync}/v1/flags", timeout=10))["flags"]
assert flags["color"]["defaultVariant"] == "green", flags["color"]
print("smoke: sync /v1/flags serves", len(flags), "merged flags")
PY

pod=$("${KCTL[@]}" -n "$NS" get pod -l app.kubernetes.io/name=flagd -o jsonpath='{.items[0].metadata.name}')
uid=$("${KCTL[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.spec.securityContext.runAsUser}')
ro=$("${KCTL[@]}" -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}')
[[ "$uid" == 65532 && "$ro" == true ]] || fail "pod security: runAsUser=$uid readOnlyRootFilesystem=$ro"
echo "smoke: OK — flagd in namespace $NS evaluates our flags"
