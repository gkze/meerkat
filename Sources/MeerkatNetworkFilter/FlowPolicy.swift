/// What the extension does with a new flow, and the only thing it can do.
///
/// The filter exists to count, so every flow is allowed as it opens, and macOS
/// is asked to report it. This type has no drop, pause, data-filtering or
/// need-rules case to return by mistake: a bug in the extension can cost
/// accuracy, never connectivity. The provider maps it to
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

    /// Allow, report the open and the close, and report statistics at `low`.
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
