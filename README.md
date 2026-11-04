# rules_flagd

Bazel rules for [flagd](https://flagd.dev), the [OpenFeature](https://openfeature.dev) feature-flag daemon. They check flag definitions at build time, unit-test flag evaluation, run a hermetic flagd in tests, and install flagd into a cluster. Three families in one repo:

- **Flags (build time)**
  - `flagd_flags` — flag definition files (JSON or YAML). flagd itself loads each file as a validation action, so a file it would refuse fails `bazel build`. By default, so does a schema violation, which flagd on its own only logs and then serves anyway.
  - `flagd_flags_test` — evaluation tests: a flag plus a context gives an expected value, variant, reason or error. Results go to Bazel as JUnit XML.
- **Hermetic server (test time)**
  - `flagd_server` — a long-running flagd on free ports; writes `$TEST_TMPDIR/<name>.env` once `/readyz` answers and every port is up.
  - `flagd_health_check` — pairs with `flagd_server` for `itest_service`.
  - `flagd_test` — `sh_test` macro with an auto-launched flagd and helpers to evaluate flags and change them at runtime.
- **Cluster install (kind / production-shaped)**
  - `flagd_manifest` — a ConfigMap, Deployment and Service running the pinned flagd image over your flags.
  - `flagd_install` / `flagd_install_health_check` — apply it with rules_kubectl and wait for `deploy/flagd`.

No host `flagd` or Go needed: the binary comes from the pinned, SHA-256-verified upstream release tarballs, and the image is pinned by digest. The rules need `python3` on the host.

## Install (Bzlmod)

```python
bazel_dep(name = "rules_flagd", version = "0.3.0")
git_override(
    module_name = "rules_flagd",
    remote = "https://github.com/collider-bazel-extensions/rules_flagd",
    tag = "v0.3.0",
)

# rules_flagd depends on rules_kubectl, which isn't in the BCR either.
bazel_dep(name = "rules_kubectl", version = "0.2.0")
git_override(
    module_name = "rules_kubectl",
    remote = "https://github.com/collider-bazel-extensions/rules_kubectl",
    commit = "81b60ab80df46b64c612f2576ffef0a7af98ccb6",  # v0.2.0
)

```

That's all: rules_flagd registers its toolchain and fetches flagd only for the platform a build needs, at 0.18.2 by default. To run the version your cluster runs, name it in your own `MODULE.bazel` (only the root module's tag counts):

```python
flagd = use_extension("@rules_flagd//:extensions.bzl", "flagd")
flagd.version(version = "0.17.1")   # pinned: 0.18.2, 0.17.1
```

The toolchain and the image `flagd_install` deploys both follow it, so tests and the cluster run the same flagd. Upgrading from v0.1 or v0.2: delete any `use_repo(flagd, "flagd_0_18_2_…")` lines; they're no longer needed. Since v0.3.0 those v0.1 names exist only on request, so a leftover line fails with Bazel's `does not generate repository "flagd_0_18_2_linux_amd64"`. To keep them for now, use `flagd.version(version = "...", v01_repo_names = True)`.

To pin by archive and integrity instead of a git tag, replace the first `git_override` with:

```python
archive_override(
    module_name = "rules_flagd",
    urls = ["https://github.com/collider-bazel-extensions/rules_flagd/archive/refs/tags/v0.3.0.tar.gz"],
    strip_prefix = "rules_flagd-0.3.0",
    integrity = "sha256-0hh43d5nPnPm/ePbCmLcb8VOxVkSN8QbxG7tPcdxbl0=",
)
```

## Flags and evaluation tests

```python
load("@rules_flagd//:defs.bzl", "flagd_flags", "flagd_flags_test")

flagd_flags(
    name = "flags",
    srcs = ["flags/base.json", "flags/overrides.yaml"],   # later files win
)

flagd_flags_test(
    name = "flags_test",
    srcs = ["flags_test.json"],
    flags = [":flags"],
    require_coverage = True,   # every flag in :flags needs a case
)
```

```json
{
  "context": {"region": "us"},
  "tests": [
    {"name": "staff get the new checkout",
     "flag": "new-checkout", "context": {"email": "dev@example.com"},
     "expect": {"value": true, "variant": "on", "reason": "TARGETING_MATCH"}},
    {"flag": "no-such-flag", "expect": {"errorCode": "FLAG_NOT_FOUND"}}
  ]
}
```

- **What the check catches.** Each file is loaded into a real flagd, the same parser your services use:
  - Bad JSON or YAML, a `defaultVariant` that isn't a variant, and similar errors: flagd refuses the file, so the build fails.
  - Anything the [flagd schema](https://flagd.dev/reference/schema/) rejects, such as `state: MAYBE`, a variant whose type differs from its siblings, or an unknown targeting operator. flagd only logs these and serves the flag anyway. They fail the build too, unless `strict = False` makes them warnings.

  flagd's report is a tree with a branch per alternative the schema allows: a flag's variants may be booleans, strings, numbers or objects, so a bad `state` is reported once per variant type, next to type mismatches that only explain why the *other* alternatives failed. rules_flagd prints the cause first, then the full report:

  ```
  flagd_flags: flags/base.json: does not conform to the flagd schema (error):
    at '/flags/x/state': value must be one of 'ENABLED', 'DISABLED'
    full report:
      ...
  ```

  The cause is the errors every alternative shares. If they share none, it is the closest branches': the deepest, then those with the fewest errors. For variants of mixed types that gives both sides, e.g. `variants/off: got string, want boolean` and `variants/on: got boolean, want string`.
- **Merge order.** flagd merges sources in order: a key in a later file replaces the same key from an earlier one. `deps` come before `srcs`.
- **Test files** are JSON. A file-level `context` is merged into every case. `expect` checks only the keys it has: `value`, `variant`, `reason`, `errorCode`. A failing case prints the flag, the context, what it expected and flagd's full answer.
- **Coverage.** With `require_coverage = True`, the test also fails if a flag defined in `flags` has no case. An extra JUnit case, `coverage`, names the untested flags: `FAIL coverage: 2 configured flag(s) untested: banner, rollout`.

| Rule | Attributes |
|---|---|
| `flagd_flags` | `srcs` (`.json`, `.yaml`, `.yml`); `deps` (other `flagd_flags`); `strict` (default `True`) |
| `flagd_flags_test` | `srcs` (JSON test files); `flags`; `require_coverage` (default `False`); `extra_args` (e.g. `["-X", "env=prod"]` for a static context value) |

## Hermetic server

### `flagd_test`

```python
load("@rules_flagd//:defs.bzl", "flagd_test")

flagd_test(
    name = "checkout_test",
    srcs = ["checkout_test.sh"],
    flags = [":flags"],
    data = [":checkout_service"],
)
```

```sh
# checkout_test.sh
source "$FLAGD_TESTLIB"
./checkout_service &        # an OpenFeature flagd provider reads FLAGD_HOST / FLAGD_PORT
[[ "$(flagd_value new-checkout '{"email":"dev@example.com"}')" == true ]]
flagd_set_flag new-checkout '{"state":"ENABLED","variants":{"on":true},"defaultVariant":"on"}'
# ... the service now sees the flag on for everyone ...
flagd_clear_flags            # back to the configured definition
```

What the test sees:

| Variable | |
|---|---|
| `FLAGD_HOST`, `FLAGD_PORT` | the evaluation (gRPC / Connect) endpoint. OpenFeature's flagd providers read these, so a provider in RPC mode connects with no code changes. |
| `FLAGD_SYNC_PORT` | the sync endpoint, for in-process providers (`FLAGD_RESOLVER=in-process FLAGD_PORT=$FLAGD_SYNC_PORT`), and `GET /v1/flags` |
| `FLAGD_OFREP_PORT`, `FLAGD_OFREP_URL` | [OFREP](https://openfeature.dev/specification/appendix-c) (`POST $FLAGD_OFREP_URL/ofrep/v1/evaluate/flags/<key>`) |
| `FLAGD_URL` | `http://127.0.0.1:$FLAGD_PORT`, for the Connect/HTTP evaluation API |
| `FLAGD_MANAGEMENT_PORT` | `/healthz`, `/readyz`, `/metrics` |
| `FLAGD_OVERRIDES_FILE` | the runtime overrides source (below) |
| `FLAGD_CONTROL_URL` | the launcher's control endpoint (`flagd_stop` / `flagd_start`) |
| `FLAGD_ENV_FILE` | this env file. `FLAGD_MAIN_ENV_FILE` is the test's first server, for switching back from a replica. |
| `FLAGD` | the flagd binary |
| `FLAGD_TESTLIB` | shell helpers (below) |

| Helper | |
|---|---|
| `flagd_value FLAG [CONTEXT_JSON]` | the value. Strings are printed raw; booleans, numbers and objects as JSON. Fails on an evaluation error. |
| `flagd_variant FLAG [CONTEXT_JSON]` | the variant |
| `flagd_eval FLAG [CONTEXT_JSON]` | the full OFREP answer as JSON |
| `flagd_wait_value FLAG EXPECTED [CONTEXT_JSON] [TIMEOUT_S]` | waits until `flagd_value` prints `EXPECTED` (default 30 s) |
| `flagd_set_flag KEY FLAG_JSON` | adds or replaces one override |
| `flagd_set_flags FILE.json` | replaces all overrides with the file's `flags` |
| `flagd_clear_flags` | removes every override |
| `flagd_stop` / `flagd_start` | stops flagd / starts it again **on the same ports, with the same sources and overrides**, and waits until it's ready. If another process has taken one of the ports, the start retries 5 times, 0.2 s apart, then fails naming the port, e.g. `another process holds ofrep 41237 (address already in use)`. The server stays up, so `flagd_start` can be tried again. |
| `flagd_start_instance ID` | starts another replica of this test's `flagd_server`, with its own ports and overrides; prints its env file |
| `flagd_use ENV_FILE` | points the helpers (and every `FLAGD_*` variable) at a replica; `flagd_use "$FLAGD_MAIN_ENV_FILE"` goes back |
| `flagd_on ENV_FILE CMD…` | runs one command against a replica, e.g. `flagd_on "$b" flagd_variant rollout "$ctx"` |

**Runtime overrides.** The server loads one more source after yours, an overrides file with the highest precedence. The `set` and `clear` helpers rewrite it and return only once flagd serves the change, typically within 100 ms. When an override is removed, the configured definition of that key comes back. flagd itself would drop the key (see DESIGN.md). Overrides are JSON.

| `flagd_test` / `flagd_server` argument | Default | |
|---|---|---|
| `flags` | `[]` | `flagd_flags` targets, merged in order |
| `ready_timeout` | `30` | seconds to wait until flagd is ready (`/readyz` and every port) |
| `extra_args` | `[]` | extra `flagd start` flags, e.g. `["-X", "env=ci"]` (a static context value) or `["--debug"]` |
| `args`, `env`, `data`, `deps`, `size`, `timeout`, `tags`, … | | as for `sh_test` (`flagd_test` only) |

Restarts and replicas, for example to check that fractional assignment is stable:

```sh
source "$FLAGD_TESTLIB"
ctx='{"targetingKey": "user-42"}'
v=$(flagd_variant rollout "$ctx")
flagd_stop; flagd_start                              # same ports, same overrides
[[ "$(flagd_variant rollout "$ctx")" == "$v" ]]
b=$(flagd_start_instance b)                          # a second flagd over the same flags
[[ "$(flagd_on "$b" flagd_variant rollout "$ctx")" == "$v" ]]
```

Replicas are stopped with the test. If flagd exits or isn't ready within `ready_timeout`, the test fails, says why and shows flagd's log; the test body never runs. Each test gets its own flagd (its own ports and overrides), so tests are safe under `--jobs=N`. flagd is stopped when the test ends. The server ignores any `FLAGD_*` variables in its own environment.

### `flagd_server` + `flagd_health_check` (rules_itest)

```python
flagd_server(name = "flagd", flags = [":flags"], tags = ["manual"])
flagd_health_check(name = "flagd_health", server = ":flagd", tags = ["manual"])

itest_service(
    name = "flagd_svc",
    exe = ":flagd",
    health_check = ":flagd_health",
)
```

The server writes `$TEST_TMPDIR/flagd.env` (named after the target) with the variables above. A service or test in any language reads it, or takes `FLAGD_HOST` / `FLAGD_PORT` from a wrapper. SIGTERM stops flagd, removes the file and exits 0.

**Several replicas of one target.** With `FLAGD_INSTANCE=<id>` in its environment, the server runs as a separate replica: its own ports, state and overrides, writing `$TEST_TMPDIR/<name>@<id>.env`. Its health check takes `instance`:

```python
flagd_health_check(name = "flagd_b_health", server = ":flagd", instance = "b", tags = ["manual"])

itest_service(
    name = "flagd_b_svc",
    exe = ":flagd",
    env = {"FLAGD_INSTANCE": "b"},
    health_check = ":flagd_b_health",
)
```

`POST $FLAGD_CONTROL_URL/stop` and `/start` restart a server from any language. A failed `/start` returns 500 with the reason.

**Interfaces.** flagd has no option to choose the address it listens on, only the ports, so the hermetic server listens on all interfaces, not just `127.0.0.1`. The env file points clients at `127.0.0.1`. Ports are free ones chosen at start-up, and checked again, by binding them as flagd will, before every start and restart.

## Cluster install

```python
load("@rules_flagd//:defs.bzl", "flagd_install", "flagd_install_health_check")

flagd_install(name = "flagd_install", flags = [":flags"], namespace = "features", tags = ["manual"])
flagd_install_health_check(name = "flagd_install_health", namespace = "features", tags = ["manual"])

itest_service(
    name = "flagd_install_svc",
    exe = ":flagd_install",
    health_check = ":flagd_install_health",
    deps = [":kind_svc"],
)
```

- **What's applied** (`flagd_manifest`):
  - a ConfigMap `flagd-flags` with your files, keyed `00-<name>`, `01-<name>`, … in source order;
  - a Deployment `flagd` running the selected version's image (`ghcr.io/open-feature/flagd:v0.18.2` by default) by digest, non-root with a read-only root filesystem, over those files;
  - a Service `flagd` with ports 8013 (evaluation), 8014 (management), 8015 (sync) and 8016 (OFREP).

  In-cluster providers use `flagd.<namespace>.svc:8013`.
- **Namespace:** the objects carry none, so `namespace` really places them (default `flagd`).
- **New flags roll the pods.** The pod template carries a hash of the flags.
- **Other attributes:** `replicas` (default 1) and `image` (default: the selected version's image, by digest).
- **Your own pipeline:** `flagd_manifest` is public, so a GitOps or Argo CD setup can ship the same manifest the tests use.
- **Smoke test:** `tests/install_smoke/` installs into kind (namespace `features`) and evaluates through `kubectl port-forward svc/flagd`.

## Pinned versions

| Component | Version | Source |
|---|---|---|
| flagd binary | `0.18.2` (default), `0.17.1` | https://github.com/open-feature/flagd/releases (GitHub asset digests) |
| flagd image | `v0.18.2@sha256:a1b6de22…`, `v0.17.1@sha256:594f9808…` | `ghcr.io/open-feature/flagd` (multi-arch index) |

flagd publishes no checksum file. `tools/update_checksums.sh <version>` therefore pins:
- each platform's tarball, from GitHub's asset digest, cross-checked by downloading it;
- the image's index digest, from ghcr.io.

`--check` verifies every pin without writing anything; CI runs it. To change the default, update `DEFAULT_VERSION` and `flagd.version()` in rules_flagd's `MODULE.bazel`.

## Development

```sh
bazel test //tests/...                                                # no container runtime
bazel test //tests/install_smoke:smoke_test --test_output=streamed    # needs Docker or podman
(cd tests/version_select && bazel test //...)                         # a consumer pinning 0.17.1
```

See [DESIGN.md](DESIGN.md) for the architecture and trade-offs.
