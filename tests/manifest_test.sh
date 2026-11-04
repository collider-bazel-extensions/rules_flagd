#!/usr/bin/env bash
# flagd_manifest: a ConfigMap key per flag file in source order, matching
# --uri args, the selected version's image by digest, no namespace, and a flags hash
# that changes with the flags.
#
# Argv: <manifest for :flags> <manifest for :base> <versions.bzl>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
M="$TEST_SRCDIR/_main/$1"; BASE="$TEST_SRCDIR/_main/$2"; V="$TEST_SRCDIR/_main/$3"

[[ $(grep -c '^kind: ' "$M") -eq 3 ]] || fail "want ConfigMap + Service + Deployment"
grep -q '^  00-base.json: |$' "$M" || fail "base.json key"
grep -q '^  01-overrides.yaml: |$' "$M" || fail "overrides.yaml key"
grep -q '^    flags:$' "$M" || fail "YAML body not indented under its key"
grep -q '^        "new-checkout": {$' "$M" || fail "JSON body not indented under its key"
# Sources in order: base first (lower precedence), overrides last.
args=$(grep -A1 -- '- --uri' "$M" | grep 'file:' | sed 's/.*file://')
[[ "$args" == $'/etc/flagd/00-base.json\n/etc/flagd/01-overrides.yaml' ]] || fail "uri args: $args"

# The image of the version the toolchain resolved (DEFAULT_VERSION here).
default=$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"$/\1/p' "$V")
image=$(sed -n "s/^    \"$default\": \"\(ghcr[^\"]*\)\",\$/\1/p" "$V")
[[ "$image" == "ghcr.io/open-feature/flagd:v$default@sha256:"* ]] || fail "no digest-pinned image for $default: $image"
grep -q "image: $image\$" "$M" || fail "manifest image is not FLAGD_IMAGES[$default]"
grep -q '^  namespace:' "$M" && fail "manifest pins a namespace"

h1=$(sed -n 's/.*rules-flagd\/flags-sha256: "\(.*\)"/\1/p' "$M")
h2=$(sed -n 's/.*rules-flagd\/flags-sha256: "\(.*\)"/\1/p' "$BASE")
[[ "$h1" =~ ^[0-9a-f]{64}$ && "$h2" =~ ^[0-9a-f]{64}$ ]] || fail "flags hash missing"
[[ "$h1" != "$h2" ]] || fail "flags hash does not change with the flags"
grep -q 'replicas: 2$' "$BASE" || fail "replicas not applied"
echo "PASS"
