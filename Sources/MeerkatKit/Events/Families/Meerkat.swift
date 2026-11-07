import Foundation
import Synchronization

// Events about the daemon itself.

// MARK: - Rule ids

/// A rule's id: its entry file, `#`, its name (`heavy-writers.ts#throttle`);
/// a whole file that failed is named by the file alone. Neither part holds a
/// `#`, so the id splits back into the two one way: the rules compiler loads
/// no entry file whose name holds one (`refusal(file:)`), and a rule whose
/// name does fails to load (`refusal(name:)`), in the daemon and unrouted in
/// the runtime (host.rs, `rule_id`).
public enum RuleID {
    public static func make(file: String, name: String) -> String { "\(file)#\(name)" }

    /// The entry file `id` names.
    public static func file(of id: String) -> String { String(id.prefix { $0 != "#" }) }

    /// Why `file`, an entry file's name, cannot be one; nil when it can.
    public static func refusal(file: String) -> String? {
        guard file.contains("#") else { return nil }
        return "\(file) is not loaded: a rule file's name must not contain #, which ends it in a rule's id"
    }

    /// Why `name` cannot be a rule's name; nil when it can.
    public static func refusal(name: String) -> String? {
        name.contains("#") ? "\"name\" must not contain #" : nil
    }
}

// MARK: - meerkat.rule

public struct RuleStatusPayload: RuleViewedPayload, Equatable {
    public enum State: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        /// Type-checked, evaluated and subscribed.
        case loaded
        /// Did not load: a type error, an exception while evaluating, or an
        /// invalid definition. `reason` says which.
        case failed
        /// Turned off by its circuit breaker or by `meerkat rules disable`.
        case disabled
        /// Its file was removed or no longer defines it.
        case unloaded
    }

    /// `<file>#<name>` (`RuleID`), or the file alone when the whole file
    /// failed.
    public let ruleId: String
    /// The entry file `ruleId` names, as the engine knows it rather than
    /// parsed back from the id: a file refused for a `#` in its name fails
    /// under that name.
    public let file: String
    public let state: State
    public let reason: String?

    public init(ruleId: String, file: String, state: State, reason: String? = nil) {
        self.ruleId = ruleId
        self.file = file
        self.state = state
        self.reason = reason
    }

    /// A rule sees only its own file's: another file's reasons hold its
    /// code's errors and the paths and grants it was refused.
    public func viewed(by view: RuleView) -> Self? { file == view.file ? self : nil }

    public static var schema: TypeSchema {
        .named(
            "RuleStatus",
            ObjectSchema([
                .field("ruleId", String.self, doc: "`<file>#<name>`, or the file alone when the whole file failed."),
                .field("file", String.self, doc: "The entry file. A rule receives only its own file's."),
                .field("state", State.self),
                .optional("reason", String.self),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(ruleId: "heavy-writers.ts#throttle", file: "heavy-writers.ts", state: .loaded),
            Self(
                ruleId: "heavy-writers.ts#throttle", file: "heavy-writers.ts", state: .disabled,
                reason: "5 failures within 60 s"),
        ]
    }
}

public enum MeerkatRuleEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "meerkat.rule",
        "A rule loaded, failed to load, was disabled or was unloaded. A rule receives only its own file's.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "the rule engine"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<RuleStatusPayload>
    ) throws -> any EventSource {
        // `origin: meerkat` marks events caused by rule effects, which rules
        // skip by default to break feedback loops. A rule's status is not an
        // effect, and rules subscribe to it on purpose.
        internalEventSource(environment, emit: emit) { event in
            guard case .rule(let status) = event else { return nil }
            return status
        }
    }
}

// MARK: - meerkat.dropped

public struct DroppedEventsPayload: RuleViewedPayload, Equatable {
    public let kind: String
    public let parameters: JSONValue
    /// The entry file of the rules whose subscription fell behind; nil for
    /// the daemon's clients (the app, the CLI, MCP) and the daemon itself.
    public let file: String?
    /// Events dropped since the previous report for this source and file.
    public let dropped: Double

    /// A rule sees only its own file's subscriptions: another file's
    /// parameters are its paths, predicates and names.
    public func viewed(by view: RuleView) -> Self? { file == view.file ? self : nil }

    public static var schema: TypeSchema {
        .named(
            "DroppedEvents",
            ObjectSchema([
                .field("kind", String.self, doc: "The event kind whose subscribers fell behind."),
                .field("parameters", JSONValue.self),
                .optional(
                    "file", String.self,
                    doc:
                        "Entry file of the rules whose subscription fell behind; absent for the daemon itself and its clients (the app, the CLI, MCP). A rule receives only its own file's reports."
                ),
                .field(
                    "dropped", Double.self, doc: "Events dropped since the previous report for this source and file."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                kind: "fs.change", parameters: .object(["paths": .array([.string("/tmp")])]), file: "downloads.ts",
                dropped: 120),
            Self(kind: "cpu.sample", parameters: .object(["interval": .number(1)]), file: nil, dropped: 3),
        ]
    }
}

public enum MeerkatDroppedEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "meerkat.dropped",
        "A subscriber fell behind and the hub dropped its oldest buffered events, reported per source and per rule file. Checked every 5 seconds. A rule receives only reports about its own file's subscriptions.",
        mechanism: .derived, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "the event hub"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<DroppedEventsPayload>
    ) throws -> any EventSource {
        let reported = Mutex<[EventHub.DropCount.Key: UInt64]>([:])
        return PollingSource(label: "meerkat-dropped", interval: 5, fireImmediately: false) {
            guard let hub = environment.attachedHub else { return }
            let counts = (hub.takeRetiredDropCounts() + hub.dropCounts()).filter { $0.kind != descriptor.name }
            let reports = reported.withLock { reported -> [DroppedEventsPayload] in
                var reports: [DroppedEventsPayload] = []
                var current: [EventHub.DropCount.Key: UInt64] = [:]
                for count in counts {
                    // Per instance: a source recreated under the same key
                    // starts counting from zero again.
                    current[count.key] = count.dropped
                    let previous = reported[count.key] ?? 0
                    if count.dropped > previous {
                        let file: String? =
                            switch count.key.subscriber {
                            case .rule(let file): file
                            case .external: nil
                            }
                        reports.append(
                            DroppedEventsPayload(
                                kind: count.kind, parameters: count.parameters, file: file,
                                dropped: Double(count.dropped - previous)))
                    }
                }
                reported = current
                return reports
            }
            for report in reports { emit(report) }
        }
    }
}

// MARK: - meerkat.notification

/// What someone did with a notification a rule posted.
public struct NotificationResponsePayload: RuleViewedPayload, Equatable {
    /// The entry file of the rule that posted it; the event reaches only
    /// rules in this file.
    public let file: String
    /// The posting rule's name, without the file.
    public let rule: String
    /// The id the rule gave the notification, or the generated one.
    public let id: String
    /// `default` for a click on the notification itself, `dismiss` for
    /// closing it, otherwise the id of the clicked action.
    public let action: String
    /// What was typed into a reply action.
    public let text: String?
    /// The `data` the rule posted with the notification.
    public let data: JSONValue?

    public init(file: String, rule: String, id: String, action: String, text: String? = nil, data: JSONValue? = nil) {
        self.file = file
        self.rule = rule
        self.id = id
        self.action = action
        self.text = text
        self.data = data
    }

    public func viewed(by view: RuleView) -> Self? { file == view.file ? self : nil }

    public static var schema: TypeSchema {
        .named(
            "NotificationResponse",
            ObjectSchema([
                .field("file", String.self, doc: "Entry file of the rule that posted the notification."),
                .field("rule", String.self, doc: "Name of the rule that posted it."),
                .field("id", String.self, doc: "The notification's id: the one the rule gave, or a generated one."),
                .field(
                    "action", String.self,
                    doc:
                        "\"default\" for a click on the notification, \"dismiss\" for closing it, otherwise the clicked action's id."
                ),
                .optional("text", String.self, doc: "What was typed into a reply action."),
                .optional("data", JSONValue.self, doc: "The data the rule posted with the notification."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                file: "heavy-writers.ts", rule: "throttle", id: "Xcode", action: "undo",
                data: .object(["pid": .number(812), "startedAt": .number(1_761_550_000_000)])),
            Self(file: "low-battery.ts", rule: "warn", id: "low-battery", action: "dismiss"),
            Self(file: "notes.ts", rule: "ask", id: "why", action: "reply", text: "compiling"),
        ]
    }
}

public enum MeerkatNotificationEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "meerkat.notification",
        "Someone clicked, dismissed or replied to a notification a rule posted. Delivered only to rules in the file whose rule posted it.",
        mechanism: .push, semantics: .occurrence, loss: .none,
        observation: .open,
        source: "UNUserNotificationCenter responses"
    )

    public static let audience = EventAudience.rules

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<NotificationResponsePayload>
    ) throws -> any EventSource {
        // A person's click, not an effect: not `origin: meerkat`.
        internalEventSource(environment, emit: emit) { event in
            guard case .notification(let response) = event else { return nil }
            return response
        }
    }
}

/// Emits what `select` finds in the daemon's internal events.
private func internalEventSource<Payload: EventPayload>(
    _ environment: SourceEnvironment, emit: Emitter<Payload>,
    select: @escaping @Sendable (InternalEvent) -> Payload?
) -> any EventSource {
    let token = Mutex<UInt64?>(nil)
    return ClosureSource(
        start: {
            let id = environment.internalEvents.add { event in
                if let payload = select(event) { emit(payload) }
            }
            token.withLock { $0 = id }
        },
        stop: {
            if let id = token.withLock({ $0 }) { environment.internalEvents.remove(id) }
        })
}
