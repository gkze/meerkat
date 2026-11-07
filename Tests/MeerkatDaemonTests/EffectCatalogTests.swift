import Foundation
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization
import Testing

@testable import MeerkatDaemon
@testable import MeerkatKit

/// The effect catalog against the daemon: every effect decodes, grants parse
/// and match by their shape, and the executor authorizes from the catalog
/// before it touches the Mac (docs/design/effects.md).
struct EffectCatalogTests {
    /// One valid request per catalog effect. A catalog entry without one
    /// fails `everyCatalogEffectDecodes`, so a new effect cannot skip the
    /// daemon's decode.
    static let samples: [String: [String: JSONValue]] = [
        "state.get": ["key": "k"],
        "state.set": ["key": "k", "value": 1],
        "state.delete": ["key": "k"],
        "notify": ["title": "t"],
        "notify.withdraw": ["id": "n"],
        "process.signal": ["target": ["pid": 10, "startedAt": 1], "signal": "stop"],
        "process.priority": ["target": ["pid": 10, "startedAt": 1], "priority": "background"],
        "process.nice": ["target": ["pid": 10, "startedAt": 1], "nice": 10],
        "exec": ["path": "/usr/bin/true"],
        "http": ["url": "https://example.com/x"],
        "store.record": ["label": "l"],
        "power.preventSleep": ["id": "build", "reason": "a build", "timeoutSeconds": 600],
        "power.allowSleep": ["id": "build"],
        "audio.setDefaultDevice": ["device": "BuiltInSpeakerDevice"],
        "audio.setVolume": ["volume": 0.5],
        "audio.setMute": ["muted": true, "direction": "input"],
        "apps.open": ["bundleId": "com.apple.TextEdit"],
        "apps.activate": ["bundleId": "com.apple.TextEdit"],
        "apps.hide": ["bundleId": "com.apple.TextEdit"],
        "apps.unhide": ["bundleId": "com.apple.TextEdit"],
        "apps.quit": ["bundleId": "com.apple.TextEdit", "force": false],
        "urls.open": ["url": "https://example.com"],
        "volumes.eject": ["path": "/Volumes/Stick"],
        "files.trash": ["path": "/tmp/x"],
        "files.setTags": ["path": "/tmp/x", "tags": ["Red"]],
        "defaults.read": ["domain": "com.apple.dock", "key": "autohide"],
        "defaults.write": ["domain": "com.apple.dock", "key": "autohide", "value": true],
        "defaults.delete": ["domain": "com.apple.dock", "key": "autohide"],
        "shortcuts.run": ["name": "Focus on"],
        "wifi.setPower": ["on": false],
        "clipboard.read": [:],
        "clipboard.write": ["text": "hi"],
        "windows.list": ["bundleId": "com.apple.TextEdit"],
        "windows.set": ["bundleId": "com.apple.TextEdit", "index": 0, "x": 10, "raise": true],
        "appearance.setDark": ["on": true],
    ]

    @Test func everyCatalogEffectDecodes() throws {
        let catalog = EffectCatalog.standard
        #expect(Set(Self.samples.keys) == Set(catalog.effects.map(\.kind)))
        for effect in catalog.effects {
            let fields = try #require(Self.samples[effect.kind], "\(effect.kind) has no sample request")
            let request = try EffectRequest(.object(fields.merging(["kind": .string(effect.kind)]) { a, _ in a }))
            #expect(request.kind == effect.kind)
        }
    }

    @Test func everyEffectsGrantAndArgumentsExist() {
        let catalog = EffectCatalog.standard
        for effect in catalog.effects {
            if let key = effect.grant.grantKey { #expect(catalog.grant(key) != nil, "\(effect.kind): no grant \(key)") }
            if case .listed(let key, let subject) = effect.grant {
                #expect(catalog.grant(key)?.shape != .flag, "\(effect.kind): \(key) is a flag")
                #expect(effect.fields.contains { $0.name == subject }, "\(effect.kind): no field \(subject)")
            }
            if case .positional(let names) = effect.arguments {
                for name in names {
                    #expect(effect.fields.contains { $0.name == name }, "\(effect.kind): no field \(name)")
                }
            }
        }
    }

    /// The request schema refuses fields it does not declare, so a typo in a
    /// rule is an error rather than a silently ignored option.
    @Test func requestsAreCheckedAgainstTheirSchema() {
        #expect(throws: EffectError.self) { try EffectRequest(["kind": "audio.setVolume", "volume": 2]) }
        #expect(throws: EffectError.self) {
            try EffectRequest(["kind": "audio.setVolume", "volume": 0.5, "devce": "x"])
        }
        #expect(throws: EffectError.self) { try EffectRequest(["kind": "files.trash", "path": "/tmp/../etc"]) }
        #expect(throws: EffectError.self) { try EffectRequest(["kind": "defaults.write", "domain": "d", "key": "k"]) }
        #expect(throws: EffectError.self) { try EffectRequest(["kind": "apps.open", "bundleId": "a b"]) }
    }

    // MARK: Grants

    @Test func grantShapesParseAndNormalize() throws {
        let grants = try CapabilityGrants(
            [
                "audio": true, "windows": ["control": true], "urls": ["allow": ["HTTPS", "mailto"]],
                "files": ["trash": ["~/Downloads"]], "shortcuts": ["allow": ["Focus on"]],
                "http": ["allow": ["https://Example.com"]], "process": ["signal": true, "priority": false],
            ], home: "/Users/u")
        #expect(grants.has("audio") && grants.has("windows.control") && grants.has("process.signal"))
        #expect(!grants.has("process.priority"))
        #expect(grants.list("urls") == ["https", "mailto"])
        #expect(grants.list("files.trash") == ["/Users/u/Downloads"])
        #expect(grants.httpOrigins == [URLOrigin("https://example.com:443")!])
    }

    @Test func unknownAndMalformedGrantsAreLoadErrors() {
        func error(_ raw: JSONValue) -> String? {
            do {
                _ = try CapabilityGrants(raw)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(error(["audio": ["control": true]]) == "\"capabilities.audio\" must be a boolean")
        #expect(error(["windows": ["move": true]]) == "\"capabilities.windows\": unknown field \"move\"")
        #expect(
            error(["urls": ["allow": ["https:"]]])
                == "\"capabilities.urls.allow\": \"https:\" is not a URL scheme like https")
        #expect(error(["files": ["trash": ["Downloads"]]]) != nil)
        #expect(error(["root": true]) == "\"capabilities\": unknown capability \"root\"")
    }

    /// A path grant matches inside its prefix only, after resolving symlinks,
    /// so a link inside a granted folder cannot reach outside it.
    @Test func pathGrantsResolveSymlinks() throws {
        let base = temporaryURL("meerkat-test")
            .resolvingSymlinksInPath()
        let granted = base.appendingPathComponent("granted")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(
            at: granted.appendingPathComponent("link"), withDestinationURL: outside)

        let grants = try CapabilityGrants(["files": ["trash": [.string(granted.path)]]])
        let shape = GrantDescriptor.Shape.pathList
        #expect(grants.allows("files.trash", subject: granted.appendingPathComponent("a.txt").path, shape: shape))
        #expect(!grants.allows("files.trash", subject: granted.path + "-sibling/a.txt", shape: shape))
        #expect(!grants.allows("files.trash", subject: granted.appendingPathComponent("link/a.txt").path, shape: shape))
        #expect(!grants.allows("files.trash", subject: outside.appendingPathComponent("a.txt").path, shape: shape))
    }

    @Test func allowListsMatchTheirSubject() throws {
        let grants = try CapabilityGrants([
            "urls": ["allow": ["https"]], "defaults": ["allow": ["com.apple.dock"]],
        ])
        #expect(grants.allows("urls", subject: "HTTPS://example.com", shape: .allowList(.scheme)))
        #expect(!grants.allows("urls", subject: "file:///etc/passwd", shape: .allowList(.scheme)))
        #expect(grants.allows("defaults", subject: "com.apple.dock", shape: .allowList(.name)))
        #expect(!grants.allows("defaults", subject: "com.apple.finder", shape: .allowList(.name)))
    }

    /// A list grant is checked against the request's own text. Normalizing it
    /// through `URL`, as the request's decode does, must not change the answer.
    /// `Int(_:)` traps past Int64, and decoding comes before any grant.
    @Test(arguments: [1e300, -1, 1.5])
    func windowIndexMustBeAnIndex(index: Double) {
        #expect(throws: EffectError.self) {
            try EffectRequest(["kind": "windows.set", "bundleId": "a", "index": .number(index)])
        }
    }

    @Test(arguments: [1e300, 0])
    func processTargetMustHaveAStartTime(startedAt: Double) throws {
        let request: JSONValue = [
            "kind": "process.signal", "signal": "terminate", "target": ["pid": 1, "startedAt": .number(startedAt)],
        ]
        #expect(throws: EffectError.self) { try EffectRequest(request) }
    }

    /// A rule that could write this domain could move the rules directory.
    @Test(arguments: [
        ("com.gkze.meerkat", false),
        ("COM.GKZE.Meerkat", false),
        ("/Users/someone/Library/Preferences/com.gkze.meerkat", false),
        ("/Users/someone/Library/Preferences/com.gkze.meerkat.plist", false),
        ("com.apple.finder", true),
    ])
    func noGrantReachesMeerkatsOwnDomain(domain: String, allowed: Bool) throws {
        let authorizer = EffectAuthorizer()
        let grants = try CapabilityGrants(["defaults": ["allow": .array([.string(domain)])]])
        let write: JSONValue = ["kind": "defaults.write", "domain": .string(domain), "key": "k", "value": "v"]
        let delete: JSONValue = ["kind": "defaults.delete", "domain": .string(domain), "key": "k"]
        for raw in [write, delete] {
            let request = try EffectRequest(raw)
            if allowed {
                try authorizer.authorize(request, grants: grants)
            } else {
                #expect(throws: EffectError.self) { try authorizer.authorize(request, grants: grants) }
            }
        }
        let read = try EffectRequest(["kind": "defaults.read", "domain": .string(domain), "key": "k"])
        try authorizer.authorize(read, grants: grants)
    }

    /// Inside a protected folder, the folder, or a folder that holds it.
    @Test(arguments: [
        ("/private/rules/meerkat.json", false),
        ("/private/rules", false),
        ("/private", false),
        ("/private/rules-of-thumb", true),
    ])
    func noGrantReachesProtectedPaths(path: String, allowed: Bool) throws {
        let authorizer = EffectAuthorizer(protectedPaths: ["/private/rules"])
        let grants = try CapabilityGrants(["files": ["trash": ["/"], "tag": ["/"]]])
        let trash = try EffectRequest(["kind": "files.trash", "path": .string(path)])
        let tags = try EffectRequest(["kind": "files.setTags", "path": .string(path), "tags": []])
        for request in [trash, tags] {
            if allowed {
                try authorizer.authorize(request, grants: grants)
            } else {
                #expect(throws: EffectError.self) { try authorizer.authorize(request, grants: grants) }
            }
        }
    }

    /// `trash` moves the link it is given, not what the link leads to, so
    /// that entry is what grants and protected paths are checked against;
    /// `setTags` follows the link, and is checked at its target.
    @Test func trashIsCheckedAtTheLinkItMoves() throws {
        // Real throughout (`/private/var`), as `realpath` gives it.
        let base = URL(fileURLWithPath: CapabilityGrants.resolved(temporaryURL("meerkat-test").path))
        defer { try? FileManager.default.removeItem(at: base) }
        let files = FileManager.default
        let dotfiles = base.appendingPathComponent("dotfiles")
        let config = base.appendingPathComponent("config/meerkat")
        let granted = base.appendingPathComponent("granted")
        let elsewhere = base.appendingPathComponent("elsewhere")
        for folder in [dotfiles.appendingPathComponent("rules"), config, granted, elsewhere] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // The rules folder linked in from dotfiles, as stow sets it up, with a
        // settings file there that is itself a link.
        let rules = config.appendingPathComponent("rules")
        try files.createSymbolicLink(at: rules, withDestinationURL: dotfiles.appendingPathComponent("rules"))
        try Data("{}".utf8).write(to: dotfiles.appendingPathComponent("settings.json"))
        try files.createSymbolicLink(
            at: dotfiles.appendingPathComponent("rules/meerkat.json"),
            withDestinationURL: dotfiles.appendingPathComponent("settings.json"))
        try Data().write(to: granted.appendingPathComponent("file"))
        try files.createSymbolicLink(
            at: elsewhere.appendingPathComponent("link"), withDestinationURL: granted.appendingPathComponent("file"))

        // As `DaemonPaths.protected` lists them: the settings file too.
        let authorizer = EffectAuthorizer(protectedPaths: [
            rules.path, rules.appendingPathComponent("meerkat.json").path,
        ])
        func allowed(_ kind: String, _ path: URL, grant: [String: JSONValue]) throws -> Bool {
            let grants = try CapabilityGrants(["files": .object(grant)])
            var raw: [String: JSONValue] = ["kind": .string(kind), "path": .string(path.path)]
            if kind == "files.setTags" { raw["tags"] = [] }
            let request = try EffectRequest(.object(raw))
            return (try? authorizer.authorize(request, grants: grants)) != nil
        }
        // The settings link in the rules folder: moving it out would reset the
        // MCP policy, though its target is in the grant. Its target, and the
        // folder holding that, are the settings too.
        let inDotfiles: JSONValue = .array([.string(dotfiles.path)])
        #expect(try !allowed("files.trash", rules.appendingPathComponent("meerkat.json"), grant: ["trash": inDotfiles]))
        #expect(try !allowed("files.setTags", rules.appendingPathComponent("meerkat.json"), grant: ["tag": inDotfiles]))
        let settings = dotfiles.appendingPathComponent("settings.json")
        #expect(try !allowed("files.trash", settings, grant: ["trash": inDotfiles]))
        #expect(try !allowed("files.setTags", settings, grant: ["tag": inDotfiles]))
        #expect(try !allowed("files.trash", dotfiles, grant: ["trash": .array([.string(base.path)])]))
        try Data().write(to: dotfiles.appendingPathComponent("other.json"))
        #expect(try allowed("files.trash", dotfiles.appendingPathComponent("other.json"), grant: ["trash": inDotfiles]))
        // The folder that holds the rules folder as Meerkat names it, by
        // another case, and by its name on the data volume.
        let inBase: JSONValue = .array([.string(base.path)])
        #expect(try !allowed("files.trash", config, grant: ["trash": inBase]))
        let upper = base.appendingPathComponent("CONFIG/meerkat")
        #expect(try !allowed("files.trash", upper, grant: ["trash": inBase]))
        #expect(try !allowed("files.trash", base.appendingPathComponent("CONFIG"), grant: ["trash": inBase]))
        let onDataVolume = URL(fileURLWithPath: "/System/Volumes/Data" + config.path)
        #expect(try !allowed("files.trash", onDataVolume, grant: ["trash": ["/System/Volumes/Data"]]))
        #expect(try !allowed("files.trash", onDataVolume, grant: ["trash": ["/"]]))
        // A link outside the grant is not inside it by pointing there.
        let inGranted: JSONValue = .array([.string(granted.path)])
        #expect(try !allowed("files.trash", elsewhere.appendingPathComponent("link"), grant: ["trash": inGranted]))
        #expect(try allowed("files.trash", granted.appendingPathComponent("file"), grant: ["trash": inGranted]))
    }

    @Test(arguments: [
        ("https://example.com/a b", true),
        ("HTTPS://EXAMPLE.com/path?q=1#f", true),
        ("https://example.com:443/", true),
        ("https://user:pw@example.com/", true),
        ("https://example.com:8443/", false),
        ("https://example.com.evil.org/", false),
        ("https://example.com@evil.org/", false),
        ("http://example.com/", false),
    ])
    func httpSubjectsMatchOriginsAsURLsDo(text: String, allowed: Bool) throws {
        let authorizer = EffectAuthorizer()
        let grants = try CapabilityGrants(["http": ["allow": ["https://example.com"]]])
        let request = try EffectRequest(["kind": "http", "url": .string(text)])
        let subject = try #require(request.subject)
        let normalized = try #require(URL(string: text)).absoluteString
        #expect(
            grants.allows("http", subject: subject, shape: .allowList(.origin))
                == grants.allows("http", subject: normalized, shape: .allowList(.origin)))
        if allowed {
            try authorizer.authorize(request, grants: grants)
        } else {
            #expect(throws: EffectError.self) { try authorizer.authorize(request, grants: grants) }
        }
    }

    @Test(arguments: [
        ("https://example.com/a b", true),
        ("HTTPS://example.com", true),
        ("mailto:someone@example.com", false),
        ("file:///etc/passwd", false),
    ])
    func urlSubjectsMatchSchemesAsURLsDo(text: String, allowed: Bool) throws {
        let authorizer = EffectAuthorizer()
        let grants = try CapabilityGrants(["urls": ["allow": ["https"]]])
        let request = try EffectRequest(["kind": "urls.open", "url": .string(text)])
        let subject = try #require(request.subject)
        let normalized = try #require(URL(string: text)).absoluteString
        #expect(
            grants.allows("urls", subject: subject, shape: .allowList(.scheme))
                == grants.allows("urls", subject: normalized, shape: .allowList(.scheme)))
        if allowed {
            try authorizer.authorize(request, grants: grants)
        } else {
            #expect(throws: EffectError.self) { try authorizer.authorize(request, grants: grants) }
        }
    }

    @Test func nullIsAValueOnlyWhereTheSchemaIsJSON() {
        let schema = TypeSchema.object(
            ObjectSchema([.init("any", .json, optional: true), .init("text", .string, optional: true)]))
        #expect(SchemaValidator.violations(of: ["any": .null], against: schema) == [])
        #expect(SchemaValidator.violations(of: ["text": .null], against: schema).count == 1)
    }

    // MARK: Executor

    final class RecordingControls: SystemControls {
        let calls = Mutex<[String]>([])
        let released = Mutex<[UInt32]>([])
        let nextAssertion = Mutex<UInt32>(1)

        private func record(_ call: String) { calls.withLock { $0.append(call) } }

        func preventSleep(name: String, reason: String, display: Bool, timeout: Double) throws -> UInt32 {
            record("preventSleep \(reason) \(display) \(timeout)")
            return nextAssertion.withLock {
                defer { $0 += 1 }
                return $0
            }
        }
        func allowSleep(_ assertion: UInt32) { released.withLock { $0.append(assertion) } }
        func setDefaultAudioDevice(uid: String, scope: AudioScope) throws { record("default \(uid) \(scope)") }
        func setVolume(_ volume: Double, scope: AudioScope, device uid: String?) throws {
            record("volume \(volume) \(scope)")
        }
        func setMute(_ muted: Bool, scope: AudioScope, device uid: String?) throws { record("mute \(muted) \(scope)") }
        func openApplication(bundleId: String, activate: Bool) async throws { record("open \(bundleId)") }
        func control(bundleId: String, action: AppAction) async throws { record("control \(bundleId) \(action)") }
        func open(_ url: URL) async throws { record("url \(url.absoluteString)") }
        func ejectVolume(path: String) async throws { record("eject \(path)") }
        func trash(path: String) throws -> String {
            record("trash \(path)")
            return "/Users/u/.Trash/x"
        }
        func setTags(path: String, tags: [String]) throws { record("tags \(path) \(tags)") }
        func readDefault(domain: String, key: String) throws -> JSONValue? { key == "set" ? .bool(true) : nil }
        func writeDefault(domain: String, key: String, value: JSONValue) throws { record("write \(domain) \(key)") }
        func deleteDefault(domain: String, key: String) throws { record("delete \(domain) \(key)") }
        func setWiFiPower(_ on: Bool) throws { record("wifi \(on)") }
        func readClipboard() async -> String? { "copied" }
        func writeClipboard(_ text: String) async { record("clipboard \(text)") }
        func windows(bundleId: String) throws -> [WindowInfo] {
            [WindowInfo(index: 0, title: "w", x: 0, y: 0, width: 100, height: 50, minimized: false, main: true)]
        }
        func setWindow(_ change: WindowChange) throws { record("window \(change.index)") }
        func setDarkMode(_ on: Bool) async throws { record("dark \(on)") }
    }

    final class SilentNotifier: Notifier {
        func post(_ plan: NotificationPlan) async throws {}
        func withdraw(identifier: String) async throws {}
    }

    private func executor(
        _ controls: RecordingControls, accessibility: EventDescriptor.Permission.Status = .granted
    ) throws -> (EffectExecutor, URL) {
        let directory = temporaryURL("meerkat-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try RuleStore(path: directory.appendingPathComponent("rules.db").path)
        let executor = EffectExecutor(
            store: store, ownProcesses: OwnProcesses(), notifier: SilentNotifier(),
            sampleDatabasePath: directory.appendingPathComponent("s.db").path, controls: controls,
            permissionStatus: { _ in accessibility })
        return (executor, directory)
    }

    private func rule(_ capabilities: JSONValue, name: String = "r") throws -> RuleDefinition {
        try RuleDefinition(
            file: "a.ts", raw: ["name": .string(name), "on": "memory.pressure", "capabilities": capabilities],
            catalog: .standard)
    }

    @Test func stateStoresAnExplicitNull() async throws {
        let (executor, directory) = try executor(RecordingControls())
        defer { try? FileManager.default.removeItem(at: directory) }
        let definition = try rule([:])
        #expect(
            await executor.perform(["kind": "state.set", "key": "k", "value": .null], for: definition)
                == .success(value: "null"))
        #expect(
            await executor.perform(["kind": "state.get", "key": "k"], for: definition)
                == .success(value: #"{"found":true,"value":null}"#))
    }

    /// `ExecResult`: an absent status or signal is left out, never null.
    @Test func execResultsLeaveOutWhatDidNotHappen() async throws {
        let (executor, directory) = try executor(RecordingControls())
        defer { try? FileManager.default.removeItem(at: directory) }
        let definition = try rule(["exec": ["allow": ["/bin/sh"]]])
        func run(_ script: String) async throws -> JSONValue {
            let outcome = await executor.perform(
                ["kind": "exec", "path": "/bin/sh", "args": ["-c", .string(script)]], for: definition)
            guard case .success(let value) = outcome else { throw EffectError.failed("\(outcome)") }
            return try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
        }
        let exited = try await run("exit 3")
        #expect(exited["status"] == 3)
        #expect(exited.objectValue?.keys.contains("signal") == false)
        let killed = try await run("kill -9 $$")
        #expect(killed["signal"] == 9)
        #expect(killed.objectValue?.keys.contains("status") == false)
    }

    @Test func effectsNeedTheirGrantBeforeTheyAct() async throws {
        let controls = RecordingControls()
        let (executor, directory) = try executor(controls)
        defer { try? FileManager.default.removeItem(at: directory) }

        let refused = await executor.perform(["kind": "audio.setMute", "muted": true], for: try rule([:]))
        #expect(refused == .failure(message: "not granted: add audio: true to this rule's capabilities"))
        let outside = await executor.perform(
            ["kind": "urls.open", "url": "file:///etc/passwd"], for: try rule(["urls": ["allow": ["https"]]]))
        #expect(
            outside == .failure(message: "not granted: add urls: { allow: [\"file\"] } to this rule's capabilities"))
        #expect(controls.calls.withLock { $0 }.isEmpty)

        #expect(
            await executor.perform(["kind": "audio.setMute", "muted": true], for: try rule(["audio": true]))
                == .success(value: "null"))
        #expect(
            await executor.perform(
                ["kind": "defaults.read", "domain": "com.apple.dock", "key": "set"],
                for: try rule(["defaults": ["allow": ["com.apple.dock"]]]))
                == .success(value: "{\"found\":true,\"value\":true}"))
        #expect(controls.calls.withLock { $0 } == ["mute true output"])
    }

    @Test func accessibilityEffectsNeedThePermission() async throws {
        let controls = RecordingControls()
        let (executor, directory) = try executor(controls, accessibility: .denied)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = await executor.perform(
            ["kind": "windows.list", "bundleId": "com.apple.TextEdit"], for: try rule(["windows": ["control": true]]))
        guard case .failure(let message) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(message.contains("accessibility permission"))
    }

    /// Reusing an assertion id replaces it; a rule that stops releases what
    /// it holds, and other rules keep theirs.
    @Test func powerAssertionsBelongToTheirRule() async throws {
        let controls = RecordingControls()
        let (executor, directory) = try executor(controls)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request: JSONValue = ["kind": "power.preventSleep", "id": "b", "reason": "r", "timeoutSeconds": 60]
        let first = try rule(["power": ["awake": true]], name: "first")
        let second = try rule(["power": ["awake": true]], name: "second")
        _ = await executor.perform(request, for: first)
        _ = await executor.perform(request, for: first)
        _ = await executor.perform(request, for: second)
        #expect(controls.released.withLock { $0 } == [1])
        executor.releaseHeld(keeping: [second.id])
        #expect(controls.released.withLock { $0 } == [1, 2])
        _ = await executor.perform(["kind": "power.allowSleep", "id": "b"], for: second)
        #expect(controls.released.withLock { $0 } == [1, 2, 3])
    }
}

/// The cases the runtime's protected.rs is held to as well
/// (`protected_paths_cover_the_shared_cases`), so the daemon's and the
/// runtime's ideas of what a protected path covers cannot drift apart.
struct ProtectedPathCases {
    struct Spec: Decodable {
        struct Layout: Decodable {
            struct Link: Decodable {
                let at: String
                let to: String
            }
            let folders: [String]
            let files: [String]
            let links: [Link]
        }
        struct Case: Decodable {
            let path: String
            let touches: Bool
            let why: String
        }
        let layout: Layout
        let protected: [String]
        let cases: [Case]
    }

    @Test func protectedPathsCoverTheSharedCases() throws {
        let spec = try JSONDecoder().decode(
            Spec.self,
            from: Data(
                contentsOf: repositoryRoot.appendingPathComponent("Sources/meerkat-runtime/src/protected_cases.json")))
        // Real throughout (`/private/var`), as `realpath` gives it.
        let root = CapabilityGrants.resolved(temporaryURL("meerkat-cases").path)
        defer { try? FileManager.default.removeItem(atPath: root) }
        func at(_ path: String) -> String {
            if path.hasPrefix("/") { return path }
            if path.hasPrefix("@data/") { return "/System/Volumes/Data\(root)/\(path.dropFirst("@data/".count))" }
            return root + "/" + path
        }
        let files = FileManager.default
        for folder in spec.layout.folders {
            try files.createDirectory(atPath: at(folder), withIntermediateDirectories: true)
        }
        for file in spec.layout.files { try Data().write(to: URL(fileURLWithPath: at(file))) }
        for link in spec.layout.links {
            try files.createSymbolicLink(atPath: at(link.at), withDestinationPath: at(link.to))
        }
        let protected = spec.protected.map(at)
        for item in spec.cases {
            let touched = CapabilityGrants.protectedPath(
                touchedBy: CapabilityGrants.entry(at(item.path)), in: protected)
            #expect((touched != nil) == item.touches, "\(item.path) (\(item.why))")
        }
    }
}
