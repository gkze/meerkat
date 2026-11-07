import CoreMediaIO
import Dispatch

// MARK: - CoreMediaIO listeners and reads

enum CMIOListenerAPI: HALListenerAPI {
    static func makeBlock(_ changed: @escaping @Sendable () -> Void) -> CMIOObjectPropertyListenerBlock {
        { _, _ in changed() }
    }

    static func add(_ key: HALPropertyKey, queue: DispatchQueue, block: @escaping CMIOObjectPropertyListenerBlock)
        -> Int32
    {
        var address = CMIOProperties.address(key)
        return CMIOObjectAddPropertyListenerBlock(key.object, &address, queue, block)
    }

    static func remove(_ key: HALPropertyKey, queue: DispatchQueue, block: @escaping CMIOObjectPropertyListenerBlock)
        -> Int32
    {
        var address = CMIOProperties.address(key)
        return CMIOObjectRemovePropertyListenerBlock(key.object, &address, queue, block)
    }
}

/// Reads of CoreMediaIO object properties.
enum CMIOProperties: HALProperties {
    static let system = CMIOObjectID(kCMIOObjectSystemObject)

    static func key(_ object: CMIOObjectID, _ selector: Int) -> HALPropertyKey {
        HALPropertyKey(
            object: object, selector: CMIOObjectPropertySelector(selector),
            scope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            element: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func address(_ key: HALPropertyKey) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: key.selector, mScope: key.scope, mElement: key.element)
    }

    static func dataSize(_ key: HALPropertyKey) -> UInt32? {
        var address = address(key)
        var size: UInt32 = 0
        return CMIOObjectGetPropertyDataSize(key.object, &address, 0, nil, &size) == noErr ? size : nil
    }

    static func data(_ key: HALPropertyKey, into buffer: UnsafeMutableRawPointer, size: UInt32) -> UInt32? {
        var address = address(key)
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(key.object, &address, 0, nil, size, &used, buffer) == noErr ? used : nil
    }

    static func devices() -> [CMIOObjectID]? {
        objectIDs(key(system, kCMIOHardwarePropertyDevices))
    }

    static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        value(key(object, selector), initial: 0)
    }

    static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        string(key(object, selector))
    }
}

// MARK: - camera.inUse

public struct CameraDevicePayload: Codable, Sendable, Equatable, SchemaDescribed {
    /// CoreMediaIO's object id; valid until the device disappears.
    public let id: UInt32
    public let name: String?
    public let uid: String?

    public static var schema: TypeSchema {
        .named(
            "CameraDevice",
            ObjectSchema([
                .field(
                    "id", UInt32.self, doc: "CoreMediaIO object id; valid while the device exists, may be reused after."
                ),
                .optional("name", String.self),
                .optional("uid", String.self, doc: "Persistent device UID."),
            ]))
    }
}

public struct CameraInUsePayload: EventPayload, Equatable {
    /// Ordered by `id`.
    public let running: [CameraDevicePayload]
    public let devices: Int

    public static var schema: TypeSchema {
        .named(
            "CameraInUse",
            ObjectSchema([
                .field(
                    "running", [CameraDevicePayload].self,
                    doc: "Cameras some process is capturing from; empty when none."),
                .field("devices", Int.self, doc: "Video capture devices present, running or not."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                running: [CameraDevicePayload(id: 35, name: "MacBook Pro Camera", uid: "0x1420000005ac8600")],
                devices: 2),
            Self(running: [CameraDevicePayload(id: 40, name: nil, uid: nil)], devices: 1),
            Self(running: [], devices: 0),
        ]
    }
}

public enum CameraInUseEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "camera.inUse",
        "Which cameras are capturing for any process changed, or a camera was connected or disconnected; this is what the camera indicator shows. The current state is delivered first. The processes involved are not reported, and no video is captured. Screen-capture devices are not included.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .named,
        source: "CoreMediaIO kCMIOHardwarePropertyDevices and kCMIODevicePropertyDeviceIsRunningSomewhere listeners"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<CameraInUsePayload>
    ) throws -> any EventSource {
        HALStateSource<CMIOListenerAPI, CameraInUsePayload>(label: "camera-in-use", read: read, emit: emit)
    }

    @Sendable static func read() -> HALSnapshot<CameraInUsePayload> {
        typealias P = CMIOProperties
        var listen: Set = [P.key(P.system, kCMIOHardwarePropertyDevices)]
        guard let devices = P.devices() else { return HALSnapshot(listen: listen, payload: nil) }
        var running: [CameraDevicePayload] = []
        for id in devices.sorted() {
            listen.insert(P.key(id, kCMIODevicePropertyDeviceIsRunningSomewhere))
            guard P.uint32(id, kCMIODevicePropertyDeviceIsRunningSomewhere) == 1 else { continue }
            running.append(
                CameraDevicePayload(
                    id: id, name: P.string(id, kCMIOObjectPropertyName),
                    uid: P.string(id, kCMIODevicePropertyDeviceUID)))
        }
        return HALSnapshot(listen: listen, payload: CameraInUsePayload(running: running, devices: devices.count))
    }
}
