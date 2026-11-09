#!/usr/bin/env bash
# Consumer check against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do): the
# export-ignore'd directories are absent and @rules_flagd//... loads for a
# consumer module.
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_flagd"
c="$work/consumer"
rm -rf "$work"; mkdir -p "$src" "$c"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in tests; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
touch "$c/BUILD.bazel"
{
    printf 'module(name = "consumer")\nbazel_dep(name = "rules_flagd")\nlocal_path_override(module_name = "rules_flagd", path = "%s")\n' "$src"
    # rules_kubectl isn't in the BCR; rules_*'s own git_override for it
    # applies only when it is the root, so the consumer pins it too.
    kubectl_commit="$(grep -A3 'module_name = "rules_kubectl"' "$src/MODULE.bazel" | sed -n 's/.*commit = "\([0-9a-f]*\)".*/\1/p')"
    if [[ -n "$kubectl_commit" ]]; then
        kubectl_version="$(sed -n 's/^bazel_dep(name = "rules_kubectl", version = "\([^"]*\)".*/\1/p' "$src/MODULE.bazel")"
        printf 'bazel_dep(name = "rules_kubectl", version = "%s")\ngit_override(module_name = "rules_kubectl", remote = "https://github.com/collider-bazel-extensions/rules_kubectl", commit = "%s")\n' "$kubectl_version" "$kubectl_commit"
    fi
} > "$c/MODULE.bazel"
cd "$c"
bazel mod deps >/dev/null
bazel query @rules_flagd//... >/dev/null
echo "PASS: @rules_flagd//... loads from the archive ($(bazel query @rules_flagd//... 2>/dev/null | wc -l) targets)"
