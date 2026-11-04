#!/usr/bin/env bash
# flagd_flags' validation action (launcher.py check): accepts good files
# (JSON and YAML); rejects files flagd refuses whatever `strict` says;
# rejects schema violations only with --strict.
#
# Argv: <launcher.py> <flagd> <base.json> <overrides.yaml> <bad_state> <bad_default>
#       <bad_syntax> <bad_targeting> <bad_mixed_variants>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
r() {
  local c
  for c in "$TEST_SRCDIR/_main/$1" "$TEST_SRCDIR/${1#../}"; do
    [[ -e "$c" ]] && { printf '%s\n' "$c"; return; }
  done
  fail "not in runfiles: $1"
}
LAUNCHER="$(r "$1")"; FLAGD="$(r "$2")"; shift 2
GOOD_JSON="$(r "$1")"; GOOD_YAML="$(r "$2")"; BAD_STATE="$(r "$3")"; BAD_DEFAULT="$(r "$4")"
BAD_SYNTAX="$(r "$5")"; BAD_TARGETING="$(r "$6")"; BAD_MIXED="$(r "$7")"
m="$TEST_TMPDIR/marker"
check() { rm -f "$m"; python3 "$LAUNCHER" check --flagd "$FLAGD" --marker "$m" "$@"; }

check --strict "$GOOD_JSON" "$GOOD_YAML" || fail "good files rejected"
[[ -f "$m" ]] || fail "no marker for good files"
echo "ok: good JSON + YAML"

if out=$(check "$BAD_DEFAULT" 2>&1); then fail "bad defaultVariant accepted"; fi
grep -q "bad_default.json: flagd refused the flags" <<<"$out" || fail "refusal not attributed: $out"
grep -q "default variant: 'nope' isn't a valid variant of flag: 'x'" <<<"$out" || fail "cause not shown: $out"
[[ ! -f "$m" ]] || fail "marker written for a bad file"
echo "ok: refused without --strict too (bad defaultVariant)"

if out=$(check "$BAD_SYNTAX" 2>&1); then fail "bad JSON accepted"; fi
grep -q "unexpected EOF" <<<"$out" || fail "JSON error not shown: $out"
echo "ok: bad JSON"

if out=$(check --strict "$BAD_STATE" 2>&1); then fail "schema violation accepted with --strict"; fi
grep -q "does not conform to the flagd schema (error)" <<<"$out" || fail "schema error not reported: $out"
grep -q "/flags/x/state': value must be one of 'ENABLED', 'DISABLED'" <<<"$out" || fail "schema detail missing: $out"
# The cause comes first; the other alternatives' type mismatches only in the full report.
summary=$(sed '/full report:/q' <<<"$out")
[[ "$(sed -n 2p <<<"$summary")" == "  at '/flags/x/state': value must be one of 'ENABLED', 'DISABLED'" ]] \
  || fail "cause not first: $out"
grep -q "want number" <<<"$summary" && fail "branch noise in the summary: $summary"
grep -q "want number" <<<"$out" || fail "full report dropped"
if out=$(check --strict "$BAD_MIXED" 2>&1); then fail "mixed variant types accepted with --strict"; fi
summary=$(sed '/full report:/q' <<<"$out")
grep -q "at '/flags/x/variants/off': got string, want boolean" <<<"$summary" || fail "mixed: $out"
grep -q "at '/flags/x/variants/on': got boolean, want string" <<<"$summary" || fail "mixed: $out"
if out=$(check --strict "$BAD_TARGETING" 2>&1); then fail "unknown targeting operator accepted with --strict"; fi
grep -q "/flags/x/targeting" <<<"$out" || fail "targeting violation not shown: $out"
echo "ok: schema violations fail with --strict"

out=$(check "$BAD_STATE" 2>&1) || fail "schema violation fatal without --strict: $out"
grep -q "does not conform to the flagd schema (warning)" <<<"$out" || fail "no warning without --strict: $out"
[[ -f "$m" ]] || fail "no marker without --strict"
echo "ok: schema violations only warn without --strict"

# One bad file among good ones fails the check and names the bad one.
if out=$(check --strict "$GOOD_JSON" "$BAD_DEFAULT" 2>&1); then fail "mixed set accepted"; fi
grep -q "bad_default.json" <<<"$out" || fail "bad file not named: $out"
grep -q "base.json" <<<"$out" && fail "good file blamed: $out"
echo "PASS"
