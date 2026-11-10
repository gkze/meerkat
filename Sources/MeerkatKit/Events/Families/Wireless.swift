import CoreLocation
import CoreWLAN
import Foundation
import IOBluetooth
import Synchronization

// Wi-Fi and Bluetooth. Both live behind privacy permissions: Wi-Fi network
// names are location data (Location Services), and any Bluetooth use needs
// the Bluetooth permission.

// MARK: - network.wifi

public struct WiFiPayload: EventPayload, Equatable {
    public enum Band: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case ghz2point4 = "2.4GHz"
        case ghz5 = "5GHz"
        case ghz6 = "6GHz"
    }

    public let interface: String
    public let poweredOn: Bool
    public let associated: Bool
    public let ssid: String?
    public let bssid: String?
    public let rssi: Int?
    public let noise: Int?
    public let transmitRateMbps: Double?
    public let channel: Int?
    public let band: Band?
    public let channelWidthMHz: Int?
    public let security: String?
    public let phyMode: String?
    public let countryCode: String?
    public let locationAuthorized: Bool

    public static var schema: TypeSchema {
        .named(
            "WiFi",
            ObjectSchema([
                .field("interface", String.self, doc: "BSD name of the Wi-Fi interface, such as en0."),
                .field("poweredOn", Bool.self),
                .field("associated", Bool.self, doc: "Joined to a network."),
                .optional("ssid", String.self, doc: "Network name; only with the Location permission."),
                .optional("bssid", String.self, doc: "Access point MAC address; only with the Location permission."),
                .optional("rssi", Int.self, doc: "Signal strength in dBm (closer to 0 is stronger)."),
                .optional("noise", Int.self, doc: "Noise floor in dBm."),
                .optional("transmitRateMbps", Double.self),
                .optional("channel", Int.self),
                .optional("band", Band.self),
                .optional("channelWidthMHz", Int.self),
                .optional("security", String.self, doc: "e.g. \"wpa3Personal\", \"wpa2Enterprise\", \"none\"."),
                .optional("phyMode", String.self, doc: "e.g. \"802.11ax\"."),
                .optional("countryCode", String.self),
                .field(
                    "locationAuthorized", Bool.self,
                    doc: "Whether Meerkat has the Location permission; without it ssid and bssid are always absent."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                interface: "en0", poweredOn: true, associated: true, ssid: "Home", bssid: "a4:83:e7:12:34:56",
                rssi: -54,
                noise: -92, transmitRateMbps: 864, channel: 149, band: .ghz5, channelWidthMHz: 80,
                security: "wpa3Personal",
                phyMode: "802.11ax", countryCode: "US", locationAuthorized: true),
            Self(
                interface: "en0", poweredOn: false, associated: false, ssid: nil, bssid: nil, rssi: nil, noise: nil,
                transmitRateMbps: nil, channel: nil, band: nil, channelWidthMHz: nil, security: nil, phyMode: nil,
                countryCode: nil, locationAuthorized: false),
        ]
    }

    static func read(_ interface: CWInterface, locationAuthorized: Bool) -> Self {
        let associated = interface.interfaceMode() == .station
        let channel = associated ? interface.wlanChannel() : nil
        let band: Band? =
            switch channel?.channelBand {
            case .band2GHz?: .ghz2point4
            case .band5GHz?: .ghz5
            case .band6GHz?: .ghz6
            default: nil
            }
        let width: Int? =
            switch channel?.channelWidth {
            case .width20MHz?: 20
            case .width40MHz?: 40
            case .width80MHz?: 80
            case .width160MHz?: 160
            default: nil
            }
        return Self(
            interface: interface.interfaceName ?? "",
            poweredOn: interface.powerOn(),
            associated: associated,
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            rssi: associated ? interface.rssiValue() : nil,
            noise: associated ? interface.noiseMeasurement() : nil,
            transmitRateMbps: associated ? interface.transmitRate() : nil,
            channel: channel?.channelNumber,
            band: band,
            channelWidthMHz: width,
            security: associated ? security(interface.security()) : nil,
            phyMode: associated ? phyMode(interface.activePHYMode()) : nil,
            countryCode: interface.countryCode(),
            locationAuthorized: locationAuthorized
        )
    }

    static func security(_ value: CWSecurity) -> String? {
        switch value {
        case .none: "none"
        case .WEP: "wep"
        case .wpaPersonal: "wpaPersonal"
        case .wpaPersonalMixed: "wpaPersonalMixed"
        case .wpa2Personal: "wpa2Personal"
        case .personal: "personal"
        case .dynamicWEP: "dynamicWEP"
        case .wpaEnterprise: "wpaEnterprise"
        case .wpaEnterpriseMixed: "wpaEnterpriseMixed"
        case .wpa2Enterprise: "wpa2Enterprise"
        case .enterprise: "enterprise"
        case .wpa3Personal: "wpa3Personal"
        case .wpa3Enterprise: "wpa3Enterprise"
        case .wpa3Transition: "wpa3Transition"
        case .OWE: "owe"
        case .oweTransition: "oweTransition"
        default: nil
        }
    }

    static func phyMode(_ value: CWPHYMode) -> String? {
        switch value {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "802.11n"
        case .mode11ac: "802.11ac"
        case .mode11ax: "802.11ax"
        default: nil
        }
    }
}

public struct WiFiParameters: EventParameters {
    public var signal: Bool

    public init(signal: Bool = false) { self.signal = signal }

    public static var objectSchema: ObjectSchema {
        ObjectSchema([
            ObjectSchema.Field(
                "signal", .boolean, default: false,
                doc:
                    "Also report every change in signal strength and transmit rate (several a minute). Without it, those fields are read only when something else changes."
            )
        ])
    }

    public static var examples: [Self] { [Self(), Self(signal: true)] }
}

public enum WiFiEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "network.wifi",
        "Wi-Fi was turned on or off, joined or left a network, roamed to another access point, or changed channel or mode; with `signal`, also every signal change. The current state is delivered first. The network name and access point need the Location permission (asked for when a rule first subscribes); without it they are absent and everything else is reported.",
        mechanism: .push, semantics: .state, loss: .coalesced, permission: .improves(.location), observation: .named,
        source:
            "CoreWLAN CWEventDelegate (power, SSID, BSSID, link, link quality, mode, country code); CLLocationManager authorization"
    )

    public static func makeSource(
        _ parameters: WiFiParameters, environment: SourceEnvironment,
        emit: Emitter<WiFiPayload>
    ) throws -> any EventSource {
        WiFiSource(signal: parameters.signal, emit: emit)
    }
}

/// CoreWLAN calls its delegate on a private queue; every read and emission
/// happens on this source's serial queue.
final class WiFiSource: NSObject, EventSource, CWEventDelegate, CLLocationManagerDelegate, @unchecked Sendable {
    private let signal: Bool
    private let reporter: StateReporter<WiFiPayload>
    private let queue = DispatchQueue(label: "com.gkze.meerkat.wifi", qos: .utility)
    /// CoreWLAN's client and CoreLocation's manager are not Sendable; they
    /// are created in `start`, used on `queue` (the client) or the main
    /// thread (the manager), and dropped in `stop`.
    private var client: CWWiFiClient?
    private var location: CLLocationManager?
    private let running = Atomic<Bool>(false)
    /// From the location manager's delegate, the only place Apple documents
    /// the authorization status as current.
    private let locationGranted = Atomic<Bool>(false)

    init(signal: Bool, emit: Emitter<WiFiPayload>) {
        self.signal = signal
        reporter = StateReporter(emit)
    }

    func start() throws {
        // A client of its own: the shared client has one delegate, which two
        // subscriptions with different parameters would fight over.
        let client = CWWiFiClient()
        guard client.interface() != nil else {
            throw EventError.sourceUnavailable("network.wifi: this Mac has no Wi-Fi interface")
        }
        client.delegate = self
        var events: [CWEventType] = [
            .powerDidChange, .ssidDidChange, .bssidDidChange, .linkDidChange, .modeDidChange,
            .countryCodeDidChange,
        ]
        if signal { events.append(.linkQualityDidChange) }
        do {
            for event in events { try client.startMonitoringEvent(with: event) }
        } catch {
            try? client.stopMonitoringAllEvents()
            client.delegate = nil
            throw EventError.sourceUnavailable("network.wifi: \(error.localizedDescription)")
        }
        queue.sync { self.client = client }
        running.store(true, ordering: .releasing)
        // The manager reports the authorization through its delegate (and
        // keeps a prompt alive), so it is kept until `stop`. Without a usage
        // description in the bundle there is nothing to ask with.
        if EventDescriptor.Permission.location.status != .unavailable {
            DispatchQueue.main.async {
                guard self.running.load(ordering: .acquiring) else { return }
                let manager = CLLocationManager()
                manager.delegate = self
                self.location = manager
            }
        }
        queue.async { self.report() }
    }

    func stop() {
        guard running.exchange(false, ordering: .acquiring) else { return }
        queue.sync {
            try? client?.stopMonitoringAllEvents()
            client?.delegate = nil
            client = nil
        }
        DispatchQueue.main.async {
            self.location?.delegate = nil
            self.location = nil
        }
    }

    /// Runs on `queue`.
    private func report() {
        guard running.load(ordering: .acquiring), let interface = client?.interface() else { return }
        let authorized = locationGranted.load(ordering: .acquiring)
        reporter.report { WiFiPayload.read(interface, locationAuthorized: authorized) }
    }

    private func changed() { queue.async { self.report() } }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func countryCodeDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func modeDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        changed()
    }
    /// Main thread; called once after the delegate is set, then on changes.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            locationGranted.store(true, ordering: .releasing)
        case .notDetermined:
            locationGranted.store(false, ordering: .releasing)
            manager.requestAlwaysAuthorization()
        default:
            locationGranted.store(false, ordering: .releasing)
        }
        changed()
    }
}

// MARK: - bluetooth.devices

public struct BluetoothDevice: Codable, Sendable, Equatable, SchemaDescribed {
    public enum MajorClass: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case computer, phone, network, audio, peripheral, imaging, wearable, toy, health, other
    }

    public let address: String
    public let name: String?
    public let connected: Bool
    public let paired: Bool
    public let majorClass: MajorClass

    public static var schema: TypeSchema {
        .named(
            "BluetoothDevice",
            ObjectSchema([
                .field("address", String.self, doc: "Device address, e.g. \"a4-83-e7-12-34-56\"."),
                .optional("name", String.self),
                .field("connected", Bool.self),
                .field("paired", Bool.self),
                .field(
                    "majorClass", MajorClass.self,
                    doc: "Bluetooth Classic device class; Low Energy-only devices are \"other\"."),
            ]))
    }

    /// Major device class values from the Bluetooth Assigned Numbers.
    static func majorClass(_ value: UInt32) -> MajorClass {
        switch value {
        case 0x01: .computer
        case 0x02: .phone
        case 0x03: .network
        case 0x04: .audio
        case 0x05: .peripheral
        case 0x06: .imaging
        case 0x07: .wearable
        case 0x08: .toy
        case 0x09: .health
        default: .other
        }
    }
}

public struct BluetoothDevicesPayload: EventPayload, Equatable {
    public let poweredOn: Bool
    /// Ordered by address.
    public let devices: [BluetoothDevice]

    public static var schema: TypeSchema {
        .named(
            "BluetoothDevices",
            ObjectSchema([
                .field("poweredOn", Bool.self, doc: "Whether Bluetooth is on."),
                .field(
                    "devices", [BluetoothDevice].self,
                    doc: "Paired devices, connected or not, ordered by address."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                poweredOn: true,
                devices: [
                    BluetoothDevice(
                        address: "a4-83-e7-12-34-56", name: "AirPods Pro", connected: true, paired: true,
                        majorClass: .audio),
                    BluetoothDevice(
                        address: "f0-b3-ec-01-02-03", name: "Magic Keyboard", connected: false, paired: true,
                        majorClass: .peripheral),
                ]),
            Self(poweredOn: false, devices: []),
        ]
    }

    /// Main thread: IOBluetooth delivers notifications on the run loop of
    /// the thread that registered them, and is used from that thread only.
    static func read() -> Self {
        let powered = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let devices = paired.compactMap { device -> BluetoothDevice? in
            guard let address = device.addressString else { return nil }
            return BluetoothDevice(
                address: address, name: device.name, connected: device.isConnected(),
                paired: device.isPaired(), majorClass: BluetoothDevice.majorClass(device.deviceClassMajor))
        }
        return Self(poweredOn: powered, devices: devices.sorted { $0.address < $1.address })
    }
}

public enum BluetoothDevicesEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "bluetooth.devices",
        "A paired Bluetooth device connected or disconnected; pairing changes and Bluetooth being turned on or off are noticed within \(NumberBounds.format(BluetoothSource.pollInterval)) seconds. The current state is delivered first. Devices that are not paired with the Mac are not reported.",
        mechanism: .push, semantics: .state, loss: .coalesced, permission: .required(.bluetooth),
        observation: .named,
        source:
            "IOBluetoothDevice connect and disconnect notifications, pairedDevices; IOBluetoothHostController powerState (checked every \(NumberBounds.format(BluetoothSource.pollInterval)) s)"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<BluetoothDevicesPayload>
    ) throws -> any EventSource {
        BluetoothSource(emit: emit)
    }
}

/// Registers IOBluetooth notifications on the main thread, which the daemon
/// keeps in `CFRunLoopRun`; reads happen there too.
final class BluetoothSource: NSObject, EventSource, @unchecked Sendable {
    static let pollInterval = 15.0

    private let reporter: StateReporter<BluetoothDevicesPayload>
    /// Main thread only.
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private let running = Atomic<Bool>(false)
    private var poll: PollingSource?

    init(emit: Emitter<BluetoothDevicesPayload>) {
        reporter = StateReporter(emit)
    }

    func start() throws {
        running.store(true, ordering: .releasing)
        DispatchQueue.main.async {
            guard self.running.load(ordering: .acquiring) else { return }
            self.connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: self,
                selector: #selector(self.connected(_:device:)))
            self.report()
        }
        let poll = PollingSource(label: "bluetooth", interval: Self.pollInterval, fireImmediately: false) {
            [weak self] in
            DispatchQueue.main.async { self?.report() }
        }
        self.poll = poll
        try poll.start()
    }

    func stop() {
        guard running.exchange(false, ordering: .acquiring) else { return }
        poll?.stop()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            self.connectNotification?.unregister()
            self.connectNotification = nil
            for notification in self.disconnectNotifications.values { notification.unregister() }
            self.disconnectNotifications = [:]
            finished.signal()
        }
        // Not when called on the main thread itself, which would deadlock.
        if !Thread.isMainThread { finished.wait() }
    }

    /// Main thread. Devices connected before the source started get their
    /// disconnect notification here, since no connect notification names them.
    private func report() {
        guard running.load(ordering: .acquiring) else { return }
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where device.isConnected() {
            watchDisconnect(of: device)
        }
        reporter.report(BluetoothDevicesPayload.read)
    }

    private func watchDisconnect(of device: IOBluetoothDevice) {
        guard let address = device.addressString, disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(disconnected(_:device:)))
    }

    @objc private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        watchDisconnect(of: device)
        report()
    }

    @objc private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString { disconnectNotifications.removeValue(forKey: address)?.unregister() }
        report()
    }
}
