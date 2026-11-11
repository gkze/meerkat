import Foundation

/// Every event kind the daemon offers. The list order is the order of
/// `meerkat events list` and of the generated TypeScript declarations.
public struct EventCatalog: Sendable {
    public let kinds: [AnyEventKind]
    private let byName: [String: AnyEventKind]

    public init(_ kinds: [AnyEventKind]) {
        self.kinds = kinds
        // Two kinds under one name would leave one unreachable and the
        // generated declarations describing the other.
        byName = Dictionary(kinds.map { ($0.name, $0) }) { first, _ in
            preconditionFailure("event kind \(first.name) declared twice")
        }
    }

    public func kind(named name: String) -> AnyEventKind? {
        byName[name]
    }

    public static let standard = EventCatalog([
        // memory, cpu, disk and network throughput
        AnyEventKind(MemoryPressureEvent.self),
        AnyEventKind(MemorySampleEvent.self),
        AnyEventKind(CPUSampleEvent.self),
        AnyEventKind(DiskSampleEvent.self),
        AnyEventKind(NetworkSampleEvent.self),
        AnyEventKind(NetworkFlowsEvent.self),
        // process
        AnyEventKind(ProcessSpawnedEvent.self),
        AnyEventKind(ProcessExitedEvent.self),
        AnyEventKind(ProcessExecEvent.self),
        AnyEventKind(ProcessHotEvent.self),
        AnyEventKind(ProcessTopEvent.self),
        AnyEventKind(ProcessListEvent.self),
        AnyEventKind(ProcessSampleEvent.self),
        // fs, volume, disk
        AnyEventKind(FSChangeEvent.self),
        AnyEventKind(FSChurnEvent.self),
        AnyEventKind(VolumeMountedEvent.self),
        AnyEventKind(VolumeWillUnmountEvent.self),
        AnyEventKind(VolumeUnmountedEvent.self),
        AnyEventKind(VolumeRenamedEvent.self),
        AnyEventKind(VolumeSpaceEvent.self),
        AnyEventKind(DiskAppearedEvent.self),
        AnyEventKind(DiskDisappearedEvent.self),
        // power, thermal, battery
        AnyEventKind(PowerSourceEvent.self),
        AnyEventKind(LowPowerModeEvent.self),
        AnyEventKind(PowerSleepEvent.self),
        AnyEventKind(PowerWillPowerOffEvent.self),
        AnyEventKind(ThermalStateEvent.self),
        AnyEventKind(ThermalPressureEvent.self),
        AnyEventKind(PowerAssertionsEvent.self),
        AnyEventKind(LidEvent.self),
        AnyEventKind(BatterySampleEvent.self),
        // display, session
        AnyEventKind(DisplaySleepEvent.self),
        AnyEventKind(DisplayReconfiguredEvent.self),
        AnyEventKind(SessionActiveEvent.self),
        AnyEventKind(SessionLockEvent.self),
        AnyEventKind(ScreensaverEvent.self),
        AnyEventKind(LoginSessionsEvent.self),
        // app, space
        AnyEventKind(AppLaunchedEvent.self),
        AnyEventKind(AppTerminatedEvent.self),
        AnyEventKind(AppActivatedEvent.self),
        AnyEventKind(AppDeactivatedEvent.self),
        AnyEventKind(AppHiddenEvent.self),
        AnyEventKind(AppUnhiddenEvent.self),
        AnyEventKind(SpaceChangedEvent.self),
        // window (Accessibility permission)
        AnyEventKind(FocusedWindowEvent.self),
        // network
        AnyEventKind(NetworkPathEvent.self),
        AnyEventKind(NetworkConfigurationEvent.self),
        AnyEventKind(HostNameEvent.self),
        AnyEventKind(NetworkLinkEvent.self),
        AnyEventKind(WiFiEvent.self),
        // audio, camera
        AnyEventKind(AudioDefaultDeviceEvent.self),
        AnyEventKind(AudioDevicesEvent.self),
        AnyEventKind(AudioInUseEvent.self),
        AnyEventKind(AudioVolumeEvent.self),
        AnyEventKind(CameraInUseEvent.self),
        // usb, hid, bluetooth
        AnyEventKind(USBAttachedEvent.self),
        AnyEventKind(USBDetachedEvent.self),
        AnyEventKind(HIDAttachedEvent.self),
        AnyEventKind(HIDDetachedEvent.self),
        AnyEventKind(BluetoothDevicesEvent.self),
        // time
        AnyEventKind(ClockSetEvent.self),
        AnyEventKind(TimeZoneEvent.self),
        AnyEventKind(DayChangedEvent.self),
        AnyEventKind(TimerEvent.self),
        // input, appearance, locale, pasteboard, idle
        AnyEventKind(InputSourceEvent.self),
        AnyEventKind(AppearanceThemeEvent.self),
        AnyEventKind(AccessibilityDisplayEvent.self),
        AnyEventKind(LocaleChangedEvent.self),
        AnyEventKind(PasteboardChangedEvent.self),
        AnyEventKind(InputIdleEvent.self),
        AnyEventKind(InputActivityEvent.self),
        // escape hatches: raw notifications, IOKit classes, the unified log
        AnyEventKind(DarwinNotificationEvent.self),
        AnyEventKind(DistributedNotificationEvent.self),
        AnyEventKind(IOKitAttachedEvent.self),
        AnyEventKind(IOKitDetachedEvent.self),
        AnyEventKind(LogEntryEvent.self),
        // the daemon itself
        AnyEventKind(MeerkatRuleEvent.self),
        AnyEventKind(MeerkatDroppedEvent.self),
        AnyEventKind(MeerkatNotificationEvent.self),
    ])
}
