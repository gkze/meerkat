import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Synchronization

// Power management beyond the power source: who is keeping the Mac awake,
// the lid, and the battery's health and draw.

// MARK: - power.assertions

public struct PowerAssertion: Codable, Sendable, Equatable, SchemaDescribed {
    /// `AssertionId`: unique while the assertion exists.
    public let id: Int
    public let pid: Int32
    public let process: String?
    /// The IOKit assertion type, such as `PreventUserIdleSystemSleep` or
    /// `PreventUserIdleDisplaySleep`. Kept as a string: the set is open.
    public let type: String
    public let name: String?
    /// The process the assertion was taken for, when a daemon took it on
    /// another's behalf (coreaudiod for an app playing sound, for example).
    public let onBehalfOfPid: Int32?
    /// Unix epoch milliseconds.
    public let startedAt: Double?

    public static var schema: TypeSchema {
        .named(
            "PowerAssertion",
            ObjectSchema([
                .field("id", Int.self, doc: "Assertion id; stable while the assertion is held."),
                .field("pid", Int32.self, doc: "Process holding the assertion."),
                .optional("process", String.self, doc: "Its name as powerd reports it."),
                .field(
                    "type", String.self,
                    doc:
                        "IOKit assertion type, e.g. \"PreventUserIdleSystemSleep\", \"PreventUserIdleDisplaySleep\", \"PreventSystemSleep\"."
                ),
                .optional("name", String.self, doc: "The holder's description, e.g. \"Playing audio\"."),
                .optional(
                    "onBehalfOfPid", Int32.self,
                    doc: "The process it was taken for, when another process took it on its behalf."),
                .optional("startedAt", Double.self, doc: "Unix epoch milliseconds."),
            ]))
    }
}

public struct PowerAssertionsPayload: EventPayload, Equatable {
    /// Ordered by pid, then id.
    public let assertions: [PowerAssertion]
    /// Assertion types in effect system-wide, sorted.
    public let active: [String]

    public static var schema: TypeSchema {
        .named(
            "PowerAssertions",
            ObjectSchema([
                .field("assertions", [PowerAssertion].self, doc: "Every assertion held now, ordered by pid then id."),
                .field(
                    "active", [String].self,
                    doc:
                        "Assertion types in effect system-wide (any holder at a non-zero level), sorted; \"PreventUserIdleSystemSleep\" here means the Mac will not idle-sleep."
                ),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                assertions: [
                    PowerAssertion(
                        id: 38_069, pid: 438, process: "powerd", type: "PreventUserIdleSystemSleep",
                        name: "Powerd - Prevent sleep while display is on", onBehalfOfPid: nil,
                        startedAt: 1_792_900_173_000),
                    PowerAssertion(
                        id: 34_211, pid: 639, process: "coreaudiod", type: "PreventUserIdleSystemSleep",
                        name: nil, onBehalfOfPid: 1287, startedAt: nil),
                ], active: ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"]),
            Self(assertions: [], active: []),
        ]
    }

    /// Throws when powerd cannot be reached or answers in a shape this
    /// does not know, so a failed read is not taken for no assertions.
    static func read() throws -> Self {
        var byProcess: Unmanaged<CFDictionary>?
        var status: Unmanaged<CFDictionary>?
        let byProcessResult = IOPMCopyAssertionsByProcess(&byProcess)
        let statusResult = IOPMCopyAssertionsStatus(&status)
        // Taken first, so both are released whatever follows.
        let processesValue = byProcess?.takeRetainedValue()
        let levelsValue = status?.takeRetainedValue()
        guard byProcessResult == kIOReturnSuccess, statusResult == kIOReturnSuccess else {
            throw EventError.sourceUnavailable(
                "powerd did not answer: IOPMCopyAssertionsByProcess \(byProcessResult), IOPMCopyAssertionsStatus \(statusResult)"
            )
        }
        guard let processes = processesValue as? [NSNumber: [[String: Any]]],
            let levels = levelsValue as? [String: NSNumber]
        else { throw EventError.sourceUnavailable("powerd answered in an unknown shape") }
        var assertions: [PowerAssertion] = []
        for (pid, entries) in processes {
            for entry in entries {
                guard let type = entry["AssertType"] as? String,
                    (entry["AssertLevel"] as? NSNumber)?.intValue ?? 0 > 0
                else { continue }
                assertions.append(
                    PowerAssertion(
                        id: (entry["AssertionId"] as? NSNumber)?.intValue ?? 0,
                        pid: pid.int32Value,
                        process: entry["Process Name"] as? String,
                        type: type,
                        name: entry["AssertName"] as? String,
                        onBehalfOfPid: (entry["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value,
                        startedAt: (entry["AssertStartWhen"] as? Date).map { $0.timeIntervalSince1970 * 1000 }
                    ))
            }
        }
        assertions.sort { ($0.pid, $0.id) < ($1.pid, $1.id) }
        return Self(assertions: assertions, active: levels.filter { $0.value.intValue > 0 }.keys.sorted())
    }
}

public enum PowerAssertionsEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 2.0
    public static let intervalRange = 0.5...300.0

    public static let descriptor = EventDescriptor(
        "power.assertions",
        "Which processes hold power assertions (keeping the Mac or its display awake, or delaying sleep) changed. Checked every `interval` seconds; an assertion taken and released between checks is never seen. The current set is delivered first.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .named,
        source: "IOPMCopyAssertionsByProcess, IOPMCopyAssertionsStatus"
    )

    /// Polled: powerd posts no public notification when assertions change
    /// (checked on macOS 27: none of the powermanagement notify names fired
    /// for `caffeinate -i`). A powerd that can't be read at the start
    /// refuses the subscription, rather than start a source that never
    /// emits; later failures follow `PollingSource`'s policy.
    public static func makeSource(
        _ parameters: IntervalParameters<PowerAssertionsEvent>, environment: SourceEnvironment,
        emit: Emitter<PowerAssertionsPayload>
    ) throws -> any EventSource {
        _ = try PowerAssertionsPayload.read()
        let reporter = StateReporter(emit)
        return PollingSource(label: "power-assertions", interval: parameters.interval, failingThrough: emit) {
            let current = try PowerAssertionsPayload.read()
            reporter.report { current }
        }
    }
}

// MARK: - power.lid

public struct LidPayload: EventPayload, Equatable {
    public let closed: Bool
    public let causesSleep: Bool

    public static var schema: TypeSchema {
        .named(
            "Lid",
            ObjectSchema([
                .field("closed", Bool.self),
                .field(
                    "causesSleep", Bool.self,
                    doc: "Whether closing the lid sleeps the Mac; false in clamshell mode (external display and power)."
                ),
            ]))
    }

    public static var examples: [Self] {
        [Self(closed: false, causesSleep: true), Self(closed: true, causesSleep: false)]
    }

    /// Nil on a Mac without a lid: IOPMrootDomain then has no clamshell keys.
    static func read() -> Self? {
        IORegistry.withService(matching: "IOPMrootDomain") { root -> Self? in
            guard let closed = IORegistry.property(root, kAppleClamshellStateKey) as? Bool else { return nil }
            let causesSleep = IORegistry.property(root, kAppleClamshellCausesSleepKey) as? Bool ?? true
            return Self(closed: closed, causesSleep: causesSleep)
        } ?? nil
    }
}

public enum LidEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "power.lid",
        "The lid was opened or closed, or whether closing it sleeps the Mac changed (clamshell mode). The current state is delivered first. On a Mac without a lid the subscription fails.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "IOPMrootDomain kIOPMMessageClamshellStateChange interest notification, AppleClamshellState"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<LidPayload>
    ) throws -> any EventSource {
        guard LidPayload.read() != nil else {
            throw EventError.sourceUnavailable("power.lid: this Mac has no lid")
        }
        let reporter = StateReporter(emit)
        return RootDomainInterestSource(
            // Read under the reporter's lock, after registering: a change in
            // between arrives as a message too, and a repeat emits nothing.
            initial: { reporter.report(LidPayload.read) },
            handle: { message, argument in
                guard message == kIOPMMessageClamshellStateChangeValue else { return }
                // The state travels in the message argument; reading the registry
                // instead could see a later change first.
                let bits = Int(bitPattern: argument)
                reporter.report {
                    LidPayload(
                        closed: bits & Int(kClamshellStateBit) != 0, causesSleep: bits & Int(kClamshellSleepBit) != 0)
                }
            })
    }

    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)` from IOPM.h, a
    /// macro Swift does not import: sys_iokit (0x38 << 26) | sub 13 << 14 | 0x100.
    static let kIOPMMessageClamshellStateChangeValue: UInt32 = 0xE003_4100
}

/// General-interest messages from IOPMrootDomain on a private serial queue,
/// and `initial` once registered, so no change is missed between the two.
/// Teardown happens on that queue, after any callback in flight.
final class RootDomainInterestSource: EventSource {
    private let initial: @Sendable () -> Void
    private let registration: IONotificationRegistration<Context>

    final class Context: Sendable {
        let handle: @Sendable (_ message: UInt32, _ argument: UInt) -> Void
        init(handle: @escaping @Sendable (UInt32, UInt) -> Void) { self.handle = handle }
    }

    init(
        initial: @escaping @Sendable () -> Void,
        handle: @escaping @Sendable (_ message: UInt32, _ argument: UInt) -> Void
    ) {
        self.initial = initial
        registration = IONotificationRegistration(label: "root-domain", context: Context(handle: handle))
    }

    func start() throws {
        try registration.start("IOServiceAddInterestNotification(IOPMrootDomain)") { port, refcon, notifier in
            let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            guard root != IO_OBJECT_NULL else { return kIOReturnNotFound }
            defer { IOObjectRelease(root) }
            return IOServiceAddInterestNotification(
                port, root, kIOGeneralInterest,
                { refcon, _, message, argument in
                    guard let refcon else { return }
                    Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
                        .handle(message, UInt(bitPattern: argument))
                }, refcon, &notifier
            )
        }
        initial()
    }

    func stop() { registration.stop() }
}

// MARK: - battery.sample

public struct BatterySamplePayload: EventPayload, Equatable {
    public let cycleCount: Int?
    public let designCycleCount: Int?
    public let healthPercent: Double?
    public let designCapacityMAh: Int?
    public let fullChargeCapacityMAh: Int?
    public let voltage: Double?
    public let amperage: Double?
    public let systemPowerWatts: Double?
    public let externalConnected: Bool?
    public let adapterWatts: Int?

    public static var schema: TypeSchema {
        .named(
            "BatterySample",
            ObjectSchema([
                .optional("cycleCount", Int.self),
                .optional("designCycleCount", Int.self, doc: "Cycles the battery is rated for."),
                .optional(
                    "healthPercent", Double.self, doc: "Full-charge capacity as a percentage of design capacity."),
                .optional("designCapacityMAh", Int.self),
                .optional("fullChargeCapacityMAh", Int.self, doc: "What a full charge holds now."),
                .optional("voltage", Double.self, doc: "Battery voltage in volts."),
                .optional("amperage", Double.self, doc: "Battery current in amperes; negative while discharging."),
                .optional(
                    "systemPowerWatts", Double.self,
                    doc: "The whole machine's power draw, from the battery and the adapter together."),
                .optional("externalConnected", Bool.self, doc: "A power adapter is connected."),
                .optional("adapterWatts", Int.self, doc: "The connected adapter's rating; absent with no adapter."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                cycleCount: 339, designCycleCount: 1000, healthPercent: 82.2, designCapacityMAh: 8579,
                fullChargeCapacityMAh: 7051, voltage: 10.573, amperage: -7.248, systemPowerWatts: 75.72,
                externalConnected: false, adapterWatts: nil),
            Self(
                cycleCount: nil, designCycleCount: nil, healthPercent: nil, designCapacityMAh: nil,
                fullChargeCapacityMAh: nil, voltage: nil, amperage: nil, systemPowerWatts: nil,
                externalConnected: true, adapterWatts: 96),
        ]
    }

    /// Nil on a Mac without a battery.
    static func read() -> Self? {
        IORegistry.withService(matching: "AppleSmartBattery") { battery in
            from(
                properties: { IORegistry.property(battery, $0) },
                adapter: IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any])
        }
    }

    /// Pure translation from AppleSmartBattery's registry properties, which
    /// are not a documented interface: absent keys stay absent.
    static func from(properties: (String) -> Any?, adapter: [String: Any]?) -> Self {
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        let data = properties("BatteryData") as? [String: Any] ?? [:]
        let telemetry = properties("PowerTelemetryData") as? [String: Any] ?? [:]
        let design = int(data["DesignCapacity"])
        let full = int(data["NominalChargeCapacity"])
        let health: Double? = if let design, let full, design > 0 { Double(full) / Double(design) * 100 } else { nil }
        // Amperage is a signed value the registry stores as unsigned 64-bit.
        let amperage = (properties("Amperage") as? NSNumber).map { Double(Int64(bitPattern: $0.uint64Value)) / 1000 }
        return Self(
            cycleCount: int(properties("CycleCount")),
            designCycleCount: int(properties("DesignCycleCount9C")),
            healthPercent: health,
            designCapacityMAh: design,
            fullChargeCapacityMAh: full,
            voltage: int(properties("Voltage")).map { Double($0) / 1000 },
            amperage: amperage,
            systemPowerWatts: int(telemetry["SystemLoad"]).map { Double($0) / 1000 },
            externalConnected: properties("ExternalConnected") as? Bool,
            adapterWatts: int(adapter?[kIOPSPowerAdapterWattsKey])
        )
    }
}

public enum BatterySampleEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 30.0
    public static let intervalRange = 5.0...3600.0

    public static let descriptor = EventDescriptor(
        "battery.sample",
        "Battery health (cycle count, capacity against design), voltage and current, the whole machine's power draw, and the adapter's rating, sampled. On a Mac without a battery the subscription fails. Values change only as often as the battery controller publishes them, so short intervals can repeat a reading.",
        mechanism: .poll, semantics: .state, loss: .lossy, stability: .undocumented,
        observation: .open,
        source: "AppleSmartBattery IORegistry properties, IOPSCopyExternalPowerAdapterDetails"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<BatterySampleEvent>, environment: SourceEnvironment,
        emit: Emitter<BatterySamplePayload>
    ) throws -> any EventSource {
        guard BatterySamplePayload.read() != nil else {
            throw EventError.sourceUnavailable("battery.sample: this Mac has no battery")
        }
        return PollingSource(label: "battery-sample", interval: parameters.interval, failingThrough: emit) {
            guard let sample = BatterySamplePayload.read() else {
                throw EventError.sourceUnavailable("the battery could not be read")
            }
            emit(sample)
        }
    }
}
