import CoreServices
import Foundation
import Synchronization

/// What file churn watches: a root and the folders under it to leave out.
/// `meerkat.json`'s `files` section sets the daemon's scope; `fs.churn`
/// subscriptions without a `root` measure it.
public struct FileScope: Codable, Sendable, Equatable {
    /// An absolute path.
    public var root: String
    /// Absolute paths; events at or below one are not counted.
    public var exclude: [String]

    public init(root: String, exclude: [String]) {
        self.root = root
        self.exclude = exclude
    }

    /// The whole startup volume, less the folders whose churn is the
    /// system's own bookkeeping: per-user temporary and cache folders, system
    /// databases, and the Spotlight and FSEvents stores. FSEvents reports
    /// files on the data volume by their firmlinked paths (/Users,
    /// /private), so these are the paths to exclude.
    public static let standard = FileScope(
        root: "/",
        exclude: ["/private/var/folders", "/private/var/db", "/.Spotlight-V100", "/.fseventsd"])
}

/// Aggregates FSEvents records into per-cluster and per-category counts.
///
/// A value type with no I/O: `PathChurnMonitor` feeds it from a live stream,
/// and tests feed it directly.
public struct ChurnAccumulator: Sendable {
    public let root: String
    public let depth: Int
    public let home: String
    /// Events at or below these paths are dropped before counting.
    public let exclude: [String]

    private var counts: [String: Int] = [:]
    private var categoryCounts: [ChurnCategory: Int] = [:]
    private var total = 0
    private var created = 0
    private var modified = 0
    private var removed = 0
    private var renamed = 0

    public init(root: String, depth: Int, home: String, exclude: [String] = []) {
        self.root = root
        self.depth = depth
        self.home = home
        self.exclude = exclude
    }

    public mutating func record(_ events: [FSEvent]) {
        for event in events where !isExcluded(event.path) {
            total += 1
            if event.has(kFSEventStreamEventFlagItemCreated) { created += 1 }
            if event.has(kFSEventStreamEventFlagItemModified) { modified += 1 }
            if event.has(kFSEventStreamEventFlagItemRemoved) { removed += 1 }
            if event.has(kFSEventStreamEventFlagItemRenamed) { renamed += 1 }
            counts[PathChurnMonitor.bucketKey(for: event.path, depth: depth, home: home), default: 0] += 1
            categoryCounts[ChurnCategory.classify(event.path), default: 0] += 1
        }
    }

    private func isExcluded(_ path: String) -> Bool {
        exclude.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    public func result(windowSeconds: Double, topBuckets: Int) -> ChurnResult {
        let buckets =
            counts
            .map { ChurnBucket(path: $0.key, events: $0.value) }
            .sorted { ($0.events, $1.path) > ($1.events, $0.path) }
            .prefix(topBuckets)
        let categories =
            categoryCounts
            .map { ChurnBucket(path: $0.key.rawValue, events: $0.value) }
            .sorted { ($0.events, $1.path) > ($1.events, $0.path) }
        return ChurnResult(
            root: root,
            windowSeconds: windowSeconds,
            totalEvents: total,
            created: created,
            modified: modified,
            removed: removed,
            renamed: renamed,
            buckets: Array(buckets),
            categories: categories,
            excluded: exclude
        )
    }
}

/// Counts filesystem change events per directory cluster using FSEvents.
///
/// This observes actual change notifications instead of inferring activity
/// from mtimes after the fact. FSEvents needs no entitlement to watch the
/// data volume, but paths protected by TCC (e.g. other apps' containers)
/// simply produce no events for this process.
public final class PathChurnMonitor: Sendable {
    private let accumulator: Mutex<ChurnAccumulator>
    private let latency: Double
    private let root: String

    /// - Parameters:
    ///   - root: directory to watch.
    ///   - depth: path components kept when bucketing, counted from `/`.
    ///   - home: used only to render `~` in bucket names.
    ///   - exclude: absolute paths whose events are not counted.
    ///   - latency: FSEvents coalescing window in seconds; see
    ///     `FSEventStream.Options.latency`.
    public init(
        root: String,
        depth: Int = 6,
        home: String = NSHomeDirectory(),
        exclude: [String] = [],
        latency: Double = 1.0
    ) {
        self.root = root
        self.latency = latency
        accumulator = Mutex(ChurnAccumulator(root: root, depth: depth, home: home, exclude: exclude))
    }

    /// Runs the stream while `body` runs, and returns the aggregate with
    /// `body`'s result: a churn window over exactly the time another
    /// measurement takes, so the two describe one interval. Blocks as `body`
    /// does; for one-shot CLI use.
    public func measure<T>(during body: () throws -> T, topBuckets: Int = 12) throws -> (churn: ChurnResult, result: T)
    {
        let (stream, end) = try startStream()
        let started = ContinuousClock.now
        let result: T
        do {
            result = try body()
        } catch {
            stream.stop()
            end.remove()
            throw error
        }
        let window = started.duration(to: .now) / .seconds(1)
        return (finish(stream, end, windowSeconds: window, topBuckets: topBuckets), result)
    }

    /// The same measurement without blocking a thread.
    public func measure(duration: Duration, topBuckets: Int = 12) async throws -> ChurnResult {
        let (stream, end) = try startStream()
        do {
            try await Task.sleep(for: duration)
        } catch {
            stream.stop()
            end.remove()
            throw error
        }
        // Waiting for the end marker blocks, so not on a shared thread.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: self.finish(stream, end, windowSeconds: duration / .seconds(1), topBuckets: topBuckets))
            }
        }
    }

    private func startStream() throws -> (FSEventStream, WindowEnd) {
        accumulator.withLock {
            $0 = ChurnAccumulator(root: $0.root, depth: $0.depth, home: $0.home, exclude: $0.exclude)
        }
        let end = try WindowEnd()
        let stream = FSEventStream(paths: [root, end.directory], options: .init(latency: latency, markSelf: false)) {
            events in
            self.accumulator.withLock { $0.record(events.filter { !end.contains($0.path) }) }
            if events.contains(where: { $0.path == end.marker }) { end.arrived() }
        }
        do {
            try stream.start()
        } catch {
            end.remove()
            throw error
        }
        return (stream, end)
    }

    /// The counts once FSEvents has delivered every change made before the
    /// window ended. Its latency holds changes back for up to `latency`
    /// seconds, and fseventsd reads them from the kernel behind time, by
    /// seconds on a busy volume; a flush delivers only what fseventsd has
    /// read. So a marker file is written at the end and the stream flushed
    /// until the marker's own event arrives: FSEvents delivers in event-id
    /// order, so every earlier change has arrived too. Past
    /// `WindowEnd.limit` the counts are what arrived by then.
    private func finish(_ stream: FSEventStream, _ end: WindowEnd, windowSeconds: Double, topBuckets: Int)
        -> ChurnResult
    {
        end.mark()
        let deadline = ContinuousClock.now + WindowEnd.limit
        repeat {
            stream.flush()
        } while !end.waitForArrival(.milliseconds(50)) && ContinuousClock.now < deadline
        stream.stop()
        end.remove()
        return accumulator.withLock { $0.result(windowSeconds: windowSeconds, topBuckets: topBuckets) }
    }

    /// A private folder watched beside the root, whose one file marks a
    /// window's end in FSEvents' own order. Its events are never counted.
    private final class WindowEnd: Sendable {
        /// How long the end waits for FSEvents to catch up.
        static let limit = Duration.seconds(5)

        /// Without links (`/private/var/folders/…`), as FSEvents reports it.
        let directory: String
        private let reached = DispatchSemaphore(value: 0)

        init() throws {
            let made = FileManager.default.temporaryDirectory.appendingPathComponent(
                "meerkat-churn-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            guard let real = realpath(made.path, nil) else {
                try? FileManager.default.removeItem(at: made)
                throw MeerkatError.streamCreationFailed
            }
            defer { free(real) }
            directory = String(cString: real)
        }

        /// Written only at the end. Not the folder: fseventsd reads behind
        /// time, so the folder's own creation can arrive after the stream
        /// starts.
        var marker: String { directory + "/end" }

        func contains(_ path: String) -> Bool { path == directory || path.hasPrefix(directory + "/") }

        func mark() { FileManager.default.createFile(atPath: marker, contents: nil) }

        func arrived() { reached.signal() }

        func waitForArrival(_ timeout: Duration) -> Bool {
            reached.wait(timeout: .now() + .nanoseconds(Int(timeout / .nanoseconds(1)))) == .success
        }

        func remove() { try? FileManager.default.removeItem(atPath: directory) }
    }

    // MARK: - Bucketing (pure, unit-tested)

    /// Collapse a file path to a directory cluster of at most `depth` components.
    ///
    /// "/Users/x/Library/Application Support/Linear/Cache/js/abc_0" with
    /// depth 5 becomes "~/Library/Application Support/Linear". Keeping the
    /// last component (the file) would produce one bucket per file, which is
    /// noise rather than a cluster.
    public static func bucketKey(for path: String, depth: Int, home: String) -> String {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !comps.isEmpty else { return path }

        let take = max(1, min(depth, comps.count))
        var key = "/" + comps[0..<take].joined(separator: "/")

        if !home.isEmpty, key == home || key.hasPrefix(home + "/") {
            key = "~" + key.dropFirst(home.count)
        }
        return key
    }
}
