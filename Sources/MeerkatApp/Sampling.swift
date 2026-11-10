import MeerkatKit
import SwiftUI

// MARK: - Rates

/// How often the Overview asks the daemon for each signal it polls. Presets
/// and the Custom choice both resolve to one of these; each feed's
/// parameters are built from them in `MetricsModel.feeds`, and the chart
/// history from them here.
///
/// The daemon shares a source between subscribers only when their parameters
/// match (`EventHub` keys instances by kind plus parameters), so rates that
/// differ from the rules' run their own samplers alongside them.
struct SamplingRates: Codable, Equatable {
    /// `cpu.sample`: headline CPU and load.
    var cpu: Double
    /// `memory.sample`, `disk.sample` and `network.sample`: one chart point
    /// per sample, for the CPU, memory, disk and network charts.
    var chart: Double
    /// `process.top` interval: refreshes the ranked rows.
    var rows: Double
    /// `process.top` rankInterval and `process.list` interval: a full process
    /// enumeration, the costly one, shared by both. Also the window of the
    /// disk card's process rows and of the resource pages' tables.
    var rank: Double
    /// `fs.churn` every: one `churnWindow` FSEvents window per period.
    var churnEvery: Double

    /// Seconds of FSEvents each churn reading collects.
    static let churnWindow = 4.0

    /// `battery.sample` does not follow the presets: the battery controller
    /// publishes new readings only every few seconds, and 5 s is the
    /// event's shortest interval.
    static let batteryInterval = 5.0
    /// `power.assertions`, for the Power page, which no preset changes.
    static let assertionInterval = 5.0

    static let relaxed = SamplingRates(cpu: 1, chart: 2, rows: 2, rank: 10, churnEvery: 60)
    static let normal = SamplingRates(cpu: 1, chart: 1, rows: 1, rank: 5, churnEvery: 25)
    static let live = SamplingRates(cpu: 0.25, chart: 0.5, rows: 0.5, rank: 2, churnEvery: 10)

    /// The charts cover the same time span at every rate.
    static let chartSpan = 120.0
    /// `chartSpan` as the axes and VoiceOver say it: "2 min".
    static let chartSpanText = SamplingStep.span(chartSpan)

    var historyLimit: Int { max(Int((Self.chartSpan / chart).rounded()), 2) }
    static let powerHistoryLimit = max(Int((chartSpan / batteryInterval).rounded()), 2)

    /// "cpu 1 Hz · charts 1 Hz · rows 1 Hz · rank 5 s"
    var cadenceSummary: String {
        [
            "cpu " + SamplingStep.rate(cpu), "charts " + SamplingStep.rate(chart),
            "rows " + SamplingStep.rate(rows), "rank " + SamplingStep.rate(rank),
        ].joined(separator: "  ·  ")
    }

    // MARK: Storage

    /// `UserDefaults` key for the Custom rates, as JSON.
    static let customKey = "samplingCustomRates"

    var json: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }

    /// The rates the stored settings select, for reads outside a view.
    static var stored: SamplingRates {
        let defaults = UserDefaults.standard
        let preset =
            defaults.string(forKey: SamplingPreset.defaultsKey).flatMap(SamplingPreset.init(rawValue:)) ?? .normal
        return preset.rates(custom: defaults.string(forKey: customKey).flatMap(SamplingRates.init(json:)))
    }
}

// In an extension, so the struct keeps its memberwise init.
extension SamplingRates {
    /// Decodes stored Custom rates; nil when absent or unreadable.
    /// Nil unless every rate is one the Settings menu could offer
    /// (`SamplingField.options`): the string is in `UserDefaults`, where
    /// anything can write it, and a zero chart interval would trap
    /// `historyLimit`.
    init?(json: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
            SamplingField.allCases.allSatisfy({ $0.options(in: value).contains(value[keyPath: $0.keyPath]) })
        else { return nil }
        self = value
    }
}

// MARK: - Presets

enum SamplingPreset: String, CaseIterable, Identifiable {
    case relaxed
    case normal
    case live
    case custom

    /// `UserDefaults` key; the Settings pane writes it, the Overview follows it.
    static let defaultsKey = "samplingPreset"

    var id: Self { self }

    var title: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .normal: return "Normal"
        case .live: return "Live"
        case .custom: return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .relaxed: return "Lightest on the machine. Good for leaving the window open all day."
        case .normal: return "The default."
        case .live: return "For watching a build or a spike. Ranks every process more often."
        case .custom: return "Choose each rate yourself."
        }
    }

    /// Nil for Custom, whose rates are stored separately.
    var fixedRates: SamplingRates? {
        switch self {
        case .relaxed: return .relaxed
        case .normal: return .normal
        case .live: return .live
        case .custom: return nil
        }
    }

    /// Custom falls back to Normal until rates have been stored.
    func rates(custom: SamplingRates?) -> SamplingRates {
        fixedRates ?? custom ?? .normal
    }
}

// MARK: - Custom fields

/// One row of the Custom rates: a signal the Overview polls, the label it
/// shows, and the steps it may take.
enum SamplingField: CaseIterable, Identifiable {
    case cpu
    case chart
    case rows
    case rank
    case churn

    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: return "CPU and load"
        case .chart: return "Charts"
        case .rows: return "Process rows"
        case .rank: return "Process ranking"
        case .churn: return "Path churn"
        }
    }

    var help: String {
        switch self {
        case .cpu: return "The CPU headline, the ring and the load average."
        case .chart: return "One point on the CPU, memory, disk and network charts per sample."
        case .rows: return "Refreshes the busiest processes already ranked."
        case .rank: return "Enumerates every process; the most expensive signal. Also the disk rows' window."
        case .churn:
            return
                "One \(SamplingStep.span(SamplingRates.churnWindow)) FSEvents window over the paths meerkat.json watches, per period."
        }
    }

    var keyPath: WritableKeyPath<SamplingRates, Double> {
        switch self {
        case .cpu: return \.cpu
        case .chart: return \.chart
        case .rows: return \.rows
        case .rank: return \.rank
        case .churn: return \.churnEvery
        }
    }

    /// Upper bounds that are view policy, not event limits: the charts span
    /// two minutes, so slower samples would leave them a handful of points.
    private var liveViewCap: Double {
        switch self {
        case .cpu, .chart, .rows: return 10
        case .rank: return 60
        case .churn: return 600
        }
    }

    /// A log-spaced ladder. It starts at 0.25 s so the CPU digit roll
    /// finishes before the next value.
    private static let ladder: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    /// The steps this field may take, given the other rates: the ladder,
    /// filtered by the `validate()` of every feed it sets (the check the
    /// daemon runs on subscribe, so a menu cannot offer what the daemon
    /// would reject) and by the live-view cap.
    /// The current value is kept when valid even off the ladder (Normal's
    /// 25 s churn period), so the menu always contains its selection.
    func options(in rates: SamplingRates) -> [Double] {
        Set(Self.ladder + [rates[keyPath: keyPath]]).sorted().filter { step in
            guard step <= liveViewCap else { return false }
            var candidate = rates
            candidate[keyPath: keyPath] = step
            // Rows on their own: pair them with an equal ranking interval so
            // only the rows' own limit applies; the ranking follows them.
            if self == .rows { candidate.rank = step }
            return isValid(candidate)
        }
    }

    /// `rates` with this field set to `value`, keeping the others valid:
    /// ranking moves up to the rows interval if it would fall below it.
    func setting(_ value: Double, in rates: SamplingRates) -> SamplingRates {
        var updated = rates
        updated[keyPath: keyPath] = value
        if self == .rows, updated.rank < value {
            updated.rank = SamplingField.rank.options(in: updated).first ?? value
        }
        return updated
    }

    private func isValid(_ rates: SamplingRates) -> Bool {
        MetricsModel.feeds.filter { $0.rates.contains(self) }.allSatisfy { feed in
            (try? feed.validate(rates)) != nil
        }
    }
}

// MARK: - Formatting

enum SamplingStep {
    /// "4 Hz" up to once a second, then "5 s", "2 min".
    static func rate(_ interval: Double) -> String {
        if interval <= 1 { return "\(formatted(1 / interval)) Hz" }
        return interval < 60 ? "\(formatted(interval)) s" : "\(formatted(interval / 60)) min"
    }

    /// "40 s", "2 min": how much time a chart covers.
    static func span(_ seconds: Double) -> String {
        seconds >= 120 ? "\(formatted(seconds / 60)) min" : "\(formatted(seconds)) s"
    }

    /// "every 0.25 s", "every 2 min": menu item text.
    static func every(_ interval: Double) -> String {
        "every " + (interval < 60 ? "\(formatted(interval)) s" : "\(formatted(interval / 60)) min")
    }

    private static func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
