"""flagd pins.

Binaries: one upstream tarball per platform, holding a single binary
named `flagd_<os>_<arch>` (the repository rule links it as `flagd`):

    https://github.com/open-feature/flagd/releases/download/flagd/v<ver>/flagd_<ver>_<OS>_<arch>.tar.gz

flagd publishes no checksum file; the SHA-256s are the GitHub release
assets' `digest`s, each cross-checked against a download.

Images (flagd_install): each version's multi-arch image index, pinned by
digest in FLAGD_IMAGES. The install deploys the image of the version the
toolchain resolved, so the deployed flagd and the test binary match.

Maintainer flow:

    tools/update_checksums.sh <ver>     # add / re-pin <ver> (binaries + image)
    (then DEFAULT_VERSION / MODULE.bazel's flagd.version() if it is the new default)
    tools/update_checksums.sh --check   # verify every pin, no writes

//tests:checksums_test fails on an empty or malformed value.
"""

# The version the `flagd` extension fetches when the root module names none.
DEFAULT_VERSION = "0.18.2"

FLAGD_VERSIONS = {
    "0.17.1": {
        "linux_amd64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.17.1/flagd_0.17.1_Linux_x86_64.tar.gz",
            "sha256": "8f74d2b1a86c3a91fe1f482134a776f06beaec74031575a2660effc1cb76ff9d",
        },
        "linux_arm64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.17.1/flagd_0.17.1_Linux_arm64.tar.gz",
            "sha256": "bd825d598bfad67185b71310c11b716675b01640af7e561e7fbdf89183a805b0",
        },
        "darwin_amd64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.17.1/flagd_0.17.1_Darwin_x86_64.tar.gz",
            "sha256": "e6d71c55e748e41b676b630bd056c6269ce8a4f10666d015508514341233bca3",
        },
        "darwin_arm64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.17.1/flagd_0.17.1_Darwin_arm64.tar.gz",
            "sha256": "0fbbc41bfc44e1f89e48ef9a94bde148bf0e357a355278ca09aaf99558c03ffa",
        },
    },
    "0.18.2": {
        "linux_amd64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.18.2/flagd_0.18.2_Linux_x86_64.tar.gz",
            "sha256": "855658f4863dff09e436cbbc6153a5e3798b9a40379a1e13917b9c847a2bfaea",
        },
        "linux_arm64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.18.2/flagd_0.18.2_Linux_arm64.tar.gz",
            "sha256": "3b202d0c3be857e2b0215778085d8b233b59cfb7c52dbb6392464dfc16a18cb7",
        },
        "darwin_amd64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.18.2/flagd_0.18.2_Darwin_x86_64.tar.gz",
            "sha256": "03de02ffcce989a3905d97cd244cee438c5407655f3919416018ce59e5499b44",
        },
        "darwin_arm64": {
            "url": "https://github.com/open-feature/flagd/releases/download/flagd/v0.18.2/flagd_0.18.2_Darwin_arm64.tar.gz",
            "sha256": "01d13c516f866d68564316de568f4fba3a24cfa0a5e9062cf9738a459c119ec2",
        },
    },
}

# The image flagd_install deploys for each version: its multi-arch index.
FLAGD_IMAGES = {
    "0.17.1": "ghcr.io/open-feature/flagd:v0.17.1@sha256:594f980857ce608e0d6c2b2848f6d0f26b5f5a7e8429aa379defb0eb69e23fd0",
    "0.18.2": "ghcr.io/open-feature/flagd:v0.18.2@sha256:a1b6de22ef4f8a4f10af2f9d0009ccef946d707d4211db342f0f2422778b764a",
}

PLATFORMS = {
    "linux_amd64":  ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64":  ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:osx",   "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:osx",   "@platforms//cpu:arm64"],
}
