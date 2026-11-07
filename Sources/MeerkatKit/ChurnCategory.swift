import Foundation

/// Classifies a changed path into "content a human authored" versus "content
/// a tool generated". Used to decide which directories deserve to be excluded
/// from Spotlight, instead of guessing.
///
/// Directories are matched as whole path components and extensions against
/// the item's own name, so `~/.aws/config` is not a static library and
/// `x.logger.ts` is not a log. The first category whose rule matches wins,
/// in declaration order.
public enum ChurnCategory: String, CaseIterable, Sendable {
    case vcsMetadata = "vcs_metadata"
    case packages
    case buildOutput = "build_output"
    case caches
    case logs
    case binaryArtifacts = "binary_artifacts"
    case appMetadata = "app_metadata"
    case authored
    case other

    /// What marks a path as one category.
    private struct Rule {
        /// Runs of whole components, like `target/debug`.
        var directories: [String] = []
        /// Extensions of the item's own name, without the dot.
        var extensions: Set<String> = []
        /// Extensions of any component: bundles such as `Foo.dSYM/…`.
        var bundles: Set<String> = []
        /// The item's whole name.
        var names: Set<String> = []
    }

    private var rule: Rule {
        switch self {
        case .vcsMetadata: Rule(directories: [".git", ".hg", ".svn", ".jj"])
        case .packages:
            Rule(directories: [
                "node_modules", "vendor", "site-packages", ".venv", "venv", "Pods", ".pnpm-store", "bower_components",
            ])
        case .buildOutput:
            Rule(
                directories: [
                    "dist", "build", ".build", "DerivedData", "zig-cache", "zig-out", "target/debug",
                    "target/release", ".next", ".nuxt", ".turbo", ".cache/build",
                ],
                // Nix's out-link: a link into /nix/store, so FSEvents reports
                // the link itself and nothing under it. Multi-output links
                // (`result-bin`) are left out: by name they can't be told
                // from a `result-summary.pdf` or a `result-cache` folder.
                names: ["result"])
        case .caches:
            Rule(directories: [
                "Caches", ".cache", "tmp", "TemporaryItems", ".Trash", "Library/Metadata", ".npm/_cacache",
                ".cargo/registry", ".rustup", ".gradle", ".m2",
            ])
        case .logs: Rule(directories: ["Logs", "log", "DiagnosticReports"], extensions: ["log"])
        case .binaryArtifacts:
            Rule(
                extensions: ["o", "a", "so", "dylib", "class", "pyc", "rlib", "rmeta", "wasm", "woff2"],
                bundles: ["dSYM"])
        case .appMetadata:
            Rule(
                directories: [
                    "Preferences", "Saved Application State", "HTTPStorages", "Group Containers",
                    "Metadata/CoreSpotlight", "Biome", "Application Support",
                ],
                names: [".DS_Store"])
        case .authored:
            Rule(extensions: [
                "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "c", "h", "cc", "cpp", "m", "mm", "java", "kt",
                "rb", "sh", "zsh", "nix", "md", "txt", "json", "yaml", "yml", "toml", "sql", "html", "css", "lock",
            ])
        case .other: Rule()
        }
    }

    public static func classify(_ path: String) -> ChurnCategory {
        let components = path.split(separator: "/").map(String.init)
        // Slashes on both ends, so a run of components matches only whole
        // components, the item's own name included.
        let delimited = "/" + components.joined(separator: "/") + "/"
        let name = components.last ?? ""
        let nameExtension = Self.pathExtension(name)
        let extensions = Set(components.compactMap(Self.pathExtension))
        return allCases.first { category in
            let rule = category.rule
            return rule.directories.contains { delimited.contains("/\($0)/") }
                || nameExtension.map(rule.extensions.contains) == true
                || !rule.bundles.isDisjoint(with: extensions)
                || rule.names.contains(name)
        } ?? .other
    }

    /// The text after a name's last dot. A leading dot starts a hidden name
    /// (`.config`), not an extension.
    private static func pathExtension(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let suffix = name[name.index(after: dot)...]
        return suffix.isEmpty ? nil : String(suffix)
    }
}
