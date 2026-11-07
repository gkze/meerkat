import CryptoKit
import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRules
import MeerkatRuntimeBindings
import MeerkatStore
import os

/// Loads rules from the rules directory and runs them against the hub.
///
/// Reload is the only way the rule set changes: compile everything, load it
/// into a fresh host, decode every definition, then replace the running rules
/// in one step. Rules whose definition did not change keep their running
/// subscription. A failed compile or load leaves the affected files' rules
/// failed and every other file's rules running.
actor RuleEngine {
    struct Configuration: Sendable {
        var rulesDirectory: URL
        var cacheDirectory: URL
        var toolchain: TypeScriptToolchain?
        var runtime: HandlerRuntime?
        /// Lints the rules directory beside each reload; nil lints nothing.
        var linter: RuleLinter? = nil
        /// What no rule's code may read or write through Deno's APIs,
        /// whatever its grants: the daemon's own state, and its rules (a rule
        /// that could rewrite rules could widen its own grants).
        var protected = ProtectedPaths()
        var reloadDebounce: Duration = .milliseconds(250)
        /// Deadline for one entry file's top-level code.
        var loadDeadline: Duration = .seconds(5)
        /// `meerkat.json`, which lives in the rules directory and reloads
        /// beside the rules but never waits on their compile; nil reads none.
        var settings: DaemonSettings? = nil
    }

    struct ProtectedPaths: Sendable, Equatable {
        var read: [String] = []
        var write: [String] = []
    }

    nonisolated let configuration: Configuration
    private let hub: EventHub
    private let store: RuleStore
    private let executor: EffectExecutor
    private let logger = Logger(subsystem: DaemonService.label, category: "rules")

    private var host: HandlerHost?
    private var hostState: HandlerHostStatus.State = .idle
    private var hostRestarts = 0
    private var lastHostExit: String?
    private var restartTask: Task<Void, Never>?
    private var backoff = HostBackoff()
    /// Per-rule effect queues for the current host: effects of one rule run
    /// in the order its handler asked for them, without one rule's slow
    /// effect holding up another's.
    private var effectQueues: [String: AsyncStream<QueuedEffect>.Continuation] = [:]
    private var queuedEffects: [String: Int] = [:]
    /// Effects one rule may have waiting; beyond it requests fail at once.
    static let maximumQueuedEffects = 512

    private struct QueuedEffect: Sendable {
        let host: HandlerHost
        let call: UInt64
        let invocation: UInt64
        /// The rule instance and dispatch run that asked: a disable, or a
        /// reload that replaced the rule, ends them before the effect runs.
        let token: UUID
        let run: Int
        /// The definition in force when the effect was requested: grants are
        /// checked against it, not against a later reload's.
        let definition: RuleDefinition
        let request: JSONValue
    }

    /// When each rule, or each file when no handler of it was running, last
    /// ended the host (`recordFault`); one that keeps ending it is disabled,
    /// or its file excluded until it changes.
    private var faults: [String: [Double]] = [:]
    private var excludedFiles: [String: (reason: String, fileHash: String)] = [:]
    static let faultLimit = 3
    static let faultWindow = 300.0

    private var rules: [String: ActiveRule] = [:]
    /// Rules switched off, with their file and its content hash when that
    /// happened: editing the file switches them back on. Kept by the file,
    /// not by what the last load returned, so a load that failed once does
    /// not forget a disable.
    private var disabled: [String: (reason: String, file: String, fileHash: String)] = [:]
    private var failed: [RuleSummary] = []
    private var diagnostics: [RuleDiagnostic] = []
    private var compiledAt: Double?
    /// The last finished lint, and the one in progress. A reload starts a
    /// new lint and cancels the old one, whose result would be stale.
    private var lint: LintReport?
    private var lintTask: Task<Void, Never>?
    private var watcher: EventSubscription?
    private var watchTask: Task<Void, Never>?
    /// What `watcher` watches.
    private var watched: WatchPlan?
    /// Why the rules directory is not there or not watched, for `report()`:
    /// edits then reload nothing until `meerkat rules reload`, which watches
    /// it again.
    private var directoryProblem: String?
    private var watcherProblem: String?
    private var reloadTask: Task<Void, Never>?
    private var generation = 0
    /// Digest of every rule source at the last load, so a burst of file
    /// events that changed nothing (an editor's save dance, events for
    /// writes that predate the watcher) does not reload.
    private var loadedDigest: String?

    /// What decides whether a rule may observe its kind, and what it sees.
    nonisolated let observation: ObservationScope

    init(configuration: Configuration, hub: EventHub, store: RuleStore, executor: EffectExecutor) {
        self.configuration = configuration
        self.hub = hub
        self.store = store
        self.executor = executor
        observation = ObservationScope(protected: configuration.protected, environment: hub.environment)
    }

    // MARK: - Lifecycle

    func start() async {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: configuration.rulesDirectory, withIntermediateDirectories: true)
        } catch {
            directoryProblem = "the rules folder \(configuration.rulesDirectory.path) cannot be created: \(error)"
            logger.error("\(self.directoryProblem ?? "", privacy: .public)")
        }
        // The compile reports a cache it cannot write to.
        try? fileManager.createDirectory(at: configuration.cacheDirectory, withIntermediateDirectories: true)
        await writeEditorSupport()
        configuration.settings?.reload()
        watchRulesDirectory()
        await reload()
    }

    func shutdown() async {
        // Anything still reloading applies nothing.
        generation += 1
        watchTask?.cancel()
        watcher?.cancel()
        reloadTask?.cancel()
        settingsReloadTask?.cancel()
        restartTask?.cancel()
        for rule in rules.values { rule.stop() }
        rules.removeAll()
        await retireHost(reason: "daemon shutting down")
    }

    // MARK: - Reload

    /// Recompiles and reloads. `force` is false only for reloads the file
    /// watcher triggers, which are skipped when no rule source changed.
    func reload(force: Bool = true) async {
        // Cheap and independent of the compile, so every reload rereads it,
        // and a reload that compiles nothing still applies its file scope.
        configuration.settings?.reload()
        recheckFileScope()
        // A watcher that could not start, or whose source stopped, is tried
        // again: what `watcherProblem` tells the user to do. One running
        // follows a `meerkat.json` link made or moved since it started.
        if watcher == nil, watcherProblem != nil { watchRulesDirectory() } else { watchAgainIfMoved() }
        let digest = sourcesDigest()
        if !force, digest == loadedDigest { return }
        loadedDigest = digest
        // This reload supersedes a pending crash restart.
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        let thisGeneration = generation
        await writeEditorSupport()
        startLint(generation: thisGeneration)

        guard let runtime = configuration.runtime, let toolchain = configuration.toolchain else {
            let (tool, missing): (RuleDiagnostic.Tool, String) =
                configuration.runtime == nil
                ? (.loader, "no rule runtime is available") : (.compiler, "the TypeScript compiler was not found")
            replaceRules(
                with: [], failures: [],
                diagnostics: [.toolFailure(tool, message: "\(missing); rules cannot load")])
            return
        }

        let output: RuleCompiler.Output
        do {
            output = try await RuleCompiler(toolchain: toolchain).compile(
                rulesDirectory: configuration.rulesDirectory,
                workDirectory: configuration.cacheDirectory.appendingPathComponent("build-\(UUID().uuidString)"),
                declarations: TypeScriptDeclarations.render(hub.catalog),
                runtimeDeclarations: runtime.declarations
            )
        } catch {
            guard thisGeneration == generation else { return }
            // Nothing compiled, so nothing runs: the host with the previous
            // rules goes too, and the next reload compiles again even with
            // the same sources, since the compiler failed and not they.
            loadedDigest = nil
            await retireHost(reason: "rules did not compile")
            guard thisGeneration == generation else { return }
            replaceRules(
                with: [], failures: [],
                diagnostics: [.toolFailure(.compiler, message: "\(error)")])
            return
        }
        guard thisGeneration == generation else { return }
        // A cancelled reload (daemon shutdown) applies nothing, and forgets
        // the digest so the next reload is not skipped as unchanged.
        if Task.isCancelled {
            loadedDigest = nil
            return
        }
        compiledAt = Date().timeIntervalSince1970 * 1000

        var failures = output.rejected.compactMap { id, reason -> RuleSummary? in
            // Only entry files are rules; rejected helper modules surface
            // through the entries that import them.
            id.contains("/") ? nil : Self.failedFile(id + ".ts", reason: reason)
        }
        var loadDiagnostics = output.diagnostics
        var entries = output.entries
        var rejected = output.rejected

        // Files excluded for ending the host stay out until they change.
        let hashes = fileHashes()
        excludedFiles = excludedFiles.filter { hashes[$0.key] == $0.value.fileHash }
        for (file, exclusion) in excludedFiles {
            let id = RuleCompiler.moduleId(file)
            guard entries.contains(id) else { continue }
            entries.removeAll { $0 == id }
            rejected[id] = "\(file) \(exclusion.reason)"
            failures.append(Self.failedFile(file, reason: exclusion.reason))
        }

        // A file whose top-level code fails or overruns its deadline fails
        // alone, in its result; anything else that ends the host retries
        // with the crash backoff.
        var results: [HandlerHost.LoadedEntry] = []
        var loadedHost: HandlerHost?
        if !entries.isEmpty {
            do {
                // This reload replaces the host; a restart scheduled by a
                // crash while it compiled is redundant now.
                restartTask?.cancel()
                restartTask = nil
                await retireHost(reason: "rules reloaded")
                let host = try await startHost()
                guard thisGeneration == generation else { return }
                results = try await host.load(
                    modules: output.modules, entries: entries, rejected: rejected,
                    entryDeadline: configuration.loadDeadline)
                guard thisGeneration == generation else { return }
                loadedHost = host
            } catch {
                guard thisGeneration == generation else { return }
                failures += entries.map { Self.failedFile($0 + ".ts", reason: "\(error)") }
                entries = []
                results = []
                // The host could not start or stopped for no file's reason:
                // try again with the crash backoff rather than never.
                scheduleRestart(after: "\(error)")
            }
        }
        if results.isEmpty {
            await retireHost(reason: "no rules to run")
            guard thisGeneration == generation else { return }
        }

        var definitions: [RuleDefinition] = []
        var unreported = Set(entries)
        for result in results {
            // The host runs user code; accept one result per file the daemon
            // asked it to load, and nothing else.
            guard unreported.remove(result.entry) != nil else { continue }
            let file = result.entry + ".ts"
            if let error = result.error {
                failures.append(Self.failedFile(file, reason: error.message))
                loadDiagnostics.append(
                    RuleDiagnostic(tool: .loader, file: file, message: error.report, fixable: false))
                continue
            }
            let loaded = result.definitions(file: file, catalog: hub.catalog, observation: observation)
            definitions += loaded.definitions
            for failure in loaded.failures {
                failures.append(
                    RuleSummary(
                        id: RuleID.make(file: file, name: failure.name), file: file, event: failure.event,
                        state: .failed, reason: failure.reason, invocations: 0, failures: 0,
                        lastInvokedAt: nil, lastError: nil))
                loadDiagnostics.append(failure.diagnostic)
            }
        }
        if let loadedHost {
            // Each file's code gets its rules' file grants before any handler
            // runs; until now it had none.
            for (entry, permissions) in Self.permissions(for: definitions, protected: configuration.protected) {
                await loadedHost.permit(entry: entry, permissions: permissions)
            }
            guard thisGeneration == generation else { return }
            // Running only once loaded and permitted: until now, kept rules'
            // events were dropped instead of invoking into a half-loaded host.
            if self.host === loadedHost {
                if await loadedHost.isAlive {
                    hostState = .running
                    backoff.running(since: .now)
                } else {
                    // It stopped after answering, while not yet running, so
                    // its exit was not handled as a crash: the rules it loaded
                    // stand, and it restarts here. (A file whose code ended
                    // it was charged through its fault.)
                    host = nil
                    scheduleRestart(after: "the handler host stopped right after loading")
                }
            }
        }
        replaceRules(with: definitions, failures: failures, diagnostics: loadDiagnostics)
        await replayMissedState()
    }

    /// The file is the unit Deno's permissions apply to (one worker per
    /// file), so a file's code may do what any of its rules was granted.
    static func permissions(for definitions: [RuleDefinition], protected: ProtectedPaths) -> [String: FilePermissions] {
        var permissions: [String: FilePermissions] = [:]
        for definition in definitions {
            let entry = RuleCompiler.moduleId(definition.file)
            var file = permissions[entry] ?? FilePermissions(denyRead: protected.read, denyWrite: protected.write)
            for path in definition.grants.fsRead where !file.read.contains(path) { file.read.append(path) }
            for path in definition.grants.fsWrite where !file.write.contains(path) { file.write.append(path) }
            permissions[entry] = file
        }
        return permissions
    }

    /// Kept `state` rules that dropped events while the host was replaced
    /// get the current value, so a transition during a reload is not lost.
    ///
    /// The replay goes into the rule's own subscription, so it passes the
    /// rule's origin filter, `match` and rate like any event, and never
    /// overlaps the rule's other invocations.
    private func replayMissedState() async {
        for rule in rules.values where rule.missedDuringRestart {
            rule.missedDuringRestart = false
            guard hub.catalog.kind(named: rule.definition.event)?.descriptor.semantics == .state else { continue }
            rule.replayLatest(in: hub)
        }
    }

    private static func failedFile(_ file: String, reason: String) -> RuleSummary {
        RuleSummary(
            id: file, file: file, event: nil, state: .failed, reason: reason, invocations: 0, failures: 0,
            lastInvokedAt: nil, lastError: nil)
    }

    private func replaceRules(
        with definitions: [RuleDefinition], failures: [RuleSummary], diagnostics: [RuleDiagnostic]
    ) {
        let previous = rules
        rules.removeAll()

        let hashes = fileHashes()
        // Keep a disable only while its file is unchanged.
        disabled = disabled.filter { hashes[$0.value.file] == $0.value.fileHash }

        for definition in definitions {
            // An unchanged rule keeps its subscription, statistics and
            // breaker: editing one file must not restart every source, or
            // replay every `state` event to rules that did not change.
            if let old = previous[definition.id], old.definition == definition, !old.isFailed,
                old.isDisabled == (disabled[definition.id] != nil)
            {
                rules[definition.id] = old
                continue
            }
            let active = ActiveRule(definition: definition)
            rules[definition.id] = active
            if let entry = disabled[definition.id] {
                active.markDisabled(entry.reason)
                continue
            }
            subscribe(active)
        }

        for (id, rule) in previous where rules[id] !== rule {
            rule.stop()
            if rules[id] == nil {
                announce(RuleStatusPayload(ruleId: id, file: rule.definition.file, state: .unloaded))
            }
        }
        // What a rule holds beyond an invocation (power assertions) lasts only
        // while that same definition stays loaded and enabled.
        executor.releaseHeld(
            keeping: Set(rules.compactMap { id, rule in previous[id] === rule && !rule.isDisabled ? id : nil }))
        for failure in failures {
            announce(RuleStatusPayload(ruleId: failure.id, file: failure.file, state: .failed, reason: failure.reason))
            log(rule: failure.id, level: .error, "failed to load: \(failure.reason ?? "unknown error")")
        }
        self.failed = failures
        self.diagnostics = diagnostics
        for diagnostic in diagnostics { logger.error("\(diagnostic.description, privacy: .public)") }
    }

    private func subscribe(_ rule: ActiveRule) {
        let definition = rule.definition
        // Where the file scope is decided for a rule that starts: loading,
        // enabling, resuming and a reload that raced a `meerkat.json` change
        // all subscribe here, against the scope as it is now. A running
        // rule's is decided again when the scope changes
        // (`recheckFileScope`), through the same `requireFileScope`.
        do {
            try observation.requireFileScope(of: definition, in: hub.catalog)
            rule.outOfScope = false
        } catch {
            failOutOfScope(rule, reason: "\(error)")
            return
        }
        let subscription: EventSubscription
        do {
            subscription = try hub.subscribe(definition.parameters, subscriber: .rule(file: definition.file))
        } catch {
            rule.markFailed("could not subscribe to \(definition.event): \(error)")
            announce(
                RuleStatusPayload(ruleId: definition.id, file: definition.file, state: .failed, reason: "\(error)"))
            return
        }
        let id = definition.id
        let token = rule.token
        let hub = self.hub
        rule.run(
            subscription: subscription,
            view: hub.catalog.kind(named: definition.event).flatMap { observation.view(of: $0, for: definition) },
            invoke: { [weak self] envelope in
                await self?.invoke(id: id, token: token, envelope) ?? false
            },
            warn: { [weak self] message in
                await self?.log(rule: id, level: .warn, message)
            },
            ended: { [weak self] run in
                await self?.dispatchEnded(id: id, token: token, run: run, reason: hub.stopReason(of: subscription))
            })
        announce(RuleStatusPayload(ruleId: definition.id, file: definition.file, state: .loaded))
        log(rule: definition.id, level: .info, "loaded, listening for \(definition.event)")
    }

    // MARK: - Invocation

    /// Runs the handler for one admitted event. Returns false when the rule
    /// must stop dispatching (its breaker tripped).
    private func invoke(id: String, token: UUID, _ envelope: EventEnvelope) async -> Bool {
        guard let rule = rules[id], rule.token == token, !rule.isStopped else { return false }
        // One invocation of a rule at a time, even across a disable and
        // enable that starts a second dispatcher while one is in flight.
        await rule.gate.acquire()
        defer { rule.gate.release() }
        guard rules[id] === rule, !rule.isStopped else { return false }
        // Only reload starts a host (it must load the rules into it). While
        // the host restarts, events are dropped rather than queued: a handler
        // that killed the host should not be fed a backlog when it returns.
        guard let host, hostState == .running else {
            rule.missedDuringRestart = true
            rule.stats.droppedWhileRestarting += 1
            if rule.stats.droppedWhileRestarting == 1 {
                log(rule: id, level: .warn, "events are dropped while the handler host restarts")
            }
            return true
        }
        let now = Date().timeIntervalSince1970
        if let reason = rule.breaker.recordInvocation(now: now) {
            disable(rule, reason: reason)
            return false
        }

        rule.stats.invocations += 1
        rule.stats.lastInvokedAt = now * 1000
        let result = await host.invoke(rule: rule.definition.id, event: envelope, timeout: rule.definition.timeout)
        // A reload may have replaced the rule meanwhile; its outcome belongs
        // to the instance that ran, not to its successor.
        guard rules[id] === rule else { return false }

        let failure: String?
        switch result {
        case .completed(nil):
            failure = nil
        case .superseded:
            // The event was lost with the retired host; a `state` rule gets
            // the current value again once the next host has loaded.
            rule.missedDuringRestart = true
            failure = nil
        case .interrupted(let reason):
            // Another rule overran or the host crashed: not this rule's
            // fault, but the event was lost the same way.
            rule.missedDuringRestart = true
            log(rule: id, level: .warn, "interrupted: \(reason)")
            failure = nil
        case .completed(let error?):
            failure = error.report
        case .timedOut:
            failure = "did not finish within \(rule.definition.timeout.formatted())"
        }
        guard let failure else { return true }
        return recordFailure(rule, failure)
    }

    /// Counts a failure against a rule; returns false when its breaker
    /// tripped.
    @discardableResult
    private func recordFailure(_ rule: ActiveRule, _ failure: String) -> Bool {
        rule.stats.failures += 1
        rule.stats.lastError = failure
        log(rule: rule.definition.id, level: .error, failure)
        if let reason = rule.breaker.recordFailure(now: Date().timeIntervalSince1970) {
            disable(rule, reason: reason)
            return false
        }
        return true
    }

    /// A dispatcher ended without being stopped: its source finished (for
    /// example, it failed to start for a co-subscriber). The rule is not
    /// listening any more; say so, and why, instead of reporting it loaded.
    private func dispatchEnded(id: String, token: UUID, run: Int, reason: String) {
        // Only the current run of a rule that was not stopped: after a
        // disable and enable, the old dispatcher ending is not a failure.
        guard let rule = rules[id], rule.token == token, rule.runID == run, rule.state == .loaded else { return }
        rule.markFailed(reason)
        announce(RuleStatusPayload(ruleId: id, file: rule.definition.file, state: .failed, reason: reason))
        log(rule: id, level: .error, reason)
    }

    private func disable(_ rule: ActiveRule, reason: String) {
        rule.stop()
        executor.releaseHeld(keeping: Set(rules.keys.filter { $0 != rule.definition.id }))
        rule.markDisabled(reason)
        let file = rule.definition.file
        disabled[rule.definition.id] = (reason, file, fileHashes()[file] ?? "")
        announce(RuleStatusPayload(ruleId: rule.definition.id, file: file, state: .disabled, reason: reason))
        log(rule: rule.definition.id, level: .warn, "disabled: \(reason)")
    }

    func setEnabled(_ id: String, enabled: Bool) throws {
        guard let rule = rules[id] else { throw EngineError.unknownRule(id) }
        if enabled {
            guard disabled.removeValue(forKey: id) != nil else { return }
            rule.reset()
            subscribe(rule)
        } else if disabled[id] == nil {
            disable(rule, reason: "disabled with meerkat rules disable")
        }
    }

    enum EngineError: Error, CustomStringConvertible {
        case unknownRule(String)
        var description: String {
            switch self {
            case .unknownRule(let id): return "no loaded rule has id \(id)"
            }
        }
    }

    // MARK: - Host

    private func startHost() async throws -> HandlerHost {
        guard let runtime = configuration.runtime else {
            hostState = .unavailable
            throw HandlerHost.HostError.exited("no rule runtime is available")
        }
        hostState = .starting
        let host = HandlerHost(transport: runtime.makeHost())
        self.host = host
        Task { [weak self] in
            for await event in host.events {
                await self?.handle(event, from: host)
            }
        }
        do {
            try await host.start()
        } catch {
            if self.host === host {
                self.host = nil
                hostState = .idle
            }
            throw error
        }
        // `.running` is set by reload once the rules are loaded.
        return host
    }

    /// Replaces the current host on purpose (reload, shutdown): in-flight
    /// invocations end as superseded, and its exit is not treated as a crash.
    private func retireHost(reason: String) async {
        guard let host else { return }
        self.host = nil
        backoff.ended(at: .now)
        // A pending crash restart keeps reporting "backing off".
        if hostState != .backingOff { hostState = .idle }
        await host.stop(reason: reason, superseded: true)
    }

    private func handle(_ event: HandlerHost.Event, from source: HandlerHost) async {
        switch event {
        case .log(let rule, let level, let message):
            log(rule: rule, level: level, message)
        case .effect(let call, let invocation, let rule, let request):
            guard source === host, let active = rules[rule], !active.isStopped else {
                await source.respond(call: call, outcome: .failure(message: "rule \(rule) is not running"))
                return
            }
            guard queuedEffects[rule, default: 0] < Self.maximumQueuedEffects else {
                let message = "more than \(Self.maximumQueuedEffects) effects are waiting for \(rule)"
                await source.respond(call: call, outcome: .failure(message: message))
                return
            }
            queuedEffects[rule, default: 0] += 1
            effectQueue(for: rule).yield(
                QueuedEffect(
                    host: source, call: call, invocation: invocation, token: active.token, run: active.runID,
                    definition: active.definition, request: request))
        case .fault(let file, let rule, let reason):
            recordFault(file: file, rule: rule, reason: reason)
        case .exited(let reason):
            // Only the running host's exit is a crash. A retired host's exit
            // is the reload or shutdown that retired it, and a death while
            // starting or loading is handled by the reload that was waiting.
            guard source === host, hostState == .running else { return }
            lastHostExit = reason
            logger.error("handler host: \(reason, privacy: .public)")
            host = nil
            hostRestarts += 1
            backoff.ended(at: .now)
            scheduleRestart(after: reason)
        case .drained(let done):
            done.resume()
        }
    }

    /// Restarts after the crash backoff's delay.
    private func scheduleRestart(after reason: String) {
        hostState = .backingOff
        let delay = backoff.failed()
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reloadAfterRestart()
        }
    }

    private func reloadAfterRestart() async {
        // This task is `restartTask`; clear it so the reload's "cancel any
        // pending restart" does not cancel the reload itself.
        restartTask = nil
        await reload()
    }

    /// One queue per rule for the daemon's life: effects of a rule run in
    /// request order, across hosts too, and each is checked against its own
    /// invocation before it runs.
    private func effectQueue(for rule: String) -> AsyncStream<QueuedEffect>.Continuation {
        if let queue = effectQueues[rule] { return queue }
        let (stream, queue) = AsyncStream.makeStream(of: QueuedEffect.self)
        effectQueues[rule] = queue
        let executor = self.executor
        Task { [weak self] in
            for await effect in stream {
                let outcome: EffectOutcome
                if await self?.isCurrent(rule, token: effect.token, run: effect.run) != true {
                    // Disabled or replaced while this effect waited.
                    outcome = .failure(message: "the rule that asked for this was disabled or reloaded")
                } else if await effect.host.isRunning(effect.invocation) {
                    outcome = await executor.perform(effect.request, for: effect.definition)
                } else {
                    // The invocation ended (timed out, superseded, its host
                    // died) while this effect waited: do not act for it.
                    outcome = .failure(message: "the handler invocation that asked for this ended")
                }
                await effect.host.respond(call: effect.call, outcome: outcome)
                await self?.dequeued(rule)
            }
        }
        return queue
    }

    private func dequeued(_ rule: String) {
        queuedEffects[rule, default: 1] -= 1
    }

    /// Whether the rule instance and dispatch run that asked for an effect
    /// are still the ones running.
    private func isCurrent(_ id: String, token: UUID, run: Int) -> Bool {
        guard let rule = rules[id] else { return false }
        return rule.token == token && rule.runID == run && !rule.isStopped
    }

    /// A rule file's code ended the host (it held its thread, exhausted its
    /// heap, or broke its worker). Charged to the rule whose handler held the
    /// thread past its budget, else to the file (a heap is the file's, shared
    /// by all its rules); three within five minutes disable that rule, or
    /// exclude the file, until the file changes.
    ///
    /// The breaker cannot do this alone: it counts within a minute, and a
    /// handler that ends the host only after a long timeout fails less often
    /// than that once the host's restart is added. A fault outside any
    /// handler counts toward no breaker at all.
    private func recordFault(file: String, rule: String?, reason: String) {
        let now = Date().timeIntervalSince1970
        let culprit = rule ?? file
        var recent = (faults[culprit] ?? []).filter { now - $0 < Self.faultWindow }
        recent.append(now)
        faults[culprit] = recent
        log(rule: culprit, level: .error, "\(reason); the handler host restarts")
        guard recent.count >= Self.faultLimit else { return }
        faults[culprit] = nil
        let repeated = "ended the handler host \(Self.faultLimit) times within \(Int(Self.faultWindow / 60)) minutes"
        if let rule, let active = rules[rule] {
            if !active.isDisabled { disable(active, reason: repeated) }
        } else {
            let reason = "excluded: its code \(repeated)"
            excludedFiles[file] = (reason, fileHashes()[file] ?? "")
            log(rule: file, level: .error, reason)
        }
    }

    // MARK: - Logs

    private func log(rule: String?, level: LogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(rule ?? "-", privacy: .public): \(message, privacy: .public)")
        case .info: logger.info("\(rule ?? "-", privacy: .public): \(message, privacy: .public)")
        case .warn: logger.warning("\(rule ?? "-", privacy: .public): \(message, privacy: .public)")
        case .error: logger.error("\(rule ?? "-", privacy: .public): \(message, privacy: .public)")
        }
        do {
            try store.appendLog(rule: rule, level: level.rawValue, message: String(message.prefix(16_384)))
        } catch {
            logger.error("could not store a rule log line: \(error, privacy: .public)")
        }
    }

    private func announce(_ status: RuleStatusPayload) {
        hub.environment.internalEvents.send(.rule(status))
    }

    // MARK: - Reporting

    func report() -> RulesReport {
        let running = rules.values.map(\.summary)
        let settingsProblem = configuration.settings?.diagnostic.map { [$0] } ?? []
        // Until the folder exists, made by someone else after the failure.
        let missing = FileManager.default.fileExists(atPath: configuration.rulesDirectory.path) ? nil : directoryProblem
        let directoryProblems = [missing, watcherProblem].compactMap { $0 }.map {
            RuleDiagnostic.toolFailure(.loader, message: $0)
        }
        return RulesReport(
            rules: (running + failed).sorted { $0.id < $1.id },
            diagnostics: diagnostics + settingsProblem + directoryProblems, compiledAt: compiledAt, lint: lint)
    }

    // MARK: - Lint

    /// Lints the rules directory beside the compile. The result is kept only
    /// if no later reload started meanwhile; it changes nothing that runs.
    private func startLint(generation thisGeneration: Int) {
        guard let linter = configuration.linter else { return }
        lintTask?.cancel()
        let directory = configuration.rulesDirectory
        lintTask = Task {
            let report = await linter.check(directory)
            guard !Task.isCancelled, thisGeneration == generation else { return }
            lint = report
            for diagnostic in report.diagnostics { logger.info("lint: \(diagnostic.description, privacy: .public)") }
        }
    }

    /// Waits for the lint in progress, for tests and `rules lint`'s callers.
    func lintFinished() async {
        await lintTask?.value
    }

    func hostStatus() async -> HandlerHostStatus {
        let workers = await host?.workers ?? 0
        return HandlerHostStatus(state: hostState, workers: workers, restarts: hostRestarts, lastExit: lastHostExit)
    }

    func logs(rule: String?, limit: Int) throws -> [RuleLogEntry] {
        try store.logs(rule: rule, limit: limit)
    }

    // MARK: - Rules directory

    /// What the watcher watches: the rules folder, and `meerkat.json` where
    /// it lands when it is a symlink out of the folder.
    private struct WatchPlan: Equatable {
        /// In the form FSEvents reports paths (symlinks resolved, so
        /// `/var/folders` is `/private/var/folders`), or no event would match.
        var directory: String
        var paths: [String]
        /// `meerkat.json` by its folder's real path (the file may not exist
        /// yet) and, when it is a symlink, by its target's: FSEvents reports a
        /// write where it lands, and a dotfile manager's link lands outside the
        /// rules folder.
        var settingsFiles: Set<String>
    }

    private func watchPlan() -> WatchPlan {
        let directory =
            (try? eventPath(configuration.rulesDirectory.path, field: "rulesDirectory"))
            ?? configuration.rulesDirectory.standardizedFileURL.path
        var plan = WatchPlan(directory: directory, paths: [directory], settingsFiles: [])
        if let file = configuration.settings?.file {
            let folder = file.deletingLastPathComponent().path
            plan.settingsFiles.insert(
                ((try? eventPath(folder, field: "settings")) ?? folder) + "/" + file.lastPathComponent)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil,
                let target = try? eventPath(file.path, field: "settings"), !plan.settingsFiles.contains(target)
            {
                plan.settingsFiles.insert(target)
                // The target itself, not its folder: FSEvents watches a
                // folder whole, and a dotfile's folder may be the home folder.
                if !target.hasPrefix(directory + "/") { plan.paths.append(target) }
            }
        }
        return plan
    }

    /// Watches again when `meerkat.json` became a link, or leads elsewhere,
    /// since the watcher started: its edits would land where nothing looks.
    private func watchAgainIfMoved() {
        guard watcher != nil, watchPlan() != watched else { return }
        watchTask?.cancel()
        watcher?.cancel()
        watcher = nil
        watchRulesDirectory()
    }

    /// Watches the rules directory through the hub, like any other rule
    /// would, and reloads after the burst of writes an editor makes settles.
    private func watchRulesDirectory() {
        let plan = watchPlan()
        let directory = plan.directory
        let subscription: EventSubscription
        do {
            subscription = try hub.subscribe(
                "fs.change",
                parameters: .object([
                    "paths": .array(plan.paths.map(JSONValue.string)), "latency": .number(0.1),
                ]))
        } catch {
            watcherLost("cannot watch the rules folder \(directory): \(error)")
            return
        }
        watcher = subscription
        watched = plan
        watcherProblem = nil
        let hub = self.hub
        let debounce = configuration.reloadDebounce
        let supportDirectory = directory + "/.meerkat/"
        let settingsPaths = plan.settingsFiles
        watchTask = Task { [weak self] in
            for await event in subscription.events {
                guard let path = event.payload["path"]?.stringValue, !path.hasPrefix(supportDirectory) else { continue }
                if settingsPaths.contains(path) {
                    await self?.scheduleSettingsReload(after: debounce)
                    continue
                }
                // Rule sources, or a stream condition on the directory
                // itself (events were dropped, the directory moved). Outside
                // it, a condition can only be the settings target's: its edit
                // may be among what was dropped.
                let streamCondition = !(event.payload["streamFlags"]?.arrayValue?.isEmpty ?? true)
                guard path.hasPrefix(directory + "/") || path == directory else {
                    if streamCondition { await self?.scheduleSettingsReload(after: debounce) }
                    continue
                }
                guard path.hasSuffix(".ts") || streamCondition else { continue }
                await self?.scheduleReload(after: debounce)
            }
            // The stream ends on shutdown, or when its source failed.
            guard !Task.isCancelled else { return }
            await self?.watcherLost(
                "the rules folder is no longer watched: \(hub.stopReason(of: subscription))")
        }
    }

    private func watcherLost(_ problem: String) {
        watcher = nil
        watcherProblem = "\(problem); edits reload nothing until meerkat rules reload"
        logger.error("\(self.watcherProblem ?? "", privacy: .public)")
    }

    /// Debounces file events. Cancelling restarts only the wait: a reload
    /// already compiling is never cancelled (that would kill the compiler mid-run and
    /// read as "nothing compiles"); a newer reload supersedes it through
    /// `generation` instead.
    private func scheduleReload(after delay: Duration) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            Task { await self?.watchedReload() }
        }
    }

    private var settingsReloadTask: Task<Void, Never>?

    /// Applies `meerkat.json` once an editor's burst of writes settles,
    /// without recompiling any rule.
    private func scheduleSettingsReload(after delay: Duration) {
        settingsReloadTask?.cancel()
        let settings = configuration.settings
        settingsReloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            settings?.reload()
            await self?.watchAgainIfMoved()
            await self?.recheckFileScope()
        }
    }

    /// `fs.churn` without a root measures `meerkat.json`'s file scope, which
    /// can change under a loaded rule's `fs.read` grant. A running rule the
    /// scope has left is failed with why, before its next measurement can
    /// finish (the source reads the scope per window, and a window lasts at
    /// least half a second); one failed for it resumes through `subscribe`,
    /// which decides again, once its grant covers the scope. A disabled rule
    /// is decided when it is enabled.
    func recheckFileScope() {
        for rule in rules.values {
            let definition = rule.definition
            guard let kind = hub.catalog.kind(named: definition.event),
                ObservationScope.watchesFileScope(kind, parameters: definition.parameters)
            else { continue }
            let refusal: String?
            do {
                try observation.requireFileScope(of: definition, in: hub.catalog)
                refusal = nil
            } catch {
                refusal = "\(error)"
            }
            switch (rule.state, refusal) {
            case (.loaded, let reason?):
                failOutOfScope(rule, reason: reason)
            case (.failed, nil) where rule.outOfScope:
                rule.reset()
                subscribe(rule)
            default:
                continue
            }
        }
    }

    /// Fails `rule` because the file scope is outside its grant, so a later
    /// `recheckFileScope` resumes it.
    private func failOutOfScope(_ rule: ActiveRule, reason: String) {
        rule.markFailed(reason)
        rule.outOfScope = true
        announce(
            RuleStatusPayload(ruleId: rule.definition.id, file: rule.definition.file, state: .failed, reason: reason))
        log(rule: rule.definition.id, level: .error, reason)
    }

    private var watchedReloadRunning = false
    private var watchedReloadPending = false

    /// Single-flight for the watcher: at most one watched reload runs, and
    /// changes during it cause exactly one more, instead of a pile of
    /// concurrent compiles.
    private func watchedReload() async {
        guard !watchedReloadRunning else {
            watchedReloadPending = true
            return
        }
        watchedReloadRunning = true
        repeat {
            watchedReloadPending = false
            await reload(force: false)
        } while watchedReloadPending
        watchedReloadRunning = false
    }

    /// The rules directory's editor support: declarations and compiler
    /// options (`RuleCompiler.writeEditorSupport`), then the lint and format
    /// policy (`RuleLinter.writeConfiguration`), so an editor checks what the
    /// daemon checks.
    private func writeEditorSupport() async {
        do {
            try RuleCompiler.writeEditorSupport(
                in: configuration.rulesDirectory, declarations: TypeScriptDeclarations.render(hub.catalog),
                runtimeDeclarations: configuration.runtime?.declarations)
        } catch {
            logger.error("could not write the editor configuration: \(error, privacy: .public)")
        }
        configuration.settings?.writeSchema(rulesDirectory: configuration.rulesDirectory)
        do {
            try await configuration.linter?.writeConfiguration(in: configuration.rulesDirectory)
        } catch {
            logger.error("could not write the lint configuration: \(error, privacy: .public)")
        }
    }

    /// SHA-256 over every rule source's path and contents.
    private func sourcesDigest() -> String {
        var hasher = SHA256()
        for source in RuleCompiler.ruleSources(in: configuration.rulesDirectory) {
            hasher.update(data: Data(source.utf8))
            hasher.update(data: Data([0]))
            if let data = try? Data(contentsOf: configuration.rulesDirectory.appendingPathComponent(source)) {
                hasher.update(data: data)
            }
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of each top-level rule file, by file name.
    private func fileHashes() -> [String: String] {
        var hashes: [String: String] = [:]
        for source in RuleCompiler.ruleSources(in: configuration.rulesDirectory) where !source.contains("/") {
            guard let data = try? Data(contentsOf: configuration.rulesDirectory.appendingPathComponent(source)) else {
                continue
            }
            hashes[source] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }
}

/// When to restart a handler host that stopped: after 1 s, doubling to 30 s
/// while hosts keep dying, and from 1 s again once a host has stayed up for
/// `stableUptime`.
struct HostBackoff {
    static let stableUptime: Duration = .seconds(60)

    private var consecutiveFailures = 0
    private var runningSince: ContinuousClock.Instant?

    /// A host loaded its rules and is running.
    mutating func running(since now: ContinuousClock.Instant) {
        runningSince = now
    }

    /// The running host ended, retired or crashed. One that ran for a while
    /// first was not part of a crash loop.
    mutating func ended(at now: ContinuousClock.Instant) {
        if let runningSince, now - runningSince >= Self.stableUptime { consecutiveFailures = 0 }
        runningSince = nil
    }

    /// A host stopped or could not start: how long to wait before the next.
    mutating func failed() -> Duration {
        consecutiveFailures += 1
        return .seconds(min(30, 1 << min(consecutiveFailures - 1, 5)))
    }
}
