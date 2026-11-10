import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRules
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization

/// Compiles a rule file's unsaved text and runs one rule on events, with
/// nothing happening (docs/design/rule-editor.md, "Dry run"). MCP gets two
/// narrower doors (docs/design/mcp.md, "Harm model"): `check` takes text and
/// runs nothing, and `runSaved` runs and takes no text.
///
/// The invariant is that a dry run sends no notification, writes no state and
/// runs no process. It holds by construction:
///
/// - The runner has no `EffectExecutor` and is given none: what performs
///   effects is out of its reach. A handler's effects end in
///   `EffectSimulator`, which only reads the rule's stored state.
/// - The draft runs in a host of its own that is never the engine's, so it
///   shares no effect queue, breaker or rule log with the running rules, and
///   a handler that stalls stalls only this host.
/// - Its file's code may read what its rules grant through Deno's APIs, and
///   write nothing: it is permitted without `fs.write` (`RuleSetLoader.permit`).
/// - The text and everything compiled from it stay in the cache directory.
///   The rules directory, whose watcher reloads rules, is only read.
final class RuleDryRunner: Sendable {
    static let maximumTextBytes = 1 << 20
    /// Captured effect requests and log text one run may return, which also
    /// bounds the reply. Beyond it, requests are left out and logs dropped.
    static let maximumCapturedBytes = 1 << 22
    /// Time for the run's handlers; checked between events, so the last
    /// handler can add its own timeout.
    static let invocationBudget: Duration = .seconds(180)

    private let configuration: RuleEngine.Configuration
    /// The engine's, so a draft compiles and loads, is refused, and sees
    /// events, as it will when saved.
    private let loader: RuleSetLoader
    private let hub: EventHub
    private let store: RuleStore
    /// The engine's (`RuleEngine.authorizer`).
    private let authorizer: EffectAuthorizer
    private let running = Mutex(false)

    private var observation: ObservationScope { loader.observation }

    /// Takes the engine's configuration, loader and authorizer, never its
    /// executor.
    init(engine: RuleEngine, hub: EventHub, store: RuleStore) {
        configuration = engine.configuration
        loader = engine.loader
        authorizer = engine.authorizer
        self.hub = hub
        self.store = store
    }

    /// Whether a dry run holds the one slot.
    var isRunning: Bool { running.withLock { $0 } }

    /// One at a time: each costs a compile of the whole directory, so a
    /// second caller is told to wait, not queued.
    private func exclusively<Value>(_ body: () async throws -> Value) async throws -> Value {
        let free = running.withLock { running in
            defer { running = true }
            return !running
        }
        guard free else { throw Refusal("a dry run is already running; try again when it finishes") }
        defer { running.withLock { $0 = false } }
        return try await body()
    }

    /// The tools, a missing one refused in words the caller can act on.
    private func tools() throws -> RuleSetLoader.Tools {
        do {
            return try loader.tools()
        } catch {
            throw Refusal(error.description)
        }
    }

    struct Check: Encodable {
        /// The text compiled: it would run if saved under `file`.
        let compiles: Bool
        let diagnostics: [RuleDiagnostic]
    }

    /// Type-checks `text` as `file` among the directory's other files. It
    /// compiles and nothing more: none of the text runs.
    func check(file: String, text: String) async throws -> Check {
        try await exclusively {
            try Self.validate(file: file, text: text)
            let compiled = try await compile(file: file, text: text, with: try tools())
            return Check(
                compiles: compiled.entries.contains(RuleCompiler.moduleId(file)), diagnostics: compiled.diagnostics)
        }
    }

    /// Runs a rule as saved in the rules directory on its event kind's
    /// examples, for a caller who may not supply code. That caller can't
    /// read rules' stored state either, so what `state.get` read is left out.
    func runSaved(file: String, rule: String?) async throws -> DryRunReport {
        try Self.validate(file: file, text: "")
        let text: String
        do {
            text = try String(
                contentsOf: configuration.rulesDirectory.appendingPathComponent(file), encoding: .utf8)
        } catch {
            throw Refusal("the rules directory has no \(file)")
        }
        var report = try await run(DryRunRequest(file: file, text: text, rule: rule, events: .examples))
        for run in report.runs.indices {
            for effect in report.runs[run].effects.indices {
                if case .read = report.runs[run].effects[effect].outcome {
                    report.runs[run].effects[effect].outcome = .read(result: .null)
                }
            }
        }
        return report
    }

    func run(_ request: DryRunRequest) async throws -> DryRunReport {
        try await exclusively { try await perform(request) }
    }

    private func perform(_ request: DryRunRequest) async throws -> DryRunReport {
        try Self.validate(request)
        let tools = try tools()

        let clock = ContinuousClock()
        let compileStarted = clock.now
        let compiled = try await compile(file: request.file, text: request.text, with: tools)
        var report = DryRunReport(
            outcome: .rejected, diagnostics: compiled.diagnostics,
            compileMilliseconds: (clock.now - compileStarted).milliseconds)
        let entry = RuleCompiler.moduleId(request.file)
        guard compiled.entries.contains(entry) else { return report }

        let recording = Recording(
            simulator: EffectSimulator(authorizer: authorizer) { [store] rule, key in
                try store.value(rule: rule, key: key)
            })
        let host = HandlerHost(transport: tools.runtime.makeHost())
        let reader = Task {
            for await event in host.events { await recording.handle(event, from: host) }
        }
        // However the run ends, the host goes, then its last events are read.
        func finish() async {
            await host.stop(reason: "dry run finished")
            await reader.value
            report.fileLogs = await recording.takeLogs()
        }
        do {
            let loadStarted = clock.now
            try await host.start()
            let definitions = try await load(
                compiled, entry: entry, file: request.file, into: host, diagnostics: &report.diagnostics)
            report.loadMilliseconds = (clock.now - loadStarted).milliseconds
            if let definitions {
                try await run(request, definitions: definitions, host: host, recording: recording, report: &report)
            }
        } catch let failure as Refusal {
            await finish()
            throw failure
        } catch {
            // The host could not start, or stopped while loading.
            report.diagnostics.append(
                RuleDiagnostic(tool: .loader, file: request.file, message: "\(error)", fixable: false))
        }
        await finish()
        return report
    }

    private static func validate(file: String, text: String) throws {
        // What `RuleCompiler.ruleSources` would find at the top of the folder.
        guard RuleCompiler.isRuleSource(file), RuleCompiler.isEntry(RuleCompiler.moduleId(file)), !file.contains("\0")
        else { throw Refusal("\(file) is not a rule file's name: expected a name like `my-rule.ts`") }
        if let refusal = RuleID.refusal(file: file) { throw Refusal(refusal) }
        guard text.utf8.count <= maximumTextBytes else {
            throw Refusal("the text is over \(maximumTextBytes) bytes")
        }
    }

    private static func validate(_ request: DryRunRequest) throws {
        try validate(file: request.file, text: request.text)
        switch request.events {
        case .given(let events):
            guard events.count <= DryRunRequest.maximumEvents else {
                throw Refusal("at most \(DryRunRequest.maximumEvents) events can run at once")
            }
        case .examples:
            break
        case .sampled(let seconds, let maxEvents):
            guard seconds > 0, seconds <= DryRunRequest.maximumSampleSeconds else {
                let longest = Int(DryRunRequest.maximumSampleSeconds)
                throw Refusal("a sample takes more than 0 and at most \(longest) seconds")
            }
            guard (1...DryRunRequest.maximumEvents).contains(maxEvents) else {
                throw Refusal("a sample takes 1 to \(DryRunRequest.maximumEvents) events")
            }
        }
    }

    /// Compiles a copy of the rules directory with the unsaved text in place
    /// of the file, so imports both ways see what saving it would give.
    private func compile(file: String, text: String, with tools: RuleSetLoader.Tools) async throws
        -> RuleCompiler.Output
    {
        let fileManager = FileManager.default
        let work = configuration.cacheDirectory.appendingPathComponent("dry-run-\(UUID().uuidString)")
        let copy = work.appendingPathComponent("rules")
        defer { try? fileManager.removeItem(at: work) }
        try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)
        for source in RuleCompiler.ruleSources(in: configuration.rulesDirectory) where source != file {
            let target = copy.appendingPathComponent(source)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: configuration.rulesDirectory.appendingPathComponent(source)).write(to: target)
        }
        try text.write(to: copy.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return try await loader.compile(copy, in: work.appendingPathComponent("build"), with: tools)
    }

    /// Evaluates the file alone and decodes its rules, its file scope held
    /// against its grants now, since the run subscribes at once; nil when
    /// the file or any of its rules failed, with why in `diagnostics`.
    private func load(
        _ compiled: RuleCompiler.Output, entry: String, file: String, into host: HandlerHost,
        diagnostics: inout [RuleDiagnostic]
    ) async throws -> [RuleDefinition]? {
        let results = try await loader.load(
            compiled, entries: [entry], rejected: compiled.rejected, into: host, fileScope: .atLoad)
        guard let loaded = results.first else { throw Refusal("the runtime did not report \(file)") }
        diagnostics += loaded.diagnostics
        return loaded.error == nil && loaded.failures.isEmpty ? loaded.definitions : nil
    }

    private func run(
        _ request: DryRunRequest, definitions: [RuleDefinition], host: HandlerHost, recording: Recording,
        report: inout DryRunReport
    ) async throws {
        report.rules = definitions.map(\.name)
        let candidates = request.rule.map { name in definitions.filter { $0.name == name } } ?? definitions
        guard candidates.count == 1, let definition = candidates.first else {
            report.outcome = definitions.isEmpty ? .rejected : .chooseRule
            if definitions.isEmpty {
                report.diagnostics.append(
                    RuleDiagnostic(tool: .loader, file: request.file, message: "exports no rules", fixable: false))
            }
            return
        }
        report.rule = definition.id
        report.event = definition.event
        report.outcome = .ran
        await recording.begin(definition)
        // What its rules grant it to read, never anything to write.
        await loader.permit(definitions, in: host, writes: false)
        let events = try await events(for: request.events, definition: definition)
        let view = hub.catalog.kind(named: definition.event).flatMap { observation.view(of: $0, for: definition) }

        let clock = ContinuousClock()
        let started = clock.now
        for envelope in events {
            guard clock.now - started < Self.invocationBudget else {
                report.outOfTime = true
                return
            }
            let run = await invoke(definition, envelope, view: view, host: host, recording: recording)
            report.runs.append(run)
        }
    }

    private func invoke(
        _ definition: RuleDefinition, _ event: EventEnvelope, view: EventView?, host: HandlerHost,
        recording: Recording
    ) async -> DryRunInvocation {
        // As the dispatcher sees it (`ObservationScope.view`): the event the
        // rule would not see is reported, not run.
        let seen: EventEnvelope? = if let view { view(event) } else { event }
        guard let envelope = seen else {
            return DryRunInvocation(
                event: event, result: .skipped(reason: "outside what the rule may observe (its capabilities)"))
        }
        if let refusal = definition.admission(of: envelope).refusal {
            return DryRunInvocation(event: envelope, result: .skipped(reason: refusal))
        }
        await host.drainEvents()
        await recording.startInvocation()
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await host.invoke(rule: definition.id, event: envelope, timeout: definition.timeout)
        let elapsed = clock.now - started
        await host.drainEvents()
        if !(await host.isAlive) {
            // A stopped host's events end, so the drain can return before
            // they are read; what it sent before stopping (a fault naming
            // this invocation) is handled by the time its exit is.
            await recording.untilExited()
        }
        let captured = await recording.endInvocation()
        // A timeout is reported by its length, which the editor shows; the
        // other failures in the words the rule's log would give them.
        let result: DryRunInvocation.Result
        switch outcome {
        case .timedOut, .overran: result = .timedOut(seconds: definition.timeout.seconds)
        case .interrupted(let reason): result = .interrupted(reason: reason)
        case .superseded: result = .interrupted(reason: "the dry run ended")
        case .undeliverable(let reason): result = .skipped(reason: reason)
        case .completed:
            result = outcome.failure(timeout: definition.timeout).map { .failed(message: $0) } ?? .completed
        }
        return DryRunInvocation(
            event: envelope, result: result, effects: captured.effects, logs: captured.logs,
            milliseconds: elapsed.milliseconds)
    }

    // MARK: - Events

    private func events(for source: DryRunRequest.Events, definition: RuleDefinition) async throws -> [EventEnvelope] {
        guard let kind = hub.catalog.kind(named: definition.event) else {
            throw Refusal("\(definition.event) is not in the catalog")
        }
        let now = Date().timeIntervalSince1970 * 1000
        func envelopes(_ events: [DryRunEvent]) -> [EventEnvelope] {
            events.enumerated().map { index, event in
                EventEnvelope(
                    kind: kind.descriptor.name, sequence: UInt64(index + 1), time: event.time ?? now,
                    origin: event.origin ?? .system, replayed: false, payload: event.payload)
            }
        }
        switch source {
        case .given(let events):
            // A handler is typed against this schema, and no live event
            // breaks it: an event that does would test nothing.
            for (index, event) in events.enumerated() {
                let problems = SchemaValidator.violations(
                    of: event.payload, against: kind.payloadSchema, at: "events[\(index)]")
                guard problems.isEmpty else { throw Refusal(problems.joined(separator: "; ")) }
            }
            return envelopes(events)
        case .examples:
            let examples = try kind.payloadExamples()
            return envelopes(examples.prefix(DryRunRequest.maximumEvents).map { DryRunEvent(payload: $0) })
        case .sampled(let seconds, let maxEvents):
            return try await sample(definition, kind: kind, seconds: seconds, maxEvents: maxEvents)
        }
    }

    /// Subscribes as the rule would, sharing its source if it runs. A source
    /// that would prompt for a permission is refused, as `EventSampler`
    /// refuses it: trying a rule must not ask for anything.
    private func sample(
        _ definition: RuleDefinition, kind: AnyEventKind, seconds: Double, maxEvents: Int
    ) async throws -> [EventEnvelope] {
        if let need = kind.descriptor.permission,
            let refusal = need.clientRefusal(
                for: definition.event, status: authorizer.permissionStatus(need.permission))
        {
            throw Refusal(refusal)
        }
        let subscription: EventSubscription
        do {
            subscription = try hub.subscribe(definition.parameters, subscriber: .rule(file: definition.file))
        } catch {
            throw Refusal("\(error)")
        }
        defer { subscription.cancel() }
        let (collected, sourceEnded) = await subscription.collect(for: seconds, timedOut: false, sourceEnded: true) {
            collected, envelope in
            collected.events.append(envelope)
            return collected.events.count >= maxEvents ? false : nil
        }
        // A source that failed while sampling gave a partial sample, which
        // would read as a quiet one: the run fails and says why.
        if sourceEnded, hub.endReason(of: subscription) != nil {
            throw Refusal("\(definition.event): \(hub.stopReason(of: subscription))")
        }
        return collected.events
    }
}

/// What the handlers of one dry run asked for, as it arrives from the host.
private actor Recording {
    private var simulator: EffectSimulator
    private var definition: RuleDefinition?
    private var effects: [DryRunEffect] = []
    private var logs: [DryRunLog] = []
    private var fileLogs: [DryRunLog] = []
    private var inInvocation = false
    private var captured = 0
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    init(simulator: EffectSimulator) {
        self.simulator = simulator
    }

    func begin(_ definition: RuleDefinition) {
        self.definition = definition
    }

    func startInvocation() {
        inInvocation = true
        effects = []
        logs = []
    }

    func endInvocation() -> (effects: [DryRunEffect], logs: [DryRunLog]) {
        inInvocation = false
        return (effects, logs)
    }

    func takeLogs() -> [DryRunLog] {
        fileLogs
    }

    /// Returns once the host's exit, and so everything it sent before it,
    /// has been handled.
    func untilExited() async {
        if exited { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    func handle(_ event: HandlerHost.Event, from host: HandlerHost) async {
        switch event {
        case .effect(let call, _, _, let request):
            guard let definition else {
                await host.respond(call: call, outcome: .failure(message: "no rule is running"))
                return
            }
            let result = simulator.perform(request, for: definition)
            var effect = result.effect
            if !spend(effect.request.canonicalString.utf8.count) {
                effect.request = .null
                effect.truncated = true
            }
            effects.append(effect)
            await host.respond(call: call, outcome: result.outcome)
        case .log(_, let level, let message):
            record(DryRunLog(level: level, message: message.prefix(utf8Bytes: HandlerHost.maximumLogLineBytes)))
        case .fault(let file, let rule, let reason):
            // Inside the invocation that caused it: one the fault ended is
            // over only once `exited`, which follows it, is handled.
            record(DryRunLog(level: .error, message: "\(rule ?? file) \(reason)"))
        case .exited:
            exited = true
            for waiter in exitWaiters { waiter.resume() }
            exitWaiters = []
        case .drained(let done):
            done.resume()
        }
    }

    private func record(_ log: DryRunLog) {
        guard spend(log.message.utf8.count) else { return }
        if inInvocation { logs.append(log) } else { fileLogs.append(log) }
    }

    private func spend(_ bytes: Int) -> Bool {
        guard captured + bytes <= RuleDryRunner.maximumCapturedBytes else { return false }
        captured += bytes
        return true
    }
}

/// Answers a dry run's effects. Nothing here acts: it is the end of every
/// effect a draft asks for, and its only access outside itself is
/// `readState`.
///
/// A request is admitted as the executor admits it, so a missing
/// grant fails the handler as it will when the rule runs. `state.get` reads
/// the rule's stored value, under the writes this run simulated. Every other
/// effect gets a placeholder of its result type: reads of the outside world
/// (`clipboard.read`, `windows.list`, `defaults.read`) are not performed
/// either, since they can ask for a permission and reveal what a draft has
/// no grant to have yet.
struct EffectSimulator {
    let authorizer: EffectAuthorizer
    let readState: @Sendable (_ rule: String, _ key: String) throws -> JSONValue?
    /// This run's writes, a nil value for a delete.
    private var state: [String: JSONValue?] = [:]

    init(
        authorizer: EffectAuthorizer,
        readState: @escaping @Sendable (_ rule: String, _ key: String) throws -> JSONValue?
    ) {
        self.authorizer = authorizer
        self.readState = readState
    }

    mutating func perform(_ raw: JSONValue, for rule: RuleDefinition) -> (effect: DryRunEffect, outcome: EffectOutcome)
    {
        let kind = raw["kind"]?.stringValue ?? "?"
        var fields = raw.objectValue ?? [:]
        fields["kind"] = nil
        do {
            let request = try authorizer.admit(raw, for: rule)
            let (value, read) = try simulate(request, rule: rule)
            return (
                DryRunEffect(
                    kind: kind, request: .object(fields),
                    outcome: read ? .read(result: value) : .simulated(result: value)),
                .success(value: value.canonicalString)
            )
        } catch {
            let message = (error as? EffectError)?.description ?? "\(error)"
            return (
                DryRunEffect(kind: kind, request: .object(fields), outcome: .refused(message: message)),
                .failure(message: message)
            )
        }
    }

    /// The value the handler gets, and whether it came from the store.
    private mutating func simulate(_ request: EffectRequest, rule: RuleDefinition) throws -> (JSONValue, read: Bool) {
        switch request.action {
        case .stateGet(let key):
            return (EffectDescriptor.Result.found(try state[key] ?? readState(rule.id, key)), true)
        case .stateSet(let key, let value):
            state.updateValue(value, forKey: key)
            return (.null, false)
        case .stateDelete(let key):
            state.updateValue(nil, forKey: key)
            return (.null, false)
        default:
            return (request.descriptor.result.placeholder, false)
        }
    }
}

extension EffectDescriptor.Result {
    /// What a simulated effect gives its handler: what the wire would carry
    /// for an empty result.
    var placeholder: JSONValue {
        switch self {
        case .none: .null
        case .value(let schema): schema.placeholder
        case .optional: Self.found(nil)
        }
    }
}

extension TypeSchema {
    /// The least value of this type, derived so a new effect's result is
    /// covered with no entry here. Optional fields stay absent.
    var placeholder: JSONValue {
        switch self {
        case .string: .string("")
        case .text(let bounds): .string(String(repeating: " ", count: bounds.minimum))
        case .number: .number(0)
        case .bounded(let bounds): .number(bounds.minimum ?? 0)
        case .boolean: .bool(false)
        case .enumeration(let values): values.first.map(JSONValue.string) ?? .null
        case .array: .array([])
        case .record: .object([:])
        case .json: .null
        case .object(let object), .named(_, let object):
            .object(
                Dictionary(
                    uniqueKeysWithValues: object.fields.filter { !$0.optional }.map { ($0.name, $0.schema.placeholder) }
                )
            )
        }
    }
}

extension Duration {
    fileprivate var seconds: Double { self / .seconds(1) }
    fileprivate var milliseconds: Double { self / .milliseconds(1) }
}
