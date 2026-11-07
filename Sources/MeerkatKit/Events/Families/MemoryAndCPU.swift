import Dispatch
import Foundation
import Synchronization

// MARK: - Shared parameter shape

/// `{ interval?: number }` with a per-event default and range.
public protocol IntervalParameterDefaults {
    static var defaultInterval: Double { get }
    static var intervalRange: ClosedRange<Double> { get }
}

public struct IntervalParameters<Defaults: IntervalParameterDefaults>: EventParameters {
    /// Seconds between samples.
    public var interval: Double

    public init(interval: Double = Defaults.defaultInterval) {
        self.interval = interval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interval = try container.decodeIfPresent(Double.self, forKey: .interval) ?? Defaults.defaultInterval
    }

    public func validate() throws {
        try requireInterval(interval, in: Defaults.intervalRange)
    }

    public static var schema: TypeSchema {
        .object(
            ObjectSchema([
                .optional(
                    "interval", Double.self,
                    doc:
                        "Seconds between samples, \(Defaults.intervalRange.lowerBound)–\(Defaults.intervalRange.upperBound). Default \(Defaults.defaultInterval)."
                )
            ]))
    }

    public static var examples: [Self] { [Self()] }
}

// MARK: - memory.pressure

public struct MemoryPressurePayload: EventPayload, Equatable {
    public enum Level: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case normal, warning, critical
    }

    public let level: Level

    public static var schema: TypeSchema {
        .named("MemoryPressure", ObjectSchema([.field("level", Level.self)]))
    }

    public static var examples: [Self] { Level.allCases.map(Self.init) }
}

public enum MemoryPressureEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "memory.pressure",
        "The kernel's memory pressure level changed. The current level is delivered first.",
        mechanism: .push, semantics: .state, loss: .none,
        observation: .open,
        source: "DispatchSource.makeMemoryPressureSource"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<MemoryPressurePayload>
    ) throws -> any EventSource {
        let queue = DispatchQueue(label: "com.gkze.meerkat.memory-pressure", qos: .utility)
        let holder = Mutex<DispatchSourceBox?>(nil)
        return ClosureSource(
            start: {
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.normal, .warning, .critical], queue: queue)
                source.setEventHandler {
                    let event = source.data
                    let level: MemoryPressurePayload.Level =
                        event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                    emit(MemoryPressurePayload(level: level))
                }
                holder.withLock { $0 = DispatchSourceBox(value: source) }
                source.resume()
                // The dispatch source reports changes only; the current level
                // comes from the same kernel state through sysctl.
                queue.async { emit(MemoryPressurePayload(level: currentMemoryPressure())) }
            },
            stop: {
                holder.withLock { box in
                    box?.value.cancel()
                    box = nil
                }
            })
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static func currentMemoryPressure() -> MemoryPressurePayload.Level {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}

struct DispatchSourceBox: @unchecked Sendable {
    let value: any DispatchSourceProtocol
}

// MARK: - memory.sample

extension MemorySample: EventPayload {
    public static var schema: TypeSchema {
        .named(
            "MemorySample",
            ObjectSchema([
                .field("pageSize", UInt64.self, doc: "Bytes per VM page."),
                .field("freeMB", Double.self),
                .field("activeMB", Double.self),
                .field("inactiveMB", Double.self),
                .field("wiredMB", Double.self),
                .field("compressedMB", Double.self),
                .field("swapUsedMB", Double.self),
                .field("swapTotalMB", Double.self),
            ]))
    }

    public static var examples: [MemorySample] {
        [
            MemorySample(
                pageSize: 16_384, freeMB: 812, activeMB: 9_120, inactiveMB: 8_877,
                wiredMB: 3_401, compressedMB: 9_885, swapUsedMB: 3_500, swapTotalMB: 4_096)
        ]
    }
}

public enum MemorySampleEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 1.0
    public static let intervalRange = 0.25...3600.0

    public static let descriptor = EventDescriptor(
        "memory.sample",
        "System memory and swap, sampled. Megabytes are decimal (10^6 bytes).",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .open,
        source: "host_statistics64, sysctl vm.swapusage"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<MemorySampleEvent>, environment: SourceEnvironment,
        emit: Emitter<MemorySample>
    ) throws -> any EventSource {
        PollingSource(label: "memory-sample", interval: parameters.interval, failingThrough: emit) {
            emit(try MemorySampler.sample())
        }
    }
}

// MARK: - cpu.sample

public struct CPUSamplePayload: EventPayload, Equatable {
    /// Percent of the whole machine (all cores) busy since the previous sample.
    public let usagePercent: Double
    /// `usagePercent` expressed as fully busy cores.
    public let busyCores: Double
    public let cpuCount: Int
    public let load1: Double
    public let load5: Double
    public let load15: Double

    public static var schema: TypeSchema {
        .named(
            "CPUSample",
            ObjectSchema([
                .field("usagePercent", Double.self, doc: "Percent of all cores busy since the previous sample."),
                .field("busyCores", Double.self),
                .field("cpuCount", Int.self),
                .field("load1", Double.self),
                .field("load5", Double.self),
                .field("load15", Double.self),
            ]))
    }

    public static var examples: [Self] {
        [Self(usagePercent: 12.5, busyCores: 1.75, cpuCount: 14, load1: 3.2, load5: 2.9, load15: 2.4)]
    }
}

public enum CPUSampleEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 1.0
    public static let intervalRange = 0.1...3600.0

    public static let descriptor = EventDescriptor(
        "cpu.sample",
        "Machine-wide CPU usage and load averages, sampled. The first event arrives after one interval.",
        mechanism: .poll, semantics: .state, loss: .lossy,
        observation: .open,
        source: "host_statistics(HOST_CPU_LOAD_INFO), getloadavg"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<CPUSampleEvent>, environment: SourceEnvironment,
        emit: Emitter<CPUSamplePayload>
    ) throws -> any EventSource {
        let cpuCount = ProcessInfo.processInfo.processorCount
        let previous = Mutex<(busy: UInt64, total: UInt64)?>(HostSampler.cpuTicks())
        return PollingSource(
            label: "cpu-sample", interval: parameters.interval, fireImmediately: false, failingThrough: emit
        ) {
            guard let now = HostSampler.cpuTicks() else {
                throw EventError.sourceUnavailable("host_statistics(HOST_CPU_LOAD_INFO) failed")
            }
            let last = previous.withLock { last in
                defer { last = now }
                return last
            }
            // Ticks that went backwards would trap the subtraction; the
            // next tick compares with these.
            guard let last, now.total > last.total, now.busy >= last.busy else { return }
            let load = try MemorySampler.loadAverages()
            let usage = Double(now.busy - last.busy) / Double(now.total - last.total) * 100
            emit(
                CPUSamplePayload(
                    usagePercent: usage,
                    busyCores: usage / 100 * Double(cpuCount),
                    cpuCount: cpuCount,
                    load1: load.0, load5: load.1, load15: load.2
                ))
        }
    }
}

// MARK: - timer

public struct TimerParameters: EventParameters {
    /// Seconds between events.
    public var every: Double

    static let everyRange = 1.0...(7 * 86_400)

    public func validate() throws {
        try requireInterval(every, name: "every", in: Self.everyRange)
    }

    public static var schema: TypeSchema {
        .object(
            ObjectSchema([
                .field(
                    "every", Double.self,
                    doc:
                        "Seconds between events, \(NumberBounds.format(everyRange.lowerBound))–\(NumberBounds.format(everyRange.upperBound))."
                )
            ]))
    }

    public static var examples: [Self] { [Self(every: 300)] }
}

public struct TimerPayload: EventPayload, Equatable {
    /// 1 for the first event after the rule loaded, then 2, 3, …
    public let count: Int

    public static var schema: TypeSchema {
        .object(ObjectSchema([.field("count", Int.self, doc: "1 for the first event, then 2, 3, …")]))
    }

    public static var examples: [Self] { [Self(count: 1)] }
}

public enum TimerEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "timer",
        "Fires every `every` seconds, first one interval after subscribing. Wakeups may be batched by up to 10% of the interval; missed fires during sleep are not replayed.",
        mechanism: .poll, semantics: .occurrence, loss: .lossy,
        observation: .open,
        source: "DispatchSourceTimer"
    )

    public static func makeSource(
        _ parameters: TimerParameters, environment: SourceEnvironment,
        emit: Emitter<TimerPayload>
    ) throws -> any EventSource {
        let count = Atomic<Int>(0)
        return PollingSource(label: "timer", interval: parameters.every, fireImmediately: false) {
            emit(TimerPayload(count: count.add(1, ordering: .relaxed).newValue))
        }
    }
}
