import CoreGraphics
import Darwin
import Foundation
import Synchronization

// Who is logged in, and whether anyone is at the keyboard.

// MARK: - session.logins

public struct LoginSession: Codable, Sendable, Equatable, SchemaDescribed {
    public let user: String
    public let line: String
    public let host: String?
    public let pid: Int32
    public let startedAt: Double

    public static var schema: TypeSchema {
        .named(
            "LoginSession",
            ObjectSchema([
                .field("user", String.self),
                .field(
                    "line", String.self,
                    doc: "\"console\" for the graphical login, a tty such as \"ttys003\" for a terminal or SSH session."
                ),
                .optional(
                    "host", String.self, doc: "Remote host for SSH and other network logins; absent for local ones."),
                .field("pid", Int32.self, doc: "The session's login process."),
                .field("startedAt", Double.self, doc: "Unix epoch milliseconds."),
            ]))
    }
}

public struct LoginSessionsPayload: EventPayload, Equatable {
    /// Ordered by start time, then line.
    public let sessions: [LoginSession]

    public static var schema: TypeSchema {
        .named(
            "LoginSessions",
            ObjectSchema([
                .field(
                    "sessions", [LoginSession].self,
                    doc: "Every login session, oldest first. Each terminal window or tab is a session of its own.")
            ]))
    }

    public static var examples: [Self] {
        [
            Self(sessions: [
                LoginSession(user: "alice", line: "console", host: nil, pid: 412, startedAt: 1_792_870_300_000),
                LoginSession(
                    user: "alice", line: "ttys004", host: "203.0.113.7", pid: 81_022, startedAt: 1_792_901_224_000),
            ]),
            Self(sessions: []),
        ]
    }

    /// `getutxent` walks one process-wide cursor; the lock keeps two readers
    /// from interleaving.
    private static let cursor = Mutex(())

    static func read() -> Self {
        cursor.withLock { _ in
            setutxent()
            defer { endutxent() }
            var sessions: [LoginSession] = []
            while let entry = getutxent() {
                guard entry.pointee.ut_type == USER_PROCESS else { continue }
                let host = String(nulTerminatedBytesOf: entry.pointee.ut_host)
                let time = entry.pointee.ut_tv
                sessions.append(
                    LoginSession(
                        user: String(nulTerminatedBytesOf: entry.pointee.ut_user),
                        line: String(nulTerminatedBytesOf: entry.pointee.ut_line),
                        host: host.isEmpty ? nil : host, pid: entry.pointee.ut_pid,
                        startedAt: Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
                    ))
            }
            return Self(sessions: sessions.sorted { ($0.startedAt, $0.line) < ($1.startedAt, $1.line) })
        }
    }
}

public enum LoginSessionsEvent: EventKind {
    /// `UTMPX_CHANGE_NOTIFICATION` from <utmpx.h>.
    static let name = "com.apple.system.utmpx"

    public static let descriptor = EventDescriptor(
        "session.logins",
        "Someone logged in or out: the graphical console, a terminal window, or an SSH session. The current sessions are delivered first.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .named,
        source: "notify(3) UTMPX_CHANGE_NOTIFICATION, getutxent"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<LoginSessionsPayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        return DarwinNotifySource(
            names: [name], initial: { reporter.report(LoginSessionsPayload.read) },
            handler: { _, _ in
                reporter.report(LoginSessionsPayload.read)
            })
    }
}

// MARK: - input.idle

public struct InputIdlePayload: EventPayload, Equatable {
    public let idle: Bool
    public let idleSeconds: Double

    public static var schema: TypeSchema {
        .named(
            "InputIdle",
            ObjectSchema([
                .field(
                    "idle", Bool.self,
                    doc: "True once no keyboard, mouse or trackpad input has arrived for `threshold` seconds."),
                .field("idleSeconds", Double.self, doc: "Seconds since the last input when this was observed."),
            ]))
    }

    public static var examples: [Self] { [Self(idle: true, idleSeconds: 301.4), Self(idle: false, idleSeconds: 0.2)] }
}

public struct InputIdleParameters: EventParameters {
    public static let defaultThreshold = 300.0

    public var threshold: Double

    public init(threshold: Double = Self.defaultThreshold) { self.threshold = threshold }

    /// How often the idle time is checked: a tenth of the threshold, between
    /// one and ten seconds, so a transition is seen within that delay.
    var checkInterval: Double { min(max(threshold / 10, 1), 10) }

    public static var objectSchema: ObjectSchema {
        ObjectSchema([
            ObjectSchema.Field(
                "threshold", .bounded(NumberBounds(5...86_400)), default: .number(defaultThreshold),
                doc: "Seconds without input before the user counts as idle")
        ])
    }

    public static var examples: [Self] { [Self(), Self(threshold: 60)] }
}

public enum InputIdleEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "input.idle",
        "The user became idle (no keyboard, mouse or trackpad input for `threshold` seconds) or active again. The current state is delivered first. Checked every threshold/10 seconds (1–10 s), so a transition is reported up to that late. Which keys or buttons were used is never observed.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .open,
        source: "CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateHIDSystemState)"
    )

    public static func makeSource(
        _ parameters: InputIdleParameters, environment: SourceEnvironment,
        emit: Emitter<InputIdlePayload>
    ) throws -> any EventSource {
        makeSource(
            parameters,
            idleSeconds: {
                // The HID system state follows input from HID devices, not
                // events other processes post into the session. ~0 is
                // kCGAnyInputEventType, which Swift does not import; an
                // imported C enum accepts any raw value, so this never fails.
                // swiftlint:disable:next force_unwrapping
                CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            }, emit: emit)
    }

    /// Emits on transitions only: `idleSeconds` grows every check, so
    /// comparing whole payloads would emit every time.
    static func makeSource(
        _ parameters: InputIdleParameters, idleSeconds: @escaping @Sendable () -> Double,
        emit: Emitter<InputIdlePayload>
    ) -> PollingSource {
        let last = Mutex<Bool?>(nil)
        return PollingSource(label: "input-idle", interval: parameters.checkInterval) {
            last.withLock { last in
                let seconds = idleSeconds()
                let idle = seconds >= parameters.threshold
                guard idle != last else { return }
                last = idle
                emit(InputIdlePayload(idle: idle, idleSeconds: seconds))
            }
        }
    }
}
