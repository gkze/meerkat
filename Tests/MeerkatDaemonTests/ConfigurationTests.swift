import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatStore
import Testing

@testable import MeerkatDaemon

/// `meerkat.json`: its schema is the one authority (the checked-in JSON
/// Schema and the example agree with it), the daemon applies a valid file
/// and keeps the last good one when an edit is invalid, and the policy it
/// sets reaches MCP.
struct ConfigurationTests {
    // MARK: - Generated schema and example

    @Test func checkedInSchemaIsCurrent() throws {
        let checkedIn = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/meerkat-rules/meerkat.schema.json"),
            encoding: .utf8)
        #expect(
            checkedIn == MeerkatConfiguration.jsonSchema(),
            "regenerate with: buck2 run //Sources/meerkat-rules:regenerate")
    }

    /// The schema's defaults are the configuration's own, and its `allow`
    /// doc names every kind the default denies by name, so neither can
    /// drift from the code.
    @Test func schemaDefaultsAndDocsComeFromTheCode() throws {
        let defaults = try JSONValue(encoding: MeerkatConfiguration())
        var checked = 0
        func check(_ schema: TypeSchema, _ value: JSONValue?, at path: String) {
            guard let object = schema.objectSchema else { return }
            for field in object.fields {
                let current = value?[field.name]
                if let given = field.default {
                    // A section's default is `{}`, which its fields' defaults fill.
                    let expected = field.schema.objectSchema.map { (try? .object($0.admit(given))) ?? given } ?? given
                    #expect(expected == current, "\(path).\(field.name)")
                    checked += 1
                }
                check(field.schema, current, at: path + "." + field.name)
            }
        }
        let schema = MeerkatConfiguration.schema()
        check(schema, defaults, at: "$")
        #expect(checked > 0)
        let allow =
            schema.objectSchema?.field("mcp")?.schema.objectSchema?.field("events")?.schema.objectSchema?
            .field("allow")?.doc ?? ""
        let named = MeerkatConfiguration.MCP.Events.rawKinds
            .union(MeerkatConfiguration.MCP.Events.rawFamilies.map { $0 + ".*" })
        for kind in named { #expect(allow.contains(kind), "\(kind)") }
    }

    /// The example sets every field to something other than its default, so
    /// a field the schema declares but decoding misses (or the reverse)
    /// shows up as a default here.
    @Test func exampleSetsEveryFieldAndDecodes() throws {
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/meerkat-rules/examples/meerkat.json"))
        let configuration = try MeerkatConfiguration.decode(data)
        let defaults = MeerkatConfiguration()
        #expect(!configuration.mcp.events.allow.isEmpty)
        #expect(!configuration.mcp.events.deny.isEmpty)
        #expect(configuration.mcp.limits.sampleSeconds != defaults.mcp.limits.sampleSeconds)
        #expect(configuration.mcp.limits.sampleEvents != defaults.mcp.limits.sampleEvents)
        #expect(configuration.mcp.limits.outputKiB != defaults.mcp.limits.outputKiB)
        #expect(configuration.mcp.limits.concurrentSamples != defaults.mcp.limits.concurrentSamples)
        #expect(configuration.samples.maxAgeDays != defaults.samples.maxAgeDays)
        #expect(configuration.samples.maxMegabytes != defaults.samples.maxMegabytes)
        #expect(configuration.files.root != defaults.files.root)
        #expect(configuration.files.exclude != defaults.files.exclude)
    }

    /// An effective configuration, written out, is a valid file that
    /// decodes to itself: the Swift types and the schema name the same
    /// fields with the same ranges.
    @Test func effectiveConfigurationRoundTrips() throws {
        var custom = MeerkatConfiguration()
        custom.mcp.events = .init(allow: ["log.entry", "iokit.*"], deny: ["fs.change"])
        custom.mcp.limits = .init(sampleSeconds: 2.5, sampleEvents: 10, outputKiB: 16, concurrentSamples: 1)
        custom.samples = .init(maxAgeDays: 1, maxMegabytes: 10)
        custom.files = .init(root: "/Users", exclude: ["/Users/Shared"])
        for configuration in [MeerkatConfiguration(), custom] {
            let data = try JSONEncoder().encode(configuration)
            #expect(try MeerkatConfiguration.decode(data) == configuration)
        }
    }

    // MARK: - Files

    /// The default scope is the whole startup volume with the system's own
    /// bookkeeping left out, and it is `FileScope.standard`: one definition.
    @Test func filesDefaultToTheWholeVolume() {
        let files = MeerkatConfiguration().files
        #expect(files.scope == FileScope.standard)
        #expect(files.root == "/")
        #expect(files.exclude.contains("/private/var/folders"))
    }

    @Test func filesPathsExpandTilde() throws {
        let data = Data(#"{"files": {"root": "~", "exclude": ["~/Library/Caches"]}}"#.utf8)
        let files = try MeerkatConfiguration.decode(data).files
        #expect(files.root == NSHomeDirectory())
        #expect(files.exclude == [NSHomeDirectory() + "/Library/Caches"])
    }

    /// Events arrive with `/private/var/...` paths; an exclusion written as
    /// `/var/...` must match them, so paths resolve rather than standardize.
    @Test func filesPathsResolveToTheFormEventsUse() throws {
        let data = Data(#"{"files": {"exclude": ["/var/folders", "/tmp/"]}}"#.utf8)
        #expect(try MeerkatConfiguration.decode(data).files.exclude == ["/private/var/folders", "/private/tmp"])
    }

    /// The schema cannot tell a relative path; decoding can, and the file
    /// is then invalid like any other problem (the last good one holds).
    @Test func relativeFilesPathIsInvalid() {
        let data = Data(#"{"files": {"exclude": ["Library/Caches"]}}"#.utf8)
        #expect(throws: MeerkatConfiguration.Invalid.self) { try MeerkatConfiguration.decode(data) }
    }

    @Test func emptyFileMeansDefaults() throws {
        #expect(try MeerkatConfiguration.decode(Data("{}".utf8)) == MeerkatConfiguration())
        let pointer = #"{ "$schema": "./.meerkat/meerkat.schema.json" }"#
        #expect(try MeerkatConfiguration.decode(Data(pointer.utf8)) == MeerkatConfiguration())
    }

    /// Null for a section or a setting means its default, as leaving it out
    /// does.
    @Test func nullMeansTheDefault() throws {
        for text in [
            #"{ "mcp": null }"#, #"{ "mcp": { "limits": null } }"#, #"{ "samples": { "maxMegabytes": null } }"#,
            #"{ "files": null }"#,
        ] {
            #expect(try MeerkatConfiguration.decode(Data(text.utf8)) == MeerkatConfiguration(), "\(text)")
        }
    }

    @Test(arguments: [
        #"{ "mcp": { "limits": { "sampleSeconds": 301 } } }"#,
        #"{ "mcp": { "limits": { "sampleEvents": 1.5 } } }"#,
        #"{ "mcp": { "limits": { "concurrentSamples": 0 } } }"#,
        #"{ "mcp": { "events": { "allow": ["log.entri"] } } }"#,
        #"{ "mcp": { "events": { "deny": "fs.change" } } }"#,
        #"{ "samples": { "maxAgeDays": "30" } }"#,
        #"{ "sample": {} }"#,
        #"{ "mcp": { "limits": { "outputBytes": 1 } } }"#,
        #"[]"#,
        #"{ "mcp": "#,
    ])
    func invalidFilesAreRejected(_ text: String) {
        #expect(throws: MeerkatConfiguration.Invalid.self) { try MeerkatConfiguration.decode(Data(text.utf8)) }
    }

    /// Problems name the field and read as a person would write the value;
    /// a misspelt kind gets the nearest one, not the whole catalog.
    @Test func problemsAreReadable() throws {
        let text = #"{ "mcp": { "events": { "allow": ["log.entri"] }, "limits": { "sampleEvents": 0 } } }"#
        let invalid = try #require(throws: MeerkatConfiguration.Invalid.self) {
            try MeerkatConfiguration.decode(Data(text.utf8))
        }
        #expect(invalid.problems.count == 2)
        let kind = invalid.problems.first ?? ""
        #expect(kind.hasPrefix(#"$.mcp.events.allow[0]: "log.entri" is not one of the "#))
        #expect(kind.hasSuffix(#"allowed values; did you mean "log.entry"?"#))
        #expect(invalid.problems.last == "$.mcp.limits.sampleEvents: 0 is less than 1")
    }

    // MARK: - Event access

    @Test func eventAccessDefaultsAllowsAndDenies() throws {
        let catalog = EventCatalog.standard
        func descriptor(_ name: String) throws -> EventDescriptor {
            try #require(catalog.kind(named: name)).descriptor
        }
        let standard = MeerkatConfiguration.MCP.Events()
        #expect(standard.allows(try descriptor("cpu.sample")))
        for denied in ["log.entry", "darwin.notification", "iokit.attached", "window.focused", "network.wifi"] {
            #expect(!standard.allows(try descriptor(denied)), "\(denied)")
        }
        let configured = MeerkatConfiguration.MCP.Events(
            allow: ["log.entry", "iokit.*"], deny: ["cpu.*", "iokit.detached"])
        #expect(configured.allows(try descriptor("log.entry")))
        #expect(configured.allows(try descriptor("iokit.attached")))
        // Deny wins, by name or by family.
        #expect(!configured.allows(try descriptor("iokit.detached")))
        #expect(!configured.allows(try descriptor("cpu.sample")))
        #expect(configured.allows(try descriptor("memory.sample")))
    }

    /// A kind delivered only to rules is never sampleable over MCP, even
    /// when `meerkat.json` allows it: the hub refuses external subscribers.
    @Test func ruleOnlyKindsAreNeverSampleable() throws {
        let catalog = EventCatalog.standard
        let policy = MCPPolicy(.init(events: .init(allow: ["meerkat.notification"])))
        #expect(!policy.allows(try #require(catalog.kind(named: "meerkat.notification"))))
        #expect(!policy.sampleableKinds(catalog).contains("meerkat.notification"))
        #expect(policy.sampleableKinds(catalog).contains("cpu.sample"))
    }

    // MARK: - Applying the file

    @Test func settingsApplyValidFilesAndKeepTheLastGood() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meerkat-config-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = DaemonSettings(rulesDirectory: directory, catalog: .standard)
        func write(_ text: String) throws { try text.write(to: settings.file, atomically: true, encoding: .utf8) }

        // An invalid file at start leaves the defaults, the fail-closed baseline.
        try write(#"{ "mcp": { "events": { "allow": ["log.entry"] }, "limits": { "sampleEvents": 0 } } }"#)
        settings.reload()
        #expect(settings.status.source == .defaults)
        #expect(settings.current == MeerkatConfiguration())
        #expect(settings.diagnostic?.message.contains("the defaults apply") == true)
        #expect(settings.diagnostic?.file == "meerkat.json")

        try write(#"{ "mcp": { "limits": { "sampleEvents": 7 } } }"#)
        settings.reload()
        #expect(settings.status.source == .file)
        #expect(settings.policy.limits.sampleEvents == 7)
        #expect(settings.diagnostic == nil)

        // A broken edit keeps what applied, and says so.
        try write(#"{ "mcp": { "limits": { "sampleEvents": 7, "#)
        settings.reload()
        #expect(settings.status.source == .lastGood)
        #expect(settings.policy.limits.sampleEvents == 7)
        #expect(settings.diagnostic?.message.contains("previous version still applies") == true)

        try write(#"{ "samples": { "maxAgeDays": 2, "maxMegabytes": 20 } }"#)
        settings.reload()
        #expect(settings.sampleLimits == .init(maxAge: 2 * 86_400, maxBytes: 20_000_000))
        #expect(settings.policy.limits.sampleEvents == MeerkatConfiguration.MCP.Limits().sampleEvents)

        try FileManager.default.removeItem(at: settings.file)
        settings.reload()
        #expect(settings.status.source == .defaults)
        #expect(settings.current == MeerkatConfiguration())

        // What the editor support writes for `$schema`.
        #expect(settings.schema.path == MeerkatConfiguration.schemaPath)
    }

    /// The engine rereads the file on every reload and reports its problem
    /// with the rule diagnostics, even with no runtime to compile rules.
    @Test func engineReportsTheFilesProblem() async throws {
        let fixture = try MCPFixture()
        try #"{ "samples": { "maxAgeDays": 0 } }"#.write(
            to: fixture.paths.rulesDirectory.appendingPathComponent("meerkat.json"), atomically: true,
            encoding: .utf8)
        await fixture.daemon.engine.reload()
        let report = await fixture.daemon.engine.report()
        let problem = try #require(report.diagnostics.first { $0.file == "meerkat.json" })
        #expect(problem.blocksLoading)
        #expect(problem.message.contains("maxAgeDays"))
    }

    /// A daemon with no rule runtime says so in its host's state, not as
    /// a host that is idle, and why in the rule diagnostics.
    @Test func noRuntimeIsAnUnavailableHost() async throws {
        let fixture = try MCPFixture()
        await fixture.daemon.engine.reload()
        #expect(await fixture.daemon.engine.hostStatus().state == .unavailable)
        let report = await fixture.daemon.engine.report()
        #expect(report.diagnostics.contains { $0.message == "no rule runtime is available; rules cannot load" })
    }

    // MARK: - Paths

    @Test func pathsPreferEnvironmentThenDefaultsThenBuiltIn() {
        let preferences = ["RulesDirectory": "/prefs/rules", "SampleDatabase": "~/samples.db", "CacheDirectory": ""]
        let paths = DaemonPaths.standard(
            environment: ["MEERKAT_RULES_DIR": "/env/rules"], preferences: { preferences[$0] })
        #expect(paths.rulesDirectory.path == "/env/rules")
        #expect(paths.sampleDatabase.path == NSHomeDirectory() + "/samples.db")
        // An empty value is no value.
        #expect(paths.cacheDirectory.path.hasSuffix("Library/Caches/com.gkze.meerkat"))
        #expect(paths.ruleDatabase.lastPathComponent == "rules.db")
        let protected = paths.protected(executable: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(protected.write.contains(DaemonPaths.preferencesFile.path))
    }

    /// Deno compares the paths a call names with its deny list as text, so a
    /// rules folder reached through a symlink is listed both ways.
    @Test func protectedPathsAreListedAsNamedAndResolved() throws {
        // Real throughout (`/private/var`), as `realpath` gives it.
        let base = URL(fileURLWithPath: CapabilityGrants.resolved(temporaryURL("meerkat-test").path))
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real/rules")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("alias"), withDestinationURL: base.appendingPathComponent("real"))
        let named = base.appendingPathComponent("alias/rules").path
        let paths = DaemonPaths.standard(environment: ["MEERKAT_RULES_DIR": named], preferences: { _ in nil })
        let protected = paths.protected(executable: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(protected.write.contains(paths.rulesDirectory.standardizedFileURL.path), "\(protected.write)")
        #expect(protected.write.contains(real.path), "\(protected.write)")
    }
}
