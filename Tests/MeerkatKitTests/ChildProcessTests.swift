import Darwin
import Foundation
import MeerkatKit
import Testing

struct ChildProcessTests {
    /// More stdin than a pipe holds, echoed back: neither side may block.
    @Test func largeInputDoesNotDeadlock() async throws {
        let input = String(repeating: "0123456789abcdef", count: 16_384)  // 256 KiB
        let result = try await ChildProcess.run(
            path: "/bin/cat", arguments: [], environment: [:], stdin: input,
            timeout: 10, outputLimit: 1 << 20)
        #expect(result.status == 0 && !result.timedOut)
        #expect(result.stdout.count == input.count)
    }

    /// A timeout ends the whole group, and a grandchild holding the pipes
    /// does not keep the effect waiting.
    @Test func timeoutKillsTheGroupAndReturns() async throws {
        let started = ContinuousClock.now
        let result = try await ChildProcess.run(
            path: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30"],
            environment: ["PATH": "/bin:/usr/bin"], stdin: nil,
            timeout: 0.5, outputLimit: 1024)
        #expect(result.timedOut)
        // SIGTERM ends it, not the SIGKILL a second later: the child does not
        // inherit the daemon's SIG_IGN (`childrenDoNotInheritIgnoredSignals`).
        // The shell dies of it, or, when its foreground `sleep` dies first,
        // exits with that child's status, 128 + SIGTERM.
        #expect(result.signal == SIGTERM || result.status == 128 + SIGTERM)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// The daemon ignores SIGTERM and SIGPIPE (meerkatd/main.swift); a child
    /// starts with both at their default, so the timeout's SIGTERM ends it
    /// and a write to a closed pipe stops it. This process stands in for the
    /// daemon while the children start.
    @Test func childrenDoNotInheritIgnoredSignals() async throws {
        let previous = (term: signal(SIGTERM, SIG_IGN), pipe: signal(SIGPIPE, SIG_IGN))
        defer {
            signal(SIGTERM, previous.term)
            signal(SIGPIPE, previous.pipe)
        }
        for (name, number) in [("TERM", SIGTERM), ("PIPE", SIGPIPE)] {
            // A shell cannot catch or reset a signal ignored when it started,
            // so it exits 3 only if it inherited SIG_IGN.
            let result = try await ChildProcess.run(
                path: "/bin/sh", arguments: ["-c", "kill -\(name) $$; exit 3"],
                environment: ["PATH": "/bin:/usr/bin"], stdin: nil, timeout: 10, outputLimit: 1024)
            #expect(result.signal == number, "SIG\(name): \(result)")
        }
    }

    @Test func outputIsCappedWithoutStallingTheChild() async throws {
        let result = try await ChildProcess.run(
            path: "/bin/sh", arguments: ["-c", "head -c 3000000 /dev/zero"],
            environment: ["PATH": "/bin:/usr/bin"], stdin: nil,
            timeout: 10, outputLimit: 4096)
        #expect(result.status == 0 && result.stdout.utf8.count == 4096)
    }

    @Test func missingExecutableFailsToSpawn() async {
        await #expect(throws: ChildProcess.Failure.self) {
            _ = try await ChildProcess.run(
                path: "/nonexistent/tool", arguments: [], environment: [:], stdin: nil,
                timeout: 1, outputLimit: 16)
        }
    }

    /// The rules tools run in the rules folder.
    @Test func runsInTheGivenDirectory() async throws {
        let result = try await ChildProcess.run(
            path: "/bin/pwd", arguments: [], environment: [:], directory: "/private/tmp", stdin: nil,
            timeout: 10, outputLimit: 1024)
        #expect(result.stdout == "/private/tmp\n")
    }

    /// A cancelled caller (a superseded compile) ends the group at once,
    /// which is not a timeout.
    @Test func cancellingEndsTheGroup() async throws {
        let started = ContinuousClock.now
        let run = Task {
            try await ChildProcess.run(
                path: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30"],
                environment: ["PATH": "/bin:/usr/bin"], stdin: nil, timeout: 60, outputLimit: 1024)
        }
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()
        let result = try await run.value
        // As at a timeout, the shell dies of SIGTERM or exits with its
        // foreground child's 128 + SIGTERM.
        #expect(!result.timedOut && (result.signal == SIGTERM || result.status == 128 + SIGTERM))
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
