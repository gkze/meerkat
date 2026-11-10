import Foundation
import MeerkatKit

/// The daemon's live configuration: `meerkat.json` in the rules directory.
///
/// What it governs is policy and limits, which the daemon applies while it
/// runs; what the daemon can do (its sources, effects and MCP surface) is
/// compiled in, and where it keeps things (`DaemonPaths`) is read at start.
/// Saving the file applies it within a second, without a restart.
///
/// `schema` is the one authority for the file's shape and ranges. The JSON
/// Schema editors use (`meerkat config schema`, and the copy the daemon
/// writes to `.meerkat/meerkat.schema.json`) is projected from it, and the
/// file is decoded through it (`ObjectSchema.decode`), as every input from
/// outside is. Every field is optional in the file; an absent one, a whole
/// section included, has the schema's default.
///
/// The file is data, never code: nothing in it runs, and rule code can write
/// neither the rules directory nor this file, wherever a symlink to it leads,
/// so no rule can widen the policy it runs under.
public struct MeerkatConfiguration: Codable, Sendable, Equatable {
    public var mcp: MCP
    public var samples: SampleBudget
    public var files: Files

    public init(mcp: MCP = .init(), samples: SampleBudget = .init(), files: Files = .init()) {
        self.mcp = mcp
        self.samples = samples
        self.files = files
    }

    /// The file's name, in the rules directory.
    public static let fileName = "meerkat.json"
    /// Where the daemon writes the JSON Schema, relative to the rules
    /// directory; `meerkat.json` names it in `$schema`.
    public static let schemaPath = RulesDirectoryLayout.supportDirectory + "/meerkat.schema.json"

    // MARK: - MCP

    public struct MCP: Codable, Sendable, Equatable {
        public var events: Events
        public var limits: Limits

        public init(events: Events = .init(), limits: Limits = .init()) {
            self.events = events
            self.limits = limits
        }

        /// Which event kinds MCP clients may sample: the built-in default,
        /// narrowed or widened.
        ///
        /// The default fails closed: a kind is allowed only when it needs no
        /// privacy permission and is not one of the raw kinds, which carry
        /// whatever other programs put in them. `allow` admits kinds the
        /// default denies; `deny` removes any kind, and wins.
        public struct Events: Codable, Sendable, Equatable {
            /// Kinds or `family.*` patterns allowed although the default
            /// denies them.
            public var allow: [String]
            /// Kinds or `family.*` patterns denied, whatever else allows them.
            public var deny: [String]

            public init(allow: [String] = [], deny: [String] = []) {
                self.allow = allow
                self.deny = deny
            }
        }

        public struct Limits: Codable, Sendable, Equatable {
            /// Ceiling on `events_sample`'s `maxSeconds` and `system_sample`'s `window`.
            public var sampleSeconds: Double
            /// Ceiling on `events_sample`'s `maxEvents`.
            public var sampleEvents: Int
            /// Most text one resource read or tool reply returns; a longer
            /// one is cut (`MCPService.bounded`). `events_sample` stops adding
            /// events at it instead.
            public var outputKiB: Int
            /// `events_sample` and `system_sample` calls one MCP session may run at once.
            public var concurrentSamples: Int

            public init(
                sampleSeconds: Double = 30, sampleEvents: Int = 500, outputKiB: Int = 1024, concurrentSamples: Int = 4
            ) {
                self.sampleSeconds = sampleSeconds
                self.sampleEvents = sampleEvents
                self.outputKiB = outputKiB
                self.concurrentSamples = concurrentSamples
            }

            public var outputBytes: Int { outputKiB * 1024 }
        }
    }

    // MARK: - Files

    /// What file churn (`fs.churn`, the Files card and page) watches when a
    /// subscription names no directory of its own.
    public struct Files: Codable, Sendable, Equatable {
        /// Absolute, in the form FSEvents reports (`eventPath`): `~` is
        /// expanded and symlinks resolved when the file is read.
        public var root: String
        /// Replaces the default exclusions when present.
        public var exclude: [String]

        public init(root: String = FileScope.standard.root, exclude: [String] = FileScope.standard.exclude) {
            self.root = root
            self.exclude = exclude
        }

        public var scope: FileScope { FileScope(root: root, exclude: exclude) }

        /// `root` and `exclude` in the form FSEvents reports.
        fileprivate func resolved() throws -> Files {
            Files(
                root: try eventPath(root, field: "root"),
                exclude: try exclude.map { try eventPath($0, field: "exclude") })
        }
    }

    // MARK: - Schema

    /// The file's schema. Kind patterns are enumerated from `catalog`, so a
    /// misspelt kind is a validation error, and editors complete them.
    public static func schema(_ catalog: EventCatalog = .standard) -> TypeSchema {
        .named("MeerkatConfiguration", objectSchema(catalog))
    }

    /// The defaults are read from the initialisers, so the Swift type and
    /// the file agree on them; a section's default is `{}`, its fields'.
    private static func objectSchema(_ catalog: EventCatalog) -> ObjectSchema {
        let kinds = catalog.kinds.map(\.name)
        var families: [String] = []
        for kind in catalog.kinds where !families.contains(kind.descriptor.family) {
            families.append(kind.descriptor.family)
        }
        let pattern = TypeSchema.enumeration(kinds + families.map { $0 + ".*" })
        let defaults = MeerkatConfiguration()
        let limits = defaults.mcp.limits
        typealias Field = ObjectSchema.Field
        let raw = (MCP.Events.rawKinds.sorted() + MCP.Events.rawFamilies.sorted().map { $0 + ".*" })
        let rawList = raw.dropLast().joined(separator: ", ") + (raw.count > 1 ? " and " : "") + (raw.last ?? "")
        let section: JSONValue = .object([:])
        return ObjectSchema([
            Field("$schema", .string, optional: true, doc: "The JSON Schema editors check this file against."),
            Field(
                "mcp",
                .named(
                    "MCPConfiguration",
                    ObjectSchema([
                        Field(
                            "events",
                            .named(
                                "MCPEvents",
                                ObjectSchema([
                                    Field(
                                        "allow", .array(pattern), default: [],
                                        doc:
                                            "Kinds or family.* patterns MCP clients may sample although the default denies them: kinds that need a privacy permission, and \(rawList). A permission kind still needs its grant, and is never prompted for."
                                    ),
                                    Field(
                                        "deny", .array(pattern), default: [],
                                        doc:
                                            "Kinds or family.* patterns MCP clients may not sample. Deny wins over allow."
                                    ),
                                ])), default: section),
                        Field(
                            "limits",
                            .named(
                                "MCPLimits",
                                ObjectSchema([
                                    Field(
                                        "sampleSeconds", .bounded(NumberBounds(1...300)),
                                        default: .number(limits.sampleSeconds),
                                        doc: "Longest events_sample, and longest system_sample window, in seconds"
                                    ),
                                    Field(
                                        "sampleEvents", .bounded(.integer(1...10_000)),
                                        default: .number(Double(limits.sampleEvents)),
                                        doc: "Most events one events_sample returns"),
                                    Field(
                                        "outputKiB", .bounded(.integer(16...16_384)),
                                        default: .number(Double(limits.outputKiB)),
                                        doc:
                                            "Most text one MCP resource read or tool reply returns, in KiB. A longer reply is cut; events_sample instead stops adding events at it."
                                    ),
                                    Field(
                                        "concurrentSamples", .bounded(.integer(1...32)),
                                        default: .number(Double(limits.concurrentSamples)),
                                        doc: "events_sample and system_sample calls one MCP session runs at once"
                                    ),
                                ])), default: section),
                    ])), default: section, doc: "What MCP clients (`meerkat mcp`) may sample, and how much."),
            Field(
                "samples",
                .named(
                    "SampleStoreConfiguration",
                    ObjectSchema([
                        Field(
                            "maxAgeDays", .bounded(.integer(1...3650)),
                            default: .number(Double(defaults.samples.maxAgeDays)),
                            doc: "Samples older than this many days are deleted"),
                        Field(
                            "maxMegabytes", .bounded(.integer(10...100_000)),
                            default: .number(Double(defaults.samples.maxMegabytes)),
                            doc: "The store is trimmed, oldest first, past this size in MB"),
                    ])), default: section, doc: "The sample store's budget (samples.db)."),
            Field(
                "files",
                .named(
                    "FilesConfiguration",
                    ObjectSchema([
                        Field(
                            "root", .string, default: .string(defaults.files.root),
                            doc:
                                "Directory file churn watches, absolute or starting with ~; by default the whole startup volume."
                        ),
                        Field(
                            "exclude", .array(.string),
                            default: .array(defaults.files.exclude.map(JSONValue.string)),
                            doc:
                                "Paths under root whose changes are not counted, absolute or starting with ~. Replaces the default list."
                        ),
                    ])), default: section,
                doc: "What file churn watches: the Files card and page, and fs.churn subscriptions without a root."),
        ])
    }

    /// The JSON Schema document for the file, as `meerkat config schema`
    /// prints it and the daemon writes it.
    public static func jsonSchema(_ catalog: EventCatalog = .standard) -> String {
        guard case .object(var document) = JSONSchema.document(schema(catalog)) else { return "{}" }
        document["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        document["title"] = "meerkat.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding a JSONValue cannot fail.
        let data = (try? encoder.encode(JSONValue.object(document))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Decoding

    public struct Invalid: Error, CustomStringConvertible, Equatable {
        public let problems: [String]
        public var description: String { problems.joined(separator: "; ") }
    }

    /// `data` as `objectSchema` admits it: undeclared fields named first,
    /// then every other problem, then the defaults filled; `null` is `{}`.
    /// Throws `Invalid` with what was found.
    public static func decode(_ data: Data, catalog: EventCatalog = .standard) throws -> MeerkatConfiguration {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            // JSONDecoder's own description is a debug dump; its underlying
            // error names the line and column.
            let detail =
                if case DecodingError.dataCorrupted(let context) = error, let underlying = context.underlyingError {
                    (underlying as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                        ?? underlying.localizedDescription
                } else {
                    error.localizedDescription
                }
            throw Invalid(problems: ["not valid JSON: \(detail)"])
        }
        do {
            var configuration = try objectSchema(catalog).decode(value, as: MeerkatConfiguration.self, at: "$")
            configuration.files = try configuration.files.resolved()
            return configuration
        } catch let mismatch as SchemaMismatch {
            throw Invalid(problems: mismatch.problems)
        } catch EventError.invalidParameters(let problem) {
            // A path the schema cannot check: relative, not ~.
            throw Invalid(problems: ["files: " + problem])
        }
    }
}

// MARK: - Status

/// What the daemon applies now and why: the effective configuration, and
/// the problem with the file when its last version could not be applied.
public struct ConfigurationStatus: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// No `meerkat.json`: every default applies.
        case defaults
        /// The file as it is now.
        case file
        /// The file's last version that applied; the current one has `problem`.
        case lastGood
    }

    /// The file's path.
    public let file: String
    public let source: Source
    public let effective: MeerkatConfiguration
    /// Why the file as it is now does not apply; nil when it does.
    public let problem: String?
    /// Unix epoch milliseconds when `effective` started to apply.
    public let appliedAt: Double

    public init(file: String, source: Source, effective: MeerkatConfiguration, problem: String?, appliedAt: Double) {
        self.file = file
        self.source = source
        self.effective = effective
        self.problem = problem
        self.appliedAt = appliedAt
    }
}

// MARK: - Event access

extension MeerkatConfiguration.MCP.Events {
    /// Arbitrary text from other programs: anything an app logs,
    /// notification names and payloads, device properties, and the reason a
    /// program gives for a power assertion. Every kind a rule must name to
    /// observe (`Observation.named`) is here, needs a permission, or is open
    /// to MCP for a reason MCPTests states, so a new one is decided, not
    /// left open by default.
    public static let rawKinds: Set<String> = [
        "log.entry", "darwin.notification", "distributed.notification", "power.assertions",
    ]
    public static let rawFamilies: Set<String> = ["iokit"]

    public static func deniedByDefault(_ descriptor: EventDescriptor) -> Bool {
        descriptor.permission != nil || rawKinds.contains(descriptor.name)
            || rawFamilies.contains(descriptor.family)
    }

    public func allows(_ descriptor: EventDescriptor) -> Bool {
        if Self.matches(deny, descriptor) { return false }
        return !Self.deniedByDefault(descriptor) || Self.matches(allow, descriptor)
    }

    /// Exact kinds, or `family.*`.
    static func matches(_ patterns: [String], _ descriptor: EventDescriptor) -> Bool {
        patterns.contains { $0 == descriptor.name || $0 == descriptor.family + ".*" }
    }
}
