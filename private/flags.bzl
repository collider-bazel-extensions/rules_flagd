"""flagd_flags — flag definitions checked by flagd itself at build time.

Each file is loaded into its own flagd as a validation action, so a file
flagd would refuse (bad JSON/YAML, a defaultVariant that isn't a
variant, ...) fails `bazel build` of anything that depends on it. With
`strict` (the default), so does a file that doesn't conform to the flagd
schema, which flagd itself only logs as a warning and then serves anyway.
"""

load(":providers.bzl", "FlagdFlagsInfo")

_TOOLCHAIN = "//toolchain:flagd"

def flag_sources(targets):
    """FlagdFlagsInfo sources (or plain files) of `targets`, in order,
    without duplicates."""
    out = []
    seen = {}
    for t in targets:
        files = t[FlagdFlagsInfo].sources if FlagdFlagsInfo in t else t[DefaultInfo].files.to_list()
        for f in files:
            if f.path not in seen:
                seen[f.path] = True
                out.append(f)
    return out

def _flagd_flags_impl(ctx):
    flagd = ctx.toolchains[_TOOLCHAIN].flagd.flagd_bin
    sources = flag_sources(ctx.attr.deps)
    seen = {f.path: True for f in sources}
    for f in ctx.files.srcs:
        if f.path not in seen:
            seen[f.path] = True
            sources.append(f)

    outputs = []
    if ctx.files.srcs:
        marker = ctx.actions.declare_file(ctx.label.name + ".checked")
        args = ctx.actions.args()
        args.add(ctx.file._launcher)
        args.add("check")
        args.add("--flagd", flagd)
        args.add("--marker", marker)
        if ctx.attr.strict:
            args.add("--strict")
        args.add_all(ctx.files.srcs)
        ctx.actions.run_shell(
            command = 'exec python3 "$@"',
            arguments = [args],
            inputs = ctx.files.srcs + [flagd, ctx.file._launcher],
            outputs = [marker],
            # python3 from the user's PATH, as for the test-time launcher.
            use_default_shell_env = True,
            mnemonic = "FlagdCheckFlags",
            progress_message = "Checking flagd flags %{label}",
        )
        outputs.append(marker)

    return [
        DefaultInfo(files = depset(sources)),
        FlagdFlagsInfo(sources = sources),
        OutputGroupInfo(_validation = depset(outputs)),
    ]

flagd_flags = rule(
    implementation = _flagd_flags_impl,
    doc = "flagd flag definition files (JSON or YAML), checked by flagd on every build.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".json", ".yaml", ".yml"],
            doc = "Flag files. flagd merges sources in order: a key in a " +
                  "later file replaces the same key from an earlier one.",
        ),
        "deps": attr.label_list(
            providers = [FlagdFlagsInfo],
            doc = "Other flagd_flags, placed before `srcs` (lower precedence).",
        ),
        "strict": attr.bool(
            default = True,
            doc = "Fail on flagd schema violations, not just on flags flagd refuses.",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)
