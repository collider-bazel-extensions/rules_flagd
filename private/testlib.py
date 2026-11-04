#!/usr/bin/env python3
"""Client helpers for rules_flagd tests (behind testlib.sh) and the
flagd_flags_test case runner. Talks to the server in $FLAGD_OFREP_URL /
$FLAGD_SYNC_PORT; standard library only.

  testlib.py eval FLAG [CONTEXT_JSON]       print the OFREP evaluation (JSON)
  testlib.py value FLAG [CONTEXT_JSON]      print the value (strings raw, others JSON);
                                            fails on an evaluation error
  testlib.py variant FLAG [CONTEXT_JSON]    print the variant
  testlib.py wait-value FLAG EXPECTED [CONTEXT_JSON] [TIMEOUT]
                                            wait until `value` prints EXPECTED
  testlib.py set-flags FILE                 replace the runtime overrides with FILE's flags
  testlib.py set-flag KEY FLAG_JSON         add / replace one override
  testlib.py clear-flags                    remove every override
  testlib.py control /stop|/start           stop flagd / start it again (same ports)
  testlib.py run-cases [--junit PATH] [--require-coverage] FILE...
                                            flagd_flags_test: evaluate each case, compare;
                                            with --require-coverage, every configured
                                            flag needs at least one case

Overrides are the server's last flag source (highest precedence). Every
change is tagged with a generation in the source's metadata, and the
set/clear commands return only once flagd serves that generation.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from xml.sax.saxutils import escape, quoteattr

_GEN = "rules_flagd_generation"


def evaluate(flag, context=None):
    """OFREP single-flag evaluation. Returns the response body (a dict
    with value/variant/reason, or errorCode/errorDetails)."""
    url = f"{os.environ['FLAGD_OFREP_URL']}/ofrep/v1/evaluate/flags/{flag}"
    body = json.dumps({"context": context or {}}).encode()
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def _show(value):
    return value if isinstance(value, str) else json.dumps(value, sort_keys=True)


def _context(arg):
    if not arg:
        return {}
    ctx = json.loads(arg)
    if not isinstance(ctx, dict):
        raise SystemExit(f"context must be a JSON object, got {arg!r}")
    return ctx


def _served():
    with urllib.request.urlopen(
            f"http://127.0.0.1:{os.environ['FLAGD_SYNC_PORT']}/v1/flags", timeout=10) as r:
        return json.load(r).get("flags", {})


def _write_overrides(doc, timeout=30.0):
    """Write `doc` as the overrides source (atomically) and wait until flagd
    serves exactly its flags, at its new generation."""
    path = os.environ["FLAGD_OVERRIDES_FILE"]
    with open(path) as f:
        current = json.load(f)
    gen = str(int(current.get("metadata", {}).get(_GEN, "0")) + 1)
    doc = dict(doc)
    doc["metadata"] = dict(doc.get("metadata") or {}, **{_GEN: gen})
    doc.setdefault("flags", {})
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f)
    os.replace(tmp, path)

    want = set(doc["flags"])
    deadline = time.monotonic() + timeout

    def wait(done, what):
        while True:
            flags = _served()
            if done(flags):
                return
            if time.monotonic() >= deadline:
                raise SystemExit(f"flagd did not {what} within {timeout:g}s; "
                                 f"check the flags are valid")
            time.sleep(0.05)

    def loaded(flags):
        mine = {k for k, v in flags.items() if v.get("source") == path}
        return mine == want and all(flags[k].get("metadata", {}).get(_GEN) == gen for k in want)

    wait(loaded, f"load the overrides ({sorted(want)})")

    # flagd drops a key whose override is removed, even if a configured
    # source defines it; re-syncing that source brings its definition back.
    removed = set(current.get("flags", {})) - want
    with open(os.path.join(os.path.dirname(path), "sources.json")) as f:
        defined_in = json.load(f)
    restore = {k: defined_in[k] for k in removed if defined_in.get(k)}
    for src in sorted(set(restore.values())):
        with open(src, "rb") as f:
            body = f.read()
        with open(src + ".tmp", "wb") as f:
            f.write(body)
        os.replace(src + ".tmp", src)
    gone = removed - set(restore)
    wait(lambda flags: all(flags.get(k, {}).get("source") == s for k, s in restore.items())
         and not gone & set(flags),
         f"restore the configured {sorted(restore)}")


def _overrides():
    with open(os.environ["FLAGD_OVERRIDES_FILE"]) as f:
        return json.load(f)


# ---- flagd_flags_test ---------------------------------------------------------

def _compare(case, got):
    """Mismatch messages for the keys present in case["expect"]."""
    problems = []
    expect = case.get("expect", {})
    for key, want in expect.items():
        if key not in ("value", "variant", "reason", "errorCode"):
            problems.append(f"unknown expect key {key!r} (value, variant, reason, errorCode)")
            continue
        have = got.get(key)
        # json.dumps keeps true distinct from 1 and 1.0 distinct from "1".
        if json.dumps(have, sort_keys=True) != json.dumps(want, sort_keys=True):
            problems.append(f"{key}: want {json.dumps(want)}, got {json.dumps(have)}")
    return problems


def configured_flags():
    """Keys from the configured sources (not the overrides), recorded by
    the launcher in sources.json next to the overrides file."""
    path = os.path.join(os.path.dirname(os.environ["FLAGD_OVERRIDES_FILE"]), "sources.json")
    with open(path) as f:
        return sorted(json.load(f))


def run_cases(files, junit=None, require_coverage=False):
    suites = []
    failed = total = 0
    for path in files:
        with open(path) as f:
            doc = json.load(f)
        base = doc.get("context", {})
        cases = doc.get("tests")
        if not isinstance(cases, list) or not cases:
            print(f"{path}: expected a non-empty \"tests\" list", file=sys.stderr)
            return 1
        results = []
        for i, case in enumerate(cases):
            name = case.get("name") or f"{case.get('flag')} #{i + 1}"
            if "flag" not in case or "expect" not in case:
                problems = ["each test needs \"flag\" and \"expect\""]
                got = {}
            else:
                context = dict(base, **case.get("context", {}))
                got = evaluate(case["flag"], context)
                problems = _compare(case, got)
            total += 1
            if problems:
                failed += 1
                print(f"FAIL {os.path.basename(path)}: {name}\n"
                      f"  flag:    {case.get('flag')}\n"
                      f"  context: {json.dumps(dict(base, **case.get('context', {})), sort_keys=True)}\n"
                      + "".join(f"  {p}\n" for p in problems)
                      + f"  flagd:   {json.dumps(got, sort_keys=True)}", file=sys.stderr)
            else:
                print(f"ok   {os.path.basename(path)}: {name}")
            results.append((name, problems))
        suites.append((os.path.basename(path), results))
    if require_coverage:
        tested = {c.get("flag") for path in files for c in json.load(open(path)).get("tests", [])}
        missing = [k for k in configured_flags() if k not in tested]
        total += 1
        if missing:
            failed += 1
            msg = "no case for: " + ", ".join(missing)
            print(f"FAIL coverage: {len(missing)} configured flag(s) untested: {', '.join(missing)}",
                  file=sys.stderr)
        else:
            msg = None
            print("ok   coverage: every configured flag has a case")
        suites.append(("coverage", [("every configured flag has a case", [msg] if msg else [])]))
    if junit:
        _junit(junit, suites)
    print(f"{total - failed}/{total} flag evaluation cases passed")
    return 1 if failed else 0


def _junit(path, suites):
    out = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<testsuites>"]
    for suite, results in suites:
        fails = sum(1 for _, p in results if p)
        out.append(f"  <testsuite name={quoteattr(suite)} tests=\"{len(results)}\" failures=\"{fails}\">")
        for name, problems in results:
            out.append(f"    <testcase name={quoteattr(name)} classname={quoteattr(suite)}>")
            if problems:
                msg = "; ".join(problems)
                out.append(f"      <failure message={quoteattr(msg)}>{escape(msg)}</failure>")
            out.append("    </testcase>")
        out.append("  </testsuite>")
    out.append("</testsuites>")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


# ---- command line ---------------------------------------------------------------

def main(argv):
    cmd, rest = argv[0], argv[1:]
    if cmd == "eval":
        print(json.dumps(evaluate(rest[0], _context(rest[1] if len(rest) > 1 else None))))
    elif cmd in ("value", "variant"):
        got = evaluate(rest[0], _context(rest[1] if len(rest) > 1 else None))
        if "errorCode" in got:
            print(f"flagd_{cmd} {rest[0]}: {got['errorCode']}: {got.get('errorDetails', '')}",
                  file=sys.stderr)
            return 1
        if cmd == "variant" and "variant" not in got:
            print(f"flagd_variant {rest[0]}: no variant (reason {got.get('reason')})", file=sys.stderr)
            return 1
        print(_show(got.get(cmd)))
    elif cmd == "wait-value":
        flag, expected = rest[0], rest[1]
        ctx = _context(rest[2] if len(rest) > 2 else None)
        timeout = float(rest[3]) if len(rest) > 3 else 30.0
        deadline = time.monotonic() + timeout
        while True:
            got = evaluate(flag, ctx)
            if "errorCode" not in got and _show(got.get("value")) == expected:
                return 0
            if time.monotonic() >= deadline:
                print(f"flagd_wait_value: {flag} is not {expected} after {timeout:g}s: "
                      f"{json.dumps(got)}", file=sys.stderr)
                return 1
            time.sleep(0.1)
    elif cmd == "set-flags":
        with open(rest[0]) as f:
            doc = json.load(f)
        new = {"flags": doc.get("flags", {})}
        if "$evaluators" in doc:
            new["$evaluators"] = doc["$evaluators"]
        _write_overrides(new)
    elif cmd == "set-flag":
        doc = _overrides()
        flags = dict(doc.get("flags", {}))
        flags[rest[0]] = json.loads(rest[1])
        doc["flags"] = flags
        _write_overrides(doc)
    elif cmd == "clear-flags":
        _write_overrides({"flags": {}})
    elif cmd == "control":
        url = os.environ["FLAGD_CONTROL_URL"] + rest[0]
        req = urllib.request.Request(url, data=b"", method="POST")
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                r.read()
        except urllib.error.HTTPError as e:
            print(f"flagd{rest[0].replace('/', '_')}: {e.code}: {e.read().decode().strip()}",
                  file=sys.stderr)
            return 1
    elif cmd == "run-cases":
        junit, coverage = None, False
        while rest and rest[0] in ("--junit", "--require-coverage"):
            if rest[0] == "--junit":
                junit, rest = rest[1], rest[2:]
            else:
                coverage, rest = True, rest[1:]
        return run_cases(rest, junit or None, coverage)
    else:
        print(f"testlib.py: unknown command {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
