import ArgumentParser
import Foundation
import MeerkatIPC

// MARK: - mcp

/// `meerkat mcp`: the ways an MCP client reaches meerkatd
/// (docs/design/mcp.md, "Transport"). With no subcommand, the stdio bridge,
/// so a client configured with `["mcp"]` starts it.
struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve MCP to a client: on stdio (the default), or over HTTP.",
        subcommands: [MCPBridge.self, MCPHTTPCommand.self],
        defaultSubcommand: MCPBridge.self
    )
}

/// `meerkat mcp http`: where meerkatd's MCP HTTP listener is and the token it
/// takes, for clients that connect to a URL instead of starting a process.
struct MCPHTTPCommand: AsyncParsableCommand, JSONOutput {
    static let configuration = CommandConfiguration(
        commandName: "http",
        abstract: "Print the MCP HTTP URL and bearer token for a client's configuration.",
        discussion: """
            meerkatd serves MCP over Streamable HTTP on 127.0.0.1, beside `meerkat mcp`, unless \
            meerkat.json sets mcp.http.enabled to false; mcp.http.port picks the port. Every request needs \
            the header `Authorization: Bearer <token>`. The token is kept in the login Keychain; anyone who \
            has it can read what meerkatd observes, so treat a client's configuration file that holds it \
            as a secret, and --rotate-token if it leaks, which ends every HTTP client. Exits \
            \(ExitStatus.unavailable.code), after printing the token, when the listener is off or failed to start.
            """
    )

    @Flag(help: "Replace the token first. Clients holding the old one are refused from their next request.")
    var rotateToken = false

    @Flag(help: "Print JSON.")
    var json = false

    func run() async throws {
        let access = try await withDaemon { try await $0.mcpHTTP(rotateToken: rotateToken) }
        // Printed whether or not HTTP is listening: a token just replaced must
        // reach the user either way.
        if json { try printJSON(access, pretty: true) } else { Self.output(access).print() }
        let status = access.status
        switch status.state {
        case .listening: return
        case .off:
            throw CommandFailure(
                "meerkatd is not serving MCP over HTTP: meerkat.json sets mcp.http.enabled to false",
                status: .unavailable)
        case .failed:
            throw CommandFailure(
                "meerkatd is not serving MCP over HTTP: \(status.problem ?? "it failed to start")", status: .unavailable
            )
        }
    }

    static func output(_ access: MCPHTTPAccess) -> TerminalOutput {
        var output = TerminalOutput()
        guard let url = access.status.url else {
            output.add("token  \(access.token)")
            return output
        }
        output.add("url    \(url)  (\(access.status.clients) clients)")
        output.add("token  \(access.token)")
        output.add()
        output.add("An MCP client's configuration:")
        output.add()
        output.add(
            #"  { "type": "http", "url": "\#(url)", "headers": { "Authorization": "Bearer \#(access.token)" } }"#)
        return output
    }
}

/// `meerkat mcp` (`meerkat mcp stdio`): an MCP stdio server for clients that
/// start one, relaying to meerkatd (docs/design/mcp.md, "Transport: a stdio
/// bridge in the CLI").
///
/// The bridge copies bytes and does not parse MCP: each stdin line goes to
/// the daemon as one `DaemonRequest.mcp`, and each `DaemonPush.mcp` comes
/// back as one stdout line. The protocol, the policy and every decision live
/// in the daemon. One bridge is one XPC session is one MCP session, so when
/// the client exits and closes stdin, the bridge exits, the session ends,
/// and the daemon releases whatever that client held.
struct MCPBridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stdio",
        abstract: "Serve MCP on stdin and stdout, backed by meerkatd.",
        discussion: """
            Configure an MCP client to start this as a stdio server:

              { "command": "\(DaemonService.installedApp)/\(DaemonService.cliPath)", "args": ["mcp"] }

            It must be the meerkat inside Meerkat.app: meerkatd accepts only clients signed with the app. \
            Diagnostics go to stderr. The bridge exits with status \(ExitStatus.success.code) when stdin \
            closes; \(ExitStatus.unavailable.code) when meerkatd restarts, cannot be reached, or turns a \
            message away because the session is backed up or closing, since MCP sessions do not survive a \
            restart and the client starts the bridge again; and \(ExitStatus.failure.code) when the client \
            sends a line longer than \(DaemonRequest.mcpMessageLimit >> 20) MiB, or meerkatd is a different \
            build, which a new bridge would meet too.
            """
    )

    /// How often the bridge checks that the daemon it started with is the
    /// one running. The daemon gives an idle session no signal when it is
    /// replaced, and a client waiting on a notification stream would wait
    /// forever.
    static let checkInterval = Duration.seconds(2)

    private enum Outcome: Sendable {
        case inputClosed
        case failed(CommandFailure)
    }

    func run() async throws {
        let client = DaemonClient()
        let started = try await withDaemon(client) { try await $0.daemonIdentity() }
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
            } catch {
                finish.yield(.failed(Self.failure(error)))
            }
        }
        Task {
            while true {
                try? await Task.sleep(for: Self.checkInterval)
                do {
                    // A daemon that stops answering ends the session like
                    // one that was replaced: the client would wait forever.
                    let current = try await client.daemonIdentity()
                    if current != started {
                        finish.yield(
                            .failed(
                                CommandFailure(
                                    "meerkatd restarted (pid \(started.pid) is now \(current.pid))",
                                    status: .unavailable)))
                        return
                    }
                } catch {
                    finish.yield(.failed(Self.failure(error)))
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

    /// What ends the session, by whose it is: the client's input (the
    /// bridge's own refusal) or a different build is a `failure`, since a
    /// new bridge would meet them again; everything else is `unavailable`,
    /// since a new bridge may get further. That includes meerkatd refusing a
    /// message: it does so only for the session's state (backed up, or
    /// closing as it shuts down), never for what the message says, which
    /// MCP answers in band; and anything not the daemon's, such as stdin
    /// failing.
    static func failure(_ error: any Error) -> CommandFailure {
        if let failure = error as? CommandFailure { return failure }
        switch DaemonFailure(classifying: error) {
        case .differentBuild?: return CommandFailure("\(error)")
        case .refused?, .unavailable?, nil: return CommandFailure("\(error)", status: .unavailable)
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
