import Foundation
import MeerkatKit

/// A dry run (docs/design/rule-editor.md, "Dry run"): compile a rule file's
/// unsaved text and run one of its rules on events, with every effect
/// captured instead of performed.
public struct DryRunRequest: Codable, Sendable, Equatable {
    /// The file's name in the rules directory, `low-battery.ts`. It need not
    /// exist yet. The rest of the directory compiles with it, as it is on disk.
    public var file: String
    /// The file's unsaved text.
    public var text: String
    /// The rule's `name`. Nil runs the file's only rule; a file with several
    /// answers `DryRunReport.Outcome.chooseRule`.
    public var rule: String?
    public var events: Events

    public enum Events: Codable, Sendable, Equatable {
        /// Events the caller already has, in order: from the Event Explorer,
        /// a file, or typed in. The first is the rule's event kind's payload.
        case given([DryRunEvent])
        /// The event kind's documented example payloads.
        case examples
        /// Whatever arrives from the rule's source, with the rule's
        /// parameters, for up to `seconds` or `maxEvents`. A `state` kind's
        /// current value comes first.
        case sampled(seconds: Double, maxEvents: Int)
    }

    public init(file: String, text: String, rule: String? = nil, events: Events) {
        self.file = file
        self.text = text
        self.rule = rule
        self.events = events
    }
}

/// One event to run, of the rule's own kind.
public struct DryRunEvent: Codable, Sendable, Equatable {
    public var payload: JSONValue
    /// Unix epoch milliseconds; nil is now.
    public var time: Double?
    /// Nil is `system`. `meerkat` events skip a rule without `includeOwn`.
    public var origin: EventOrigin?

    public init(payload: JSONValue, time: Double? = nil, origin: EventOrigin? = nil) {
        self.payload = payload
        self.time = time
        self.origin = origin
    }
}

public struct DryRunReport: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The rule ran on `runs`, which is empty when a sample saw nothing.
        case ran
        /// The file does not compile or load: see `diagnostics`.
        case rejected
        /// The request named no rule and the file has several, or named one
        /// it doesn't have: see `rules`.
        case chooseRule
    }

    public var outcome: Outcome
    /// Compile and load diagnostics of the whole compile. Those of other
    /// files are listed too: an import of a file with errors fails the load.
    public var diagnostics: [RuleDiagnostic]
    /// The names of the file's rules, in definition order.
    public var rules: [String]
    /// The id of the rule that ran, `file.ts#name`.
    public var rule: String?
    /// The event kind it listens to.
    public var event: String?
    /// What the file logged outside any invocation: its top-level code, and
    /// its timers between invocations.
    public var fileLogs: [DryRunLog]
    public var runs: [DryRunInvocation]
    /// The run's time budget ended before every event ran.
    public var outOfTime: Bool
    public var compileMilliseconds: Double
    public var loadMilliseconds: Double

    public init(
        outcome: Outcome, diagnostics: [RuleDiagnostic] = [], rules: [String] = [], rule: String? = nil,
        event: String? = nil, fileLogs: [DryRunLog] = [], runs: [DryRunInvocation] = [], outOfTime: Bool = false,
        compileMilliseconds: Double = 0, loadMilliseconds: Double = 0
    ) {
        self.outcome = outcome
        self.diagnostics = diagnostics
        self.rules = rules
        self.rule = rule
        self.event = event
        self.fileLogs = fileLogs
        self.runs = runs
        self.outOfTime = outOfTime
        self.compileMilliseconds = compileMilliseconds
        self.loadMilliseconds = loadMilliseconds
    }
}

/// One event's way through the rule.
public struct DryRunInvocation: Codable, Sendable, Equatable {
    public enum Result: Codable, Sendable, Equatable {
        /// The handler finished.
        case completed
        /// The handler threw, or rejected.
        case failed(message: String)
        case timedOut(seconds: Double)
        /// The dry run's host stopped: another event's handler held the
        /// JavaScript thread, or the runtime failed.
        case interrupted(reason: String)
        /// The rule's origin filter or `match` skipped the event; the handler
        /// did not run. Rate limits and debounce are not applied.
        case skipped(reason: String)
    }

    public var event: EventEnvelope
    public var result: Result
    /// In the order the handler asked for them.
    public var effects: [DryRunEffect]
    public var logs: [DryRunLog]
    /// The handler's wall time; 0 when skipped.
    public var milliseconds: Double

    public init(
        event: EventEnvelope, result: Result, effects: [DryRunEffect] = [], logs: [DryRunLog] = [],
        milliseconds: Double = 0
    ) {
        self.event = event
        self.result = result
        self.effects = effects
        self.logs = logs
        self.milliseconds = milliseconds
    }
}

/// An effect the handler asked for. None of them happened.
public struct DryRunEffect: Codable, Sendable, Equatable {
    public enum Outcome: Codable, Sendable, Equatable {
        /// Would have been performed; the handler received `result`, a
        /// placeholder of the effect's result type, or a simulated state
        /// write's outcome.
        case simulated(result: JSONValue)
        /// `state.get`: read from the rule's stored state, with this run's
        /// simulated writes on top. The one thing a dry run reads.
        case read(result: JSONValue)
        /// The request is invalid or its grant or permission is missing. The
        /// handler received this error, as it would have.
        case refused(message: String)
    }

    /// `notify`, `state.set`, `exec`.
    public var kind: String
    /// The request's fields without `kind`; null when `truncated`.
    public var request: JSONValue
    public var outcome: Outcome
    /// The run captured its limit of data, so `request` was left out.
    public var truncated: Bool

    public init(kind: String, request: JSONValue, outcome: Outcome, truncated: Bool = false) {
        self.kind = kind
        self.request = request
        self.outcome = outcome
        self.truncated = truncated
    }
}

public struct DryRunLog: Codable, Sendable, Equatable {
    public var level: LogLevel
    public var message: String

    public init(level: LogLevel, message: String) {
        self.level = level
        self.message = message
    }
}
