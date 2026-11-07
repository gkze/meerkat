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
/// daemon validates the file against it before decoding. Every field is
/// optional in the file; an absent one keeps its default.
///
/// The file is data, never code: nothing in it runs, and rule code can write
/// neither the rules directory nor this file, wherever a symlink to it leads,
/// so no rule can widen the policy it runs under.
public struct MeerkatConfiguration: Codable, Sendable, Equatable {
    public var mcp: MCP
    public var samples: Samples
    public var files: Files

    public init(mcp: MCP = .init(), samples: Samples = .init(), files: Files = .init()) {
        self.mcp = mcp
        self.samples = samples
        self.files = files
    }

    /// The file's name, in the rules directory.
    public static let fileName = "meerkat.json"
    /// Where the daemon writes the JSON Schema, relative to the rules
    /// directory; `meerkat.json` names it in `$schema`.
    public static let schemaPath = ".meerkat/meerkat.schema.json"

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

    // MARK: - Samples

    /// The sample store's own budget, whoever records into it. A rule's
    /// `store.record({ retain })` bounds its own label within this.
    public struct Samples: Codable, Sendable, Equatable {
        /// Samples older than this are deleted.
        public var maxAgeDays: Int
        /// The store is trimmed, oldest first, when it grows past this.
        public var maxMegabytes: Int

        public init(maxAgeDays: Int = SampleBudget.maxAgeDays, maxMegabytes: Int = SampleBudget.maxMegabytes) {
            self.maxAgeDays = maxAgeDays
            self.maxMegabytes = maxMegabytes
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
        let kinds = catalog.kinds.map(\.name)
        var families: [String] = []
        for kind in catalog.kinds where !families.contains(kind.descriptor.family) {
            families.append(kind.descriptor.family)
        }
        let pattern = TypeSchema.enumeration(kinds + families.map { $0 + ".*" })
        let defaults = MeerkatConfiguration()
        let limits = defaults.mcp.limits
        return .named(
            "MeerkatConfiguration",
            ObjectSchema([
                .init("$schema", .string, optional: true, doc: "The JSON Schema editors check this file against."),
                .init(
                    "mcp",
                    .named(
                        "MCPConfiguration",
                        ObjectSchema([
                            .init(
                                "events",
                                .named(
                                    "MCPEvents",
                                    ObjectSchema([
                                        .init(
                                            "allow", .array(pattern), optional: true,
                                            doc:
                                                "Kinds or family.* patterns MCP clients may sample although the default denies them: kinds that need a privacy permission, and log.entry, darwin.notification, distributed.notification and iokit.*. A permission kind still needs its grant, and is never prompted for."
                                        ),
                                        .init(
                                            "deny", .array(pattern), optional: true,
                                            doc:
                                                "Kinds or family.* patterns MCP clients may not sample. Deny wins over allow."
                                        ),
                                    ])), optional: true),
                            .init(
                                "limits",
                                .named(
                                    "MCPLimits",
                                    ObjectSchema([
                                        .init(
                                            "sampleSeconds", .bounded(NumberBounds(minimum: 1, maximum: 300)),
                                            optional: true,
                                            doc:
                                                "Longest events_sample, and longest system_sample window, in seconds: 1 to 300, default \(NumberBounds.format(limits.sampleSeconds))."
                                        ),
                                        .init(
                                            "sampleEvents", .bounded(.integer(1...10_000)), optional: true,
                                            doc:
                                                "Most events one events_sample returns: 1 to 10000, default \(limits.sampleEvents)."
                                        ),
                                        .init(
                                            "outputKiB", .bounded(.integer(16...16_384)), optional: true,
                                            doc:
                                                "Most text one MCP resource read or tool reply returns, in KiB: 16 to 16384, default \(limits.outputKiB). A longer reply is cut; events_sample instead stops adding events at it."
                                        ),
                                        .init(
                                            "concurrentSamples", .bounded(.integer(1...32)), optional: true,
                                            doc:
                                                "events_sample and system_sample calls one MCP session runs at once: 1 to 32, default \(limits.concurrentSamples)."
                                        ),
                                    ])), optional: true),
                        ])), optional: true, doc: "What MCP clients (`meerkat mcp`) may sample, and how much."),
                .init(
                    "samples",
                    .named(
                        "SampleStoreConfiguration",
                        ObjectSchema([
                            .init(
                                "maxAgeDays", .bounded(.integer(1...3650)), optional: true,
                                doc:
                                    "Samples older than this many days are deleted: 1 to 3650, default \(defaults.samples.maxAgeDays)."
                            ),
                            .init(
                                "maxMegabytes", .bounded(.integer(10...100_000)), optional: true,
                                doc:
                                    "The store is trimmed, oldest first, past this size in MB: 10 to 100000, default \(defaults.samples.maxMegabytes)."
                            ),
                        ])), optional: true, doc: "The sample store's budget (samples.db)."),
                .init(
                    "files",
                    .named(
                        "FilesConfiguration",
                        ObjectSchema([
                            .init(
                                "root", .string, optional: true,
                                doc:
                                    "Directory file churn watches, absolute or starting with ~. Default \(defaults.files.root), the whole startup volume."
                            ),
                            .init(
                                "exclude", .array(.string), optional: true,
                                doc:
                                    "Paths under root whose changes are not counted, absolute or starting with ~. Replaces the default list: \(defaults.files.exclude.joined(separator: ", "))."
                            ),
                        ])), optional: true,
                    doc: "What file churn watches: the Files card and page, and fs.churn subscriptions without a root."),
            ]))
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

    /// Validates `data` against `schema`, then decodes it over the defaults.
    /// Throws `Invalid` with every problem found.
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
        let problems = SchemaValidator.violations(of: value, against: schema(catalog))
        guard problems.isEmpty else { throw Invalid(problems: problems) }
        do {
            // The schema has rejected anything undeclared or out of range;
            // absent fields keep their defaults.
            var configuration = try JSONValue(encoding: MeerkatConfiguration()).merging(value)
                .decode(as: MeerkatConfiguration.self)
            configuration.files = try configuration.files.resolved()
            return configuration
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
