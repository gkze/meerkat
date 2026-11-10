# Tests that keep the files other tools read in step with the BUCK files
# that own the same facts (see buck2/conformance). Each writes what
# Buck builds as JSON and has the checker compare it with the other file.
# `spm_tables` runs the same checker to generate buck2/third_party/swift's tables.

load("//buck2/rules/swift:defs.bzl", "SwiftTargetInfo")
load(":check.bzl", "XCODE_ENV", "external_test", "with_xcode_env")

# The checker runs `swift package dump-package` through xcrun, so from the
# Xcode Buck builds with.
def _test(ctx: AnalysisContext, mode: str, expected: Artifact, hidden = []) -> list[Provider]:
    command = cmd_args(ctx.attrs._checker[RunInfo], mode, expected, hidden = hidden)
    return [DefaultInfo(default_output = expected), external_test(command, ["conformance"], XCODE_ENV)]

_CHECKER = attrs.default_only(attrs.exec_dep(providers = [RunInfo], default = "//buck2/conformance:conformance"))

def _swiftpm_graph_test_impl(ctx: AnalysisContext) -> list[Provider]:
    graph = {}
    for target in ctx.attrs.targets:
        if SwiftTargetInfo in target:
            info = target[SwiftTargetInfo]
            graph[info.module_name] = {"deps": info.deps, "linker": info.linker, "swift": info.swift_settings}
    expected = {"graph": graph, "minimum_macos": ctx.attrs.minimum_macos}
    return _test(ctx, "spm-graph", ctx.actions.write_json("swift-graph.json", expected))

# Package.swift declares the Swift targets `targets` (a query) finds, with
# the same dependencies, linker settings and Swift settings, for
# `minimum_macos`.
swiftpm_graph_test = rule(
    impl = _swiftpm_graph_test_impl,
    attrs = {"minimum_macos": attrs.string(), "targets": attrs.query(), "_checker": _CHECKER},
)

def _spm_pins_test_impl(ctx: AnalysisContext) -> list[Provider]:
    return _test(ctx, "spm-pins", ctx.actions.write_json("revisions.json", ctx.attrs.revisions))

# Package.resolved pins each package at `revisions`' revision, and every
# exact version or revision Package.swift requires.
spm_pins_test = rule(
    impl = _spm_pins_test_impl,
    attrs = {"revisions": attrs.dict(attrs.string(), attrs.string()), "_checker": _CHECKER},
)

def _npm_pins_test_impl(ctx: AnalysisContext) -> list[Provider]:
    tarballs = ctx.attrs.tarballs
    expected = ctx.actions.write_json("npm.json", {"tarballs": tarballs, "versions": ctx.attrs.versions})
    return _test(ctx, "npm-pins", expected, hidden = tarballs.values())

# Sources/meerkat-rules/bun.lock's integrity for each `package@version` is its tarball's, and
# Sources/meerkat-rules/package.json's devDependencies are `versions` (tools Buck takes from
# elsewhere, whose npm packages the editor installs).
npm_pins_test = rule(
    impl = _npm_pins_test_impl,
    attrs = {
        "tarballs": attrs.dict(attrs.string(), attrs.source()),
        "versions": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "_checker": _CHECKER,
    },
)

def _archives(ctx: AnalysisContext):
    archives = {name: archive[DefaultInfo].default_outputs[0] for name, archive in ctx.attrs.archives.items()}
    return ctx.actions.write_json("archives.json", archives), archives.values()

_ARCHIVES = attrs.dict(attrs.string(), attrs.dep())

def _spm_manifest_test_impl(ctx: AnalysisContext) -> list[Provider]:
    expected, archives = _archives(ctx)
    return _test(ctx, "spm-manifest", expected, hidden = archives)

# buck2/third_party/swift/modules.bzl is what each package's manifest at its
# pinned revision says: every module's settings, the traits each package
# builds with, and its deployment target.
spm_manifest_test = rule(
    impl = _spm_manifest_test_impl,
    attrs = {"archives": _ARCHIVES, "_checker": _CHECKER},
)

def _spm_tables_impl(ctx: AnalysisContext) -> list[Provider]:
    expected, archives = _archives(ctx)
    command = with_xcode_env([ctx.attrs._checker[RunInfo], "spm-tables", expected])
    return [DefaultInfo(), RunInfo(args = cmd_args(command, hidden = archives))]

# `buck2 run` it to rewrite buck2/third_party/swift/modules.bzl.
spm_tables = rule(
    impl = _spm_tables_impl,
    attrs = {"archives": _ARCHIVES, "_checker": _CHECKER},
)
