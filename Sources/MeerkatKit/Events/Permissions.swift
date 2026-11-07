import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CoreLocation
import Foundation

// The one place that knows how each TCC permission is checked and requested.
//
// Grants belong to the code identity of the responsible process: for the
// daemon that is the signed Meerkat.app bundle, so a grant survives
// rebuilds signed by the same team and is lost by an ad-hoc build.
//
// Requests happen only from a source's `start`, which runs only when a rule
// subscribes to an event that needs the permission.

extension EventDescriptor.Permission {
    /// Why a client may not sample `kind`, or nil when `status` is granted. A
    /// source would ask when it starts, and a client must never cause that
    /// prompt.
    public func refusal(for kind: String, status: Status) -> String? {
        status == .granted
            ? nil
            : "\(kind) needs the \(rawValue) permission, which Meerkat does not have; grant it in \(settingsPane)"
    }

    /// Where the user grants it.
    public var settingsPane: String {
        switch self {
        case .accessibility: "System Settings › Privacy & Security › Accessibility"
        case .inputMonitoring: "System Settings › Privacy & Security › Input Monitoring"
        case .location: "System Settings › Privacy & Security › Location Services"
        case .bluetooth: "System Settings › Privacy & Security › Bluetooth"
        }
    }

    /// The Info.plist key macOS requires before it will ask; without it the
    /// request fails (Location) or the process is killed (Bluetooth).
    var usageDescriptionKey: String? {
        switch self {
        case .accessibility, .inputMonitoring: nil
        case .location: "NSLocationUsageDescription"
        case .bluetooth: "NSBluetoothAlwaysUsageDescription"
        }
    }

    public enum Status: String, Sendable, Codable, CaseIterable, SchemaDescribed {
        case granted
        /// Never asked; `request` shows the system prompt.
        case notDetermined
        /// Refused or turned off; only the user can change it in Settings.
        case denied
        /// This process cannot ask: it has no bundle with the required
        /// usage description (a test binary, for example).
        case unavailable
    }

    /// Reads a status. The daemon's parts take one, because what a process
    /// reads depends on what launched it (`status` is the real answer).
    public typealias StatusReader = @Sendable (EventDescriptor.Permission) -> Status

    /// The current status, without prompting.
    public var status: Status {
        if let key = usageDescriptionKey, Bundle.main.object(forInfoDictionaryKey: key) == nil {
            return .unavailable
        }
        switch self {
        case .accessibility:
            // Accessibility has no "not determined": untrusted is untrusted.
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .denied
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        }
    }

    /// Throws unless granted. When the user has not refused yet, asks first:
    /// Accessibility and Input Monitoring add Meerkat to their list in
    /// Settings (and show a prompt once), so the grant takes effect the next
    /// time the source starts, after `meerkat rules reload`.
    ///
    /// Location and Bluetooth are asked for by the sources themselves, which
    /// own the manager objects whose lifetime the prompt depends on.
    func require(for event: String) throws {
        switch status {
        case .granted:
            return
        case .unavailable:
            throw EventError.sourceUnavailable(
                "\(event) needs the \(rawValue) permission, which this process cannot request (no \(usageDescriptionKey ?? "bundle") in its Info.plist); run it from the installed Meerkat.app"
            )
        case .notDetermined, .denied:
            switch self {
            case .accessibility:
                // The value of kAXTrustedCheckOptionPrompt, a C global Swift
                // 6 will not read from a nonisolated context.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .inputMonitoring:
                _ = CGRequestListenEventAccess()
            case .location, .bluetooth:
                if status == .notDetermined { return }
            }
            throw EventError.sourceUnavailable(
                "\(event) needs the \(rawValue) permission: enable Meerkat in \(settingsPane), then subscribe again (for rules, `meerkat rules reload`)"
            )
        }
    }
}
