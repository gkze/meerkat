import DiskArbitration
import Foundation
import IOKit
import Synchronization

// MARK: - disk.appeared / disk.disappeared

public struct DiskPayload: EventPayload, Equatable {
    public let bsdName: String?
    public let volumeName: String?
    public let volumePath: String?
    public let mediaName: String?
    public let mediaSizeBytes: UInt64?
    public let removable: Bool?
    public let ejectable: Bool?
    public let `internal`: Bool?
    public let whole: Bool?
    public let `protocol`: String?

    public init(
        bsdName: String?, volumeName: String?, volumePath: String?, mediaName: String?,
        mediaSizeBytes: UInt64?, removable: Bool?, ejectable: Bool?, internal: Bool?, whole: Bool?,
        protocol: String?
    ) {
        self.bsdName = bsdName
        self.volumeName = volumeName
        self.volumePath = volumePath
        self.mediaName = mediaName
        self.mediaSizeBytes = mediaSizeBytes
        self.removable = removable
        self.ejectable = ejectable
        self.internal = `internal`
        self.whole = whole
        self.protocol = `protocol`
    }

    public static var schema: TypeSchema {
        .named(
            "Disk",
            ObjectSchema([
                .optional("bsdName", String.self, doc: "For example disk4s1; absent for network volumes."),
                .optional("volumeName", String.self),
                .optional("volumePath", String.self, doc: "Mount point, when mounted."),
                .optional("mediaName", String.self),
                .optional("mediaSizeBytes", UInt64.self),
                .optional("removable", Bool.self),
                .optional("ejectable", Bool.self),
                .optional("internal", Bool.self, doc: "Whether the device is internal to the Mac."),
                .optional("whole", Bool.self, doc: "Whether this is a whole disk rather than a partition or volume."),
                .optional(
                    "protocol", String.self,
                    doc: "Device protocol, for example \"USB\", \"Apple Fabric\" or \"Disk Image\"."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                bsdName: "disk4s1", volumeName: "Backup", volumePath: "/Volumes/Backup", mediaName: "Untitled",
                mediaSizeBytes: 1_000_204_886_016, removable: false, ejectable: true, internal: false, whole: false,
                protocol: "USB"),
            Self(
                bsdName: nil, volumeName: nil, volumePath: nil, mediaName: nil, mediaSizeBytes: nil, removable: nil,
                ejectable: nil, internal: nil, whole: nil, protocol: nil),
        ]
    }

    static func from(_ disk: DADisk) -> DiskPayload {
        let description = DADiskCopyDescription(disk) as? [CFString: Any] ?? [:]
        func value<T>(_ key: CFString, as type: T.Type) -> T? { description[key] as? T }
        return DiskPayload(
            bsdName: value(kDADiskDescriptionMediaBSDNameKey, as: String.self),
            volumeName: value(kDADiskDescriptionVolumeNameKey, as: String.self),
            volumePath: value(kDADiskDescriptionVolumePathKey, as: URL.self)?.path(percentEncoded: false),
            mediaName: value(kDADiskDescriptionMediaNameKey, as: String.self),
            mediaSizeBytes: value(kDADiskDescriptionMediaSizeKey, as: NSNumber.self)?.uint64Value,
            removable: value(kDADiskDescriptionMediaRemovableKey, as: Bool.self),
            ejectable: value(kDADiskDescriptionMediaEjectableKey, as: Bool.self),
            internal: value(kDADiskDescriptionDeviceInternalKey, as: Bool.self),
            whole: value(kDADiskDescriptionMediaWholeKey, as: Bool.self),
            protocol: value(kDADiskDescriptionDeviceProtocolKey, as: String.self)
        )
    }
}

public enum DiskAppearedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "disk.appeared",
        "A disk, partition, APFS volume or network volume became known to DiskArbitration, for example when a drive or disk image is attached. Disks already present when the subscription starts are not reported. Appearing is not mounting: see `volume.mounted`.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "DARegisterDiskAppearedCallback"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<DiskPayload>
    ) throws -> any EventSource {
        DiskArbitrationSource(label: "disk-appeared", phase: .appeared) { emit(.from($0)) }
    }
}

public enum DiskDisappearedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "disk.disappeared",
        "A disk, partition, APFS volume or network volume went away, for example when a drive is ejected or unplugged. The fields describe the disk as DiskArbitration last knew it.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "DARegisterDiskDisappearedCallback"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<DiskPayload>
    ) throws -> any EventSource {
        DiskArbitrationSource(label: "disk-disappeared", phase: .disappeared) { emit(.from($0)) }
    }
}

/// One DiskArbitration session with one callback, scheduled on a private
/// serial queue. Registration and every callback run on that queue.
///
/// DiskArbitration announces every disk that exists when an appeared
/// callback is registered. Its "initial announcements done" signal
/// (`DARegisterIdleCallback`) is not public API, so the existing disks are
/// recognized instead: the IOMedia registry ids present just before
/// registering, plus the mount points of disks without media (network
/// volumes). A disk that appears after that snapshot is reported even when
/// DiskArbitration announces it in its initial batch.
final class DiskArbitrationSource: EventSource {
    enum Phase { case appeared, disappeared }

    private let phase: Phase
    private let queue: DispatchQueue
    private let context: Context
    private let session = Mutex<SessionBox?>(nil)

    final class Context: Sendable {
        let handle: @Sendable (DADisk) -> Void
        /// Disks that existed before registration: set in `start` before the
        /// callback is registered, then claimed by callbacks on the queue.
        let existing: Mutex<ExistingDisks>

        init(handle: @escaping @Sendable (DADisk) -> Void, existing: ExistingDisks) {
            self.handle = handle
            self.existing = Mutex(existing)
        }
    }

    struct ExistingDisks {
        var media: Set<UInt64>
        var mountPoints: Set<String>

        static func snapshot() throws -> ExistingDisks {
            var media = Set<UInt64>()
            try IORegistry.forEachService(matching: "IOMedia") { service in
                let id = IORegistry.entryID(service)
                if id != 0 { media.insert(id) }
            }
            var mounts: UnsafeMutablePointer<statfs>?
            let count = Int(getmntinfo(&mounts, MNT_NOWAIT))
            let mountPoints = Set(
                UnsafeBufferPointer(start: mounts, count: max(count, 0)).map { entry in
                    String(nulTerminatedBytesOf: entry.f_mntonname)
                })
            return ExistingDisks(media: media, mountPoints: mountPoints)
        }

        /// True (once) when `disk` was present at the snapshot.
        mutating func claim(_ disk: DADisk) -> Bool {
            let media = DADiskCopyIOMedia(disk)
            if media != IO_OBJECT_NULL {
                defer { IOObjectRelease(media) }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS else { return false }
                return self.media.remove(id) != nil
            }
            let description = DADiskCopyDescription(disk) as? [CFString: Any] ?? [:]
            guard let path = (description[kDADiskDescriptionVolumePathKey] as? URL)?.path(percentEncoded: false)
            else { return false }
            // getmntinfo has no trailing slash; the URL path may.
            return mountPoints.remove(withoutTrailingSlash(path)) != nil
        }
    }

    /// A CoreFoundation session object, only used on `queue` after `start`.
    private struct SessionBox: @unchecked Sendable {
        let value: DASession
    }

    private static let appeared: DADiskAppearedCallback = { disk, context in
        guard let context else { return }
        let state = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        guard !state.existing.withLock({ $0.claim(disk) }) else { return }
        state.handle(disk)
    }

    private static let disappeared: DADiskDisappearedCallback = { disk, context in
        guard let context else { return }
        Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().handle(disk)
    }

    init(label: String, phase: Phase, handle: @escaping @Sendable (DADisk) -> Void) {
        self.phase = phase
        queue = DispatchQueue(label: "com.gkze.meerkat.\(label)", qos: .utility)
        context = Context(handle: handle, existing: ExistingDisks(media: [], mountPoints: []))
    }

    func start() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw EventError.sourceUnavailable("DASessionCreate failed")
        }
        // Disappearances are never replayed, so only appearances need it.
        if phase == .appeared {
            // Without it every disk already attached would be reported as
            // appearing.
            let existing = try ExistingDisks.snapshot()
            context.existing.withLock { $0 = existing }
        }
        // The callback's reference: released in `stop` after unregistering.
        let context = Unmanaged.passRetained(self.context).toOpaque()
        switch phase {
        case .appeared: DARegisterDiskAppearedCallback(session, nil, Self.appeared, context)
        case .disappeared: DARegisterDiskDisappearedCallback(session, nil, Self.disappeared, context)
        }
        self.session.withLock { $0 = SessionBox(value: session) }
        DASessionSetDispatchQueue(session, queue)
    }

    func stop() {
        guard let session = session.withLock({ $0.take() }) else { return }
        let context = Unmanaged.passUnretained(self.context)
        let phase = self.phase
        // On the queue: after any callback in flight, before the context goes.
        queue.async {
            let callback =
                switch phase {
                case .appeared: unsafeBitCast(Self.appeared, to: UnsafeMutableRawPointer.self)
                case .disappeared: unsafeBitCast(Self.disappeared, to: UnsafeMutableRawPointer.self)
                }
            DAUnregisterCallback(session.value, callback, context.toOpaque())
            DASessionSetDispatchQueue(session.value, nil)
            context.release()
        }
    }
}

// MARK: - volume.space

public struct VolumeSpacePayload: EventPayload, Equatable {
    /// The `VQ_*` conditions from <sys/mount.h>.
    public enum Condition: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case notResponding, needAuth, lowDisk, mount, unmount, dead, assist, notRespondingLock, update
        case veryLowDisk, serverEvent, quota, nearLowDisk, desiredDisk, freeSpaceChange
        case purgeableSpaceChange, idlePurgeNotify
    }

    public let conditions: [Condition]
    public let dataVolumeFreeBytes: UInt64?
    public let dataVolumeTotalBytes: UInt64?

    public static var schema: TypeSchema {
        .named(
            "VolumeSpace",
            ObjectSchema([
                .field(
                    "conditions", [Condition].self,
                    doc:
                        "Kernel volume conditions signalled since the last event, for any file system; empty when only bits this version does not name were set."
                ),
                .optional(
                    "dataVolumeFreeBytes", UInt64.self,
                    doc: "Bytes available to unprivileged users on /System/Volumes/Data; absent if statfs failed."),
                .optional(
                    "dataVolumeTotalBytes", UInt64.self, doc: "Size of /System/Volumes/Data; absent if statfs failed."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                conditions: [.freeSpaceChange], dataVolumeFreeBytes: 104_857_600_000,
                dataVolumeTotalBytes: 994_662_584_320),
            Self(conditions: [.lowDisk, .veryLowDisk], dataVolumeFreeBytes: nil, dataVolumeTotalBytes: nil),
        ]
    }

    static let bits: [(Int32, Condition)] = [
        (VQ_NOTRESP, .notResponding), (VQ_NEEDAUTH, .needAuth), (VQ_LOWDISK, .lowDisk), (VQ_MOUNT, .mount),
        (VQ_UNMOUNT, .unmount), (VQ_DEAD, .dead), (VQ_ASSIST, .assist), (VQ_NOTRESPLOCK, .notRespondingLock),
        (VQ_UPDATE, .update), (VQ_VERYLOWDISK, .veryLowDisk), (VQ_SERVEREVENT, .serverEvent), (VQ_QUOTA, .quota),
        (VQ_NEARLOWDISK, .nearLowDisk), (VQ_DESIRED_DISK, .desiredDisk), (VQ_FREE_SPACE_CHANGE, .freeSpaceChange),
        (VQ_PURGEABLE_SPACE_CHANGE, .purgeableSpaceChange), (VQ_IDLE_PURGE_NOTIFY, .idlePurgeNotify),
    ]

    static func from(fflags: UInt32) -> Self {
        var info = statfs()
        let measured = statfs("/System/Volumes/Data", &info) == 0
        return Self(
            conditions: bits.filter { fflags & UInt32(bitPattern: $0.0) != 0 }.map(\.1),
            dataVolumeFreeBytes: measured ? info.f_bavail * UInt64(info.f_bsize) : nil,
            dataVolumeTotalBytes: measured ? info.f_blocks * UInt64(info.f_bsize) : nil
        )
    }
}

public enum VolumeSpaceEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "volume.space",
        "The kernel signalled a volume condition: low, very low or near-low disk space, a significant free-space change, a mount, unmount or update, or an unresponsive network server. The kernel does not say which volume; the payload reports the data volume's free space. Conditions signalled before the event is read are merged into one event.",
        mechanism: .push, semantics: .occurrence, loss: .coalesced,
        observation: .open,
        source: "kqueue EVFILT_FS (VQ_* from <sys/mount.h>), statfs"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<VolumeSpacePayload>
    ) throws -> any EventSource {
        let queue = DispatchQueue(label: "com.gkze.meerkat.volume-space", qos: .utility)
        let holder = Mutex<DispatchSourceBox?>(nil)
        return ClosureSource(
            start: {
                let kq = kqueue()
                guard kq >= 0 else {
                    throw EventError.sourceUnavailable("kqueue failed: \(String(cString: strerror(errno)))")
                }
                // EVFILT_FS has one global knote list (ident 0). fflags 0 asks
                // for every condition; the kernel sets EV_CLEAR itself, so the
                // conditions accumulate until read.
                var change = kevent(
                    ident: 0, filter: Int16(EVFILT_FS), flags: UInt16(EV_ADD | EV_CLEAR),
                    fflags: 0, data: 0, udata: nil)
                guard kevent(kq, &change, 1, nil, 0, nil) == 0 else {
                    let message = String(cString: strerror(errno))
                    close(kq)
                    throw EventError.sourceUnavailable("kevent(EVFILT_FS) failed: \(message)")
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: kq, queue: queue)
                source.setEventHandler {
                    var event = kevent()
                    var poll = timespec()
                    while kevent(kq, nil, 0, &event, 1, &poll) > 0 {
                        emit(VolumeSpacePayload.from(fflags: event.fflags))
                    }
                }
                source.setCancelHandler { close(kq) }
                holder.withLock { $0 = DispatchSourceBox(value: source) }
                source.resume()
            },
            stop: {
                holder.withLock { box in
                    box?.value.cancel()
                    box = nil
                }
            })
    }
}
