# rules_flagd

Bazel rules for flagd (OpenFeature):
- build-time flag checks by flagd itself (`flagd_flags`);
- flag evaluation tests (`flagd_flags_test`);
- a hermetic per-test flagd with runtime overrides (`flagd_server`, `flagd_test`);
- a cluster install over its own manifest (`flagd_manifest`, `flagd_install`).

It mirrors rules_prometheus's structure; see DESIGN.md.

## Commit requirements

- All tests must pass before any commit with code changes: `bazel test //tests/...`. Run the kind smoke `//tests/install_smoke:smoke_test` too when install code changes.
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to reflect any code changes before committing: new rules, changed attributes, new public API surface, behaviour changes.

## Repo layout

```
rules_flagd/
├── MODULE.bazel              # module; toolchain registration; dev deps (itest, kind)
├── defs.bzl                  # public API re-exports
├── extensions.bzl            # `flagd.version()` → flagd_<ver>_<plat> repos (is_root-guarded)
├── private/
│   ├── versions.bzl          # FLAGD_VERSIONS (url / sha256 per platform), FLAGD_IMAGE (by digest)
│   ├── repositories.bzl      # per-platform repo: tarball → flagd_<os>_<arch> linked as `flagd`
│   ├── providers.bzl         # FlagdBinaryInfo, FlagdFlagsInfo
│   ├── flags.bzl             # flagd_flags (+ validation action), flag_sources()
│   ├── launcher.py           # `check` (validation) and `serve` (flagd_server) modes
│   ├── server.bzl            # flagd_server, flagd_health_check, FlagdServerInfo
│   ├── server.sh.tmpl        # runfiles resolution (into variables) → launcher.py serve
│   ├── test.bzl              # flagd_test, flagd_flags_test macros
│   ├── flagd_test_trampoline.sh  # server → env → test (not exec)
│   ├── testlib.sh / testlib.py   # flagd_value/variant/eval/wait_value/set_flag(s)/clear_flags; run-cases
│   ├── run_cases.sh          # flagd_flags_test body
│   ├── install.bzl           # flagd_manifest, flagd_install, flagd_install_health_check
│   ├── manifest.py           # fills manifests/flagd.yaml.tmpl
│   └── manifests/flagd.yaml.tmpl  # ConfigMap + Service + Deployment (no namespace)
├── toolchain/                # toolchain_type, per-platform toolchains, :current
├── tools/update_checksums.sh # binary pins (GitHub asset digests) + image digest; --check
└── tests/
    ├── BUILD.bazel
    ├── analysis_tests.bzl    # providers, executables, bad-attribute failures
    ├── testdata/             # flags (base.json, overrides.yaml, by_env.json), cases, bad files
    ├── api_test.sh           # flagd_test: env, OFREP/Connect/sync/metrics, helpers, overrides
    ├── check_flags_test.sh   # validation: refused / schema strict vs lenient / attribution
    ├── flags_failure_test.sh # wrong expectation: named, want/got, JUnit failure
    ├── server_test.sh        # direct run: extra_args static context, caller FLAGD_* ignored, SIGTERM
    ├── server_failure_test.sh  # bad flag / readiness timeout / flagd_test never runs body
    ├── server_cleanup_test.sh  # flagd stopped when a flagd_test ends
    ├── itest_test.sh         # flagd_server as a rules_itest service
    ├── manifest_test.sh      # keys + --uri order, pinned image, no namespace, hash, replicas
    ├── health_check_test.sh, checksums_test.sh
    └── install_smoke/        # kind + flagd_install(namespace = "features") + port-forward
```

## Key concepts

- **flagd validates.** `launcher.py check` loads each file into its own flagd. `error setting state` means refused; the "does not conform to the schema" warning is a schema violation (fatal with `strict`, the default). Ready means it loaded. It uses loopback ports only.
- **Merge order.** Sources are merged in order and later wins; `deps` come before `srcs`.
- **Ports and environment.** Four free ports. `FLAGD_HOST` / `FLAGD_PORT` are what OpenFeature flagd providers read. The server scrubs `FLAGD_*` from its own environment and sets `HOME` to its state dir.
- **fsnotify.** Sources go through `--sources` with `provider: fsnotify` (about 10 ms reloads). The default `file:` provider polls every 1 s.
- **Overrides.** A last-precedence `overrides.json` is stamped with `rules_flagd_generation`. Helpers poll `GET /v1/flags` on the sync port (it reports `source` and metadata) until it matches. flagd *deletes* a key whose override is removed, so the helpers re-sync that key's configured source. That is why the server loads writable copies of the sources and records `sources.json` at start.
- **Shutdown.** Signal handlers are installed before start. Once flagd is ready, the handler only terminates and arms a kill timer; it must not `wait()`.
- **flagd_test.** The trampoline shifts its 5 arguments and runs (doesn't `exec`) the test. `data` goes on both the inner binary and the `sh_test`, so `args` can use `$(rootpath)`.
- **Install.** The manifest is rules_flagd's own; there's no upstream standalone chart, and the operator needs cert-manager. It has no namespace (`-n` places it), the image is digest-pinned, and a flags hash in the pod template rolls the pods on change.

## Public API

```python
load("@rules_flagd//:defs.bzl",
    "flagd_flags",                 # srcs, deps, strict
    "flagd_flags_test",            # srcs (JSON cases), flags, extra_args
    "flagd_server",                # flags, ready_timeout, extra_args
    "flagd_health_check",          # server
    "flagd_test",                  # srcs, flags, ready_timeout, extra_args, args, env, data, ...
    "flagd_manifest",              # flags, replicas, image
    "flagd_install",               # flags, namespace, replicas, image, wait_timeout
    "flagd_install_health_check",  # namespace
    "FlagdBinaryInfo", "FlagdFlagsInfo", "FlagdServerInfo",
)
```

## Development

```sh
bazel test //tests/...                                  # no container runtime
systemd-run --scope --user --property=Delegate=yes -- \
    bazel test //tests/install_smoke:smoke_test --test_output=streamed   # kind (podman)
tools/update_checksums.sh 0.18.2      # re-pin binaries + image; --check to verify
```

To clean up stray servers, use `pgrep -x flagd_linux_x86` (the process name), never `pkill -f` with a pattern. The pattern matches the shell running it.

### Test results (last full run: 2026-11-04)

All 20 test targets pass on Linux x86_64 (flagd 0.18.2): 19 in `//tests/...` and the kind smoke on rootless podman. Other checks:
- 48 parallel runs of the server tests passed with no stray processes.
- Checked by hand:
  - a bad flag file fails `bazel build`, even with network blocked in the sandbox;
  - `strict = False` only warns;
  - switching the trampoline back to `exec` fails `server_cleanup_test`.
- A scratch consumer module ran `flagd_flags_test` and `flagd_test` and built a manifest.

| Test target | What it verifies | Result |
|---|---|---|
| `//tests:flags_test` | 10 evaluation cases: targeting + `$ref`, merge order, numbers, objects, fractional, DISABLED, FLAG_NOT_FOUND | PASSED |
| `//tests:flags_failure_test` | wrong expectation fails, names the case, want/got, JUnit failure | PASSED |
| `//tests:check_flags_test` | good JSON + YAML; refused (bad default, bad JSON); schema strict vs lenient; bad file named | PASSED |
| `//tests:api_test` | env; helpers; Connect + sync + metrics; set_flag / set_flags / clear_flags restore; wait_value | PASSED |
| `//tests:server_test` | static context via extra_args, caller FLAGD_* ignored, SIGTERM exit 0, all ports closed | PASSED |
| `//tests:server_failure_test` | bad flag, readiness timeout, flagd_test never runs its body | PASSED |
| `//tests:server_cleanup_test` | flagd stopped when a flagd_test ends | PASSED |
| `//tests:itest_test` | flagd_server + health check as an itest_service | PASSED |
| `//tests:manifest_test` | ConfigMap keys + `--uri` order, digest-pinned image, no namespace, flags hash, replicas | PASSED |
| `//tests:health_check_test` | exits non-zero without env file, 0 with | PASSED |
| `//tests:checksums_test` | every pinned URL has a 64-hex SHA-256 | PASSED |
| `//tests:analysis_tests` (8) | providers, source order, executables, bad timeout, empty flags, zero replicas | PASSED |
| `//tests/install_smoke:smoke_test` | kind, namespace `features`: OFREP targeting, merge order, sync, non-root read-only pod | PASSED |

## Known limitations

- `python3` is required on the host: the validation action, the server launcher and the test helpers.
- The validation action starts flagd, so it binds loopback ports in the build sandbox.
- Evaluation test cases and runtime overrides are JSON; flag files may be YAML.
- File sources only; no operator install.
