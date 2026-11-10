import Foundation
import MeerkatKit
import MeerkatRuntimeBindings
import MeerkatStore
import Testing

@testable import MeerkatDaemon

/// What `process.signal` refuses whatever the rule's grants: the daemon, and
/// what it started. This test process stands in for the daemon, and
/// `continue` would be harmless if a refusal failed.
struct OwnProcessProtectionTests {
    /// Asks to `continue` `pid` and returns the refusal.
    private func refusal(signalling pid: pid_t) async throws -> String? {
        let directory = temporaryURL("meerkat-protect")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeerkatStore.RuleStore(path: directory.appendingPathComponent("rules.db").path)
        let executor = EffectExecutor(
            store: store, ownProcesses: OwnProcesses(), notifier: SilentNotifier(),
            sampleDatabasePath: directory.appendingPathComponent("s.db").path,
            authorizer: EffectAuthorizer(permissionStatus: { _ in .granted }, protectedPaths: []))
        let record = try #require(ProcessTable.record(pid: pid))
        let definition = try RuleDefinition(
            file: "a.ts",
            raw: ["name": "r", "on": "memory.pressure", "capabilities": ["process": ["signal": true]]],
            catalog: .standard)
        let outcome = await executor.perform(
            [
                "kind": "process.signal", "signal": "continue",
                "target": ["pid": .number(Double(record.pid)), "startedAt": .number(record.identity.startedAt)],
            ], for: definition)
        guard case .failure(let message) = outcome else { return nil }
        return message
    }

    /// Rules run inside the daemon, so signalling it would stop them all.
    @Test func theDaemonCannotBeSignalled() async throws {
        #expect(try await refusal(signalling: getpid())?.contains("the daemon itself") == true)
    }

    /// Nor a process the daemon started (`log stream`, a compiler, another
    /// rule's `exec`).
    @Test func theDaemonsChildrenCannotBeSignalled() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let refusal = try await refusal(signalling: child.processIdentifier)
        #expect(refusal?.contains("was started by the daemon") == true)
    }

    /// Nor what those started in turn: a shell's `sleep` stands in for the
    /// process an `exec` child or a helper runs.
    @Test func whatTheDaemonsChildrenStartCannotBeSignalled() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "/bin/sleep 30 & echo $!; wait"]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        defer { shell.terminate() }
        var line = ""
        while !line.contains("\n") {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            line += String(decoding: data, as: UTF8.self)
        }
        let pid = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        #expect(ProcessTable.record(pid: pid)?.parentPid == shell.processIdentifier)
        let refusal = try await refusal(signalling: pid)
        #expect(refusal?.contains("was started by the daemon") == true)
    }
}
