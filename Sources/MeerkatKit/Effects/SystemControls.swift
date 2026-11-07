import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CoreServices
import CoreWLAN
import DiskArbitration
import Foundation
import IOKit.pwr_mgt

/// The macOS calls behind the tier A and B effects (docs/design/effects.md).
///
/// Grants, targets and request limits are the daemon's to check before it
/// calls here; these only act, and say plainly when macOS refuses. Tests use
/// a recording fake, so they never change the machine they run on.
public protocol SystemControls: Sendable {
    /// A power assertion that macOS releases after `timeout` seconds, or when
    /// this process exits. Returns its id.
    func preventSleep(name: String, reason: String, display: Bool, timeout: Double) throws -> UInt32
    func allowSleep(_ assertion: UInt32)

    func setDefaultAudioDevice(uid: String, scope: AudioScope) throws
    func setVolume(_ volume: Double, scope: AudioScope, device uid: String?) throws
    func setMute(_ muted: Bool, scope: AudioScope, device uid: String?) throws

    func openApplication(bundleId: String, activate: Bool) async throws
    func control(bundleId: String, action: AppAction) async throws
    func open(_ url: URL) async throws

    func ejectVolume(path: String) async throws
    /// Returns where the item is in the Trash.
    func trash(path: String) throws -> String
    func setTags(path: String, tags: [String]) throws

    func readDefault(domain: String, key: String) throws -> JSONValue?
    func writeDefault(domain: String, key: String, value: JSONValue) throws
    func deleteDefault(domain: String, key: String) throws

    func setWiFiPower(_ on: Bool) throws

    func readClipboard() async -> String?
    func writeClipboard(_ text: String) async

    /// The application's windows, front to back.
    func windows(bundleId: String) throws -> [WindowInfo]
    func setWindow(_ change: WindowChange) throws

    func setDarkMode(_ on: Bool) async throws
}

public enum AudioScope: String, Sendable, CaseIterable, SchemaDescribed {
    case output, input
}

public enum AppAction: Sendable, Equatable {
    case activate, hide, unhide
    case quit(force: Bool)
}

public struct WindowInfo: Sendable, Equatable, Codable {
    public let index: Int
    public let title: String?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let minimized: Bool
    public let main: Bool

    public init(
        index: Int, title: String?, x: Double, y: Double, width: Double, height: Double, minimized: Bool, main: Bool
    ) {
        self.index = index
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.minimized = minimized
        self.main = main
    }
}

public struct WindowChange: Sendable, Equatable {
    public let bundleId: String
    public let index: Int
    public let x: Double?
    public let y: Double?
    public let width: Double?
    public let height: Double?
    public let minimized: Bool?
    public let raise: Bool

    public init(
        bundleId: String, index: Int, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil,
        minimized: Bool? = nil, raise: Bool = false
    ) {
        self.bundleId = bundleId
        self.index = index
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.minimized = minimized
        self.raise = raise
    }
}

/// macOS refused, or the target was not there. The message is the rule's to
/// read.
public struct SystemControlError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - macOS

public struct MacSystemControls: SystemControls {
    public init() {}

    // MARK: Power

    public func preventSleep(name: String, reason: String, display: Bool, timeout: Double) throws -> UInt32 {
        // IOPMLib's assertion type and timeout action constants are CFSTR
        // macros, which Swift does not import; these are their values.
        let type = display ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            type as CFString, name as CFString, reason as CFString, nil, nil, timeout,
            "TimeoutActionRelease" as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw SystemControlError("IOPMAssertionCreateWithDescription failed (\(String(format: "0x%08x", result)))")
        }
        return id
    }

    public func allowSleep(_ assertion: UInt32) {
        IOPMAssertionRelease(assertion)
    }

    // MARK: Audio

    private typealias P = CoreAudioProperties

    private static func defaultSelector(_ scope: AudioScope) -> AudioObjectPropertySelector {
        scope == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }

    private static func halScope(_ scope: AudioScope) -> AudioObjectPropertyScope {
        scope == .output ? P.output : P.input
    }

    /// The device with this UID, or the current default for `scope`.
    private static func device(_ uid: String?, scope: AudioScope) throws -> AudioObjectID {
        if let uid {
            guard let id = P.devices()?.first(where: { P.string($0, kAudioDevicePropertyDeviceUID) == uid }) else {
                throw SystemControlError("no audio device has UID \(uid)")
            }
            return id
        }
        guard let id = P.uint32(P.system, defaultSelector(scope)), id != kAudioObjectUnknown else {
            throw SystemControlError("there is no default \(scope.rawValue) device")
        }
        return id
    }

    private static func set<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
        _ value: T, _ what: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(object, &address),
            AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue
        else {
            throw SystemControlError("this device's \(what) cannot be changed")
        }
        let status = withUnsafeBytes(of: value) { bytes in
            guard let base = bytes.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(bytes.count), base)
        }
        guard status == noErr else { throw SystemControlError("setting the \(what) failed (OSStatus \(status))") }
    }

    public func setDefaultAudioDevice(uid: String, scope: AudioScope) throws {
        let id = try Self.device(uid, scope: scope)
        guard (P.channels(id, Self.halScope(scope)) ?? 0) > 0 else {
            throw SystemControlError("\(uid) has no \(scope.rawValue) channels")
        }
        try Self.set(P.system, Self.defaultSelector(scope), kAudioObjectPropertyScopeGlobal, id, "default device")
    }

    public func setVolume(_ volume: Double, scope: AudioScope, device uid: String?) throws {
        // The virtual main volume is what the system volume control sets,
        // also on devices that only have per-channel volume.
        try Self.set(
            try Self.device(uid, scope: scope), kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            Self.halScope(scope), Float32(volume), "volume")
    }

    public func setMute(_ muted: Bool, scope: AudioScope, device uid: String?) throws {
        try Self.set(
            try Self.device(uid, scope: scope), kAudioDevicePropertyMute, Self.halScope(scope), UInt32(muted ? 1 : 0),
            "mute")
    }

    // MARK: Applications and URLs

    public func openApplication(bundleId: String, activate: Bool) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw SystemControlError("no application with bundle identifier \(bundleId) is installed")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw SystemControlError("opening \(bundleId) failed: \(error.localizedDescription)")
        }
    }

    public func control(bundleId: String, action: AppAction) async throws {
        try await MainActor.run {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            guard !running.isEmpty else { throw SystemControlError("\(bundleId) is not running") }
            for app in running {
                switch action {
                // Each returns whether the request was sent; an app that
                // ignores it is not an error here.
                case .activate: _ = app.activate()
                case .hide: _ = app.hide()
                case .unhide: _ = app.unhide()
                case .quit(let force): _ = force ? app.forceTerminate() : app.terminate()
                }
            }
        }
    }

    public func open(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw SystemControlError("no application opened \(url.absoluteString)") }
    }

    // MARK: Volumes and files

    public func ejectVolume(path: String) async throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw SystemControlError("DiskArbitration is not available")
        }
        let queue = DispatchQueue(label: "com.gkze.meerkat.eject")
        DASessionSetDispatchQueue(session, queue)
        defer { DASessionSetDispatchQueue(session, nil) }
        guard
            let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault, session, URL(fileURLWithPath: path, isDirectory: true) as CFURL)
        else {
            throw SystemControlError("\(path) is not a mounted volume")
        }
        guard EjectTarget(description: DADiskCopyDescription(disk) as? [CFString: Any] ?? [:]).isAllowed else {
            throw SystemControlError("\(path) is on an internal disk; only removable or external volumes are ejected")
        }
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        try await DiskOperation.run("unmounting \(path)") { context in
            DADiskUnmount(
                whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                { _, dissenter, context in DiskOperation.finish(context, dissenter) }, context)
        }
        try await DiskOperation.run("ejecting \(path)") { context in
            DADiskEject(
                whole, DADiskEjectOptions(kDADiskEjectOptionDefault),
                { _, dissenter, context in DiskOperation.finish(context, dissenter) }, context)
        }
    }

    public func trash(path: String) throws -> String {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        } catch {
            throw SystemControlError("moving \(path) to the Trash failed: \(error.localizedDescription)")
        }
        return result?.path ?? ""
    }

    public func setTags(path: String, tags: [String]) throws {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.tagNames = tags
        do {
            try url.setResourceValues(values)
        } catch {
            throw SystemControlError("setting tags on \(path) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Defaults

    public func readDefault(domain: String, key: String) throws -> JSONValue? {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { return nil }
        // Strictly: a rule may write what it read back, so a value with any
        // part JSON cannot hold (a non-finite number) is refused whole, not
        // shortened, and not mistaken for absent.
        guard let json = JSONValue(propertyList: value, strict: true) else {
            throw SystemControlError("\(domain) \(key) holds a value JSON cannot represent")
        }
        return json
    }

    public func writeDefault(domain: String, key: String, value: JSONValue) throws {
        guard let propertyList = value.propertyList else {
            throw SystemControlError("a user default cannot hold null; use defaults.delete")
        }
        CFPreferencesSetAppValue(key as CFString, propertyList as CFPropertyList, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            throw SystemControlError("writing \(domain) failed")
        }
    }

    public func deleteDefault(domain: String, key: String) throws {
        CFPreferencesSetAppValue(key as CFString, nil, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            throw SystemControlError("writing \(domain) failed")
        }
    }

    // MARK: Wi-Fi

    public func setWiFiPower(_ on: Bool) throws {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw SystemControlError("this Mac has no Wi-Fi interface")
        }
        do {
            try interface.setPower(on)
        } catch {
            throw SystemControlError("turning Wi-Fi \(on ? "on" : "off") failed: \(error.localizedDescription)")
        }
    }

    // MARK: Clipboard

    public func readClipboard() async -> String? {
        await MainActor.run { NSPasteboard.general.string(forType: .string) }
    }

    public func writeClipboard(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Windows (Accessibility)

    private static func application(_ bundleId: String) throws -> AXUIElement {
        guard
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first(where: { !$0.isTerminated })
        else {
            throw SystemControlError("\(bundleId) is not running")
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func cfBoolean(_ flag: Bool) -> CFBoolean { flag ? kCFBooleanTrue : kCFBooleanFalse }

    /// A point or size attribute; nil when it is absent or not an AXValue.
    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    private static func axWindows(_ bundleId: String) throws -> [AXUIElement] {
        let app = try application(bundleId)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            throw SystemControlError("reading \(bundleId)'s windows failed (AXError \(result.rawValue))")
        }
        return windows
    }

    public func windows(bundleId: String) throws -> [WindowInfo] {
        try Self.axWindows(bundleId).enumerated().map { index, window in
            var point = CGPoint.zero
            var size = CGSize.zero
            if let value = Self.axValue(window, kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &point) }
            if let value = Self.axValue(window, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
            return WindowInfo(
                index: index, title: Self.attribute(window, kAXTitleAttribute) as? String,
                x: point.x, y: point.y, width: size.width, height: size.height,
                minimized: Self.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                main: Self.attribute(window, kAXMainAttribute) as? Bool ?? false)
        }
    }

    public func setWindow(_ change: WindowChange) throws {
        let windows = try Self.axWindows(change.bundleId)
        guard windows.indices.contains(change.index) else {
            throw SystemControlError(
                "\(change.bundleId) has \(windows.count) windows; there is no index \(change.index)")
        }
        let window = windows[change.index]
        func set(_ name: String, _ value: CFTypeRef) throws {
            let result = AXUIElementSetAttributeValue(window, name as CFString, value)
            guard result == .success else {
                throw SystemControlError("setting \(name) failed (AXError \(result.rawValue))")
            }
        }
        if let minimized = change.minimized { try set(kAXMinimizedAttribute, Self.cfBoolean(minimized)) }
        if change.x != nil || change.y != nil {
            var current = CGPoint.zero
            if let value = Self.axValue(window, kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &current) }
            var point = CGPoint(x: change.x ?? current.x, y: change.y ?? current.y)
            if let value = AXValueCreate(.cgPoint, &point) { try set(kAXPositionAttribute, value) }
        }
        if change.width != nil || change.height != nil {
            var current = CGSize.zero
            if let value = Self.axValue(window, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &current) }
            var size = CGSize(width: change.width ?? current.width, height: change.height ?? current.height)
            if let value = AXValueCreate(.cgSize, &size) { try set(kAXSizeAttribute, value) }
        }
        if change.raise {
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            guard result == .success else {
                throw SystemControlError("raising the window failed (AXError \(result.rawValue))")
            }
        }
    }

    // MARK: Appearance (Apple Events)

    public func setDarkMode(_ on: Bool) async throws {
        try await Self.requestAutomation(of: "com.apple.systemevents", name: "System Events")
        // A fixed script: the effect names the action, never script text
        // (docs/design/effects.md, "Apple Events as fixed actions").
        let source =
            "tell application id \"com.apple.systemevents\" to tell appearance preferences to set dark mode to \(on)"
        let failure: String? = await MainActor.run {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return nil }
            if error[NSAppleScript.errorNumber] as? Int == -1743 {
                return
                    "Meerkat may not control System Events: turn on System Events under Meerkat in System Settings › Privacy & Security › Automation"
            }
            return "System Events refused: \(error[NSAppleScript.errorMessage] as? String ?? "\(error)")"
        }
        if let failure { throw SystemControlError(failure) }
    }

    private static func requestAutomation(of bundleId: String, name: String) async throws {
        switch await AutomationPermission.request(bundleId) {
        case .granted:
            return
        case .denied:
            throw SystemControlError(
                "Meerkat may not control \(name): turn on \(name) under Meerkat in System Settings › Privacy & Security › Automation, or allow it from Meerkat › Settings"
            )
        case .notDetermined:
            // A background process cannot raise the prompt; only the app can.
            throw SystemControlError(
                "Meerkat has not been allowed to control \(name): open Meerkat › Settings › Automation and click Allow")
        case .unavailable(let status):
            throw SystemControlError("asking to control \(name) failed (OSStatus \(status))")
        }
    }
}

// MARK: - Automation

/// Whether Meerkat may send Apple Events to an app (Privacy & Security ›
/// Automation).
///
/// macOS decides for the app a process belongs to: meerkatd's requests are
/// Meerkat's (`com.gkze.meerkat`), so one decision covers the app and the
/// daemon. Only a foreground app may raise the prompt; for meerkatd, macOS
/// refuses without asking ("Policy disallows prompt"), so the app asks on
/// the daemon's behalf (Settings › Automation).
public enum AutomationPermission {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// Nobody has decided; only the app can ask.
        case notDetermined
        /// The check itself failed, with this OSStatus.
        case unavailable(Int32)
    }

    /// The decision, without prompting.
    public static func status(_ bundleId: String) async -> Status {
        await determine(bundleId, ask: false)
    }

    /// The decision, asking the user when nobody has decided and this
    /// process may prompt. Waits for the answer.
    public static func request(_ bundleId: String) async -> Status {
        await determine(bundleId, ask: true)
    }

    private static func determine(_ bundleId: String, ask: Bool) async -> Status {
        // The check needs the target running; start it in the background.
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        // It blocks until a prompt is answered, so it runs off the
        // concurrency pool.
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<OSStatus, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
                continuation.resume(
                    returning: AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask))
            }
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unavailable(status)
        }
    }
}

// MARK: - DiskArbitration

/// What decides whether `volumes.eject` may act on a volume, from its
/// DiskArbitration description: never one on an internal disk, unless its
/// media is removable or ejectable (a card in the built-in reader). A fact
/// the description leaves out counts as internal and fixed, the side that
/// refuses. The one rule that keeps the effect off the boot disk, kept apart
/// from the call so it can be checked without a disk.
struct EjectTarget: Equatable {
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool

    init(description: [CFString: Any]) {
        isInternal = description[kDADiskDescriptionDeviceInternalKey] as? Bool ?? true
        isRemovable = description[kDADiskDescriptionMediaRemovableKey] as? Bool ?? false
        isEjectable = description[kDADiskDescriptionMediaEjectableKey] as? Bool ?? false
    }

    var isAllowed: Bool { !isInternal || isRemovable || isEjectable }
}

/// Bridges one DiskArbitration request, which reports through a C callback,
/// to `async`.
private final class DiskOperation: @unchecked Sendable {
    private let continuation: CheckedContinuation<Void, any Error>
    private let what: String

    private init(_ continuation: CheckedContinuation<Void, any Error>, what: String) {
        self.continuation = continuation
        self.what = what
    }

    static func run(_ what: String, start: (UnsafeMutableRawPointer) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            start(Unmanaged.passRetained(DiskOperation(continuation, what: what)).toOpaque())
        }
    }

    /// Called once per request, from the session's queue.
    static func finish(_ context: UnsafeMutableRawPointer?, _ dissenter: DADissenter?) {
        guard let context else { return }
        let operation = Unmanaged<DiskOperation>.fromOpaque(context).takeRetainedValue()
        if let dissenter {
            let reason = DADissenterGetStatusString(dissenter) as String? ?? "status \(DADissenterGetStatus(dissenter))"
            operation.continuation.resume(throwing: SystemControlError("\(operation.what) failed: \(reason)"))
        } else {
            operation.continuation.resume()
        }
    }
}
