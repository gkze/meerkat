/// What the extension does with a new flow, and the only thing it can do.
///
/// The filter exists to count, so every flow is allowed as it opens, and macOS
/// is asked to report its close. This type has no drop, pause, data-filtering or
/// need-rules case to return by mistake: a bug in the extension can cost
/// accuracy, never connectivity. The provider maps it to
/// `NEFilterNewFlowVerdict.allow()` with `shouldReport` and
/// `statisticsReportFrequency` set, and to nothing else.
public struct NewFlowVerdict: Sendable, Equatable {
    /// How often macOS reports a flow's running totals while it is open:
    /// `never` is only at its close; `low` is about every five seconds.
    ///
    /// Asking for running totals keeps the flow attached to the filter, and
    /// when the filter's session ends (the extension crashing) the kernel
    /// resets every attached connection (seen on macOS 27: a download reset
    /// the moment NetworkExtension uninstalled the session).
    public enum StatisticsFrequency: Sendable, Equatable, CaseIterable {
        case never, low, medium, high
    }

    public let statistics: StatisticsFrequency

    private init(statistics: StatisticsFrequency) {
        self.statistics = statistics
    }

    /// Allow, and report the flow's bytes when it closes. No running totals:
    /// a long flow is counted when it ends, and the extension crashing costs
    /// no connection (`StatisticsFrequency`).
    public static let allowAndCount = NewFlowVerdict(statistics: .never)
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
