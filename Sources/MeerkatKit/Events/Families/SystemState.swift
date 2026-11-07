import Foundation
import Synchronization

// Foundation-level system state: thermal state, Low Power Mode, the clock,
// the time zone, the calendar day and the locale. Every notification here is
// posted on `NotificationCenter.default`.

// MARK: - Shared source shape

/// A `state` event fed by notifications. It registers first and then reports
/// the current value, so no change is missed between the two. `StateReporter`
/// orders reads and emits, and a repeat of the last value emits nothing.
func notificationStateSource<Payload: EventPayload & Equatable>(
    center: NotificationCenter,
    names: [Notification.Name],
    emit: Emitter<Payload>,
    current: @escaping @Sendable () -> Payload?,
    changed: @escaping @Sendable (Notification) -> Payload?
) -> NotificationSource {
    let reporter = StateReporter(emit)
    return NotificationSource(
        center: center, names: names,
        initial: { reporter.report(current) },
        handler: { notification in reporter.report { changed(notification) } })
}

// MARK: - thermal.state

public struct ThermalStatePayload: EventPayload, Equatable {
    public enum State: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case nominal, fair, serious, critical
    }

    public let state: State

    public static var schema: TypeSchema {
        .named(
            "ThermalState",
            ObjectSchema([
                .field("state", State.self, doc: "ProcessInfo.thermalState: nominal, fair, serious or critical.")
            ]))
    }

    public static var examples: [Self] { State.allCases.map(Self.init) }
}

extension ThermalStatePayload {
    /// Nil for a state this build does not know.
    init?(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self.init(state: .nominal)
        case .fair: self.init(state: .fair)
        case .serious: self.init(state: .serious)
        case .critical: self.init(state: .critical)
        @unknown default: return nil
        }
    }
}

public enum ThermalStateEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "thermal.state",
        "The system thermal state changed (nominal, fair, serious, critical). The current state is delivered first. Temperatures and fan speeds are not reported.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "ProcessInfo.thermalStateDidChangeNotification"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<ThermalStatePayload>
    ) throws -> any EventSource {
        let read: @Sendable () -> ThermalStatePayload? = { ThermalStatePayload(ProcessInfo.processInfo.thermalState) }
        return notificationStateSource(
            center: .default, names: [ProcessInfo.thermalStateDidChangeNotification],
            emit: emit, current: read, changed: { _ in read() })
    }
}

// MARK: - power.lowPowerMode

public struct LowPowerModePayload: EventPayload, Equatable {
    public let enabled: Bool

    public static var schema: TypeSchema {
        .named("LowPowerMode", ObjectSchema([.field("enabled", Bool.self)]))
    }

    public static var examples: [Self] { [Self(enabled: false), Self(enabled: true)] }
}

public enum LowPowerModeEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "power.lowPowerMode",
        "Low Power Mode was turned on or off. The current setting is delivered first.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "NSProcessInfoPowerStateDidChange, ProcessInfo.isLowPowerModeEnabled"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<LowPowerModePayload>
    ) throws -> any EventSource {
        let read: @Sendable () -> LowPowerModePayload? = {
            LowPowerModePayload(enabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        return notificationStateSource(
            center: .default, names: [.NSProcessInfoPowerStateDidChange],
            emit: emit, current: read, changed: { _ in read() })
    }
}

// MARK: - time.clockSet

public enum ClockSetEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "time.clockSet",
        "The system clock was set, by the user or by network time. The size of the jump is not reported.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "NSSystemClockDidChange"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<EmptyPayload>
    ) throws -> any EventSource {
        NotificationSource(center: .default, names: [.NSSystemClockDidChange]) { _ in emit(EmptyPayload()) }
    }
}

// MARK: - time.zone

public struct TimeZonePayload: EventPayload, Equatable {
    /// IANA identifier, for example "Europe/Berlin".
    public let identifier: String
    public let abbreviation: String?
    public let secondsFromGMT: Int

    public static var schema: TypeSchema {
        .named(
            "TimeZone",
            ObjectSchema([
                .field("identifier", String.self, doc: "IANA identifier, for example \"Europe/Berlin\"."),
                .optional("abbreviation", String.self, doc: "For example \"CEST\"; absent when the zone has none."),
                .field("secondsFromGMT", Int.self, doc: "Offset from GMT now, including daylight saving time."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(identifier: "Europe/Berlin", abbreviation: "CEST", secondsFromGMT: 7_200),
            Self(identifier: "Asia/Kolkata", abbreviation: nil, secondsFromGMT: 19_800),
        ]
    }
}

extension TimeZone {
    /// The system's zone as it is now. Foundation reads it once per process
    /// and keeps it until `resetSystemTimeZone()`, and the daemon outlives
    /// zone changes, so every reader that reports the current zone resets
    /// first, not only the one that hears the change.
    static var currentSystem: TimeZone {
        NSTimeZone.resetSystemTimeZone()
        return .current
    }
}

extension TimeZonePayload {
    init(_ zone: TimeZone, at date: Date = Date()) {
        self.init(
            identifier: zone.identifier, abbreviation: zone.abbreviation(for: date),
            secondsFromGMT: zone.secondsFromGMT(for: date))
    }
}

public enum TimeZoneEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "time.zone",
        "The system time zone changed. The current zone is delivered first. Daylight saving transitions within a zone are not reported.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "NSSystemTimeZoneDidChange, TimeZone.current"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<TimeZonePayload>
    ) throws -> any EventSource {
        notificationStateSource(
            center: .default, names: [.NSSystemTimeZoneDidChange], emit: emit,
            current: { TimeZonePayload(.currentSystem) },
            changed: { _ in TimeZonePayload(.currentSystem) })
    }
}

// MARK: - time.dayChanged

public struct DayChangedPayload: EventPayload, Equatable {
    /// The new local calendar date, `YYYY-MM-DD`.
    public let date: String

    public static var schema: TypeSchema {
        .named(
            "DayChanged",
            ObjectSchema([
                .field("date", String.self, doc: "The new local date, YYYY-MM-DD.")
            ]))
    }

    public static var examples: [Self] { [Self(date: "2026-10-24")] }
}

extension DayChangedPayload {
    /// The local date of `now` in the system's time zone as it is now, in
    /// the Gregorian calendar that ISO 8601 specifies.
    init(now: Date) {
        self.init(date: now.formatted(Date.ISO8601FormatStyle(timeZone: .currentSystem).year().month().day()))
    }
}

public enum DayChangedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "time.dayChanged",
        "The local calendar day changed. If the Mac slept through one or more midnights, one event arrives after wake, so skipped days are not reported individually.",
        mechanism: .push, semantics: .occurrence, loss: .coalesced,
        observation: .open,
        source: "wall-clock timer at local midnight, NSSystemTimeZoneDidChange, NSSystemClockDidChange"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<DayChangedPayload>
    ) throws -> any EventSource {
        DayChangeSource(emit: emit)
    }
}

/// `time.dayChanged`: a wall-clock timer at the next local midnight in the
/// system's zone as it is then, and a check whenever the zone or the clock
/// changes, emitting when the local date differs from the last one seen.
///
/// Not `NSCalendarDayChanged`: Foundation keeps the midnight of the zone the
/// process read first, through `resetSystemTimeZone()` and a posted
/// `NSSystemTimeZoneDidChange` (seen on macOS 27), so a daemon that outlived
/// a zone change would announce each day at the old zone's midnight. A
/// wall-clock deadline that passed while the Mac slept fires once on wake.
final class DayChangeSource: EventSource {
    private let emit: Emitter<DayChangedPayload>
    private let queue = DispatchQueue(label: "com.gkze.meerkat.day-changed", qos: .utility)
    private let state = Mutex(State())

    private struct State {
        var timer: PollingSource.TimerBox?
        var observers: [NotificationSource.TokenBox] = []
        var today: DayChangedPayload?
    }

    init(emit: Emitter<DayChangedPayload>) { self.emit = emit }

    func start() throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.check() }
        let observers = [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange].map { name in
            NotificationSource.TokenBox(
                value: NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { [weak self] in self?.check() }
                })
        }
        state.withLock { state in
            state.timer = PollingSource.TimerBox(value: timer)
            state.observers = observers
        }
        timer.resume()
        // Notes today's date and arms the timer.
        queue.async { [weak self] in self?.check() }
    }

    func stop() {
        let (timer, observers) = state.withLock { state in
            defer { (state.timer, state.observers) = (nil, []) }
            return (state.timer, state.observers)
        }
        timer?.value.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer.value) }
    }

    /// On `queue`.
    private func check() {
        let now = Date()
        let today = DayChangedPayload(now: now)
        let (timer, changed) = state.withLock { state in
            defer { state.today = today }
            return (state.timer, state.today.map { $0 != today } ?? false)
        }
        guard let timer else { return }
        if changed { emit(today) }
        let next = Self.nextMidnight(after: now, in: .currentSystem).timeIntervalSince1970
        timer.value.schedule(
            wallDeadline: DispatchWallTime(timespec: timespec(tv_sec: Int(next.rounded(.up)), tv_nsec: 0)),
            leeway: .seconds(1))
    }

    /// The first moment after `date` that starts a day in `zone`: midnight,
    /// or the first time that exists on a day whose midnight a clock change
    /// skips.
    static func nextMidnight(after date: Date, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.nextDate(
            after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(3600)
    }
}

// MARK: - locale.changed

public struct LocalePayload: EventPayload, Equatable {
    /// For example "en_US".
    public let identifier: String

    public static var schema: TypeSchema {
        .named(
            "Locale",
            ObjectSchema([
                .field("identifier", String.self, doc: "The current locale identifier, for example \"en_US\".")
            ]))
    }

    public static var examples: [Self] { [Self(identifier: "en_US"), Self(identifier: "de_DE@calendar=gregorian")] }
}

public enum LocaleChangedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "locale.changed",
        "The user's locale settings changed (region, number or date formats, calendar). The current locale identifier is delivered first; individual format preferences are not reported.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "NSLocale.currentLocaleDidChangeNotification"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<LocalePayload>
    ) throws -> any EventSource {
        let read: @Sendable () -> LocalePayload? = { LocalePayload(identifier: Locale.current.identifier) }
        return notificationStateSource(
            center: .default, names: [NSLocale.currentLocaleDidChangeNotification],
            emit: emit, current: read, changed: { _ in read() })
    }
}
