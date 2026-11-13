/// What the extension does with a new flow, and the only thing it can do.
///
/// The filter exists to count, so every flow is allowed as it opens, and macOS
/// is asked to report it. This type has no drop, pause, data-filtering or
/// need-rules case to return by mistake: no decision of the extension's can
/// block a connection. (Its crashing can, once: see `allowAndCount`.) The
/// provider maps it to
/// `NEFilterNewFlowVerdict.allow()` with `shouldReport` and
/// `statisticsReportFrequency` set, and to nothing else.
public struct NewFlowVerdict: Sendable, Equatable {
    /// How often macOS reports a flow's running totals. `low` is about every
    /// five seconds, the default sample interval of the process events.
    public enum StatisticsFrequency: Sendable, Equatable, CaseIterable {
        case low, medium, high
    }

    public let statistics: StatisticsFrequency

    private init(statistics: StatisticsFrequency) {
        self.statistics = statistics
    }

    /// Allow, report the flow's running totals at `low` and its close.
    ///
    /// Any reporting keeps the flow attached to the filter, and when the
    /// filter's session ends (the extension crashing) the kernel resets every
    /// attached connection. Reporting only the close does not avoid it (both
    /// seen on macOS 27), so the totals come every five seconds, and
    /// `CrashGuard` keeps a crashing extension from doing it repeatedly.
    public static let allowAndCount = NewFlowVerdict(statistics: .low)
}

/// The kinds of flow NetworkExtension offers a socket filter. The verdict is
/// the same for all of them; naming them lets the tests show it for each.
public enum FlowKind: Sendable, CaseIterable {
    case tcp, udp, other
}

public enum FlowPolicy {
    /// The verdict for a new flow, whatever it is. Total and constant: no
    /// input reaches a verdict that is not `allowAndCount`.
    public static func verdict(for _: FlowKind) -> NewFlowVerdict { .allowAndCount }
}
