import Foundation
import MeerkatKit
import UserNotifications

/// Posts through `UNUserNotificationCenter`, attributed to Meerkat.app, and
/// owns the categories registered for rules' actions.
///
/// The center requires a bundle identity; a daemon run outside the bundle
/// (SwiftPM builds, tests) reports that instead of crashing in the framework.
///
/// An actor because registering categories replaces the center's whole set:
/// every registration goes through this one owner, so two rules posting
/// different actions at once cannot drop each other's.
actor UserNotifier: Notifier {
    private var registry = CategoryRegistry()
    private var restored = false

    func post(_ plan: NotificationPlan) async throws {
        let center = try Self.center()
        try await authorize(center)
        await restoreIfNeeded(center)
        let category = plan.category
        var admission = registry.admit(category)
        if admission == .full {
            registry.evict(keeping: await deliveredCategoryIdentifiers(center))
            admission = registry.admit(category)
        }
        switch admission {
        case .full:
            throw EffectError.failed(
                "too many distinct notification action sets in use (\(CategoryRegistry.capacity)); withdraw some")
        case .changed:
            center.setNotificationCategories(Set(registry.categories.map(Self.category)))
        case .unchanged:
            break
        }
        defer { registry.finish(category) }

        let content = UNMutableNotificationContent()
        content.title = plan.title
        if let subtitle = plan.subtitle { content.subtitle = subtitle }
        if let body = plan.body { content.body = body }
        if plan.sound { content.sound = .default }
        content.threadIdentifier = plan.threadIdentifier
        content.categoryIdentifier = category.identifier
        content.userInfo = plan.userInfo
        try await center.add(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil))
    }

    func withdraw(identifier: String) async throws {
        let center = try Self.center()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private static func center() throws -> UNUserNotificationCenter {
        guard Bundle.main.bundleIdentifier != nil else {
            throw EffectError.failed("notifications are available when meerkatd runs from Meerkat.app")
        }
        return UNUserNotificationCenter.current()
    }

    private func authorize(_ center: UNUserNotificationCenter) async throws {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                throw EffectError.failed("notifications were not allowed for Meerkat")
            }
        case .denied:
            throw EffectError.failed("notifications are turned off for Meerkat in System Settings > Notifications")
        default:
            break
        }
    }

    /// A restarted daemon starts with an empty registry; its first
    /// registration would drop the categories of notifications still on
    /// screen and remove their buttons. Each carries its actions, so the set
    /// is rebuilt from them first.
    private func restoreIfNeeded(_ center: UNUserNotificationCenter) async {
        guard !restored else { return }
        restored = true
        let delivered = await center.deliveredNotifications()
        registry.restore(delivered.compactMap { NotificationPlan.category(userInfo: Self.strings($0)) })
    }

    private func deliveredCategoryIdentifiers(_ center: UNUserNotificationCenter) async -> Set<String> {
        Set(await center.deliveredNotifications().map(\.request.content.categoryIdentifier))
    }

    private static func category(_ category: NotificationCategory) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: category.identifier,
            actions: category.actions.map { action in
                let options: UNNotificationActionOptions = action.destructive ? [.destructive] : []
                guard let input = action.input else {
                    return UNNotificationAction(identifier: action.id, title: action.title, options: options)
                }
                return UNTextInputNotificationAction(
                    identifier: action.id, title: action.title, options: options, textInputButtonTitle: "Send",
                    textInputPlaceholder: input.placeholder ?? "")
            },
            intentIdentifiers: [],
            // Without it, closing a notification reports nothing.
            options: [.customDismissAction])
    }

    /// The string entries of a delivered notification's `userInfo`; ours
    /// holds nothing else.
    fileprivate static func strings(_ notification: UNNotification) -> [String: String] {
        var strings: [String: String] = [:]
        for (key, value) in notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { strings[key] = value }
        }
        return strings
    }
}

/// Receives what people do with rules' notifications and hands each
/// response, decoded once here, to `deliver`.
///
/// Installed at daemon start: the center delivers responses to the delegate
/// present when it reports them, and a response to a notification posted
/// before a restart still routes, because everything it needs is in the
/// notification's `userInfo`.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let deliver: @Sendable (NotificationResponsePayload) -> Void
    private let dropped: @Sendable (String) -> Void

    init(
        deliver: @escaping @Sendable (NotificationResponsePayload) -> Void,
        dropped: @escaping @Sendable (String) -> Void
    ) {
        self.deliver = deliver
        self.dropped = dropped
    }

    /// Becomes the center's delegate when meerkatd runs from the bundle.
    func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action: NotificationPlan.ResponseAction
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = .default
        case UNNotificationDismissActionIdentifier: action = .dismiss
        case let identifier: action = .action(identifier)
        }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let request = response.notification.request
        guard
            let payload = NotificationPlan.response(
                userInfo: UserNotifier.strings(response.notification), action: action, text: text)
        else {
            dropped("response \(response.actionIdentifier) to \(request.identifier) is not for a rule notification")
            return
        }
        deliver(payload)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
