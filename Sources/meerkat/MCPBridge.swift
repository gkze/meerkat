import ArgumentParser
import Foundation
import MeerkatIPC

// MARK: - mcp

/// `meerkat mcp`: an MCP stdio server for clients that start one, relaying
/// to meerkatd (docs/design/mcp.md, "Transport: a stdio bridge in the CLI").
///
/// The bridge copies bytes and does not parse MCP: each stdin line goes to
/// the daemon as one `DaemonRequest.mcp`, and each `DaemonPush.mcp` comes
/// back as one stdout line. The protocol, the policy and every decision live
/// in the daemon. One bridge is one XPC session is one MCP session, so when
/// the client exits and closes stdin, the bridge exits, the session ends,
/// and the daemon releases whatever that client held.
struct MCPBridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve MCP on stdin and stdout, backed by meerkatd.",
        discussion: """
            Configure an MCP client to start this as a stdio server:

              { "command": "~/Applications/Meerkat.app/Contents/MacOS/meerkat", "args": ["mcp"] }

            It must be the meerkat inside Meerkat.app: meerkatd accepts only clients signed with the app. \
            Diagnostics go to stderr. The bridge exits with status 0 when stdin closes; 69 when meerkatd \
            restarts or cannot be reached, since MCP sessions do not survive a restart and the client \
            starts the bridge again; and 1 when the client sends a line longer than \
            \(DaemonRequest.mcpMessageLimit >> 20) MiB, which a new bridge would refuse too.
            """
    )

    /// How often the bridge checks that the daemon it started with is the
    /// one running. The daemon gives an idle session no signal when it is
    /// replaced, and a client waiting on a notification stream would wait
    /// forever.
    static let checkInterval = Duration.seconds(2)

    /// How the session ends. A failure says whose it is by its status: 69
    /// for the daemon, which a new bridge may reach, and 1 for the client's
    /// input, which a new bridge would refuse again.
    private enum Outcome: Sendable {
        case inputClosed
        case failed(CommandFailure)
    }

    func run() async throws {
        let client = DaemonClient()
        let started: DaemonIdentity
        do {
            started = try await client.daemonIdentity(within: DaemonClient.pingLimit)
        } catch {
            throw CommandFailure("meerkat mcp: \(error)", status: ExitStatus.unavailable)
        }
        // Registered before the first message, so no answer can arrive unread.
        let output = client.mcpMessages()

        let (outcomes, finish) = AsyncStream.makeStream(of: Outcome.self)
        Task {
            for await message in output {
                FileHandle.standardOutput.write(message + Data("\n".utf8))
            }
        }
        Task {
            do {
                try await Self.relayInput(to: client)
                finish.yield(.inputClosed)
            } catch let failure as CommandFailure {
                finish.yield(.failed(failure))
            } catch {
                finish.yield(.failed(CommandFailure("\(error)", status: ExitStatus.unavailable)))
            }
        }
        Task {
            while true {
                try? await Task.sleep(for: Self.checkInterval)
                do {
                    // A daemon that stops answering ends the session like
                    // one that was replaced: the client would wait forever.
                    let current = try await client.daemonIdentity(within: DaemonClient.pingLimit)
                    if current != started {
                        finish.yield(
                            .failed(
                                CommandFailure(
                                    "meerkatd restarted (pid \(started.pid) is now \(current.pid))",
                                    status: ExitStatus.unavailable)))
                        return
                    }
                } catch {
                    finish.yield(.failed(CommandFailure("\(error)", status: ExitStatus.unavailable)))
                    return
                }
            }
        }

        // The first outcome decides. The stdin reader may be blocked in a read
        // that cancellation cannot interrupt, so nothing waits for it: the
        // process ends when `main` does.
        var outcome = Outcome.inputClosed
        for await first in outcomes {
            outcome = first
            break
        }
        if case .failed(let failure) = outcome {
            throw CommandFailure("meerkat mcp: \(failure.message); the MCP session has ended", status: failure.status)
        }
    }

    /// Sends each stdin line to the daemon in order, until stdin closes. A
    /// line over the daemon's limit is the client's failure; a send that
    /// fails is the daemon's.
    ///
    /// Lines end at LF only, with an optional CR before it. Foundation's
    /// line sequences also split at U+2028 and U+2029, which JSON allows
    /// unescaped inside strings.
    private static func relayInput(to client: DaemonClient) async throws {
        var line = Data()
        for try await byte in FileHandle.standardInput.bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                guard line.count <= DaemonRequest.mcpMessageLimit else {
                    throw CommandFailure("an input line is longer than \(DaemonRequest.mcpMessageLimit) bytes")
                }
                continue
            }
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            if !line.isEmpty { try await client.sendMCP(line) }
            line.removeAll(keepingCapacity: true)
        }
        if !line.isEmpty { try await client.sendMCP(line) }
    }
}
