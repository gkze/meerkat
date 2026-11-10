# The command that assembles, signs and installs Meerkat.app from its parts
# (Tools/Bundler/parts.bzl).
#
# Buck builds everything the bundle holds; the bundler only lays it out,
# compiles the icon, writes the plists and signs, which needs the keychain's
# identity and so cannot be a build action. `buck2 run //Tools/Bundler:app`
# (`-- --install` to install) runs it with each part's path.

load("//Tools/Bundler:parts.bzl", "PARTS")
load("//buck2/rules/swift:defs.bzl", "SwiftResourcesInfo")

# What the bundler copies in: the parts, and the notices generated from
# them, each passed as `--<name>` (`-` for `_`), the option Bundler.swift
# declares for it. The app is in every bundle; the full bundle needs the
# rest (Bundler.swift's `validate`), which the preview leaves out.
_INPUTS = list(PARTS) + ["notices"]

def _directory_impl(ctx: AnalysisContext) -> list[Provider]:
    return [DefaultInfo(default_output = ctx.actions.copied_dir(ctx.label.name, ctx.attrs.entries))]

# A directory of `entries` (destination path -> file or directory), copied
# rather than linked: the bundler copies it into the bundle as is.
directory = rule(
    impl = _directory_impl,
    attrs = {"entries": attrs.dict(attrs.string(), attrs.source(allow_directory = True))},
)

def _mode_transition_impl(platform: PlatformInfo, refs: struct, attrs: struct) -> PlatformInfo:
    mode = refs.debug if attrs.mode == "debug" else refs.release
    constraints = dict(platform.configuration.constraints)
    constraints[mode[ConstraintValueInfo].setting.label] = mode[ConstraintValueInfo]
    return PlatformInfo(
        # The label of //buck2/platforms:<mode>, whose constraints these
        # are, so the bundle shares that platform's build.
        label = "root//buck2/platforms:" + attrs.mode,
        configuration = ConfigurationInfo(constraints = constraints, values = platform.configuration.values),
    )

# The bundle is built in its own `mode`, whatever the command line's.
_mode_transition = transition(
    impl = _mode_transition_impl,
    refs = {
        "debug": "//buck2/config:mode[debug]",
        "release": "//buck2/config:mode[release]",
    },
    attrs = ["mode"],
)

def _bundle_command_impl(ctx: AnalysisContext) -> list[Provider]:
    args = cmd_args(ctx.attrs.bundler[RunInfo])
    for name in _INPUTS:
        part = getattr(ctx.attrs, name)
        if part:
            args.add("--" + name.replace("_", "-"), part[DefaultInfo].default_outputs[0])
    # The resource bundles of the modules the app links, for
    # Contents/Resources, where their `Bundle.module` looks.
    if SwiftResourcesInfo in ctx.attrs.app:
        for bundle in ctx.attrs.app[SwiftResourcesInfo].bundles:
            args.add("--resource-bundle", bundle)
    args.add("--app-version", ctx.attrs.version)
    args.add("--minimum-system-version", ctx.attrs.minimum_macos)
    args.add("--developer-dir", ctx.attrs.developer_dir)
    if ctx.attrs.preview:
        args.add("--preview")
    # Checks the bundle must not be assembled without: their outputs are
    # inputs of the command, so `buck2 run` builds them first and stops when
    # one fails.
    args.add(cmd_args(hidden = [check[DefaultInfo].default_outputs for check in ctx.attrs.checks]))
    return [DefaultInfo(), RunInfo(args = args)]

# `buck2 run` this to build Meerkat.app (`preview`: Meerkat Preview.app,
# the app alone) from its parts, in `mode`, at `version` (`[meerkat] version`).
# Arguments after `--` reach the bundler (`--install`, `--identity`,
# `--output`, `--notarize`, `--archive`).
bundle_command = rule(
    impl = _bundle_command_impl,
    attrs = {name: attrs.option(attrs.dep(), default = None) for name in _INPUTS} | {
        "app": attrs.dep(),
        "bundler": attrs.exec_dep(providers = [RunInfo]),
        "checks": attrs.list(attrs.dep(), default = []),
        "developer_dir": attrs.string(),
        "minimum_macos": attrs.string(),
        "mode": attrs.enum(["debug", "release"]),
        "preview": attrs.bool(default = False),
        "version": attrs.string(),
    },
    cfg = _mode_transition,
)
