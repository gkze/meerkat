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
final class EffectExecutor: Sendable {
    private let store: RuleStore
    private let ownProcesses: OwnProcesses
    private let notifier: any Notifier
    private let sampleDatabasePath: String
    /// The sample store's budget as `meerkat.json` sets it now.
    private let sampleLimits: @Sendable () -> SampleStore.Limits
    private let authorizer: EffectAuthorizer
    private let controls: any SystemControls
    /// Power assertions by rule id, then by the rule's own id for them.
    /// Released when the rule stops (`releaseHeld`).
    private let assertions = Mutex<[String: [String: UInt32]]>([:])

    static let outputLimit = 1 << 20
    static let shortcutsExecutable = "/usr/bin/shortcuts"

    init(
        store: RuleStore, ownProcesses: OwnProcesses, notifier: any Notifier, sampleDatabasePath: String,
        sampleLimits: @escaping @Sendable () -> SampleStore.Limits = { .standard }, protectedPaths: [String] = [],
        controls: any SystemControls = MacSystemControls(),
        permissionStatus: @escaping EventDescriptor.Permission.StatusReader = { $0.status }
    ) {
        authorizer = EffectAuthorizer(permissionStatus: permissionStatus, protectedPaths: protectedPaths)
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
            if let act = pathEffect(request.action) {
                // Checked and done with rules' renames held off, so no rule's
                // code swaps a folder on the path between the two.
                let value = try await DenoRuntime.holdingRuleRenames {
                    try authorizer.decide(request, for: rule)
                    return try act()
                }
                return .success(value: value.canonicalString)
            }
            try authorizer.decide(request, for: rule)
            return .success(value: try await execute(request.action, rule: rule).canonicalString)
        } catch let error as EffectError {
            return .failure(message: error.description)
        } catch {
            return .failure(message: "\(error)")
        }
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

    private func execute(_ action: EffectRequest.Action, rule: RuleDefinition) async throws -> JSONValue {
        switch action {
        case .stateGet(let key):
            return EffectDescriptor.Result.found(try store.value(rule: rule.id, key: key))
        case .stateSet(let key, let value):
            try store.setValue(value, rule: rule.id, key: key)
            return .null
        case .stateDelete(let key):
            try store.deleteValue(rule: rule.id, key: key)
            return .null
        case .notify(let spec):
            try await notifier.post(NotificationPlan(rule: rule, spec: spec))
            return .null
        case .withdrawNotification(let id):
            try await notifier.withdraw(identifier: NotificationPlan.identifier(ruleId: rule.id, id: id))
            return .null
        case .signal(let target, let signal):
            try verifyOwnProcess(target)
            // An exit the signal causes is the daemon's doing; nothing else
            // about the process is (`OwnProcesses.expectExit`). It is expected
            // before the signal is sent, since the exit can be observed
            // before `kill` returns, and withdrawn on failure only if this
            // call added it.
            let expected = signal.terminates && ownProcesses.expectExit(target)
            guard kill(target.pid, signal.number) == 0 else {
                if expected { ownProcesses.withdrawExpectedExit(target) }
                throw EffectError.failed(
                    "kill(\(target.pid), \(signal.rawValue)) failed: \(String(cString: strerror(errno)))")
            }
            return .null
        case .priority(let target, let priority):
            try verifyOwnProcess(target)
            let value = priority == .background ? PRIO_DARWIN_BG : 0
            guard setpriority(PRIO_DARWIN_PROCESS, id_t(target.pid), value) == 0 else {
                throw EffectError.failed("setpriority(\(target.pid)) failed: \(String(cString: strerror(errno)))")
            }
            return .null
        case .nice(let target, let nice):
            try verifyOwnProcess(target)
            guard setpriority(PRIO_PROCESS, id_t(target.pid), nice) == 0 else {
                throw EffectError.failed(
                    "setpriority(\(target.pid), \(nice)) failed: \(String(cString: strerror(errno))); only lowering priority is allowed"
                )
            }
            return .null
        case .exec(let spec):
            return try JSONValue(encoding: await run(spec))
        case .http(let spec):
            return try await fetch(spec, allowed: rule.grants.httpOrigins)
        case .record(let spec):
            try await record(spec)
            return .null
        case .preventSleep(let spec):
            let assertion = try controls.preventSleep(
                name: "Meerkat rule \(rule.id)", reason: spec.reason, display: spec.display, timeout: spec.timeout)
            let replaced = assertions.withLock { held in
                held[rule.id, default: [:]].updateValue(assertion, forKey: spec.id)
            }
            if let replaced { controls.allowSleep(replaced) }
        case .allowSleep(let id):
            let released = assertions.withLock { $0[rule.id]?.removeValue(forKey: id) }
            if let released { controls.allowSleep(released) }
        case .audioDefaultDevice(let uid, let scope):
            try controls.setDefaultAudioDevice(uid: uid, scope: scope)
        case .audioVolume(let volume, let scope, let device):
            try controls.setVolume(volume, scope: scope, device: device)
        case .audioMute(let muted, let scope, let device):
            try controls.setMute(muted, scope: scope, device: device)
        case .openApplication(let bundleId, let activate):
            try await controls.openApplication(bundleId: bundleId, activate: activate)
        case .controlApplication(let bundleId, let action):
            try await controls.control(bundleId: bundleId, action: action)
        case .openURL(let url):
            try await controls.open(url)
        case .ejectVolume(let path):
            try await controls.ejectVolume(path: path)
        case .trash, .setTags:
            return try pathEffect(action)?() ?? .null
        case .readDefault(let domain, let key):
            return EffectDescriptor.Result.found(try controls.readDefault(domain: domain, key: key))
        case .writeDefault(let domain, let key, let value):
            try controls.writeDefault(domain: domain, key: key, value: value)
        case .deleteDefault(let domain, let key):
            try controls.deleteDefault(domain: domain, key: key)
        case .runShortcut(let spec):
            return try JSONValue(encoding: await runShortcut(spec))
        case .wifiPower(let on):
            try controls.setWiFiPower(on)
        case .readClipboard:
            return EffectDescriptor.Result.found(await controls.readClipboard().map(JSONValue.string))
        case .writeClipboard(let text):
            await controls.writeClipboard(text)
        case .listWindows(let bundleId):
            return try JSONValue(encoding: controls.windows(bundleId: bundleId))
        case .setWindow(let change):
            try controls.setWindow(change)
        case .darkMode(let on):
            try await controls.setDarkMode(on)
        }
        return .null
    }

    /// `shortcuts run`, with the input and output through files: the command
    /// reads input and writes output only by path.
    private func runShortcut(_ spec: ShortcutSpec) async throws -> ChildProcess.Result {
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
            result.stdout = String(decoding: data.prefix(Self.outputLimit), as: UTF8.self)
        }
        return result
    }

    /// The target must still be the same process, and ours to act on.
    private func verifyOwnProcess(_ target: ProcessIdentity) throws {
        guard let record = ProcessTable.record(pid: target.pid), record.identity == target else {
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

    /// What an effect that acts on a path does, for `perform` to run with
    /// rules' renames held off; nil for other effects. The path is one rule
    /// code may also rename, inside its grants.
    private func pathEffect(_ action: EffectRequest.Action) -> (@Sendable () throws -> JSONValue)? {
        let controls = self.controls
        switch action {
        case .trash(let path):
            return { .object(["trashedPath": .string(try controls.trash(path: path))]) }
        case .setTags(let path, let tags):
            return {
                try controls.setTags(path: path, tags: tags)
                return .null
            }
        default:
            return nil
        }
    }

    // MARK: - exec

    private func run(_ spec: ExecSpec) async throws -> ChildProcess.Result {
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
                timeout: spec.timeout, outputLimit: Self.outputLimit
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
                if data.count >= Self.outputLimit { break }
            }
        } catch {
            throw EffectError.failed(
                "http \(spec.method.rawValue) \(spec.url.absoluteString): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw EffectError.failed("http: not an HTTP response") }
        var headers: [String: JSONValue] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = .string(value) }
        }
        return .object([
            "status": .number(Double(http.statusCode)),
            "headers": .object(headers),
            "body": .string(String(decoding: data, as: UTF8.self)),
        ])
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
        // The sampler sleeps through its window; that belongs on a dispatch
        // thread, not on one of the few Swift concurrency threads every actor
        // in the daemon shares.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let sample = try SystemSampler.sample(
                        SystemSampler.Options(
                            window: spec.window, top: spec.top, systemOnly: spec.systemOnly
                        ))
                    let directory = (path as NSString).deletingLastPathComponent
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let store = try SampleStore(path: path, limits: limits)
                    // A sample that was committed still gets its retention;
                    // the limits failure is the effect's error afterwards.
                    var unapplied: LimitsNotAppliedError?
                    do {
                        try store.insert(label: spec.label, sample: sample)
                    } catch let error as LimitsNotAppliedError {
                        unapplied = error
                    }
                    if let retain = spec.retain { try store.retainNewest(retain, label: spec.label) }
                    if let unapplied { throw unapplied }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Decides whether a rule may have an effect: its grant from the effect
/// catalog (docs/design/effects.md) and the privacy permission it needs. It
/// performs nothing, so the executor and a dry run ask the same question.
struct EffectAuthorizer: Sendable {
    var permissionStatus: EventDescriptor.Permission.StatusReader = { $0.status }
    /// What no effect may change, whatever the rule's grants: the same
    /// paths Deno's APIs are denied (`RuleEngine.ProtectedPaths.write`).
    var protectedPaths: [String] = []

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
        // The measurement takes `window`, so a window as long as the
        // handler's timeout can only time the invocation out.
        if case .record(let spec) = request.action, Duration.seconds(spec.window) >= rule.timeout {
            throw EffectError.invalid(
                "store.record: windowSeconds (\(spec.window)) must be less than the rule's timeoutSeconds")
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
            guard let grant, let subject = request.subject,
                grants.allows(key, subject: subject, shape: grant.shape, entry: request.actsOnEntry)
            else {
                throw EffectError.notGranted(
                    EffectCatalog.standard.grantText(key, entry: Self.entry(for: request, in: grant)))
            }
        }
        if let permission = effect.permission, permissionStatus(permission) != .granted {
            throw EffectError.failed(
                "\(request.kind) needs the \(permission.rawValue) permission: allow meerkatd in \(permission.settingsPane)"
            )
        }
    }

    /// A rule that could change the daemon's own settings, rules or state
    /// could widen its own grants, so no grant allows it. Reading is fine.
    ///
    /// The path is taken in the form the effect acts on (the link itself for
    /// `trash`, what it leads to for `setTags`), and compared with each
    /// protected path in every form it has (`CapabilityGrants.forms`): a
    /// protected folder reached through symlinks is still above or inside
    /// whatever is moved, and so is each link on its way.
    private func refuseProtected(_ request: EffectRequest) throws {
        switch request.action {
        case .writeDefault(let domain, _, _), .deleteDefault(let domain, _):
            guard !DaemonPaths.isOwnDomain(domain) else {
                throw EffectError.invalid("\(request.kind): no rule may change Meerkat's own defaults domain")
            }
        case .trash(let path), .setTags(let path, _):
            let target = request.actsOnEntry ? CapabilityGrants.entry(path) : CapabilityGrants.resolved(path)
            guard CapabilityGrants.protectedPath(touchedBy: target, in: protectedPaths) == nil else {
                throw EffectError.invalid("\(request.kind): \(path) holds Meerkat's rules, state or app")
            }
        default:
            break
        }
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
