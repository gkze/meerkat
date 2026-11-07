import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import Synchronization

// MARK: - usb.attached / usb.detached

public struct USBDevicePayload: IOServicePayload, Equatable {
    public let name: String?
    public let vendorId: Int?
    public let productId: Int?
    public let serialNumber: String?
    public let locationId: Int?
    /// The IORegistry entry id: stable while the device stays attached, and
    /// equal in the `usb.attached` and `usb.detached` events for one device.
    public let registryEntryId: UInt64

    public static var schema: TypeSchema {
        .named(
            "USBDevice",
            ObjectSchema([
                .optional("name", String.self, doc: "USB product name string."),
                .optional("vendorId", Int.self, doc: "idVendor."),
                .optional("productId", Int.self, doc: "idProduct."),
                .optional("serialNumber", String.self, doc: "USB serial number string; many devices have none."),
                .optional("locationId", Int.self, doc: "locationID: the port path, stable for one physical port."),
                .field(
                    "registryEntryId", UInt64.self,
                    doc: "IORegistry entry id; the same in attached and detached events for one connection."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                name: "DJI MIC MINI", vendorId: 11427, productId: 16_400, serialNumber: "8C1A2B3C",
                locationId: 17_825_792, registryEntryId: 4_294_996_368),
            Self(
                name: nil, vendorId: nil, productId: nil, serialNumber: nil, locationId: nil,
                registryEntryId: 4_294_996_369),
        ]
    }

    /// Reads the device's registry properties. Absent properties stay nil.
    public static let className = "IOUSBHostDevice"

    public static func from(_ device: io_object_t) -> USBDevicePayload {
        func property<T>(_ key: String, as type: T.Type) -> T? { IORegistry.property(device, key) as? T }
        return USBDevicePayload(
            name: property("USB Product Name", as: String.self),
            vendorId: property("idVendor", as: NSNumber.self)?.intValue,
            productId: property("idProduct", as: NSNumber.self)?.intValue,
            serialNumber: property("USB Serial Number", as: String.self),
            locationId: property("locationID", as: NSNumber.self)?.intValue,
            registryEntryId: IORegistry.entryID(device)
        )
    }
}

public enum USBAttachedEvent: IOServiceEventKind {
    public typealias Payload = USBDevicePayload
    public static let notification = kIOFirstMatchNotification
    public static let descriptor = EventDescriptor(
        "usb.attached",
        "A USB device was connected. Devices already connected when the subscription starts are not reported. A hub and each device behind it are reported separately.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "IOServiceAddMatchingNotification(kIOFirstMatchNotification, IOUSBHostDevice)"
    )
}

public enum USBDetachedEvent: IOServiceEventKind {
    public typealias Payload = USBDevicePayload
    public static let notification = kIOTerminatedNotification
    public static let descriptor = EventDescriptor(
        "usb.detached",
        "A USB device was disconnected. The fields are read as the device leaves; ones it no longer reports are absent. Match it to its `usb.attached` event by `registryEntryId`.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "IOServiceAddMatchingNotification(kIOTerminatedNotification, IOUSBHostDevice)"
    )
}

// MARK: - hid.attached / hid.detached

public struct HIDDevicePayload: IOServicePayload, Equatable {
    /// From the primary usage (HID Usage Tables, Generic Desktop and
    /// Digitizer pages).
    public enum Kind: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case keyboard, mouse, trackpad, gameController, other
    }

    public let kind: Kind
    public let name: String?
    public let manufacturer: String?
    public let vendorId: Int?
    public let productId: Int?
    public let transport: String?
    public let usagePage: Int?
    public let usage: Int?
    public let registryEntryId: UInt64

    public static var schema: TypeSchema {
        .named(
            "HIDDevice",
            ObjectSchema([
                .field("kind", Kind.self, doc: "What the device's primary usage says it is."),
                .optional("name", String.self, doc: "Product string."),
                .optional("manufacturer", String.self),
                .optional("vendorId", Int.self),
                .optional("productId", Int.self),
                .optional(
                    "transport", String.self,
                    doc: "How it is connected, e.g. \"USB\", \"Bluetooth\", \"Bluetooth Low Energy\", \"SPI\"."),
                .optional("usagePage", Int.self, doc: "Primary HID usage page."),
                .optional("usage", Int.self, doc: "Primary HID usage."),
                .field(
                    "registryEntryId", UInt64.self,
                    doc: "IORegistry entry id; the same in attached and detached events for one connection."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                kind: .keyboard, name: "Magic Keyboard", manufacturer: "Apple Inc.", vendorId: 76, productId: 668,
                transport: "Bluetooth", usagePage: 1, usage: 6, registryEntryId: 4_294_999_101),
            Self(
                kind: .other, name: nil, manufacturer: nil, vendorId: nil, productId: nil, transport: nil,
                usagePage: nil, usage: nil, registryEntryId: 4_294_999_102),
        ]
    }

    static func kind(usagePage: Int?, usage: Int?) -> Kind {
        switch (usagePage, usage) {
        case (0x01, 0x06), (0x01, 0x07): .keyboard
        case (0x01, 0x01), (0x01, 0x02): .mouse
        case (0x0D, 0x05): .trackpad
        case (0x01, 0x04), (0x01, 0x05), (0x01, 0x08): .gameController
        default: .other
        }
    }

    public static let className = "IOHIDDevice"

    public static func from(_ device: io_object_t) -> Self {
        func string(_ key: String) -> String? { IORegistry.property(device, key) as? String }
        func int(_ key: String) -> Int? { (IORegistry.property(device, key) as? NSNumber)?.intValue }
        let page = int(kIOHIDPrimaryUsagePageKey)
        let usage = int(kIOHIDPrimaryUsageKey)
        return Self(
            kind: kind(usagePage: page, usage: usage), name: string(kIOHIDProductKey),
            manufacturer: string(kIOHIDManufacturerKey), vendorId: int(kIOHIDVendorIDKey),
            productId: int(kIOHIDProductIDKey), transport: string(kIOHIDTransportKey),
            usagePage: page, usage: usage, registryEntryId: IORegistry.entryID(device))
    }
}

public enum HIDAttachedEvent: IOServiceEventKind {
    public typealias Payload = HIDDevicePayload
    public static let notification = kIOFirstMatchNotification
    public static let descriptor = EventDescriptor(
        "hid.attached",
        "A keyboard, mouse, trackpad, game controller or other HID device was connected, over USB, Bluetooth or internally. Devices already connected when the subscription starts are not reported. One physical device can publish several HID services (a keyboard with media keys, for example), each reported separately. No input from the device is observed.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "IOServiceAddMatchingNotification(kIOFirstMatchNotification, IOHIDDevice)"
    )
}

public enum HIDDetachedEvent: IOServiceEventKind {
    public typealias Payload = HIDDevicePayload
    public static let notification = kIOTerminatedNotification
    public static let descriptor = EventDescriptor(
        "hid.detached",
        "A HID device was disconnected. Match it to its `hid.attached` event by `registryEntryId`.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "IOServiceAddMatchingNotification(kIOTerminatedNotification, IOHIDDevice)"
    )
}

// MARK: - iokit.attached / iokit.detached

public struct IOKitServicePayload: EventPayload, Equatable {
    public let className: String
    public let name: String?
    public let registryEntryId: UInt64
    public let properties: [String: JSONValue]

    public static var schema: TypeSchema {
        .named(
            "IOKitService",
            ObjectSchema([
                .field(
                    "className", String.self,
                    doc: "The service's own class, which can be a subclass of the one matched."),
                .optional("name", String.self, doc: "Registry entry name."),
                .field(
                    "registryEntryId", UInt64.self,
                    doc: "IORegistry entry id; the same in attached and detached events for one service."),
                .field(
                    "properties", [String: JSONValue].self,
                    doc:
                        "The requested properties the service has, as JSON (data as base64); missing ones are left out."
                ),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                className: "IOThunderboltSwitchType5", name: "IOThunderboltSwitchType5", registryEntryId: 4_294_970_011,
                properties: ["Device Vendor Name": "CalDigit, Inc.", "Device Model Name": "TS4"]),
            Self(className: "IOPCIDevice", name: nil, registryEntryId: 4_294_970_012, properties: [:]),
        ]
    }
}

public struct IOKitServiceParameters: EventParameters {
    public static let maximumProperties = 32

    public var className: String
    public var properties: [String]

    public init(className: String, properties: [String] = []) {
        self.className = className
        self.properties = Array(Set(properties)).sorted()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            className: try container.decode(String.self, forKey: .className),
            properties: try container.decodeIfPresent([String].self, forKey: .properties) ?? [])
    }

    public func validate() throws {
        // IOKit class names are C++ identifiers.
        guard className.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil else {
            throw EventError.invalidParameters("\"className\" must be an IOKit class name, got \"\(className)\"")
        }
        guard properties.count <= Self.maximumProperties, !properties.contains(where: \.isEmpty) else {
            throw EventError.invalidParameters(
                "\"properties\" must list at most \(Self.maximumProperties) non-empty keys")
        }
    }

    public static var schema: TypeSchema {
        .object(
            ObjectSchema([
                .field(
                    "className", String.self,
                    doc:
                        "IOKit class to match, subclasses included, e.g. \"IOThunderboltSwitch\" or \"IOPCIDevice\"; `ioreg -l` lists them. A class that does not exist matches nothing."
                ),
                .optional(
                    "properties", [String].self,
                    doc:
                        "Registry properties to include, at most \(maximumProperties); duplicates are ignored. Default none."
                ),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(className: "IOThunderboltSwitch", properties: ["Device Vendor Name", "Device Model Name"]),
            Self(className: "IOPCIDevice"),
        ]
    }
}

extension IOKitServicePayload {
    static func from(_ service: io_object_t, properties keys: [String]) -> Self {
        var properties: [String: JSONValue] = [:]
        for key in keys {
            if let value = IORegistry.property(service, key).flatMap({ JSONValue(propertyList: $0) }) {
                properties[key] = value
            }
        }
        var name = [CChar](repeating: 0, count: 128)  // io_name_t
        let named = IORegistryEntryGetName(service, &name) == KERN_SUCCESS
        return Self(
            className: IORegistry.className(service), name: named ? String(nulTerminated: name) : nil,
            registryEntryId: IORegistry.entryID(service), properties: properties)
    }
}

public enum IOKitAttachedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "iokit.attached",
        "Escape hatch: a service of an IOKit class (or a subclass) appeared, such as a Thunderbolt device, a PCI device or a display. Services present when the subscription starts are not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .named,
        source: "IOServiceAddMatchingNotification(kIOFirstMatchNotification, className)"
    )

    public static func makeSource(
        _ parameters: IOKitServiceParameters, environment: SourceEnvironment,
        emit: Emitter<IOKitServicePayload>
    ) throws -> any EventSource {
        IOServiceNotificationSource(
            label: descriptor.name, className: parameters.className,
            notification: kIOFirstMatchNotification
        ) {
            emit(.from($0, properties: parameters.properties))
        }
    }
}

public enum IOKitDetachedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "iokit.detached",
        "Escape hatch: a service of an IOKit class (or a subclass) went away. Properties are read as it leaves; ones it no longer has are absent. Match it to its `iokit.attached` event by `registryEntryId`.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .named,
        source: "IOServiceAddMatchingNotification(kIOTerminatedNotification, className)"
    )

    public static func makeSource(
        _ parameters: IOKitServiceParameters, environment: SourceEnvironment,
        emit: Emitter<IOKitServicePayload>
    ) throws -> any EventSource {
        IOServiceNotificationSource(
            label: descriptor.name, className: parameters.className,
            notification: kIOTerminatedNotification
        ) {
            emit(.from($0, properties: parameters.properties))
        }
    }
}

/// A payload read from a service of one IOKit class.
public protocol IOServicePayload: EventPayload {
    static var className: String { get }
    static func from(_ service: io_object_t) -> Self
}

/// A kind fed by one IOKit matching notification.
public protocol IOServiceEventKind: EventKind where Payload: IOServicePayload, Parameters == NoParameters {
    static var notification: String { get }
}

extension IOServiceEventKind {
    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<Payload>
    ) throws -> any EventSource {
        IOServiceNotificationSource(
            label: descriptor.name, className: Payload.className, notification: notification
        ) { emit(.from($0)) }
    }
}

/// One IOKit matching notification on a private serial queue.
///
/// The iterator returned at registration lists services that already match
/// (for first-match notifications, everything present now). Draining it arms
/// the notification; those services are released without being reported,
/// since they did not appear while the subscription ran.
///
/// Every use of the port and the iterator happens on `queue`, so teardown
/// cannot race a callback that is iterating.
final class IOServiceNotificationSource: EventSource {
    private let className: String
    private let notification: String
    private let registration: IONotificationRegistration<Context>

    final class Context: Sendable {
        let handle: @Sendable (io_object_t) -> Void
        init(handle: @escaping @Sendable (io_object_t) -> Void) { self.handle = handle }
    }

    /// - Parameter handle: called on the private queue for each service that
    ///   matched after registration. The service is released after it returns.
    init(
        label: String, className: String, notification: String,
        handle: @escaping @Sendable (io_object_t) -> Void
    ) {
        self.className = className
        self.notification = notification
        registration = IONotificationRegistration(label: label, context: Context(handle: handle))
    }

    func start() throws {
        try registration.start("IOServiceAddMatchingNotification(\(className))") { port, refcon, iterator in
            let status = IOServiceAddMatchingNotification(
                port, notification, IOServiceMatching(className),
                { refcon, iterator in
                    guard let refcon else { return }
                    IORegistry.drain(iterator, Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue().handle)
                }, refcon, &iterator
            )
            // Arm before scheduling so the existing services cannot be handed
            // to the callback; nothing else can touch the port yet.
            if status == KERN_SUCCESS { IORegistry.drain(iterator) }
            return status
        }
    }

    func stop() { registration.stop() }
}

// MARK: - display.reconfigured

public struct DisplayReconfiguredPayload: EventPayload, Equatable {
    public enum Change: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case added, removed, moved, setMain, setMode, mirrored, unmirrored, enabled, disabled, desktopShapeChanged
    }

    public let displayId: UInt32
    public let changes: [Change]
    public let isMain: Bool?
    public let isBuiltin: Bool?
    public let width: Double?
    public let height: Double?

    public static var schema: TypeSchema {
        .named(
            "DisplayReconfiguration",
            ObjectSchema([
                .field("displayId", UInt32.self, doc: "CGDirectDisplayID."),
                .field(
                    "changes", [Change].self,
                    doc: "What changed for this display; can be empty for an on-line display that was not affected."),
                .optional(
                    "isMain", Bool.self, doc: "Absent for a removed display, which CoreGraphics no longer describes."),
                .optional("isBuiltin", Bool.self, doc: "Absent for a removed display."),
                .optional("width", Double.self, doc: "Bounds width in points; absent for a removed display."),
                .optional("height", Double.self, doc: "Bounds height in points; absent for a removed display."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                displayId: 1, changes: [.setMode, .desktopShapeChanged], isMain: true, isBuiltin: true,
                width: 1512, height: 982),
            Self(displayId: 4, changes: [.removed], isMain: nil, isBuiltin: nil, width: nil, height: nil),
        ]
    }

    static let flags: [(CGDisplayChangeSummaryFlags, Change)] = [
        (.addFlag, .added), (.removeFlag, .removed), (.movedFlag, .moved), (.setMainFlag, .setMain),
        (.setModeFlag, .setMode), (.mirrorFlag, .mirrored), (.unMirrorFlag, .unmirrored),
        (.enabledFlag, .enabled), (.disabledFlag, .disabled), (.desktopShapeChangedFlag, .desktopShapeChanged),
    ]

    static func from(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) -> Self {
        let changes = Self.flags.filter { flags.contains($0.0) }.map(\.1)
        // CoreGraphics calls fail for a removed display id; report nothing
        // rather than the zeros they return.
        guard !flags.contains(.removeFlag) else {
            return Self(displayId: display, changes: changes, isMain: nil, isBuiltin: nil, width: nil, height: nil)
        }
        let bounds = CGDisplayBounds(display)
        return Self(
            displayId: display, changes: changes,
            isMain: CGDisplayIsMain(display) != 0, isBuiltin: CGDisplayIsBuiltin(display) != 0,
            width: bounds.isEmpty ? nil : Double(bounds.width),
            height: bounds.isEmpty ? nil : Double(bounds.height))
    }
}

public enum DisplayReconfiguredEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "display.reconfigured",
        "A display was added, removed, moved, mirrored or changed mode. One event per affected display after the change completes; the \"about to reconfigure\" phase is not reported. Delivered only while the host process runs its main run loop.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "CGDisplayRegisterReconfigurationCallback"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<DisplayReconfiguredPayload>
    ) throws -> any EventSource {
        DisplayReconfigurationSource(emit: emit)
    }
}

/// CoreGraphics invokes reconfiguration callbacks on the process's event
/// processing thread, the main thread, so the context is released on the
/// main queue after removal: a callback already running there finishes first.
final class DisplayReconfigurationSource: EventSource {
    private let context: Context
    private let registered = Atomic<Bool>(false)

    final class Context: Sendable {
        let emit: Emitter<DisplayReconfiguredPayload>
        init(emit: Emitter<DisplayReconfiguredPayload>) { self.emit = emit }
    }

    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        let context = Unmanaged<Context>.fromOpaque(userInfo).takeUnretainedValue()
        context.emit(.from(display: display, flags: flags))
    }

    init(emit: Emitter<DisplayReconfiguredPayload>) {
        context = Context(emit: emit)
    }

    func start() throws {
        // The callback's reference: released in `stop`, or below on failure.
        let context = Unmanaged.passRetained(self.context)
        let status = CGDisplayRegisterReconfigurationCallback(Self.callback, context.toOpaque())
        guard status == .success else {
            context.release()
            throw EventError.sourceUnavailable(
                "CGDisplayRegisterReconfigurationCallback failed with \(status.rawValue)")
        }
        registered.store(true, ordering: .releasing)
    }

    func stop() {
        guard registered.exchange(false, ordering: .acquiring) else { return }
        let context = Unmanaged.passUnretained(self.context)
        CGDisplayRemoveReconfigurationCallback(Self.callback, context.toOpaque())
        DispatchQueue.main.async { context.release() }
    }
}
