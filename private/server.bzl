"""flagd_server + flagd_health_check — hermetic flagd test fixtures.

`flagd_server` is a long-running executable (see launcher.py) that
starts one flagd on four free 127.0.0.1 ports with its flag sources plus
a writable overrides source, waits for GET /readyz, then writes
`$TEST_TMPDIR/<name>.env`:

    FLAGD_HOST=127.0.0.1
    FLAGD_PORT                     evaluation (gRPC / Connect) port
    FLAGD_SYNC_PORT                sync port (in-process providers)
    FLAGD_OFREP_PORT / FLAGD_MANAGEMENT_PORT
    FLAGD_URL / FLAGD_OFREP_URL    http://127.0.0.1:<port>
    FLAGD_OVERRIDES_FILE           the overrides source
    FLAGD                          /abs/path/to/flagd

and runs until SIGTERM. `flagd_health_check` exits 0 iff that file
exists; it drops into `itest_service.health_check`.
"""

load(":flags.bzl", "flag_sources")
load(":providers.bzl", "FlagdFlagsInfo")

_TOOLCHAIN = "//toolchain:flagd"

FlagdServerInfo = provider(
    doc = "A flagd_server target.",
    fields = {
        "binary":  "FlagdBinaryInfo: the toolchain's binary.",
        "sources": "list of File: the flag sources, in order.",
    },
)

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def check_timeout(label, value):
    """Validate a timeout attribute: a positive number of seconds."""
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: ready_timeout = {}: expected a positive number of seconds.".format(
            label, repr(value)))
    return raw

def _flagd_server_impl(ctx):
    ft = ctx.toolchains[_TOOLCHAIN].flagd
    sources = flag_sources(ctx.attr.flags)

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__NAME__":          ctx.label.name,
            "__LAUNCHER__":      ctx.file._launcher.short_path,
            "__FLAGD__":         ft.flagd_bin.short_path,
            "__READY_TIMEOUT__": check_timeout(ctx.label, ctx.attr.ready_timeout),
            "__SOURCES__":       "\n".join([
                "src=\"$(resolve {})\"; sources+=(--source \"$src\")".format(_shell_quote(f.short_path))
                for f in sources
            ]),
            "__EXTRA_ARGS__":    " ".join([_shell_quote(a) for a in ctx.attr.extra_args]),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [wrapper, ctx.file._launcher, ft.flagd_bin] + sources)
    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        FlagdServerInfo(binary = ft, sources = sources),
    ]

flagd_server = rule(
    implementation = _flagd_server_impl,
    executable = True,
    doc = """\
Long-running flagd for tests and rules_itest compositions. Writes
`$TEST_TMPDIR/<name>.env` once /readyz answers 200. If flagd refuses its
flags, exits, or isn't ready within `ready_timeout`, it exits non-zero,
naming the cause and printing flagd's log.
""",
    attrs = {
        "flags": attr.label_list(
            providers = [FlagdFlagsInfo],
            doc = "flagd_flags targets, merged in order (later wins). " +
                  "Empty: flagd serves only the runtime overrides.",
        ),
        "ready_timeout": attr.string(
            default = "30",
            doc = "Seconds to wait for /readyz. A positive number.",
        ),
        "extra_args": attr.string_list(
            doc = "Extra `flagd start` flags, e.g. [\"--debug\"] or " +
                  "[\"-X\", \"env=test\"] (a static context value).",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:server.sh.tmpl", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)

# ---- flagd_health_check -----------------------------------------------------

def _flagd_health_check_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {"__ENV_FILE_NAME__": ctx.attr.server.label.name + ".env"},
        is_executable = True,
    )
    return [DefaultInfo(executable = wrapper)]

flagd_health_check = rule(
    implementation = _flagd_health_check_impl,
    executable = True,
    attrs = {
        "server": attr.label(
            mandatory = True,
            providers = [FlagdServerInfo],
            doc = "The flagd_server this check pairs with.",
        ),
        "_tmpl": attr.label(default = "//private:health_check.sh.tmpl", allow_single_file = True),
    },
)
