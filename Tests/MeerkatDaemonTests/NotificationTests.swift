import Foundation
import MeerkatIPC
import MeerkatRuntimeBindings
import MeerkatStore
import Synchronization
import Testing
import notify

@testable import MeerkatDaemon
@testable import MeerkatKit

/// `notify`'s pure parts: what a rule may ask for, how a request becomes a
/// notification, and how a response finds its way back.
struct NotificationSpecTests {
    private func spec(_ fields: [String: JSONValue]) throws -> NotificationSpec {
        let request = try EffectRequest(.object(fields.merging(["kind": "notify"]) { a, _ in a }))
        guard case .notify(let spec) = request.action else {
            throw EffectError.invalid("not a notify request")
        }
        return spec
    }

    @Test func titleOnlyStillDecodes() throws {
        let decoded = try spec(["title": "Battery low", "body": "12 %"])
        #expect(decoded == NotificationSpec(title: "Battery low", body: "12 %"))
    }

    @Test func fullRequestDecodes() throws {
        let decoded = try spec([
            "title": "t", "id": "low", "group": "power", "sound": true,
            "actions": [
                ["id": "undo", "title": "Undo", "destructive": true],
                ["id": "reply", "title": "Reply", "input": ["placeholder": "Why?"]],
            ],
            "data": ["pid": 4],
        ])
        #expect(decoded.id == "low")
        #expect(decoded.group == "power")
        #expect(decoded.sound)
        #expect(
            decoded.actions == [
                NotificationAction(id: "undo", title: "Undo", destructive: true),
                NotificationAction(id: "reply", title: "Reply", input: .init(placeholder: "Why?")),
            ])
        #expect(decoded.data == ["pid": 4])
    }

    @Test(
        arguments: [
            ["title": ""],
            ["title": "t", "id": ""],
            ["title": "t", "actions": [["id": "default", "title": "x"]]],
            ["title": "t", "actions": [["id": "dismiss", "title": "x"]]],
            ["title": "t", "actions": [["id": "a", "title": "x"], ["id": "a", "title": "y"]]],
            ["title": "t", "actions": .array((1...5).map { ["id": .string("a\($0)"), "title": "x"] })],
            ["title": "t", "actions": ["undo"]],
            ["title": "t", "data": .string(String(repeating: "x", count: 4096))],
        ] as [[String: JSONValue]])
    func invalidRequestsAreRefused(_ fields: [String: JSONValue]) {
        #expect(throws: EffectError.self) { try spec(fields) }
    }

    /// Display text is bounded in bytes, four for each character it was once
    /// counted in, so a title that fit in any script still fits.
    @Test func displayTextFitsItsCharactersInAnyScript() throws {
        let title = String(repeating: "😀", count: 256)
        let action = String(repeating: "😀", count: 64)
        let decoded = try spec(["title": .string(title), "actions": [["id": "a", "title": .string(action)]]])
        #expect(decoded.title == title && decoded.actions.first?.title == action)
        #expect(throws: EffectError.self) { try spec(["title": .string(title + "x")]) }
    }

    /// Null data carries nothing back, so it is left out as absent data is.
    @Test func nullDataIsLeftOut() throws {
        #expect(try spec(["title": "t", "data": .null]).data == nil)
    }

    @Test func withdrawDecodes() throws {
        #expect(try EffectRequest(["kind": "notify.withdraw", "id": "low"]).action == .withdrawNotification(id: "low"))
        #expect(throws: EffectError.self) { try EffectRequest(["kind": "notify.withdraw", "id": ""]) }
    }
}

struct NotificationPlanTests {
    /// A rule named `name` in `file`, as the engine hands one to the plan.
    private func rule(_ file: String, _ name: String) throws -> RuleDefinition {
        try RuleDefinition(file: file, raw: ["name": .string(name), "on": "memory.pressure"], catalog: .standard)
    }

    /// Rule names and files may contain any separator; the identifier must
    /// still be distinct for every (rule, id) pair, or one rule could replace
    /// or withdraw another's notification.
    @Test func identifiersDoNotCollideAcrossRules() throws {
        let pairs = [("x.ts#a", "b|c"), ("x.ts#a|b", "c"), ("x.ts#ab", "c"), ("x.ts#a", "bc"), ("1:x.ts#a", "")]
        let identifiers = pairs.map { NotificationPlan.identifier(ruleId: $0.0, id: $0.1) }
        #expect(Set(identifiers).count == pairs.count)
    }

    @Test func withdrawAddressesWhatPostCreated() throws {
        let plan = NotificationPlan(rule: try rule("a.ts", "r"), spec: NotificationSpec(title: "t", id: "low"))
        #expect(plan.identifier == NotificationPlan.identifier(ruleId: "a.ts#r", id: "low"))
    }

    @Test func notificationsAreGroupedByRule() throws {
        let plain = NotificationPlan(rule: try rule("a.ts", "r"), spec: NotificationSpec(title: "t"))
        let grouped = NotificationPlan(rule: try rule("a.ts", "r"), spec: NotificationSpec(title: "t", group: "g"))
        let other = NotificationPlan(rule: try rule("a.ts", "s"), spec: NotificationSpec(title: "t"))
        #expect(plain.threadIdentifier != grouped.threadIdentifier)
        #expect(plain.threadIdentifier != other.threadIdentifier)
    }

    @Test func responseCarriesRuleIdentityAndData() throws {
        let undo = NotificationAction(id: "undo", title: "Undo")
        let plan = NotificationPlan(
            rule: try rule("heavy-writers.ts", "throttle"),
            spec: NotificationSpec(title: "t", id: "812", actions: [undo], data: ["pid": 812, "note": .null]))
        let clicked = NotificationPlan.response(userInfo: plan.userInfo, action: .action("undo"), text: nil)
        #expect(
            clicked
                == NotificationResponsePayload(
                    file: "heavy-writers.ts", rule: "throttle", id: "812", action: "undo",
                    data: ["pid": 812, "note": .null]))
        #expect(NotificationPlan.response(userInfo: plan.userInfo, action: .default, text: nil)?.action == "default")
        #expect(NotificationPlan.response(userInfo: plan.userInfo, action: .dismiss, text: nil)?.action == "dismiss")
    }

    @Test func generatedIDsComeBackInResponses() throws {
        let plan = NotificationPlan(rule: try rule("a.ts", "r"), spec: NotificationSpec(title: "t"), generatedID: "G")
        #expect(NotificationPlan.response(userInfo: plan.userInfo, action: .default, text: nil)?.id == "G")
    }

    @Test func repliesCarryTheirText() throws {
        let reply = NotificationAction(id: "reply", title: "Reply", input: .init(placeholder: nil))
        let plan = NotificationPlan(rule: try rule("a.ts", "r"), spec: NotificationSpec(title: "t", actions: [reply]))
        #expect(
            NotificationPlan.response(userInfo: plan.userInfo, action: .action("reply"), text: "hi")?.text == "hi")
    }

    @Test func foreignOrMalformedResponsesAreDropped() throws {
        let plan = NotificationPlan(rule: try rule("a.ts", "r"), spec: NotificationSpec(title: "t"))
        // An action the notification was never posted with.
        #expect(NotificationPlan.response(userInfo: plan.userInfo, action: .action("kill"), text: nil) == nil)
        // A notification some other code posted.
        #expect(NotificationPlan.response(userInfo: ["n": "A1"], action: .default, text: nil) == nil)
        var corrupt = plan.userInfo
        corrupt["meerkat.data"] = "{"
        #expect(NotificationPlan.response(userInfo: corrupt, action: .default, text: nil) == nil)
    }

    @Test func categoriesAreDerivedFromContent() throws {
        let actions = [NotificationAction(id: "undo", title: "Undo")]
        let plan = NotificationPlan(rule: try rule("a.ts", "r"), spec: NotificationSpec(title: "t", actions: actions))
        #expect(plan.category == NotificationCategory(actions: actions))
        #expect(plan.category != NotificationCategory(actions: []))
        // A restarted daemon rebuilds the same category from a delivered
        // notification.
        #expect(NotificationPlan.category(userInfo: plan.userInfo) == plan.category)
    }
}

struct CategoryRegistryTests {
    private func category(_ n: Int) -> NotificationCategory {
        NotificationCategory(actions: [NotificationAction(id: "a\(n)", title: "x")])
    }

    @Test func admittingTheSameCategoryTwiceChangesNothing() {
        var registry = CategoryRegistry()
        #expect(registry.admit(category(1)) == .changed)
        #expect(registry.admit(category(1)) == .unchanged)
        #expect(registry.categories.count == 1)
    }

    @Test func aFullRegistryEvictsOnlyUnusedCategories() {
        var registry = CategoryRegistry()
        for n in 0..<CategoryRegistry.capacity {
            _ = registry.admit(category(n))
            registry.finish(category(n))
        }
        #expect(registry.admit(category(999)) == .full)
        registry.evict(keeping: [category(0).identifier])
        #expect(registry.categories == [category(0)])
        #expect(registry.admit(category(999)) == .changed)
    }

    @Test func postsInFlightSurviveEviction() {
        var registry = CategoryRegistry()
        _ = registry.admit(category(1))
        registry.evict(keeping: [])
        #expect(registry.categories == [category(1)])
        registry.finish(category(1))
        registry.evict(keeping: [])
        #expect(registry.categories.isEmpty)
    }

    @Test func restoredCategoriesStayWithinCapacity() {
        var registry = CategoryRegistry()
        registry.restore((0..<(CategoryRegistry.capacity + 10)).map(category))
        #expect(registry.categories.count == CategoryRegistry.capacity)
    }
}

struct NotifyEffectTests {
    final class RecordingNotifier: Notifier {
        let posted = Mutex<[NotificationPlan]>([])
        let withdrawn = Mutex<[String]>([])
        func post(_ plan: NotificationPlan) async throws { posted.withLock { $0.append(plan) } }
        func withdraw(identifier: String) async throws { withdrawn.withLock { $0.append(identifier) } }
    }

    private func executor(_ notifier: RecordingNotifier) throws -> (EffectExecutor, URL) {
        let directory = temporaryURL("meerkat-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try RuleStore(path: directory.appendingPathComponent("rules.db").path)
        return (
            EffectExecutor(
                store: store, ownProcesses: OwnProcesses(), notifier: notifier,
                sampleDatabasePath: directory.appendingPathComponent("s.db").path,
                authorizer: EffectAuthorizer(permissionStatus: { _ in .granted }, protectedPaths: [])),
            directory
        )
    }

    private func rule(_ name: String, notify: Bool) throws -> RuleDefinition {
        try RuleDefinition(
            file: "a.ts",
            raw: ["name": .string(name), "on": "memory.pressure", "capabilities": ["notify": .bool(notify)]],
            catalog: .standard)
    }

    @Test func postAndWithdrawUseTheRulesOwnIdentifier() async throws {
        let notifier = RecordingNotifier()
        let (executor, directory) = try executor(notifier)
        defer { try? FileManager.default.removeItem(at: directory) }
        let definition = try rule("r", notify: true)
        #expect(
            await executor.perform(["kind": "notify", "title": "t", "id": "low"], for: definition)
                == .success(value: "null"))
        #expect(
            await executor.perform(["kind": "notify.withdraw", "id": "low"], for: definition) == .success(value: "null")
        )
        let posted = try #require(notifier.posted.withLock { $0.first })
        #expect(notifier.withdrawn.withLock { $0 } == [posted.identifier])
        #expect(posted.userInfo["meerkat.file"] == "a.ts")
        #expect(posted.userInfo["meerkat.rule"] == "r")
    }

    @Test func withdrawNeedsTheNotifyGrant() async throws {
        let notifier = RecordingNotifier()
        let (executor, directory) = try executor(notifier)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = await executor.perform(
            ["kind": "notify.withdraw", "id": "low"], for: try rule("r", notify: false))
        guard case .failure(let message) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(message.contains("notify: true"))
        #expect(notifier.withdrawn.withLock { $0 }.isEmpty)
    }
}

/// Responses through the real engine and runtime: a responder rule in the
/// posting file runs with the response; a rule in another file never does.
/// The notification center itself is not involved (no bundle in tests); the
/// responder's output is what `NotificationResponder` would send.
@Suite(.serialized)
struct NotificationResponseEndToEndTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    @Test func responsesReachOnlyThePostingFile() async throws {
        let fixture = try Fixture()
        for file in ["mine", "other"] {
            try fixture.write(
                "\(file).ts",
                """
                import { rule } from "meerkat";
                export const respond = rule({
                  name: "respond",
                  on: "meerkat.notification",
                  match: { rule: "throttle" },
                  async handle(event, ctx) {
                    await ctx.state.set("seen", { action: event.action, id: event.id, data: event.data ?? null });
                  },
                });
                """)
        }
        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        let diagnosis = await fixture.diagnosis()
        #expect(report.rules.filter { $0.state == .loaded }.count == 2, diagnosis)

        let store = try fixture.store()
        let expected: JSONValue = ["action": "undo", "id": "812", "data": ["pid": 812]]
        let delivered = try await eventually {
            fixture.daemon.hub.environment.internalEvents.send(
                .notification(
                    NotificationResponsePayload(
                        file: "mine.ts", rule: "throttle", id: "812", action: "undo", data: ["pid": 812])))
            return try store.value(rule: "mine.ts#respond", key: "seen") == expected
        }
        if !delivered { Issue.record(await fixture.diagnosis()) }
        #expect(try store.value(rule: "other.ts#respond", key: "seen") == nil)
        await fixture.cleanup()
    }

    /// `ctx.notify.withdraw` reaches the daemon as `notify.withdraw`. Tests
    /// run outside the bundle, so the notifier refuses it, which proves the
    /// request decoded and passed the grant check.
    @Test func withdrawReachesTheDaemonFromTheRuntime() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "warn.ts",
            """
            import { rule } from "meerkat";
            export const warn = rule({
              name: "warn",
              on: "darwin.notification",
              params: { names: ["\(name)"] },
              capabilities: { observe: { allow: ["darwin.notification"] }, notify: true },
              async handle(_event, ctx) {
                try {
                  await ctx.notify.withdraw("low");
                  await ctx.state.set("outcome", "ok");
                } catch (error) {
                  await ctx.state.set("outcome", String(error));
                }
              },
            });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        let refused = try await eventually {
            notify_post(name)
            return try store.value(rule: "warn.ts#warn", key: "outcome")?.stringValue?.contains("Meerkat.app") == true
        }
        if !refused { Issue.record(await fixture.diagnosis()) }
        await fixture.cleanup()
    }
}
