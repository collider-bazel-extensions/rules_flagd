#!/usr/bin/env python3
"""Starts flagd for rules_flagd. Two modes:

  launcher.py check --flagd BIN --marker OUT [--strict] FILE...
      flagd_flags' validation action. Loads each flag file into its own
      flagd and fails if flagd refuses it ("error setting state": bad
      JSON/YAML, an unknown defaultVariant, ...) or, with --strict, if
      flagd reports that it does not conform to the flagd schema (which
      flagd itself only logs as a warning). flagd validates against its
      embedded schemas, so there is no network access. Writes OUT on
      success.

  launcher.py serve --flagd BIN --env-file PATH --state-dir DIR
                    --ready-timeout SECONDS [--source FILE]...
                    [-- EXTRA_FLAGD_FLAGS...]
      flagd_server. Picks four free ports (evaluation, management, sync,
      OFREP) and starts `flagd start` with writable copies of the sources
      in order, plus an overrides source last (highest precedence) for
      the test helpers. Records which source defines each key in
      <state-dir>/sources.json. Ports are bind-checked before flagd starts;
      a clash retries with new ports, up to 5 times. Once GET /readyz on
      the management port answers 200 and every other port answers HTTP,
      writes the env file atomically:
        FLAGD_HOST=127.0.0.1
        FLAGD_PORT=<evaluation port>   (OpenFeature flagd providers, RPC)
        FLAGD_SYNC_PORT=<sync port>    (in-process providers)
        FLAGD_OFREP_PORT / FLAGD_MANAGEMENT_PORT
        FLAGD_URL=http://127.0.0.1:<evaluation port>
        FLAGD_OFREP_URL=http://127.0.0.1:<OFREP port>
        FLAGD_OVERRIDES_FILE=<overrides source>
        FLAGD_CONTROL_URL=http://127.0.0.1:<port>   (POST /stop, /start)
        FLAGD_ENV_FILE=<this env file>
        FLAGD=<absolute path to the flagd binary>
      The control endpoint stops flagd and starts it again on the same
      ports, sources and overrides file. SIGTERM / SIGINT stop flagd,
      remove the env file and exit 0; if flagd dies without being asked
      to, exits with its status.

In both modes a flagd that refuses its flags, exits, or isn't ready in
time is an error that names the cause and prints flagd's log.
"""

import argparse
import errno
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_REFUSED = "error setting state"
_IN_USE = "address already in use"
_SHUTTING_DOWN = "shutting down"
# Start attempts: new free ports each time on a first start; the same
# ports, _RESTART_DELAY apart, on a restart.
_RESTART_ATTEMPTS = 5
_RESTART_DELAY = 0.2
_SCHEMA = "does not conform to the schema"


class Failed(Exception):
    """flagd refused its flags or couldn't start; the message says why."""


def _log(msg):
    print(f"[flagd] {msg}", file=sys.stderr, flush=True)


def _free_ports(n):
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def _ready(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/readyz", timeout=2) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError):
        return False


def _answers_http(port):
    """True if something on the port answers HTTP (any status). flagd's
    listeners all do; a port another process holds without serving (or a
    listener flagd hasn't opened yet) doesn't."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=0.5):
            return True
    except urllib.error.HTTPError:
        return True
    except (urllib.error.URLError, OSError):
        return False


def _all_ready(ports):
    """/readyz on the management port, and every other port answering.
    /readyz alone can answer before another listener fails to bind (and
    flagd exits), which would pass off a port another process holds."""
    return _ready(ports["management"]) and all(
        _answers_http(ports[k]) for k in ("evaluation", "sync", "ofrep"))


def _read_from(path, offset):
    """The log from byte `offset` on (this attempt's part)."""
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            return f.read().decode("utf-8", "replace")
    except OSError:
        return "(no log)"


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return "(no log)"


def flagd_env(home):
    """The caller's environment without FLAGD_* (flagd reads those as
    configuration; an env file sourced by a test sets several), with HOME
    pointing at `home` so a user's ~/.agent.yaml can't configure it."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("FLAGD_")}
    env["HOME"] = home
    os.makedirs(home, exist_ok=True)
    return env


def _bindable(port):
    """Whether flagd could listen on `port`: bind it as flagd does, on all
    interfaces (dual-stack where available) with SO_REUSEADDR, so a
    listener on 127.0.0.1 or any other address counts as taken."""
    for family, addr in ((socket.AF_INET6, "::"), (socket.AF_INET, "")):
        try:
            s = socket.socket(family)
        except OSError:
            continue
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            s.bind((addr, port))
            return True
        except OSError as e:
            if e.errno == errno.EADDRINUSE:
                return False
            continue  # e.g. IPv6 disabled: try IPv4
        finally:
            s.close()
    return True


def _taken(ports):
    return [f"{name} {port}" for name, port in ports.items() if not _bindable(port)]


def start(flagd, sources, state_dir, ready_timeout, extra, procs, fixed_ports=None):
    """Start flagd and wait until it is ready on every port. Returns
    (proc, ports, log_path); ports maps evaluation/management/sync/ofrep.

    Ports are checked before flagd starts: when a listener can't bind,
    flagd shuts down gracefully, which takes 5 s, and only then logs why.
    A first start retries a clash with new free ports. A restart
    (fixed_ports) keeps its ports and retries them, _RESTART_DELAY apart,
    then fails naming the taken ports. Each attempt reads only its own
    part of the log, which a restart appends to."""
    log_path = os.path.join(state_dir, "flagd.log")
    env = flagd_env(os.path.join(state_dir, "home"))
    taken = []
    for attempt in range(1, _RESTART_ATTEMPTS + 1):
        if attempt > 1 and fixed_ports:
            time.sleep(_RESTART_DELAY)
        if fixed_ports:
            ports = dict(fixed_ports)
        else:
            ev, mgmt, sync, ofrep = _free_ports(4)
            ports = {"evaluation": ev, "management": mgmt, "sync": sync, "ofrep": ofrep}
        taken = _taken(ports)
        if taken:
            _log(f"port taken: {', '.join(taken)} (attempt {attempt}); "
                 + ("retrying" if attempt < _RESTART_ATTEMPTS else "giving up"))
            continue
        ev, mgmt, sync, ofrep = ports["evaluation"], ports["management"], ports["sync"], ports["ofrep"]
        cmd = [flagd, "start", "-p", str(ev), "-m", str(mgmt), "-g", str(sync), "-r", str(ofrep)]
        # fsnotify: changes apply in ~10 ms; the default `file:` provider
        # polls once a second.
        if sources:
            cmd += ["--sources", json.dumps([{"uri": s, "provider": "fsnotify"} for s in sources])]
        cmd += extra
        with open(log_path, "a" if fixed_ports else "w") as log:
            offset = os.path.getsize(log_path)  # bytes: what earlier runs wrote
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, env=env)
        procs.append(proc)
        deadline = time.monotonic() + ready_timeout
        refused = shutting_down = False
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                break
            if _all_ready(ports) and proc.poll() is None:
                return proc, ports, log_path
            out = _read_from(log_path, offset)
            if _REFUSED in out:
                refused = True
                break
            # Shutting down before it was ready: a listener failed (a port
            # taken between the check and flagd's bind). Don't wait out
            # flagd's 5 s graceful shutdown.
            if _SHUTTING_DOWN in out or _IN_USE in out:
                shutting_down = True
                break
            time.sleep(0.05)
        timed_out = proc.poll() is None and not refused and not shutting_down
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        out = _read_from(log_path, offset)
        if refused or _REFUSED in out:
            raise Failed("flagd refused the flags:\n" + _refusal(out))
        taken = _taken(ports)
        if taken or _IN_USE in out:
            _log(f"port taken: {', '.join(taken) or 'see the log'} (attempt {attempt}); "
                 + ("retrying" if attempt < _RESTART_ATTEMPTS else "giving up"))
            continue
        if timed_out:
            raise Failed(f"flagd was not ready (GET /readyz and every port answering) within "
                         f"{ready_timeout:g}s. flagd log:\n{out}")
        raise Failed(f"flagd exited with status {proc.returncode} before it was ready. "
                     f"flagd log:\n{out}")
    if fixed_ports:
        raise Failed(f"flagd could not listen on its ports again after {_RESTART_ATTEMPTS} "
                     f"attempts {_RESTART_DELAY:g}s apart: another process holds "
                     f"{', '.join(taken) or 'one of them'} (address already in use)")
    raise Failed(f"flagd could not get free ports after {_RESTART_ATTEMPTS} attempts")


def _refusal(log):
    lines = [l for l in log.splitlines() if _REFUSED in l]
    return "\n".join("  " + l.split(_REFUSED, 1)[1].lstrip(": ").split("\t")[0]
                     for l in lines) or log


def _schema_report(log):
    """The schema-validation part of flagd's log (a multi-line warning)."""
    lines = log.splitlines()
    for i, line in enumerate(lines):
        if _SCHEMA in line:
            out = [line.split(_SCHEMA, 1)[1].lstrip("; ")]
            for nxt in lines[i + 1:]:
                if not nxt.startswith((" ", "-")):
                    break
                out.append(nxt.split("\t")[0])
            return "\n".join("  " + l for l in out)
    return None


def schema_causes(report):
    """The most specific failures in flagd's schema report.

    The report is a tree: `'allOf' failed` nodes need every child,
    `'anyOf'` / `'oneOf'` nodes list one failed branch per alternative (a
    flag's variants may be booleans, strings, numbers or objects, so a bad
    `state` fails once per variant type, next to type mismatches that
    only explain why the *other* alternatives failed). For an alternative
    node the causes are the errors common to every branch; if there are
    none, the deepest branch's. Returns "at '<path>': <message>" lines.
    """
    nodes = []  # (depth, path, message)
    for line in report.splitlines():
        stripped = line.lstrip(" ")
        if not stripped.startswith("- at '"):
            continue
        depth = (len(line) - len(stripped)) // 2
        path, _, msg = stripped[len("- at '"):].partition("': ")
        nodes.append((depth, path, msg.strip()))
    if not nodes:
        return []

    def build(i):
        depth, path, msg = nodes[i]
        children, j = [], i + 1
        while j < len(nodes) and nodes[j][0] > depth:
            if nodes[j][0] == depth + 1:
                children.append(j)
            j += 1
        return (path, msg, [build(c) for c in children])

    def causes(node):
        path, msg, kids = node
        if not kids:
            return [(path, msg)]
        sets = [causes(k) for k in kids]
        if "'allOf' failed" in msg:
            out = []
            for s in sets:
                out += [c for c in s if c not in out]
            return out
        common = [c for c in sets[0] if all(c in s for s in sets[1:])]
        if common:
            return common
        # No error shared by every alternative: the deepest branches are the
        # closest matches (then those with fewest errors); equally close
        # branches are all shown, e.g. variants of mixed types.
        rank = lambda s: (max(p.count("/") for p, _ in s), -len(s))  # noqa: E731
        best = max(rank(s) for s in sets)
        out = []
        for s in sets:
            if rank(s) == best:
                out += [c for c in s if c not in out]
        return out

    roots = [i for i, n in enumerate(nodes) if n[0] == nodes[0][0]]
    out = []
    for r in roots:
        for c in causes(build(r)):
            if c not in out:
                out.append(c)
    return [f"at '{p}': {m}" for p, m in out]


def check(args):
    status = 0
    for path in args.files:
        with tempfile.TemporaryDirectory() as state:
            procs = []
            try:
                proc, _, log_path = start(args.flagd, [os.path.abspath(path)], state,
                                          args.ready_timeout, [], procs)
            except Failed as e:
                print(f"flagd_flags: {path}: {e}", file=sys.stderr)
                status = 1
                continue
            # Schema validation is logged before the store is ready.
            report = _schema_report(_read(log_path))
            proc.terminate()
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            if report:
                kind = "error" if args.strict else "warning"
                causes = schema_causes(report)
                summary = "".join(f"  {c}\n" for c in causes)
                print(f"flagd_flags: {path}: does not conform to the flagd schema ({kind}):\n"
                      f"{summary}"
                      f"  full report:\n"
                      + "\n".join("  " + l for l in report.splitlines()), file=sys.stderr)
                if args.strict:
                    status = 1
    if status == 0:
        open(args.marker, "w").close()
    return status


def write_env(env_file, values):
    tmp = env_file + ".tmp"
    with open(tmp, "w") as f:
        for k, v in values.items():
            f.write(f"{k}={v}\n")
    os.replace(tmp, env_file)


def serve(args):
    os.makedirs(args.state_dir, exist_ok=True)
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass
    # Writable copies of the sources: when an override is removed, flagd
    # drops the key outright, and the configured definition only comes back
    # when its source re-syncs, so the test helpers rewrite the copy.
    src_dir = os.path.join(args.state_dir, "sources")
    if os.path.isdir(src_dir):
        shutil.rmtree(src_dir)
    os.makedirs(src_dir)
    sources = []
    for i, src in enumerate(args.source):
        copy = os.path.join(src_dir, f"{i:02d}-{os.path.basename(src)}")
        shutil.copyfile(src, copy)
        sources.append(copy)
    overrides = os.path.join(args.state_dir, "overrides.json")
    with open(overrides, "w") as f:
        json.dump({"metadata": {"rules_flagd_generation": "0"}, "flags": {}}, f)
    sources.append(overrides)

    # Installed before flagd starts, so a signal during start-up still
    # stops it. Once ready, the handler only asks flagd to stop: the main
    # thread is blocked in proc.wait(), which holds Popen's wait lock, so
    # waiting here as well would stall until a timeout.
    procs, stopping, ready = [], [], []

    def _stop(signum, _frame):
        if stopping:
            return
        _log(f"signal {signum}; stopping")
        stopping.append(signum)
        for p in procs:
            if p.poll() is None:
                p.terminate()
                killer = threading.Timer(10, p.kill)
                killer.daemon = True
                killer.start()
        if not ready:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    try:
        proc, ports, log_path = start(args.flagd, sources, args.state_dir,
                                      args.ready_timeout, args.extra, procs)
    except Failed as e:
        _log(str(e))
        return 1

    ev, ofrep = ports["evaluation"], ports["ofrep"]
    # Which source defines each key, for restoring keys after overrides.
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{ports['sync']}/v1/flags", timeout=10) as r:
            served = json.load(r).get("flags", {})
    except (urllib.error.URLError, OSError, ValueError) as e:
        _log(f"could not read the served flags from the sync port: {e}")
        proc.kill()
        return 1
    with open(os.path.join(args.state_dir, "sources.json"), "w") as f:
        json.dump({k: v.get("source") for k, v in served.items()}, f)

    server = {"proc": proc, "stopped": False}
    lock = threading.Lock()

    def control(path):
        """POST /stop, /start: restart flagd on the same ports, with the
        same sources and overrides file."""
        if stopping:
            return 503, "shutting down"
        with lock:
            p = server["proc"]
            if path == "/stop":
                server["stopped"] = True
                if p.poll() is None:
                    p.terminate()
                    try:
                        p.wait(10)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait()
                _log("flagd stopped (control)")
                return 200, "stopped"
            if path == "/start":
                if p.poll() is None:
                    return 200, "already running"
                try:
                    new, _, _ = start(args.flagd, sources, args.state_dir, args.ready_timeout,
                                      args.extra, procs, fixed_ports=ports)
                except Failed as e:
                    _log(str(e))
                    return 500, str(e)
                server["proc"], server["stopped"] = new, False
                _log("flagd started again (control) on the same ports")
                return 200, "started"
        return 404, f"unknown control path {path}"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            status, text = control(self.path)
            body = (text + "\n").encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    write_env(args.env_file, {
        "FLAGD_HOST": "127.0.0.1",
        "FLAGD_PORT": ev,
        "FLAGD_SYNC_PORT": ports["sync"],
        "FLAGD_OFREP_PORT": ofrep,
        "FLAGD_MANAGEMENT_PORT": ports["management"],
        "FLAGD_URL": f"http://127.0.0.1:{ev}",
        "FLAGD_OFREP_URL": f"http://127.0.0.1:{ofrep}",
        "FLAGD_OVERRIDES_FILE": overrides,
        "FLAGD_CONTROL_URL": f"http://127.0.0.1:{httpd.server_address[1]}",
        "FLAGD_ENV_FILE": os.path.abspath(args.env_file),
        "FLAGD": os.path.abspath(args.flagd),
    })
    ready.append(True)
    _log(f"ready: evaluation {ev}, OFREP {ofrep}, sync {ports['sync']}; env file {args.env_file}")

    # Run until signalled, or until flagd exits without being asked to.
    rc = 0
    while not stopping:
        p = server["proc"]
        if p.poll() is not None and not server["stopped"]:
            with lock:  # not mid-restart
                if server["proc"] is p and not server["stopped"]:
                    rc = p.returncode
                    break
        time.sleep(0.1)
    httpd.shutdown()
    p = server["proc"]
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(10)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass
    if stopping:
        return 0
    _log(f"flagd exited with status {rc}. flagd log:\n{_read(log_path)}")
    return rc if rc > 0 else 1


def main(argv):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)

    c = sub.add_parser("check")
    c.add_argument("--flagd", required=True)
    c.add_argument("--marker", required=True)
    c.add_argument("--strict", action="store_true")
    c.add_argument("--ready-timeout", type=float, default=30.0)
    c.add_argument("files", nargs="+")

    s = sub.add_parser("serve")
    s.add_argument("--flagd", required=True)
    s.add_argument("--env-file", required=True)
    s.add_argument("--state-dir", required=True)
    s.add_argument("--ready-timeout", type=float, default=30.0)
    s.add_argument("--source", action="append", default=[])
    s.add_argument("extra", nargs="*")

    args = p.parse_args(argv)
    if not 0 < args.ready_timeout < float("inf"):
        _log(f"--ready-timeout must be a positive number of seconds, got {args.ready_timeout}")
        return 1
    args.flagd = os.path.abspath(args.flagd)
    return check(args) if args.mode == "check" else serve(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
