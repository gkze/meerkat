import MeerkatKit

/// A metric's values summarized: the median and the observed range.
public struct Spread: Codable, Sendable, Equatable {
    public let median: Double
    public let min: Double
    public let max: Double

    /// Nil when there are no values: unknown is not zero.
    public init?(_ values: [Double]) {
        guard let low = values.min(), let high = values.max(), let median = values.median else { return nil }
        self.median = median
        min = low
        max = high
    }

    /// Each metric of `SampleMetric` that any of `samples` has, by name.
    public static func byMetric(_ samples: [[String: Double]]) -> [String: Spread] {
        var spreads: [String: Spread] = [:]
        for metric in SampleMetric.allCases {
            spreads[metric.rawValue] = Spread(samples.compactMap { $0[metric.rawValue] })
        }
        return spreads
    }
}

/// What `meerkat compare` and MCP's `samples_compare` report: each label's
/// medians and ranges, and for exactly two labels the change between them
/// and the warnings that say whether it means anything. One owner, so the
/// CLI's table and the JSON agents read can't disagree.
///
/// A single sample can't detect a change: on a loaded host total CPU varies
/// 2.4x run to run. Only medians over several samples whose ranges don't
/// overlap mean anything, and even then a metric whose own spread is
/// comparable to the change is flagged.
public struct SampleComparison: Codable, Sendable, Equatable {
    public struct Label: Codable, Sendable, Equatable {
        public let label: String
        public let count: Int
        /// By metric name; a metric no sample of the label has is absent.
        public let metrics: [String: Spread]
    }

    /// The second label's median minus the first's.
    public struct Change: Codable, Sendable, Equatable {
        public let change: Double
        /// Relative to the first label's median; nil when that is zero.
        public let percent: Double?
    }

    /// In the order the labels first appear.
    public let labels: [Label]
    /// From the first label to the second, by metric; nil unless there are
    /// exactly two labels.
    public let delta: [String: Change]?
    /// Metrics whose two ranges overlap: not separable at this sample count.
    public let overlapping: [String]
    /// Metrics that spread by more than half their median within a label:
    /// more samples or a longer window are needed.
    public let noisy: [String]

    /// Groups `records` by label, in the order labels first appear.
    public init(_ records: [StoredMetrics]) {
        var order: [String] = []
        var byLabel: [String: [[String: Double]]] = [:]
        for record in records {
            if byLabel[record.label] == nil { order.append(record.label) }
            byLabel[record.label, default: []].append(record.metrics)
        }
        self.init(order.map { ($0, byLabel[$0] ?? []) })
    }

    /// `groups` are each label's samples, in the order to report them.
    public init(_ groups: [(label: String, samples: [[String: Double]])]) {
        let names = SampleMetric.allCases.map(\.rawValue)
        let labels = groups.map {
            Label(label: $0.label, count: $0.samples.count, metrics: Spread.byMetric($0.samples))
        }
        self.labels = labels

        guard groups.count == 2 else {
            delta = nil
            overlapping = []
            noisy = []
            return
        }
        let (first, second) = (labels[0].metrics, labels[1].metrics)
        var delta: [String: Change] = [:]
        var overlapping: [String] = []
        for name in names {
            guard let a = first[name], let b = second[name] else { continue }
            let change = b.median - a.median
            delta[name] = Change(change: change, percent: a.median == 0 ? nil : change / abs(a.median) * 100)
            // Constants on both sides (swap pinned at one page count) didn't
            // move; they aren't "overlapping".
            if a.min == a.max && b.min == b.max { continue }
            if a.min <= b.max && b.min <= a.max { overlapping.append(name) }
        }
        self.delta = delta
        self.overlapping = overlapping
        noisy = names.filter { name in
            labels.contains { label in
                guard let spread = label.metrics[name] else { return false }
                return (spread.max - spread.min) / Swift.max(abs(spread.median), 1) > 0.5
            }
        }
    }
}

/// One label of a store, as `meerkat analyze` and `meerkat://samples`
/// report it: how many samples, and the spread of the machine-wide
/// metrics. A metric no sample of the label has is nil: CPU is stored as
/// NULL when it could not be measured, and unknown is not zero.
public struct LabelSummary: Codable, Sendable, Equatable {
    public let label: String
    public let count: Int
    /// Machine-wide, percent of all cores.
    public let cpuUsagePct: Spread?
    public let compressedGB: Spread?
    public let swapGB: Spread?

    public init(_ metrics: SampleStore.LabelMetrics) {
        label = metrics.label
        count = metrics.count
        cpuUsagePct = Spread(metrics.cpu)
        compressedGB = Spread(metrics.compressedGB)
        swapGB = Spread(metrics.swapGB)
    }
}
