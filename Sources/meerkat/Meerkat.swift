import ArgumentParser
import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatStore

// meerkat — measurement CLI.
//
// Two modes that matter for before/after work:
//   sample:  --repeat N --label X --db FILE       (N samples, SQLite time series)
//   compare: meerkat compare FILE                (medians and ranges per label)
//
// The compare command exists because a single sample cannot detect a change:
// on a loaded host total CPU varies 2.4x run to run. Only medians over several
// samples with non-overlapping ranges mean anything.

@main
struct Meerkat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meerkat",
        abstract: "Unprivileged macOS system telemetry, events and rules.",
        discussion: """
            For coding agents: `meerkat skills` has instructions on using Meerkat, and `meerkat mcp` serves \
            it over MCP.

            Commands that print data print JSON with --json, or always. Exit statuses: \(ExitStatus.summary) \
            With --json, a failure other than a check's findings writes one JSON object to stderr, \
            {"error": {"status": N, "message": "..."}}, after any notes in text.
            """,
        subcommands: [
            Sample.self, Analyze.self, Compare.self,
            Status.self, Events.self, Effects.self, Rules.self, Config.self, Types.self, Agent.self, MCPBridge.self,
            Skills.self,
        ]
    )
}

// MARK: - Small helpers

func stderrLine(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func padField(_ text: String, _ width: Int, right: Bool = false) -> String {
    guard text.count < width else { return text }
    let fill = String(repeating: " ", count: width - text.count)
    return right ? fill + text : text + fill
}

/// Opens an existing store read-only, distinguishing a missing file from a
/// database that fails to open or is not a store of this build's schema.
/// Reading changes nothing in the file.
func openExistingStore(_ path: String) throws -> SampleStore {
    let expanded = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expanded) else {
        throw CommandFailure("no database at \(expanded)", status: ExitStatus.noInput)
    }
    return try SampleStore(readingFrom: expanded)
}

/// Order of metrics in every summary table.
let metricOrder = SampleMetric.allCases.map(\.rawValue)

// MARK: - sample

struct Sample: AsyncParsableCommand, JSONOutput {
    static let configuration = CommandConfiguration(
        abstract: "Take one or more samples.",
        discussion:
            "Prints one sample as JSON, or a summary when --repeat is above 1. Exits non-zero after the run if any sample could not be written to --db or retention failed. A sample that can't be taken ends the run, and the summary covers the samples taken."
    )

    @Option(help: "CPU, I/O and churn window in seconds.")
    var window = SystemSampler.Options().window

    @Option(help: "Processes to report.")
    var top = SystemSampler.Options().top

    @Option(name: .customLong("churn"), help: "Also count FSEvents change activity under this path, over the window.")
    var churnPath: String?

    @Option(help: "Path components per churn bucket.")
    var churnDepth = SystemSampler.Options().churnDepth

    @Option(name: .customLong("repeat"), help: "Take N samples and print a summary.")
    var repeatCount = 1

    @Option(help: "Tag samples; required for a meaningful compare.")
    var label = "unlabelled"

    @Option(name: .customLong("db"), help: "Write each sample to this SQLite time-series store.")
    var dbPath: String?

    @Option(help: "Keep only the newest N samples under --label after writing.")
    var retain: Int?

    @Flag(help: "Pretty-print JSON.")
    var pretty = false

    @Flag(help: "Print JSON: the sample, as without --table, or with --repeat the summary.")
    var json = false

    @Flag(help: "Human-readable single sample.")
    var table = false

    @Flag(help: "Only processes whose executable ships with macOS (by path; see docs/cli.md).")
    var systemOnly = false

    @Flag(name: .shortAndLong, help: "Suppress the sample output (for recorders).")
    var quiet = false

    func validate() throws {
        guard window > 0 else { throw ValidationError("--window must be greater than 0") }
        guard top > 0 else { throw ValidationError("--top must be greater than 0") }
        guard churnDepth > 0 else { throw ValidationError("--churn-depth must be greater than 0") }
        guard repeatCount > 0 else { throw ValidationError("--repeat must be greater than 0") }
        if let retain, retain <= 0 {
            throw ValidationError("--retain must be greater than 0")
        }
        guard !(json && table) else { throw ValidationError("use --json or --table, not both") }
    }

    func run() async throws {
        let store = try dbPath.map(Self.openOrCreateStore)

        let encoder = JSONEncoder.meerkat(pretty: pretty)

        let (collected, problems) = await record(into: store, sampling: takeSample) { index, sample in
            if repeatCount > 1 {
                stderrLine("sample \(index + 1)/\(repeatCount) taken")
            } else if quiet {
                // Recorder mode: the failure still reports what went wrong.
            } else if table {
                printTable(sample)
            } else {
                FileHandle.standardOutput.write(try encoder.encode(sample))
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }

        if repeatCount > 1, !collected.isEmpty {
            let summary = BatchSummary(
                label: label, count: collected.count, metrics: Spread.byMetric(collected.map(\.coreMetrics)))
            if json {
                try printJSON(summary, pretty: pretty)
            } else {
                printBatchSummary(summary)
            }
        }
        if !problems.isEmpty { throw CommandFailure(problems.joined(separator: "\n")) }
    }

    /// Takes the samples, recording each in `store` with `--retain`
    /// (`SampleStore.record`) and passing it to `show`. A failed write does
    /// not stop the run (the other samples are still worth having); a
    /// failed sample does. Either way the run ends with every problem, in
    /// order, so a recorder that only watches the exit status notices, and
    /// none is lost to a later one.
    func record(
        into store: SampleStore?, sampling: () async throws -> SystemSample,
        show: (_ index: Int, SystemSample) throws -> Void
    ) async -> (samples: [SystemSample], problems: [String]) {
        var problems: [String] = []
        var collected: [SystemSample] = []
        for index in 0..<repeatCount {
            let sample: SystemSample
            do {
                sample = try await sampling()
            } catch {
                problems.append("\(error)")
                break
            }
            collected.append(sample)

            if let store {
                do {
                    try store.record(sample, label: label, retain: retain)
                } catch let error as LimitsNotAppliedError {
                    // Committed: written once, not to be written again.
                    problems.append("\(error)")
                } catch {
                    problems.append("could not write sample: \(error)")
                }
            }
            do {
                try show(index, sample)
            } catch {
                problems.append("could not encode sample: \(error)")
            }
        }
        return (collected, problems)
    }

    private static func openOrCreateStore(_ path: String) throws -> SampleStore {
        try SampleStore(
            path: (path as NSString).expandingTildeInPath,
            limits: recordingLimits(file: DaemonPaths.standard().configurationFile))
    }

    /// The budget `meerkat.json` sets, which every insert applies. It is
    /// what deletes samples, so a file that can't be read stops the write
    /// rather than falling back to the defaults.
    static func recordingLimits(file: URL) throws -> SampleStore.Limits {
        guard FileManager.default.fileExists(atPath: file.path) else { return .standard }
        return SampleStore.Limits(try MeerkatConfiguration.decode(Data(contentsOf: file)).samples)
    }

    private func takeSample() async throws -> SystemSample {
        do {
            return try await SystemSampler.sample(
                SystemSampler.Options(
                    window: window, top: top, systemOnly: systemOnly,
                    churnPath: churnPath, churnDepth: churnDepth
                ))
        } catch {
            throw CommandFailure("sampling failed: \(error)")
        }
    }
    private func printTable(_ s: SystemSample) {
        print("host \(s.host)  cores \(s.cpuCount)  window \(String(format: "%.1f", s.windowSeconds))s")
        print(String(format: "load %.2f %.2f %.2f", s.load1, s.load5, s.load15))
        print(
            String(
                format: "mem  free %.0fMB  compressed %.0fMB  wired %.0fMB  swap %.0fMB",
                s.memory.freeMB, s.memory.compressedMB, s.memory.wiredMB, s.memory.swapUsedMB))
        print("cpu  " + (s.cpuUsagePercent.map { String(format: "%.1f%% of %d cores", $0, s.cpuCount) } ?? "unknown"))
        // "-" is a counter the kernel refused (another user's process).
        func column(_ value: Double?, _ format: String, width: Int) -> String {
            padField(value.map { String(format: format, $0) } ?? "-", width, right: true)
        }
        print("\npid      cpu%   rMB/s  wMB/s    footprint  name")
        for p in s.processes {
            print(
                padField("\(p.pid)", 7) + padField(String(format: "%.1f", p.cpuPct), 7, right: true)
                    + column(p.diskReadMBps, "%.1f", width: 7)
                    + column(p.diskWriteMBps, "%.1f", width: 7)
                    + column(p.footprintMB, "%.0fMB", width: 12)
                    + "  " + terminalSafe(p.name))
        }
        if let c = s.churn {
            print(
                "\nchurn  \(c.totalEvents) events in \(Int(c.windowSeconds))s "
                    + "(created \(c.created), modified \(c.modified), removed \(c.removed), renamed \(c.renamed))")
            for b in c.buckets {
                print(String(format: "  %5d  ", b.events) + terminalSafe(b.path))
            }
        }
    }

    /// What --repeat reports: each metric's median and range over the batch.
    struct BatchSummary: Encodable {
        let label: String
        let count: Int
        let metrics: [String: Spread]
    }

    private func printBatchSummary(_ summary: BatchSummary) {
        let colWidth = 24
        var lines = [padField("metric", 16) + padField("median", colWidth) + padField("range", colWidth)]
        for key in metricOrder {
            guard let spread = summary.metrics[key] else { continue }
            lines.append(
                padField(key, 16)
                    + padField(String(format: "%.1f", spread.median), colWidth)
                    + padField(String(format: "%.0f - %.0f", spread.min, spread.max), colWidth))
        }
        lines.append("")
        lines.append("label \"\(label)\", n=\(summary.count) — write with --db, then run compare")
        print(lines.joined(separator: "\n"))
    }
}

// MARK: - compare

struct Compare: ParsableCommand, JSONOutput {
    static let configuration = CommandConfiguration(
        abstract: "Per-label medians and ranges, with the delta between two labels.",
        discussion: """
            With exactly two labels, also lists the metrics whose ranges overlap, which this many samples \
            can't separate, and those too noisy within a label to judge. Exits \(ExitStatus.failure.code) when the store has no \
            samples, and \(ExitStatus.noInput.code) when there is no store.
            """
    )

    @Argument(help: "SQLite store written with --db.")
    var db: String

    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let records = try openExistingStore(db).allMetrics()
        let comparison = SampleComparison(records)
        guard !comparison.labels.isEmpty else {
            throw CommandFailure("no samples in \((db as NSString).expandingTildeInPath)")
        }
        if json { return try printJSON(comparison, pretty: true) }
        print(Self.lines(comparison).joined(separator: "\n"))
    }

    static func lines(_ comparison: SampleComparison) -> [String] {
        let colWidth = 22
        var lines: [String] = []
        var head = padField("label", 14) + " " + padField("n", 3)
        for key in metricOrder { head += " " + padField(key, colWidth) }
        lines.append(head)

        for label in comparison.labels {
            var row = padField(terminalSafe(label.label), 14) + " " + padField("\(label.count)", 3)
            for key in metricOrder {
                let cell = label.metrics[key].map { String(format: "%.0f [%.0f-%.0f]", $0.median, $0.min, $0.max) }
                row += " " + padField(cell ?? "-", colWidth)
            }
            lines.append(row)
        }

        if let delta = comparison.delta {
            var row = padField("delta", 14) + " " + padField("", 3)
            for key in metricOrder {
                let cell = delta[key].flatMap { change in
                    change.percent.map { String(format: "%+.0f (%+.0f%%)", change.change, $0) }
                }
                row += " " + padField(cell ?? "-", colWidth)
            }
            lines.append("")
            lines.append(row)
        }

        if comparison.labels.count > 2 {
            lines.append("")
            lines.append("note: \(comparison.labels.count) labels present; delta shown only for exactly two")
        }
        if !comparison.overlapping.isEmpty {
            lines.append("")
            lines.append(
                "overlapping ranges (not separable at this sample count): "
                    + comparison.overlapping.joined(separator: ", "))
        }
        if !comparison.noisy.isEmpty {
            lines.append(
                "high within-label variance (increase --repeat or --window): "
                    + comparison.noisy.joined(separator: ", "))
        }
        return lines
    }
}

// MARK: - analyze

struct Analyze: ParsableCommand, JSONOutput {
    static let configuration = CommandConfiguration(
        abstract: "Per-label and per-process summary of a store.",
        discussion: "Exits \(ExitStatus.noInput.code) when there is no store."
    )

    @Argument(help: "SQLite store written with --db.")
    var db: String

    @Flag(help: "Print JSON, with every process rather than the busiest.") var json = false

    /// What the store holds: each label's spread, and each process's CPU
    /// across the samples it appears in.
    struct Analysis: Encodable {
        struct Process: Encodable {
            let name: String
            /// Percent of one core: the mean over the samples it was in, and the most.
            let meanCPUPct: Double
            let peakCPUPct: Double
            /// How many samples it was in.
            let seen: Int
        }

        let records: Int
        let labels: [LabelSummary]
        /// Busiest first.
        let processes: [Process]
    }

    func run() throws {
        let store = try openExistingStore(db)
        let analysis = Self.analysis(labels: try store.labelMetrics(), usage: try store.processUsage())
        if json { return try printJSON(analysis, pretty: true) }

        print("records: \(analysis.records) in \((db as NSString).expandingTildeInPath)")
        print("")
        print("PER-LABEL (median, range)")
        print(
            padField("label", 14) + padField("n", 4, right: true)
                + padField("cpu_usage", 12, right: true) + padField("range", 16, right: true)
                + padField("compressed", 12, right: true) + padField("swap", 10, right: true))
        // "-" where no sample of the label has the value.
        func median(_ spread: Spread?, _ format: String) -> String {
            spread.map { String(format: format, $0.median) } ?? "-"
        }
        for entry in analysis.labels {
            let range = entry.cpuUsagePct.map { String(format: "%.0f-%.0f", $0.min, $0.max) } ?? "-"
            print(
                padField(terminalSafe(entry.label), 14)
                    + padField(String(entry.count), 4, right: true)
                    + padField(median(entry.cpuUsagePct, "%.1f"), 12, right: true)
                    + padField(range, 16, right: true)
                    + padField(median(entry.compressedGB, "%.2f"), 12, right: true)
                    + padField(median(entry.swapGB, "%.2f"), 10, right: true))
        }

        print("")
        print("PER-PROCESS (across \(analysis.records) records; mean of samples where present)")
        print(
            padField("mean cpu%", 10, right: true) + padField("peak", 8, right: true)
                + padField("seen/n", 8, right: true) + "  name")
        for process in analysis.processes.prefix(18) {
            print(
                padField(String(format: "%.1f", process.meanCPUPct), 10, right: true)
                    + padField(String(format: "%.1f", process.peakCPUPct), 8, right: true)
                    + padField("\(process.seen)/\(analysis.records)", 8, right: true) + "  "
                    + terminalSafe(process.name))
        }
    }

    /// Processes are grouped by their short name, which the sampler gives
    /// every row (`ProcessCounters.name`), so one program's instances and
    /// runs are one line.
    static func analysis(labels: [SampleStore.LabelMetrics], usage: [SampleStore.ProcessUsage]) -> Analysis {
        var grouped: [String: (values: [Double], peak: Double, samples: Set<Int>)] = [:]
        for row in usage {
            var entry = grouped[row.name] ?? (values: [], peak: 0, samples: [])
            entry.values.append(row.cpuPct)
            entry.peak = max(entry.peak, row.cpuPct)
            entry.samples.insert(row.sampleID)
            grouped[row.name] = entry
        }
        let processes = grouped.map { name, entry in
            Analysis.Process(
                name: name, meanCPUPct: entry.values.reduce(0, +) / Double(max(1, entry.values.count)),
                peakCPUPct: entry.peak, seen: entry.samples.count)
        }
        // Ties by name, so the order doesn't depend on the dictionary's.
        .sorted { ($0.meanCPUPct, $1.name) > ($1.meanCPUPct, $0.name) }
        return Analysis(
            records: labels.reduce(0) { $0 + $1.count },
            labels: labels.sorted { $0.count > $1.count }.map(LabelSummary.init),
            processes: processes)
    }
}
