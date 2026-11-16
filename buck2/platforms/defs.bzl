load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")

# The hosts, `<os>-<cpu>`, that something here runs on, each a config_setting
# of ./BUCK: macOS, where everything builds, and Linux, which runs the
# `portable` checks (.github/workflows/ci.yml).
HOSTS = ["macos-arm64", "linux-arm64"]

def _remote_execution() -> bool:
    """Whether this Mac's `.buckconfig.local` turns remote execution on
    (`[meerkat] remote_execution`, true or false)."""
    remote = read_root_config("meerkat", "remote_execution", "false")
    if remote not in ("true", "false"):
        fail("[meerkat] remote_execution must be true or false, not {}".format(repr(remote)))
    return remote == "true"

def _executor_config() -> CommandExecutorConfig:
    # Remote execution is a machine's choice: `[meerkat] remote_execution =
    # true` and the `[buck2_re_client]` addresses go in .buckconfig.local
    # (docs/design/remote-execution.md). Actions then run on the REAPI
    # workers, and here only those that cannot (`local_only`, such as the
    # Swift compiles). A worker must have the toolchains the keys name, so
    # each is asked for by the same values.
    if not _remote_execution():
        return CommandExecutorConfig(local_enabled = True, remote_enabled = False)
    return CommandExecutorConfig(
        local_enabled = True,
        remote_enabled = True,
        use_limited_hybrid = True,
        remote_execution_properties = {
            "OSFamily": "Darwin",
            "rust_release": read_root_config("rust", "release"),
            "xcode_build": read_root_config("swift", "xcode_build"),
        },
        remote_execution_use_case = "buck2-default",
        remote_output_paths = "output_paths",
    )

def _execution_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    platform = ExecutionPlatformInfo(
        label = ctx.label.raw_target(),
        configuration = ctx.attrs.platform[PlatformInfo].configuration,
        executor_config = _executor_config(),
    )

    # Second, so a target takes it only when it asks: `exec_compatible_with
    # = LOCAL_EXECUTION`.
    local = ExecutionPlatformInfo(
        label = ctx.attrs.local.label.raw_target(),
        configuration = ctx.attrs.local[PlatformInfo].configuration,
        executor_config = CommandExecutorConfig(local_enabled = True, remote_enabled = False),
    )
    return [
        DefaultInfo(),
        platform,
        ExecutionPlatformRegistrationInfo(platforms = [platform, local], exec_marker_constraint = get_exec_platform_marker()),
    ]

# The host as the platform build tools run on, in `platform`'s configuration,
# and the same host for actions that must run here (`local`).
execution_platform = rule(
    impl = _execution_platform_impl,
    attrs = {
        "local": attrs.dep(providers = [PlatformInfo]),
        "platform": attrs.dep(providers = [PlatformInfo]),
    },
)

# What a target names in `exec_compatible_with` to run its actions on this
# Mac even with remote execution on: one whose actions read paths only this
# machine has (buck2/rules/buildscript.bzl).
LOCAL_EXECUTION = ["root//buck2/config:execution[local]"]
