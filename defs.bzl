"""Public API for rules_flagd.

Flags (build time):
  flagd_flags         — flag definition files, loaded by flagd itself as a
                        validation action on every build.
  flagd_flags_test    — flag evaluation tests (flag + context → expected).

Hermetic server (test-time):
  flagd_server        — long-running flagd; writes $TEST_TMPDIR/<name>.env
                        when /readyz answers.
  flagd_health_check  — pairs with flagd_server for itest_service.
  flagd_test          — sh_test macro: auto-launched flagd with runtime
                        flag overrides.

Cluster install:
  flagd_manifest              — ConfigMap + Deployment + Service for flags.
  flagd_install               — applies it and waits for deploy/flagd.
  flagd_install_health_check  — paired readiness probe.
"""

load("//private:flags.bzl", _flagd_flags = "flagd_flags")
load("//private:install.bzl",
     _flagd_install = "flagd_install",
     _flagd_install_health_check = "flagd_install_health_check",
     _flagd_manifest = "flagd_manifest")
load("//private:providers.bzl",
     _FlagdBinaryInfo = "FlagdBinaryInfo",
     _FlagdFlagsInfo = "FlagdFlagsInfo")
load("//private:server.bzl",
     _FlagdServerInfo = "FlagdServerInfo",
     _flagd_health_check = "flagd_health_check",
     _flagd_server = "flagd_server")
load("//private:test.bzl",
     _flagd_flags_test = "flagd_flags_test",
     _flagd_test = "flagd_test")

flagd_flags = _flagd_flags
flagd_flags_test = _flagd_flags_test
flagd_server = _flagd_server
flagd_health_check = _flagd_health_check
flagd_test = _flagd_test
flagd_manifest = _flagd_manifest
flagd_install = _flagd_install
flagd_install_health_check = _flagd_install_health_check
FlagdBinaryInfo = _FlagdBinaryInfo
FlagdFlagsInfo = _FlagdFlagsInfo
FlagdServerInfo = _FlagdServerInfo
