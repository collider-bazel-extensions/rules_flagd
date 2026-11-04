"""Per-platform flagd repo: downloads the release tarball at the pinned
sha, exposes its binary (`flagd_<os>_<arch>` upstream) as `flagd`, and
declares the platform's toolchain implementation, so the repo name
(`flagd_<platform>`) doesn't change with the version.
"""

load(":versions.bzl", "FLAGD_IMAGES", "FLAGD_VERSIONS")

_BUILD = """\
load("{toolchain_bzl}", "flagd_toolchain")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "flagd_bin",
    srcs = ["flagd"],
)

flagd_toolchain(
    name = "toolchain_impl",
    version = "{version}",
    image = "{image}",
    flagd_bin = ":flagd_bin",
)
"""

def _impl(rctx):
    version = rctx.attr.version
    platform = rctx.attr.platform

    if version not in FLAGD_VERSIONS:
        fail("rules_flagd: unknown flagd version '{}'. Known: {} ".format(
            version,
            sorted(FLAGD_VERSIONS.keys()),
        ) + "(add one with tools/update_checksums.sh <version>)")
    if version not in FLAGD_IMAGES:
        fail("rules_flagd: no pinned image for flagd {} (tools/update_checksums.sh {})".format(version, version))
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
    rctx.file("BUILD.bazel", _BUILD.format(
        toolchain_bzl = str(Label("//toolchain:toolchain.bzl")),
        version = version,
        image = FLAGD_IMAGES[version],
    ))

flagd_binary_repo = repository_rule(
    implementation = _impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)
