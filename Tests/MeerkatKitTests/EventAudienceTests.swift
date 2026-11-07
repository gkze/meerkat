import Foundation
import Testing

@testable import MeerkatKit

/// `EventAudience.rules`: the hub refuses clients a kind delivered only to
/// rules; which events each rule sees is the payload's view.
struct EventAudienceTests {
    @Test func externalSubscribersAreRefused() {
        let hub = EventHub()
        #expect(throws: EventError.self) { try hub.subscribe("meerkat.notification") }
        #expect(throws: Never.self) {
            try hub.subscribe("meerkat.notification", subscriber: .rule(file: "a.ts")).cancel()
        }
    }

    @Test func unrestrictedKindsIgnoreTheSubscriber() throws {
        let hub = EventHub()
        let subscription = try hub.subscribe("meerkat.rule", subscriber: .rule(file: "a.ts"))
        subscription.cancel()
    }

    /// Every `meerkat.*` kind about rules keeps each file to its own: by the
    /// payload's `file`, in its view.
    @Test(arguments: [
        ("meerkat.notification", JSONValue.object(["rule": "r", "id": "1", "action": "default"])),
        ("meerkat.rule", JSONValue.object(["state": "failed", "reason": "watching /Users/me/Private needs …"])),
        ("meerkat.dropped", JSONValue.object(["kind": "fs.change", "parameters": .object([:]), "dropped": 3])),
    ])
    func aRuleSeesOnlyItsOwnFiles(_ name: String, _ fields: JSONValue) throws {
        let kind = try #require(EventCatalog.standard.kind(named: name))
        let view = try #require(kind.view, "\(name) has no view")
        let event = { (file: String) -> JSONValue in
            var object = fields.objectValue ?? [:]
            object["file"] = .string(file)
            if name == "meerkat.rule" { object["ruleId"] = .string(file + "#r") }
            return .object(object)
        }
        let rule = RuleView(file: "a.ts", user: nil)
        #expect(view(event("a.ts"), rule) == event("a.ts"), "\(name)")
        #expect(view(event("b.ts"), rule) == nil, "\(name)")
    }

    /// A rule id splits back into its file one way (`RuleID`): no part holds
    /// a `#`, and an entry file whose name does is not loaded. A status
    /// carries its file as the engine gives it, so a refused file's failure
    /// reaches its own file, not the one its name starts with.
    @Test func aRuleIdNamesItsFile() {
        #expect(RuleID.make(file: "b.ts", name: "r") == "b.ts#r")
        #expect(RuleID.file(of: "b.ts#r") == "b.ts")
        #expect(RuleID.file(of: "b.ts") == "b.ts")
        #expect(RuleID.refusal(file: "b.ts") == nil)
        #expect(RuleID.refusal(file: "x.ts#y.ts") != nil)
        #expect(RuleID.refusal(name: "y.ts#c") != nil)
        let refused = RuleStatusPayload(ruleId: "x.ts#y.ts", file: "x.ts#y.ts", state: .failed, reason: "x")
        #expect(refused.viewed(by: RuleView(file: "x.ts", user: nil)) == nil)
        #expect(refused.viewed(by: RuleView(file: "x.ts#y.ts", user: nil)) == refused)
    }
}

/// Signalling a process attributes its exit to the daemon, and nothing else
/// about it.
struct ExpectedExitTests {
    @Test func onlyTheExpectedExitIsTheDaemons() {
        let own = OwnProcesses()
        let target = ProcessIdentity(pid: 4242, startMicroseconds: 1)
        #expect(own.expectExit(target))
        #expect(!own.expectExit(target), "a second request does not count as its own addition")
        #expect(own.expectsExit(of: target))
        #expect(!own.contains(target), "the process itself, and so its children, stay the system's")
        own.withdrawExpectedExit(target)
        #expect(!own.expectsExit(of: target))
        own.expectExit(target)
        own.remove(target)
        #expect(!own.expectsExit(of: target), "the observed exit clears it")
    }
}
