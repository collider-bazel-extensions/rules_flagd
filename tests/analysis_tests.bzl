"""Analysis-time tests: install macros, flagd_server / flagd_flags
providers, and the analysis errors for bad attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@rules_flagd//:defs.bzl",
    "FlagdFlagsInfo",
    "FlagdServerInfo",
    "flagd_health_check",
    "flagd_install",
    "flagd_install_health_check",
    "flagd_manifest",
    "flagd_server",
)

def _has_executable_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, target[DefaultInfo].files_to_run.executable != None,
                 "expected target to expose an executable")
    return analysistest.end(env)

_has_executable_test = analysistest.make(_has_executable_impl)

def _server_info_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlagdServerInfo]
    asserts.equals(env, "0.18.2", info.binary.version)
    asserts.equals(env, ["base.json", "overrides.yaml"], [f.basename for f in info.sources])
    return analysistest.end(env)

_server_info_test = analysistest.make(_server_info_impl)

def _flags_order_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlagdFlagsInfo]
    asserts.equals(env, ["base.json", "overrides.yaml"], [f.basename for f in info.sources])
    return analysistest.end(env)

_flags_order_test = analysistest.make(_flags_order_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def analysis_test_suite(name):
    flagd_server(
        name = name + "_server_subject",
        flags = ["//tests/testdata:flags"],
        tags = ["manual"],
    )
    flagd_health_check(name = name + "_health_subject", server = ":" + name + "_server_subject", tags = ["manual"])
    flagd_install(name = name + "_install_subject", flags = ["//tests/testdata:flags"], tags = ["manual"])
    flagd_install_health_check(name = name + "_install_health_subject", tags = ["manual"])
    flagd_server(name = name + "_bad_timeout_subject", ready_timeout = "soon", tags = ["manual"])
    flagd_health_check(
        name = name + "_bad_instance_subject",
        instance = "b/../x",
        server = ":" + name + "_server_subject",
        tags = ["manual"],
    )
    flagd_manifest(name = name + "_no_flags_subject", flags = [], tags = ["manual"])
    flagd_manifest(name = name + "_zero_replicas_subject", flags = ["//tests/testdata:base"],
                   replicas = 0, tags = ["manual"])

    tests = {
        "_info": (_server_info_test, ":" + name + "_server_subject", None),
        "_flags_order": (_flags_order_test, "//tests/testdata:flags", None),
        "_health_executable": (_has_executable_test, ":" + name + "_health_subject", None),
        "_install_executable": (_has_executable_test, ":" + name + "_install_subject", None),
        "_install_health_executable": (_has_executable_test, ":" + name + "_install_health_subject", None),
        "_timeout": (_fails_test, ":" + name + "_bad_timeout_subject", "expected a positive number of seconds"),
        "_instance": (_fails_test, ":" + name + "_bad_instance_subject", "use letters, digits, _ and -"),
        "_no_flags": (_fails_test, ":" + name + "_no_flags_subject", "needs at least one flag file"),
        "_replicas": (_fails_test, ":" + name + "_zero_replicas_subject", "must be at least 1"),
    }
    for suffix, (rule, target, message) in tests.items():
        if message:
            rule(name = name + suffix, target_under_test = target, message = message)
        else:
            rule(name = name + suffix, target_under_test = target)
    native.test_suite(name = name, tests = [":" + name + s for s in tests])
