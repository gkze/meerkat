import CryptoKit
import Foundation

// Checks that the files other tools read describe what Buck builds. Buck is
// the build; Package.swift and Package.resolved remain for SourceKit-LSP and
// Xcode, and Sources/meerkat-rules/bun.lock for the editor's TypeScript install, so each of
// them must agree with the BUCK files that own the same facts:
//
//   conformance spm-graph EXPECTED.json   Package.swift's targets, their
//                                         dependencies and their Swift
//                                         settings (warnings, upcoming
//                                         features) are Buck's Swift graph,
//                                         and its macOS is `[meerkat]
//                                         minimum_macos`
//   conformance spm-pins EXPECTED.json    Package.resolved pins the revisions
//                                         //buck2/third_party/swift builds
//   conformance spm-manifest ARCHIVES.json  buck2/third_party/swift/modules.bzl
//                                         is what each package manifest at its
//                                         pin says (Manifests.swift)
//   conformance spm-tables ARCHIVES.json  rewrites that file
//   conformance npm-pins EXPECTED.json    bun.lock's integrity for each npm
//                                         package is that of the tarball
//                                         //buck2/third_party/js builds from, and
//                                         package.json names the versions of
//                                         the tools it takes from GitHub
//
// EXPECTED.json is written by the test's rule (buck2/rules/conformance.bzl) from
// the BUCK files. Run from the repository root. Exit status: 0 when they
// agree, 1 listing each disagreement, 2 for bad arguments or input.

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func readJSON<T: Decodable>(_ type: T.Type, at path: String, json5: Bool = false) throws -> T {
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = json5
    do {
        return try decoder.decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        throw Failure(description: "\(path): \(error)")
    }
}

/// What a Swift target is compiled with beyond its sources: how warnings are
/// treated (`error`, or `default`) and its upcoming features, sorted.
struct SwiftSettings: Decodable, Equatable, CustomStringConvertible {
    let warnings: String
    let upcomingFeatures: [String]

    enum CodingKeys: String, CodingKey {
        case warnings
        case upcomingFeatures = "upcoming_features"
    }

    init(warnings: String, upcomingFeatures: [String]) {
        self.warnings = warnings
        self.upcomingFeatures = upcomingFeatures.sorted()
    }

    /// From the manifest's `treatAllWarnings` and `enableUpcomingFeature`.
    init(_ target: PackageManifest.Target) {
        var warnings = "default"
        var features: [String] = []
        for setting in target.settings where setting.tool == "swift" && setting.condition == nil {
            for (kind, argument) in setting.kind {
                guard let value = argument._0?.description else { continue }
                switch kind {
                case "treatAllWarnings": warnings = value
                case "enableUpcomingFeature": features.append(value)
                default: break
                }
            }
        }
        self.init(warnings: warnings, upcomingFeatures: features)
    }

    var description: String { "warnings \(warnings), upcoming features \(upcomingFeatures)" }
}

/// Every target in both, with the same dependencies and, for a Swift
/// target, the same settings, for the same macOS. A C target's settings are
/// not compared: Package.swift gives every target the Swift settings, which
/// clang ignores.
func checkGraph(expected path: String) throws -> [String] {
    struct Expected: Decodable {
        struct Target: Decodable {
            let deps: [String]
            /// None for a C target.
            let swift: SwiftSettings?
        }
        let graph: [String: Target]
        let minimumMacOS: String

        enum CodingKeys: String, CodingKey {
            case graph
            case minimumMacOS = "minimum_macos"
        }
    }
    let expected = try readJSON(Expected.self, at: path)
    let root = try dumpPackage(at: ".")
    let buck = expected.graph
    let manifest = Dictionary(uniqueKeysWithValues: root.targets.map { ($0.name, $0) })
    var problems: [String] = []
    let minimum = root.platforms.first { $0.platformName == "macos" }?.version
    if minimum != expected.minimumMacOS {
        problems.append(
            "[meerkat] minimum_macos is \(expected.minimumMacOS), Package.swift has \(minimum ?? "none")")
    }
    for name in Set(buck.keys).union(manifest.keys).sorted() {
        guard let buck = buck[name] else {
            problems.append("\(name): in Package.swift, not built by Buck")
            continue
        }
        guard let manifest = manifest[name] else {
            problems.append("\(name): built by Buck, not in Package.swift")
            continue
        }
        let dependencies = manifest.dependencies.map(\.name).sorted()
        if buck.deps != dependencies {
            problems.append("\(name): Buck depends on \(buck.deps), Package.swift on \(dependencies)")
        }
        if let settings = buck.swift, settings != SwiftSettings(manifest) {
            problems.append("\(name): Buck builds with \(settings), Package.swift with \(SwiftSettings(manifest))")
        }
    }
    return problems
}

/// Package.resolved's revision for each package Buck builds.
func checkSwiftPins(expected path: String) throws -> [String] {
    struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { let revision: String }
            let identity: String
            let state: State
        }
        let pins: [Pin]
    }
    let expected = try readJSON([String: String].self, at: path)
    let resolved = Dictionary(
        uniqueKeysWithValues: try readJSON(Resolved.self, at: "Package.resolved").pins.map {
            ($0.identity, $0.state.revision)
        })
    return expected.sorted(by: { $0.key < $1.key }).compactMap { identity, revision in
        switch resolved[identity] {
        case nil: return "\(identity): built by Buck at \(revision), not pinned in Package.resolved"
        case revision: return nil
        case let pinned?: return "\(identity): Buck builds \(revision), Package.resolved pins \(pinned)"
        }
    }
}

/// bun.lock's `integrity` for each `package@version` Buck builds, against
/// the SHA-512 of the tarball Buck downloaded; and package.json's version of
/// each tool Buck takes from a GitHub release instead.
func checkNPMPins(expected path: String) throws -> [String] {
    struct Expected: Decodable {
        let tarballs: [String: String]
        let versions: [String: String]
    }
    struct Lock: Decodable {
        /// Each entry is `[ "name@version", registry, metadata, integrity ]`.
        let packages: [String: [Entry]]
    }
    struct Entry: Decodable {
        let string: String?
        init(from decoder: any Decoder) throws {
            string = try? decoder.singleValueContainer().decode(String.self)
        }
    }
    struct Package: Decodable { let devDependencies: [String: String] }
    let expected = try readJSON(Expected.self, at: path)
    let lock = try readJSON(Lock.self, at: "Sources/meerkat-rules/bun.lock", json5: true)
    let package = try readJSON(Package.self, at: "Sources/meerkat-rules/package.json")
    var integrity: [String: String] = [:]
    for entry in lock.packages.values {
        let strings = entry.compactMap(\.string)
        if let spec = strings.first, let hash = strings.last(where: { $0.hasPrefix("sha512-") }) {
            integrity[spec] = hash
        }
    }
    var problems = try expected.tarballs.sorted(by: { $0.key < $1.key }).compactMap { spec, path -> String? in
        let tarball = try Data(contentsOf: URL(fileURLWithPath: path))
        let actual = "sha512-" + Data(SHA512.hash(data: tarball)).base64EncodedString()
        switch integrity[spec] {
        case nil: return "\(spec): built by Buck, not in Sources/meerkat-rules/bun.lock"
        case actual: return nil
        case let locked?: return "\(spec): Buck's tarball is \(actual), Sources/meerkat-rules/bun.lock has \(locked)"
        }
    }
    for (tool, version) in expected.versions.sorted(by: { $0.key < $1.key })
    where package.devDependencies[tool] != version {
        let installed = package.devDependencies[tool] ?? "none"
        problems.append("\(tool): Buck builds \(version), Sources/meerkat-rules/package.json has \(installed)")
    }
    return problems
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 2, let mode = arguments.first, let expected = arguments.last else {
    FileHandle.standardError.write(
        Data("usage: conformance spm-graph|spm-pins|spm-manifest|spm-tables|npm-pins EXPECTED.json\n".utf8))
    exit(2)
}
do {
    let problems: [String]
    switch mode {
    case "spm-graph": problems = try checkGraph(expected: expected)
    case "spm-pins": problems = try checkSwiftPins(expected: expected)
    case "spm-manifest": problems = try checkManifests(archives: expected)
    case "spm-tables": problems = try writeTables(archives: expected)
    case "npm-pins": problems = try checkNPMPins(expected: expected)
    default: throw Failure(description: "unknown check \(mode)")
    }
    for problem in problems { print(problem) }
    exit(problems.isEmpty ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("conformance: \(error)\n".utf8))
    exit(2)
}
