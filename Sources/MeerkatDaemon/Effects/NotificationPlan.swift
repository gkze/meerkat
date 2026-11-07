import CryptoKit
import Foundation
import MeerkatKit

/// How a rule's `notify` becomes a notification-center request, and how a
/// response maps back to the rule that posted it.
///
/// Pure, so the identity and routing rules are testable without the
/// notification center. `UserNotifier` only applies plans.
struct NotificationPlan: Sendable, Equatable {
    /// Unique per (rule, id): posting it again replaces the notification.
    let identifier: String
    let threadIdentifier: String
    let category: NotificationCategory
    let title: String
    let subtitle: String?
    let body: String?
    let sound: Bool
    /// Strings only, so every value is a property-list value.
    let userInfo: [String: String]

    init(rule: RuleDefinition, spec: NotificationSpec, generatedID: @autoclosure () -> String = UUID().uuidString) {
        let id = spec.id ?? generatedID()
        identifier = Self.identifier(ruleId: rule.id, id: id)
        threadIdentifier = Self.identifier(ruleId: rule.id, id: spec.group ?? "")
        category = NotificationCategory(actions: spec.actions)
        title = spec.title
        subtitle = spec.subtitle
        body = spec.body
        sound = spec.sound
        var userInfo = [
            Key.file: rule.file, Key.rule: rule.name, Key.id: id, Key.actions: Self.encode(spec.actions),
        ]
        userInfo[Key.data] = spec.data?.canonicalString
        self.userInfo = userInfo
    }

    /// `<utf8 length of ruleId>:<ruleId><id>`. The length makes the split
    /// unambiguous: rule names and file names may contain any separator, so
    /// plain concatenation would let `x.ts#a` + `b|c` collide with
    /// `x.ts#a|b` + `c`, and one rule replace another's notification.
    static func identifier(ruleId: String, id: String) -> String {
        "\(ruleId.utf8.count):\(ruleId)\(id)"
    }

    /// The category a delivered notification was posted with, from its
    /// `userInfo`; nil for notifications this daemon did not post.
    static func category(userInfo: [String: String]) -> NotificationCategory? {
        guard let text = userInfo[Key.actions], let actions = decodeActions(text) else { return nil }
        return NotificationCategory(actions: actions)
    }

    /// What was done with a notification, as the event rules receive. Nil
    /// when the notification is not one of ours, or names an action it was
    /// never posted with.
    static func response(
        userInfo: [String: String], action: ResponseAction, text: String?
    ) -> NotificationResponsePayload? {
        guard let file = userInfo[Key.file], let rule = userInfo[Key.rule], let id = userInfo[Key.id],
            let actions = userInfo[Key.actions].flatMap(decodeActions)
        else { return nil }
        let data: JSONValue?
        if let encoded = userInfo[Key.data] {
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8)) else { return nil }
            data = decoded
        } else {
            data = nil
        }
        let name: String
        switch action {
        case .default: name = "default"
        case .dismiss: name = "dismiss"
        case .action(let actionID):
            guard actions.contains(where: { $0.id == actionID }) else { return nil }
            name = actionID
        }
        return NotificationResponsePayload(file: file, rule: rule, id: id, action: name, text: text, data: data)
    }

    enum ResponseAction: Equatable {
        case `default`
        case dismiss
        case action(String)
    }

    private enum Key {
        static let file = "meerkat.file"
        static let rule = "meerkat.rule"
        static let id = "meerkat.id"
        static let actions = "meerkat.actions"
        static let data = "meerkat.data"
    }

    private static func encode(_ actions: [NotificationAction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // Plain Codable values; encoding cannot fail.
        return String(decoding: (try? encoder.encode(actions)) ?? Data("[]".utf8), as: UTF8.self)
    }

    private static func decodeActions(_ text: String) -> [NotificationAction]? {
        try? JSONDecoder().decode([NotificationAction].self, from: Data(text.utf8))
    }
}

/// A set of actions, registered with the notification center under an id
/// derived from its content, so equal sets share one registration and a
/// restarted daemon derives the same id again.
struct NotificationCategory: Sendable, Hashable {
    let identifier: String
    let actions: [NotificationAction]

    init(actions: [NotificationAction]) {
        self.actions = actions
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(actions)) ?? Data()
        let digest = SHA256.hash(data: bytes).prefix(12).map { String(format: "%02x", $0) }.joined()
        identifier = "meerkat.\(digest)"
    }
}

/// The categories the daemon keeps registered. The notification center
/// replaces its whole set on every registration, so one owner keeps the
/// union of what live notifications need.
struct CategoryRegistry: Sendable {
    static let capacity = 64

    private(set) var categories: Set<NotificationCategory> = []
    /// Categories of posts that are being added: not delivered yet, so not
    /// visible to an eviction's delivered set, but needed.
    private var inFlight: [NotificationCategory: Int] = [:]

    enum Admission: Equatable {
        /// Already registered; nothing to change.
        case unchanged
        /// The set changed and must be registered again.
        case changed
        /// No room: evict unused categories, then try again.
        case full
    }

    /// Adds `category` and marks it in flight until `finish`, unless the
    /// registry is full.
    mutating func admit(_ category: NotificationCategory) -> Admission {
        let present = categories.contains(category)
        guard present || categories.count < Self.capacity else { return .full }
        inFlight[category, default: 0] += 1
        if present { return .unchanged }
        categories.insert(category)
        return .changed
    }

    /// Drops categories that no delivered notification (`used`, by
    /// identifier) and no post in flight needs.
    mutating func evict(keeping used: Set<String>) {
        categories = categories.filter { used.contains($0.identifier) || inFlight[$0] != nil }
    }

    mutating func finish(_ category: NotificationCategory) {
        guard let count = inFlight[category] else { return }
        inFlight[category] = count > 1 ? count - 1 : nil
    }

    /// Adds categories rebuilt from delivered notifications at startup.
    mutating func restore(_ restored: some Sequence<NotificationCategory>) {
        for category in restored where categories.count < Self.capacity { categories.insert(category) }
    }
}
