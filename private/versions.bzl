"""flagd pins.

Binaries: one upstream tarball per platform, holding a single binary
named `flagd_<os>_<arch>` (the repository rule links it as `flagd`):

    https://github.com/open-feature/flagd/releases/download/flagd/v<ver>/flagd_<ver>_<OS>_<arch>.tar.gz

flagd publishes no checksum file; the SHA-256s are the GitHub release
assets' `digest`s, each cross-checked against a download.

Image (flagd_install): the multi-arch image index, pinned by digest.

Maintainer flow:

    tools/update_checksums.sh <ver>     # add / re-pin <ver> (binaries + image)
    tools/update_checksums.sh --check   # verify every pin, no writes

//tests:checksums_test fails on an empty or malformed value.
"""

FLAGD_VERSIONS = {
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

# The image flagd_install deploys: the v0.18.2 multi-arch index.
FLAGD_IMAGE = "ghcr.io/open-feature/flagd:v0.18.2@sha256:a1b6de22ef4f8a4f10af2f9d0009ccef946d707d4211db342f0f2422778b764a"

PLATFORMS = {
    "linux_amd64":  ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64":  ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:osx",   "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:osx",   "@platforms//cpu:arm64"],
}
