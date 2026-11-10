import CoreGraphics
import Foundation
import Synchronization

// MARK: - input.activity

public struct InputActivityPayload: EventPayload, Equatable {
    public let keyPresses: Int
    public let clicks: Int
    public let scrolls: Int
    public let pointerDistance: Double
    public let seconds: Double

    public static var schema: TypeSchema {
        .named(
            "InputActivity",
            ObjectSchema([
                .field(
                    "keyPresses", Int.self, doc: "Keys pressed (key repeat included). Which keys is never observed."),
                .field("clicks", Int.self, doc: "Mouse and trackpad button presses, any button."),
                .field("scrolls", Int.self, doc: "Scroll events; one trackpad swipe produces many."),
                .field("pointerDistance", Double.self, doc: "Distance the pointer travelled, in screen points."),
                .field("seconds", Double.self, doc: "Length of the interval these counts cover."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(keyPresses: 312, clicks: 14, scrolls: 220, pointerDistance: 8_430.5, seconds: 60),
            Self(keyPresses: 0, clicks: 0, scrolls: 0, pointerDistance: 0, seconds: 60),
        ]
    }
}

public enum InputActivityEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 60.0
    public static let intervalRange = 1.0...3600.0

    public static let descriptor = EventDescriptor(
        "input.activity",
        "How much keyboard, mouse and trackpad input arrived during each interval: counts of key presses, clicks and scrolls, and pointer distance. The first report arrives one interval after subscribing. Key codes, characters and pointer positions are never kept or reported.",
        mechanism: .derived, semantics: .state, loss: .coalesced, permission: .required(.inputMonitoring),
        observation: .named,
        source: "CGEventTap (listen-only, session) for key down, mouse down, scroll wheel and mouse moved events"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<InputActivityEvent>, environment: SourceEnvironment,
        emit: Emitter<InputActivityPayload>
    ) throws -> any EventSource {
        InputActivitySource(interval: parameters.interval, emit: emit)
    }
}

/// A listen-only event tap on a thread of its own, counting into a tally
/// that a timer drains every interval.
final class InputActivitySource: EventSource {
    static let mask: CGEventMask = [
        CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
        .otherMouseDragged,
    ]
    .reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }

    private let thread = RunLoopThread(name: "input-activity")
    private let tally = Tally()
    private let tap = Mutex<TapBox?>(nil)
    private let timer: PollingSource

    private struct TapBox: @unchecked Sendable {
        let port: CFMachPort
        let source: CFRunLoopSource
    }

    /// Counts since the last drain. The tap callback runs on the tap thread;
    /// the timer drains on its own queue.
    final class Tally: Sendable {
        struct Counts {
            var keyPresses = 0, clicks = 0, scrolls = 0
            var distance = 0.0
            var lastLocation: CGPoint?
            var since = ContinuousClock.now
        }

        let counts = Mutex(Counts())
        /// Set once the tap exists, so the callback can re-enable it.
        let port = Mutex<PortBox?>(nil)

        struct PortBox: @unchecked Sendable { let value: CFMachPort }

        func record(_ type: CGEventType, at location: CGPoint) {
            counts.withLock { counts in
                switch type {
                case .keyDown: counts.keyPresses += 1
                case .leftMouseDown, .rightMouseDown, .otherMouseDown: counts.clicks += 1
                case .scrollWheel: counts.scrolls += 1
                default:
                    if let last = counts.lastLocation {
                        counts.distance += hypot(location.x - last.x, location.y - last.y)
                    }
                    counts.lastLocation = location
                }
            }
        }

        func drain() -> InputActivityPayload {
            counts.withLock { counts in
                let now = ContinuousClock.now
                let elapsed = now - counts.since
                let seconds = elapsed / .seconds(1)
                defer { counts = Counts(lastLocation: counts.lastLocation, since: now) }
                return InputActivityPayload(
                    keyPresses: counts.keyPresses, clicks: counts.clicks, scrolls: counts.scrolls,
                    pointerDistance: counts.distance, seconds: seconds)
            }
        }
    }

    init(interval: Double, emit: Emitter<InputActivityPayload>) {
        let tally = self.tally
        timer = PollingSource(label: "input-activity", interval: interval, fireImmediately: false) {
            emit(tally.drain())
        }
    }

    func start() throws {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tally = Unmanaged<Tally>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // The system turns a slow or interrupted tap off; a
                // listen-only tap adds no latency, so turn it back on.
                if let port = tally.port.withLock({ $0 }) { CGEvent.tapEnable(tap: port.value, enable: true) }
            default:
                tally.record(type, at: event.location)
            }
            return Unmanaged.passUnretained(event)
        }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: Self.mask, callback: callback,
                userInfo: Unmanaged.passUnretained(tally).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        else {
            throw EventError.sourceUnavailable(
                "input.activity: CGEventTapCreate failed; check that Meerkat is enabled in \(EventDescriptor.Permission.inputMonitoring.settingsPane)"
            )
        }
        let box = TapBox(port: port, source: source)
        tap.withLock { $0 = box }
        let portBox = Tally.PortBox(value: port)
        tally.port.withLock { $0 = portBox }
        thread.start()
        thread.perform { runLoop in CFRunLoopAddSource(runLoop, box.source, .commonModes) }
        _ = tally.drain()
        try timer.start()
    }

    func stop() {
        timer.stop()
        guard let box = tap.withLock({ $0.take() }) else { return }
        thread.stop { runLoop in
            CGEvent.tapEnable(tap: box.port, enable: false)
            CFRunLoopRemoveSource(runLoop, box.source, .commonModes)
            CFMachPortInvalidate(box.port)
        }
        tally.port.withLock { $0 = nil }
    }
}
