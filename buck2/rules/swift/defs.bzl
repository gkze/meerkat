# Swift rules: one module per target, compiled by Xcode's swiftc (in
# parallel batches in debug, whole-module in release), linked statically.
#
# The prelude's Swift support lives in its Apple rules, which do not run
# outside Meta (they need Meta-only targets and a test runner, and have open
# bugs in the open-source build), so these rules own compilation and reuse
# the prelude's C++ link model for everything else: a `swift_library` is a
# linkable like any `cxx_library`, `rust_library` or `prebuilt_cxx_library`,
# and a binary links all of them through one `MergedLinkInfo` graph.
#
#   swift_library   a module: `.swiftmodule` for importers, a static library
#                   for linking
#   clang_module    a C target (or system library) made importable from Swift
#   swift_macro     a compiler plugin, built for the host, named in `macros`;
#                   every module that depends on the naming target, however
#                   indirectly, loads it too, as SwiftPM does
#   swift_binary    an executable, compiled and linked by one swiftc
#   swift_test      a swift-testing suite, run by `buck2 test`
#   swift_resource_bundle
#                   a module's resources, as SwiftPM bundles them, with the
#                   `Bundle.module` accessor its library compiles in
#   prebuilt_framework
#                   a binary framework from an `.xcframework` archive (a
#                   package's binary target), importable and linked
#
# Settings mirror SwiftPM's: `package` scopes `package` declarations,
# `defines`, `upcoming_features` and `experimental_features` are
# `swiftSettings`, and third-party code (`warnings = "suppress"`) builds the
# way SwiftPM builds remote packages.

load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load(
    "@prelude//linking:link_info.bzl",
    "LibOutputStyle",
    "LinkInfo",
    "LinkInfos",
    "LinkStrategy",
    "MergedLinkInfo",
    "create_merged_link_info",
    "create_merged_link_info_for_propagation",
    "get_link_args_for_strategy",
    "unpack_link_args",
)
load(":toolchain.bzl", "SwiftToolchainInfo")

# The search paths a module's importers need, transitively: `-I` for Swift
# modules, `-Xcc -I` for the directories holding clang module maps. A Swift
# module records its imports, so every importer needs the whole closure.
SwiftSearchPathTSet = transitive_set(args_projections = {"args": lambda value: value})

# The macro plugins a module's sources may expand, transitively: SwiftPM
# makes every macro in a target's dependency closure available to it, so a
# module that uses a dependency's macros (SQLiteData's `@Table`, from
# StructuredQueries through StructuredQueriesSQLite) need not name them. Each
# value is one `-load-plugin-executable` flag, created once by its
# `swift_macro`, so a plugin reachable along several paths is passed once.
SwiftPluginTSet = transitive_set(args_projections = {"args": lambda value: value})

SwiftModuleInfo = provider(fields = {
    "module_name": str,
    "plugins": SwiftPluginTSet,
    "search_paths": SwiftSearchPathTSet,
})

# What a target is in SwiftPM's terms, for //buck2/conformance: its
# module name, those of its direct dependencies (modules and macros), and
# for a Swift target the settings Package.swift states as `swiftSettings`
# (`warnings`, sorted `upcoming_features`); None for a C target or a binary
# framework.
SwiftTargetInfo = provider(fields = {
    "deps": list[str],
    "module_name": str,
    "swift_settings": dict[str, typing.Any] | None,
})

# A module's resource bundle: the `.bundle` directory and the source that
# defines `Bundle.module` for the module to find it.
SwiftResourceBundleInfo = provider(fields = {
    "accessor": Artifact,
    "bundle": Artifact,
})

# Every resource bundle of the modules a target links: an app copies them
# into Contents/Resources (Tools/Bundler), where `Bundle.module` looks.
SwiftResourcesInfo = provider(fields = {"bundles": list[Artifact]})

def _resources(deps: list[Dependency], own: list[Artifact] = []) -> SwiftResourcesInfo:
    bundles = {bundle.short_path: bundle for bundle in own}
    for dep in deps:
        if SwiftResourcesInfo in dep:
            for bundle in dep[SwiftResourcesInfo].bundles:
                bundles[bundle.short_path] = bundle
    return SwiftResourcesInfo(bundles = bundles.values())

SwiftMacroInfo = provider(fields = {
    "executable": Artifact,
    "module_name": str,
    # This plugin's node in `SwiftPluginTSet`.
    "plugin": SwiftPluginTSet,
})

def _toolchain(ctx: AnalysisContext) -> SwiftToolchainInfo:
    return ctx.attrs._swift_toolchain[SwiftToolchainInfo]

def _search_paths(ctx: AnalysisContext, deps: list[Dependency], own = None) -> SwiftSearchPathTSet:
    children = [dep[SwiftModuleInfo].search_paths for dep in deps if SwiftModuleInfo in dep]
    if own == None:
        return ctx.actions.tset(SwiftSearchPathTSet, children = children)
    return ctx.actions.tset(SwiftSearchPathTSet, value = own, children = children)

def _plugins(ctx: AnalysisContext, deps: list[Dependency], macros: list[Dependency] = []) -> SwiftPluginTSet:
    """The plugins of `macros` and of every module in `deps`' closure."""
    children = [macro[SwiftMacroInfo].plugin for macro in macros]
    children += [dep[SwiftModuleInfo].plugins for dep in deps if SwiftModuleInfo in dep]
    return ctx.actions.tset(SwiftPluginTSet, children = children)

def _compile_command(ctx: AnalysisContext, module_name: str, srcs: list, parse_as_library: bool, extra_flags: list) -> (cmd_args, SwiftSearchPathTSet, SwiftPluginTSet):
    """swiftc with a module's settings and sources, and no output yet; also
    the search paths of its dependencies and the plugins it loads (its own
    `macros` and its dependencies')."""
    toolchain = _toolchain(ctx)
    dep_paths = _search_paths(ctx, ctx.attrs.deps)
    plugins = _plugins(ctx, ctx.attrs.deps, ctx.attrs.macros)
    cmd = cmd_args(toolchain.swiftc)
    cmd.add(
        "-module-name",
        module_name,
        "-swift-version",
        ctx.attrs.language_mode,
        "-target",
        toolchain.triple(ctx.attrs.minimum_os) if ctx.attrs.minimum_os else toolchain.target,
        "-sdk",
        toolchain.sdk,
        "-module-cache-path",
        toolchain.module_cache,
        "-package-name",
        ctx.attrs.package,
    )
    if parse_as_library:
        cmd.add("-parse-as-library")
    cmd.add(toolchain.compile_flags)
    if ctx.attrs.warnings == "error":
        cmd.add("-warnings-as-errors")
    elif ctx.attrs.warnings == "suppress":
        cmd.add("-suppress-warnings")
    for define in ctx.attrs.defines:
        cmd.add("-D" + define)
    for feature in ctx.attrs.upcoming_features:
        cmd.add("-enable-upcoming-feature", feature)
    for feature in ctx.attrs.experimental_features:
        cmd.add("-enable-experimental-feature", feature)
    cmd.add(plugins.project_as_args("args"))
    cmd.add(ctx.attrs.swift_flags)
    cmd.add(extra_flags)
    cmd.add(dep_paths.project_as_args("args"))
    cmd.add(srcs)
    return cmd, dep_paths, plugins

def _run_swiftc(ctx: AnalysisContext, cmd: cmd_args, category: str):
    # The driver keeps its intermediate objects in TMPDIR until the step
    # that consumes them (the archiver or the linker); a directory of the
    # action's own keeps them out of Buck's shared, cleaned temporary space.
    scratch = ctx.actions.declare_output(category + "-tmp", dir = True)
    ctx.actions.run(
        cmd_args(
            "/bin/sh",
            "-c",
            'mkdir -p "$1" && export TMPDIR="$PWD/$1" && shift && exec "$@"',
            "--",
            scratch.as_output(),
            cmd,
        ),
        category = category,
        env = {"MEERKAT_XCODE_BUILD": _toolchain(ctx).xcode_build},
        # The shared SDK module cache is written outside Buck's outputs.
        local_only = True,
    )

def _compile(ctx: AnalysisContext, module_name: str, srcs: list, parse_as_library: bool, extra_flags: list = []) -> (Artifact, Artifact, SwiftSearchPathTSet, SwiftPluginTSet):
    """Compiles one module into a static library. Returns the library, the
    directory holding its `.swiftmodule` (and `.swiftdoc`,
    `.swiftsourceinfo`), and what `_compile_command` returns."""
    # A static library rather than objects: its sources are known only when
    # the action runs (`srcs_dir`), and in debug the driver compiles them in
    # parallel batches (SwiftPM's default), so their objects are not known
    # either. Whole-module optimization is release's (`compile_flags`).
    library = ctx.actions.declare_output("lib{}.a".format(module_name))
    modules = ctx.actions.declare_output("modules", dir = True)
    cmd, dep_paths, plugins = _compile_command(ctx, module_name, srcs, parse_as_library, extra_flags)
    cmd.add(
        "-emit-library",
        "-static",
        "-o",
        library.as_output(),
        "-emit-module",
        "-emit-module-path",
        cmd_args(modules.as_output(), format = "{}/" + module_name + ".swiftmodule"),
    )
    _run_swiftc(ctx, cmd, "swift_compile")
    return library, modules, dep_paths, plugins

def _force_load(libraries: list[Artifact]) -> cmd_args:
    """Links every member of each library, as SwiftPM links a module's
    objects: a member nothing references by symbol can still hold protocol
    conformances or other metadata the runtime finds by scanning."""
    return cmd_args([cmd_args("-Xlinker", "-force_load", "-Xlinker", library) for library in libraries])

def _link_info(ctx: AnalysisContext, libraries: list[Artifact], linker_flags: list) -> MergedLinkInfo:
    cxx = ctx.attrs._cxx_toolchain[CxxToolchainInfo]
    info = LinkInfo(
        name = ctx.label.name,
        pre_flags = [_force_load(libraries)],
        post_flags = linker_flags,
    )
    infos = LinkInfos(default = info, stripped = info)
    return create_merged_link_info(
        ctx,
        cxx.pic_behavior,
        link_infos = {style: infos for style in LibOutputStyle},
        deps = [dep[MergedLinkInfo] for dep in ctx.attrs.deps if MergedLinkInfo in dep],
    )

def _srcs(ctx: AnalysisContext) -> list:
    """The module's sources: `srcs`, or every `.swift` file under `srcs_dir`
    as SwiftPM finds them (recursively, following symbolic links, skipping
    hidden entries, documentation catalogs and `exclude`), passed to swiftc
    as a response file."""
    if not ctx.attrs.srcs_dir:
        return ctx.attrs.srcs
    listing = ctx.actions.declare_output("srcs.rsp")
    prune = []
    for path in ctx.attrs.exclude:
        prune += ["-path", "$1/" + path, "-prune", "-o"]
    script = 'find -L "$1" \\( -name ".*" -o -name "*.docc" \\) -prune -o {} -name "*.swift" -type f -print | LC_ALL=C sort | sed \'s/.*/"&"/\' > "$2"'.format(" ".join(['"{}"'.format(arg) for arg in prune]))
    ctx.actions.run(
        cmd_args("/bin/sh", "-c", script, "--", ctx.attrs.srcs_dir, listing.as_output()),
        category = "swift_sources",
    )
    return ctx.attrs.srcs + [cmd_args(listing, format = "@{}", hidden = ctx.attrs.srcs_dir)]

# Attributes every compiling rule takes.
def _compile_attrs() -> dict:
    return {
        "defines": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        # Paths under `srcs_dir` that are not sources, as SwiftPM's `exclude`.
        "exclude": attrs.list(attrs.string(), default = []),
        "experimental_features": attrs.list(attrs.string(), default = []),
        "language_mode": attrs.string(default = "6"),
        # Linker inputs the module needs that Swift does not autolink, such
        # as `-framework` for a framework imported only by a C dependency.
        "linker_flags": attrs.list(attrs.arg(), default = []),
        "macros": attrs.list(attrs.exec_dep(providers = [SwiftMacroInfo]), default = []),
        # The deployment target, when not the toolchain's: SwiftPM compiles
        # each package for the macOS its manifest declares.
        "minimum_os": attrs.option(attrs.string(), default = None),
        "module_name": attrs.option(attrs.string(), default = None),
        "package": attrs.string(),
        "srcs": attrs.list(attrs.source(), default = []),
        # A directory of sources (a third-party package's target directory).
        "srcs_dir": attrs.option(attrs.source(allow_directory = True), default = None),
        "swift_flags": attrs.list(attrs.arg(), default = []),
        "upcoming_features": attrs.list(attrs.string(), default = []),
        # "error" for first-party code (Package.swift's treatAllWarnings),
        # "suppress" for third-party code, as SwiftPM builds remote packages.
        "warnings": attrs.enum(["default", "error", "suppress"], default = "default"),
        "_cxx_toolchain": attrs.toolchain_dep(default = "toolchains//:cxx", providers = [CxxToolchainInfo]),
        "_swift_toolchain": attrs.toolchain_dep(default = "toolchains//:swift", providers = [SwiftToolchainInfo]),
    }

def _module_name(ctx: AnalysisContext) -> str:
    return ctx.attrs.module_name or ctx.label.name

def _target_info(ctx: AnalysisContext, module_name: str) -> SwiftTargetInfo:
    deps = [dep[SwiftTargetInfo].module_name for dep in ctx.attrs.deps if SwiftTargetInfo in dep]
    deps += [macro[SwiftMacroInfo].module_name for macro in getattr(ctx.attrs, "macros", [])]
    settings = None
    if hasattr(ctx.attrs, "upcoming_features"):
        settings = {"upcoming_features": sorted(ctx.attrs.upcoming_features), "warnings": ctx.attrs.warnings}
    return SwiftTargetInfo(module_name = module_name, deps = sorted(deps), swift_settings = settings)

def _swift_library_impl(ctx: AnalysisContext) -> list[Provider]:
    module_name = _module_name(ctx)
    entry = []
    if ctx.attrs.entry_point:
        entry = ["-Xfrontend", "-entry-point-function-name", "-Xfrontend", ctx.attrs.entry_point]
    bundle = ctx.attrs.resource_bundle[SwiftResourceBundleInfo] if ctx.attrs.resource_bundle else None
    srcs = _srcs(ctx) + ([bundle.accessor] if bundle else [])
    obj, modules, _, plugins = _compile(ctx, module_name, srcs, parse_as_library = True, extra_flags = entry)
    search_paths = _search_paths(ctx, ctx.attrs.deps, own = cmd_args("-I", modules))
    return [
        _resources(ctx.attrs.deps, [bundle.bundle] if bundle else []),
        DefaultInfo(default_outputs = [obj], other_outputs = [modules], sub_targets = {
            "library": [DefaultInfo(default_output = obj)],
            "swiftmodule": [DefaultInfo(default_output = modules)],
        }),
        SwiftModuleInfo(module_name = module_name, plugins = plugins, search_paths = search_paths),
        _target_info(ctx, module_name),
        _link_info(ctx, [obj], ctx.attrs.linker_flags),
    ]

swift_library = rule(
    impl = _swift_library_impl,
    attrs = _compile_attrs() | {
        # For an executable module (one with `@main`) that tests import, as
        # SwiftPM builds executable targets: the entry point is renamed so a
        # test runner can link the module, and the executable (a
        # `swift_binary` with only this in `deps`) aliases it back to `main`
        # with `-Xlinker -alias -Xlinker _<entry_point> -Xlinker _main`.
        "entry_point": attrs.option(attrs.string(), default = None),
        # The module's resources (a `swift_resource_bundle`), found through
        # `Bundle.module`.
        "resource_bundle": attrs.option(attrs.dep(providers = [SwiftResourceBundleInfo]), default = None),
    },
)

def _link_arguments(ctx: AnalysisContext, name: str, libraries: list[Artifact], extra_flags: list) -> cmd_args:
    """`@argsfile` with everything an executable links: `libraries` whole,
    then the link graph of `deps` (Swift modules, C, Rust, prebuilt
    libraries) and the target's linker flags."""
    cxx = ctx.attrs._cxx_toolchain[CxxToolchainInfo]
    link_args = get_link_args_for_strategy(
        ctx.actions,
        ctx.label,
        cxx.linker_info,
        [dep[MergedLinkInfo] for dep in ctx.attrs.deps if MergedLinkInfo in dep],
        LinkStrategy("static"),
        prefer_stripped = False,
        transformation_spec_context = None,
    )
    contents = cmd_args(_force_load(libraries), unpack_link_args(link_args), ctx.attrs.linker_flags, extra_flags)
    argsfile, macro_files = ctx.actions.write(name + ".link-args", contents, allow_args = True)
    return cmd_args(argsfile, format = "@{}", hidden = [macro_files, contents])

def _link(ctx: AnalysisContext, name: str, libraries: list[Artifact], extra_flags: list = []) -> Artifact:
    """Links an executable from `libraries` (a module's own) and `deps`."""
    toolchain = _toolchain(ctx)
    output = ctx.actions.declare_output(name)
    # Every library reaches the linker as `-Xlinker -force_load` in the args
    # file, and swiftc's driver refuses to link with no input file ("no input
    # files"). So the module's own library, or for an executable that is only
    # its `deps` the first dependency module's, is also an input; the linker
    # loads an archive it already force-loaded once.
    inputs = libraries or [dep[DefaultInfo].default_outputs[0] for dep in ctx.attrs.deps if SwiftModuleInfo in dep][:1]
    ctx.actions.run(
        cmd_args(
            toolchain.swiftc,
            "-target",
            toolchain.target,
            "-sdk",
            toolchain.sdk,
            "-o",
            output.as_output(),
            _link_arguments(ctx, name, libraries, extra_flags),
            inputs,
        ),
        category = "swift_link",
        env = {"MEERKAT_XCODE_BUILD": toolchain.xcode_build},
    )
    return output

def _has_main_file(ctx: AnalysisContext) -> bool:
    for src in ctx.attrs.srcs:
        if src.basename == "main.swift":
            return True
    return False

def _swift_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    if ctx.attrs.srcs or ctx.attrs.srcs_dir:
        # One swiftc compiles and links: as an executable, a `main.swift`'s
        # top-level code is the entry point, which it cannot be in a library.
        executable = ctx.actions.declare_output(ctx.label.name)
        cmd, _, _ = _compile_command(ctx, _module_name(ctx), _srcs(ctx), not _has_main_file(ctx), [])
        # With `-g`, the driver also emits the module for the debugger. Give
        # it a declared path: without one it writes `<Module>-1.swiftmodule`
        # and its siblings into the working directory, the repository root.
        module = ctx.actions.declare_output(ctx.label.name + ".swiftmodule")
        cmd.add("-emit-executable", "-o", executable.as_output(), "-emit-module-path", module.as_output())
        cmd.add(_link_arguments(ctx, ctx.label.name, [], []))
        _run_swiftc(ctx, cmd, "swift_compile_and_link")
        target_info = _target_info(ctx, _module_name(ctx))
    else:
        # The executable is its `deps` linked: an executable module built as
        # a library so tests can import it (see `swift_library`'s
        # `entry_point`). SwiftPM's one executable target is this and that
        # module.
        executable = _link(ctx, ctx.label.name, [])
        target_info = ctx.attrs.deps[0][SwiftTargetInfo]
    return [
        DefaultInfo(default_output = executable),
        RunInfo(args = [executable]),
        target_info,
        _resources(ctx.attrs.deps),
    ]

swift_binary = rule(
    impl = _swift_binary_impl,
    attrs = _compile_attrs(),
)

def _swift_macro_impl(ctx: AnalysisContext) -> list[Provider]:
    module_name = _module_name(ctx)
    obj, _, _, _ = _compile(ctx, module_name, _srcs(ctx), parse_as_library = True)
    executable = _link(ctx, module_name, [obj])
    plugin = ctx.actions.tset(
        SwiftPluginTSet,
        value = cmd_args("-load-plugin-executable", cmd_args(executable, format = "{}#" + module_name)),
    )
    return [
        DefaultInfo(default_output = executable),
        RunInfo(args = [executable]),
        SwiftMacroInfo(executable = executable, module_name = module_name, plugin = plugin),
        _target_info(ctx, module_name),
    ]

# Named in another target's `macros`, which builds it for the execution
# platform: the compiler runs it while compiling that target.
swift_macro = rule(
    impl = _swift_macro_impl,
    attrs = _compile_attrs(),
)

_TEST_MAIN = """\
import Testing

@main struct SwiftTestingRunner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
"""

def _swift_test_impl(ctx: AnalysisContext) -> list[Provider]:
    toolchain = _toolchain(ctx)
    module_name = _module_name(ctx)
    main = ctx.actions.write("SwiftTestingRunner.swift", _TEST_MAIN)
    testing = ["-F", toolchain.platform_frameworks]
    obj, _, _, _ = _compile(
        ctx, module_name, _srcs(ctx) + [main], parse_as_library = True,
        extra_flags = testing + ["-plugin-path", toolchain.testing_plugins],
    )
    rpaths = []
    for path in [toolchain.platform_frameworks, toolchain.platform_libraries]:
        rpaths += ["-Xlinker", "-rpath", "-Xlinker", path]
    executable = _link(ctx, module_name, [obj], extra_flags = testing + rpaths)
    return [
        DefaultInfo(default_output = executable),
        RunInfo(args = [executable]),
        ExternalRunnerTestInfo(
            type = "swift_testing",
            command = [executable],
            env = ctx.attrs.env,
            labels = ctx.attrs.labels,
            contacts = [],
            # Tests name fixtures relative to the repository root, as
            # `swift test` runs them.
            run_from_project_root = True,
            use_project_relative_paths = True,
        ),
        _target_info(ctx, module_name),
    ]

# A swift-testing suite as one executable, with the entry point SwiftPM
# generates for it. Arguments after `--` go to Buck's test executor, which
# passes each `--test-arg` on to swift-testing, e.g.
# `buck2 test //Tests/MeerkatKitTests -- --test-arg=--filter --test-arg=SampleStore`.
swift_test = rule(
    impl = _swift_test_impl,
    attrs = _compile_attrs() | {
        "env": attrs.dict(attrs.string(), attrs.arg(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
    },
)

def _clang_module_impl(ctx: AnalysisContext) -> list[Provider]:
    module_name = _module_name(ctx)
    if ctx.attrs.include_dir:
        directory = ctx.attrs.include_dir
    else:
        lines = ["module {} {{".format(module_name)]
        lines += ['    header "{}"'.format(header.basename) for header in ctx.attrs.headers]
        lines += ['    link "{}"'.format(library) for library in ctx.attrs.link]
        lines += ["    export *", "}", ""]
        files = {header.basename: header for header in ctx.attrs.headers}
        files["module.modulemap"] = ctx.actions.write("module.modulemap", "\n".join(lines))
        directory = ctx.actions.symlinked_dir(module_name, files)
    search_paths = _search_paths(ctx, ctx.attrs.deps, own = cmd_args("-Xcc", cmd_args(directory, format = "-I{}")))
    providers = [
        DefaultInfo(default_output = directory),
        SwiftModuleInfo(module_name = module_name, plugins = _plugins(ctx, ctx.attrs.deps), search_paths = search_paths),
        _target_info(ctx, module_name),
    ]
    merged = [dep[MergedLinkInfo] for dep in ctx.attrs.deps if MergedLinkInfo in dep]
    if merged:
        providers.append(create_merged_link_info_for_propagation(ctx, merged))
    return providers

# A C target (or system library) as a clang module Swift can `import`: a
# generated module map over `headers`, or a package's own `include_dir`. The
# compiled code, if any, is a `cxx_library` (or `prebuilt_cxx_library`) in
# `deps`, whose link info this forwards.
clang_module = rule(
    impl = _clang_module_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        # The headers a generated module map names.
        "headers": attrs.list(attrs.source(), default = []),
        # A directory that already holds a `module.modulemap` and its
        # headers (a package's own), used instead of generating one.
        "include_dir": attrs.option(attrs.source(allow_directory = True), default = None),
        # Libraries the generated module map autolinks (`link "icucore"`).
        "link": attrs.list(attrs.string(), default = []),
        "module_name": attrs.option(attrs.string(), default = None),
        "_cxx_toolchain": attrs.toolchain_dep(default = "toolchains//:cxx", providers = [CxxToolchainInfo]),
    },
)

_INFO_PLIST = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>{name}.resources</string>
    <key>CFBundleName</key>
    <string>{name}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
</dict>
</plist>
"""

# SwiftPM's generated accessor finds the bundle beside the executable or in
# the build directory; this one looks where an app keeps it (Contents/
# Resources), then beside the executable (a test or tool run from buck-out).
_ACCESSOR = """\
import Foundation

private final class BundleFinder {{}}

extension Foundation.Bundle {{
    /// This module's resources ({name}.bundle).
    static let module: Bundle = {{
        let name = "{name}.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for case let directory? in candidates {{
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) {{ return bundle }}
        }}
        fatalError("could not find \\(name)")
    }}()
}}
"""

def _swift_resource_bundle_impl(ctx: AnalysisContext) -> list[Provider]:
    toolchain = _toolchain(ctx)
    name = ctx.attrs.bundle_name
    bundle = ctx.actions.declare_output(name + ".bundle", dir = True)
    plist = ctx.actions.write(name + "-Info.plist", _INFO_PLIST.format(name = name))
    script = [
        'out="$1/Contents/Resources" && mkdir -p "$out" && cp "$2" "$1/Contents/Info.plist" && shift 2',
        'while [ $# -gt 0 ]; do case "$1" in',
        '  copy) cp -R "$2" "$out/$3" ;;',
        '  process) /usr/bin/xcrun actool "$2" --compile "$out" --platform macosx --minimum-deployment-target "$3" --output-format human-readable-text --errors > /dev/null ;;',
        "esac; shift 3; done",
    ]
    args = []
    for resource in ctx.attrs.copy:
        args += ["copy", resource, resource.basename]
    for catalog in ctx.attrs.process:
        args += ["process", catalog, ctx.attrs.minimum_os]
    ctx.actions.run(
        cmd_args("/bin/sh", "-c", "\n".join(script), "--", bundle.as_output(), plist, args),
        category = "swift_resource_bundle",
        env = {"DEVELOPER_DIR": toolchain.developer_dir, "MEERKAT_XCODE_BUILD": toolchain.xcode_build},
    )
    accessor = ctx.actions.write(name + "+resource_bundle_accessor.swift", _ACCESSOR.format(name = name))
    return [DefaultInfo(default_output = bundle), SwiftResourceBundleInfo(accessor = accessor, bundle = bundle)]

# A module's resources as SwiftPM bundles them (`<package>_<module>.bundle`):
# `copy` entries as they are, `process` asset catalogs compiled by actool
# (the only processed kind used here). The module's `swift_library` names it
# in `resource_bundle`.
swift_resource_bundle = rule(
    impl = _swift_resource_bundle_impl,
    attrs = {
        "bundle_name": attrs.string(),
        "copy": attrs.list(attrs.source(allow_directory = True), default = []),
        "minimum_os": attrs.string(),
        "process": attrs.list(attrs.source(allow_directory = True), default = []),
        "_swift_toolchain": attrs.toolchain_dep(default = "toolchains//:swift", providers = [SwiftToolchainInfo]),
    },
)

def _prebuilt_framework_impl(ctx: AnalysisContext) -> list[Provider]:
    unpacked = ctx.actions.declare_output("unpacked", dir = True)
    ctx.actions.run(
        cmd_args("/bin/sh", "-c", 'mkdir -p "$2" && exec /usr/bin/ditto -x -k "$1" "$2"', "--", ctx.attrs.archive, unpacked.as_output()),
        category = "unpack_framework",
    )
    # The directory holding `<name>.framework`.
    frameworks = cmd_args(unpacked, format = "{}/" + ctx.attrs.library)
    search = cmd_args("-F", frameworks, delimiter = "")
    info = LinkInfo(name = ctx.label.name, pre_flags = [search, "-framework", ctx.attrs.framework])
    infos = LinkInfos(default = info, stripped = info)
    cxx = ctx.attrs._cxx_toolchain[CxxToolchainInfo]
    return [
        DefaultInfo(default_output = unpacked),
        SwiftModuleInfo(
            module_name = ctx.attrs.framework,
            plugins = ctx.actions.tset(SwiftPluginTSet),
            search_paths = ctx.actions.tset(SwiftSearchPathTSet, value = search),
        ),
        SwiftTargetInfo(module_name = _module_name(ctx), deps = [], swift_settings = None),
        create_merged_link_info(ctx, cxx.pic_behavior, link_infos = {style: infos for style in LibOutputStyle}),
    ]

# A package's binary target: the `.xcframework` zip `archive`, unpacked, its
# macOS `library` (`<identifier>` in the xcframework) searched for
# `framework`'s module and linked. Static frameworks only: nothing is
# embedded in the app.
prebuilt_framework = rule(
    impl = _prebuilt_framework_impl,
    attrs = {
        "archive": attrs.source(),
        "framework": attrs.string(),
        "library": attrs.string(),
        "module_name": attrs.option(attrs.string(), default = None),
        "_cxx_toolchain": attrs.toolchain_dep(default = "toolchains//:cxx", providers = [CxxToolchainInfo]),
    },
)
