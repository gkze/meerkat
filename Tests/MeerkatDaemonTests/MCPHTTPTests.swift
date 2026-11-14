import Foundation
import MeerkatIPC
import MeerkatKit
import Synchronization
import Testing

@testable import MeerkatDaemon

/// MCP over Streamable HTTP as a client sees it: real requests over TCP to a
/// real `MCPHTTPServer` on an ephemeral loopback port, serving the same
/// `MCPService` the XPC tests do. They cover what this transport adds: the
/// token and `Origin` checks, refusing on the head, sessions begun with
/// `initialize`, 2026-07-28 clients, the body and client limits, rotation and
/// a port that is taken. Not covered: idle expiry and the replay budget, which
/// take half an hour or 64 MiB, and the deadline for a connection's first head.
@Suite(.serialized)
struct MCPHTTPTests {
    /// A listening server with a token kept in memory, not the Keychain.
    struct Listening {
        let peer: Peer
        let server: MCPHTTPServer
        let url: URL
        let token: String

        init(port: Int = 0) async throws {
            peer = try Peer()
            server = MCPHTTPServer(token: MCPHTTPToken(store: MemoryStore()))
            await server.apply(.init(enabled: true, port: port), serving: peer.service)
            let access = try await server.access(rotateToken: false)
            url = try #require(access.status.url.flatMap(URL.init(string:)), "\(access.status)")
            token = access.token
        }

        var port: Int { url.port ?? 0 }

        /// Runs `body` against a listening server, then stops it, whether
        /// `body` returned or threw.
        static func serve(port: Int = 0, _ body: (Listening) async throws -> Void) async throws {
            let listening = try await Listening(port: port)
            do {
                try await body(listening)
            } catch {
                await listening.server.stop()
                throw error
            }
            await listening.server.stop()
        }
    }

    final class MemoryStore: MCPHTTPToken.Store {
        private let value = Mutex<String?>(nil)
        func read() throws -> String? { value.withLock { $0 } }
        func write(_ token: String) throws { value.withLock { $0 = token } }
    }

    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The JSON-RPC message: the body itself, or the last `data:` line of
        /// an SSE body.
        var message: JSONValue {
            get throws {
                let text = String(decoding: body, as: UTF8.self)
                let json =
                    header("Content-Type")?.hasPrefix("text/event-stream") == true
                    ? text.split(separator: "\n").last { $0.hasPrefix("data: ") && $0.count > 6 }.map {
                        String($0.dropFirst(6))
                    } ?? ""
                    : text
                return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            }
        }
    }

    static func post(
        _ url: URL, _ message: JSONValue, token: String?, session: String? = nil,
        accept: String = "application/json, text/event-stream",
        headers: [String: String] = [:]
    ) async throws -> Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request)
    }

    static func send(_ request: URLRequest) async throws -> Reply {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return Reply(status: http.statusCode, headers: headers, body: data)
    }

    /// Writes `bytes` on a new connection to `port`, and returns what comes
    /// back before the server closes it, or 5 seconds pass. Raw, so a test can
    /// send a head without its body.
    static func exchange(port: Int, _ bytes: Data) throws -> String {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(socket >= 0)
        defer { close(socket) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.send(socket, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if sent <= 0 { return }
                offset += sent
            }
        }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(socket, &chunk, chunk.count, 0)
            if count <= 0 { break }
            received.append(contentsOf: chunk[..<count])
        }
        return String(decoding: received, as: UTF8.self)
    }

    static func head(port: Int, token: String?, contentLength: Int) -> String {
        "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\n"
            + (token.map { "Authorization: Bearer \($0)\r\n" } ?? "")
            + "Content-Length: \(contentLength)\r\n\r\n"
    }

    static let initialize: JSONValue = [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
        ],
    ]

    static func modern(_ method: String, id: Int = 1, _ params: [String: JSONValue] = [:]) -> JSONValue {
        var params = params
        params["_meta"] = Peer.meta(version: "2026-07-28")
        return ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params)]
    }

    // MARK: - Who may connect

    @Test func aRequestWithoutTheTokenIsRefused() async throws {
        try await Listening.serve { listening in
            let missing = try await Self.post(listening.url, Self.initialize, token: nil)
            #expect(missing.status == 401)
            #expect(missing.header("WWW-Authenticate") == "Bearer")
            let wrong = try await Self.post(listening.url, Self.initialize, token: String(repeating: "x", count: 43))
            #expect(wrong.status == 401)
            #expect(await listening.server.status.clients == 0)
        }
    }

    /// A request without the token is answered on its head: its body is never
    /// waited for, let alone kept. A server that read the body first would
    /// answer nothing here, since none is sent.
    @Test func aRequestIsRefusedOnItsHead() async throws {
        try await Listening.serve { listening in
            let reply = try Self.exchange(
                port: listening.port, Data(Self.head(port: listening.port, token: nil, contentLength: 1_000_000).utf8))
            #expect(reply.hasPrefix("HTTP/1.1 401"), "\(reply)")
        }
    }

    /// A page served from anywhere else, another port on this Mac included,
    /// is refused even with the token: DNS rebinding and cross-origin requests.
    @Test func anotherOriginIsRefused() async throws {
        try await Listening.serve { listening in
            for origin in ["http://evil.example", "http://127.0.0.1:\(listening.port + 1)"] {
                let reply = try await Self.post(
                    listening.url, Self.initialize, token: listening.token, headers: ["Origin": origin])
                #expect(reply.status == 403, "\(origin)")
            }
            let own = try await Self.post(
                listening.url, Self.initialize, token: listening.token,
                headers: ["Origin": "http://127.0.0.1:\(listening.port)"])
            #expect(own.status == 200)
        }
    }

    // MARK: - Sessions

    @Test func initializeBeginsASession() async throws {
        try await Listening.serve { listening in
            let initialized = try await Self.post(listening.url, Self.initialize, token: listening.token)
            #expect(initialized.status == 200)
            let session = try #require(initialized.header("Mcp-Session-Id"))
            let result = try initialized.message["result"]
            #expect(result?["protocolVersion"] == "2025-11-25")
            #expect(result?["serverInfo"]?["name"] == "meerkatd")
            #expect(await listening.server.status.clients == 1)

            let headers = ["MCP-Protocol-Version": "2025-11-25"]
            _ = try await Self.post(
                listening.url, ["jsonrpc": "2.0", "method": "notifications/initialized"], token: listening.token,
                session: session, headers: headers)
            let tools = try await Self.post(
                listening.url, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: listening.token,
                session: session, headers: headers)
            #expect(
                try tools.message["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
                    == ["events_sample", "samples_compare", "resource_read", "rules_check", "rules_dry_run"])
            // Initialize-based results carry no 2026-07-28 caching hints.
            #expect(try tools.message["result"]?["ttlMs"] == nil)
        }
    }

    @Test func anUnknownSessionIsNotFound() async throws {
        try await Listening.serve { listening in
            let reply = try await Self.post(
                listening.url, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: listening.token,
                session: UUID().uuidString)
            #expect(reply.status == 404)
        }
    }

    @Test func modernRequestsNeedNoSession() async throws {
        try await Listening.serve { listening in
            let reply = try await Self.post(
                listening.url, Self.modern("tools/list"), token: listening.token, accept: "application/json",
                // 2026-07-28 over HTTP names the method in a header too.
                headers: ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"])
            #expect(reply.status == 200, "\(String(decoding: reply.body, as: UTF8.self))")
            let result = try reply.message["result"]
            #expect(result?["ttlMs"] == 0)
            #expect(result?["cacheScope"] == "private")
            #expect(reply.header("Mcp-Session-Id") == nil)
        }
    }

    /// 2026-07-28 clients are told apart by `MCP-Client-Identity`, each with a
    /// server of its own, so their request ids can't meet; clients without one
    /// share one.
    @Test func eachModernClientHasItsOwnServer() async throws {
        try await Listening.serve { listening in
            for identity in ["a", "b", nil, "a", nil] as [String?] {
                var headers = ["MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"]
                headers["MCP-Client-Identity"] = identity
                let reply = try await Self.post(
                    listening.url, Self.modern("tools/list"), token: listening.token, accept: "application/json",
                    headers: headers)
                #expect(reply.status == 200)
            }
            #expect(await listening.server.status.clients == 3)
        }
    }

    /// An `initialize` the transport refuses (here, for its `Accept` header)
    /// opens nothing.
    @Test func aRefusedInitializeOpensNoSession() async throws {
        try await Listening.serve { listening in
            let refused = try await Self.post(
                listening.url, Self.initialize, token: listening.token, accept: "application/json")
            #expect(refused.status != 200)
            #expect(refused.header("Mcp-Session-Id") == nil)
            #expect(await listening.server.status.clients == 0)
        }
    }

    /// One the server refuses, inside the stream the transport opened for it,
    /// ends the session that stream named.
    @Test func anInitializeTheServerRefusesOpensNoSession() async throws {
        try await Listening.serve { listening in
            let invalid: JSONValue = [
                "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": 5],
            ]
            let refused = try await Self.post(listening.url, invalid, token: listening.token)
            #expect(try refused.message["error"] != nil, "\(String(decoding: refused.body, as: UTF8.self))")
            #expect(await listening.server.status.clients == 0)
            // The transport named a session before the server refused it.
            let session = try #require(refused.header("Mcp-Session-Id"))
            let after = try await Self.post(
                listening.url, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: listening.token,
                session: session)
            #expect(after.status == 404)
        }
    }

    @Test func deleteEndsTheSession() async throws {
        try await Listening.serve { listening in
            let initialized = try await Self.post(listening.url, Self.initialize, token: listening.token)
            let session = try #require(initialized.header("Mcp-Session-Id"))
            var delete = URLRequest(url: listening.url)
            delete.httpMethod = "DELETE"
            delete.setValue("Bearer \(listening.token)", forHTTPHeaderField: "Authorization")
            delete.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            delete.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
            #expect(try await Self.send(delete).status == 200)
            #expect(await listening.server.status.clients == 0)
            let after = try await Self.post(
                listening.url, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: listening.token,
                session: session)
            #expect(after.status == 404)
        }
    }

    @Test func clientsPastTheLimitAreRefused() async throws {
        try await Listening.serve { listening in
            for _ in 0..<MCPHTTPClients.clientLimit {
                #expect(try await Self.post(listening.url, Self.initialize, token: listening.token).status == 200)
            }
            let over = try await Self.post(listening.url, Self.initialize, token: listening.token)
            #expect(over.status == 503)
            #expect(await listening.server.status.clients == MCPHTTPClients.clientLimit)
        }
    }

    /// Answered as soon as the body passes the limit: the server never waits
    /// for the rest, which here never comes.
    @Test func aBodyOverTheLimitIsRefused() async throws {
        try await Listening.serve { listening in
            let size = MCPHTTPListener.bodyLimit + 1
            var bytes = Data(Self.head(port: listening.port, token: listening.token, contentLength: size + 100).utf8)
            bytes.append(Data(repeating: UInt8(ascii: " "), count: size))
            let reply = try Self.exchange(port: listening.port, bytes)
            #expect(reply.hasPrefix("HTTP/1.1 413"), "\(reply.prefix(200))")
        }
    }

    @Test func anotherPathIsNotFound() async throws {
        try await Listening.serve { listening in
            var other = URLComponents(url: listening.url, resolvingAgainstBaseURL: false)!
            other.path = "/other"
            let reply = try await Self.post(other.url!, Self.initialize, token: listening.token)
            #expect(reply.status == 404)
        }
    }

    // MARK: - The token and the port

    /// A rotated token ends every session opened with the old one, and the
    /// old token opens nothing new.
    @Test func rotatingTheTokenEndsEverySession() async throws {
        try await Listening.serve { listening in
            let initialized = try await Self.post(listening.url, Self.initialize, token: listening.token)
            let session = try #require(initialized.header("Mcp-Session-Id"))
            let rotated = try await listening.server.access(rotateToken: true)
            #expect(rotated.token != listening.token)
            #expect(rotated.status.clients == 0)
            #expect(try await Self.post(listening.url, Self.initialize, token: listening.token).status == 401)
            let ended = try await Self.post(
                listening.url, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: rotated.token,
                session: session)
            #expect(ended.status == 404)
            #expect(try await Self.post(listening.url, Self.initialize, token: rotated.token).status == 200)
        }
    }

    @Test func aPortThatIsTakenIsReported() async throws {
        try await Listening.serve { first in
            let second = MCPHTTPServer(token: MCPHTTPToken(store: MemoryStore()))
            await second.apply(.init(enabled: true, port: first.port), serving: first.peer.service)
            let status = await second.status
            #expect(status.state == .failed)
            #expect(status.problem?.isEmpty == false)
            // The first is unaffected.
            let reply = try await Self.post(first.url, Self.initialize, token: first.token)
            #expect(reply.status == 200)
        }
    }

    @Test func turningItOffStopsListening() async throws {
        let listening = try await Listening()
        await listening.server.apply(.init(enabled: false, port: 0), serving: listening.peer.service)
        #expect(await listening.server.status == .off)
        await #expect(throws: (any Error).self) {
            _ = try await Self.post(listening.url, Self.initialize, token: listening.token)
        }
    }

    // MARK: - The token

    @Test func theTokenIsComparedWhole() throws {
        let token = MCPHTTPToken(store: MemoryStore())
        #expect(!token.authorizes("Bearer anything"), "nothing matches before a token is loaded")
        let value = try token.current()
        #expect(value.count == 43)
        #expect(token.authorizes("Bearer \(value)"))
        #expect(token.authorizes("bearer \(value)"))
        #expect(!token.authorizes(value))
        #expect(!token.authorizes("Bearer \(value.dropLast())"))
        #expect(!token.authorizes("Bearer \(value)x"))
        // One character different, in the middle, at the same length.
        var changed = Array(value)
        changed[21] = changed[21] == "A" ? "B" : "A"
        #expect(!token.authorizes("Bearer \(String(changed))"))
        #expect(!token.authorizes(nil))
        // Read back, not made again.
        #expect(try token.current() == value)
    }
}
