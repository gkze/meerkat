// swift-tools-version:6.4
import PackageDescription

// Buck builds this repository (the BUCK files; docs/building.md). This
// manifest declares the same Swift targets, with the same dependencies and
// linker settings, for SourceKit-LSP and Xcode; //:package_swift_test fails
// when it and the BUCK files disagree, and //buck2/third_party/swift:pins_test
// when Package.resolved and //buck2/third_party/swift pin different revisions
// or a version or revision required here is not the one pinned. What each
// target is for is in its BUCK file.

/// Where the unsafe flags below find meerkatd's Rust, one static library
/// (the rule runtime, Sources/meerkat-runtime), for
/// building with SwiftPM anyway:
///
///     buck2 build @buck2/mode/release '//Sources/meerkat-runtime:meerkat_runtime[staticlib]' \
///         --out .build/cargo/release/libmeerkat_runtime.a
///
/// Its Swift bindings (Sources/meerkat-runtime/) are generated from
/// that library by Sources/meerkat-runtime/bindgen and checked in; `Tools/check` fails when
/// they are stale.
let runtimeLibraries = Context.packageDirectory + "/.build/cargo/release"

let package = Package(
    name: "Meerkat",
    // `[meerkat] minimum_macos` in .buckconfig; //:package_swift_test.
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "MeerkatKit", targets: ["MeerkatKit"]),
        .executable(name: "meerkat", targets: ["meerkat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/pointfreeco/sqlite-data.git", from: "1.12.1"),
        // D1 (docs/design/mcp.md): the official MCP Swift SDK with its open
        // 2026-07-28 pull request (modelcontextprotocol/swift-sdk#314) at that
        // PR's head commit, from its author's repository, until a release carries
        // 2026-07-28. Pinned by revision: the SDK depends on a branch
        // (swift-docc-plugin), which SwiftPM refuses under a version requirement.
        .package(
            url: "https://github.com/romanbsd/swift-sdk.git",
            revision: "aa545cb891262979cd800170b6037143d6409d02"),
        // The MCP transport names swift-log's `Logger` (the SDK's `Transport`
        // requires one).
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2"),
        // The rule editor (docs/design/rule-editor.md): CodeEditSourceEditor
        // for the view, ChimeHQ's LanguageServerProtocol (over JSONRPC) for
        // tsrs's language server. The text view and the languages are named
        // too because the editor uses their types (`Emphasis`,
        // `CodeLanguage`); CodeEditSourceEditor pins the languages exactly.
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor.git", from: "0.15.2"),
        .package(url: "https://github.com/CodeEditApp/CodeEditTextView.git", from: "0.12.1"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol.git", from: "0.14.2"),
        .package(url: "https://github.com/ChimeHQ/JSONRPC.git", from: "0.9.2"),
    ],
    targets: [
        .target(name: "MeerkatKit"),
        .target(
            name: "MeerkatStore",
            dependencies: [
                "MeerkatKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(name: "MeerkatIPC", dependencies: ["MeerkatKit"]),
        .target(name: "CICU", linkerSettings: [.linkedLibrary("icucore")]),
        .target(name: "MeerkatRules", dependencies: ["MeerkatKit"]),
        .target(
            name: "CMeerkatRuntime",
            path: "Sources/meerkat-runtime/CMeerkatRuntime",
            linkerSettings: [
                .unsafeFlags(["-L", runtimeLibraries, "-lmeerkat_runtime"]),
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedFramework("CoreServices"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "MeerkatRuntimeBindings", dependencies: ["CMeerkatRuntime"],
            path: "Sources/meerkat-runtime/MeerkatRuntimeBindings"),
        .target(
            name: "MeerkatDaemon",
            dependencies: [
                "MeerkatKit", "MeerkatIPC", "MeerkatStore", "MeerkatRules", "MeerkatRuntimeBindings", "CICU",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(name: "meerkatd", dependencies: ["MeerkatDaemon"]),
        .target(name: "MeerkatAgent", dependencies: ["MeerkatIPC", "MeerkatKit"]),
        .target(name: "MeerkatNetworkFilter"),
        .executableTarget(name: "MeerkatNetworkFilterExtension", dependencies: ["MeerkatNetworkFilter"]),
        .executableTarget(
            name: "meerkat",
            dependencies: [
                "MeerkatKit",
                "MeerkatStore",
                "MeerkatIPC",
                "MeerkatAgent",
                "MeerkatRules",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "MeerkatApp",
            dependencies: [
                "MeerkatKit", "MeerkatIPC", "MeerkatAgent", "MeerkatRules",
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditTextView", package: "CodeEditTextView"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
                .product(name: "JSONRPC", package: "JSONRPC"),
            ]
        ),
        .testTarget(
            name: "MeerkatAppTests",
            dependencies: [
                "MeerkatApp", "MeerkatAgent", "MeerkatKit", "MeerkatIPC", "MeerkatRules",
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
            ]),
        .testTarget(
            name: "MeerkatKitTests",
            dependencies: [
                "MeerkatKit",
                "MeerkatStore",
                // The schema conformance test compares the migrated schema
                // (GRDB) with the `@Table` column metadata (SQLiteData).
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(name: "MeerkatIPCTests", dependencies: ["MeerkatIPC", "MeerkatKit", "MeerkatNetworkFilter"]),
        .testTarget(name: "MeerkatAgentTests", dependencies: ["MeerkatAgent", "MeerkatIPC", "MeerkatKit"]),
        .testTarget(name: "MeerkatNetworkFilterTests", dependencies: ["MeerkatNetworkFilter"]),
        .testTarget(
            name: "CLITests",
            dependencies: [
                "meerkat",
                "MeerkatAgent",
                "MeerkatIPC",
                "MeerkatKit",
                "MeerkatRules",
                "MeerkatStore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The icon document is the bundler's input, compiled by actool, not a
        // SwiftPM resource; parts.bzl is Buck's.
        .executableTarget(
            name: "bundle",
            dependencies: [
                "MeerkatIPC", "MeerkatKit", "MeerkatRules", "ReleaseVersion", "ToolProcess",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/Bundler",
            exclude: ["AppIcon.icon", "parts.bzl"]
        ),
        .target(name: "ReleaseVersion", path: "Tools/ReleaseVersion"),
        .target(name: "ToolProcess", path: "Tools/ToolProcess"),
        .executableTarget(
            name: "release",
            dependencies: [
                "ReleaseVersion", "ToolProcess", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/Release"
        ),
        .testTarget(name: "ReleaseVersionTests", dependencies: ["ReleaseVersion"]),
        .testTarget(
            name: "MeerkatDaemonTests",
            dependencies: [
                "MeerkatDaemon", "MeerkatRules", "MeerkatRuntimeBindings", "MeerkatIPC", "MeerkatKit", "MeerkatStore",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// Every Swift target builds with warnings as errors and the upcoming features
// that only add compile-time checks, as buck2/rules/meerkat.bzl builds it
// (//:package_swift_test compares them). Features that change runtime behaviour
// (NonisolatedNonsendingByDefault, InferIsolatedConformances) and those that
// need source-wide annotation (InternalImportsByDefault, strict memory safety)
// are left for a deliberate migration. Clang targets ignore Swift settings.
// The generated modules (the bindings and their C header, checked in) omit
// ExistentialAny only, which the generator does not write.
let generatedModules: Set = ["CMeerkatRuntime", "MeerkatRuntimeBindings"]
for target in package.targets {
    let generated = generatedModules.contains(target.name)
    // Each module directory also holds its BUCK file, which SwiftPM would
    // otherwise report as unhandled. The generated modules' directories have
    // none.
    if !generated {
        target.exclude += ["BUCK"]
    }
    target.swiftSettings =
        (target.swiftSettings ?? []) + [.treatAllWarnings(as: .error)]
        + (generated ? [] : [.enableUpcomingFeature("ExistentialAny")]) + [
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("ImmutableWeakCaptures"),
        ]
}
