import CoreServices
import Foundation
import Synchronization

/// Expands `~` and requires an absolute path, so equal directories normalize
/// to equal parameters.
public func absolutePath(_ raw: String, field: String) throws -> String {
    (try expandedPath(raw, field: field) as NSString).standardizingPath
}

/// A path in the form FSEvents reports it, for matching events against:
/// `~` expanded, as the kernel names it (`canonicalPath`: symlinks
/// resolved, so `/var/folders` is `/private/var/folders`), no trailing
/// slash. Not `standardizingPath`, which strips `/private` and would never
/// match an event's path.
public func eventPath(_ raw: String, field: String) throws -> String {
    canonicalPath(withoutTrailingSlash(try expandedPath(raw, field: field)))
}

/// An absolute `path` as the kernel names the file it reaches: the real
/// path of its longest existing ancestor (every symlink resolved), with
/// that ancestor's deepest directory named as the kernel names it once
/// open (`F_GETPATH`), and the rest appended as written.
///
/// `realpath` alone leaves other names of one folder standing: since
/// macOS 10.15 the data volume's folders are reached at their firmlinks
/// (`/Users`) and under the volume's mount point
/// (`/System/Volumes/Data/Users`), and `/.nofollow/…` and
/// `/.vol/<device>/<inode>` name any file again. The kernel's name is one
/// of them whichever was used, so paths compared to decide what file they
/// name (grants, the daemon's protected paths, event paths) are compared
/// in this form. The runtime's protected.rs keeps the same form
/// (`resolve`); protected_cases.json in it holds the two to the same
/// verdicts on protected paths.
public func canonicalPath(_ path: String) -> String {
    var existing = path
    var rest: [String] = []
    while existing != "/", !existing.isEmpty {
        if let real = realpath(existing, nil) {
            defer { free(real) }
            existing = String(cString: real)
            break
        }
        rest.insert((existing as NSString).lastPathComponent, at: 0)
        existing = (existing as NSString).deletingLastPathComponent
    }
    // A directory that cannot be opened (no read permission) is named
    // through the nearest one above it that can: below a folder's kernel
    // name, the rest are plain names.
    var directory = existing
    while true {
        if let named = kernelName(ofDirectory: directory) {
            directory = named
            break
        }
        guard directory != "/", !directory.isEmpty else { break }
        rest.insert((directory as NSString).lastPathComponent, at: 0)
        directory = (directory as NSString).deletingLastPathComponent
    }
    return rest.reduce(directory) { ($0 as NSString).appendingPathComponent($1) }
}

/// The kernel's name for the directory at `path`, or nil when it is not a
/// directory or cannot be opened. Opened without blocking, so a FIFO swapped
/// in is refused rather than waited on.
private func kernelName(ofDirectory path: String) -> String? {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &name) != -1 else { return nil }
    return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The data volume's names for a canonical `path`: under its mount point
/// (`/System/Volumes/Data/Users/…` for `/Users/…`), for each firmlink in
/// `/usr/share/firmlinks` that `path` is at or inside. The kernel names
/// such a folder by its firmlink, so `canonicalPath` never returns these;
/// but the mount point and the folders above it are above them, and a
/// check for what is above a path needs them.
public func dataVolumeNames(of path: String) -> [String] {
    Firmlinks.standard.compactMap { link in
        guard path == link.path || path.hasPrefix(link.path + "/") else { return nil }
        return link.onDataVolume + path.dropFirst(link.path.count)
    }
}

/// `/usr/share/firmlinks`: each line a firmlink's path, a tab, and its
/// folder's path relative to the data volume's root, which is where the
/// volume holding the firmlink's folder is mounted. Read as the runtime's
/// protected.rs reads it (`FIRMLINKS`).
private enum Firmlinks {
    static let standard: [(path: String, onDataVolume: String)] = {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0].hasPrefix("/"), !fields[1].hasPrefix("/") else { return nil }
            let path = String(fields[0])
            var volume = statfs()
            guard statfs(path, &volume) == 0 else { return nil }
            let mount = String(nulTerminatedBytesOf: volume.f_mntonname)
            guard mount != "/", mount.hasPrefix("/") else { return nil }
            return (path, mount + "/" + fields[1])
        }
    }()
}

private func expandedPath(_ raw: String, field: String) throws -> String {
    let expanded = (raw as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else {
        throw EventError.invalidParameters("\"\(field)\" must be an absolute path or start with ~, got \"\(raw)\"")
    }
    return expanded
}

/// `path` without trailing slashes, as the OS's mount points and event paths
/// are written; `/` stays.
func withoutTrailingSlash(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
}

// MARK: - fs.change

public struct FSChangeParameters: PathObservingParameters {
    public var paths: [String]
    public var latency: Double
    public var sinceEventId: Double?

    public init(paths: [String], latency: Double = 1, sinceEventId: Double? = nil) {
        self.paths = paths
        self.latency = latency
        self.sinceEventId = sinceEventId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paths = try container.decode([String].self, forKey: .paths).map { try absolutePath($0, field: "paths") }
        latency = try container.decodeIfPresent(Double.self, forKey: .latency) ?? 1
        sinceEventId = try container.decodeIfPresent(Double.self, forKey: .sinceEventId)
    }

    public var observedPaths: ObservedPaths { ObservedPaths(paths: paths) }

    public func validate() throws {
        guard !paths.isEmpty else { throw EventError.invalidParameters("\"paths\" must not be empty") }
        try requireInterval(latency, name: "latency", in: 0...60)
        // JSON numbers are exact up to 2^53, and `FSEventStreamEventId(_:)`
        // traps past 2^64.
        if let sinceEventId, !(0...0x20_0000_0000_0000).contains(sinceEventId) || sinceEventId != sinceEventId.rounded()
        {
            throw EventError.invalidParameters("\"sinceEventId\" must be an integer between 0 and 2^53")
        }
    }

    public static var schema: TypeSchema {
        .object(
            ObjectSchema([
                .field("paths", [String].self, doc: "Directories to watch recursively; absolute or starting with ~."),
                .optional(
                    "latency", Double.self,
                    doc: "FSEvents coalescing window in seconds, 0–60. Default 1. Lower costs more."),
                .optional(
                    "sinceEventId", Double.self,
                    doc: "Replay history after this event id (from a previous event's `eventId`), then continue live."),
            ]))
    }

    public static var examples: [Self] {
        [Self(paths: ["/Users/example/Library"]), Self(paths: ["/tmp"], latency: 0, sinceEventId: 1200)]
    }
}

public struct FSChangePayload: EventPayload, Equatable {
    public enum Change: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case created, removed, modified, renamed, inodeMetadataModified, finderInfoModified
        case ownerChanged, xattrModified, cloned
    }

    public enum ItemType: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case file, directory, symlink, hardlink, unknown
    }

    public enum StreamFlag: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        /// Events were coalesced or dropped below this path: rescan it.
        case mustScanSubDirs
        case userDropped, kernelDropped, eventIdsWrapped
        /// The replay requested with `sinceEventId` has caught up.
        case historyDone
        case rootChanged, mount, unmount
    }

    public let path: String
    /// What changed. Several can be set at once: FSEvents coalesces.
    public let changes: [Change]
    public let itemType: ItemType
    /// Stream-level conditions; usually empty.
    public let streamFlags: [StreamFlag]
    public let eventId: Double

    public static var schema: TypeSchema {
        .named(
            "FSChange",
            ObjectSchema([
                .field("path", String.self),
                .field("changes", [Change].self, doc: "What changed; FSEvents may coalesce several into one event."),
                .field("itemType", ItemType.self),
                .field(
                    "streamFlags", [StreamFlag].self, doc: "Stream conditions such as mustScanSubDirs; usually empty."),
                .field("eventId", Double.self, doc: "Pass as `sinceEventId` to resume after this event."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                path: "/Users/example/notes.md", changes: [.created, .modified], itemType: .file, streamFlags: [],
                eventId: 1_234_567),
            Self(
                path: "/Users/example", changes: [], itemType: .unknown, streamFlags: [.historyDone], eventId: 1_234_568
            ),
        ]
    }

    static func from(_ event: FSEvent) -> FSChangePayload {
        let changeFlags: [(Int, Change)] = [
            (kFSEventStreamEventFlagItemCreated, .created),
            (kFSEventStreamEventFlagItemRemoved, .removed),
            (kFSEventStreamEventFlagItemModified, .modified),
            (kFSEventStreamEventFlagItemRenamed, .renamed),
            (kFSEventStreamEventFlagItemInodeMetaMod, .inodeMetadataModified),
            (kFSEventStreamEventFlagItemFinderInfoMod, .finderInfoModified),
            (kFSEventStreamEventFlagItemChangeOwner, .ownerChanged),
            (kFSEventStreamEventFlagItemXattrMod, .xattrModified),
            (kFSEventStreamEventFlagItemCloned, .cloned),
        ]
        let streamFlags: [(Int, StreamFlag)] = [
            (kFSEventStreamEventFlagMustScanSubDirs, .mustScanSubDirs),
            (kFSEventStreamEventFlagUserDropped, .userDropped),
            (kFSEventStreamEventFlagKernelDropped, .kernelDropped),
            (kFSEventStreamEventFlagEventIdsWrapped, .eventIdsWrapped),
            (kFSEventStreamEventFlagHistoryDone, .historyDone),
            (kFSEventStreamEventFlagRootChanged, .rootChanged),
            (kFSEventStreamEventFlagMount, .mount),
            (kFSEventStreamEventFlagUnmount, .unmount),
        ]
        let itemType: ItemType =
            event.has(kFSEventStreamEventFlagItemIsFile)
            ? .file
            : event.has(kFSEventStreamEventFlagItemIsDir)
                ? .directory
                : event.has(kFSEventStreamEventFlagItemIsSymlink)
                    ? .symlink
                    : event.has(kFSEventStreamEventFlagItemIsHardlink)
                        ? .hardlink
                        : .unknown
        return FSChangePayload(
            path: event.path,
            changes: changeFlags.filter { event.has($0.0) }.map(\.1),
            itemType: itemType,
            streamFlags: streamFlags.filter { event.has($0.0) }.map(\.1),
            eventId: Double(event.id)
        )
    }
}

public enum FSChangeEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "fs.change",
        "A file or directory under a watched path changed. FSEvents coalesces within `latency`, so one event can carry several changes; paths protected by privacy controls produce no events. Changes made by this daemon have origin \"meerkat\".",
        mechanism: .push, semantics: .occurrence, loss: .coalesced,
        observation: .paths,
        source: "FSEvents (file-level)"
    )

    public static func makeSource(
        _ parameters: FSChangeParameters, environment: SourceEnvironment,
        emit: Emitter<FSChangePayload>
    ) throws -> any EventSource {
        let options = FSEventStream.Options(
            latency: parameters.latency,
            sinceEventId: parameters.sinceEventId.map { FSEventStreamEventId($0) },
            markSelf: true
        )
        let stream = FSEventStream(paths: parameters.paths, options: options) { events in
            for event in events {
                emit(
                    FSChangePayload.from(event),
                    origin: event.has(kFSEventStreamEventFlagOwnEvent) ? .meerkat : .system)
            }
        }
        return stream
    }
}

// MARK: - fs.churn

public struct FSChurnParameters: PathObservingParameters {
    /// The directory to measure; nil measures the daemon's file scope
    /// (`meerkat.json` `files`, by default the whole startup volume), read
    /// afresh for each window so an edit applies at the next one.
    public var root: String?
    /// Paths left out, on top of the scope's own exclusions when `root` is nil.
    public var exclude: [String]
    public var window: Double
    public var every: Double
    public var depth: Int
    public var top: Int

    public static let defaultWindow = 4.0
    public static let defaultEvery = 25.0
    public static let defaultDepth = 5
    public static let defaultTop = 12
    static let depthRange = 1...64
    static let topRange = 1...500

    public init(
        root: String? = nil, exclude: [String] = [], window: Double = defaultWindow, every: Double = defaultEvery,
        depth: Int = defaultDepth, top: Int = defaultTop
    ) {
        self.root = root
        self.exclude = exclude
        self.window = window
        self.every = every
        self.depth = depth
        self.top = top
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decodeIfPresent(String.self, forKey: .root).map { try absolutePath($0, field: "root") }
        exclude = try (container.decodeIfPresent([String].self, forKey: .exclude) ?? []).map {
            try eventPath($0, field: "exclude")
        }
        window = try container.decodeIfPresent(Double.self, forKey: .window) ?? Self.defaultWindow
        every = try container.decodeIfPresent(Double.self, forKey: .every) ?? Self.defaultEvery
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? Self.defaultDepth
        top = try container.decodeIfPresent(Int.self, forKey: .top) ?? Self.defaultTop
    }

    public func validate() throws {
        try requireInterval(window, name: "window", in: 0.5...3600)
        try requireInterval(every, name: "every", in: window...86_400)
        try requireCount(depth, name: "depth", in: Self.depthRange)
        try requireCount(top, name: "top", in: Self.topRange)
        guard exclude.count <= 256 else { throw EventError.invalidParameters("\"exclude\" takes at most 256 paths") }
    }

    public var observedPaths: ObservedPaths { ObservedPaths(paths: root.map { [$0] }, exclude: exclude) }

    /// The root and exclusions one window measures.
    func scope(in environment: SourceEnvironment) -> FileScope {
        guard let root else {
            let configured = environment.fileScope
            return FileScope(root: configured.root, exclude: configured.exclude + exclude)
        }
        return FileScope(root: root, exclude: exclude)
    }

    public static var schema: TypeSchema {
        .object(
            ObjectSchema([
                .optional(
                    "root", String.self,
                    doc:
                        "Directory to measure. Default: the daemon's file scope, meerkat.json files.root (the whole startup volume) less files.exclude."
                ),
                .optional(
                    "exclude", [String].self,
                    doc: "Absolute or ~ paths whose events are not counted, on top of the scope's own. Default none."),
                .optional(
                    "window", Double.self,
                    doc: "Seconds each measurement listens for. Default \(NumberBounds.format(defaultWindow))."),
                .optional(
                    "every", Double.self,
                    doc:
                        "Seconds between the starts of measurements, at least `window`. Default \(NumberBounds.format(defaultEvery))."
                ),
                .optional(
                    "depth", Int.self, doc: "Path components per bucket, counted from /. Default \(defaultDepth)."),
                .optional("top", Int.self, doc: "Buckets reported. Default \(defaultTop)."),
            ]))
    }

    public static var examples: [Self] { [Self(), Self(root: "/Users/example/Library")] }
}

extension ChurnBucket: SchemaDescribed {
    public static var schema: TypeSchema {
        .named("ChurnBucket", ObjectSchema([.field("path", String.self), .field("events", Int.self)]))
    }
}

extension ChurnResult: EventPayload {
    public static var schema: TypeSchema {
        .named(
            "Churn",
            ObjectSchema([
                .field("root", String.self),
                .field("windowSeconds", Double.self),
                .field("totalEvents", Int.self),
                .field("created", Int.self),
                .field("modified", Int.self),
                .field("removed", Int.self),
                .field("renamed", Int.self),
                .field("buckets", [ChurnBucket].self, doc: "Busiest directory clusters."),
                .field(
                    "categories", [ChurnBucket].self,
                    doc:
                        "The same events by kind, `path` naming it: \(ChurnCategory.allCases.map(\.rawValue).joined(separator: ", "))."
                ),
                .field("excluded", [String].self, doc: "Paths under root whose events were not counted."),
            ]))
    }

    public static var examples: [ChurnResult] {
        [
            ChurnResult(
                root: "/Users/example/Library", windowSeconds: 4, totalEvents: 37, created: 5, modified: 30,
                removed: 1, renamed: 1, buckets: [ChurnBucket(path: "~/Library/Caches/com.example", events: 20)],
                categories: [ChurnBucket(path: "caches", events: 20)], excluded: [])
        ]
    }
}

public enum FSChurnEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "fs.churn",
        "How much changed under a directory (by default the whole startup volume, less meerkat.json's exclusions) during a measurement window, by directory cluster and by file kind. Measures `window` seconds out of every `every`.",
        mechanism: .derived, semantics: .state, loss: .lossy,
        observation: .paths,
        source: "FSEvents (file-level)"
    )

    public static func makeSource(
        _ parameters: FSChurnParameters, environment: SourceEnvironment,
        emit: Emitter<ChurnResult>
    ) throws -> any EventSource {
        let task = Mutex<Task<Void, Never>?>(nil)
        return ClosureSource(
            start: {
                let measuring = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        let started = ContinuousClock.now
                        let scope = parameters.scope(in: environment)
                        let monitor = PathChurnMonitor(
                            root: scope.root, depth: parameters.depth,
                            home: environment.homeDirectory, exclude: scope.exclude)
                        let result: ChurnResult
                        do {
                            result = try await monitor.measure(
                                duration: .seconds(parameters.window), topBuckets: parameters.top)
                        } catch {
                            // Cancellation is `stop`; anything else ends the
                            // measurements for good.
                            if !Task.isCancelled { emit.fail("fs.churn could not measure \(scope.root): \(error)") }
                            return
                        }
                        emit(result)
                        try? await Task.sleep(until: started + .seconds(parameters.every), clock: .continuous)
                    }
                }
                task.withLock { $0 = measuring }
            },
            stop: {
                task.withLock { $0.take() }?.cancel()
            })
    }
}
