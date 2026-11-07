import Foundation
import IOKit.ps

// MARK: - power.source

public struct PowerSourcePayload: EventPayload, Equatable {
    /// What the machine is drawing from (`IOPSGetProvidingPowerSourceType`).
    public enum Providing: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case ac, battery, ups
        /// IOKit returned no answer or a value this version does not know.
        case unknown
    }

    /// `IOPSGetBatteryWarningLevel`.
    public enum WarningLevel: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        /// Not low on battery, or drawing from external power.
        case none
        /// The battery can provide no more than about 20 minutes.
        case early
        /// The battery can provide no more than about 10 minutes.
        case final
    }

    public let providing: Providing
    public let warningLevel: WarningLevel
    /// One entry per power source IOKit lists (internal batteries and UPSs).
    public let batteries: [PowerSourceBattery]

    public static var schema: TypeSchema {
        .named(
            "PowerSource",
            ObjectSchema([
                .field("providing", Providing.self, doc: "What the machine draws from now."),
                .field("warningLevel", WarningLevel.self, doc: "The system's low-battery warning level."),
                .field(
                    "batteries", [PowerSourceBattery].self,
                    doc: "Every power source IOKit lists (internal batteries, UPSs); empty on a desktop Mac."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                providing: .battery, warningLevel: .none,
                batteries: [
                    PowerSourceBattery(
                        name: "InternalBattery-0", currentCapacityPercent: 76, isCharging: false,
                        isCharged: nil, timeToEmptyMinutes: 312, timeToFullMinutes: nil,
                        powerSourceState: .battery)
                ]),
            Self(
                providing: .ac, warningLevel: .none,
                batteries: [
                    PowerSourceBattery(
                        name: "InternalBattery-0", currentCapacityPercent: 100, isCharging: false,
                        isCharged: true, timeToEmptyMinutes: nil, timeToFullMinutes: nil,
                        powerSourceState: .ac)
                ]),
            Self(providing: .ac, warningLevel: .none, batteries: []),
        ]
    }
}

public struct PowerSourceBattery: Codable, Sendable, Equatable, SchemaDescribed {
    /// `kIOPSPowerSourceStateKey`.
    public enum State: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case ac, battery, offline
    }

    public let name: String
    public let currentCapacityPercent: Double?
    public let isCharging: Bool?
    public let isCharged: Bool?
    public let timeToEmptyMinutes: Int?
    public let timeToFullMinutes: Int?
    public let powerSourceState: State?

    public static var schema: TypeSchema {
        .named(
            "PowerSourceBattery",
            ObjectSchema([
                .field("name", String.self),
                .optional("currentCapacityPercent", Double.self, doc: "Current Capacity / Max Capacity × 100."),
                .optional("isCharging", Bool.self),
                .optional("isCharged", Bool.self),
                .optional(
                    "timeToEmptyMinutes", Int.self,
                    doc: "Only while discharging on its own power; absent while IOKit is still calculating."),
                .optional(
                    "timeToFullMinutes", Int.self,
                    doc: "Only while charging; absent while IOKit is still calculating."),
                .optional(
                    "powerSourceState", State.self,
                    doc: "Whether this source is on external power, its own, or off line."),
            ]))
    }
}

public enum PowerSourceEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "power.source",
        "The power source or battery state changed: AC, battery or UPS, the low-battery warning level, and each battery's charge and time estimates. The current state is delivered first; an event is sent only when one of these fields changes, so voltage or temperature changes alone are not reported.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source: "notify(3) kIOPSNotifyAnyPowerSource, IOPSCopyPowerSourcesInfo"
    )

    /// `notify(3)` rather than `IOPSNotificationCreateRunLoopSource`: the
    /// header documents this name as the run-loop-free equivalent, and the
    /// run loop source would need a thread kept alive in `CFRunLoopRun` only
    /// to forward the same signal. The notification carries no data, so the
    /// payload is read afresh each time; repeated posts may be coalesced.
    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<PowerSourcePayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        let publish: @Sendable () -> Void = { reporter.report { PowerSnapshot.read() } }
        return DarwinNotifySource(names: [kIOPSNotifyAnyPowerSource], initial: publish) { _, _ in publish() }
    }
}

/// Translation from IOKit's power source dictionaries to the payload.
enum PowerSnapshot {
    static func read() -> PowerSourcePayload {
        let warningLevel: PowerSourcePayload.WarningLevel
        switch IOPSGetBatteryWarningLevel() {
        case kIOPSLowBatteryWarningEarly: warningLevel = .early
        case kIOPSLowBatteryWarningFinal: warningLevel = .final
        default: warningLevel = .none
        }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSourcePayload(providing: .unknown, warningLevel: warningLevel, batteries: [])
        }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as [CFTypeRef]? ?? []
        let batteries = sources.compactMap { source -> PowerSourceBattery? in
            guard
                let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { return nil }
            return battery(from: description)
        }
        return PowerSourcePayload(
            providing: Self.providing(providing), warningLevel: warningLevel,
            batteries: batteries)
    }

    static func providing(_ value: String?) -> PowerSourcePayload.Providing {
        switch value {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMUPSPowerKey: return .ups
        default: return .unknown
        }
    }

    /// Applies the validity rules in IOPSKeys.h: time to empty only while on
    /// the source's own power and not charging, time to full only while
    /// charging, and -1 ("still calculating") is never reported.
    static func battery(from description: [String: Any]) -> PowerSourceBattery {
        let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
        let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
        let percent: Double? = if let current, let maximum, maximum > 0 { current / maximum * 100 } else { nil }
        let isCharging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue
        let state: PowerSourceBattery.State? =
            switch description[kIOPSPowerSourceStateKey] as? String {
            case kIOPSACPowerValue?: .ac
            case kIOPSBatteryPowerValue?: .battery
            case kIOPSOffLineValue?: .offline
            default: nil
            }
        func minutes(_ key: String) -> Int? {
            guard let value = (description[key] as? NSNumber)?.intValue, value >= 0 else { return nil }
            return value
        }
        return PowerSourceBattery(
            name: description[kIOPSNameKey] as? String ?? "",
            currentCapacityPercent: percent,
            isCharging: isCharging,
            isCharged: (description[kIOPSIsChargedKey] as? NSNumber)?.boolValue,
            timeToEmptyMinutes: state == .battery && isCharging == false ? minutes(kIOPSTimeToEmptyKey) : nil,
            timeToFullMinutes: isCharging == true ? minutes(kIOPSTimeToFullChargeKey) : nil,
            powerSourceState: state
        )
    }
}
