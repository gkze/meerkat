import AudioToolbox
import CoreAudio
import Dispatch
import Synchronization

// MARK: - Property-listener state sources

// CoreAudio and CoreMediaIO share one listener model: register a block for an
// (object, selector, scope) address on a dispatch queue, and remove it with
// the same block and queue. The objects worth listening to change at run time
// (devices and processes come and go), so a source recomputes the addresses it
// needs on every change and reconciles its registrations with them.

/// One property address on a HAL-style object. CoreAudio and CoreMediaIO
/// both use 32-bit object ids, selectors, scopes and elements.
struct HALPropertyKey: Hashable, Sendable {
    var object: UInt32
    var selector: UInt32
    var scope: UInt32
    /// The main element; both frameworks define it as 0.
    var element: UInt32 = 0
}

/// A framework's block-based property listener calls.
protocol HALListenerAPI: SendableMetatype {
    associatedtype Block
    static func makeBlock(_ changed: @escaping @Sendable () -> Void) -> Block
    static func add(_ key: HALPropertyKey, queue: DispatchQueue, block: Block) -> Int32
    static func remove(_ key: HALPropertyKey, queue: DispatchQueue, block: Block) -> Int32
}

/// Typed reads of HAL object properties over a framework's two read calls;
/// nil when a property cannot be read, which for an object usually means it
/// disappeared while being read.
protocol HALProperties {
    static func dataSize(_ key: HALPropertyKey) -> UInt32?
    /// Fills `buffer`, which holds `size` bytes; returns the bytes written.
    static func data(_ key: HALPropertyKey, into buffer: UnsafeMutableRawPointer, size: UInt32) -> UInt32?
}

extension HALProperties {
    static func objectIDs(_ key: HALPropertyKey) -> [UInt32]? {
        guard let size = dataSize(key) else { return nil }
        let stride = MemoryLayout<UInt32>.size
        var ids = [UInt32](repeating: 0, count: Int(size) / stride)
        guard let used = data(key, into: &ids, size: size) else { return nil }
        return Array(ids.prefix(Int(used) / stride))
    }

    /// A fixed-size property; `initial` only gives the buffer its type.
    static func value<Value: BitwiseCopyable>(_ key: HALPropertyKey, initial: Value) -> Value? {
        var value = initial
        guard data(key, into: &value, size: UInt32(MemoryLayout<Value>.size)) != nil else { return nil }
        return value
    }

    /// A CFString property; both frameworks return it retained.
    static func string(_ key: HALPropertyKey) -> String? {
        var value: Unmanaged<CFString>?
        guard data(key, into: &value, size: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)) != nil else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// What a state source reads on each change: the properties whose changes
/// can alter the state, and the state itself (nil when it could not be read).
struct HALSnapshot<Payload> {
    var listen: Set<HALPropertyKey>
    var payload: Payload?
}

/// A `state` source over HAL property listeners.
///
/// Everything after `start` runs on one serial queue: the first read (the
/// first HAL call in a process takes 60–130 ms, so it must not run on the
/// caller of `start`), every listener callback, and the removal in `stop`,
/// which waits for the queue. After `stop` returns no listener remains and
/// nothing more is emitted. Identical consecutive states are not emitted.
final class HALStateSource<API: HALListenerAPI, Payload: EventPayload & Equatable>: EventSource {
    private let queue: DispatchQueue
    private let read: @Sendable () -> HALSnapshot<Payload>
    private let reporter: StateReporter<Payload>
    private let state = Mutex<State>(State())

    private struct State {
        var running = false
        /// The single block every registration of this source uses, so
        /// removal can pass the exact block that was added.
        var block: API.Block?
        var registered: Set<HALPropertyKey> = []
    }

    init(label: String, read: @escaping @Sendable () -> HALSnapshot<Payload>, emit: Emitter<Payload>) {
        queue = DispatchQueue(label: "com.gkze.meerkat.\(label)", qos: .utility)
        self.read = read
        reporter = StateReporter(emit)
    }

    func start() throws {
        state.withLock { $0.running = true }
        queue.async { self.refresh() }
    }

    func stop() {
        queue.sync {
            let block = state.withLock { state -> API.Block? in
                state.running = false
                return state.block
            }
            guard let block else { return }
            let registered = state.withLock { state -> Set<HALPropertyKey> in
                defer { state.registered = [] }
                return state.registered
            }
            for key in registered { _ = API.remove(key, queue: queue, block: block) }
        }
    }

    /// Runs on `queue`.
    private func refresh() {
        guard
            let block = state.withLock({ state -> API.Block? in
                guard state.running else { return nil }
                if state.block == nil {
                    // Weak: the HAL keeps the block until removal, and a stopped
                    // source must not be kept alive by it.
                    state.block = API.makeBlock { [weak self] in self?.refresh() }
                }
                return state.block
            })
        else { return }

        // A property can change between reading it and registering for it.
        // When new registrations were added, read again so such a change is
        // seen; bounded, because objects can keep appearing.
        var snapshot = read()
        for _ in 0..<3 {
            let registered = state.withLock { $0.registered }
            for key in registered.subtracting(snapshot.listen) {
                _ = API.remove(key, queue: queue, block: block)
            }
            var kept = registered.intersection(snapshot.listen)
            var added = false
            for key in snapshot.listen.subtracting(registered)
            where API.add(key, queue: queue, block: block) == 0 {
                // A failed add means the object is already gone; the list
                // listener reports its removal.
                kept.insert(key)
                added = true
            }
            state.withLock { $0.registered = kept }
            guard added else { break }
            snapshot = read()
        }

        reporter.report { snapshot.payload }
    }
}

enum CoreAudioListenerAPI: HALListenerAPI {
    static func makeBlock(_ changed: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in changed() }
    }

    static func add(_ key: HALPropertyKey, queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock)
        -> Int32
    {
        var address = CoreAudioProperties.address(key)
        return AudioObjectAddPropertyListenerBlock(key.object, &address, queue, block)
    }

    static func remove(_ key: HALPropertyKey, queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock)
        -> Int32
    {
        var address = CoreAudioProperties.address(key)
        return AudioObjectRemovePropertyListenerBlock(key.object, &address, queue, block)
    }
}

// MARK: - CoreAudio reads

/// Reads of CoreAudio object properties.
enum CoreAudioProperties: HALProperties {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let global = kAudioObjectPropertyScopeGlobal
    static let input = kAudioObjectPropertyScopeInput
    static let output = kAudioObjectPropertyScopeOutput

    static func key(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = global
    ) -> HALPropertyKey {
        HALPropertyKey(object: object, selector: selector, scope: scope, element: kAudioObjectPropertyElementMain)
    }

    static func address(_ key: HALPropertyKey) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: key.selector, mScope: key.scope, mElement: key.element)
    }

    static func dataSize(_ key: HALPropertyKey) -> UInt32? {
        var address = address(key)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(key.object, &address, 0, nil, &size) == noErr ? size : nil
    }

    static func data(_ key: HALPropertyKey, into buffer: UnsafeMutableRawPointer, size: UInt32) -> UInt32? {
        var address = address(key)
        var used = size
        return AudioObjectGetPropertyData(key.object, &address, 0, nil, &used, buffer) == noErr ? used : nil
    }

    static func objectIDs(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = global
    ) -> [AudioObjectID]? {
        objectIDs(key(object, selector, scope))
    }

    static func uint32(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = global
    ) -> UInt32? {
        value(key(object, selector, scope), initial: 0)
    }

    static func float32(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = global
    ) -> Float32? {
        value(key(object, selector, scope), initial: 0)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        string(key(object, selector))
    }

    /// Channels across the device's streams in one direction.
    static func channels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int? {
        let key = key(device, kAudioDevicePropertyStreamConfiguration, scope)
        guard let size = dataSize(key) else { return nil }
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard data(key, into: raw, size: size) != nil else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func devices() -> [AudioObjectID]? {
        objectIDs(system, kAudioHardwarePropertyDevices)
    }

    /// The device's description, or nil when its stream configuration cannot
    /// be read (the device is going away).
    static func device(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard let inputs = channels(id, input), let outputs = channels(id, output) else { return nil }
        return AudioDeviceInfo(
            id: id,
            uid: string(id, kAudioDevicePropertyDeviceUID),
            name: string(id, kAudioObjectPropertyName),
            manufacturer: string(id, kAudioObjectPropertyManufacturer),
            inputChannels: inputs,
            outputChannels: outputs,
            transport: uint32(id, kAudioDevicePropertyTransportType).map(AudioDeviceInfo.Transport.init(code:))
        )
    }
}

// MARK: - Shared payload types

/// An audio device as CoreAudio describes it.
public struct AudioDeviceInfo: Codable, Sendable, Equatable, SchemaDescribed {
    public enum Transport: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay, aggregate, virtual
        case thunderbolt, pci, firewire, avb, continuityCapture, remoteScreen, remoteStreaming
        /// CoreAudio reports no transport, or one this version does not name.
        case unknown

        init(code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
            case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            // 'fgrp' (the deprecated kAudioDeviceTransportTypeAutoAggregate)
            // is an aggregate the system assembled.
            case kAudioDeviceTransportTypeAggregate, 0x6667_7270: self = .aggregate
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypePCI: self = .pci
            case kAudioDeviceTransportTypeFireWire: self = .firewire
            case kAudioDeviceTransportTypeAVB: self = .avb
            case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
                self = .continuityCapture
            case kAudioDeviceTransportTypeRemoteScreen: self = .remoteScreen
            case kAudioDeviceTransportTypeRemoteStreaming: self = .remoteStreaming
            default: self = .unknown
            }
        }
    }

    /// CoreAudio's object id; valid until the device disappears.
    public let id: UInt32
    public let uid: String?
    public let name: String?
    public let manufacturer: String?
    public let inputChannels: Int
    public let outputChannels: Int
    public let transport: Transport?

    public static var schema: TypeSchema {
        .named(
            "AudioDevice",
            ObjectSchema([
                .field(
                    "id", UInt32.self, doc: "CoreAudio object id; valid while the device exists, may be reused after."),
                .optional("uid", String.self, doc: "Persistent device UID; stable across reconnects and reboots."),
                .optional("name", String.self),
                .optional("manufacturer", String.self),
                .field(
                    "inputChannels", Int.self,
                    doc: "Input channels across all input streams; 0 for output-only devices."),
                .field(
                    "outputChannels", Int.self,
                    doc: "Output channels across all output streams; 0 for input-only devices."),
                .optional(
                    "transport", Transport.self, doc: "How the device is connected; absent when CoreAudio does not say."
                ),
            ]))
    }

    static let speakers = AudioDeviceInfo(
        id: 74, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
        manufacturer: "Apple Inc.", inputChannels: 0, outputChannels: 2,
        transport: .builtIn)
    static let microphone = AudioDeviceInfo(
        id: 81, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        manufacturer: "Apple Inc.", inputChannels: 1, outputChannels: 0,
        transport: .builtIn)
    static let bare = AudioDeviceInfo(
        id: 120, uid: nil, name: nil, manufacturer: nil,
        inputChannels: 2, outputChannels: 2, transport: nil)
}

// MARK: - audio.devices

public struct AudioDevicesPayload: EventPayload, Equatable {
    /// Ordered by `id`.
    public let devices: [AudioDeviceInfo]

    public static var schema: TypeSchema {
        .named(
            "AudioDevices",
            ObjectSchema([
                .field("devices", [AudioDeviceInfo].self, doc: "Every audio device, ordered by id.")
            ]))
    }

    public static var examples: [Self] {
        [Self(devices: [.speakers, .microphone, .bare]), Self(devices: [])]
    }
}

public enum AudioDevicesEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "audio.devices",
        "The set of audio input and output devices changed (a device was connected, disconnected, or created). The current list is delivered first. Changes to a device's name or channels alone are not reported.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source: "CoreAudio kAudioHardwarePropertyDevices listener"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<AudioDevicesPayload>
    ) throws -> any EventSource {
        let listen: Set = [CoreAudioProperties.key(CoreAudioProperties.system, kAudioHardwarePropertyDevices)]
        return HALStateSource<CoreAudioListenerAPI, AudioDevicesPayload>(
            label: "audio-devices",
            read: {
                let payload = CoreAudioProperties.devices().map { ids in
                    AudioDevicesPayload(devices: ids.sorted().compactMap(CoreAudioProperties.device))
                }
                return HALSnapshot(listen: listen, payload: payload)
            }, emit: emit)
    }
}

// MARK: - audio.defaultDevice

public struct AudioDefaultDevicePayload: EventPayload, Equatable {
    public let input: AudioDeviceInfo?
    public let output: AudioDeviceInfo?
    public let systemOutput: AudioDeviceInfo?

    public static var schema: TypeSchema {
        .named(
            "AudioDefaultDevices",
            ObjectSchema([
                .optional("input", AudioDeviceInfo.self, doc: "Default input; absent when there is none."),
                .optional(
                    "output", AudioDeviceInfo.self, doc: "Default output for content; absent when there is none."),
                .optional(
                    "systemOutput", AudioDeviceInfo.self,
                    doc: "Output for alerts and sound effects; absent when there is none."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(input: .microphone, output: .speakers, systemOutput: .speakers),
            Self(input: nil, output: nil, systemOutput: nil),
        ]
    }
}

public enum AudioDefaultDeviceEvent: EventKind {
    static let selectors = [
        kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ]

    public static let descriptor = EventDescriptor(
        "audio.defaultDevice",
        "The default input, output, or system (alert) output device changed; every event carries all three. The current defaults are delivered first.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source:
            "CoreAudio kAudioHardwarePropertyDefaultInputDevice, DefaultOutputDevice, DefaultSystemOutputDevice listeners"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<AudioDefaultDevicePayload>
    ) throws -> any EventSource {
        let listen = Set(selectors.map { CoreAudioProperties.key(CoreAudioProperties.system, $0) })
        return HALStateSource<CoreAudioListenerAPI, AudioDefaultDevicePayload>(
            label: "audio-default-device",
            read: {
                func device(_ selector: AudioObjectPropertySelector) -> AudioDeviceInfo? {
                    guard let id = CoreAudioProperties.uint32(CoreAudioProperties.system, selector),
                        id != kAudioObjectUnknown
                    else { return nil }
                    return CoreAudioProperties.device(id)
                }
                return HALSnapshot(
                    listen: listen,
                    payload: AudioDefaultDevicePayload(
                        input: device(kAudioHardwarePropertyDefaultInputDevice),
                        output: device(kAudioHardwarePropertyDefaultOutputDevice),
                        systemOutput: device(kAudioHardwarePropertyDefaultSystemOutputDevice)
                    ))
            }, emit: emit)
    }
}

// MARK: - audio.inUse

public enum AudioDirection: String, Codable, Sendable, CaseIterable, SchemaDescribed {
    case input, output
}

public struct AudioRunningDevice: Codable, Sendable, Equatable, SchemaDescribed {
    public let device: AudioDeviceInfo
    public let direction: AudioDirection

    public static var schema: TypeSchema {
        .named(
            "AudioRunningDevice",
            ObjectSchema([
                .field("device", AudioDeviceInfo.self),
                .field(
                    "direction", AudioDirection.self, doc: "\"input\" means something is recording from the device."),
            ]))
    }
}

public struct AudioInUsePayload: EventPayload, Equatable {
    /// Ordered by device id, then input before output.
    public let running: [AudioRunningDevice]

    public static var schema: TypeSchema {
        .named(
            "AudioInUse",
            ObjectSchema([
                .field(
                    "running", [AudioRunningDevice].self,
                    doc: "Devices doing audio I/O for any process, one entry per direction; empty when idle.")
            ]))
    }

    public static var examples: [Self] {
        [
            Self(running: [
                AudioRunningDevice(device: .speakers, direction: .output),
                AudioRunningDevice(device: .bare, direction: .input),
            ]),
            Self(running: []),
        ]
    }
}

public enum AudioInUseEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "audio.inUse",
        "Which audio devices are doing input or output for any process changed; a device with an input entry is being recorded from, which is what the microphone indicator shows. The current set is delivered first. The processes involved are not reported, and no audio is captured.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .named,
        source:
            "CoreAudio kAudioDevicePropertyDeviceIsRunningSomewhere and kAudioProcessPropertyIsRunningInput/Output, Devices listeners"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<AudioInUsePayload>
    ) throws -> any EventSource {
        HALStateSource<CoreAudioListenerAPI, AudioInUsePayload>(label: "audio-in-use", read: read, emit: emit)
    }

    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` is per device: its
    /// scope is ignored (checked on macOS 27), so it cannot tell a headset's
    /// microphone from its speaker. The direction comes from the process
    /// objects: a process running input whose input device list contains the
    /// device. A direction also needs streams on the device, because some
    /// system processes list an output-only device among their inputs (an
    /// echo-cancellation reference). Processes report the physical devices
    /// they drive, so I/O through an aggregate device shows up on its
    /// sub-devices, not on the aggregate (checked with a private aggregate).
    @Sendable static func read() -> HALSnapshot<AudioInUsePayload> {
        typealias P = CoreAudioProperties
        var listen: Set = [
            P.key(P.system, kAudioHardwarePropertyDevices),
            P.key(P.system, kAudioHardwarePropertyProcessObjectList),
        ]
        guard let devices = P.devices(), let processes = P.objectIDs(P.system, kAudioHardwarePropertyProcessObjectList)
        else {
            return HALSnapshot(listen: listen, payload: nil)
        }

        var inUse: [AudioDirection: Set<AudioObjectID>] = [.input: [], .output: []]
        for process in processes {
            listen.formUnion([
                P.key(process, kAudioProcessPropertyIsRunningInput),
                P.key(process, kAudioProcessPropertyIsRunningOutput),
                P.key(process, kAudioProcessPropertyDevices, P.input),
                P.key(process, kAudioProcessPropertyDevices, P.output),
            ])
            if P.uint32(process, kAudioProcessPropertyIsRunningInput) == 1 {
                inUse[.input, default: []].formUnion(P.objectIDs(process, kAudioProcessPropertyDevices, P.input) ?? [])
            }
            if P.uint32(process, kAudioProcessPropertyIsRunningOutput) == 1 {
                inUse[.output, default: []].formUnion(
                    P.objectIDs(process, kAudioProcessPropertyDevices, P.output) ?? [])
            }
        }

        var running: [AudioRunningDevice] = []
        for id in devices.sorted() {
            listen.insert(P.key(id, kAudioDevicePropertyDeviceIsRunningSomewhere))
            guard P.uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1,
                let device = P.device(id)
            else { continue }
            if device.inputChannels > 0, inUse[.input]?.contains(id) == true {
                running.append(AudioRunningDevice(device: device, direction: .input))
            }
            if device.outputChannels > 0, inUse[.output]?.contains(id) == true {
                running.append(AudioRunningDevice(device: device, direction: .output))
            }
        }
        return HALSnapshot(listen: listen, payload: AudioInUsePayload(running: running))
    }
}

// MARK: - audio.volume

public struct AudioVolume: Codable, Sendable, Equatable, SchemaDescribed {
    public let device: AudioDeviceInfo
    public let volume: Double?
    public let muted: Bool?

    public static var schema: TypeSchema {
        .named(
            "AudioVolume",
            ObjectSchema([
                .field("device", AudioDeviceInfo.self),
                .optional(
                    "volume", Double.self,
                    doc:
                        "0–1, as the menu-bar slider shows it; absent when the device has no software volume (some HDMI and USB devices)."
                ),
                .optional("muted", Bool.self, doc: "Absent when the device has no mute control."),
            ]))
    }
}

public struct AudioVolumePayload: EventPayload, Equatable {
    public let output: AudioVolume?
    public let input: AudioVolume?

    public static var schema: TypeSchema {
        .named(
            "AudioVolumes",
            ObjectSchema([
                .optional("output", AudioVolume.self, doc: "The default output device; absent when there is none."),
                .optional("input", AudioVolume.self, doc: "The default input device; absent when there is none."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                output: AudioVolume(device: .speakers, volume: 0.5, muted: false),
                input: AudioVolume(device: .microphone, volume: 0.71, muted: false)),
            Self(output: AudioVolume(device: .bare, volume: nil, muted: nil), input: nil),
        ]
    }
}

public enum AudioVolumeEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "audio.volume",
        "The volume or mute state of the default output or input device changed, or a different default device took over. The current state is delivered first.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source:
            "CoreAudio kAudioHardwareServiceDeviceProperty_VirtualMainVolume and kAudioDevicePropertyMute listeners on the default devices"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<AudioVolumePayload>
    ) throws -> any EventSource {
        HALStateSource<CoreAudioListenerAPI, AudioVolumePayload>(label: "audio-volume", read: read, emit: emit)
    }

    /// The virtual main volume is the value the system volume UI uses: the
    /// main element when the device has one, otherwise its channels'
    /// balance-preserving combination, so it exists on devices with only
    /// per-channel volume.
    @Sendable static func read() -> HALSnapshot<AudioVolumePayload> {
        typealias P = CoreAudioProperties
        var listen: Set = [
            P.key(P.system, kAudioHardwarePropertyDefaultOutputDevice),
            P.key(P.system, kAudioHardwarePropertyDefaultInputDevice),
        ]
        func volume(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioVolume? {
            guard let id = P.uint32(P.system, selector), id != kAudioObjectUnknown,
                let device = P.device(id)
            else { return nil }
            listen.insert(P.key(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope))
            listen.insert(P.key(id, kAudioDevicePropertyMute, scope))
            return AudioVolume(
                device: device,
                volume: P.float32(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope).map(Double.init),
                muted: P.uint32(id, kAudioDevicePropertyMute, scope).map { $0 != 0 }
            )
        }
        let payload = AudioVolumePayload(
            output: volume(kAudioHardwarePropertyDefaultOutputDevice, P.output),
            input: volume(kAudioHardwarePropertyDefaultInputDevice, P.input))
        return HALSnapshot(listen: listen, payload: payload)
    }
}
