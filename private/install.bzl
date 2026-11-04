"""flagd_manifest, flagd_install, flagd_install_health_check — flagd in a
cluster.

There is no upstream standalone flagd chart (the OpenFeature Operator
deploys flagd through its own CRDs and needs cert-manager), so the
manifest is rules_flagd's own: a ConfigMap with your flag files, a
Deployment running the pinned, digest-pinned flagd image over them, and
a Service exposing the evaluation (8013), management (8014), sync (8015)
and OFREP (8016) ports. Objects carry no namespace; kubectl_apply puts
them in `namespace`.
"""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")
load(":flags.bzl", "flag_sources")
load(":providers.bzl", "FlagdFlagsInfo")

_DEPLOY = "deploy/flagd"

def _flagd_manifest_impl(ctx):
    sources = flag_sources(ctx.attr.flags)
    if not sources:
        fail("{}: flags is empty; flagd_manifest needs at least one flag file.".format(ctx.label))
    if ctx.attr.replicas < 1:
        fail("{}: replicas = {}: must be at least 1.".format(ctx.label, ctx.attr.replicas))
    # Default: the image of the version the toolchain resolved, so the
    # deployed flagd matches the one tests run.
    image = ctx.attr.image or ctx.toolchains["//toolchain:flagd"].flagd.image
    out = ctx.actions.declare_file(ctx.label.name + ".yaml")
    ctx.actions.run_shell(
        command = 'exec python3 "$@"',
        arguments = [ctx.file._script.path, ctx.file._template.path, out.path,
                     image, str(ctx.attr.replicas)] + [f.path for f in sources],
        inputs = sources + [ctx.file._script, ctx.file._template],
        outputs = [out],
        use_default_shell_env = True,
        mnemonic = "FlagdManifest",
        progress_message = "Rendering flagd manifest %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

flagd_manifest = rule(
    implementation = _flagd_manifest_impl,
    doc = "The flagd Kubernetes manifest for `flags` (ConfigMap + Deployment + Service).",
    attrs = {
        "flags": attr.label_list(
            mandatory = True,
            providers = [FlagdFlagsInfo],
            doc = "flagd_flags targets, merged in order (later wins).",
        ),
        "image": attr.string(
            doc = "flagd image. Default: the image of the flagd version the " +
                  "toolchain resolved (flagd.version()), by digest.",
        ),
        "replicas": attr.int(default = 1, doc = "Deployment replicas."),
        "_script": attr.label(default = "//private:manifest.py", allow_single_file = True),
        "_template": attr.label(default = "//private/manifests:flagd.yaml.tmpl", allow_single_file = True),
    },
    toolchains = ["//toolchain:flagd"],
)

def flagd_install(
        name,
        flags,
        namespace = "flagd",
        replicas = 1,
        image = None,
        wait_timeout = "300s",
        **kwargs):
    """Apply flagd with `flags` into `namespace` and block until
    `deploy/flagd` has rolled out. Drops into `itest_service.exe`.

    Args:
      name: target name.
      flags: flagd_flags targets, merged in order (later wins).
      namespace: namespace to install into (created if missing).
      replicas: Deployment replicas.
      image: flagd image; default the selected flagd version's image, by digest.
      wait_timeout: rollout wait.
      **kwargs: forwarded to kubectl_apply (tags, visibility,
        wait_for_rollouts, ...).
    """
    manifest_kwargs = {"image": image} if image else {}
    flagd_manifest(
        name = name + "_manifest",
        flags = flags,
        replicas = replicas,
        tags = kwargs.get("tags"),
        visibility = kwargs.get("visibility"),
        **manifest_kwargs
    )
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply(
        name = name,
        manifests = [":" + name + "_manifest"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_rollouts = [_DEPLOY] + list(extra_rollouts),
        wait_timeout = wait_timeout,
        **kwargs
    )

def flagd_install_health_check(
        name,
        namespace = "flagd",
        **kwargs):
    """Readiness probe paired with `flagd_install`: same rollout wait with
    `--timeout=0s`. Drops into `itest_service.health_check`."""
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_rollouts = [_DEPLOY] + list(extra_rollouts),
        **kwargs
    )
