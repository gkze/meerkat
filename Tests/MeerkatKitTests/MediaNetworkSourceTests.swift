import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import MeerkatKit

// Live tests of the audio, camera and network sources against the real OS.
// None of them needs a privacy grant: device and process properties are
// read, never captured. The only triggered changes use a private aggregate
// audio device, which only this process can see, playing silence.

private let mediaNetworkKinds = [
    AnyEventKind(AudioDevicesEvent.self),
    AnyEventKind(AudioDefaultDeviceEvent.self),
    AnyEventKind(AudioInUseEvent.self),
    AnyEventKind(CameraInUseEvent.self),
    AnyEventKind(NetworkPathEvent.self),
    AnyEventKind(NetworkConfigurationEvent.self),
]

private func mediaNetworkHub() -> EventHub {
    EventHub(catalog: EventCatalog(mediaNetworkKinds))
}

/// Subscribes, takes the initial state, checks it against the schema and
/// decodes it.
private func mediaNetworkInitial<Payload: EventPayload>(
    _ kind: String, as type: Payload.Type, hub: EventHub
) async throws -> (EventSubscription, Payload) {
    let subscription = try hub.subscribe(kind)
    let envelope = try #require(await nextEvent(subscription), "\(kind): no initial state")
    // The first value of a push `state` source is its current value.
    #expect(envelope.replayed)
    let schema = try #require(hub.catalog.kind(named: kind)).payloadSchema
    #expect(SchemaValidator.violations(of: envelope.payload, against: schema).isEmpty)
    return (subscription, try envelope.payload.decode(as: Payload.self))
}

private func mediaNetworkDecode<Payload: Decodable>(_ envelope: EventEnvelope, as type: Payload.Type) -> Payload? {
    try? envelope.payload.decode(as: Payload.self)
}

/// Serialized: the private aggregate device appears in `audio.devices` and
/// the default-device properties for as long as a test holds it.
@Suite(.serialized)
struct MediaNetworkSourceTests {
    // MARK: Initial state

    @Test func audioDevicesListsAnOutputDevice() async throws {
        let hub = mediaNetworkHub()
        let (subscription, state) = try await mediaNetworkInitial(
            "audio.devices", as: AudioDevicesPayload.self, hub: hub)
        defer { subscription.cancel() }
        #expect(state.devices.contains { $0.outputChannels > 0 })
        #expect(state.devices.map(\.id) == state.devices.map(\.id).sorted())
        #expect(Set(state.devices.map(\.id)).count == state.devices.count)
        #expect(state.devices.allSatisfy { $0.uid != nil && $0.name != nil && $0.transport != nil })
    }

    @Test func audioDefaultDeviceHasAnOutputThatIsListed() async throws {
        let hub = mediaNetworkHub()
        let (subscription, defaults) = try await mediaNetworkInitial(
            "audio.defaultDevice", as: AudioDefaultDevicePayload.self, hub: hub)
        defer { subscription.cancel() }
        let output = try #require(defaults.output)
        #expect(output.outputChannels > 0)
        #expect(try #require(defaults.systemOutput).outputChannels > 0)
        if let input = defaults.input { #expect(input.inputChannels > 0) }

        let (devicesSubscription, devices) = try await mediaNetworkInitial(
            "audio.devices", as: AudioDevicesPayload.self, hub: hub)
        defer { devicesSubscription.cancel() }
        #expect(devices.devices.contains(output))
    }

    @Test func audioInUseEntriesMatchDeviceDirections() async throws {
        let hub = mediaNetworkHub()
        let (subscription, state) = try await mediaNetworkInitial("audio.inUse", as: AudioInUsePayload.self, hub: hub)
        defer { subscription.cancel() }
        for entry in state.running {
            #expect(
                (entry.direction == .input ? entry.device.inputChannels : entry.device.outputChannels) > 0, "\(entry)")
        }
    }

    @Test func cameraInUseCountsDevices() async throws {
        let hub = mediaNetworkHub()
        let (subscription, state) = try await mediaNetworkInitial("camera.inUse", as: CameraInUsePayload.self, hub: hub)
        defer { subscription.cancel() }
        #expect(state.devices >= state.running.count)
        #expect(Set(state.running.map(\.id)).count == state.running.count)
    }

    @Test func networkPathIsSatisfiedOnThisConnectedMachine() async throws {
        let hub = mediaNetworkHub()
        let (subscription, path) = try await mediaNetworkInitial("network.path", as: NetworkPathPayload.self, hub: hub)
        defer { subscription.cancel() }
        #expect(path.status == .satisfied)
        #expect(!path.interfaces.isEmpty)
        #expect(path.supportsDNS)
        #expect(path.supportsIPv4 || path.supportsIPv6)
        #expect(Set(path.interfaces.map(\.name)).count == path.interfaces.count)
    }

    @Test func networkConfigurationHasAPrimaryInterfaceOnThePath() async throws {
        let hub = mediaNetworkHub()
        let (subscription, configuration) = try await mediaNetworkInitial(
            "network.configuration", as: NetworkConfigurationPayload.self, hub: hub)
        defer { subscription.cancel() }
        let primary = try #require(configuration.primaryInterface)
        #expect(configuration.primaryService != nil)
        #expect(configuration.ipv4Addresses.contains(.init(interface: "lo0", address: "127.0.0.1")))
        #expect(!configuration.dnsServers.isEmpty)
        if configuration.ipv4Addresses.contains(where: { $0.interface == primary }) == false {
            Issue.record("primary interface \(primary) has no IPv4 address: \(configuration.ipv4Addresses)")
        }

        let (pathSubscription, path) = try await mediaNetworkInitial(
            "network.path", as: NetworkPathPayload.self, hub: hub)
        defer { pathSubscription.cancel() }
        #expect(path.interfaces.map(\.name).contains(primary))
    }

    // MARK: Changes at the OS boundary

    /// Creating and destroying a private aggregate device changes the device
    /// list; the source must report both.
    @Test func audioDevicesReportsAnAggregateDeviceAppearingAndGoing() async throws {
        let hub = mediaNetworkHub()
        let (subscription, initial) = try await mediaNetworkInitial(
            "audio.devices", as: AudioDevicesPayload.self, hub: hub)
        defer { subscription.cancel() }
        let aggregate = try MediaNetworkAggregateDevice()
        #expect(!initial.devices.contains { $0.uid == aggregate.uid })

        let uid = aggregate.uid
        let appeared = await nextEvent(subscription) { envelope in
            mediaNetworkDecode(envelope, as: AudioDevicesPayload.self)?.devices.contains { $0.uid == uid } == true
        }
        let device = try #require(
            appeared.flatMap { mediaNetworkDecode($0, as: AudioDevicesPayload.self) }?
                .devices.first { $0.uid == uid })
        #expect(device.transport == .aggregate)
        #expect(device.outputChannels > 0)

        aggregate.destroy()
        let gone = await nextEvent(subscription) { envelope in
            mediaNetworkDecode(envelope, as: AudioDevicesPayload.self)?.devices.contains { $0.uid == uid } == false
        }
        #expect(gone != nil)
    }

    /// Playing silence through a private aggregate device runs its physical
    /// output for this process. CoreAudio attributes the I/O to that
    /// sub-device, not to the aggregate, so the default output must be listed
    /// as running output while it plays and the aggregate never. Other
    /// processes may keep the output running, so the start and stop events
    /// are only expected when it was idle beforehand.
    @Test func audioInUseReportsThisProcessPlaying() async throws {
        let hub = mediaNetworkHub()
        let (subscription, initial) = try await mediaNetworkInitial("audio.inUse", as: AudioInUsePayload.self, hub: hub)
        defer { subscription.cancel() }
        let aggregate = try MediaNetworkAggregateDevice()
        defer { aggregate.destroy() }
        let output = aggregate.subDevice
        @Sendable func playing(_ state: AudioInUsePayload?) -> Bool {
            state?.running.contains { $0.device.id == output && $0.direction == .output } == true
        }
        let wasIdle = !playing(initial)

        try aggregate.startSilentOutput()
        var snapshot = AudioInUseEvent.read()
        let deadline = ContinuousClock.now + .seconds(5)
        while !playing(snapshot.payload), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            snapshot = AudioInUseEvent.read()
        }
        #expect(playing(snapshot.payload))
        #expect(snapshot.payload?.running.contains { $0.device.uid == aggregate.uid } == false)
        // The source listens to this process's own output state.
        let me = try #require(mediaNetworkProcessObject(getpid()))
        #expect(snapshot.listen.contains(CoreAudioProperties.key(me, kAudioProcessPropertyIsRunningOutput)))

        if wasIdle {
            #expect(
                await nextEvent(subscription) {
                    playing(mediaNetworkDecode($0, as: AudioInUsePayload.self))
                } != nil)
        }
        aggregate.stopOutput()
        if wasIdle {
            #expect(
                await nextEvent(subscription) {
                    !playing(mediaNetworkDecode($0, as: AudioInUsePayload.self))
                } != nil)
        } else {
            print("audio.inUse: default output was already running for another process; start/stop events not checked")
        }
    }

    // MARK: Lifecycle

    /// Start and stop, with and without waiting for the initial state: start
    /// does not throw, nothing is emitted after stop, and a stopped source is
    /// not kept alive by an OS registration.
    @Test(arguments: mediaNetworkKinds.map(\.name), [false, true])
    func startsAndStopsCleanly(_ name: String, waitForInitial: Bool) async throws {
        let kind = try #require(mediaNetworkKinds.first { $0.name == name })
        let received = Atomic<Int>(0)
        weak var weakSource: (any EventSource)?
        do {
            let source = try kind.makeSource(kind.normalized(.object([:])), environment: SourceEnvironment()) {
                emission in
                guard case .event = emission else { return }
                received.add(1, ordering: .relaxed)
            }
            weakSource = source
            try source.start()
            if waitForInitial {
                let deadline = ContinuousClock.now + .seconds(10)
                while received.load(ordering: .relaxed) == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(received.load(ordering: .relaxed) == 1, "\(name): no initial state")
            }
            source.stop()
        }
        let afterStop = received.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.load(ordering: .relaxed) == afterStop, "\(name): emitted after stop")
        #expect(weakSource == nil, "\(name): source still alive after stop")
    }

    @Test func hubStopsEverySourceWhenSubscribersLeave() async throws {
        let hub = mediaNetworkHub()
        for kind in mediaNetworkKinds {
            let subscription = try hub.subscribe(kind.name)
            #expect(await nextEvent(subscription) != nil, "\(kind.name)")
            subscription.cancel()
        }
        #expect(hub.statistics().isEmpty)
    }
}

/// CoreAudio's process object for `pid`, if it has one.
private func mediaNetworkProcessObject(_ pid: pid_t) -> AudioObjectID? {
    var address = CoreAudioProperties.address(
        CoreAudioProperties.key(CoreAudioProperties.system, kAudioHardwarePropertyTranslatePIDToProcessObject))
    var pid = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        CoreAudioProperties.system, &address,
        UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? object : nil
}

/// A private aggregate device over the default output device: visible only to
/// this process, removed by `destroy` (or when the process exits).
private final class MediaNetworkAggregateDevice: Sendable {
    let uid = "com.gkze.meerkat.tests.\(UUID().uuidString)"
    let id: AudioObjectID
    /// The default output device the aggregate drives.
    let subDevice: AudioObjectID
    private let queue = DispatchQueue(label: "com.gkze.meerkat.tests.aggregate-io")
    private let io = Mutex<(proc: AudioDeviceIOProcID?, destroyed: Bool)>((nil, false))

    init() throws {
        let output = try #require(
            CoreAudioProperties.uint32(CoreAudioProperties.system, kAudioHardwarePropertyDefaultOutputDevice))
        let outputUID = try #require(CoreAudioProperties.string(output, kAudioDevicePropertyDeviceUID))
        subDevice = output
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "Meerkat test aggregate",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        ]
        var id: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        try #require(status == noErr, "AudioHardwareCreateAggregateDevice: \(status)")
        self.id = id
    }

    func startSilentOutput() throws {
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, id, queue) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        try #require(status == noErr, "AudioDeviceCreateIOProcIDWithBlock: \(status)")
        io.withLock { $0.proc = proc }
        status = AudioDeviceStart(id, proc)
        try #require(status == noErr, "AudioDeviceStart: \(status)")
    }

    func stopOutput() {
        guard
            let proc = io.withLock({ state -> AudioDeviceIOProcID? in
                defer { state.proc = nil }
                return state.proc
            })
        else { return }
        AudioDeviceStop(id, proc)
        AudioDeviceDestroyIOProcID(id, proc)
    }

    func destroy() {
        stopOutput()
        let first = io.withLock { state -> Bool in
            defer { state.destroyed = true }
            return !state.destroyed
        }
        if first { AudioHardwareDestroyAggregateDevice(id) }
    }
}
