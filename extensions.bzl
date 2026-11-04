"""Bzlmod extension. Single `version` tag — fetches the upstream flagd
release tarball for each supported platform as `flagd_<platform>`.

The root module's tag wins; without one, rules_flagd's own applies, so
consumers declare nothing unless they want another pinned version
(`flagd.version(version = "0.17.1")`). The toolchain, and the image
flagd_install deploys, follow the selected version.

`v01_repo_names = True` also creates rules_flagd v0.1's repo names,
`flagd_<ver>_<plat>`, for a MODULE.bazel that still `use_repo`s them.
Off by default (v0.3.0+): every created repo is recorded in consumers'
MODULE.bazel.lock.
"""

load("//private:repositories.bzl", "flagd_binary_repo")
load("//private:versions.bzl", "DEFAULT_VERSION", "PLATFORMS")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),  # e.g. "0.18.2"
    "v01_repo_names": attr.bool(
        default = False,
        doc = "Also create v0.1's flagd_<ver>_<plat> repo names.",
    ),
})

def _impl(mctx):
    root, own, v01_names = [], [], False
    for mod in mctx.modules:
        if mod.is_root:
            root += [t.version for t in mod.tags.version]
            v01_names = v01_names or any([t.v01_repo_names for t in mod.tags.version])
        elif mod.name == "rules_flagd":
            own += [t.version for t in mod.tags.version]

    # Only one module's tags apply (the same is_root rule as across this
    # organization): repos are named per platform, not per version.
    versions = root or own or [DEFAULT_VERSION]
    if len({v: True for v in versions}) > 1:
        fail("rules_flagd: flagd.version() named more than one version: {}".format(versions))
    version = versions[0]
    for plat in PLATFORMS.keys():
        flagd_binary_repo(
            name = "flagd_" + plat,
            version = version,
            platform = plat,
        )

        # v0.1 names, on request, so a consumer's existing use_repo(flagd,
        # "flagd_<ver>_<plat>") keeps working.
        if not v01_names:
            continue
        flagd_binary_repo(
            name = "flagd_{}_{}".format(version.replace(".", "_"), plat),
            version = version,
            platform = plat,
        )

flagd = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
