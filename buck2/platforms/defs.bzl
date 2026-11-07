load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")

def _execution_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    configuration = ctx.attrs.platform[PlatformInfo].configuration
    platform = ExecutionPlatformInfo(
        label = ctx.label.raw_target(),
        configuration = configuration,
        executor_config = CommandExecutorConfig(local_enabled = True, remote_enabled = False),
    )
    return [
        DefaultInfo(),
        platform,
        ExecutionPlatformRegistrationInfo(platforms = [platform], exec_marker_constraint = get_exec_platform_marker()),
    ]

# The host as the platform build tools run on, in `platform`'s configuration.
execution_platform = rule(
    impl = _execution_platform_impl,
    attrs = {"platform": attrs.dep(providers = [PlatformInfo])},
)
