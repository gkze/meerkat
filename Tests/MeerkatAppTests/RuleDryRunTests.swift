import Foundation
import MeerkatIPC
import MeerkatKit
import Testing

@testable import MeerkatApp

/// The editor's dry run apart from its view: which events a run asks for,
/// how meerkatd's answers and refusals come back, and what the rows say.
@MainActor
struct RuleDryRunTests {
    /// Records requests and answers from a queue.
    private final class Daemon: @unchecked Sendable {
        var requests: [DryRunRequest] = []
        var answer: Result<DryRunReport, any Error> = .success(DryRunReport(outcome: .ran))

        func send(_ request: DryRunRequest) throws -> DryRunReport {
            requests.append(request)
            return try answer.get()
        }
    }

    private func model(_ daemon: Daemon) -> RuleDryRunModel {
        RuleDryRunModel { [daemon] request in try daemon.send(request) }
    }

    private func envelope(_ kind: String = "power.source", time: Double = 1_000) -> EventEnvelope {
        EventEnvelope(
            kind: kind, sequence: 1, time: time, origin: .system, replayed: false, payload: .object(["a": .number(1)]))
    }

    private func received(_ id: Int) -> ReceivedEvent {
        ReceivedEvent(id: id, envelope: envelope(time: Double(id)), date: .now, summary: "")
    }

    // MARK: - Requests

    @Test func eachSourceAsksForItsEvents() async {
        let daemon = Daemon()
        let model = model(daemon)
        let held = [DryRunEvent(payload: .null)]
        model.source = .live
        model.sampleSeconds = 10
        await model.run(file: "a.ts", text: "text", rule: "warn", recorded: held)
        model.source = .recorded
        await model.run(file: "a.ts", text: "text", rule: nil, recorded: held)
        model.source = .example
        await model.run(file: "a.ts", text: "text", rule: nil, recorded: held)
        #expect(daemon.requests.map(\.events) == [.sampled(seconds: 10, maxEvents: 16), .given(held), .examples])
        #expect(daemon.requests[0].file == "a.ts")
        #expect(daemon.requests[0].text == "text")
        #expect(daemon.requests[0].rule == "warn")
    }

    /// The Explorer holds newest first, one kind; a run wants oldest first,
    /// and its rule's kind.
    @Test func recordedEventsAreTheRulesKindOldestFirst() {
        let events = (0..<100).reversed().map(received)
        let picked = RuleDryRunModel.recorded(events, of: "power.source", for: "power.source")
        #expect(picked.count == RuleDryRunModel.recordedLimit)
        #expect(picked.first?.time == 36)
        #expect(picked.last?.time == 99)
        #expect(picked.first?.origin == .system)
        #expect(RuleDryRunModel.recorded(events, of: "fs.change", for: "power.source").isEmpty)
        #expect(RuleDryRunModel.recorded(events, of: nil, for: nil).isEmpty)
        #expect(RuleDryRunModel.recorded(events, of: "fs.change", for: nil).count == RuleDryRunModel.recordedLimit)
    }

    // MARK: - Answers

    @Test func aReportIsKeptWithWhatRan() async {
        let daemon = Daemon()
        let report = DryRunReport(outcome: .rejected)
        daemon.answer = .success(report)
        let model = model(daemon)
        await model.run(file: "a.ts", text: "text", rule: nil, recorded: [])
        #expect(model.state == .finished(.init(file: "a.ts", text: "text", report: report)))
        #expect(!model.isRunning)
    }

    /// The running daemon may predate dry runs: that needs a restart, which
    /// a retry won't replace; a refusal is meerkatd's own words; anything
    /// else is about reaching it. The run that failed keeps its file.
    @Test(arguments: [
        (DaemonClient.ClientError.differentBuild("unknown case"), "differentBuild"),
        (.daemon("a dry run is already running"), "refused"),
        (.unreachable("no agent"), "unreachable"),
    ])
    func failuresAreClassifiedByWhoFailed(error: DaemonClient.ClientError, expected: String) async {
        let daemon = Daemon()
        daemon.answer = .failure(error)
        let model = model(daemon)
        await model.run(file: "a.ts", text: "", rule: nil, recorded: [])
        guard case .failed(let file, let fault) = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        #expect(file == "a.ts")
        let found =
            switch fault {
            case .differentBuild: "differentBuild"
            case .refused: "refused"
            case .unreachable: "unreachable"
            }
        #expect(found == expected)
    }

    /// Answers wait for the test, like a sample in progress.
    private final class Gate: @unchecked Sendable {
        private var continuations: [CheckedContinuation<DryRunReport, Never>] = []
        var waiting: Int { continuations.count }

        func wait() async -> DryRunReport {
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            for continuation in continuations { continuation.resume(returning: DryRunReport(outcome: .ran)) }
            continuations = []
        }
    }

    /// meerkatd answers at the end of a sample and can't be stopped, so
    /// while one runs another isn't sent, and only its own file's editor
    /// shows it or its answer, whatever the editor showed meanwhile.
    @Test func aRunIsAloneAndBelongsToItsFile() async throws {
        let gate = Gate()
        let model = RuleDryRunModel { [gate] _ in await gate.wait() }
        let run = Task { await model.run(file: "a.ts", text: "", rule: nil, recorded: []) }
        try await waitUntil { gate.waiting == 1 }
        #expect(model.isRunning)
        await model.run(file: "b.ts", text: "", rule: nil, recorded: [])
        #expect(gate.waiting == 1)
        #expect(model.state(for: "b.ts") == .idle)
        #expect(model.state(for: nil) == .idle)
        guard case .running = model.state(for: "a.ts") else {
            Issue.record("expected a.ts running, got \(model.state)")
            return
        }

        gate.open()
        await run.value
        #expect(model.state(for: "b.ts") == .idle)
        #expect(
            model.state(for: "a.ts") == .finished(.init(file: "a.ts", text: "", report: DryRunReport(outcome: .ran))))
    }

    // MARK: - Words

    @Test func progressCountsTheSampleThenTheRun() {
        let started = Date(timeIntervalSince1970: 0)
        let sampling = RuleDryRunModel.Running(file: "a.ts", started: started, sampleSeconds: 120)
        let now = Date(timeIntervalSince1970: 44)
        #expect(
            RuleDryRunModel.progress(of: sampling, kind: "power.source", at: now)
                == "Sampling power.source · 0:44 of 2:00")
        #expect(RuleDryRunModel.progress(of: sampling, kind: nil, at: now) == "Sampling events · 0:44 of 2:00")
        let after = Date(timeIntervalSince1970: 120)
        #expect(RuleDryRunModel.progress(of: sampling, kind: nil, at: after) == "Running the rule…")
        let given = RuleDryRunModel.Running(file: "a.ts", started: started, sampleSeconds: nil)
        #expect(RuleDryRunModel.progress(of: given, kind: nil, at: now) == "Running the rule…")
    }

    @Test func aReportSumsItsRows() {
        let effect = DryRunEffect(kind: "notify", request: .object([:]), outcome: .simulated(result: .null))
        let report = DryRunReport(
            outcome: .ran,
            runs: [
                DryRunInvocation(event: envelope(), result: .completed, effects: [effect, effect]),
                DryRunInvocation(event: envelope(), result: .skipped(reason: "match")),
                DryRunInvocation(event: envelope(), result: .failed(message: "boom")),
            ])
        #expect(report.summary == "3 events · 1 skipped · 1 failed · 2 effects")
        #expect(DryRunReport(outcome: .ran).summary == "0 events · 0 effects")
    }

    @Test func resultsNameTheirEnding() {
        #expect(DryRunInvocation.Result.completed.detail == nil)
        #expect(DryRunInvocation.Result.timedOut(seconds: 30).label == "Timed Out")
        #expect(DryRunInvocation.Result.timedOut(seconds: 30).detail?.contains("30 s") == true)
        #expect(DryRunInvocation.Result.interrupted(reason: "host stopped").isFailure)
        #expect(!DryRunInvocation.Result.skipped(reason: "match").isFailure)
    }

    /// A simulated effect's result is a placeholder, not something to show;
    /// a `state.get` read and a refusal are what the handler really got.
    @Test func effectsSayWhatTheHandlerGot() {
        let simulated = DryRunEffect(
            kind: "exec", request: .object(["path": .string("/bin/ls")]), outcome: .simulated(result: .string("")))
        #expect(simulated.outcomeLabel == "Simulated")
        #expect(simulated.outcomeDetail == nil)
        #expect(simulated.requestText == "path: /bin/ls")
        let read = DryRunEffect(kind: "state.get", request: .null, outcome: .read(result: .bool(true)))
        #expect(read.outcomeLabel == "Read")
        #expect(read.outcomeDetail == "true")
        let refused = DryRunEffect(kind: "notify", request: .null, outcome: .refused(message: "no grant"))
        #expect(refused.outcomeDetail == "no grant")
        let truncated = DryRunEffect(
            kind: "notify", request: .null, outcome: .simulated(result: .null), truncated: true)
        #expect(truncated.requestText.contains("not captured"))
    }
}
