#!/usr/bin/env bash
# Maintainer-time script: pin the flagd release tarballs and image in
# private/versions.bzl.
#
#   tools/update_checksums.sh <version>   # add / re-pin <version> (and point FLAGD_IMAGE at it)
#   tools/update_checksums.sh --check     # verify every pinned entry and the image
#
# flagd publishes no checksum file. The binary SHA-256s are the GitHub
# release assets' `digest`s, each cross-checked by downloading the tarball
# and hashing it; the image is the ghcr.io multi-arch index digest for
# v<version>. Any mismatch aborts without touching versions.bzl.
set -euo pipefail

cd "$(dirname "$0")/.."
for tool in curl sha256sum python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "update_checksums: needs $tool" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -r -f -- "$work"' EXIT

# platform -> upstream asset suffix
declare -A asset=(
    [linux_amd64]=Linux_x86_64
    [linux_arm64]=Linux_arm64
    [darwin_amd64]=Darwin_x86_64
    [darwin_arm64]=Darwin_arm64
)
plats=(linux_amd64 linux_arm64 darwin_amd64 darwin_arm64)

# Prints "<platform> <url> <sha256>" for each platform of <version>,
# verified against the downloaded tarball.
published() {
    local ver="$1" plat name url sum actual
    # $GITHUB_TOKEN, if set, avoids the API's anonymous rate limit (CI).
    local auth=()
    [[ -z "${GITHUB_TOKEN:-}" ]] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL "${auth[@]}" -o "$work/release.json" \
        "https://api.github.com/repos/open-feature/flagd/releases/tags/flagd/v$ver"
    for plat in "${plats[@]}"; do
        name="flagd_${ver}_${asset[$plat]}.tar.gz"
        url="https://github.com/open-feature/flagd/releases/download/flagd/v$ver/$name"
        sum=$(python3 -I - "$work/release.json" "$name" <<'PY'
import json, sys
release, name = sys.argv[1:]
for a in json.load(open(release))["assets"]:
    if a["name"] == name and (a.get("digest") or "").startswith("sha256:"):
        print(a["digest"][len("sha256:"):])
PY
)
        [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "update_checksums: no digest for $name" >&2; exit 1; }
        curl -fsSL -o "$work/tgz" "$url"
        actual=$(sha256sum "$work/tgz" | awk '{print $1}')
        [[ "$actual" == "$sum" ]] || { echo "update_checksums: $name hashes to $actual, GitHub says $sum" >&2; exit 1; }
        echo "$plat $url $sum"
    done
}

# Prints ghcr.io/open-feature/flagd:v<ver>@sha256:<index digest>.
image() {
    local ver="$1" token digest
    token=$(curl -fsSL "https://ghcr.io/token?scope=repository:open-feature/flagd:pull" |
        python3 -I -c 'import json, sys; print(json.load(sys.stdin)["token"])')
    digest=$(curl -fsSI -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
        "https://ghcr.io/v2/open-feature/flagd/manifests/v$ver" |
        tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "update_checksums: no image digest for v$ver" >&2; exit 1; }
    echo "ghcr.io/open-feature/flagd:v$ver@$digest"
}

if [[ "${1:-}" == "--check" ]]; then
    status=0
    for ver in $(python3 -I -c '
import re, sys
print(" ".join(sorted(set(re.findall(r"^    \"([0-9][^\"]*)\": \{", open(sys.argv[1]).read(), re.M)))))
' private/versions.bzl); do
        while read -r plat url sum; do
            if grep -qF "\"sha256\": \"$sum\"" private/versions.bzl; then
                echo "OK    $ver $plat"
            else
                echo "DRIFT $ver $plat: published $sum" >&2; status=1
            fi
        done < <(published "$ver")
    done
    pinned=$(sed -n 's/^FLAGD_IMAGE = "\(.*\)"$/\1/p' private/versions.bzl)
    tag=${pinned#*:v}; tag=${tag%@*}
    if [[ "$(image "$tag")" == "$pinned" ]]; then
        echo "OK    image $pinned"
    else
        echo "DRIFT image: pinned $pinned, registry has $(image "$tag")" >&2; status=1
    fi
    exit "$status"
fi

ver="${1:?usage: tools/update_checksums.sh <version> | --check}"
published "$ver" > "$work/pins"
img=$(image "$ver")
python3 -I - private/versions.bzl "$ver" "$work/pins" "$img" <<'PY'
import re, sys
path, ver, pins, img = sys.argv[1:]
rows = [l.split() for l in open(pins) if l.strip()]
entry = f'    "{ver}": {{\n'
for plat, url, sha in rows:
    entry += (f'        "{plat}": {{\n'
              f'            "url": "{url}",\n'
              f'            "sha256": "{sha}",\n'
              f'        }},\n')
entry += "    },\n"
text = open(path).read()
pat = re.compile(r'    "' + re.escape(ver) + r'": \{\n.*?\n    \},\n', re.S)
if pat.search(text):
    text = pat.sub(lambda m: entry, text)
else:
    text = text.replace("FLAGD_VERSIONS = {\n", "FLAGD_VERSIONS = {\n" + entry, 1)
text = re.sub(r'^FLAGD_IMAGE = ".*"$', f'FLAGD_IMAGE = "{img}"', text, flags=re.M)
text = re.sub(r"^# The image flagd_install deploys: the v[0-9.]+ multi-arch index\.$",
              f"# The image flagd_install deploys: the v{ver} multi-arch index.", text, flags=re.M)
open(path, "w").write(text)
print(f"pinned {ver} for {len(rows)} platforms and {img} in {path}")
PY
