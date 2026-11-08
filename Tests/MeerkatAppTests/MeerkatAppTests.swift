import AppKit
import Foundation
import MeerkatAgent
import MeerkatIPC
import MeerkatKit
import MeerkatRules
import SwiftUI
import Testing

@testable import MeerkatApp

/// The app's decision logic, apart from its views: the rates the Overview
/// asks the daemon for, how a lost daemon is explained, and how memory sizes
/// read.
struct SamplingTests {
    /// A preset the daemon would refuse leaves the Overview blank, so every
    /// preset's subscriptions must pass the check the daemon runs on
    /// subscribe.
    @Test(arguments: [SamplingRates.relaxed, .normal, .live])
    func presetsPassTheDaemonsValidation(rates: SamplingRates) throws {
        try rates.cpuParameters.validate()
        try rates.chartParameters.validate()
        try rates.diskParameters.validate()
        try rates.networkParameters.validate()
        try rates.processParameters().validate()
        try rates.listParameters.validate()
        try rates.churnParameters.validate()
        try SamplingRates.batteryParameters.validate()
        try SamplingRates.assertionParameters.validate()
    }

    /// Each Custom menu shows its current selection, even off the ladder
    /// (Normal's 25 s churn period).
    @Test(arguments: [SamplingRates.relaxed, .normal, .live])
    func everyMenuContainsItsSelection(rates: SamplingRates) {
        for field in SamplingField.allCases {
            #expect(field.options(in: rates).contains(rates[keyPath: field.keyPath]), "\(field)")
        }
    }

    /// Ranking can't be more frequent than the rows it feeds: slowing the
    /// rows past it moves the ranking along.
    @Test func slowerRowsLiftTheRanking() throws {
        let updated = SamplingField.rows.setting(10, in: .live)
        #expect(updated.rows == 10)
        #expect(updated.rank >= 10)
        try updated.processParameters().validate()
    }

    /// Custom falls back to Normal until rates are stored, and stored rates
    /// survive the round trip through `UserDefaults`' JSON string.
    @Test func customRatesRoundTripAndFallBack() {
        #expect(SamplingPreset.custom.rates(custom: nil) == .normal)
        #expect(SamplingRates(json: SamplingRates.live.json) == .live)
        #expect(SamplingRates(json: "{\"cpu\":") == nil)
        var zeroChart = SamplingRates.normal
        zeroChart.chart = 0
        #expect(SamplingRates(json: zeroChart.json) == nil)
        #expect(SamplingPreset.relaxed.rates(custom: .live) == .relaxed)
    }

    /// The charts cover `chartSpan` at every chart rate.
    @Test(arguments: [SamplingRates.relaxed, .normal, .live])
    func historyCoversTheChartSpan(rates: SamplingRates) {
        #expect(Double(rates.historyLimit) * rates.chart == SamplingRates.chartSpan)
    }
}

struct DaemonProblemTests {
    /// A daemon of another build needs a restart, not an install; any other
    /// failure, including a subscription lost across a restart, is explained
    /// by the agent's registration.
    @Test func onlyADifferentBuildAsksForARestart() {
        let different = DaemonProblem(
            fault: DaemonFault(DaemonClient.ClientError.differentBuild("v2")), agent: .enabled)
        #expect(different.title == "meerkatd is a different build")

        let resubscribe = DaemonFault(
            DaemonClient.ClientError.resubscribeFailed(kind: "cpu.sample", reason: "starting"))
        #expect(!resubscribe.isDifferentBuild)
        #expect(DaemonProblem(fault: resubscribe, agent: .enabled).title == "meerkatd isn't answering")
        #expect(DaemonProblem(fault: resubscribe, agent: .notRegistered).title == "meerkatd isn't installed")
    }
}

struct MemorySizeTests {
    /// Payloads carry decimal megabytes; macOS labels binary multiples GB,
    /// so a 16 GiB Mac reads "16 GB" rather than "17.18 GB".
    @Test func binaryMultiplesReadAsMacOSShowsThem() {
        let sixteenGiB = Double(16 << 30) / 1_000_000
        #expect(MemorySize.bytes(megabytes: sixteenGiB) == 16 << 30)
        let parts = MemorySize.parts(megabytes: sixteenGiB)
        #expect(parts.value == "16")
        #expect(parts.unit == "GB")
    }

    /// A reading `Int64` cannot hold is clamped, not trapped on.
    @Test func outOfRangeReadingsClamp() {
        #expect(MemorySize.bytes(megabytes: .nan) == 0)
        #expect(MemorySize.bytes(megabytes: .infinity) == .max)
        #expect(MemorySize.bytes(megabytes: 1e300) == .max)
        #expect(MemorySize.bytes(megabytes: -.infinity) == .min)
    }
}

/// Other users' processes report CPU only: their other columns are unknown,
/// not zero.
struct ProcessCounterTests {
    @Test func unknownReadsAsADashNotAZero() {
        #expect(ProcessCounter(value: nil).text { String($0) } == "–")
        #expect(ProcessCounter(value: 0).text { String($0) } == "0.0")
    }

    @Test func unknownSortsBelowEveryReading() {
        let sorted = [ProcessCounter(value: 2), .init(value: nil), .init(value: 0)].sorted(by: >)
        #expect(sorted.map(\.value) == [2, 0, nil])
        // Two unknowns are unordered: neither sorts below the other.
        let unknown = ProcessCounter(value: nil)
        let alsoUnknown = ProcessCounter(value: nil)
        #expect(!(unknown < alsoUnknown))
    }
}

@Suite("Rolling series")
struct RollingSeriesTests {
    @Test("each series numbers its own samples one by one, as SlidingPlot needs to glide")
    func numbering() {
        var disk = RollingSeries<Double>()
        var network = RollingSeries<Double>()
        for value in 1...3 {
            disk.append(Double(value), limit: 2)
            network.append(Double(value), limit: 2)
        }
        #expect(disk.points.map(\.id) == [2, 3])
        #expect(network.points.map(\.id) == [2, 3])
        #expect(disk.last == 3)
    }

    @Test("a filling series spans its whole window, so each sample moves the chart one slot")
    func windowWhileFilling() {
        var series = RollingSeries<Double>()
        series.append(1, limit: 5)
        #expect(windowDomain(series) == -4...1)
        series.append(2, limit: 5)
        #expect(windowDomain(series) == -3...2)
        #expect(series.drawn.map(\.id) == [1, 2])
        for value in 3...7 { series.append(Double(value), limit: 5) }
        #expect(windowDomain(series) == 2...7)
        #expect(series.points.map(\.id) == [3, 4, 5, 6, 7])
        // The spare departed sample covers an interrupted glide's left edge.
        #expect(series.drawn.map(\.id) == [2, 3, 4, 5, 6, 7])
        #expect(series.map { $0 * 2 }.capacity == 5)
    }

    @Test("clearing keeps numbering, so a mark never reuses an id")
    func clearing() {
        var series = RollingSeries<Double>()
        series.append(1, limit: 5)
        series.clear()
        series.append(2, limit: 5)
        #expect(series.points.map(\.id) == [2])
        #expect(series.departed.isEmpty)
    }

    @Test("a mapped series keeps its numbering and what scrolled out")
    func mapping() {
        var series = RollingSeries<Double>()
        for value in 1...4 { series.append(Double(value), limit: 2) }
        let doubled = series.map { $0 * 2 }
        #expect(doubled.points.map(\.id) == [3, 4])
        #expect(doubled.points.map(\.value) == [6, 8])
        #expect(doubled.departed.map(\.id) == [1, 2])
    }

    @Test("a series remembers only as many departed samples as the scale uses")
    func departedIsBounded() {
        var series = RollingSeries<Double>()
        for value in 0..<(StickyTop.memory + 10) { series.append(Double(value), limit: 3) }
        #expect(series.departed.count == StickyTop.memory)
        #expect(series.departed.last.map { $0.id + 1 } == series.points.first?.id)
    }
}

@Suite("Sliding plot")
@MainActor
struct SlidingPlotTests {
    @Test("a glide lasts the gap between samples, bounded at both ends")
    func glideDuration() {
        #expect(SlidingPlotView.glideDuration(gap: 2) == 2)
        #expect(SlidingPlotView.glideDuration(gap: 0) == 0.1)
        #expect(SlidingPlotView.glideDuration(gap: 3600) == SamplingRates.chartSpan)
    }

    @Test("a glide cut short starts from where the drawing is, as far as the hidden slots reach")
    func glideStart() {
        #expect(SlidingPlotView.glideStart(slot: 10, inFlight: 0) == 10)
        #expect(SlidingPlotView.glideStart(slot: 10, inFlight: 4) == 14)
        #expect(SlidingPlotView.glideStart(slot: 10, inFlight: 25) == CGFloat(SlidingPlotView.hidden) * 10)
    }

    @Test("a new scale starts stretched to look like the one shown")
    func verticalMap() throws {
        // The top doubles: the new drawing starts twice as tall, so a value
        // keeps its place on screen.
        let grow = try #require(VerticalMap(from: 0...10, to: 0...20))
        #expect(grow == VerticalMap(scale: 2, offset: 0))
        // A banded range shifts up a quarter of the shown span.
        let shift = try #require(VerticalMap(from: 100...140, to: 110...150))
        #expect(shift == VerticalMap(scale: 1, offset: 0.25))
        // 15 in 0...20 sits at 0.75 of the drawing; shown over 0...10 it
        // would sit at 1.5: the stretched drawing puts it there.
        #expect(grow.scale * 0.75 + grow.offset == 1.5)
        #expect(VerticalMap(from: 5...5, to: 0...1) == nil)
        // Mid-rescale, the next change composes with what is on screen.
        let half = VerticalMap(scale: 0.5, offset: 0)
        #expect(half.after(grow) == VerticalMap(scale: 1, offset: 0))
    }
}

@Suite("Sticky top")
struct StickyTopTests {
    private func peak(_ series: RollingSeries<Double>) -> Double? { StickyTop.peak(of: series) { $0 } }

    @Test("an empty series has no peak")
    func empty() {
        var series = RollingSeries<Double>()
        #expect(peak(series) == nil)
        series.append(5, limit: 2)
        series.clear()
        #expect(peak(series) == nil)
    }

    @Test("a spike holds the top while drawn, then shrinks 6% a sample")
    func decay() {
        var series = RollingSeries<Double>()
        for value in [10.0, 1] { series.append(value, limit: 2) }
        #expect(peak(series) == 10)
        series.append(1, limit: 2)
        #expect(abs(peak(series)! - 9.4) < 1e-9)
        series.append(1, limit: 2)
        #expect(abs(peak(series)! - 10 * 0.94 * 0.94) < 1e-9)
    }

    /// The top used to be kept in view state and advanced once a sample:
    /// grow to the window's peak, else shrink 6%. As a function of the
    /// series it must draw the same top.
    @Test("the top is the one the per-sample recurrence reached")
    func matchesTheRecurrence() {
        var series = RollingSeries<Double>()
        var kept: Double?
        var seed: UInt64 = 7
        for _ in 0..<40 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = seed >> 60 == 0 ? 50 : Double(seed >> 59)
            series.append(value, limit: 6)
            let window = series.points.map(\.value).max()!
            kept = max(window, (kept ?? window) * 0.94)
            #expect(abs(peak(series)! - kept!) < 1e-9)
        }
    }
}

@Suite("Rule file source")
struct RuleFileSourceTests {
    @Test(
        "an export name is a valid identifier",
        arguments: [
            ("xcode-hot", "xcodeHot"), ("delete", "ruleDelete"), ("9-lives", "rule9Lives"),
            ("Mixed-CaseName", "mixedCaseName"), ("h²o", "hO"), ("①-watch", "watch"), ("½", "rule"),
            ("監視-cpu", "監視Cpu"), ("snake_case", "snakeCase"),
        ])
    func identifier(name: String, expected: String) {
        #expect(RuleFileSource.identifier(RuleFileSource.words(name)) == expected)
    }

    @Test("a name with no words takes the caller's fallback")
    func empty() {
        #expect(RuleFileSource.identifier([], empty: "processRule") == "processRule")
    }

    @Test("a rule made from a process named like a keyword compiles as an export")
    func sheetUsesTheGuard() {
        var draft = ProcessRuleDraft(process: "delete")
        draft.fileName = "delete.ts"
        #expect(draft.source.contains("export const ruleDelete = rule({"))
    }

    /// The preview builds as the numbers are typed, before `problem` is
    /// shown, so no number may trap.
    @Test(arguments: [1e20, 1e300, -1e20])
    func anyNumberBuildsAPreview(value: Double) {
        var draft = ProcessRuleDraft(process: "worker")
        draft.minutes = value
        draft.threshold = value
        #expect(!draft.source.isEmpty)
        #expect(draft.problem != nil)
    }

    /// What the sheet says loads must load: `process.hot` stops at a day,
    /// and whole seconds at zero.
    @Test(arguments: [(2000.0, false), (0.001, false), (1440.0, true), (5.0, true)])
    func durationsTheDaemonRefusesAreProblems(minutes: Double, valid: Bool) {
        var draft = ProcessRuleDraft(process: "worker")
        draft.minutes = minutes
        #expect((draft.problem == nil) == valid)
    }

    /// A process name is any string, line breaks included: it goes in only
    /// as string literals that read back as the same string, so none of it
    /// can end a comment or start a line of code.
    @Test(arguments: ["evil\nprocess.exit(1)", "evil\r\nprocess.exit(1)", "evil\u{2028}process.exit(1)"])
    func aProcessNameNeverBecomesCode(name: String) throws {
        let draft = ProcessRuleDraft(process: name)
        let lines = draft.source.components(separatedBy: .newlines)
        #expect(!lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("process.exit") })
        let literal = ProcessRuleDraft.literal(name)
        #expect(draft.source.contains("name: \(literal)"))
        #expect(try JSONDecoder().decode(String.self, from: Data(literal.utf8)) == name)
    }

    /// The sheet and the editor agree on what a rule file may be called.
    @Test(arguments: ["types.d.ts", "../escape.ts", "sub/rule.ts", ".hidden.ts", " "])
    func aFileNameTheEditorRefusesIsAProblem(fileName: String) {
        var draft = ProcessRuleDraft(process: "worker")
        draft.fileName = fileName
        #expect(draft.problem != nil)
    }

    /// A rule for a process observes processes, and every user's only when
    /// the process is another user's.
    @Test(arguments: [(false, "own"), (true, "all")])
    func theRuleObservesWhatItNeeds(otherUser: Bool, level: String) {
        for action in ProcessRuleDraft.Action.allCases {
            var draft = ProcessRuleDraft(process: "worker", otherUser: otherUser)
            draft.action = action
            #expect(draft.source.contains("process: { observe: \"\(level)\""), "\(action)")
        }
    }

    /// What the editor's template and the sheet write is a rule as the real
    /// declarations type it: text checks can't tell that a capability or
    /// an observation grant is spelled the way `meerkat.d.ts` requires.
    @Test func whatTheAppWritesTypeChecks() async throws {
        let toolchain = try #require(TypeScriptToolchain.locate(), "set MEERKAT_TSRS, as buck2 test does")
        let runtime = try #require(toolchain.runtimeDeclarations, "set MEERKAT_RUNTIME_TYPES, as buck2 test does")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppRuleSources-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var files = ["new-rule.ts": RuleEditorModel.template(for: "new-rule.ts")]
        for action in ProcessRuleDraft.Action.allCases {
            for otherUser in [false, true] {
                var draft = ProcessRuleDraft(process: "worker", otherUser: otherUser)
                draft.action = action
                draft.fileName = "worker-\(action.rawValue)-\(otherUser ? "all" : "own").ts"
                files[draft.fileName] = draft.source
            }
        }
        for (name, text) in files { try Data(text.utf8).write(to: directory.appendingPathComponent(name)) }

        let output = try await RuleCompiler(toolchain: toolchain).compile(
            rulesDirectory: directory, workDirectory: directory.appendingPathComponent(".work"),
            declarations: TypeScriptDeclarations.render(),
            runtimeDeclarations: try String(contentsOf: runtime, encoding: .utf8))
        #expect(output.diagnostics.isEmpty, "\(output.diagnostics)")
        #expect(Set(output.entries) == Set(files.keys.map { ($0 as NSString).deletingPathExtension }))
    }

    @Test func aLongDurationStaysWithinTheRateLimit() {
        var draft = ProcessRuleDraft(process: "worker")
        draft.minutes = 1440
        #expect(draft.source.contains("throttleSeconds: 86400"))
    }
}

#if DEBUG
    /// The rules folder is the daemon's, which can move at a restart.
    @MainActor
    struct RulesFolderTests {
        /// A daemon whose `RulesDirectory` the test moves.
        private actor MovingDaemon: DaemonConnection {
            var folder = "/rules/one"
            func move(to folder: String) { self.folder = folder }

            func send(_ request: DaemonRequest) async throws -> DaemonReply {
                switch request {
                case .rules: return .rules(RulesReport(rules: [], diagnostics: [], compiledAt: nil))
                case .status:
                    let s = SampleData.status(uptime: 1)
                    return .status(
                        DaemonStatus(
                            version: s.version, pid: s.pid, startedAt: s.startedAt, executablePath: s.executablePath,
                            rulesDirectory: folder, handlerHost: s.handlerHost, sources: s.sources, rules: s.rules,
                            configuration: s.configuration))
                default: throw DaemonClient.ClientError.unexpectedReply("\(request)")
                }
            }

            func subscribe(_ kind: String, parameters: JSONValue) async throws
                -> AsyncThrowingStream<EventEnvelope, any Error>
            {
                AsyncThrowingStream { _ in }
            }
        }

        @Test func aMovedFolderIsFollowed() async {
            let daemon = MovingDaemon()
            let model = RulesModel(client: daemon)
            await model.refresh()
            #expect(model.rulesDirectory == "/rules/one")
            // `meerkat agent restart` after moving `RulesDirectory`.
            await daemon.move(to: "/rules/two")
            await model.refresh()
            #expect(model.rulesDirectory == "/rules/two")
            #expect(model.fileURL("a.ts").path == "/rules/two/a.ts")
        }
    }

    @Suite("Sample daemon")
    struct SampleDaemonTests {
        private func first(
            _ stream: AsyncThrowingStream<EventEnvelope, any Error>, count: Int
        ) async throws -> [EventEnvelope] {
            var received: [EventEnvelope] = []
            for try await envelope in stream {
                received.append(envelope)
                if received.count == count { break }
            }
            return received
        }

        @Test("toggles stay in the sample report")
        func toggles() async throws {
            let daemon = SampleDaemon()
            let rule = try #require(SampleData.rules.rules.first { $0.state == .loaded })
            let report = try await daemon.setRule(rule.id, enabled: false)
            #expect(report.rules.first { $0.id == rule.id }?.state == .disabled)
            #expect(try await daemon.rules() == report)
        }

        @Test("status keeps the real rules folder, so the Rules page's folder does not change")
        func rulesFolder() async throws {
            let status = try await SampleDaemon().status()
            #expect(status.rulesDirectory == DaemonPaths.standard().rulesDirectory.path)
        }

        @Test("dropped reports arrive once, with past times, oldest first")
        func dropped() async throws {
            let daemon = SampleDaemon()
            let reports = try await first(
                try await daemon.subscribe(MeerkatDroppedEvent.descriptor.name, parameters: .object([:])), count: 2)
            #expect(reports.map { $0.payload["dropped"]?.numberValue } == [100, 212])
            #expect(reports.map { $0.payload["file"]?.stringValue } == ["downloads.ts", nil])
            #expect(reports[0].time < reports[1].time)
            #expect(reports[1].time < Date().timeIntervalSince1970 * 1000)

            let again = try await daemon.subscribe(MeerkatDroppedEvent.descriptor.name, parameters: .object([:]))
            let silent = Task { try await first(again, count: 1) }
            try await Task.sleep(for: .milliseconds(50))
            silent.cancel()
            #expect(try await silent.value.isEmpty)
        }

        @Test("the Health page keeps which file each dropped report is for")
        @MainActor
        func droppedFiles() async throws {
            let model = HealthModel(client: SampleDaemon())
            let watching = Task { await model.watch() }
            defer { watching.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while model.dropped.count < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            // Newest first.
            #expect(model.dropped.map(\.file) == [nil, "downloads.ts"])
            #expect(model.dropped.map(\.dropped) == [212, 100])
        }

        @Test("a kind with no feed stays open and silent, like meerkat.rule")
        func quiet() async throws {
            let stream = try await SampleDaemon().subscribe("meerkat.rule", parameters: .object([:]))
            let silent = Task { try await first(stream, count: 1) }
            try await Task.sleep(for: .milliseconds(50))
            silent.cancel()
            #expect(try await silent.value.isEmpty)
        }

        private func decodes<Kind: EventKind>(_ kind: Kind.Type, _ parameters: Kind.Parameters) async throws {
            for try await (_, envelope) in try await SampleDaemon().events(kind, parameters: parameters) {
                #expect(envelope.kind == Kind.descriptor.name)
                return
            }
        }

        @Test("the Overview's feeds decode as their kinds' payloads")
        func feeds() async throws {
            let rates = SamplingRates.normal
            try await decodes(CPUSampleEvent.self, rates.cpuParameters)
            try await decodes(MemorySampleEvent.self, rates.chartParameters)
            try await decodes(MemoryPressureEvent.self, NoParameters())
            try await decodes(DiskSampleEvent.self, rates.diskParameters)
            try await decodes(NetworkSampleEvent.self, rates.networkParameters)
            try await decodes(BatterySampleEvent.self, SamplingRates.batteryParameters)
            try await decodes(PowerSourceEvent.self, NoParameters())
            try await decodes(ThermalStateEvent.self, NoParameters())
            try await decodes(LowPowerModeEvent.self, NoParameters())
            try await decodes(ProcessTopEvent.self, rates.processParameters())
            try await decodes(ProcessListEvent.self, rates.listParameters)
            try await decodes(FSChurnEvent.self, rates.churnParameters)
        }
    }
#endif

/// Status words are small text: in the light appearance they must reach
/// WCAG AA's 4.5:1, which the system's green, orange and red do not.
@MainActor
struct StatusTextTests {
    /// Relative luminance of `color` resolved for `appearance`, over white
    /// when it is translucent.
    private func luminance(_ color: NSColor, in appearance: NSAppearance.Name, over: Double = 1) -> Double {
        var resolved = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        func linear(_ c: CGFloat) -> Double {
            let value = Double(c) * Double(resolved.alphaComponent) + over * (1 - Double(resolved.alphaComponent))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(resolved.redComponent) + 0.7152 * linear(resolved.greenComponent) + 0.0722
            * linear(resolved.blueComponent)
    }

    private func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    @Test func statusTextIsReadableOnLightSurfaces() {
        let pairs: [(text: NSColor, fill: NSColor)] = [
            (.normalText, .systemGreen), (.warnText, .systemOrange), (.criticalText, .systemRed),
        ]
        for (text, fill) in pairs {
            let word = luminance(text, in: .aqua)
            #expect(contrast(word, 1) >= 4.5, "\(fill) on white")
            // `StatusBadge`'s capsule: a 14% tint of the status colour.
            let capsule = luminance(fill.withAlphaComponent(0.14), in: .aqua)
            #expect(contrast(word, capsule) >= 4.5, "\(fill) on its capsule")
            // What it replaces did not: the reason it exists.
            #expect(contrast(luminance(fill, in: .aqua), 1) < 4.5, "\(fill)")
        }
    }

    @Test func onlyStatusColoursChangeAsText() {
        #expect(Theme.text(Theme.warn) != Theme.warn)
        #expect(Theme.text(Theme.critical) != Theme.critical)
        #expect(Theme.text(Theme.normal) != Theme.normal)
        #expect(Theme.text(.secondary) == .secondary)
        #expect(Theme.text(Theme.cpu) == Theme.cpu)
    }
}
