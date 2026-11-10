import Foundation
import Synchronization

/// One delivered event.
public struct EventEnvelope: Sendable, Codable, Equatable {
    public let kind: String
    /// Increases by one per event from the same source instance.
    public let sequence: UInt64
    /// Unix epoch milliseconds when the hub received the event.
    public let time: Double
    public let origin: EventOrigin
    /// True when the event is the current value of a `state` event rather
    /// than a change observed after the subscriber subscribed: either replayed
    /// from a source that was already running, or the value a push `state`
    /// source reads as it starts (`Emitter.current`, its documented "current
    /// value first"). A source with no value to read then marks nothing, so
    /// its first change is a change. Polled and derived `state` kinds have no
    /// such value: their first event is a measurement.
    public let replayed: Bool
    public let payload: JSONValue

    public init(
        kind: String, sequence: UInt64, time: Double, origin: EventOrigin,
        replayed: Bool, payload: JSONValue
    ) {
        self.kind = kind
        self.sequence = sequence
        self.time = time
        self.origin = origin
        self.replayed = replayed
        self.payload = payload
    }

    func asReplay() -> EventEnvelope {
        EventEnvelope(
            kind: kind, sequence: sequence, time: time, origin: origin,
            replayed: true, payload: payload)
    }
}

/// A live subscription. Iterate `events`; call `cancel()` to release it.
/// (Dropping the stream is not enough: the hub keeps the subscriber's read
/// position until it is cancelled.)
public struct EventSubscription: Sendable {
    public let id: UInt64
    public let kind: String
    /// The parameters after defaults were applied.
    public let parameters: JSONValue
    public let events: EventStream
    let onCancel: @Sendable () -> Void

    public func cancel() { onCancel() }
}

/// What a bounded `collect` has kept so far.
public struct CollectedEvents: Sendable {
    public var events: [EventEnvelope] = []
    /// For a collector that bounds what it keeps by size.
    public var bytes = 0
}

extension EventSubscription {
    /// Reads events for at most `seconds`, for a client that takes a bounded
    /// sample. `add` keeps what it wants and returns a reason to stop, or nil
    /// to go on. Cancelling the reading task ends the stream, so whichever
    /// bound comes first, everything collected is returned.
    public func collect<Reason: Sendable>(
        for seconds: Double, timedOut: Reason, sourceEnded: Reason,
        add: @escaping @Sendable (inout CollectedEvents, EventEnvelope) -> Reason?
    ) async -> (collected: CollectedEvents, reason: Reason) {
        await withTaskGroup(of: (collected: CollectedEvents, reason: Reason).self) { group in
            group.addTask {
                var collected = CollectedEvents()
                for await envelope in events {
                    if let reason = add(&collected, envelope) { return (collected, reason) }
                }
                return (collected, sourceEnded)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return (CollectedEvents(), timedOut)
            }
            var first = await group.next() ?? (CollectedEvents(), timedOut)
            group.cancelAll()
            for await rest in group { first.collected.events += rest.collected.events }
            return first
        }
    }
}

/// One subscriber's view of its source instance's event ring.
///
/// The read position lives in the hub, not in the iterator, so every
/// iterator made from the same stream continues where the previous one
/// stopped. Iterate from one task at a time. Cancelling the iterating task
/// cancels the subscription, as with `AsyncStream`.
public struct EventStream: AsyncSequence, AsyncIteratorProtocol, Sendable {
    public typealias Element = EventEnvelope
    public typealias Failure = Never

    let hub: EventHub
    let subscriber: UInt64

    public mutating func next() async -> EventEnvelope? {
        await hub.next(for: subscriber)
    }

    public func makeAsyncIterator() -> Self { self }
}

/// The newest `capacity` events of one source instance, addressed by
/// sequence number. Sequences are contiguous from 1, so an event's slot is
/// `(sequence - 1) % capacity` and no head index is needed.
///
/// Only events some subscriber has yet to read, and the newest one (a
/// `state` kind's replay), keep their envelope: `release` empties the rest.
/// Holding every slot until it was overwritten kept `capacity` payloads per
/// instance alive for nothing: with the app open (14 instances), the
/// footprint rose from 29 MB to a 45 MB plateau as the rings filled
/// (2026-10-29).
struct EventRing {
    let capacity: Int
    private var slots: [EventEnvelope?] = []
    /// Sequence of the newest event; 0 before the first.
    private(set) var newest: UInt64 = 0
    /// Every event up to this sequence has been released or evicted.
    private var released: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity > 0, "an event ring needs room for at least one event")
        self.capacity = capacity
    }

    /// Sequence of the oldest event still held; `newest + 1` when empty.
    var oldest: UInt64 {
        newest < UInt64(capacity) ? 1 : newest - UInt64(capacity) + 1
    }

    var latest: EventEnvelope? { self[newest] }

    subscript(sequence: UInt64) -> EventEnvelope? {
        guard sequence >= oldest, sequence <= newest else { return nil }
        return slots[slot(sequence)]
    }

    /// Appends the next event and returns the sequence it evicted, if any.
    mutating func append(_ envelope: EventEnvelope) -> UInt64? {
        precondition(envelope.sequence == newest + 1, "events enter a ring in sequence order")
        newest = envelope.sequence
        guard slots.count == capacity else {
            slots.append(envelope)
            return nil
        }
        let index = slot(newest)
        defer { slots[index] = envelope }
        // A released slot was read by every subscriber: nothing is lost.
        return slots[index]?.sequence
    }

    /// Empties the slots of events up to `sequence`, which every subscriber
    /// has read, except the newest event.
    mutating func release(through sequence: UInt64) {
        guard newest > 1 else { return }
        let end = min(sequence, newest - 1)
        let start = max(released + 1, oldest)
        guard start <= end else { return }
        for sequence in start...end { slots[slot(sequence)] = nil }
        released = end
    }

    /// Events whose envelope is still held.
    var held: Int { slots.count { $0 != nil } }

    /// Identifies the slots' storage, which a duplicated ring does not share.
    var storage: UnsafeRawPointer? { slots.withUnsafeBytes(\.baseAddress) }

    private func slot(_ sequence: UInt64) -> Int {
        Int((sequence - 1) % UInt64(capacity))
    }
}

/// Counters for one active source instance.
public struct SourceStatistics: Sendable, Codable, Equatable {
    /// Distinguishes source instances that had the same kind and parameters
    /// at different times.
    public let instance: UInt64
    public let kind: String
    public let parameters: JSONValue
    public let subscribers: Int
    public let delivered: UInt64
    /// Events dropped because a subscriber's buffer was full, over the
    /// instance's whole life, departed subscribers included.
    public let dropped: UInt64
    /// The source's own note on how it runs, e.g. the predicate `log`
    /// applies for `log.entry`. Absent when the source has none.
    public let detail: String?
    /// Payloads the source made that JSON cannot carry (a NaN or infinite
    /// number), left out rather than delivered.
    public let unencodable: UInt64
    /// Why the latest of them could not be encoded.
    public let lastUnencodable: String?
}

/// Routes events from sources to subscribers.
///
/// A source instance exists while at least one subscriber wants its
/// (kind, parameters) pair: the first subscriber starts it, the last one to
/// leave stops it. This is what makes an idle daemon cost nothing. A source
/// that fails after starting (`Emitter.fail`) ends every subscriber's stream,
/// and `endReason(of:)` says why.
///
/// Each instance keeps the events its subscribers have not read yet, and its
/// newest event, in one ring shared by all of its subscribers; a subscriber
/// is only a read position into it. A subscriber
/// that falls more than the ring's capacity behind loses the events evicted
/// before it read them: they are counted as dropped when they are evicted,
/// and its next read starts at the oldest event still held.
public final class EventHub: Sendable {
    public let catalog: EventCatalog
    public let environment: SourceEnvironment
    /// Events each source instance holds for subscribers that have not read
    /// them yet.
    public let retainedEvents: Int

    private struct Subscriber {
        /// Who subscribed, so drops can be reported to the file whose rules
        /// fell behind and to no other (`meerkat.dropped`).
        let owner: EventSubscriber
        /// Sequence of the next event this subscriber reads.
        var cursor: UInt64
        /// A value to deliver again, as a replay, once everything up to
        /// `after` has been read.
        var replay: Replay?
        /// The task suspended in `next` until an event arrives.
        var waiter: CheckedContinuation<EventEnvelope?, Never>?
    }

    private struct Replay {
        let after: UInt64
        let envelope: EventEnvelope
    }

    /// Change one in place (`state.instances[key]?.…`): a copy shares the
    /// ring's slots with the dictionary, so changing the copy duplicates all
    /// `capacity` of them.
    private struct Instance {
        /// Distinguishes this instance from a later one with the same key,
        /// so a callback still queued by a stopped source cannot deliver
        /// into its successor.
        let token: UInt64
        let kind: AnyEventKind
        let parameters: JSONValue
        var source: (any EventSource)?
        var ring: EventRing
        var subscribers: [UInt64: Subscriber] = [:]
        var delivered: UInt64 = 0
        var dropped: UInt64 = 0
        var unencodable: (count: UInt64, reason: String)?
        /// `dropped`, by who missed the events.
        var droppedBy: [EventSubscriber: UInt64] = [:]

        var isState: Bool { kind.descriptor.semantics == .state }

        /// The next event for `id`, advancing its cursor, or nil when it has
        /// read everything (or is not a subscriber).
        mutating func read(_ id: UInt64) -> EventEnvelope? {
            guard var subscriber = subscribers[id] else { return nil }
            defer {
                subscribers[id] = subscriber
                releaseRead()
            }
            // Events evicted before this subscriber read them were counted
            // as dropped at eviction.
            subscriber.cursor = max(subscriber.cursor, ring.oldest)
            if let replay = subscriber.replay, subscriber.cursor > replay.after {
                subscriber.replay = nil
                return replay.envelope.asReplay()
            }
            guard let envelope = ring[subscriber.cursor] else { return nil }
            subscriber.cursor += 1
            delivered += 1
            return envelope
        }

        /// Lets the ring empty what the slowest subscriber has read.
        mutating func releaseRead() {
            guard let slowest = subscribers.values.map(\.cursor).min() else { return }
            ring.release(through: slowest - 1)
        }

        /// Counts `sequence`, just evicted from the ring, as dropped for each
        /// subscriber that had not read it. A replay still waiting in front
        /// of it is superseded by the events after it, so it is dropped and
        /// counted too, as it was when each subscriber had its own buffer.
        mutating func evicted(_ sequence: UInt64) {
            for id in Array(subscribers.keys) {
                guard var subscriber = subscribers[id], subscriber.cursor <= sequence else { continue }
                var lost: UInt64 = 1
                if let replay = subscriber.replay, replay.after < sequence {
                    subscriber.replay = nil
                    lost += 1
                }
                dropped += lost
                droppedBy[subscriber.owner, default: 0] += lost
                subscribers[id] = subscriber
            }
        }

        /// Hands `id` its next event if it is waiting for one.
        mutating func wake(_ id: UInt64) -> (CheckedContinuation<EventEnvelope?, Never>, EventEnvelope)? {
            guard let waiter = subscribers[id]?.waiter, let envelope = read(id) else { return nil }
            subscribers[id]?.waiter = nil
            return (waiter, envelope)
        }

        /// Puts the next event in the ring; returns the waiters it wakes.
        ///
        /// A reported value equal to the latest is no change, whether the
        /// source read it twice as it started or the OS notified without
        /// one, and is left out. Only a push `state` kind's current value is
        /// `replayed`, and only as the source's first event: a polled kind's
        /// first event is a measurement, and a read that a change beat to
        /// the ring reports what came after that change.
        mutating func append(
            payload: JSONValue, origin: EventOrigin, value: Emission.ReportedValue?, time: Double
        ) -> [(CheckedContinuation<EventEnvelope?, Never>, EventEnvelope)] {
            if value != nil, let latest = ring.latest, latest.payload == payload, latest.origin == origin { return [] }
            let current = value == .current && ring.newest == 0 && isState && kind.descriptor.mechanism == .push
            let envelope = EventEnvelope(
                kind: kind.name, sequence: ring.newest + 1, time: time,
                origin: origin, replayed: current, payload: payload)
            if let evicted = ring.append(envelope) { self.evicted(evicted) }
            return Array(subscribers.keys).compactMap { wake($0) }
        }

        /// Queues the latest event of a `state` kind again for `id`; returns
        /// its waiter if it can have the replay now.
        mutating func replayLatest(to id: UInt64) -> (CheckedContinuation<EventEnvelope?, Never>, EventEnvelope)? {
            guard isState, let latest = ring.latest else { return nil }
            subscribers[id]?.replay = Replay(after: ring.newest, envelope: latest)
            return wake(id)
        }
    }

    private struct State {
        var instances: [String: Instance] = [:]
        var keyBySubscriber: [UInt64: String] = [:]
        var nextSubscriber: UInt64 = 1
        var nextInstance: UInt64 = 1
        /// Why each subscriber's stream ended, for subscribers of a source
        /// that failed; kept until the subscription is cancelled.
        var failures: [UInt64: String] = [:]
        /// Final drop counts of stopped instances that had dropped events,
        /// kept until `takeRetiredDropCounts` collects them (bounded).
        var retired: [DropCount] = []
    }

    private static let retiredLimit = 256

    private let state = Mutex(State())

    public init(
        catalog: EventCatalog = .standard, environment: SourceEnvironment = SourceEnvironment(),
        retainedEvents: Int = 512
    ) {
        self.catalog = catalog
        self.environment = environment
        self.retainedEvents = max(1, retainedEvents)
        environment.attach(hub: self)
    }

    /// Subscribes to `kind` with `parameters` (a JSON object, or null for
    /// none). Throws `EventError` for an unknown kind, invalid parameters,
    /// a kind whose audience excludes `subscriber`, or a source that cannot
    /// start.
    public func subscribe(
        _ kind: String, parameters: JSONValue = .object([:]), subscriber: EventSubscriber = .external
    ) throws -> EventSubscription {
        guard let eventKind = catalog.kind(named: kind) else { throw EventError.unknownEvent(kind) }
        return try subscribe(eventKind, try eventKind.normalized(parameters), subscriber: subscriber)
    }

    /// Subscribes with parameters already decoded, such as those a caller
    /// checked grants against, so the source watches exactly what was
    /// checked.
    public func subscribe(_ parameters: NormalizedParameters, subscriber: EventSubscriber = .external) throws
        -> EventSubscription
    {
        guard let eventKind = catalog.kind(named: parameters.kind) else {
            throw EventError.unknownEvent(parameters.kind)
        }
        return try subscribe(eventKind, parameters, subscriber: subscriber)
    }

    private func subscribe(
        _ eventKind: AnyEventKind, _ given: NormalizedParameters, subscriber: EventSubscriber
    ) throws -> EventSubscription {
        let kind = eventKind.name
        let normalized = given.json
        // Which of a kind's events each rule sees is its view, applied where
        // the rule dispatches (`RuleViewedPayload`); the hub decides only
        // who may subscribe.
        if eventKind.audience == .rules, case .external = subscriber {
            throw EventError.restricted("\(kind) is delivered only to rules, in the file that caused it")
        }
        let key = kind + " " + normalized.canonicalString

        let (id, token, isFirst) = state.withLock { state -> (UInt64, UInt64, Bool) in
            let id = state.nextSubscriber
            state.nextSubscriber += 1
            state.keyBySubscriber[id] = key
            let isFirst = state.instances[key] == nil
            let token = state.nextInstance
            if isFirst { state.nextInstance += 1 }
            // A new subscriber reads only what arrives from now on, except a
            // `state` kind's current value, which it gets first as a replay.
            func subscribe(_ instance: inout Instance) -> (UInt64, UInt64, Bool) {
                let newest = instance.ring.newest
                let replay = instance.isState ? instance.ring.latest.map { Replay(after: newest, envelope: $0) } : nil
                instance.subscribers[id] = Subscriber(owner: subscriber, cursor: newest + 1, replay: replay)
                return (id, instance.token, isFirst)
            }
            // In place, through the defaulting subscript (see Instance).
            return subscribe(
                &state.instances[
                    key,
                    default: Instance(
                        token: token, kind: eventKind, parameters: normalized,
                        ring: EventRing(capacity: retainedEvents))
                ])
        }

        if isFirst {
            // Started outside the lock: a source may emit its initial state
            // synchronously from `start`, and emitting takes the lock.
            do {
                let source = try eventKind.makeSource(
                    given, environment: environment,
                    fail: { [weak self] reason in
                        self?.fail(key: key, token: token, reason: reason)
                    },
                    sink: { [weak self] emission in
                        self?.deliver(key: key, token: token, emission)
                    })
                try source.start()
                let keep = state.withLock { state -> Bool in
                    guard state.instances[key]?.token == token else { return false }
                    state.instances[key]?.source = source
                    return true
                }
                // Every subscriber left, or the source failed, while it was
                // starting.
                if !keep { source.stop() }
            } catch {
                let waiters = state.withLock { state -> [CheckedContinuation<EventEnvelope?, Never>] in
                    guard state.instances[key]?.token == token else { return [] }
                    let subscribers = state.instances.removeValue(forKey: key)?.subscribers ?? [:]
                    for subscriber in subscribers.keys { state.keyBySubscriber[subscriber] = nil }
                    return subscribers.values.compactMap(\.waiter)
                }
                for waiter in waiters { waiter.resume(returning: nil) }
                if let error = error as? EventError { throw error }
                throw EventError.sourceUnavailable("\(kind): \(error)")
            }
        }

        return EventSubscription(
            id: id, kind: kind, parameters: normalized,
            events: EventStream(hub: self, subscriber: id)
        ) { [weak self] in
            self?.release(id)
        }
    }

    /// Delivers the latest event of a `state` source again, as a replay, to
    /// one subscriber only, after everything it has not read yet.
    public func replayLatest(to subscription: EventSubscription) {
        let woken = state.withLock { state -> (CheckedContinuation<EventEnvelope?, Never>, EventEnvelope)? in
            guard let key = state.keyBySubscriber[subscription.id] else { return nil }
            return state.instances[key]?.replayLatest(to: subscription.id)
        }
        if let (waiter, envelope) = woken { waiter.resume(returning: envelope) }
    }

    /// Why the hub ended `subscription`'s stream without it being cancelled:
    /// the reason its source gave when it failed. Nil while the stream runs.
    public func endReason(of subscription: EventSubscription) -> String? {
        state.withLock { $0.failures[subscription.id] }
    }

    /// Whether the subscriber is suspended in `next`, waiting for an event.
    func isWaiting(_ subscription: EventSubscription) -> Bool {
        state.withLock { state in
            guard let key = state.keyBySubscriber[subscription.id] else { return false }
            return state.instances[key]?.subscribers[subscription.id]?.waiter != nil
        }
    }

    /// Events whose envelope each running instance still holds, by kind.
    func heldEvents() -> [String: Int] {
        state.withLock { state in
            state.instances.values.reduce(into: [:]) { $0[$1.kind.name, default: 0] += $1.ring.held }
        }
    }

    /// The ring storage of each running instance, by kind.
    func ringStorage() -> [String: UnsafeRawPointer?] {
        state.withLock { state in
            state.instances.values.reduce(into: [:]) { $0[$1.kind.name] = $1.ring.storage }
        }
    }

    /// Snapshot of every running source.
    public func statistics() -> [SourceStatistics] {
        state.withLock { state in
            state.instances.values.map(Self.statistics(of:))
                .sorted { ($0.kind, $0.parameters.canonicalString) < ($1.kind, $1.parameters.canonicalString) }
        }
    }

    /// Events one source instance dropped for one subscriber, over the
    /// instance's life: what `meerkat.dropped` reports, per rule file.
    public struct DropCount: Sendable, Equatable {
        public struct Key: Sendable, Hashable {
            public let instance: UInt64
            public let subscriber: EventSubscriber
        }

        public let key: Key
        public let kind: String
        public let parameters: JSONValue
        public let dropped: UInt64
    }

    /// Drop counts of every running source, by who missed the events.
    public func dropCounts() -> [DropCount] {
        state.withLock { state in state.instances.values.flatMap(Self.dropCounts(of:)) }
    }

    /// Drop counts of sources that stopped since the last call, so drops
    /// just before a source stops are not lost.
    public func takeRetiredDropCounts() -> [DropCount] {
        state.withLock { state in
            defer { state.retired.removeAll() }
            return state.retired
        }
    }

    private static func dropCounts(of instance: Instance) -> [DropCount] {
        instance.droppedBy.map { subscriber, dropped in
            DropCount(
                key: DropCount.Key(instance: instance.token, subscriber: subscriber), kind: instance.kind.name,
                parameters: instance.parameters, dropped: dropped)
        }
    }

    private static func statistics(of instance: Instance) -> SourceStatistics {
        SourceStatistics(
            instance: instance.token,
            kind: instance.kind.name,
            parameters: instance.parameters,
            subscribers: instance.subscribers.count,
            delivered: instance.delivered,
            dropped: instance.dropped,
            detail: instance.source?.detail,
            unencodable: instance.unencodable?.count ?? 0,
            lastUnencodable: instance.unencodable?.reason
        )
    }

    // MARK: - Internals

    /// The next event for subscriber `id`, suspending until one arrives; nil
    /// once the subscription is cancelled or its source failed.
    fileprivate func next(for id: UInt64) async -> EventEnvelope? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<EventEnvelope?, Never>) in
                let ready = state.withLock { state -> EventEnvelope?? in
                    guard let key = state.keyBySubscriber[id], state.instances[key] != nil else {
                        return .some(nil)
                    }
                    if let envelope = state.instances[key]?.read(id) { return envelope }
                    precondition(
                        state.instances[key]?.subscribers[id]?.waiter == nil,
                        "an event stream was iterated from two tasks at once")
                    state.instances[key]?.subscribers[id]?.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: { [weak self] in
            self?.release(id)
        }
    }

    private func deliver(key: String, token: UInt64, _ emission: Emission) {
        let now = nowMilliseconds()
        let woken = state.withLock { state -> [(CheckedContinuation<EventEnvelope?, Never>, EventEnvelope)] in
            guard state.instances[key]?.token == token else { return [] }
            switch emission {
            case .event(let payload, let origin, let value):
                // Appending under the lock keeps every subscriber's order
                // equal to the sequence order; waiters resume after the
                // lock is released.
                return state.instances[key]?.append(payload: payload, origin: origin, value: value, time: now)
                    ?? []
            case .unencodable(let reason):
                let count = (state.instances[key]?.unencodable?.count ?? 0) + 1
                state.instances[key]?.unencodable = (count, reason)
                return []
            }
        }
        for (waiter, envelope) in woken { waiter.resume(returning: envelope) }
    }

    /// Ends a source instance whose source failed after it started. Each
    /// subscriber's stream ends at once, events it had not read included,
    /// and its key is forgotten, so a later subscriber with the same
    /// parameters starts a new instance.
    private func fail(key: String, token: UInt64, reason: String) {
        let (source, waiters) = state.withLock {
            state -> ((any EventSource)?, [CheckedContinuation<EventEnvelope?, Never>]) in
            guard state.instances[key]?.token == token, let instance = state.instances.removeValue(forKey: key)
            else { return (nil, []) }
            for id in instance.subscribers.keys {
                state.keyBySubscriber[id] = nil
                state.failures[id] = reason
            }
            Self.retire(instance, in: &state)
            return (instance.source, instance.subscribers.values.compactMap(\.waiter))
        }
        for waiter in waiters { waiter.resume(returning: nil) }
        // The source may be failing on its own queue, which its `stop` can
        // wait for. Nil when it fails inside `start`: `subscribe` stops it.
        if let source { DispatchQueue.global(qos: .utility).async { source.stop() } }
    }

    /// Keeps a departing instance's final drop counts if it dropped events.
    private static func retire(_ instance: Instance, in state: inout State) {
        state.retired += dropCounts(of: instance)
        if state.retired.count > retiredLimit { state.retired.removeFirst(state.retired.count - retiredLimit) }
    }

    private func release(_ id: UInt64) {
        let (stopping, waiter) = state.withLock {
            state -> ((any EventSource)?, CheckedContinuation<EventEnvelope?, Never>?) in
            state.failures[id] = nil
            guard let key = state.keyBySubscriber.removeValue(forKey: id),
                var instance = state.instances.removeValue(forKey: key)
            else { return (nil, nil) }
            let waiter = instance.subscribers.removeValue(forKey: id)?.waiter
            if instance.subscribers.isEmpty {
                Self.retire(instance, in: &state)
                return (instance.source, waiter)
            }
            // What only the departed subscriber had left to read.
            instance.releaseRead()
            state.instances[key] = instance
            return (nil, waiter)
        }
        waiter?.resume(returning: nil)
        stopping?.stop()
    }
}
