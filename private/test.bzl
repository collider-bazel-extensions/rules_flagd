"""flagd_test and flagd_flags_test — sh_test macros with an auto-launched
flagd.

Each target gets its own flagd_server (own ports, own overrides source),
so tests are safe under `--jobs=N`.

The trampoline (flagd_test_trampoline.sh) starts the server, waits for
its env file, sources it (FLAGD_HOST, FLAGD_PORT, FLAGD_SYNC_PORT,
FLAGD_OFREP_PORT, FLAGD_MANAGEMENT_PORT, FLAGD_URL, FLAGD_OFREP_URL,
FLAGD_OVERRIDES_FILE, FLAGD), exports FLAGD_TESTLIB, and runs the test
with the target's args. It runs the test rather than exec'ing it, so it
can stop flagd when the test ends.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":server.bzl", "flagd_server")

def flagd_test(
        name,
        srcs,
        flags = None,
        ready_timeout = 30,
        extra_args = None,
        deps = None,
        data = None,
        args = None,
        size = "small",
        timeout = None,
        tags = None,
        **kwargs):
    """sh_test against an auto-launched flagd.

    Args:
      name: target name.
      srcs: the test script (one file).
      flags: flagd_flags targets the server loads, merged in order.
      ready_timeout: seconds to wait for flagd's /readyz.
      extra_args: extra `flagd start` flags.
      deps: forwarded to the inner sh_binary.
      data: runfiles for the test (on the inner sh_binary and the
        sh_test, so `args` may use $(rootpath) on them).
      args: arguments for the test script.
      size: sh_test size. Default "small".
      timeout: sh_test timeout.
      tags: tags for the sh_test (helper targets also get "manual").
      **kwargs: forwarded to sh_test (env, env_inherit, flaky, ...).
    """
    tags = tags or []
    server_name = name + "_flagd"
    flagd_server(
        name = server_name,
        flags = flags or [],
        ready_timeout = str(ready_timeout),
        extra_args = extra_args or [],
        tags = tags + ["manual"],
        testonly = True,
    )

    inner_name = name + "_inner"
    sh_binary(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        data = data,
        tags = tags + ["manual"],
        testonly = True,
    )

    sh_test(
        name = name,
        srcs = [Label("//private:flagd_test_trampoline.sh")],
        args = [
            "$(rootpath :{})".format(server_name),
            "$(rootpath :{})".format(inner_name),
            server_name,
            "$(rootpath {})".format(Label("//private:testlib.sh")),
            "$(rootpath {})".format(Label("//private:testlib.py")),
        ] + (args or []),
        # `data` here too, so `args` can use $(rootpath) on it.
        data = [
            ":" + server_name,
            ":" + inner_name,
            Label("//private:testlib.sh"),
            Label("//private:testlib.py"),
        ] + (data or []),
        size = size,
        timeout = timeout,
        tags = tags,
        **kwargs
    )

def flagd_flags_test(
        name,
        srcs,
        flags,
        require_coverage = False,
        extra_args = None,
        tags = None,
        **kwargs):
    """Flag evaluation tests: each case evaluates one flag with a context
    against a flagd serving `flags`, and checks the result. Results go to
    Bazel as JUnit XML (one testcase per case).

    A test file is JSON:

        {
          "context": {"region": "eu"},          # optional, merged into every case
          "tests": [
            {
              "name": "example.com users get the new checkout",
              "flag": "new-checkout",
              "context": {"email": "a@example.com"},
              "expect": {"value": true, "variant": "on", "reason": "TARGETING_MATCH"}
            }
          ]
        }

    `expect` checks only the keys it has: value, variant, reason,
    errorCode (e.g. "FLAG_NOT_FOUND").

    Args:
      name: target name.
      srcs: JSON test files.
      flags: flagd_flags targets under test, merged in order.
      require_coverage: fail unless every flag defined in `flags` has at
        least one case (a JUnit "coverage" case names the untested ones).
      extra_args: extra `flagd start` flags (e.g. ["-X", "env=prod"]).
      tags: sh_test tags.
      **kwargs: forwarded to flagd_test (size, timeout, ...).
    """
    flagd_test(
        name = name,
        srcs = [Label("//private:run_cases.sh")],
        flags = flags,
        extra_args = extra_args,
        data = srcs,
        args = (["--require-coverage"] if require_coverage else []) +
               ["$(rootpaths {})".format(s) for s in srcs],
        tags = tags,
        **kwargs
    )
