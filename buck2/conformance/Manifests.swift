import Foundation
import ToolProcess

// `conformance spm-manifest` and `spm-tables`: buck2/third_party/swift/modules.bzl,
// derived from the package manifests. For every module the repository reaches
// from Package.swift's products, the settings SwiftPM would build its target
// with, from `swift package dump-package` of the pinned archive: directory,
// kind, dependencies split into modules and macro plugins (with platform and
// trait conditions applied), defines, upcoming and experimental features,
// other flags, excludes, language mode; and for every package, its enabled
// traits and macOS deployment target.

/// The generated tables, from the repository root.
let tablesPath = "buck2/third_party/swift/modules.bzl"

/// One module's entry in the tables.
struct ModuleEntry: Codable, Equatable {
    var package: String
    var path: String
    var kind: String
    var languageMode: String?
    var deps: [String]?
    var macros: [String]?
    var defines: [String]?
    var upcomingFeatures: [String]?
    var experimentalFeatures: [String]?
    var swiftFlags: [String]?
    var exclude: [String]?
    var srcs: [String]?
    /// A C target's public headers directory, when not `include`.
    var include: String?
    /// The headers of a C target whose public headers directory has no
    /// module map (SwiftPM generates one over them).
    var headers: [String]?
    var cDefines: [String]?
    var headerSearchPaths: [String]?
    var linkedLibraries: [String]?
    var resources: [Resource]?

    struct Resource: Codable, Equatable {
        /// `copy` (kept as is) or `process` (an asset catalog, compiled).
        var rule: String
        var path: String
    }

    enum CodingKeys: String, CodingKey {
        case package, path, kind, deps, macros, defines, exclude, srcs, include, headers, resources
        case languageMode = "language_mode"
        case upcomingFeatures = "upcoming_features"
        case experimentalFeatures = "experimental_features"
        case swiftFlags = "swift_flags"
        case cDefines = "c_defines"
        case headerSearchPaths = "header_search_paths"
        case linkedLibraries = "linked_libraries"
    }
}

/// The parts of `swift package dump-package` output this check reads.
struct PackageManifest: Decodable {
    struct Version: Decodable { let _version: String }
    struct Platform: Decodable {
        let platformName: String
        let version: String
    }
    struct Trait: Decodable {
        let name: String
        let enabledTraits: [String]
    }
    struct Condition: Decodable {
        let platformNames: [String]?
        let traits: [String]?
    }
    struct Dependency: Decodable {
        struct SourceControl: Decodable {
            struct Request: Decodable {
                let name: String
                let condition: Condition?
            }
            /// `{"revision": [sha]}`, `{"exact": [version]}` or a range,
            /// which neither field reads.
            struct Requirement: Decodable {
                let revision: [String]?
                let exact: [String]?
            }
            let identity: String
            let traits: [Request]?
            let requirement: Requirement?
        }
        let sourceControl: [SourceControl]?
    }
    struct Product: Decodable {
        let name: String
        let targets: [String]
    }
    struct Target: Decodable {
        let name: String
        let type: String
        let path: String?
        let exclude: [String]
        let sources: [String]?
        let publicHeadersPath: String?
        let resources: [ResourceDeclaration]?
        let dependencies: [TargetDependency]
        let settings: [Setting]
    }
    /// `{"path": "Resources", "rule": {"copy": {}}}`.
    struct ResourceDeclaration: Decodable {
        let path: String
        let rule: [String: Ignored]
    }
    struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {}
    }
    /// `{"byName": [name, condition]}`, `{"target": [name, condition]}` or
    /// `{"product": [name, package, moduleAliases, condition]}`.
    struct TargetDependency: Decodable {
        let kind: String
        let name: String
        let package: String?
        let condition: Condition?

        init(from decoder: any Decoder) throws {
            let entry = try decoder.singleValueContainer().decode([String: [Element]].self)
            guard let (kind, elements) = entry.first, let name = elements.first?.string else {
                throw Failure(description: "unreadable target dependency \(entry)")
            }
            self.kind = kind
            self.name = name
            package = kind == "product" ? elements.dropFirst().first?.string : nil
            condition = elements.last?.condition
        }

        enum Element: Decodable {
            case string(String)
            case condition(Condition)
            case other

            var string: String? { if case .string(let value) = self { value } else { nil } }
            var condition: Condition? { if case .condition(let value) = self { value } else { nil } }

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    self = .string(string)
                } else if let condition = try? container.decode(Condition.self), condition.platformNames != nil {
                    self = .condition(condition)
                } else {
                    self = .other
                }
            }
        }
    }
    /// `{"tool": "swift", "kind": {"define": {"_0": "NAME"}}, "condition": …}`.
    struct Setting: Decodable {
        let tool: String
        let kind: [String: Argument]
        let condition: Condition?

        struct Argument: Decodable {
            let _0: Value?
        }
        enum Value: Decodable {
            case string(String)
            case strings([String])
            var description: String {
                switch self {
                case .string(let value): value
                case .strings(let values): values.joined(separator: " ")
                }
            }
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) {
                    self = .string(string)
                } else {
                    self = .strings(try container.decode([String].self))
                }
            }
        }
    }

    let toolsVersion: Version
    let swiftLanguageModes: [String]?
    let swiftLanguageVersions: [String]?
    let platforms: [Platform]
    let traits: [Trait]?
    let dependencies: [Dependency]
    let products: [Product]
    let targets: [Target]
}

func dumpPackage(at directory: String) throws -> PackageManifest {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("conformance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    // The Xcode is DEVELOPER_DIR's, which the rules set (conformance.bzl).
    let output = try Subprocess(
        "/usr/bin/xcrun",
        ["swift", "package", "dump-package", "--package-path", directory, "--scratch-path", scratch.path]
    ).output()
    do {
        return try JSONDecoder().decode(PackageManifest.self, from: Data(output.utf8))
    } catch {
        throw Failure(description: "\(directory): \(error)")
    }
}

/// The traits each package is built with: every dependent's requests (a
/// dependency without `traits` asks for its defaults), conditions applied,
/// expanded through each trait's `enabledTraits`, until nothing changes.
func enabledTraits(root: PackageManifest, packages: [String: PackageManifest]) -> [String: Set<String>] {
    var requested: [String: Set<String>] = [:]
    var enabled: [String: Set<String>] = [:]
    func requests(from manifest: PackageManifest, enabled own: Set<String>) {
        for dependency in manifest.dependencies.flatMap({ $0.sourceControl ?? [] }) {
            let names =
                dependency.traits.map { traits in
                    traits.filter { request in
                        request.condition?.traits.map { !own.isDisjoint(with: $0) } ?? true
                    }.map(\.name)
                } ?? ["default"]
            requested[dependency.identity, default: []].formUnion(names)
        }
    }
    func expand(_ names: Set<String>, in manifest: PackageManifest) -> Set<String> {
        let declared = Dictionary(uniqueKeysWithValues: (manifest.traits ?? []).map { ($0.name, $0.enabledTraits) })
        var result: Set<String> = []
        var pending = Array(names)
        while let name = pending.popLast() {
            guard result.insert(name).inserted else { continue }
            pending += declared[name] ?? []
        }
        result.remove("default")
        return result
    }
    requests(from: root, enabled: [])
    var changed = true
    while changed {
        changed = false
        for (identity, manifest) in packages {
            let now = expand(requested[identity] ?? ["default"], in: manifest)
            if now != enabled[identity] {
                enabled[identity] = now
                changed = true
            }
            requests(from: manifest, enabled: now)
        }
    }
    return enabled
}

func applies(_ condition: PackageManifest.Condition?, traits: Set<String>) -> Bool {
    guard let condition else { return true }
    if let platforms = condition.platformNames, !platforms.isEmpty, !platforms.contains("macos") { return false }
    if let required = condition.traits, !required.isEmpty, traits.isDisjoint(with: required) { return false }
    return true
}

/// The tables' text, and what stopped it being complete.
func deriveTables(archives path: String) throws -> (text: String, problems: [String]) {
    let archives = try readJSON([String: String].self, at: path)
    var manifests: [String: PackageManifest] = [:]
    for (identity, archive) in archives {
        manifests[identity] = try dumpPackage(at: archive)
    }
    let root = try dumpPackage(at: ".")
    let traits = enabledTraits(root: root, packages: manifests)
    var problems: [String] = []

    var pending: [(name: String, package: String)] = []
    for target in root.targets {
        for dependency in target.dependencies where applies(dependency.condition, traits: []) {
            if dependency.kind != "product", root.targets.contains(where: { $0.name == dependency.name }) { continue }
            guard let (identity, _, product) = findProduct(dependency.name, package: dependency.package, in: manifests)
            else {
                problems.append("\(target.name) depends on \(dependency.name), which no package in PACKAGES provides")
                continue
            }
            pending += product.targets.map { ($0, identity) }
        }
    }
    var modules: [String: ModuleEntry] = [:]
    while let (name, package) = pending.popLast() {
        guard modules[name] == nil else { continue }
        guard let manifest = manifests[package], let archive = archives[package],
            let target = manifest.targets.first(where: { $0.name == name })
        else {
            problems.append("\(name): \(package) has no such target")
            continue
        }
        let derived = try derive(
            target, in: manifest, package: package, archive: archive,
            traits: traits[package] ?? [], manifests: manifests)
        for problem in derived.problems { problems.append("\(name): \(problem)") }
        modules[name] = derived.module
        pending += derived.dependencies
    }

    let minimum = manifests.mapValues { manifest in
        manifest.platforms.first { $0.platformName == "macos" }?.version ?? "10.13"
    }
    let enabled = traits.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }
    let text = """
        # @generated from each package's manifest at its pinned revision. Do not edit;
        # run: buck2 run //buck2/third_party/swift:regenerate

        TRAITS = \(try starlark(enabled))

        MINIMUM_MACOS = \(try starlark(minimum))

        MODULES = \(try starlark(modules))

        """
    return (text, problems)
}

/// `value` as JSON, which is a Starlark literal here: only strings, lists and
/// dictionaries.
func starlark(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// The problems deriving the tables found, or that the checked-in tables differ.
func checkManifests(archives path: String) throws -> [String] {
    let (text, problems) = try deriveTables(archives: path)
    let current = try? String(contentsOfFile: tablesPath, encoding: .utf8)
    guard current == text else {
        return problems + ["\(tablesPath) is stale; regenerate with: buck2 run //buck2/third_party/swift:regenerate"]
    }
    return problems
}

/// Rewrites the checked-in tables, unless deriving them found problems.
func writeTables(archives path: String) throws -> [String] {
    let (text, problems) = try deriveTables(archives: path)
    if problems.isEmpty { try text.write(toFile: tablesPath, atomically: true, encoding: .utf8) }
    return problems
}

/// The module entry the tables should have for `target`.
func derive(
    _ target: PackageManifest.Target, in manifest: PackageManifest, package: String, archive: String,
    traits: Set<String>, manifests: [String: PackageManifest]
) throws -> (module: ModuleEntry, dependencies: [(name: String, package: String)], problems: [String]) {
    var problems: [String] = []
    let path = target.path ?? "Sources/\(target.name)"
    let kind: String
    switch target.type {
    case "macro": kind = "macro"
    case "system": kind = "system"
    case "binary": kind = "binary"
    case "regular":
        kind = try containsSwift(URL(fileURLWithPath: archive).appendingPathComponent(path)) ? "library" : "c"
    default:
        kind = target.type
        problems.append("unsupported target type \(target.type)")
    }

    var deps: [String] = []
    var macros: [String] = []
    var dependencies: [(name: String, package: String)] = []
    for dependency in target.dependencies where applies(dependency.condition, traits: traits) {
        // A product names its targets; `byName` is a target of this package
        // or else a product of a dependency.
        let resolved: [(name: String, package: String, owner: PackageManifest)]
        if dependency.kind != "product", manifest.targets.contains(where: { $0.name == dependency.name }) {
            resolved = [(dependency.name, package, manifest)]
        } else if let (identity, other, product) = findProduct(
            dependency.name, package: dependency.package, in: manifests)
        {
            resolved = product.targets.map { ($0, identity, other) }
        } else {
            problems.append("depends on \(dependency.name), which no package in PACKAGES provides")
            continue
        }
        for (name, identity, owner) in resolved {
            dependencies.append((name, identity))
            if owner.targets.first(where: { $0.name == name })?.type == "macro" {
                macros.append(name)
            } else {
                deps.append(name)
            }
        }
    }

    var defines: [String] = []
    var upcoming: [String] = []
    var experimental: [String] = []
    var flags: [String] = []
    var languageMode: String?
    for setting in target.settings where setting.tool == "swift" && applies(setting.condition, traits: traits) {
        for (kind, argument) in setting.kind {
            let value = argument._0?.description ?? ""
            switch kind {
            case "define": defines.append(value)
            case "enableUpcomingFeature": if !upcoming.contains(value) { upcoming.append(value) }
            case "enableExperimentalFeature": experimental.append(value)
            case "strictMemorySafety": flags.append("-strict-memory-safety")
            // Passed through unchanged, as SwiftPM passes a dependency's
            // (swift-log's `-Xfrontend -require-explicit-sendable`).
            case "unsafeFlags":
                switch argument._0 {
                case .strings(let values)?: flags.append(contentsOf: values)
                case .string(let value)?: flags.append(value)
                case nil: break
                }
            case "swiftLanguageMode": languageMode = value
            default: problems.append("unsupported swift setting \(kind)")
            }
        }
    }
    var cDefines: [String] = []
    var headerSearchPaths: [String] = []
    var linkedLibraries: [String] = []
    for setting in target.settings where applies(setting.condition, traits: traits) {
        for (kind, argument) in setting.kind {
            let value = argument._0?.description ?? ""
            switch (setting.tool, kind) {
            case ("swift", _): break
            case ("c", "define"): cDefines.append(value)
            case ("c", "headerSearchPath"): headerSearchPaths.append(value)
            case ("linker", "linkedLibrary"): linkedLibraries.append(value)
            default: problems.append("unsupported \(setting.tool) setting \(kind)")
            }
        }
    }

    let modes = (manifest.swiftLanguageModes ?? manifest.swiftLanguageVersions ?? []).compactMap { Int($0) }
    let packageMode = modes.max().map(String.init) ?? (manifest.toolsVersion._version.hasPrefix("5") ? "5" : "6")
    let mode = languageMode ?? packageMode

    func nonEmpty<T>(_ values: [T]) -> [T]? { values.isEmpty ? nil : values }
    let directory = URL(fileURLWithPath: archive).appendingPathComponent(path)
    let isC = kind == "c"
    let swift = kind == "library" || kind == "macro"
    let include = target.publicHeadersPath ?? "include"
    let module = ModuleEntry(
        package: package, path: path, kind: kind, languageMode: swift && mode != "6" ? mode : nil,
        deps: swift ? nonEmpty(deps) : nil, macros: nonEmpty(macros),
        defines: nonEmpty(defines), upcomingFeatures: nonEmpty(upcoming),
        experimentalFeatures: nonEmpty(experimental), swiftFlags: nonEmpty(flags),
        exclude: swift ? nonEmpty(target.exclude) : nil,
        srcs: isC ? try cSources(directory, sources: target.sources, exclude: target.exclude) : nil,
        include: isC && include != "include" ? include : nil,
        headers: isC ? try generatedModuleHeaders(directory.appendingPathComponent(include)) : nil,
        cDefines: nonEmpty(cDefines), headerSearchPaths: nonEmpty(headerSearchPaths),
        linkedLibraries: nonEmpty(linkedLibraries),
        resources: swift ? nonEmpty(try resources(of: target, in: directory)) : nil)
    return (module, dependencies, problems)
}

func findProduct(_ name: String, package: String?, in manifests: [String: PackageManifest])
    -> (identity: String, manifest: PackageManifest, product: PackageManifest.Product)?
{
    for (identity, manifest) in manifests.sorted(by: { $0.key < $1.key })
    where package == nil || package?.lowercased() == identity {
        if let product = manifest.products.first(where: { $0.name == name }) {
            return (identity, manifest, product)
        }
    }
    return nil
}

/// `url`'s path below `directory`. Both are resolved first: an enumerator can
/// spell a path through a symbolic link differently from the directory it was
/// given (`/tmp`, `/private/tmp`), and which spelling depends on the toolchain.
func relativePath(_ url: URL, to directory: URL) -> String {
    let base = directory.resolvingSymlinksInPath().pathComponents
    return url.resolvingSymlinksInPath().pathComponents.dropFirst(base.count).joined(separator: "/")
}

/// A C target's C and Objective-C sources, relative to its directory: under
/// its `sources` (default: the whole directory), less `exclude`.
func cSources(_ directory: URL, sources: [String]?, exclude: [String]) throws -> [String] {
    let excluded = exclude.map { relativePath(directory.appendingPathComponent($0), to: directory) }
    var found: [String] = []
    for root in (sources ?? ["."]).map({ directory.appendingPathComponent($0) }) {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let path = relativePath(url, to: directory)
            if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            if ["c", "m"].contains(url.pathExtension) {
                found.append(path)
            }
        }
    }
    return found.sorted()
}

/// The headers SwiftPM's generated module map covers, relative to the
/// public headers directory; nil when the package ships its own module map.
func generatedModuleHeaders(_ include: URL) throws -> [String]? {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: include.appendingPathComponent("module.modulemap").path) { return nil }
    var headers: [String] = []
    let enumerator = fileManager.enumerator(at: include, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "h" else { continue }
        headers.append(relativePath(url, to: include))
    }
    return headers.sorted()
}

/// A target's resources: those it declares, and the asset catalogs SwiftPM
/// compiles without being asked (the only implicitly processed kind these
/// packages have). Not privacy manifests (`PrivacyInfo.xcprivacy`), which
/// no code reads and which matter only to App Store submission, so they are
/// not built (buck2/third_party/swift/BUCK).
func resources(of target: PackageManifest.Target, in directory: URL) throws -> [ModuleEntry.Resource] {
    var found = (target.resources ?? []).filter { !$0.path.hasSuffix(".xcprivacy") }.map { declaration in
        ModuleEntry.Resource(rule: declaration.rule.keys.first ?? "process", path: declaration.path)
    }
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        if url.pathExtension == "xcassets" {
            enumerator?.skipDescendants()
            let path = relativePath(url, to: directory)
            if !found.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                found.append(.init(rule: "process", path: path))
            }
        }
    }
    return found
}

func containsSwift(_ directory: URL) throws -> Bool {
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        if url.pathExtension == "swift" { return true }
    }
    return false
}
