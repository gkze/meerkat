# The Swift toolchain: Xcode's swiftc for macOS on Apple silicon, the SDK it
# compiles against, and the per-mode flags every Swift target gets.
#
# The toolchain lives outside Buck's view (it is the installed Xcode), so
# Buck cannot hash it. `xcode_build` is part of every Swift action's
# environment instead: changing Xcode means changing `[swift] xcode_build` in
# .buckconfig, which invalidates every cached Swift action, and
# //buck2/rules/swift:xcode_test fails until the two agree.

SwiftToolchainInfo = provider(fields = {
    # Flags for every compile in this mode (optimization, debug info,
    # `-enable-testing`).
    "compile_flags": list[str],
    # The Xcode the tools come from, for those run through `xcrun`
    # (actool for resource bundles' asset catalogs).
    "developer_dir": str,
    # Shared clang module cache for SDK modules, which would otherwise be
    # rebuilt by every compile.
    "module_cache": str,
    # Where Xcode keeps the Testing framework and its interop libraries.
    "platform_frameworks": str,
    "platform_libraries": str,
    "sdk": str,
    "swiftc": RunInfo,
    # swift-testing's macro plugin (`@Test`, `#expect`). Xcode keeps it in a
    # subdirectory swiftc does not search by default; SwiftPM passes it as a
    # `-plugin-path` for test targets, and so does `swift_test`.
    "testing_plugins": str,
    # The target triple for the toolchain's minimum macOS; `triple(version)`
    # for another deployment target.
    "target": str,
    "triple": typing.Callable,
    "xcode_build": str,
})

def _triple(minimum_os: str) -> str:
    return "arm64-apple-macos" + minimum_os

def _swift_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    developer = ctx.attrs.developer_dir
    platform = developer + "/Platforms/MacOSX.platform"
    toolchain = developer + "/Toolchains/XcodeDefault.xctoolchain"
    swiftc = toolchain + "/usr/bin/swiftc"
    return [
        DefaultInfo(),
        SwiftToolchainInfo(
            compile_flags = ctx.attrs.compile_flags,
            developer_dir = developer,
            module_cache = ctx.attrs.module_cache,
            platform_frameworks = platform + "/Developer/Library/Frameworks",
            platform_libraries = platform + "/Developer/usr/lib",
            sdk = platform + "/Developer/SDKs/MacOSX.sdk",
            swiftc = RunInfo(args = [swiftc]),
            testing_plugins = toolchain + "/usr/lib/swift/host/plugins/testing",
            target = _triple(ctx.attrs.minimum_os),
            triple = _triple,
            xcode_build = ctx.attrs.xcode_build,
        ),
    ]

swift_toolchain = rule(
    impl = _swift_toolchain_impl,
    attrs = {
        "compile_flags": attrs.list(attrs.string(), default = []),
        "developer_dir": attrs.string(),
        "minimum_os": attrs.string(),
        "module_cache": attrs.string(),
        "xcode_build": attrs.string(),
    },
    is_toolchain_rule = True,
)
