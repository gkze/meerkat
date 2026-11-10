import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRules
import MeerkatRuntimeBindings

/// Where a handler host runs: one instance of the rule runtime, spoken to in
/// `DaemonToHost` and `HostToDaemon` messages (Sources/meerkat-runtime/src/protocol.rs,
/// generated into `MeerkatRuntimeBindings`).
///
/// meerkatd's is the embedded Deno runtime (`DenoRuntime`); tests substitute
/// runtimes that fail in ways the real one cannot be made to.
public protocol HandlerHostTransport: AnyObject, Sendable {
    /// Starts the runtime. `receive` gets each message in order; `terminated`
    /// follows the last one, once, with why the runtime stopped.
    func start(
        receive: @escaping @Sendable (HostToDaemon) -> Void, terminated: @escaping @Sendable (String) -> Void
    ) throws
    func send(_ message: DaemonToHost)
    /// Interrupts every worker; `terminated` follows. Safe to call again.
    func stop(reason: String)
}

/// The rule runtime: what rule code is compiled against and what runs it.
public struct HandlerRuntime: Sendable {
    /// TypeScript declarations of the globals the runtime gives rule code.
    public let declarations: String
    /// Makes a fresh runtime for each host the engine starts.
    public let makeHost: @Sendable () -> any HandlerHostTransport

    public init(declarations: String, makeHost: @escaping @Sendable () -> any HandlerHostTransport) {
        self.declarations = declarations
        self.makeHost = makeHost
    }
}

/// One running handler host and the requests in flight to it.
///
/// A host loads one rule set, once: a reload starts a new host instead of
/// replacing JavaScript state in place. The host can end at any moment (its
/// watchdog found JavaScript stuck, a file's worker failed, a reload retired
/// it); every pending request then completes, so no caller waits forever.
/// Restarting is the engine's policy.
///
/// Deadlines are enforced inside the runtime, which knows who holds each
/// worker's JavaScript thread; this side keeps backstops for a runtime that
/// stops answering altogether.
///
/// Everything the host sends on its own initiative arrives on `events` in
/// order, from this host only, so the engine can ignore a host it already
/// replaced.
actor HandlerHost {
    enum InvocationResult: Sendable, Equatable {
        case completed(HandlerError?)
        /// The handler's promise did not settle in time. Nothing else a
        /// handler does is charged to its invocation.
        case timedOut
        /// The handler's own code held the thread past the deadline, which
        /// ended the host. The engine charges it where it counts the fault
        /// (`Event.fault`, which names the rule), in one step, so the failure
        /// and the fault are never seen apart.
        case overran
        /// The host ended for a reason that is not this rule's fault (another
        /// file's code ended it, or it failed). Not counted against the rule.
        case interrupted(String)
        /// A reload retired this host while the invocation ran.
        case superseded
        /// The event could not be sent to the handler, which never ran; why,
        /// in the encoder's words. Not counted against the rule.
        case undeliverable(String)
    }

    enum HostError: Error, CustomStringConvertible {
        case exited(String)

        var description: String {
            switch self {
            case .exited(let reason): return "handler host stopped: \(reason)"
            }
        }
    }

    /// One entry's `loaded` result, its definitions decoded.
    struct LoadedEntry: Sendable {
        let entry: String
        /// The entry's file (`RuleCompiler.entryFile`), which the host is
        /// told to name it by in every message, and each of its rules' ids
        /// begin with.
        let file: String
        /// Each rule's definition with `handle` removed, as the author wrote it.
        let rules: [JSONValue]
        let error: HandlerError?
    }

    enum Event: Sendable {
        /// A handler asked for an effect during `invocation`; answer with
        /// `respond(call:outcome:)`.
        case effect(call: UInt64, invocation: UInt64, rule: String, request: JSONValue)
        case log(rule: String?, level: LogLevel, message: String)
        /// A rule file's code ended the host, which is stopping. `rule` when
        /// it was that rule's handler running its own code; otherwise the
        /// runtime knows only the file (a timer, or a handler's continuation
        /// after an `await`). `reason` follows the name; `exited`, which
        /// comes next, has the sentence whole.
        case fault(file: String, rule: String?, reason: String)
        case exited(reason: String)
        /// Everything sent before this has been handled (`drainEvents`).
        case drained(CheckedContinuation<Void, Never>)
    }

    private enum Delivery: Sendable {
        case message(HostToDaemon, bytes: Int)
        case terminated(String)
    }

    nonisolated let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    private let transport: any HandlerHostTransport
    private var started = false
    private var ready: CheckedContinuation<Void, any Error>?
    private var loading: CheckedContinuation<[LoadedEntry], any Error>?
    /// Each entry the load asked for, with its file.
    private var loadEntries: [String: String] = [:]
    private var loadBackstop: Task<Void, Never>?
    private var invocations: [UInt64: Invocation] = [:]
    private var nextInvocation: UInt64 = 1
    private var loadedFiles = 0
    private var exitReason: String?
    private var outcomeForPending: InvocationResult?
    /// Set once the host reported a fault: it is stopping, so nothing it
    /// asks for any more is acted on.
    private var dying = false
    private var logBudgets = LogBudgets()

    private struct Invocation {
        let rule: String
        let continuation: CheckedContinuation<InvocationResult, Never>
        /// Nil once the handler started.
        var unstartedTimeout: Duration?
        var effects = 0
        var backstop: Task<Void, Never>?
    }

    /// Effects one invocation may request; a handler looping over effects
    /// without awaiting them would otherwise flood the daemon.
    static let effectsPerInvocation = 256
    /// Bytes of host messages received but not yet handled before the
    /// runtime's delivery blocks, which in turn blocks the workers sending:
    /// backpressure instead of a buffer that grows with whatever rules log.
    /// A message counts the text it carries (`HostToDaemon.textBytes`).
    static let readAheadBytes = 8 << 20
    /// Most text one message from the host may carry: the runtime's own
    /// limit, which its ops keep rule code within.
    static let maximumMessageBytes = Int(maximumMessageTextBytes())
    /// Longest log line, error message or stack the runtime sends, in bytes:
    /// the limit for every line of a rule's log.
    static let maximumLogLineBytes = Int(MeerkatRuntimeBindings.maximumTextBytes())
    /// Time allowed between starting the host and its `ready`.
    static let startupDeadline: Duration = .seconds(10)
    /// Beyond a deadline the host itself enforces, how long to wait before
    /// deciding the host stopped answering.
    static let backstopGrace: Duration = .seconds(30)
    /// An invocation not yet started waits behind other work of its file,
    /// which may run up to the longest timeout a rule can have.
    static let unstartedBackstop: Duration = .seconds(RuleLimits.timeoutRange.upperBound) + backstopGrace

    init(transport: any HandlerHostTransport) {
        self.transport = transport
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
    }

    var isAlive: Bool { exitReason == nil && !dying }

    /// Rule files loaded into this host.
    var workers: Int { exitReason == nil ? loadedFiles : 0 }

    /// Whether `invocation` is still running in this host, for effects that
    /// waited in a queue.
    func isRunning(_ invocation: UInt64) -> Bool {
        exitReason == nil && !dying && invocations[invocation] != nil
    }

    // MARK: - Lifecycle

    /// Starts the runtime and waits for its `ready`.
    func start() async throws {
        precondition(!started, "a handler host starts once")
        started = true
        let (deliveries, sink) = AsyncStream.makeStream(of: Delivery.self)
        let credit = ByteCredit(capacity: Self.readAheadBytes)
        do {
            // The runtime calls these from its delivery thread, one at a
            // time: waiting for credit there is the backpressure.
            try transport.start(
                receive: { message in
                    let bytes = message.textBytes
                    credit.acquire(bytes)
                    sink.yield(.message(message, bytes: bytes))
                },
                terminated: { reason in
                    sink.yield(.terminated(reason))
                    sink.finish()
                })
        } catch {
            sink.finish()
            terminated("could not start: \(error)")
            throw HostError.exited(exitReason ?? "could not start")
        }
        // One consumer keeps messages in the order the runtime sent them,
        // with its termination after all of them.
        Task { [weak self] in
            for await delivery in deliveries {
                switch delivery {
                case .message(let message, let bytes):
                    await self?.receive(message)
                    credit.release(bytes)
                case .terminated(let reason):
                    await self?.terminated(reason)
                }
            }
        }
        let startup = Task { [weak self] in
            try? await Task.sleep(for: Self.startupDeadline)
            await self?.startupOverran()
        }
        defer { startup.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if let exitReason {
                continuation.resume(throwing: HostError.exited(exitReason))
            } else {
                ready = continuation
            }
        }
    }

    /// Stops the host. Pending invocations complete with `.superseded` when
    /// a reload retired the host, `.interrupted` otherwise. The runtime ends
    /// with the first reason it was given, or the fault that came first.
    func stop(reason: String, superseded: Bool = false) {
        if outcomeForPending == nil { outcomeForPending = superseded ? .superseded : .interrupted(reason) }
        transport.stop(reason: reason)
    }

    // MARK: - Requests

    /// Loads the rule set. The runtime enforces `entryDeadline` on each
    /// file's top-level code and reports a file that overran (or failed) in
    /// its result, without stopping the others. At most one result per
    /// entry asked for, and none for anything else. `entries` are module
    /// ids; the host names each by its file, which only the daemon derives.
    func load(
        modules: [RuleCompiler.Module], entries: [String], rejected: [String: String],
        entryDeadline: Duration
    ) async throws -> [LoadedEntry] {
        let named = entries.map { HostEntry(module: $0, file: RuleCompiler.entryFile($0)) }
        loadEntries = Dictionary(named.map { ($0.module, $0.file) }) { first, _ in first }
        send(
            .load(
                modules: modules.map { HostModule(id: $0.id, code: $0.code) }, entries: named, rejected: rejected,
                entryDeadlineSeconds: Self.seconds(entryDeadline),
                effects: EffectCatalog.standard.runtimeTable.canonicalString))
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[LoadedEntry], any Error>) in
            if let exitReason {
                continuation.resume(throwing: HostError.exited(exitReason))
            } else {
                loading = continuation
                let backstop = entryDeadline + Self.backstopGrace
                loadBackstop = Task { [weak self] in
                    try? await Task.sleep(for: backstop)
                    guard !Task.isCancelled else { return }
                    await self?.loadOverran(after: backstop)
                }
            }
        }
    }

    /// What `entry`'s code may do through Deno's APIs, before any of its
    /// handlers run.
    func permit(entry: String, permissions: FilePermissions) {
        send(.permit(entry: entry, permissions: permissions))
    }

    /// Runs one handler; the host enforces `timeout` from the moment the
    /// handler starts.
    func invoke(rule: String, event: EventEnvelope, timeout: Duration) async -> InvocationResult {
        if let exitReason { return .interrupted(exitReason) }
        if dying { return .interrupted("the handler host is restarting") }
        let invocation = nextInvocation
        nextInvocation += 1
        let text: String
        do {
            text = try String(decoding: JSONEncoder().encode(event), as: UTF8.self)
        } catch EncodingError.invalidValue(_, let context) {
            // A non-finite number in the payload, say: neither the host's
            // problem nor the rule's.
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return .undeliverable("the event has no JSON form at \(path): \(context.debugDescription)")
        } catch {
            return .undeliverable("the event has no JSON form: \(error)")
        }
        guard send(.invoke(invocation: invocation, rule: rule, event: text, timeoutSeconds: Self.seconds(timeout)))
        else { return .interrupted(exitReason ?? "the handler host stopped") }
        return await withCheckedContinuation { (continuation: CheckedContinuation<InvocationResult, Never>) in
            invocations[invocation] = Invocation(
                rule: rule, continuation: continuation, unstartedTimeout: timeout,
                backstop: backstop(invocation, after: Self.unstartedBackstop))
        }
    }

    func respond(call: UInt64, outcome: EffectOutcome) {
        send(.effectResult(call: call, result: outcome))
    }

    /// Returns once whoever reads `events` has handled everything sent so
    /// far: an invocation's result can overtake its effects and logs there.
    func drainEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if case .terminated = eventSink.yield(.drained(continuation)) { continuation.resume() }
        }
    }

    // MARK: - Internals

    @discardableResult
    private func send(_ message: DaemonToHost) -> Bool {
        guard exitReason == nil else { return false }
        transport.send(message)
        return true
    }

    private func backstop(_ invocation: UInt64, after delay: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unresponsive(invocation)
        }
    }

    private func loadOverran(after delay: Duration) {
        guard loading != nil else { return }
        stop(reason: "did not finish loading within \(delay.formatted())")
    }

    private func startupOverran() {
        guard ready != nil else { return }
        stop(reason: "did not start within \(Self.startupDeadline.formatted())")
    }

    /// No answer within a deadline plus grace: the host is not working,
    /// whoever is to blame.
    private func unresponsive(_ invocation: UInt64) {
        guard invocations[invocation] != nil else { return }
        stop(reason: "stopped answering")
    }

    /// Handles one message. The host runs user code, so the JSON it relays
    /// is decoded here, once; a message too long or not decodable means the
    /// host is not behaving, and it is stopped.
    private func receive(_ message: HostToDaemon) {
        guard message.limitedBytes <= Self.maximumMessageBytes else {
            stop(reason: "sent a message too long")
            return
        }
        switch message {
        case .ready:
            ready?.resume()
            ready = nil
        case .loaded(let entries):
            // The host runs user code: one result per entry this load asked
            // for, and nothing else, is what callers get.
            var unreported = loadEntries
            let results: [LoadedEntry]
            do {
                results = try entries.compactMap { result in
                    try unreported.removeValue(forKey: result.entry).map { try LoadedEntry(result, file: $0) }
                }
            } catch {
                stop(reason: "sent an undecodable message: \(error)")
                return
            }
            loadBackstop?.cancel()
            loadBackstop = nil
            loadedFiles = results.filter { $0.error == nil }.count
            loading?.resume(returning: results)
            loading = nil
        case .started(let invocation):
            // The deadline now runs in the host; this side waits that long
            // plus grace before calling the host unresponsive.
            if let timeout = invocations[invocation]?.unstartedTimeout {
                invocations[invocation]?.unstartedTimeout = nil
                invocations[invocation]?.backstop?.cancel()
                invocations[invocation]?.backstop = backstop(invocation, after: timeout + Self.backstopGrace)
            }
        case .invocationDone(let invocation, let error):
            finish(invocation, .completed(error))
        case .invocationTimedOut(let invocation):
            finish(invocation, .timedOut)
        case .fault(let file, let rule, let invocation, let kind, let reason):
            dying = true
            if kind == .overran, let invocation {
                // A handler's own code held the thread past its timeout: its
                // invocation fails with it. (Gone already only if a reload
                // superseded it meanwhile.)
                finish(invocation, .overran)
            }
            eventSink.yield(.fault(file: file, rule: rule, reason: reason))
        case .effect(let call, let invocation, let rule, let text):
            let request: JSONValue
            do {
                request = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            } catch {
                stop(reason: "sent an undecodable effect request: \(error)")
                return
            }
            // Only the handler that is running, for its own rule, may ask for
            // effects: a context kept past its handler (stored by the rule,
            // or used from a timer) is refused rather than acting outside the
            // invocation's deadline and the breaker's view.
            guard !dying, var pending = invocations[invocation], pending.rule == rule else {
                respond(
                    call: call, outcome: .failure(message: "effects are only available while the rule's handler runs"))
                return
            }
            pending.effects += 1
            invocations[invocation] = pending
            guard pending.effects <= Self.effectsPerInvocation else {
                respond(
                    call: call,
                    outcome: .failure(message: "more than \(Self.effectsPerInvocation) effects in one invocation"))
                return
            }
            eventSink.yield(.effect(call: call, invocation: invocation, rule: rule, request: request))
        case .log(let rule, let level, let message):
            let (file, decision) = logBudgets.admit(rule: rule, now: ContinuousClock.now)
            switch decision {
            case .accept(let dropped):
                if dropped > 0 {
                    eventSink.yield(
                        .log(rule: file, level: .warn, message: "dropped \(dropped) log lines over the rate limit"))
                }
                eventSink.yield(.log(rule: rule, level: LogLevel(level), message: message))
            case .drop:
                break
            }
        }
    }

    private func finish(_ invocation: UInt64, _ result: InvocationResult) {
        guard let pending = invocations.removeValue(forKey: invocation) else { return }
        pending.backstop?.cancel()
        pending.continuation.resume(returning: result)
    }

    // MARK: - Termination

    /// The runtime stopped, after delivering everything it sent.
    private func terminated(_ reason: String) {
        guard exitReason == nil else { return }
        exitReason = reason
        ready?.resume(throwing: HostError.exited(reason))
        ready = nil
        loadBackstop?.cancel()
        loading?.resume(throwing: HostError.exited(reason))
        loading = nil
        let outcome = outcomeForPending ?? .interrupted(reason)
        for invocation in Array(invocations.keys) { finish(invocation, outcome) }
        eventSink.yield(.exited(reason: reason))
        eventSink.finish()
    }

    private static func seconds(_ duration: Duration) -> Double { duration / .seconds(1) }
}

extension HandlerHost.LoadedEntry {
    init(_ result: EntryResult, file: String) throws {
        entry = result.entry
        self.file = file
        rules = try result.rules.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        error = result.error
    }
}

extension HandlerError {
    /// The message with its stack, as the engine reports a failed load. V8's
    /// stack already starts with the message (`Error: text`), so that one is
    /// the stack alone; a stack the rule replaced keeps the message above it.
    var report: String {
        guard let stack else { return message }
        return stack.hasPrefix(message) ? stack : "\(message)\n\(stack)"
    }
}

extension LogLevel {
    init(_ level: HostLogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .warn: self = .warn
        case .error: self = .error
        }
    }
}

extension HostToDaemon {
    /// UTF-8 bytes of the text the message carries: what the read-ahead
    /// budget counts.
    var textBytes: Int {
        switch self {
        case .loaded(let results): results.reduce(0) { $0 + $1.textBytes }
        default: limitedBytes
        }
    }

    /// What the message size limit counts: as `textBytes`, but each file's
    /// result on its own, as the runtime bounds it (protocol.rs,
    /// `MAXIMUM_MESSAGE_TEXT`).
    var limitedBytes: Int {
        switch self {
        case .ready, .started, .invocationTimedOut: 0
        case .loaded(let results): results.map(\.textBytes).max() ?? 0
        case .invocationDone(_, let error): error?.textBytes ?? 0
        case .fault(let file, let rule, _, _, let reason):
            file.utf8.count + (rule?.utf8.count ?? 0) + reason.utf8.count
        case .effect(_, _, let rule, let request): rule.utf8.count + request.utf8.count
        case .log(let rule, _, let message): (rule?.utf8.count ?? 0) + message.utf8.count
        }
    }
}

extension EntryResult {
    fileprivate var textBytes: Int {
        entry.utf8.count + rules.reduce(0) { $0 + $1.utf8.count } + (error?.textBytes ?? 0)
    }
}

extension HandlerError {
    fileprivate var textBytes: Int { message.utf8.count + (stack?.utf8.count ?? 0) }
}

/// A byte budget shared by the runtime's delivery thread (which waits) and
/// the consumer task (which releases).
final class ByteCredit: @unchecked Sendable {
    // NSCondition is thread-safe; `available` is only touched under it.
    private let condition = NSCondition()
    private var available: Int
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        available = capacity
    }

    /// Waits until `bytes` fit; a message larger than the whole budget waits
    /// until nothing else is outstanding.
    func acquire(_ bytes: Int) {
        let needed = min(bytes, capacity)
        condition.lock()
        while available < needed { condition.wait() }
        available -= needed
        condition.unlock()
    }

    func release(_ bytes: Int) {
        condition.lock()
        available = min(available + min(bytes, capacity), capacity)
        condition.broadcast()
        condition.unlock()
    }
}

/// A `LogBudget` for each rule file, so one file logging in a loop cannot
/// drop another's lines (its errors among them): the file is the unit of
/// isolation. Lines under no rule, the host's own, have one of their own.
struct LogBudgets: Sendable {
    private var budgets: [String?: LogBudget] = [:]

    /// Whether a line kept under `rule` (a rule's id or its file, as the
    /// host attributes it) passes, and the file whose budget it was, which a
    /// report of drops is kept under.
    mutating func admit(rule: String?, now: ContinuousClock.Instant) -> (file: String?, LogBudget.Decision) {
        let file = rule.map { RuleID.file(of: $0) }
        return (file, budgets[file, default: LogBudget()].admit(now: now))
    }
}

/// Token bucket for log lines from one file: a burst of 1000, refilled at
/// 200 lines a second.
struct LogBudget: Sendable {
    static let capacity = 1000.0
    static let perSecond = 200.0

    private var tokens = LogBudget.capacity
    private var last: ContinuousClock.Instant?
    private var dropped = 0

    enum Decision: Equatable {
        /// Accept, reporting how many lines were dropped since the last
        /// accepted one.
        case accept(dropped: Int)
        case drop
    }

    mutating func admit(now: ContinuousClock.Instant) -> Decision {
        if let last {
            let elapsed = now - last
            tokens = min(Self.capacity, tokens + elapsed / .seconds(1) * Self.perSecond)
        }
        last = now
        guard tokens >= 1 else {
            dropped += 1
            return .drop
        }
        tokens -= 1
        defer { dropped = 0 }
        return .accept(dropped: dropped)
    }
}
