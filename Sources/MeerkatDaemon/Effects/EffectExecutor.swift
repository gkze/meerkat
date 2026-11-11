import Darwin
import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization

/// Applies notification plans. Abstracted because notifications need the
/// app bundle's identity, which tests and SwiftPM builds do not have.
protocol Notifier: Sendable {
    func post(_ plan: NotificationPlan) async throws
    func withdraw(identifier: String) async throws
}

/// Performs effects for rules after checking their grants.
///
/// Which grant each effect needs, and how a list grant is matched, comes from
/// the effect catalog (docs/design/effects.md). Process effects target an
/// identity (pid plus start time) and re-check it immediately before acting,
/// and refuse other users' processes; exec runs an allow-listed executable
/// with an argv array and no shell; http only reaches allow-listed origins,
/// including after redirects. macOS controls go through `SystemControls`.
/// What each effect is checked for comes from its descriptor
/// (`EffectDescriptor.Traits`), through the `EffectAuthorizer` the daemon
/// builds once and gives the dry run too.
final class EffectExecutor: Sendable {
    private let store: RuleStore
    private let ownProcesses: OwnProcesses
    private let notifier: any Notifier
    private let sampleDatabasePath: String
    /// The sample store's budget as `meerkat.json` sets it now.
    private let sampleLimits: @Sendable () -> SampleStore.Limits
    /// What admits a request: the dry run simulates effects under it too.
    let authorizer: EffectAuthorizer
    private let controls: any SystemControls
    /// Power assertions by rule id, then by the rule's own id for them.
    /// Released when the rule stops (`releaseHeld`).
    private let assertions = Mutex<[String: [String: UInt32]]>([:])

    static let shortcutsExecutable = "/usr/bin/shortcuts"

    init(
        store: RuleStore, ownProcesses: OwnProcesses, notifier: any Notifier, sampleDatabasePath: String,
        authorizer: EffectAuthorizer, sampleLimits: @escaping @Sendable () -> SampleStore.Limits = { .standard },
        controls: any SystemControls = MacSystemControls()
    ) {
        self.authorizer = authorizer
        self.controls = controls
        self.sampleLimits = sampleLimits
        self.store = store
        self.ownProcesses = ownProcesses
        self.notifier = notifier
        self.sampleDatabasePath = sampleDatabasePath
    }

    func perform(_ raw: JSONValue, for rule: RuleDefinition) async -> EffectOutcome {
        do {
            let request = try EffectRequest(raw)
            let authorizer = self.authorizer
            let value: JSONValue
            switch (body(request.action, rule: rule), request.descriptor.traits.path?.isProtected == true) {
            case (.synchronous(let act), true):
                // Checked and done with rules' renames held off, so no rule's
                // code swaps a folder on the path between the two.
                value = try await DenoRuntime.holdingRuleRenames {
                    try authorizer.decide(request, for: rule)
                    return try act()
                }
            case (.asynchronous, true):
                // Only a synchronous body can run under the hold.
                throw EffectError.failed("\(request.kind) acts on a path but cannot run with renames held off")
            case (.synchronous(let act), false):
                try await admit(request, for: rule)
                value = try act()
            case (.asynchronous(let act), false):
                try await admit(request, for: rule)
                value = try await act()
            }
            return .success(value: value.canonicalString)
        } catch let error as EffectError {
            return .failure(message: error.description)
        } catch {
            return .failure(message: "\(error)")
        }
    }

    /// The authorizer's decision, then the Automation permission the
    /// descriptor names, asked only of a request the rule may make. The
    /// catalog keeps that permission off effects on protected paths, which
    /// run under the rename hold and cannot wait for it.
    private func admit(_ request: EffectRequest, for rule: RuleDefinition) async throws {
        try authorizer.decide(request, for: rule)
        if let target = request.descriptor.automation { try await controls.requireAutomation(of: target) }
    }

    /// Releases what rules hold beyond an invocation (power assertions) for
    /// every rule not in `keeping`: unloaded, changed or disabled rules.
    func releaseHeld(keeping: Set<String>) {
        let released = assertions.withLock { held in
            let gone = held.filter { !keeping.contains($0.key) }
            for id in gone.keys { held.removeValue(forKey: id) }
            return gone.values.flatMap(\.values)
        }
        for assertion in released { controls.allowSleep(assertion) }
    }

    /// What performing an action does; an effect on a protected path is
    /// synchronous (`perform`).
    private enum Body {
        case synchronous(@Sendable () throws -> JSONValue)
        case asynchronous(() async throws -> JSONValue)
    }

    /// One switch over every action, so each says how it runs.
    private func body(_ action: EffectRequest.Action, rule: RuleDefinition) -> Body {
        let controls = self.controls
        /// An action whose value is null.
        func effect(_ act: @escaping () async throws -> Void) -> Body {
            .asynchronous {
                try await act()
                return .null
            }
        }
        switch action {
        case .stateGet(let key):
            return .asynchronous { EffectDescriptor.Result.found(try self.store.value(rule: rule.id, key: key)) }
        case .stateSet(let key, let value):
            return effect { try self.store.setValue(value, rule: rule.id, key: key) }
        case .stateDelete(let key):
            return effect { try self.store.deleteValue(rule: rule.id, key: key) }
        case .notify(let spec):
            return effect { try await self.notifier.post(NotificationPlan(rule: rule, spec: spec)) }
        case .withdrawNotification(let id):
            return effect {
                try await self.notifier.withdraw(identifier: NotificationPlan.identifier(ruleId: rule.id, id: id))
            }
        case .signal(let target, let signal):
            return effect {
                try self.verifyOwnProcess(target)
                // An exit the signal causes is the daemon's doing; nothing
                // else about the process is (`OwnProcesses.expectExit`). It is
                // expected before the signal is sent, since the exit can be
                // observed before `kill` returns, and withdrawn on failure
                // only if this call added it.
                let expected = signal.terminates && self.ownProcesses.expectExit(target)
                guard kill(target.pid, signal.number) == 0 else {
                    if expected { self.ownProcesses.withdrawExpectedExit(target) }
                    throw EffectError.failed(
                        "kill(\(target.pid), \(signal.rawValue)) failed: \(String(cString: strerror(errno)))")
                }
            }
        case .priority(let target, let priority):
            return effect {
                try self.verifyOwnProcess(target)
                let value = priority == .background ? PRIO_DARWIN_BG : 0
                guard setpriority(PRIO_DARWIN_PROCESS, id_t(target.pid), value) == 0 else {
                    throw EffectError.failed("setpriority(\(target.pid)) failed: \(String(cString: strerror(errno)))")
                }
            }
        case .nice(let target, let nice):
            return effect {
                try self.verifyOwnProcess(target)
                guard setpriority(PRIO_PROCESS, id_t(target.pid), nice) == 0 else {
                    throw EffectError.failed(
                        "setpriority(\(target.pid), \(nice)) failed: \(String(cString: strerror(errno))); only lowering priority is allowed"
                    )
                }
            }
        case .exec(let spec):
            return .asynchronous { try JSONValue(encoding: await self.run(spec)) }
        case .http(let spec):
            return .asynchronous { try await self.fetch(spec, allowed: rule.grants.httpOrigins) }
        case .record(let spec):
            return effect { try await self.record(spec) }
        case .preventSleep(let spec):
            return effect {
                let assertion = try controls.preventSleep(
                    name: "Meerkat rule \(rule.id)", reason: spec.reason, display: spec.display,
                    timeout: spec.timeout)
                let replaced = self.assertions.withLock { held in
                    held[rule.id, default: [:]].updateValue(assertion, forKey: spec.id)
                }
                if let replaced { controls.allowSleep(replaced) }
            }
        case .allowSleep(let id):
            return effect {
                let released = self.assertions.withLock { $0[rule.id]?.removeValue(forKey: id) }
                if let released { controls.allowSleep(released) }
            }
        case .audioDefaultDevice(let uid, let scope):
            return effect { try controls.setDefaultAudioDevice(uid: uid, scope: scope) }
        case .audioVolume(let volume, let scope, let device):
            return effect { try controls.setVolume(volume, scope: scope, device: device) }
        case .audioMute(let muted, let scope, let device):
            return effect { try controls.setMute(muted, scope: scope, device: device) }
        case .openApplication(let bundleId, let activate):
            return effect { try await controls.openApplication(bundleId: bundleId, activate: activate) }
        case .controlApplication(let bundleId, let action):
            return effect { try await controls.control(bundleId: bundleId, action: action) }
        case .openURL(let url):
            return effect { try await controls.open(url) }
        case .ejectVolume(let path):
            return effect { try await controls.ejectVolume(path: path) }
        case .trash(let path):
            return .synchronous { try JSONValue(encoding: TrashResult(trashedPath: try controls.trash(path: path))) }
        case .setTags(let path, let tags):
            return .synchronous {
                try controls.setTags(path: path, tags: tags)
                return .null
            }
        case .readDefault(let domain, let key):
            return .asynchronous { EffectDescriptor.Result.found(try controls.readDefault(domain: domain, key: key)) }
        case .writeDefault(let domain, let key, let value):
            return effect { try controls.writeDefault(domain: domain, key: key, value: value) }
        case .deleteDefault(let domain, let key):
            return effect { try controls.deleteDefault(domain: domain, key: key) }
        case .runShortcut(let spec):
            return .asynchronous { try JSONValue(encoding: await self.runShortcut(spec)) }
        case .wifiPower(let on):
            return effect { try controls.setWiFiPower(on) }
        case .readClipboard:
            return .asynchronous { EffectDescriptor.Result.found(await controls.readClipboard().map(JSONValue.string)) }
        case .writeClipboard(let text):
            return effect { await controls.writeClipboard(text) }
        case .listWindows(let bundleId):
            return .asynchronous { try JSONValue(encoding: controls.windows(bundleId: bundleId)) }
        case .setWindow(let change):
            return effect { try controls.setWindow(change) }
        case .darkMode(let on):
            return effect { try await controls.setDarkMode(on) }
        }
    }

    /// `shortcuts run`, with the input and output through files: the command
    /// reads input and writes output only by path.
    private func runShortcut(_ spec: ShortcutSpec) async throws -> ExecResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meerkat-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.txt")
        var arguments = ["run", spec.name, "--output-path", output.path, "--output-type", "public.plain-text"]
        if let input = spec.input {
            let file = directory.appendingPathComponent("input.txt")
            try Data(input.utf8).write(to: file)
            arguments += ["--input-path", file.path]
        }
        var result = try await run(
            ExecSpec(path: Self.shortcutsExecutable, arguments: arguments, timeout: spec.timeout, stdin: nil))
        if let data = FileManager.default.contents(atPath: output.path) {
            result.stdout = String(decoding: data.prefix(ExecResult.outputLimit), as: UTF8.self)
        }
        return result
    }

    /// The target must still be the same process, and ours to act on.
    private func verifyOwnProcess(_ target: ProcessIdentity) throws {
        guard let record = ProcessTable.record(of: target) else {
            throw EffectError.failed("process \(target.pid) started at \(target.startedAt) is no longer running")
        }
        guard record.uid == getuid() else {
            throw EffectError.failed(
                "process \(target.pid) belongs to uid \(record.uid); only your own processes can be changed")
        }
        // The rules run inside the daemon, so its stop would wedge them all
        // (and SIGTERM would end it).
        guard target.pid != getpid() else {
            throw EffectError.failed("a rule cannot signal or reprioritize the daemon itself")
        }
        // Nor what the daemon started for itself or for other rules, or what
        // those started in turn: a stopped `log stream` would leave every
        // `log.entry` rule silent with no failure, and another rule's `exec`
        // child, and the processes it runs, are that rule's.
        guard !Self.descendsFromDaemon(record) else {
            throw EffectError.failed(
                "process \(target.pid) was started by the daemon, or by a process it started; a rule cannot signal or reprioritize it"
            )
        }
    }

    /// Whether the daemon is among `record`'s ancestors. One that left its
    /// parent, as a daemonizing process does, now belongs to launchd and is
    /// not counted. Bounded, since a parent's pid may be reused meanwhile.
    private static func descendsFromDaemon(_ record: ProcessRecord) -> Bool {
        var parent = record.parentPid
        for _ in 0..<64 where parent > 1 {
            if parent == getpid() { return true }
            guard let next = ProcessTable.record(pid: parent) else { return false }
            parent = next.parentPid
        }
        return false
    }

    // MARK: - exec

    private func run(_ spec: ExecSpec) async throws -> ExecResult {
        // A fixed, minimal environment: rules declare executables by absolute
        // path, so nothing here should depend on the daemon's environment.
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        let ownProcesses = self.ownProcesses
        // The identity stays until the tracker observes the exit, which can
        // come after `run` returns; removing it here would report the
        // child's own events as the system's.
        do {
            return try await ChildProcess.run(
                path: spec.path, arguments: spec.arguments, environment: environment, stdin: spec.stdin,
                timeout: spec.timeout, outputLimit: ExecResult.outputLimit
            ) { pid in
                guard let identity = ProcessTable.record(pid: pid)?.identity else { return }
                ownProcesses.insert(identity)
            }
        } catch {
            throw EffectError.failed("\(error)")
        }
    }

    // MARK: - http

    private func fetch(_ spec: HTTPSpec, allowed: [URLOrigin]) async throws -> JSONValue {
        var request = URLRequest(url: spec.url, timeoutInterval: spec.timeout)
        request.httpMethod = spec.method.rawValue
        for (name, value) in spec.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = spec.body.map { Data($0.utf8) }

        // `timeoutInterval` above bounds the wait between bytes; the resource
        // timeout bounds the whole exchange, so a server that trickles bytes
        // cannot hold the rule's effect queue past `timeout`.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = spec.timeout
        let session = URLSession(
            configuration: configuration, delegate: RedirectGuard(allowed: allowed), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, received) = try await session.bytes(for: request)
            response = received
            // The body is cut at `outputLimit` while it arrives, not after
            // buffering all of it.
            for try await byte in bytes {
                data.append(byte)
                if data.count >= ExecResult.outputLimit { break }
            }
        } catch {
            throw EffectError.failed(
                "http \(spec.method.rawValue) \(spec.url.absoluteString): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw EffectError.failed("http: not an HTTP response") }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return try JSONValue(
            encoding: HTTPResponse(
                status: http.statusCode, headers: headers, body: String(decoding: data, as: UTF8.self)))
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        let allowed: [URLOrigin]
        init(allowed: [URLOrigin]) { self.allowed = allowed }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let url = request.url, let origin = URLOrigin(url: url), allowed.contains(origin) else { return nil }
            return request
        }
    }

    // MARK: - store.record

    private func record(_ spec: RecordSpec) async throws {
        let path = sampleDatabasePath
        // Read per write, so a change to meerkat.json applies to the next one.
        let limits = sampleLimits()
        let sample = try await SystemSampler.sample(
            SystemSampler.Options(window: spec.window, top: spec.top, systemOnly: spec.systemOnly))
        // A write can wait up to the store's busy timeout behind another
        // writer (the CLI); that wait belongs on a dispatch thread too.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    with: Result {
                        try SampleStore(path: path, limits: limits).record(
                            sample, label: spec.label, retain: spec.retain)
                    })
            }
        }
    }
}

/// Decides whether a rule may have an effect: its grant from the effect
/// catalog (docs/design/effects.md), the privacy permission it needs, and the
/// checks its descriptor declares (`EffectDescriptor.Traits`). It performs
/// nothing, so the executor and a dry run ask the same question; the daemon
/// builds one and gives it to both.
struct EffectAuthorizer: Sendable {
    let permissionStatus: EventDescriptor.Permission.StatusReader
    /// What no effect may change, whatever the rule's grants: the same
    /// paths Deno's APIs are denied (`RuleEngine.ProtectedPaths.write`).
    let protectedPaths: [String]

    init(permissionStatus: @escaping EventDescriptor.Permission.StatusReader, protectedPaths: [String]) {
        self.permissionStatus = permissionStatus
        self.protectedPaths = protectedPaths
    }

    /// Decodes a rule's request and decides it. What this refuses is what
    /// both perform and a dry run refuse.
    func admit(_ raw: JSONValue, for rule: RuleDefinition) throws -> EffectRequest {
        let request = try EffectRequest(raw)
        try decide(request, for: rule)
        return request
    }

    /// `admit` for a request already decoded.
    func decide(_ request: EffectRequest, for rule: RuleDefinition) throws {
        try authorize(request, grants: rule.grants)
        if let field = request.descriptor.traits.lastsWithinTimeout {
            let seconds = try Self.declared(field, of: request, \.numberValue)
            guard Duration.seconds(seconds) < rule.timeout else {
                throw EffectError.invalid(
                    "\(request.kind): \(field) (\(NumberBounds.format(seconds))) must be less than the rule's timeoutSeconds"
                )
            }
        }
    }

    func authorize(_ request: EffectRequest, grants: CapabilityGrants) throws {
        try refuseProtected(request)
        let effect = request.descriptor
        switch effect.grant {
        case .none:
            break
        case .flag(let key):
            guard grants.has(key) else {
                throw EffectError.notGranted(EffectCatalog.standard.grantText(key, entry: nil))
            }
        case .listed(let key, _):
            let grant = EffectCatalog.standard.grant(key)
            let entry = effect.traits.path?.form == .entry
            guard let grant, let subject = request.subject,
                grants.allows(key, subject: subject, shape: grant.shape, entry: entry)
            else {
                throw EffectError.notGranted(
                    EffectCatalog.standard.grantText(key, entry: Self.entry(for: request, in: grant)))
            }
        }
        if let permission = effect.permission, permissionStatus(permission) != .granted {
            throw EffectError.failed(
                "\(request.kind) needs \(permission.named): enable Meerkat in \(permission.settingsPane)"
            )
        }
    }

    /// A rule that could change the daemon's own settings, rules or state
    /// could widen its own grants, so no grant allows it. Reading is fine.
    ///
    /// The path is taken in the form the effect acts on (the link itself for
    /// an `entry` path, what it leads to for a `target` one), and compared
    /// with each protected path in every form it has
    /// (`CapabilityGrants.forms`): a protected folder reached through
    /// symlinks is still above or inside whatever is moved, and so is each
    /// link on its way.
    private func refuseProtected(_ request: EffectRequest) throws {
        let traits = request.descriptor.traits
        if let field = traits.changesDefaultsDomain,
            DaemonPaths.isOwnDomain(try Self.declared(field, of: request, \.stringValue))
        {
            throw EffectError.invalid("\(request.kind): no rule may change Meerkat's own defaults domain")
        }
        if let declared = traits.path, declared.isProtected {
            guard let path = request.path else { throw EffectError.invalid("\(request.kind): has no path to check") }
            let target = declared.form == .entry ? CapabilityGrants.entry(path) : CapabilityGrants.resolved(path)
            guard CapabilityGrants.protectedPath(touchedBy: target, in: protectedPaths) == nil else {
                throw EffectError.invalid("\(request.kind): \(path) holds Meerkat's rules, state or app")
            }
        }
    }

    /// The field a trait's check reads. The catalog keeps each one present
    /// (`EffectCatalog`); a request without it is refused, never let through
    /// unchecked.
    private static func declared<T>(_ field: String, of request: EffectRequest, _ read: (JSONValue) -> T?) throws -> T {
        guard let value = request.fields[field].flatMap(read) else {
            throw EffectError.invalid("\(request.kind): has no \(field) to check")
        }
        return value
    }

    /// The list entry that would allow the request, for the refusal message.
    private static func entry(for request: EffectRequest, in grant: GrantDescriptor?) -> String? {
        guard let subject = request.subject else { return nil }
        switch grant?.shape {
        case .allowList(.origin)?:
            guard let url = URL(string: subject) else { return subject }
            return "\(url.scheme ?? "https")://\(url.host ?? "")"
        case .allowList(.scheme)?:
            return URL(string: subject)?.scheme ?? subject
        case .pathList?:
            return (subject as NSString).deletingLastPathComponent
        default:
            return subject
        }
    }
}
