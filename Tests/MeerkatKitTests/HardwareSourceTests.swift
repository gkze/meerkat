import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import Synchronization
import Testing

@testable import MeerkatKit

/// Live tests of the hardware event sources (power, USB, display, disk,
/// volume conditions) at the real OS boundary.
@Suite(.serialized)
struct HardwareSourceTests {
    let hub = EventHub(
        catalog: EventCatalog([
            AnyEventKind(PowerSourceEvent.self),
            AnyEventKind(USBAttachedEvent.self),
            AnyEventKind(USBDetachedEvent.self),
            AnyEventKind(DisplayReconfiguredEvent.self),
            AnyEventKind(DiskAppearedEvent.self),
            AnyEventKind(DiskDisappearedEvent.self),
            AnyEventKind(VolumeSpaceEvent.self),
        ]))

    // MARK: power.source

    @Test func powerSourceDeliversTheCurrentStateFirst() async throws {
        let subscription = HardwareEventRecorder(try hub.subscribe("power.source"))
        defer { subscription.cancel() }
        let event = try #require(await subscription.next(within: .seconds(5)))
        // The first value of a push `state` source is its current value.
        #expect(event.replayed)
        let kind = try #require(hub.catalog.kind(named: "power.source"))
        #expect(SchemaValidator.violations(of: event.payload, against: kind.payloadSchema).isEmpty)

        let payload = try event.payload.decode(as: PowerSourcePayload.self)
        #expect(payload.providing != .unknown)
        for battery in payload.batteries {
            #expect(!battery.name.isEmpty)
            if let percent = battery.currentCapacityPercent { #expect((0...100).contains(percent)) }
            // -1 means "still calculating" and must never be reported.
            #expect((battery.timeToEmptyMinutes ?? 0) >= 0)
            #expect((battery.timeToFullMinutes ?? 0) >= 0)
        }
        // The same reading taken directly agrees, unless the state changed
        // in between (then a second event follows).
        if PowerSnapshot.read() == payload {
            #expect(await subscription.next(within: .milliseconds(300)) == nil)
        }
    }

    @Test func batteryTimesFollowTheValidityRules() {
        let calculating = PowerSnapshot.battery(from: [
            kIOPSNameKey: "InternalBattery-0", kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 80,
            kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSTimeToEmptyKey: -1, kIOPSTimeToFullChargeKey: 30,
        ])
        #expect(calculating.currentCapacityPercent == 50)
        #expect(calculating.timeToEmptyMinutes == nil)
        // Time to full is only valid while charging.
        #expect(calculating.timeToFullMinutes == nil)
        #expect(calculating.powerSourceState == .battery)

        let charging = PowerSnapshot.battery(from: [
            kIOPSNameKey: "InternalBattery-0", kIOPSIsChargingKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSTimeToEmptyKey: 0, kIOPSTimeToFullChargeKey: 45,
        ])
        #expect(charging.timeToFullMinutes == 45)
        #expect(charging.timeToEmptyMinutes == nil)
        #expect(charging.currentCapacityPercent == nil)
        #expect(PowerSnapshot.providing("UPS Power") == .ups)
        #expect(PowerSnapshot.providing(nil) == .unknown)
    }

    // MARK: usb.*

    @Test func usbSourcesStartWithoutReportingConnectedDevices() async throws {
        let attached = HardwareEventRecorder(try hub.subscribe("usb.attached"))
        let detached = HardwareEventRecorder(try hub.subscribe("usb.detached"))
        // Devices already connected are drained at registration, not reported.
        #expect(await attached.next(within: .milliseconds(500)) == nil)
        #expect(await detached.next(within: .milliseconds(10)) == nil)
        attached.cancel()
        detached.cancel()
        #expect(hub.statistics().isEmpty)
    }

    /// Needs a USB device attached; skipped (not failed) without one.
    static var usbDeviceConnected: Bool {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"))
        defer { if device != IO_OBJECT_NULL { IOObjectRelease(device) } }
        return device != IO_OBJECT_NULL
    }

    @Test(.enabled(if: usbDeviceConnected, "no USB device is connected"))
    func usbPayloadReadsRegistryProperties() throws {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"))
        try #require(device != IO_OBJECT_NULL, "no USB device is connected")
        defer { IOObjectRelease(device) }
        let payload = USBDevicePayload.from(device)
        #expect(payload.registryEntryId != 0)
        #expect(payload.vendorId != nil)
        #expect(payload.locationId != nil)
        let schema = USBDevicePayload.schema
        #expect(SchemaValidator.violations(of: try JSONValue(encoding: payload), against: schema).isEmpty)
    }

    // MARK: display.reconfigured

    @Test func displaySourceStartsAndStops() async throws {
        let subscription = HardwareEventRecorder(try hub.subscribe("display.reconfigured"))
        #expect(await subscription.next(within: .milliseconds(200)) == nil)
        subscription.cancel()
        #expect(hub.statistics().isEmpty)
    }

    @Test func displayPayloadDescribesLiveAndRemovedDisplays() {
        let main = CGMainDisplayID()
        let live = DisplayReconfiguredPayload.from(display: main, flags: [.setModeFlag, .desktopShapeChangedFlag])
        #expect(live.changes == [.setMode, .desktopShapeChanged])
        #expect(live.isMain == true)
        #expect((live.width ?? 0) > 0 && (live.height ?? 0) > 0)

        let removed = DisplayReconfiguredPayload.from(display: 9_999, flags: [.removeFlag])
        #expect(
            removed
                == DisplayReconfiguredPayload(
                    displayId: 9_999, changes: [.removed], isMain: nil,
                    isBuiltin: nil, width: nil, height: nil))
    }

    // MARK: disk.*

    @Test func diskImageAttachAndDetachAreReported() async throws {
        try await DiskImageGate.shared.run { try await self.diskImageAttachAndDetachAreReportedBody() }
    }

    private func diskImageAttachAndDetachAreReportedBody() async throws {
        let present = hardwareBSDNames()
        #expect(!present.isEmpty)
        let appeared = HardwareEventRecorder(try hub.subscribe("disk.appeared"))
        let disappeared = HardwareEventRecorder(try hub.subscribe("disk.disappeared"))
        defer {
            appeared.cancel()
            disappeared.cancel()
        }
        // Disks present at registration are not reported. (Disks other
        // processes attach meanwhile legitimately are.)
        #expect(
            await appeared.next(within: .seconds(1)) { event in
                (try? event.payload.decode(as: DiskPayload.self).bsdName).flatMap { $0 }.map(present.contains) ?? false
            } == nil)

        let image = try HardwareDiskImage()
        defer { image.remove() }
        let devices = try image.attach(mount: false)
        #expect(!devices.isEmpty)
        let shown = try #require(
            await appeared.next(within: .seconds(10)) { event in
                (try? event.payload.decode(as: DiskPayload.self).bsdName).flatMap { $0 }.map(devices.contains) ?? false
            })
        let disk = try shown.payload.decode(as: DiskPayload.self)
        #expect((disk.mediaSizeBytes ?? 0) > 0)
        #expect(disk.ejectable == true)

        try image.detach()
        let gone = try #require(
            await disappeared.next(within: .seconds(10)) { event in
                (try? event.payload.decode(as: DiskPayload.self).bsdName).flatMap { $0 }.map(devices.contains) ?? false
            })
        let kind = try #require(hub.catalog.kind(named: "disk.disappeared"))
        #expect(SchemaValidator.violations(of: gone.payload, against: kind.payloadSchema).isEmpty)
    }

    /// disk.sample's totals leave disk images out; this checks the registry
    /// signal that decides it on a real attached image.
    @Test func attachedDiskImageIsVirtual() async throws {
        try await DiskImageGate.shared.run { try self.attachedDiskImageIsVirtualBody() }
    }

    private func attachedDiskImageIsVirtualBody() throws {
        let image = try HardwareDiskImage()
        defer { image.remove() }
        let devices = try image.attach(mount: false)
        let disks = try DiskCounters.read().values.filter { devices.contains($0.bsdName) }
        #expect(!disks.isEmpty)
        #expect(disks.allSatisfy { $0.isVirtual })
    }

    // MARK: volume.space

    @Test func volumeConditionsReportMountAndUnmount() async throws {
        try await DiskImageGate.shared.run { try await self.volumeConditionsReportMountAndUnmountBody() }
    }

    private func volumeConditionsReportMountAndUnmountBody() async throws {
        let subscription = HardwareEventRecorder(try hub.subscribe("volume.space"))
        defer { subscription.cancel() }

        let image = try HardwareDiskImage()
        defer { image.remove() }
        _ = try image.attach(mount: true)
        let mounted = try #require(
            await subscription.next(within: .seconds(10)) { event in
                (try? event.payload.decode(as: VolumeSpacePayload.self).conditions.contains(.mount)) ?? false
            })
        let payload = try mounted.payload.decode(as: VolumeSpacePayload.self)
        #expect((payload.dataVolumeTotalBytes ?? 0) > 0)
        #expect((payload.dataVolumeFreeBytes ?? .max) <= (payload.dataVolumeTotalBytes ?? 0))

        try image.detach()
        #expect(
            await subscription.next(within: .seconds(10)) { event in
                (try? event.payload.decode(as: VolumeSpacePayload.self).conditions.contains(.unmount)) ?? false
            } != nil)
    }

    @Test func volumeConditionBitsMapToNames() {
        let payload = VolumeSpacePayload.from(fflags: UInt32(VQ_LOWDISK | VQ_FREE_SPACE_CHANGE | 0x40000))
        #expect(payload.conditions == [.lowDisk, .freeSpaceChange])
    }
}

/// BSD names of every IOMedia object now, read independently of
/// DiskArbitration.
func hardwareBSDNames() -> Set<String> {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var names = Set<String>()
    var media = IOIteratorNext(iterator)
    while media != IO_OBJECT_NULL {
        if let name = IORegistryEntryCreateCFProperty(media, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        {
            names.insert(name)
        }
        IOObjectRelease(media)
        media = IOIteratorNext(iterator)
    }
    return names
}

/// Collects a subscription's events from one long-lived consumer, so tests
/// can wait with a timeout without cancelling the stream's iteration (which
/// would finish the subscription).
final class HardwareEventRecorder: Sendable {
    let subscription: EventSubscription
    private let state = Mutex<(events: [EventEnvelope], consumed: Int)>(([], 0))

    init(_ subscription: EventSubscription) {
        self.subscription = subscription
        // Holds the recorder until the subscription finishes.
        Task {
            for await event in subscription.events { self.state.withLock { $0.events.append(event) } }
        }
    }

    /// The next not-yet-returned event matching `matches` within `timeout`,
    /// or nil. Events skipped over while searching are consumed.
    func next(
        within timeout: Duration,
        where matches: (EventEnvelope) -> Bool = { _ in true }
    ) async -> EventEnvelope? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let found = state.withLock { state -> EventEnvelope? in
                while state.consumed < state.events.count {
                    let event = state.events[state.consumed]
                    state.consumed += 1
                    if matches(event) { return event }
                }
                return nil
            }
            if let found { return found }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func cancel() { subscription.cancel() }
}

/// A 1 MB APFS disk image in a private temporary directory, attached and
/// detached with `hdiutil` (unprivileged for the user's own images).
final class HardwareDiskImage: Sendable {
    let directory: URL
    let path: String
    private let attached = Mutex<String?>(nil)

    init() throws {
        directory = temporaryURL("meerkat-hw")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appending(path: "probe.dmg").path(percentEncoded: false)
        _ = try Self.hdiutil(["create", "-size", "1m", "-fs", "APFS", "-volname", "MeerkatHW", path])
    }

    /// Attaches the image and returns the BSD names of every disk it created.
    func attach(mount: Bool) throws -> Set<String> {
        var arguments = ["attach", "-plist", "-nobrowse", path]
        if mount {
            arguments += ["-mountroot", directory.path(percentEncoded: false)]
        } else {
            arguments.append("-nomount")
        }
        let output = try Self.hdiutil(arguments)
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entries = plist?["system-entities"] as? [[String: Any]] ?? []
        let names = entries.compactMap { ($0["dev-entry"] as? String)?.replacingOccurrences(of: "/dev/", with: "") }
        // The first entry is the whole disk; detaching it detaches the rest.
        attached.withLock { $0 = names.first }
        return Set(names)
    }

    func detach() throws {
        guard let whole = attached.withLock({ $0.take() }) else { return }
        _ = try Self.hdiutil(["detach", whole, "-force"])
    }

    func remove() {
        try? detach()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EventError.sourceUnavailable("hdiutil \(arguments.first ?? "") exited \(process.terminationStatus)")
        }
        return output
    }
}
