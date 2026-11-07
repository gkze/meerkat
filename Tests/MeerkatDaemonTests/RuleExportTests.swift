import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatStore
import Testing
import notify

@testable import MeerkatDaemon

/// Rules are the values `rule()` returns that an entry file exports: one
/// module or many, with any number of exports each.
@Suite(.serialized)
struct RuleExportTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    /// One entry collects rules from a helper module and an array export;
    /// other exports are ignored, and a rule exported twice is one rule.
    @Test func aSingleModuleExportsRulesFromAnywhere() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try FileManager.default.createDirectory(
            at: fixture.paths.rulesDirectory.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try fixture.write(
            "lib/marks.ts",
            """
            import { rule } from "meerkat";
            const mark = (key: string) => rule({
              name: key, on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
              async handle(_e, ctx) { await ctx.state.set("ran", true); },
            });
            export const first = mark("first");
            export const second = mark("second");
            """)
        try fixture.write(
            "index.ts",
            """
            import { rule } from "meerkat";
            export * from "./lib/marks";
            export { first as alias } from "./lib/marks";
            export const grouped = [
              rule({ name: "third", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                     async handle(_e, ctx) { await ctx.state.set("ran", true); } }),
            ];
            export const helper = (n: number): number => n + 1;
            export const strings = ["not", "rules"];
            """)
        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        let ids = Set(report.rules.filter { $0.state == .loaded }.map(\.id))
        #expect(ids == ["index.ts#first", "index.ts#second", "index.ts#third"], "\(report.rules)")
        let store = try fixture.store()
        #expect(
            try await eventually {
                notify_post(name)
                return try ["first", "second", "third"].allSatisfy {
                    try store.value(rule: "index.ts#\($0)", key: "ran") == .bool(true)
                }
            })
        await fixture.cleanup()
    }

    /// The default export is an export like any other: a rule, or an array of
    /// rules with nested arrays flattened, type-checked and compiled as usual.
    @Test func defaultExportsAndNestedArraysLoad() async throws {
        let fixture = try Fixture()
        try fixture.write(
            "single.ts",
            """
            import { rule } from "meerkat";
            export default rule({ name: "only", on: "memory.pressure", handle() {} });
            """)
        try fixture.write(
            "list.ts",
            """
            import { rule } from "meerkat";
            const audio = [rule({ name: "a", on: "memory.pressure", handle() {} })];
            export default [
              audio,
              [rule({ name: "b", on: "power.source", match: { providing: "battery" }, handle() {} })],
              rule({ name: "c", on: "timer", params: { every: 60 }, handle() {} }),
            ];
            """)
        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        let ids = Set(report.rules.filter { $0.state == .loaded }.map(\.id))
        #expect(ids == ["single.ts#only", "list.ts#a", "list.ts#b", "list.ts#c"], "\(report.rules)")
        await fixture.cleanup()
    }

    /// A file written for side-effect registration fails loudly instead of
    /// loading and running nothing; other files are unaffected.
    @Test func aFileThatExportsNoRulesItCreatesFails() async throws {
        let fixture = try Fixture()
        try fixture.write(
            "old.ts",
            """
            import { rule } from "meerkat";
            rule({ name: "a", on: "memory.pressure", handle() {} });
            rule({ name: "b", on: "memory.pressure", handle() {} });
            """)
        try fixture.write(
            "new.ts",
            """
            import { rule } from "meerkat";
            export const c = rule({ name: "c", on: "memory.pressure", handle() {} });
            """)
        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        #expect(
            report.rules.contains {
                $0.file == "old.ts" && $0.state == .failed
                    && ($0.reason ?? "").contains("creates rules (a, b) but exports none")
            }, "\(report.rules)")
        #expect(report.rules.contains { $0.id == "new.ts#c" && $0.state == .loaded })
        await fixture.cleanup()
    }

    /// Rules an entry creates, or imports, but does not export do not run,
    /// and the file's log says which.
    @Test func unexportedRulesAreReported() async throws {
        let fixture = try Fixture()
        try fixture.write(
            "partial.ts",
            """
            import { rule } from "meerkat";
            rule({ name: "hidden", on: "memory.pressure", handle() {} });
            export const shown = rule({ name: "shown", on: "memory.pressure", handle() {} });
            """)
        try fixture.write(
            "empty.ts",
            """
            export const nothing = 1;
            """)
        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        #expect(report.rules.contains { $0.id == "partial.ts#shown" && $0.state == .loaded })
        #expect(!report.rules.contains { $0.id == "partial.ts#hidden" })
        let store = try fixture.store()
        let warned = try await eventually(5) {
            let partial = try store.logs(rule: "partial.ts", limit: 10)
            let empty = try store.logs(rule: "empty.ts", limit: 10)
            return partial.contains { $0.level == .warn && $0.message.hasSuffix("so not running: hidden") }
                && empty.contains { $0.level == .warn && $0.message == "empty.ts exports no rules" }
        }
        let diagnosis = await fixture.diagnosis()
        #expect(warned, diagnosis)
        await fixture.cleanup()
    }

    /// Ambiguous exports fail their file: two different rules with one name,
    /// and an array that mixes rules with other values.
    @Test func ambiguousExportsFail() async throws {
        let fixture = try Fixture()
        try fixture.write(
            "twice.ts",
            """
            import { rule } from "meerkat";
            export const one = rule({ name: "same", on: "memory.pressure", handle() {} });
            export const two = rule({ name: "same", on: "memory.pressure", handle() {} });
            """)
        try fixture.write(
            "mixed.ts",
            """
            import { rule } from "meerkat";
            export const all = [rule({ name: "r", on: "memory.pressure", handle() {} }), "oops"];
            """)
        try await fixture.daemon.start(listen: false)
        let report = await fixture.daemon.engine.report()
        #expect(
            report.rules.contains {
                $0.file == "twice.ts" && $0.state == .failed && ($0.reason ?? "").contains("\"same\" is defined twice")
            }, "\(report.rules)")
        #expect(
            report.rules.contains {
                $0.file == "mixed.ts" && $0.state == .failed && ($0.reason ?? "").contains("export \"all\" mixes rules")
            }, "\(report.rules)")
        await fixture.cleanup()
    }
}
