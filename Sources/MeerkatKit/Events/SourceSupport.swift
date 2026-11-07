import Foundation
import Synchronization
import SystemConfiguration
import notify

// Building blocks shared by event sources. Each owns exactly one OS
// registration and undoes it in `stop`.

/// Calls `tick` every `interval` seconds, starting after one interval (or
/// immediately with `fireImmediately`), on a private queue or on `queue`.
/// Sources with several timers pass one queue, so their ticks never overlap.
///
/// A source that measures something which can fail uses the throwing form,
/// which owns the policy for every polling source: a tick that throws is
/// skipped, the skips and the last error show in `detail` (daemon status),
/// and `failureLimit` failures in a row end the subscription through `fail`,
/// so a measurement that has stopped working is not mistaken for a quiet
/// machine.
final class PollingSource: EventSource {
    private let interval: Double
    private let fireImmediately: Bool
    private let tick: @Sendable () throws -> Void
    private let fail: @Sendable (String) -> Void
    private let queue: DispatchQueue
    private let timer = Mutex<TimerBox?>(nil)
    private let failures = Mutex<Failures>(Failures())

    /// Consecutive failed ticks that end the subscription.
    static let failureLimit = 5

    struct TimerBox: @unchecked Sendable {
        let value: any DispatchSourceTimer
    }

    private struct Failures {
        var skipped = 0
        var consecutive = 0
        var last: String?
    }

    /// A source whose tick cannot fail.
    convenience init(
        label: String, interval: Double, fireImmediately: Bool = true, queue: DispatchQueue? = nil,
        tick: @escaping @Sendable () -> Void
    ) {
        self.init(
            label: label, interval: interval, fireImmediately: fireImmediately, queue: queue, fail: { _ in }, tick)
    }

    /// A source whose tick can fail, ending the subscription through `emit`.
    convenience init<Payload>(
        label: String, interval: Double, fireImmediately: Bool = true, queue: DispatchQueue? = nil,
        failingThrough emit: Emitter<Payload>, measure: @escaping @Sendable () throws -> Void
    ) {
        self.init(
            label: label, interval: interval, fireImmediately: fireImmediately, queue: queue,
            fail: { emit.fail($0) }, measure)
    }

    private init(
        label: String, interval: Double, fireImmediately: Bool, queue: DispatchQueue?,
        fail: @escaping @Sendable (String) -> Void, _ measure: @escaping @Sendable () throws -> Void
    ) {
        self.interval = interval
        self.fireImmediately = fireImmediately
        tick = measure
        self.fail = fail
        self.queue = queue ?? DispatchQueue(label: "com.gkze.meerkat.\(label)", qos: .utility)
    }

    func start() throws {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let nanos = Int((interval * 1_000_000_000).rounded())
        source.schedule(
            deadline: fireImmediately ? .now() : .now() + .nanoseconds(nanos),
            repeating: .nanoseconds(nanos),
            // Let the kernel batch wakeups by up to a tenth of the interval.
            leeway: .nanoseconds(max(nanos / 10, 1_000_000))
        )
        source.setEventHandler { [weak self] in self?.run() }
        timer.withLock { $0 = TimerBox(value: source) }
        source.resume()
    }

    func stop() {
        timer.withLock { box in
            box?.value.cancel()
            box = nil
        }
    }

    var detail: String? {
        failures.withLock { failures in
            failures.last.map { "skipped \(failures.skipped) failed measurement(s); last: \($0)" }
        }
    }

    private func run() {
        do {
            try tick()
            failures.withLock { $0.consecutive = 0 }
        } catch {
            let reason = "\(error)"
            let ended = failures.withLock { failures -> Bool in
                failures.skipped += 1
                failures.consecutive += 1
                failures.last = reason
                return failures.consecutive == Self.failureLimit
            }
            // Outside the lock: the hub reads `detail` and stops this source.
            if ended { fail("its measurement failed \(Self.failureLimit) times in a row: \(reason)") }
        }
    }
}

/// Observes notifications on a `NotificationCenter` (the default center,
/// `NSWorkspace.shared.notificationCenter`, or the distributed center).
final class NotificationSource: EventSource {
    private let center: NotificationCenter
    private let names: [Notification.Name]
    private let initial: (@Sendable () -> Void)?
    private let handler: @Sendable (Notification) -> Void
    private let tokens = Mutex<[TokenBox]>([])

    struct TokenBox: @unchecked Sendable {
        let value: any NSObjectProtocol
    }

    /// - Parameter initial: run once after registering, for `state` events
    ///   that report the current value before the first change.
    init(
        center: NotificationCenter, names: [Notification.Name],
        initial: (@Sendable () -> Void)? = nil,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        self.names = names
        self.initial = initial
        self.handler = handler
    }

    func start() throws {
        let handler = self.handler
        let registered = names.map { name in
            TokenBox(
                value: center.addObserver(forName: name, object: nil, queue: nil) { notification in
                    handler(notification)
                })
        }
        tokens.withLock { $0 = registered }
        initial?()
    }

    func stop() {
        let registered = tokens.withLock { tokens -> [TokenBox] in
            defer { tokens = [] }
            return tokens
        }
        for token in registered { center.removeObserver(token.value) }
    }
}

/// Observes Darwin `notify(3)` names.
final class DarwinNotifySource: EventSource {
    private let names: [String]
    private let initial: (@Sendable () -> Void)?
    private let handler: @Sendable (_ name: String, _ token: Int32) -> Void
    private let queue = DispatchQueue(label: "com.gkze.meerkat.notify", qos: .utility)
    private let tokens = Mutex<[Int32]>([])

    init(
        names: [String], initial: (@Sendable () -> Void)? = nil,
        handler: @escaping @Sendable (_ name: String, _ token: Int32) -> Void
    ) {
        self.names = names
        self.initial = initial
        self.handler = handler
    }

    func start() throws {
        var registered: [Int32] = []
        for name in names {
            var token: Int32 = 0
            let handler = self.handler
            let status = notify_register_dispatch(name, &token, queue) { token in
                handler(name, token)
            }
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                for token in registered { notify_cancel(token) }
                throw EventError.sourceUnavailable("notify_register_dispatch(\(name)) failed with \(status)")
            }
            registered.append(token)
        }
        tokens.withLock { $0 = registered }
        initial?()
    }

    func stop() {
        let registered = tokens.withLock { tokens -> [Int32] in
            defer { tokens = [] }
            return tokens
        }
        for token in registered { notify_cancel(token) }
    }

    /// The 64-bit state attached to a notify name, if the poster sets one.
    static func state(of name: String) -> UInt64? {
        var token: Int32 = 0
        guard notify_register_check(name, &token) == UInt32(NOTIFY_STATUS_OK) else { return nil }
        defer { notify_cancel(token) }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK) else { return nil }
        return state
    }
}

/// Runs `start` and `stop` closures, for sources whose registration is a
/// single framework call pair.
final class ClosureSource: EventSource {
    private let startBody: @Sendable () throws -> Void
    private let stopBody: @Sendable () -> Void

    init(start: @escaping @Sendable () throws -> Void, stop: @escaping @Sendable () -> Void) {
        startBody = start
        stopBody = stop
    }

    func start() throws { try startBody() }
    func stop() { stopBody() }
}

/// Emits a state value only when it differs from the last one emitted, and
/// reads plus emits under one lock, so a slow initial read cannot publish a
/// value older than one a concurrent change already published.
final class StateReporter<Payload: EventPayload & Equatable>: Sendable {
    private let last = Mutex<Payload?>(nil)
    private let emit: Emitter<Payload>

    init(_ emit: Emitter<Payload>) { self.emit = emit }

    /// `read` runs under the lock; nil means "no value available", which
    /// emits nothing.
    func report(_ read: () -> Payload?) {
        last.withLock { last in
            guard let value = read(), value != last else { return }
            last = value
            emit(value)
        }
    }
}

/// Watches SCDynamicStore keys (and regex key patterns) and calls `changed`
/// with the store on a private serial queue, once after starting and then
/// after every change notification.
///
/// `stop` detaches the store on that queue, so once it returns no `changed`
/// call is running and none follows.
final class DynamicStoreKeySource: EventSource {
    private let keys: [String]
    private let patterns: [String]
    private let changed: @Sendable (SCDynamicStore) -> Void
    private let queue = DispatchQueue(label: "com.gkze.meerkat.dynamic-store", qos: .utility)
    private let store = Mutex<StoreBox?>(nil)

    /// SCDynamicStore is a CF object without a Sendable annotation. This
    /// source uses it in `start` and then only on `queue`.
    struct StoreBox: @unchecked Sendable {
        let value: SCDynamicStore
    }

    /// The callback context. The store retains and releases it through the
    /// context's callbacks, so it lives exactly as long as the store; it
    /// refers back to this source weakly.
    private final class Callback: Sendable {
        let changed: @Sendable () -> Void
        init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
    }

    init(keys: [String], patterns: [String] = [], changed: @escaping @Sendable (SCDynamicStore) -> Void) {
        self.keys = keys
        self.patterns = patterns
        self.changed = changed
    }

    func start() throws {
        let callback = Callback { [weak self] in self?.fire() }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(info).retain().toOpaque()) },
            release: { info in Unmanaged<Callback>.fromOpaque(info).release() },
            copyDescription: nil
        )
        // `callback` must outlive the create call, which retains it through
        // the context's `retain`; from then on the store owns it.
        let created = withExtendedLifetime(callback) {
            SCDynamicStoreCreate(
                nil, "com.gkze.meerkat" as CFString,
                { _, _, info in
                    guard let info else { return }
                    Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().changed()
                }, &context)
        }
        func failure(_ call: String) -> EventError {
            EventError.sourceUnavailable("\(call) failed: \(String(cString: SCErrorString(SCError())))")
        }
        guard let created else { throw failure("SCDynamicStoreCreate") }
        guard SCDynamicStoreSetNotificationKeys(created, keys as CFArray, patterns.isEmpty ? nil : patterns as CFArray)
        else { throw failure("SCDynamicStoreSetNotificationKeys") }
        store.withLock { $0 = StoreBox(value: created) }
        guard SCDynamicStoreSetDispatchQueue(created, queue) else {
            let error = failure("SCDynamicStoreSetDispatchQueue")
            store.withLock { $0 = nil }
            throw error
        }
        queue.async { self.fire() }
    }

    func stop() {
        queue.sync {
            guard let box = store.withLock({ $0.take() }) else { return }
            SCDynamicStoreSetDispatchQueue(box.value, nil)
        }
    }

    /// Runs on `queue`.
    private func fire() {
        guard let box = store.withLock({ $0 }) else { return }
        changed(box.value)
    }
}

/// A thread of a source's own running a CFRunLoop, for APIs that deliver
/// callbacks only to a run loop (AXObserver, CGEventTap) and whose calls can
/// block on another process: they must not run on the daemon's main thread.
final class RunLoopThread: Sendable {
    private let name: String
    private let runLoop = Mutex<RunLoopBox?>(nil)

    struct RunLoopBox: @unchecked Sendable {
        let value: CFRunLoop
    }

    init(name: String) {
        self.name = name
    }

    /// Starts the thread and returns once its run loop accepts work.
    func start() {
        let ready = DispatchSemaphore(value: 0)
        // The thread retains this object until its run loop ends in `stop`.
        let thread = Thread { [self] in
            let current = RunLoopBox(value: CFRunLoopGetCurrent())
            runLoop.withLock { $0 = current }
            ready.signal()
            // A run loop with no sources returns at once; this port keeps it
            // running until `stop` clears the box and calls CFRunLoopStop.
            RunLoop.current.add(Port(), forMode: .default)
            while runLoop.withLock({ $0 != nil }) {
                CFRunLoopRun()
            }
        }
        thread.name = "com.gkze.meerkat.\(name)"
        thread.qualityOfService = .utility
        thread.start()
        ready.wait()
    }

    /// Runs `body` on the thread, after work already submitted. Does nothing
    /// once stopped.
    func perform(_ body: @escaping @Sendable (CFRunLoop) -> Void) {
        guard let box = runLoop.withLock({ $0 }) else { return }
        CFRunLoopPerformBlock(box.value, CFRunLoopMode.defaultMode.rawValue) { body(box.value) }
        CFRunLoopWakeUp(box.value)
    }

    /// Runs `cleanup` on the thread, then ends it; returns after both.
    func stop(_ cleanup: @escaping @Sendable (CFRunLoop) -> Void = { _ in }) {
        guard let box = runLoop.withLock({ $0 }) else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(box.value, CFRunLoopMode.defaultMode.rawValue) { [self] in
            cleanup(box.value)
            runLoop.withLock { $0 = nil }
            CFRunLoopStop(box.value)
            done.signal()
        }
        CFRunLoopWakeUp(box.value)
        done.wait()
    }
}

// MARK: - Parameter helpers

/// Validates a polling interval against the range an event supports.
func requireInterval(_ value: Double, name: String = "interval", in range: ClosedRange<Double>) throws {
    guard value.isFinite, range.contains(value) else {
        throw EventError.invalidParameters(
            "\"\(name)\" must be between \(range.lowerBound) and \(range.upperBound) seconds, got \(value)")
    }
}

/// Validates a count against the range a parameter supports.
func requireCount(_ value: Int, name: String, in range: ClosedRange<Int>) throws {
    guard range.contains(value) else {
        throw EventError.invalidParameters("\"\(name)\" must be \(range.lowerBound)–\(range.upperBound)")
    }
}

extension String {
    /// A NUL-terminated buffer filled by a C call, as UTF-8.
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A C string in a fixed-size array field, which Swift imports as a tuple.
    init<Field>(nulTerminatedBytesOf field: Field) {
        self = withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Unix epoch milliseconds now, the time unit every payload uses.
func nowMilliseconds() -> Double {
    Date().timeIntervalSince1970 * 1000
}
