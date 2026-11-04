# rules_flagd — design notes

rules_flagd follows the shape of rules_prometheus and rules_alertmanager: a toolchain, build-time checks run as validation actions, a launcher-based hermetic server with a health check and an `sh_test` macro, and a cluster install. These notes cover what is specific to flagd.

## Three families

- **Flags at build time.** Most flag mistakes are in the definitions themselves. `flagd_flags` catches them in `bazel build`, and `flagd_flags_test` checks targeting logic without a service.
- **A hermetic flagd** for testing code that evaluates flags through an OpenFeature provider, OFREP or the Connect API.
- **A cluster install** for end-to-end tests where workloads in kind talk to flagd.

## Toolchain

Each release tarball holds a single binary named `flagd_<os>_<arch>`. The repository rule finds that one file and links it as `flagd`. flagd publishes no checksum file. The pins are therefore GitHub's per-asset `digest`, and `tools/update_checksums.sh` cross-checks each one against a download. Each version's image is pinned by its multi-arch index digest (`FLAGD_IMAGES`), which the same script fetches from ghcr.io.

**Choosing the version (v0.2, #1).** In v0.1 `toolchain/BUILD.bazel` named the `flagd_0_18_2_*` repos and the version string, so `flagd.version()` could only select 0.18.2. Now:
- **Repos named per platform:** `flagd_<platform>`. Each one declares its own `flagd_toolchain` with the version and that version's image.
- **The root module's tag wins**, else rules_flagd's own, else `DEFAULT_VERSION`. This is the scheme rules_otel and rules_gitleaks use.
- **The install follows it:** `flagd_manifest` takes its default image from the resolved toolchain. A consumer running flagd 0.17.1 in its cluster pins `flagd.version(version = "0.17.1")`, and tests and the install use the same version. `tests/version_select/`, a separate consumer module that CI runs, checks both.
- **v0.1 names still resolve.** The extension also creates the `flagd_<ver>_<plat>` names for the selected version, so a v0.1 consumer's `use_repo(...)` keeps working. Repos are only fetched when used.

Pinned versions: 0.18.2 (default) and 0.17.1.

## Validating with flagd itself

flagd has no `validate` command. Its JSON schema could be checked by another validator, but that would need a third-party library on the host. It would also miss the semantic checks flagd does when it loads flags, such as a `defaultVariant` that isn't a variant. Instead, the validation action starts the pinned flagd on each file (`launcher.py check`) and reads the outcome:

| flagd's behaviour | What it means | rules_flagd |
|---|---|---|
| logs `error setting state: …`, `/readyz` stays 412 | it refused the file: bad JSON/YAML, unknown default variant, … | fail, with flagd's reason |
| logs a `warn` "does not conform to the schema" with the full report, then **serves the flag** | schema violation: `state: MAYBE`, mixed variant types, unknown targeting operator, … | fail with `strict` (the default), else print it as a warning |
| `/readyz` 200 | loaded | pass |

The schema is embedded in the binary, so the check needs no network. It needs only loopback ports, and it works with `--sandbox_default_allow_network=false`. Each file gets its own flagd, so an error names the file. A check takes about 150 ms per file.

`strict` defaults to true because flagd serving a schema-invalid flag usually hides a bug. An unknown targeting operator, for example, quietly never matches.

**Reading flagd's schema report (v0.2, #1).** flagd prints the validator's whole error tree. A flag's `variants` may be booleans, strings, numbers or objects (a `oneOf` / `anyOf` with one `allOf` branch per type). So a bad `state` appears once per branch, next to type mismatches that only explain why the other branches failed, plus the `/flags` "got object, want array" alternative. `launcher.py`'s `schema_causes` reads the tree:
- an `allOf` node's causes are the union of its children's;
- an `anyOf` / `oneOf` node's causes are the errors **every** alternative shares;
- if the alternatives share none, the causes are the **closest** branches': the deepest, then those with the fewest errors, keeping every tied branch.

Keeping ties matters for variants of mixed types: "off isn't a boolean" and "on isn't a string" are equally right. The causes are printed first, then the full report.

## Hermetic server

- **Ports.** The launcher picks four free ports: evaluation, management, sync and OFREP. It retries with new ones on a clash, except on a restart (below). Ready means `GET /readyz` on the management port returns 200. If flagd refuses its flags at start, the launcher fails at once, without waiting for the timeout.
- **Environment.** `FLAGD_HOST` / `FLAGD_PORT` are the variables OpenFeature's flagd providers read, so a service under test finds the server with no code changes. In return, the server itself runs without any `FLAGD_*` from its caller, because flagd reads those as configuration. `HOME` points at the state dir, so a user's `~/.agent.yaml` can't configure it either.
- **fsnotify sources.** Sources are passed with `--sources` using the `fsnotify` provider. The default `file:` provider polls once a second. With fsnotify a change applies in about 10 ms, which keeps the override helpers fast.

### Runtime overrides

Tests often need to flip a flag mid-test. The server appends one more source after the configured ones, `overrides.json`, which has the highest precedence. The helpers rewrite it atomically. Two flagd behaviours shape them:

1. **Knowing when a change applied.** A flag set's `metadata` is copied into each of its flags, and the sync port's `GET /v1/flags` reports each flag's `source`. The helpers stamp the overrides with an increasing `rules_flagd_generation` and poll until the served flags from that source are exactly the new set, at the new generation.
2. **Removing an override deletes the key.** When a higher-precedence source drops a key, flagd removes the flag outright. It does not fall back to a lower source's definition, which only returns when that source next syncs. Re-syncing a lower source never beats a higher one, which was checked.

   So the server loads writable copies of the configured sources, and records at start-up which source defines each key (`sources.json`). After removing overrides, the helpers rewrite the configured source of each removed key, and wait until flagd serves it from there again.

### Restarts and replicas (v0.2, #1)

Tests of fractional assignment need flagd restarted mid-test, and a second flagd over the same flags (another replica).

- **Restart.** The launcher runs a small HTTP control endpoint (`FLAGD_CONTROL_URL`, `POST /stop` and `/start`), as rules_otel does.
  - `/start` runs flagd again with the same sources, the same overrides file and the **same ports**, so the env file stays valid and providers reconnect. A port taken in the meantime is an error, not a silent move to new ports.
  - A requested stop doesn't count as a crash. Only an exit the test didn't ask for stops the server.
  - HTTP rather than signals, because `/start` must report whether flagd became ready again.
- **Replicas.** `FLAGD_INSTANCE=<id>` in the server's environment makes it a separate replica: env file `<name>@<id>.env`, state directory `flagd-<name>@<id>`, its own ports and overrides.
  - Inside a `flagd_test`, `flagd_start_instance` starts one, and the trampoline stops it with the test.
  - Under rules_itest, an `itest_service` passes `env = {"FLAGD_INSTANCE": ...}`, and `flagd_health_check(instance = ...)` waits for the right file.
  - `flagd_use` / `flagd_on` switch the helpers by sourcing a replica's env file. Every helper already reads its target from the `FLAGD_*` variables.

### `flagd_test` and `flagd_flags_test`

`flagd_test` follows rules_nats' fixed trampoline (v0.1.1):
- it removes its own arguments before the test sees `"$@"`;
- it runs the test rather than `exec`ing it, so its EXIT trap stops flagd;
- HUP, INT and TERM exit 129, 130 and 143.

`//tests:server_cleanup_test` fails if the trampoline `exec`s.

`flagd_flags_test` is a `flagd_test` whose body is the case runner (`testlib.py run-cases`). There is no offline evaluator to call, so evaluation tests use the real server, about 0.5 s per target. Cases are JSON because the host's Python has no YAML parser; flag files can still be YAML, since flagd parses those. Results are written as JUnit XML to `$XML_OUTPUT_FILE`.

**Coverage (v0.2, #1).** `require_coverage = True` fails the test if a flag defined in `flags` has no case. The set of flags is the configured sources' keys, as served at start-up (`sources.json`; overrides are empty then). It is reported as an extra JUnit case, `coverage`, naming the untested flags.

## Cluster install

- **Why not the operator.** There is no upstream chart for a standalone flagd. Kubernetes support upstream is the OpenFeature Operator. It installs flagd through its own CRDs (`FeatureFlag`, `FeatureFlagSource`, `Flagd`), and its admission webhooks need cert-manager. That is a much heavier dependency than "run flagd with these flags", and its chart pins an older flagd (v0.16.2).

  rules_flagd therefore ships its own small manifest template (`private/manifests/flagd.yaml.tmpl`). `flagd_manifest` fills it in at build time: one ConfigMap key per flag file, matching `--uri` arguments in source order, the pinned image, and a hash of the flags.
- **Namespace.** Unlike the chart-rendered installs in this organization, the objects carry no namespace. So `flagd_install(namespace = ...)` really places them: rules_kubectl applies with `-n`.
- **Flag changes.** A ConfigMap volume updates in place only after the kubelet's sync delay, up to about a minute. The hash in the pod template makes re-applying new flags roll the Deployment instead, which is deterministic. In the cluster, flagd keeps the default polling `file:` provider. Kubernetes updates ConfigMap volumes by swapping symlinks, which a stat-based poll follows reliably.

## What this repo does not (yet) do

- **The OpenFeature Operator.** No `FeatureFlag` / `FeatureFlagSource` rendering and no sidecar injection. It would compose with rules_certmanager.
- **Remote sources:** HTTP, gRPC, S3/GCS/Azure, and the Kubernetes `FeatureFlag` provider. The hermetic server serves files only.
- **flagd-proxy** and in-process (offline file) provider fixtures beyond exposing the sync port.
- **Non-shell `flagd_test`.** Use `flagd_server` + `flagd_health_check` through rules_itest, and read the env file.
