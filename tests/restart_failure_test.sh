#!/usr/bin/env bash
# A restart that can't get its ports back fails, naming the taken port, and
# leaves the server able to start again; a port held only briefly is
# retried (5 attempts, 0.2 s apart) and the restart succeeds.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$FLAGD_TESTLIB"

hold() {  # hold <port> <seconds>: bind 127.0.0.1:<port> in the background
  local ready="$TEST_TMPDIR/held.$1.$2"
  rm -f "$ready"
  python3 -c '
import socket, sys, time
s = socket.socket()
# As most servers do: binds over TIME_WAIT, still conflicts with a listener.
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen()
open(sys.argv[3], "w").close()
time.sleep(float(sys.argv[2]))
' "$1" "$2" "$ready" &
  holder=$!
  for _ in $(seq 1 100); do [[ -f "$ready" ]] && return; sleep 0.02; done
  fail "could not hold port $1"
}

flagd_set_flag banner '{"state": "ENABLED", "variants": {"on": true}, "defaultVariant": "on"}'
port=$FLAGD_OFREP_PORT

# Held across the whole retry window: the restart fails, naming the cause.
flagd_stop
hold "$port" 3
rc=0; out=$(flagd_start 2>&1) || rc=$?
[[ "$rc" != 0 ]] || fail "restart succeeded while port $port was held"
grep -q "500" <<<"$out" || fail "no 500: $out"
grep -q "could not listen on its ports again after 5 attempts 0.2s apart" <<<"$out" || fail "retries not reported: $out"
grep -q "another process holds ofrep $port (address already in use)" <<<"$out" || fail "taken port not named: $out"
wait "$holder"
echo "ok: a port held throughout fails the restart, naming it"

# The server survived the failed restart: once the port is free it starts.
flagd_start
[[ "$FLAGD_OFREP_PORT" == "$port" ]] || fail "ports changed"
[[ "$(flagd_value banner)" == true ]] || fail "override lost after the failed restart"
echo "ok: starts again afterwards, same ports, overrides kept"

# Held briefly: a retry gets the port back.
flagd_stop
hold "$port" 0.3
flagd_start || fail "restart failed although the port was released within the retry window"
wait "$holder"
[[ "$(flagd_value banner)" == true ]] || fail "not serving after a retried restart"
echo "ok: a port held for 0.3 s is retried and the restart succeeds"
echo "PASS"
