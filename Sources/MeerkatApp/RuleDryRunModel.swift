import Foundation
import MeerkatIPC
import MeerkatKit
import Observation

/// The rule editor's dry run ("Try It"): the unsaved text run on events by
/// meerkatd, with every effect captured instead of performed
/// (docs/design/rule-editor.md, "Dry run").
///
/// meerkatd answers once, when the run ends, and can't be told to stop, so a
/// run isn't cancelled, and the daemon refuses another until the first is
/// done. A run and its answer belong to one file (`state(for:)`): another
/// file's editor shows neither.
@MainActor
@Observable
final class RuleDryRunModel {
    enum Source: String, CaseIterable, Identifiable {
        case live = "Live"
        case recorded = "Recorded"
        case example = "Example"

        var id: Self { self }
    }

    enum Failure: Equatable {
        /// The running meerkatd is a different build, so it doesn't know
        /// the request.
        case differentBuild
        /// meerkatd's own answer, such as a run already in progress.
        case refused(String)
        case unreachable(String)

        init(_ error: any Error) {
            switch error as? DaemonClient.ClientError {
            case .differentBuild?: self = .differentBuild
            case .daemon(let message)?: self = .refused(message)
            default: self = .unreachable("\(error)")
            }
        }

        var title: String {
            switch self {
            case .differentBuild: "meerkatd is a different build"
            case .refused: "meerkatd refused the dry run"
            case .unreachable: "Couldn't reach meerkatd"
            }
        }

        var detail: String {
            switch self {
            case .differentBuild:
                "The running meerkatd is a different build from this app. Restart it from this build with "
                    + "`meerkat agent restart`, then run again."
            case .refused(let message), .unreachable(let message): message
            }
        }
    }

    /// A run under way. `sampleSeconds` is set while meerkatd collects live
    /// events; the handlers run after that.
    struct Running: Equatable {
        let file: String
        let started: Date
        let sampleSeconds: Double?
    }

    /// A report, with what it ran.
    struct Finished: Equatable {
        let file: String
        let text: String
        let report: DryRunReport
    }

    enum State: Equatable {
        case idle
        case running(Running)
        case finished(Finished)
        case failed(file: String, Failure)

        /// The file the run was for.
        var file: String? {
            switch self {
            case .idle: nil
            case .running(let running): running.file
            case .finished(let finished): finished.file
            case .failed(let file, _): file
            }
        }
    }

    static let sampleChoices: [Double] = [10, 30, 120]
    /// A sample stops at this many events, whatever its length. meerkatd's
    /// limit for a run is `recordedLimit`.
    static let sampleEvents = 16
    static let recordedLimit = 64

    var source = Source.live
    var sampleSeconds = 30.0
    /// The rule chosen in a file with several.
    var rule: String?
    private(set) var state = State.idle

    private let send: @Sendable (DryRunRequest) async throws -> DryRunReport

    init(send: @escaping @Sendable (DryRunRequest) async throws -> DryRunReport) {
        self.send = send
    }

    convenience init(client: any DaemonConnection) {
        self.init { try await client.dryRun($0) }
    }

    /// Whether a run is under way, for any file: meerkatd runs one at a
    /// time.
    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    /// The run as `file`'s editor shows it: idle unless it was for `file`.
    func state(for file: String?) -> State {
        state.file == file ? state : .idle
    }

    /// Runs `text` on the chosen source's events; `recorded` are the events
    /// of `Source.recorded`. One run at a time.
    func run(file: String, text: String, rule: String?, recorded: [DryRunEvent]) async {
        guard !isRunning else { return }
        let events: DryRunRequest.Events
        switch source {
        case .live: events = .sampled(seconds: sampleSeconds, maxEvents: Self.sampleEvents)
        case .recorded: events = .given(recorded)
        case .example: events = .examples
        }
        state = .running(
            Running(file: file, started: .now, sampleSeconds: source == .live ? sampleSeconds : nil))
        do {
            let report = try await send(DryRunRequest(file: file, text: text, rule: rule, events: events))
            state = .finished(Finished(file: file, text: text, report: report))
        } catch {
            state = .failed(file: file, Failure(error))
        }
    }

    /// The events kept by the Event Explorer that `kind`'s rule can run on,
    /// oldest first, the newest `recordedLimit` of them. With no `kind`
    /// known (a new file), meerkatd checks them against the rule's kind.
    static func recorded(_ events: [ReceivedEvent], of held: String?, for kind: String?) -> [DryRunEvent] {
        guard held != nil, kind == nil || kind == held else { return [] }
        return events.prefix(recordedLimit).reversed().map {
            DryRunEvent(payload: $0.envelope.payload, time: $0.envelope.time, origin: $0.envelope.origin)
        }
    }

    /// What a run is doing at `now`.
    static func progress(of run: Running, kind: String?, at now: Date) -> String {
        guard let seconds = run.sampleSeconds, now.timeIntervalSince(run.started) < seconds else {
            return "Running the rule…"
        }
        let elapsed = Self.minutes(now.timeIntervalSince(run.started))
        return "Sampling \(kind ?? "events") · \(elapsed) of \(Self.minutes(seconds))"
    }

    private static func minutes(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

extension DryRunReport {
    /// One line for the inspector's footer.
    var summary: String {
        let skipped = runs.count { $0.result.isSkipped }
        let failed = runs.count { $0.result.isFailure }
        let effects = runs.reduce(0) { $0 + $1.effects.count }
        var parts = [runs.count == 1 ? "1 event" : "\(runs.count) events"]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        parts.append(effects == 1 ? "1 effect" : "\(effects) effects")
        return parts.joined(separator: " · ")
    }
}

extension DryRunInvocation.Result {
    var label: String {
        switch self {
        case .completed: "Ran"
        case .failed: "Failed"
        case .timedOut: "Timed Out"
        case .interrupted: "Stopped"
        case .skipped: "Skipped"
        }
    }

    var isSkipped: Bool {
        if case .skipped = self { true } else { false }
    }

    var isFailure: Bool {
        switch self {
        case .completed, .skipped: false
        case .failed, .timedOut, .interrupted: true
        }
    }

    /// Why it ended as it did, unless it simply finished.
    var detail: String? {
        switch self {
        case .completed: nil
        case .failed(let message): message
        case .timedOut(let seconds): "The handler ran past its \(JSONValue.format(seconds)) s limit."
        case .interrupted(let reason), .skipped(let reason): reason
        }
    }
}

extension DryRunEffect {
    var requestText: String { truncated ? "Request not captured: the run reached its limit." : request.summary }

    var outcomeLabel: String {
        switch outcome {
        case .simulated: "Simulated"
        case .read: "Read"
        case .refused: "Refused"
        }
    }

    /// What the handler got, when it's more than a placeholder.
    var outcomeDetail: String? {
        switch outcome {
        case .simulated: nil
        case .read(let result): result.compactText
        case .refused(let message): message
        }
    }
}
