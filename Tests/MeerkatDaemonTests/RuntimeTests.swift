import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
import Testing
import notify

@testable import MeerkatDaemon

/// Bounds the daemon and the runtime each enforce on the same text.
struct RuntimeLimitTests {
    /// A name the runtime routes is one the daemon loads, and the reverse.
    @Test func ruleNamesHaveOneBound() {
        #expect(RuleID.maximumNameBytes == Int(maximumRuleNameBytes()))
    }
}

/// `capabilities.fs`: what a rule may grant its file, and what it never can.
struct FileGrantTests {
    @Test func pathsAreAbsoluteNormalizedOrHomeRelative() throws {
        let paths = try CapabilityGrants.paths(["/", "/tmp/x", "~", "~/Development"], "fs.write", home: "/Users/u")
        #expect(paths == ["/", "/tmp/x", "/Users/u", "/Users/u/Development"])
        for bad in ["relative", "/a/../b", "/a/./b", "/a/", "//a", "~user/x", ""] {
            #expect(throws: RuleDefinitionError.self, "\(bad)") {
                try CapabilityGrants.paths([.string(bad)], "fs.write", home: "/Users/u")
            }
        }
    }

    @Test func aFileGetsItsRulesGrantsAndNeverTheProtectedPaths() throws {
        func rule(_ file: String, _ name: String, _ fs: JSONValue) throws -> RuleDefinition {
            try RuleDefinition(
                file: file, raw: ["name": .string(name), "on": "memory.pressure", "capabilities": ["fs": fs]],
                catalog: .standard)
        }
        let definitions = [
            try rule("a.ts", "one", ["write": ["/tmp/a"]]),
            try rule("a.ts", "two", ["read": ["/tmp/r"], "write": ["/tmp/a", "/tmp/b"]]),
            try rule("b.ts", "three", [:]),
        ]
        let protected = RuleEngine.ProtectedPaths(read: ["/state"], write: ["/rules", "/state"])
        let permissions = RuleSetLoader.permissions(for: definitions, protected: protected)
        #expect(
            permissions["a"]
                == FilePermissions(
                    read: ["/tmp/r"], write: ["/tmp/a", "/tmp/b"],
                    denyRead: ["/state"], denyWrite: ["/rules", "/state"]))
        #expect(permissions["b"] == FilePermissions(denyRead: ["/state"], denyWrite: ["/rules", "/state"]))
    }

    @Test func theDaemonsOwnPathsAreProtected() {
        let paths = DaemonPaths(
            rulesDirectory: URL(fileURLWithPath: "/u/rules"), cacheDirectory: URL(fileURLWithPath: "/u/cache"),
            ruleDatabase: URL(fileURLWithPath: "/u/state/rules.db"),
            sampleDatabase: URL(fileURLWithPath: "/u/data/s.db"))
        let protected = paths.protected(
            executable: URL(fileURLWithPath: "/Applications/Meerkat.app/Contents/MacOS/meerkatd"))
        #expect(protected.read == ["/u/state"])
        #expect(
            protected.write == [
                // meerkat.json may be a link out of the rules folder.
                "/u/rules", "/u/rules/meerkat.json", "/u/cache", "/u/state", "/u/data/s.db", "/u/data/s.db-wal",
                "/u/data/s.db-shm",
                // The defaults domain can move the rules directory.
                DaemonPaths.preferencesFile.path, "/Applications/Meerkat.app",
            ])
    }
}

@Suite(.serialized)
struct RuntimeEndToEndTests {
    typealias Fixture = DaemonEndToEndTests.Fixture

    /// The rule that motivated the runtime: mark a directory as never to be
    /// indexed, with Deno's file API, inside its grant and nowhere else.
    @Test func aRuleWritesInsideItsGrantOnly() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        // Outside the fixture's root, which is its state folder and so
        // protected, with everything in it.
        let elsewhere = temporaryURL("meerkat-granted")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let granted = elsewhere.appendingPathComponent("granted").standardizedFileURL
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)
        let outside = elsewhere.appendingPathComponent("outside").standardizedFileURL
        let intoRules = fixture.paths.rulesDirectory.appendingPathComponent("planted.ts").standardizedFileURL
        try fixture.write(
            "mark.ts",
            """
            import { rule } from "meerkat";
            const attempt = async (path: string): Promise<string> => {
              try { await Deno.writeTextFile(path, ""); return "ok"; } catch (error) { return (error as Error).name; }
            };
            export const mark = rule({ name: "mark", on: "darwin.notification", params: { names: ["\(name)"] },
                   capabilities: { observe: { allow: ["darwin.notification"] }, fs: { write: ["\(granted.path)", "\(fixture.paths.rulesDirectory.path)"] } },
                   async handle(_e, ctx) {
                     await ctx.state.set("results", [
                       await attempt("\(granted.appendingPathComponent(".metadata_never_index").path)"),
                       await attempt("\(outside.path)"),
                       await attempt("\(intoRules.path)"),
                     ]);
                   } });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        let ran = try await eventually(10) {
            notify_post(name)
            return try store.value(rule: "mark.ts#mark", key: "results") != nil
        }
        let diagnosis = await fixture.diagnosis()
        #expect(ran, diagnosis)
        // The rules directory stays protected even though the rule granted
        // itself write access to it.
        #expect(try store.value(rule: "mark.ts#mark", key: "results") == ["ok", "NotCapable", "NotCapable"])
        #expect(FileManager.default.fileExists(atPath: granted.appendingPathComponent(".metadata_never_index").path))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: intoRules.path))
        await fixture.cleanup()
    }

    /// Nothing a rule runs can end the daemon's process.
    @Test func ruleCodeCannotExitTheDaemon() async throws {
        let fixture = try Fixture()
        let name = uniqueName()
        try fixture.write(
            "exit.ts",
            """
            import { rule } from "meerkat";
            export const exit = rule({ name: "exit", on: "darwin.notification", capabilities: { observe: { allow: ["darwin.notification"] } }, params: { names: ["\(name)"] },
                   async handle(_e, ctx) {
                     try { Deno.exit(1); } catch { await ctx.state.set("survived", true); }
                   } });
            """)
        try await fixture.daemon.start(listen: false)
        let store = try fixture.store()
        let survived = try await eventually(10) {
            notify_post(name)
            return try store.value(rule: "exit.ts#exit", key: "survived") == .bool(true)
        }
        let diagnosis = await fixture.diagnosis()
        #expect(survived, diagnosis)
        await fixture.cleanup()
    }
}
