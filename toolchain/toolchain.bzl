"""flagd_toolchain — exposes the platform-resolved `flagd` binary as a
`ToolchainInfo`, so rules resolve it via
`ctx.toolchains["@rules_flagd//toolchain:flagd"]`.

`current_flagd_toolchain` forwards the resolved binary as a plain target
(files + runfiles) for `data = [...]` use in tests.
"""

load("//private:providers.bzl", "FlagdBinaryInfo")

FLAGD_TOOLCHAIN_TYPE = Label("//toolchain:flagd")

def _toolchain_impl(ctx):
    info = FlagdBinaryInfo(
        version   = ctx.attr.version,
        flagd_bin = ctx.file.flagd_bin,
    )
    return [
        platform_common.ToolchainInfo(flagd = info),
        DefaultInfo(
            files = depset([ctx.file.flagd_bin]),
            runfiles = ctx.runfiles(files = [ctx.file.flagd_bin]),
        ),
    ]

flagd_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version":   attr.string(mandatory = True),
        "flagd_bin": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _current_impl(ctx):
    info = ctx.toolchains[FLAGD_TOOLCHAIN_TYPE].flagd
    return [
        info,
        DefaultInfo(
            files = depset([info.flagd_bin]),
            runfiles = ctx.runfiles(files = [info.flagd_bin]),
        ),
    ]

current_flagd_toolchain = rule(
    implementation = _current_impl,
    toolchains = [FLAGD_TOOLCHAIN_TYPE],
    doc = "The resolved flagd binary, as files and runfiles.",
)
