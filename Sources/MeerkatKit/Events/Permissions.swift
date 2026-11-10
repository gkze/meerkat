import AppKit
import ApplicationServices
import CoreBluetooth
import CoreGraphics
import CoreLocation
import CoreServices
import Foundation

// The one place that knows how each TCC permission is checked and requested,
// and what a kind's `PermissionNeed` means for a subscription.
//
// Grants belong to the code identity of the responsible process: for the
// daemon that is the signed Meerkat.app bundle, so a grant survives
// rebuilds signed by the same team and is lost by an ad-hoc build.
//
// Requests happen only as a source starts, which happens only when
// something subscribes to a kind that needs the permission. Accessibility
// and Input Monitoring are asked for before the source exists, where every
// source is made (`NormalizedParameters.instantiate`, through
// `PermissionNeed.require`); Location and Bluetooth by the source itself,
// which owns the manager object whose lifetime the prompt depends on
// (`Permission.asksFromSource`).

extension EventDescriptor.PermissionNeed {
    /// What `meerkat events list`, `meerkat effects`, the app and the
    /// generated declarations say about it: the one wording, in lower case
    /// to sit in a list of traits; the app capitalises it as a sentence.
    public var note: String {
        switch without {
        case .refused: "needs \(permission.named)"
        case .reportsLess: "reports more with \(permission.named)"
        }
    }

    /// The gate before a source exists: throws when the subscription may
    /// not start. Asks first when Meerkat may still be granted it and the
    /// source is not the one to ask.
    func require(for kind: String) throws {
        switch without {
        case .reportsLess: return
        case .refused: try permission.require(for: kind)
        }
    }

    /// Why a client may not sample `kind` now, or nil. A client must never
    /// cause a prompt, so a source that would ask is refused too.
    public func clientRefusal(for kind: String, status: EventDescriptor.Permission.Status) -> String? {
        switch (without, status) {
        case (_, .granted), (.reportsLess, .denied), (.reportsLess, .unavailable): nil
        case (.reportsLess, .notDetermined):
            "\(kind) would ask for \(permission.named), which only a rule may cause; grant it in \(permission.settingsPane)"
        case (.refused, _):
            "\(kind) \(note), which Meerkat does not have; grant it in \(permission.settingsPane)"
        }
    }
}

extension EventDescriptor.Permission {
    /// The permission as System Settings names it: what every message
    /// about it says, never the raw value, which is for machines.
    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .location: "Location Services"
        case .bluetooth: "Bluetooth"
        }
    }

    /// The permission in a sentence.
    public var named: String { "the \(displayName) permission" }

    /// Where the user grants it.
    public var settingsPane: String { "System Settings › Privacy & Security › \(displayName)" }

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

    /// Whether the source asks for it as it starts, rather than the hub.
    var asksFromSource: Bool {
        switch self {
        case .accessibility, .inputMonitoring: false
        case .location, .bluetooth: true
        }
    }

    /// Throws unless granted, or not determined yet for a permission the
    /// source asks for itself. When the user has not refused yet, asks
    /// first: Accessibility and Input Monitoring add Meerkat to their list
    /// in Settings (and show a prompt once), so the grant takes effect the
    /// next time the source starts, after `meerkat rules reload`.
    fileprivate func require(for event: String) throws {
        switch status {
        case .granted:
            return
        case .unavailable:
            throw EventError.sourceUnavailable(
                "\(event) needs \(named), which this process cannot request (no \(usageDescriptionKey ?? "bundle") in its Info.plist); run it from the installed Meerkat.app"
            )
        case .notDetermined where asksFromSource:
            return
        case .notDetermined, .denied:
            switch self {
            case .accessibility:
                // The value of kAXTrustedCheckOptionPrompt, a C global Swift
                // 6 will not read from a nonisolated context.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .inputMonitoring:
                _ = CGRequestListenEventAccess()
            case .location, .bluetooth:
                break
            }
            throw EventError.sourceUnavailable(
                "\(event) needs \(named): enable Meerkat in \(settingsPane), then subscribe again (for rules, `meerkat rules reload`)"
            )
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
