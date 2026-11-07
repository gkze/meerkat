import CoreServices
import Foundation
import Synchronization

/// One FSEvents record.
public struct FSEvent: Sendable, Equatable {
    public let path: String
    public let flags: FSEventStreamEventFlags
    public let id: FSEventStreamEventId

    public init(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId) {
        self.path = path
        self.flags = flags
        self.id = id
    }

    public func has(_ flag: Int) -> Bool {
        flags & FSEventStreamEventFlags(flag) != 0
    }
}

/// Owns one `FSEventStreamRef` for its whole life: create, schedule on a
/// private queue, start, and stop/invalidate/release exactly once.
///
/// The stream context retains this object, so a callback already queued when
/// `stop` runs still finds a live instance.
public final class FSEventStream: EventSource {
    public struct Options: Sendable, Equatable {
        /// Coalescing window in seconds. A client-side knob: a larger value
        /// lets fseventsd batch deliveries at the cost of timestamp
        /// precision. 0 asks for immediate delivery, the most expensive
        /// setting available to a client.
        public var latency: Double = 1.0
        /// Resume from this event id (replays history since it); nil means
        /// only changes from now on.
        public var sinceEventId: FSEventStreamEventId?
        /// Ask FSEvents to flag events caused by this process.
        public var markSelf = true

        public init(latency: Double = 1.0, sinceEventId: FSEventStreamEventId? = nil, markSelf: Bool = true) {
            self.latency = latency
            self.sinceEventId = sinceEventId
            self.markSelf = markSelf
        }
    }

    private let paths: [String]
    private let options: Options
    private let handler: @Sendable ([FSEvent]) -> Void
    private let queue = DispatchQueue(label: "com.gkze.meerkat.fsevents", qos: .utility)
    private let stream = Mutex<StreamRef?>(nil)

    private struct StreamRef: @unchecked Sendable {
        let value: FSEventStreamRef
    }

    public init(
        paths: [String], options: Options = Options(),
        handler: @escaping @Sendable ([FSEvent]) -> Void
    ) {
        self.paths = paths
        self.options = options
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<FSEventStream>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventStream>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        // NoDefer defeats coalescing, so only ask for it when the caller
        // explicitly wants zero latency.
        var flagBits = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
        if options.latency <= 0 { flagBits |= kFSEventStreamCreateFlagNoDefer }
        if options.markSelf { flagBits |= kFSEventStreamCreateFlagMarkSelf }

        guard
            let ref = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventCallback,
                &context,
                paths as CFArray,
                options.sinceEventId ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                max(options.latency, 0),
                FSEventStreamCreateFlags(flagBits)
            )
        else {
            throw MeerkatError.streamCreationFailed
        }

        FSEventStreamSetDispatchQueue(ref, queue)
        guard FSEventStreamStart(ref) else {
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
            throw MeerkatError.streamCreationFailed
        }
        stream.withLock { $0 = StreamRef(value: ref) }
    }

    public func stop() {
        guard
            let ref = stream.withLock({ current -> StreamRef? in
                defer { current = nil }
                return current
            })
        else { return }
        FSEventStreamStop(ref.value)
        FSEventStreamInvalidate(ref.value)
        FSEventStreamRelease(ref.value)
    }

    /// Delivers what FSEvents holds back for the latency window now, and
    /// returns after the handler has run for it. Held under the lock, so a
    /// `stop` meanwhile waits; it must not be called from the handler.
    public func flush() {
        stream.withLock { current in
            if let current { FSEventStreamFlushSync(current.value) }
        }
    }

    /// The latest event id FSEvents has issued system-wide, for checkpoints.
    public static var currentEventId: FSEventStreamEventId {
        FSEventsGetCurrentEventId()
    }

    fileprivate func deliver(
        count: Int, paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        ids: UnsafePointer<FSEventStreamEventId>
    ) {
        let array = unsafeBitCast(paths, to: NSArray.self)
        var events: [FSEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = array[index] as? String else { continue }
            events.append(FSEvent(path: path, flags: flags[index], id: ids[index]))
        }
        handler(events)
    }
}

private let fsEventCallback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
    guard let info else { return }
    Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()
        .deliver(count: count, paths: paths, flags: flags, ids: ids)
}
