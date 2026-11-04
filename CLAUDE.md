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
├── extensions.bzl            # `flagd.version()` → flagd_<plat> repos (root tag, else ours) + v0.1 names
├── private/
│   ├── versions.bzl          # DEFAULT_VERSION, FLAGD_VERSIONS (url / sha256), FLAGD_IMAGES (by digest)
│   ├── repositories.bzl      # per-platform repo: tarball → `flagd` + its flagd_toolchain (version, image)
│   ├── providers.bzl         # FlagdBinaryInfo, FlagdFlagsInfo
│   ├── flags.bzl             # flagd_flags (+ validation action), flag_sources()
│   ├── launcher.py           # `check` (validation; schema_causes) and `serve` (control endpoint) modes
│   ├── server.bzl            # flagd_server, flagd_health_check, FlagdServerInfo
│   ├── server.sh.tmpl        # runfiles resolution (into variables) → launcher.py serve
│   ├── test.bzl              # flagd_test, flagd_flags_test macros
│   ├── flagd_test_trampoline.sh  # server → env → test (not exec)
│   ├── testlib.sh / testlib.py   # value/variant/eval/wait_value/set_flag(s)/clear_flags, stop/start,
│   │                             # start_instance/use/on; run-cases (+ coverage)
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
    ├── coverage_failure_test.sh  # require_coverage names the untested flags
    ├── replicas_test.sh      # flagd_stop/start (same ports, overrides kept), a second replica
    ├── restart_failure_test.sh  # restart with a held port: 500 naming it; brief hold retried
    ├── readme_version_test.sh   # README install snippet = MODULE.bazel version
    ├── server_test.sh        # direct run: extra_args static context, caller FLAGD_* ignored, SIGTERM
    ├── server_failure_test.sh  # bad flag / readiness timeout / flagd_test never runs body
    ├── server_cleanup_test.sh  # flagd stopped when a flagd_test ends
    ├── itest_test.sh         # flagd_server as two rules_itest services (FLAGD_INSTANCE=b)
    ├── manifest_test.sh      # keys + --uri order, pinned image, no namespace, hash, replicas
    ├── health_check_test.sh, checksums_test.sh
    ├── install_smoke/        # kind + flagd_install(namespace = "features") + port-forward
    └── version_select/       # separate consumer pinning 0.17.1 (binary + image) with v01_repo_names (CI)
```

## Key concepts

- **flagd validates.** `launcher.py check` loads each file into its own flagd. `error setting state` means refused; the "does not conform to the schema" warning is a schema violation (fatal with `strict`, the default). Ready means it loaded. It uses loopback ports only.
- **Versions.** `flagd_<plat>` repos at the root's `flagd.version()` (else ours); 0.18.2 (default) and 0.17.1. v0.1's `flagd_<ver>_<plat>` names only with `v01_repo_names = True`. The toolchain carries the version's image, which `flagd_manifest` deploys by default.
- **Schema report.** `schema_causes` prints the errors shared by every alternative of an `anyOf`/`oneOf` first (else the deepest, fewest-error branches), then the full tree.
- **Merge order.** Sources are merged in order and later wins; `deps` come before `srcs`.
- **Ports and environment.** Four free ports. `FLAGD_HOST` / `FLAGD_PORT` are what OpenFeature flagd providers read. The server scrubs `FLAGD_*` from its own environment and sets `HOME` to its state dir.
- **fsnotify.** Sources go through `--sources` with `provider: fsnotify` (about 10 ms reloads). The default `file:` provider polls every 1 s.
- **Overrides.** A last-precedence `overrides.json` is stamped with `rules_flagd_generation`. Helpers poll `GET /v1/flags` on the sync port (it reports `source` and metadata) until it matches. flagd *deletes* a key whose override is removed, so the helpers re-sync that key's configured source. That is why the server loads writable copies of the sources and records `sources.json` at start.
- **Restart / replicas.** Control endpoint `POST /stop|/start`: same ports, sources and overrides; a requested stop isn't a crash. Ports are bind-checked before every start (flagd drains 5 s before exiting on a bind failure); a restart retries 5 × 0.2 s, then 500 naming the port. Ready = `/readyz` + every port answering HTTP. `FLAGD_INSTANCE=<id>` → `<name>@<id>.env`, own ports and state; `flagd_start_instance` pids go to `$FLAGD_INSTANCE_PIDS` and the trampoline stops them.
- **Shutdown.** Signal handlers are installed before start. Once flagd is ready, the handler only terminates and arms a kill timer; it must not `wait()`.
- **flagd_test.** The trampoline shifts its 5 arguments and runs (doesn't `exec`) the test. `data` goes on both the inner binary and the `sh_test`, so `args` can use `$(rootpath)`.
- **Install.** The manifest is rules_flagd's own; there's no upstream standalone chart, and the operator needs cert-manager. It has no namespace (`-n` places it), the image is digest-pinned, and a flags hash in the pod template rolls the pods on change.

## Public API

```python
load("@rules_flagd//:defs.bzl",
    "flagd_flags",                 # srcs, deps, strict
    "flagd_flags_test",            # srcs (JSON cases), flags, require_coverage, extra_args
    "flagd_server",                # flags, ready_timeout, extra_args
    "flagd_health_check",          # server, instance
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
(cd tests/version_select && bazel test //...)   # consumer pinning 0.17.1
```

To clean up stray servers, use `pgrep -x flagd_linux_x86` (the process name), never `pkill -f` with a pattern. The pattern matches the shell running it.

### Test results (last full run: 2026-11-04)

All 24 test targets in `//tests/...` pass on Linux x86_64 (flagd 0.18.2), 9 of them analysis tests; the kind smoke last ran (v0.2.0) on rootless podman and runs in CI. Other checks:
- `tests/version_select` (a consumer pinning 0.17.1) gets the 0.17.1 binary and image, and with `v01_repo_names = True` a v0.1 repo name; CI runs it. Without the opt-in, a v0.1-style `use_repo` fails with "does not generate repository" (checked by hand).
- 8 runs each of the server tests in parallel, the restart, restart-failure and replica tests included, passed with no stray processes.
- `tools/update_checksums.sh --check` verifies every pin, both images included.
- Checked by hand:
  - a bad flag file fails `bazel build`, even with network blocked in the sandbox;
  - `strict = False` only warns;
  - switching the trampoline back to `exec` fails `server_cleanup_test`, for the server and a replica.
- A scratch consumer module ran `flagd_flags_test` and `flagd_test` and built a manifest (v0.1).

| Test target | What it verifies | Result |
|---|---|---|
| `//tests:flags_test` | 10 evaluation cases (targeting + `$ref`, merge order, numbers, objects, fractional, DISABLED, FLAG_NOT_FOUND) + coverage | PASSED |
| `//tests:flags_failure_test` | wrong expectation fails, names the case, want/got, JUnit failure | PASSED |
| `//tests:coverage_failure_test` | `require_coverage`: untested flags named, JUnit `coverage` failure | PASSED |
| `//tests:check_flags_test` | good JSON + YAML; refused (bad default, bad JSON); schema strict vs lenient; cause first (state; mixed variant types) | PASSED |
| `//tests:api_test` | env; helpers; Connect + sync + metrics; set_flag / set_flags / clear_flags restore; wait_value | PASSED |
| `//tests:restart_failure_test` | restart with a held port: 500 naming it after 5 × 0.2 s; starts afterwards; a briefly held port is retried | PASSED |
| `//tests:readme_version_test` | README `bazel_dep` / `tag` match MODULE.bazel (fails on v0.2.0's README) | PASSED |
| `//tests:replicas_test` | stop/start on the same ports with overrides kept; a second replica (own ports and overrides); same fractional assignment | PASSED |
| `//tests:server_test` | static context via extra_args, caller FLAGD_* ignored, SIGTERM exit 0, all ports closed | PASSED |
| `//tests:server_failure_test` | bad flag, readiness timeout, flagd_test never runs its body | PASSED |
| `//tests:server_cleanup_test` | flagd and a `flagd_start_instance` replica stopped when a flagd_test ends | PASSED |
| `//tests:itest_test` | two itest_services of one flagd_server (`FLAGD_INSTANCE=b`, `instance` health check) | PASSED |
| `//tests:manifest_test` | ConfigMap keys + `--uri` order, the selected version's digest-pinned image, no namespace, flags hash, replicas | PASSED |
| `//tests:health_check_test` | exits non-zero without env file, 0 with | PASSED |
| `//tests:checksums_test` | every pinned URL has a 64-hex SHA-256 | PASSED |
| `//tests:analysis_tests` (9) | providers, source order, executables, bad timeout, empty flags, zero replicas, bad instance | PASSED |
| `//tests/install_smoke:smoke_test` | kind, namespace `features`: OFREP targeting, merge order, sync, non-root read-only pod | PASSED |

## Known limitations

- `python3` is required on the host: the validation action, the server launcher and the test helpers.
- The validation action starts flagd, so it binds loopback ports in the build sandbox.
- Evaluation test cases and runtime overrides are JSON; flag files may be YAML.
- File sources only; no operator install.
- flagd listens on all interfaces (it has no bind-address option); clients use `127.0.0.1`.

## Releasing

1. Bump `version` in `MODULE.bazel` and the README's `bazel_dep` / `tag` (`//tests:readme_version_test` checks them).
2. PR (branch not named like the tag), CI green, squash-merge, tag `vX.Y.Z`, `gh release create`.
3. Download the tag's archive, compute its `sha256-…` integrity, verify it with a consumer (and that a wrong hash is rejected), then update the README's `archive_override`.
