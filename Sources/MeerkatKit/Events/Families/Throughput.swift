import Darwin
import Foundation
import IOKit
import Synchronization

// System-wide I/O rates from cumulative kernel counters: the first tick takes
// a baseline, every later tick reports the change since the previous one.

/// Holds the previous counters of a rate sampler and turns each new reading
/// into per-second rates over the elapsed time.
final class CounterBaseline<Counters: Sendable>: Sendable {
    private let previous = Mutex<(counters: Counters, at: ContinuousClock.Instant)?>(nil)

    /// Returns the previous reading and the seconds since it, and stores
    /// `counters` as the next baseline. Nil on the first call.
    func advance(to counters: Counters) -> (previous: Counters, seconds: Double)? {
        let now = ContinuousClock.now
        return previous.withLock { previous in
            defer { previous = (counters, now) }
            guard let last = previous else { return nil }
            let elapsed = now - last.at
            let seconds = elapsed / .seconds(1)
            return seconds > 0 ? (last.counters, seconds) : nil
        }
    }
}

/// `new - old` for counters that only grow; a counter that went backwards
/// (a device that reset) reports nothing rather than a huge rate.
private func delta(_ new: UInt64, _ old: UInt64) -> UInt64? {
    new >= old ? new - old : nil
}

// MARK: - disk.sample

public struct DiskRate: Codable, Sendable, Equatable, SchemaDescribed {
    public let bsdName: String
    /// A disk image or other virtual device. Its I/O also reaches the disk
    /// that holds its backing store, so totals leave it out.
    public let isVirtual: Bool
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public let readsPerSecond: Double
    public let writesPerSecond: Double
    public let readLatencyMs: Double?
    public let writeLatencyMs: Double?
    public let errors: Int

    public static var schema: TypeSchema {
        .named(
            "DiskRate",
            ObjectSchema([
                .field("bsdName", String.self, doc: "Whole-disk BSD name, such as disk0."),
                .field(
                    "isVirtual", Bool.self,
                    doc:
                        "A disk image or other virtual device, whose I/O also reaches the disk holding its backing store."
                ),
                .field("readBytesPerSecond", Double.self),
                .field("writeBytesPerSecond", Double.self),
                .field("readsPerSecond", Double.self, doc: "Read operations per second."),
                .field("writesPerSecond", Double.self, doc: "Write operations per second."),
                .optional(
                    "readLatencyMs", Double.self, doc: "Mean time per read over the interval; absent with no reads."),
                .optional(
                    "writeLatencyMs", Double.self, doc: "Mean time per write over the interval; absent with no writes."),
                .field("errors", Int.self, doc: "Read and write errors during the interval."),
            ]))
    }
}

public struct DiskSamplePayload: EventPayload, Equatable {
    /// Ordered by BSD name.
    public let disks: [DiskRate]
    /// Sums over the disks that are not virtual: what the machine's storage
    /// actually moved, without counting a disk image's I/O twice.
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public init(disks: [DiskRate]) {
        self.disks = disks
        let physical = disks.filter { !$0.isVirtual }
        readBytesPerSecond = physical.reduce(0) { $0 + $1.readBytesPerSecond }
        writeBytesPerSecond = physical.reduce(0) { $0 + $1.writeBytesPerSecond }
    }

    public static var schema: TypeSchema {
        .named(
            "DiskSample",
            ObjectSchema([
                .field(
                    "disks", [DiskRate].self,
                    doc:
                        "Every physical or virtual disk present for the whole interval, ordered by BSD name; disk images and APFS volumes' backing disks included."
                ),
                .field(
                    "readBytesPerSecond", Double.self,
                    doc: "Sum over disks that are not virtual (a disk image's I/O also crosses the disk holding it)."
                ),
                .field("writeBytesPerSecond", Double.self, doc: "Same sum for written bytes."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(disks: [
                DiskRate(
                    bsdName: "disk0", isVirtual: false, readBytesPerSecond: 1_048_576,
                    writeBytesPerSecond: 524_288, readsPerSecond: 64, writesPerSecond: 32, readLatencyMs: 0.16,
                    writeLatencyMs: 0.03, errors: 0),
                DiskRate(
                    bsdName: "disk4", isVirtual: true, readBytesPerSecond: 65_536, writeBytesPerSecond: 0,
                    readsPerSecond: 4, writesPerSecond: 0, readLatencyMs: 0.4, writeLatencyMs: nil, errors: 0),
            ]),
            Self(disks: []),
        ]
    }
}

/// Cumulative counters of one block storage driver.
struct DiskCounters: Sendable, Equatable {
    var bsdName: String
    var isVirtual: Bool
    var bytesRead: UInt64, bytesWritten: UInt64
    var reads: UInt64, writes: UInt64
    /// Nanoseconds spent on reads and writes.
    var readTime: UInt64, writeTime: UInt64
    var errors: UInt64

    /// Keyed by the driver's registry entry id, so a disk ejected and another
    /// attached under the same BSD name are never subtracted from each other.
    static func read() throws -> [UInt64: DiskCounters] {
        var result: [UInt64: DiskCounters] = [:]
        try IORegistry.forEachService(matching: "IOBlockStorageDriver") { driver in
            guard let statistics = IORegistry.property(driver, "Statistics") as? [String: NSNumber],
                let name = bsdName(below: driver)
            else { return }
            func value(_ key: String) -> UInt64 { statistics[key]?.uint64Value ?? 0 }
            result[IORegistry.entryID(driver)] = DiskCounters(
                bsdName: name, isVirtual: isVirtual(above: driver),
                bytesRead: value("Bytes (Read)"), bytesWritten: value("Bytes (Write)"),
                reads: value("Operations (Read)"), writes: value("Operations (Write)"),
                readTime: value("Total Time (Read)"), writeTime: value("Total Time (Write)"),
                errors: value("Errors (Read)") + value("Errors (Write)")
            )
        }
        return result
    }

    /// The whole-disk IOMedia the driver publishes, its direct child.
    private static func bsdName(below driver: io_registry_entry_t) -> String? {
        var child: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &child) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(child) }
        return IORegistry.property(child, "BSD Name") as? String
    }

    /// Disk image devices (`AppleDiskImageDevice`, the in-kernel image
    /// driver) describe their interconnect as "Virtual Interface"; real
    /// controllers name a bus (Apple Fabric, PCI-Express, USB, ...). The
    /// device is the driver's provider.
    private static func isVirtual(above driver: io_registry_entry_t) -> Bool {
        var device: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(device) }
        let characteristics = IORegistry.property(device, "Protocol Characteristics") as? [String: Any]
        return characteristics?["Physical Interconnect"] as? String == "Virtual Interface"
    }

    static func rates(from old: [UInt64: DiskCounters], to new: [UInt64: DiskCounters], seconds: Double) -> [DiskRate] {
        new.compactMap { id, now -> DiskRate? in
            guard let then = old[id],
                let read = delta(now.bytesRead, then.bytesRead),
                let written = delta(now.bytesWritten, then.bytesWritten),
                let reads = delta(now.reads, then.reads), let writes = delta(now.writes, then.writes)
            else { return nil }
            func latency(_ time: UInt64?, _ operations: UInt64) -> Double? {
                guard let time, operations > 0 else { return nil }
                return Double(time) / Double(operations) / 1_000_000
            }
            return DiskRate(
                bsdName: now.bsdName, isVirtual: now.isVirtual,
                readBytesPerSecond: Double(read) / seconds, writeBytesPerSecond: Double(written) / seconds,
                readsPerSecond: Double(reads) / seconds, writesPerSecond: Double(writes) / seconds,
                readLatencyMs: latency(delta(now.readTime, then.readTime), reads),
                writeLatencyMs: latency(delta(now.writeTime, then.writeTime), writes),
                errors: Int(delta(now.errors, then.errors) ?? 0)
            )
        }
        .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }
}

public enum DiskSampleEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 1.0
    public static let intervalRange = 0.25...3600.0

    public static let descriptor = EventDescriptor(
        "disk.sample",
        "Read and write throughput, operation rates and mean latency of every disk over the last interval. The first sample arrives one interval after subscribing. Per-process disk I/O is in process.top.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .open,
        source: "IOBlockStorageDriver \"Statistics\" registry property"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<DiskSampleEvent>, environment: SourceEnvironment,
        emit: Emitter<DiskSamplePayload>
    ) throws -> any EventSource {
        let baseline = CounterBaseline<[UInt64: DiskCounters]>()
        _ = baseline.advance(to: try DiskCounters.read())
        return PollingSource(
            label: "disk-sample", interval: parameters.interval, fireImmediately: false, failingThrough: emit
        ) {
            // A failed read keeps the last baseline, so the next sample
            // covers the skipped interval.
            let now = try DiskCounters.read()
            guard let (old, seconds) = baseline.advance(to: now) else { return }
            emit(DiskSamplePayload(disks: DiskCounters.rates(from: old, to: now, seconds: seconds)))
        }
    }
}

// MARK: - network.sample

public struct InterfaceRate: Codable, Sendable, Equatable, SchemaDescribed {
    public let name: String
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double
    public let receivedPacketsPerSecond: Double
    public let sentPacketsPerSecond: Double
    public let errors: Int

    public static var schema: TypeSchema {
        .named(
            "InterfaceRate",
            ObjectSchema([
                .field("name", String.self, doc: "BSD interface name, such as en0 or utun4."),
                .field("receivedBytesPerSecond", Double.self),
                .field("sentBytesPerSecond", Double.self),
                .field("receivedPacketsPerSecond", Double.self),
                .field("sentPacketsPerSecond", Double.self),
                .field("errors", Int.self, doc: "Input and output errors during the interval."),
            ]))
    }
}

public struct NetworkSamplePayload: EventPayload, Equatable {
    public let interfaces: [InterfaceRate]
    public let receivedBytesPerSecond: Double
    public let sentBytesPerSecond: Double

    public static var schema: TypeSchema {
        .named(
            "NetworkSample",
            ObjectSchema([
                .field(
                    "interfaces", [InterfaceRate].self,
                    doc: "Interfaces that carried traffic during the interval, ordered by name; idle ones are left out."
                ),
                .field(
                    "receivedBytesPerSecond", Double.self,
                    doc:
                        "Sum over physical interfaces (not loopback or tunnels, whose traffic also crosses a physical one)."
                ),
                .field("sentBytesPerSecond", Double.self, doc: "Same sum for sent bytes."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                interfaces: [
                    InterfaceRate(
                        name: "en0", receivedBytesPerSecond: 250_000, sentBytesPerSecond: 12_000,
                        receivedPacketsPerSecond: 180, sentPacketsPerSecond: 90, errors: 0)
                ],
                receivedBytesPerSecond: 250_000, sentBytesPerSecond: 12_000),
            Self(interfaces: [], receivedBytesPerSecond: 0, sentBytesPerSecond: 0),
        ]
    }
}

/// Cumulative 64-bit counters of one interface.
struct InterfaceCounters: Sendable, Equatable {
    var name: String
    /// IFT_* from <net/if_types.h>.
    var type: UInt8
    var receivedBytes: UInt64, sentBytes: UInt64
    var receivedPackets: UInt64, sentPackets: UInt64
    var errors: UInt64

    /// Loopback and tunnel traffic is counted again on the physical
    /// interface that carries it, so totals leave it out.
    var countsTowardTotal: Bool {
        // IFT_LOOP 0x18, IFT_GIF 0x37, IFT_STF 0x39, IFT_OTHER 0x01 (utun, ipsec).
        ![0x18, 0x37, 0x39, 0x01].contains(type)
    }

    /// `NET_RT_IFLIST2` rather than `getifaddrs`: the latter's `if_data`
    /// counters are 32-bit and wrap every 4 GB. Keyed by interface index.
    /// Throws when the table can't be read, which is not a machine without
    /// traffic.
    static func read() throws -> [UInt32: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { throw readFailure("size") }
        guard size > 0 else { return [:] }
        // The table can grow between the two calls; by more than this
        // (ENOMEM), and the tick is skipped.
        size += size / 8
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { throw readFailure("table") }

        var result: [UInt32: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                defer { offset += Int(header.ifm_msglen) }
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                    offset + MemoryLayout<if_msghdr2>.size <= size
                else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let end = min(offset + Int(header.ifm_msglen), size)
                guard
                    let name = linkName(raw, after: offset, end: end, addresses: message.ifm_addrs)
                        ?? indexName(message.ifm_index)
                else { continue }
                let data = message.ifm_data
                result[UInt32(message.ifm_index)] = InterfaceCounters(
                    name: name, type: data.ifi_type,
                    receivedBytes: data.ifi_ibytes, sentBytes: data.ifi_obytes,
                    receivedPackets: data.ifi_ipackets, sentPackets: data.ifi_opackets,
                    errors: data.ifi_ierrors + data.ifi_oerrors
                )
            }
        }
        return result
    }

    /// The interface's name from the link-level address the kernel appends to
    /// an `RTM_IFINFO2` message (`RTA_IFP`). `if_indextoname` reads the whole
    /// interface table on each call, so naming every interface that way made
    /// one sample cost one table read per interface: most of `network.sample`'s
    /// cost at 1 s (2026-10-29). Nil when the message carries no such address
    /// first, or a malformed one.
    static func linkName(_ raw: UnsafeRawBufferPointer, after offset: Int, end: Int, addresses: Int32) -> String? {
        // Addresses follow in bit order: with no lower bit set, RTA_IFP is first.
        guard addresses & RTA_IFP != 0, addresses & (RTA_IFP - 1) == 0 else { return nil }
        let start = offset + MemoryLayout<if_msghdr2>.size
        guard let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data),
            start + dataOffset <= end,
            // The fixed-size struct may reach past a short last message.
            start + MemoryLayout<sockaddr_dl>.size <= raw.count
        else { return nil }
        let address = raw.loadUnaligned(fromByteOffset: start, as: sockaddr_dl.self)
        let length = Int(address.sdl_nlen)
        guard Int32(address.sdl_family) == AF_LINK, length > 0, start + dataOffset + length <= end else { return nil }
        return String(decoding: raw[(start + dataOffset)..<(start + dataOffset + length)], as: UTF8.self)
    }

    private static func readFailure(_ what: String) -> EventError {
        .sourceUnavailable("sysctl(NET_RT_IFLIST2) \(what): \(String(cString: strerror(errno)))")
    }

    private static func indexName(_ index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return if_indextoname(UInt32(index), &name) != nil ? String(nulTerminated: name) : nil
    }

    static func sample(
        from old: [UInt32: InterfaceCounters], to new: [UInt32: InterfaceCounters],
        seconds: Double
    ) -> NetworkSamplePayload {
        var received = 0.0
        var sent = 0.0
        let interfaces = new.compactMap { index, now -> InterfaceRate? in
            // Same index and name: an index reused by a new interface is not
            // subtracted from the old one's counters.
            guard let then = old[index], then.name == now.name,
                let inBytes = delta(now.receivedBytes, then.receivedBytes),
                let outBytes = delta(now.sentBytes, then.sentBytes),
                let inPackets = delta(now.receivedPackets, then.receivedPackets),
                let outPackets = delta(now.sentPackets, then.sentPackets),
                inPackets + outPackets > 0
            else { return nil }
            if now.countsTowardTotal {
                received += Double(inBytes) / seconds
                sent += Double(outBytes) / seconds
            }
            return InterfaceRate(
                name: now.name,
                receivedBytesPerSecond: Double(inBytes) / seconds, sentBytesPerSecond: Double(outBytes) / seconds,
                receivedPacketsPerSecond: Double(inPackets) / seconds,
                sentPacketsPerSecond: Double(outPackets) / seconds,
                errors: Int(delta(now.errors, then.errors) ?? 0))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return NetworkSamplePayload(interfaces: interfaces, receivedBytesPerSecond: received, sentBytesPerSecond: sent)
    }
}

public enum NetworkSampleEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 1.0
    public static let intervalRange = 0.25...3600.0

    public static let descriptor = EventDescriptor(
        "network.sample",
        "Bytes and packets per second on each network interface over the last interval, with totals over physical interfaces. The first sample arrives one interval after subscribing. Which processes or hosts the traffic belongs to is not reported.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .open,
        source: "sysctl NET_RT_IFLIST2 (if_data64)"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<NetworkSampleEvent>, environment: SourceEnvironment,
        emit: Emitter<NetworkSamplePayload>
    ) throws -> any EventSource {
        let baseline = CounterBaseline<[UInt32: InterfaceCounters]>()
        _ = baseline.advance(to: try InterfaceCounters.read())
        return PollingSource(
            label: "network-sample", interval: parameters.interval, fireImmediately: false, failingThrough: emit
        ) {
            // As disk.sample: a failed read keeps the last baseline.
            let now = try InterfaceCounters.read()
            guard let (old, seconds) = baseline.advance(to: now) else { return }
            emit(InterfaceCounters.sample(from: old, to: now, seconds: seconds))
        }
    }
}
