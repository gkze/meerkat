import AppKit
import ApplicationServices
import Foundation
import Synchronization

// MARK: - window.focused

public struct FocusedWindowPayload: EventPayload, Equatable {
    public struct App: Codable, Sendable, Equatable, SchemaDescribed {
        public let pid: Int32
        public let bundleId: String?
        public let name: String?

        public static var schema: TypeSchema {
            .named(
                "FocusedApp",
                ObjectSchema([
                    .field("pid", Int32.self),
                    .optional("bundleId", String.self),
                    .optional("name", String.self),
                ]))
        }
    }

    public struct Window: Codable, Sendable, Equatable, SchemaDescribed {
        public let title: String?
        public let role: String?
        public let subrole: String?
        public let x: Double?
        public let y: Double?
        public let width: Double?
        public let height: Double?
        public let minimized: Bool?
        public let fullScreen: Bool?

        public static var schema: TypeSchema {
            .named(
                "FocusedWindow",
                ObjectSchema([
                    .optional("title", String.self, doc: "Absent when the app gives the window no title."),
                    .optional("role", String.self, doc: "Accessibility role, normally \"AXWindow\"."),
                    .optional(
                        "subrole", String.self, doc: "e.g. \"AXStandardWindow\", \"AXDialog\", \"AXFloatingWindow\"."),
                    .optional(
                        "x", Double.self,
                        doc: "Left edge in global screen points, origin at the main display's top left."),
                    .optional("y", Double.self, doc: "Top edge in global screen points."),
                    .optional("width", Double.self),
                    .optional("height", Double.self),
                    .optional("minimized", Bool.self),
                    .optional("fullScreen", Bool.self),
                ]))
        }
    }

    public let app: App
    public let window: Window?

    public static var schema: TypeSchema {
        .named(
            "FocusedWindowState",
            ObjectSchema([
                .field("app", App.self, doc: "The frontmost application."),
                .optional(
                    "window", Window.self, doc: "Its focused window; absent when it has none (or does not answer)."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                app: App(pid: 812, bundleId: "com.apple.TextEdit", name: "TextEdit"),
                window: Window(
                    title: "notes.txt", role: "AXWindow", subrole: "AXStandardWindow", x: 120, y: 80,
                    width: 900, height: 640, minimized: false, fullScreen: false)),
            Self(app: App(pid: 391, bundleId: "com.apple.finder", name: "Finder"), window: nil),
        ]
    }
}

public enum FocusedWindowEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "window.focused",
        "The frontmost app, its focused window, or that window's title changed. The current state is delivered first. Position, size, minimized and full-screen are read at each change but moving or resizing alone does not produce an event. Some apps expose no windows to Accessibility (the Electron-based Claude desktop app, checked on macOS 27); for them `window` is absent. With no window open, Finder reports the desktop. Needs the Accessibility permission; window titles can contain document names and web page titles.",
        mechanism: .push, semantics: .state, loss: .coalesced, permission: .accessibility,
        observation: .named,
        source:
            "AXObserver kAXFocusedWindowChanged, kAXMainWindowChanged, kAXTitleChanged on the frontmost app; NSWorkspace.didActivateApplicationNotification"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<FocusedWindowPayload>
    ) throws -> any EventSource {
        AXFocusSource(emit: emit)
    }
}

/// Follows the frontmost application with one AXObserver at a time.
///
/// Accessibility calls are synchronous IPC into the target app, so they run
/// on a thread of this source's own (whose run loop hosts the observer) and
/// with a messaging timeout: an app that hangs delays only this source.
final class AXFocusSource: EventSource {
    static let messagingTimeout: Float = 0.5
    static let notifications = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXTitleChangedNotification,
    ]

    private let reporter: StateReporter<FocusedWindowPayload>
    private let context: Context
    private let thread = RunLoopThread(name: "accessibility")
    private let state = Mutex<State>(State())

    /// The workspace observer, and the AXObserver with the app element it
    /// watches (used only on the AX thread).
    private struct State {
        var workspaceToken: TokenBox?
        var observed: Observed?
    }

    private struct Observed: @unchecked Sendable {
        let app: NSRunningApplication
        let element: AXUIElement
        let observer: AXObserver
    }

    private struct TokenBox: @unchecked Sendable { let value: any NSObjectProtocol }
    private struct AppBox: @unchecked Sendable { let value: NSRunningApplication }

    /// The observer callback's context. Observers are removed on the AX
    /// thread in `stop`, before the source (which owns this) can go away.
    final class Context: Sendable {
        let changed: @Sendable () -> Void
        init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
    }

    private final class WeakBox: @unchecked Sendable {
        weak var value: AXFocusSource?
    }

    init(emit: Emitter<FocusedWindowPayload>) {
        reporter = StateReporter(emit)
        let box = WeakBox()
        context = Context { box.value?.report() }
        box.value = self
    }

    func start() throws {
        try EventDescriptor.Permission.accessibility.require(for: FocusedWindowEvent.descriptor.name)
        thread.start()
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let self
            else { return }
            let box = AppBox(value: app)
            self.thread.perform { [weak self] runLoop in self?.follow(box.value, on: runLoop) }
        }
        let tokenBox = TokenBox(value: token)
        state.withLock { $0.workspaceToken = tokenBox }
        if let front = NSWorkspace.shared.frontmostApplication.map({ AppBox(value: $0) }) {
            thread.perform { [weak self] runLoop in self?.follow(front.value, on: runLoop) }
        }
    }

    func stop() {
        if let token = state.withLock({ $0.workspaceToken.take() }) {
            NSWorkspace.shared.notificationCenter.removeObserver(token.value)
        }
        thread.stop { [self] runLoop in
            if let observed = state.withLock({ $0.observed.take() }) { Self.detach(observed, from: runLoop) }
        }
    }

    /// AX thread: observe `app` instead of the previous frontmost app.
    private func follow(_ app: NSRunningApplication, on runLoop: CFRunLoop) {
        if let previous = state.withLock({ $0.observed.take() }) { Self.detach(previous, from: runLoop) }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue().changed()
        }
        if AXObserverCreate(app.processIdentifier, callback, &created) == .success, let observer = created {
            let refcon = Unmanaged.passUnretained(context).toOpaque()
            for name in Self.notifications {
                // Fails for apps that are not accessible (some agents); the
                // focused-window read below still reports the app.
                _ = AXObserverAddNotification(observer, element, name as CFString, refcon)
            }
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            let observed = Observed(app: app, element: element, observer: observer)
            state.withLock { $0.observed = observed }
        }
        report(app: app, element: element)
    }

    private static func detach(_ observed: Observed, from runLoop: CFRunLoop) {
        for name in notifications {
            _ = AXObserverRemoveNotification(observed.observer, observed.element, name as CFString)
        }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observed.observer), .defaultMode)
    }

    /// AX thread, from an observer callback.
    private func report() {
        guard let observed = state.withLock({ $0.observed }) else { return }
        report(app: observed.app, element: observed.element)
    }

    private func report(app: NSRunningApplication, element: AXUIElement) {
        let payload = FocusedWindowPayload(
            app: .init(pid: app.processIdentifier, bundleId: app.bundleIdentifier, name: app.localizedName),
            window: Self.focusedWindow(of: element)
        )
        reporter.report { payload }
    }

    /// The focused window, else the main window, else the first window:
    /// some apps leave the focused-window attribute unset while one of
    /// theirs is frontmost.
    static func focusedWindow(of app: AXUIElement) -> FocusedWindowPayload.Window? {
        let windows: [AXUIElement]? = attribute(app, kAXWindowsAttribute)
        guard
            let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute)
                ?? attribute(app, kAXMainWindowAttribute) ?? windows?.first
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let position: AXValue? = attribute(window, kAXPositionAttribute)
        let extent: AXValue? = attribute(window, kAXSizeAttribute)
        let hasOrigin = position.map { AXValueGetValue($0, .cgPoint, &origin) } ?? false
        let hasSize = extent.map { AXValueGetValue($0, .cgSize, &size) } ?? false
        let title: String? = attribute(window, kAXTitleAttribute)
        return FocusedWindowPayload.Window(
            title: title.flatMap { $0.isEmpty ? nil : $0 },
            role: attribute(window, kAXRoleAttribute),
            subrole: attribute(window, kAXSubroleAttribute),
            x: hasOrigin ? Double(origin.x) : nil, y: hasOrigin ? Double(origin.y) : nil,
            width: hasSize ? Double(size.width) : nil, height: hasSize ? Double(size.height) : nil,
            minimized: attribute(window, kAXMinimizedAttribute),
            fullScreen: attribute(window, "AXFullScreen")
        )
    }

    /// One attribute, nil when missing, of another type, or the app timed out.
    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else {
            return nil
        }
        // A cast to a Core Foundation type always succeeds, whatever the
        // object is, so the type ID is what decides.
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? value as? T : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? value as? T : nil
        }
        if T.self == [AXUIElement].self {
            guard let array = value as? [AnyObject] else { return nil }
            return array.filter { CFGetTypeID($0) == AXUIElementGetTypeID() } as? T
        }
        return value as? T
    }
}
