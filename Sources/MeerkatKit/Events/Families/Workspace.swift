import AppKit
import CoreGraphics
import Foundation

// Events NSWorkspace posts on its own notification center: applications,
// Spaces, sleep and wake, displays, the login session, volumes and display
// accessibility options.
//
// Delivery contract: NSWorkspace posts these through the main run loop. They
// arrive (on the main thread, through `queue: nil` observers) only while the
// host process runs the main CFRunLoop, as `meerkatd` does with
// `CFRunLoopRun()`. A process that parks its main thread in `dispatchMain()`
// or blocks it never receives them; this was observed with app launch and
// volume notifications on macOS 27.

/// One source per NSWorkspace notification name.
private func workspaceSource(
    _ name: Notification.Name,
    handler: @escaping @Sendable (Notification) -> Void
) -> NotificationSource {
    NotificationSource(center: NSWorkspace.shared.notificationCenter, names: [name], handler: handler)
}

/// A file URL's path without the trailing slash that directory URLs (bundles,
/// mount points) carry, so paths compare equal to the ones rules write.
private func fileSystemPath(_ url: URL) -> String {
    withoutTrailingSlash(url.path(percentEncoded: false))
}

// MARK: - app.*

/// The application a workspace notification is about.
public struct ApplicationPayload: NotificationPayload, Equatable {
    public enum ActivationPolicy: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        /// Appears in the Dock and may have a user interface.
        case regular
        /// No Dock icon; may show windows and menus (menu bar extras).
        case accessory
        /// No Dock icon and no user interface.
        case prohibited
    }

    public let pid: Int32
    public let bundleId: String?
    public let name: String?
    /// The executable inside the bundle.
    public let path: String?
    public let bundlePath: String?
    /// Absent for a policy this build does not know.
    public let activationPolicy: ActivationPolicy?

    public static var schema: TypeSchema {
        .named(
            "Application",
            ObjectSchema([
                .field("pid", Int32.self),
                .optional("bundleId", String.self, doc: "CFBundleIdentifier; absent for an app without one."),
                .optional("name", String.self, doc: "Localized display name."),
                .optional("path", String.self, doc: "The executable."),
                .optional("bundlePath", String.self, doc: "The .app bundle; absent for an unbundled app."),
                .optional(
                    "activationPolicy", ActivationPolicy.self,
                    doc: "regular (Dock icon), accessory (menu bar extra) or prohibited (no UI)."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                pid: 812, bundleId: "com.apple.TextEdit", name: "TextEdit",
                path: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
                bundlePath: "/System/Applications/TextEdit.app", activationPolicy: .regular),
            Self(pid: 901, bundleId: nil, name: nil, path: nil, bundlePath: nil, activationPolicy: nil),
        ]
    }
}

extension ApplicationPayload {
    /// The payload for a notification carrying `applicationUserInfoKey`;
    /// nil when it carries none.
    public init?(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return nil }
        self.init(application)
    }

    init(_ application: NSRunningApplication) {
        let policy: ActivationPolicy? =
            switch application.activationPolicy {
            case .regular: .regular
            case .accessory: .accessory
            case .prohibited: .prohibited
            @unknown default: nil
            }
        self.init(
            pid: application.processIdentifier,
            bundleId: application.bundleIdentifier,
            name: application.localizedName,
            path: application.executableURL.map(fileSystemPath),
            bundlePath: application.bundleURL.map(fileSystemPath),
            activationPolicy: policy)
    }
}

/// A payload read from one notification.
public protocol NotificationPayload: EventPayload {
    /// Nil when the notification does not carry what the payload reports:
    /// such a notification has nothing to report, and emits nothing.
    init?(_ notification: Notification)
}

/// A kind fed by one `NSWorkspace` notification.
public protocol WorkspaceEventKind: EventKind where Payload: NotificationPayload, Parameters == NoParameters {
    static var notification: Notification.Name { get }
}

extension WorkspaceEventKind {
    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<Payload>
    ) throws -> any EventSource {
        workspaceSource(notification) { notification in
            if let payload = Payload(notification) { emit(payload) }
        }
    }
}

/// The six application events share their payload.
public protocol ApplicationEventKind: WorkspaceEventKind where Payload == ApplicationPayload {}

private let notApplicationProcesses =
    "Command-line tools and daemons are not reported; use process.spawned and process.exited for those."

public enum AppLaunchedEvent: ApplicationEventKind {
    public static let notification = NSWorkspace.didLaunchApplicationNotification
    public static let descriptor = EventDescriptor(
        "app.launched",
        "An application finished launching. \(notApplicationProcesses)",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "NSWorkspace.didLaunchApplicationNotification"
    )
}

public enum AppTerminatedEvent: ApplicationEventKind {
    public static let notification = NSWorkspace.didTerminateApplicationNotification
    public static let descriptor = EventDescriptor(
        "app.terminated",
        "An application quit or was killed. The exit status is not reported. \(notApplicationProcesses)",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "NSWorkspace.didTerminateApplicationNotification"
    )
}

public enum AppActivatedEvent: ApplicationEventKind {
    public static let notification = NSWorkspace.didActivateApplicationNotification
    public static let descriptor = EventDescriptor(
        "app.activated",
        "An application became the active (frontmost) application. Which window has focus is not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "NSWorkspace.didActivateApplicationNotification"
    )
}

public enum AppDeactivatedEvent: ApplicationEventKind {
    public static let notification = NSWorkspace.didDeactivateApplicationNotification
    public static let descriptor = EventDescriptor(
        "app.deactivated",
        "An application stopped being the active application.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "NSWorkspace.didDeactivateApplicationNotification"
    )
}

public enum AppHiddenEvent: ApplicationEventKind {
    public static let notification = NSWorkspace.didHideApplicationNotification
    public static let descriptor = EventDescriptor(
        "app.hidden",
        "An application was hidden (Hide, Command-H). Minimized windows are not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "NSWorkspace.didHideApplicationNotification"
    )
}

public enum AppUnhiddenEvent: ApplicationEventKind {
    public static let notification = NSWorkspace.didUnhideApplicationNotification
    public static let descriptor = EventDescriptor(
        "app.unhidden",
        "A hidden application was shown again.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .processes,
        source: "NSWorkspace.didUnhideApplicationNotification"
    )
}

// MARK: - space.changed

public enum SpaceChangedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "space.changed",
        "The active Space (desktop) changed. Which Space, and on which display, is not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSWorkspace.activeSpaceDidChangeNotification"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<EmptyPayload>
    ) throws -> any EventSource {
        workspaceSource(NSWorkspace.activeSpaceDidChangeNotification) { _ in emit(EmptyPayload()) }
    }
}

// MARK: - power.sleep

public struct PowerSleepPayload: EventPayload, Equatable {
    public enum Phase: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case willSleep, didWake
    }

    public let phase: Phase

    public static var schema: TypeSchema {
        .named("PowerSleep", ObjectSchema([.field("phase", Phase.self)]))
    }

    public static var examples: [Self] { Phase.allCases.map(Self.init) }
}

public enum PowerSleepEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "power.sleep",
        "The system is about to sleep (willSleep) or has woken (didWake). Sleep is not delayed for handlers, so a willSleep handler may not finish before the system sleeps. Display-only sleep is display.sleep.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<PowerSleepPayload>
    ) throws -> any EventSource {
        NotificationSource(
            center: NSWorkspace.shared.notificationCenter,
            names: [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification]
        ) { notification in
            let phase: PowerSleepPayload.Phase =
                notification.name == NSWorkspace.willSleepNotification ? .willSleep : .didWake
            emit(PowerSleepPayload(phase: phase))
        }
    }
}

// MARK: - power.willPowerOff

public enum PowerWillPowerOffEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "power.willPowerOff",
        "The user asked to log out, restart or shut down. Which of the three, and whether it is later cancelled, is not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSWorkspace.willPowerOffNotification"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<EmptyPayload>
    ) throws -> any EventSource {
        workspaceSource(NSWorkspace.willPowerOffNotification) { _ in emit(EmptyPayload()) }
    }
}

// MARK: - display.sleep

public struct DisplaySleepPayload: EventPayload, Equatable {
    public let asleep: Bool

    public static var schema: TypeSchema {
        .named("DisplaySleep", ObjectSchema([.field("asleep", Bool.self)]))
    }

    public static var examples: [Self] { [Self(asleep: false), Self(asleep: true)] }
}

public enum DisplaySleepEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "display.sleep",
        "The displays went to sleep or woke. The main display's current state is delivered first. Screen lock and the screen saver are separate events.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, CGDisplayIsAsleep"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<DisplaySleepPayload>
    ) throws -> any EventSource {
        notificationStateSource(
            center: NSWorkspace.shared.notificationCenter,
            names: [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification],
            emit: emit,
            current: { DisplaySleepPayload(asleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0) },
            changed: { DisplaySleepPayload(asleep: $0.name == NSWorkspace.screensDidSleepNotification) }
        )
    }
}

// MARK: - session.active

public struct SessionActivePayload: EventPayload, Equatable {
    /// Whether this user's session is the one on the console.
    public let active: Bool

    public static var schema: TypeSchema {
        .named(
            "SessionActive",
            ObjectSchema([
                .field("active", Bool.self, doc: "Whether this user's session owns the console (screen, keyboard).")
            ]))
    }

    public static var examples: [Self] { [Self(active: true), Self(active: false)] }
}

public enum SessionActiveEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "session.active",
        "This user's login session became the console session or was switched away from (fast user switching). The current state is delivered first when the window server reports it; a process outside a window-server session gets no initial value. Screen lock is session.lock.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source:
            "NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification, CGSessionCopyCurrentDictionary"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<SessionActivePayload>
    ) throws -> any EventSource {
        notificationStateSource(
            center: NSWorkspace.shared.notificationCenter,
            names: [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification],
            emit: emit,
            current: currentSession,
            changed: { SessionActivePayload(active: $0.name == NSWorkspace.sessionDidBecomeActiveNotification) }
        )
    }

    /// `kCGSessionOnConsoleKey` of this process's window-server session; nil
    /// when the process has no session or the key is absent.
    @Sendable static func currentSession() -> SessionActivePayload? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        else { return nil }
        return SessionActivePayload(active: onConsole)
    }
}

// MARK: - volume.*

public struct VolumePayload: NotificationPayload, Equatable {
    /// The mount point, for example "/Volumes/Backup".
    public let path: String
    public let name: String?

    public static var schema: TypeSchema {
        .named(
            "Volume",
            ObjectSchema([
                .field("path", String.self, doc: "Mount point, for example \"/Volumes/Backup\"."),
                .optional("name", String.self, doc: "Localized volume name."),
            ]))
    }

    public static var examples: [Self] {
        [Self(path: "/Volumes/Backup", name: "Backup"), Self(path: "/Volumes/Untitled", name: nil)]
    }
}

extension VolumePayload {
    /// Nil when the notification has no volume URL, which the documented
    /// volume notifications always carry.
    public init?(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return nil }
        self.init(
            path: fileSystemPath(url),
            name: notification.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String)
    }
}

public struct VolumeRenamedPayload: NotificationPayload, Equatable {
    public let path: String
    public let name: String?
    public let oldPath: String?
    public let oldName: String?

    public static var schema: TypeSchema {
        .named(
            "VolumeRenamed",
            ObjectSchema([
                .field("path", String.self, doc: "New mount point."),
                .optional("name", String.self, doc: "New localized name."),
                .optional("oldPath", String.self, doc: "Previous mount point."),
                .optional("oldName", String.self, doc: "Previous localized name."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(path: "/Volumes/Archive", name: "Archive", oldPath: "/Volumes/Backup", oldName: "Backup"),
            Self(path: "/Volumes/Archive", name: nil, oldPath: nil, oldName: nil),
        ]
    }
}

extension VolumeRenamedPayload {
    public init?(_ notification: Notification) {
        guard let current = VolumePayload(notification) else { return nil }
        let info = notification.userInfo
        self.init(
            path: current.path, name: current.name,
            oldPath: (info?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL).map(fileSystemPath),
            oldName: info?[NSWorkspace.oldLocalizedVolumeNameUserInfoKey] as? String)
    }
}

/// Mounted, will-unmount and unmounted share their payload.
public protocol VolumeEventKind: WorkspaceEventKind where Payload == VolumePayload {}

public enum VolumeMountedEvent: VolumeEventKind {
    public static let notification = NSWorkspace.didMountNotification
    public static let descriptor = EventDescriptor(
        "volume.mounted",
        "A volume was mounted: a disk, a disk image (including ones hidden from Finder) or a network share. The device and file system are not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSWorkspace.didMountNotification"
    )
}

public enum VolumeWillUnmountEvent: VolumeEventKind {
    public static let notification = NSWorkspace.willUnmountNotification
    public static let descriptor = EventDescriptor(
        "volume.willUnmount",
        "A volume is about to be unmounted. Unmounting does not wait for handlers, and a forced unmount may skip this event.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSWorkspace.willUnmountNotification"
    )
}

public enum VolumeUnmountedEvent: VolumeEventKind {
    public static let notification = NSWorkspace.didUnmountNotification
    public static let descriptor = EventDescriptor(
        "volume.unmounted",
        "A volume was unmounted or ejected.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSWorkspace.didUnmountNotification"
    )
}

public enum VolumeRenamedEvent: WorkspaceEventKind {
    public typealias Payload = VolumeRenamedPayload
    public static let notification = NSWorkspace.didRenameVolumeNotification
    public static let descriptor = EventDescriptor(
        "volume.renamed",
        "A mounted volume was renamed; its mount point usually changes with it.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSWorkspace.didRenameVolumeNotification"
    )
}

// MARK: - accessibility.display

public struct AccessibilityDisplayPayload: EventPayload, Equatable {
    public let reduceMotion: Bool
    public let reduceTransparency: Bool
    public let increaseContrast: Bool
    public let differentiateWithoutColor: Bool
    public let invertColors: Bool

    static func current() -> AccessibilityDisplayPayload {
        let workspace = NSWorkspace.shared
        return AccessibilityDisplayPayload(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
            invertColors: workspace.accessibilityDisplayShouldInvertColors
        )
    }

    public static var schema: TypeSchema {
        .named(
            "AccessibilityDisplay",
            ObjectSchema([
                .field("reduceMotion", Bool.self),
                .field("reduceTransparency", Bool.self),
                .field("increaseContrast", Bool.self),
                .field("differentiateWithoutColor", Bool.self),
                .field("invertColors", Bool.self),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                reduceMotion: false, reduceTransparency: false, increaseContrast: false,
                differentiateWithoutColor: false, invertColors: false),
            Self(
                reduceMotion: true, reduceTransparency: true, increaseContrast: false,
                differentiateWithoutColor: true, invertColors: false),
        ]
    }
}

public enum AccessibilityDisplayEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "accessibility.display",
        "A display accessibility option changed (reduce motion, reduce transparency, increase contrast, differentiate without color, invert colors). All five current values are delivered first and with every change; other accessibility settings are not reported.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "NSWorkspace.accessibilityDisplayOptionsDidChangeNotification"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<AccessibilityDisplayPayload>
    ) throws -> any EventSource {
        notificationStateSource(
            center: NSWorkspace.shared.notificationCenter,
            names: [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification],
            emit: emit,
            current: { AccessibilityDisplayPayload.current() },
            changed: { _ in AccessibilityDisplayPayload.current() }
        )
    }
}
