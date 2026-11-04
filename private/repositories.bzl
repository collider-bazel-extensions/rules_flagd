"""Per-platform flagd repo: downloads the release tarball at the pinned
sha and exposes its binary (`flagd_<os>_<arch>` upstream) as `flagd`.
"""

load(":versions.bzl", "FLAGD_VERSIONS")

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "flagd_bin",
    srcs = ["flagd"],
)
"""

def _impl(rctx):
    version = rctx.attr.version
    platform = rctx.attr.platform

    if version not in FLAGD_VERSIONS:
        fail("rules_flagd: unknown flagd version '{}'. Known: {}".format(
            version, sorted(FLAGD_VERSIONS.keys()),
        ))
    pin = FLAGD_VERSIONS[version].get(platform)
    if not pin:
        fail("rules_flagd: platform '{}' missing for version {}".format(platform, version))

    rctx.download_and_extract(url = pin["url"], sha256 = pin["sha256"], output = "dist")
    bins = [p for p in rctx.path("dist").readdir()
            if p.basename.startswith("flagd_") and "." not in p.basename]
    if len(bins) != 1:
        fail("rules_flagd: expected one flagd_<os>_<arch> binary in {}, found {}".format(
            pin["url"], [p.basename for p in rctx.path("dist").readdir()]))
    rctx.symlink(bins[0], "flagd")
    rctx.file("WORKSPACE", "workspace(name = \"{}\")\n".format(rctx.name))
    rctx.file("BUILD.bazel", _BUILD)

flagd_binary_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)
