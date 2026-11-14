import Foundation
import MCP
import MeerkatIPC
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// The TCP side of MCP over HTTP (docs/design/mcp.md, "Transport: Streamable
/// HTTP"): swift-nio parses HTTP/1.1 on 127.0.0.1, and each request at
/// `/mcp` goes to `MCPHTTPClients` as the SDK's `HTTPRequest`.
///
/// Any process on this Mac can connect, so what a connection can cost before
/// it shows the token is bounded here: the request is admitted or refused on
/// its head, before its body is read; a connection that sends no head within
/// `headDeadline` is closed; and at most `connectionLimit` are open.
final class MCPHTTPListener: Sendable {
    static let host = "127.0.0.1"
    static let path = "/mcp"
    /// The largest request body: the same bound as one `meerkat mcp` line.
    static let bodyLimit = DaemonRequest.mcpMessageLimit
    static let connectionLimit = 128
    static let headDeadline = Duration.seconds(10)

    private typealias Connection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>

    /// The port bound, which differs from the one asked for when that was 0.
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: NIOAsyncChannel<Connection, Never>
    private let serving: Task<Void, Never>

    var url: String { "http://\(Self.host):\(port)\(Self.path)" }

    private init(
        port: Int, group: MultiThreadedEventLoopGroup, channel: NIOAsyncChannel<Connection, Never>,
        serving: Task<Void, Never>
    ) {
        self.port = port
        self.group = group
        self.channel = channel
        self.serving = serving
    }

    /// Binds `port` on the loopback address and serves until `stop`. Throws
    /// when the port cannot be bound, such as when another program holds it.
    static func start(port: Int, clients: MCPHTTPClients) async throws -> MCPHTTPListener {
        // One thread: requests are small and the work is in the servers' tasks.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel: NIOAsyncChannel<Connection, Never>
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 64)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: host, port: port) { child in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.configureHTTPServerPipeline()
                        return try Connection(wrappingChannelSynchronously: child)
                    }
                }
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        let bound = channel.channel.localAddress?.port ?? port
        let serving = Task<Void, Never> {
            let open = OpenConnections()
            // Ends when the listening socket closes (`stop`); cancelling it
            // closes every connection still open.
            _ = try? await withThrowingDiscardingTaskGroup { tasks in
                try await channel.executeThenClose { inbound in
                    for try await connection in inbound {
                        let admitted = open.count.withLock { open in
                            guard open < connectionLimit else { return false }
                            open += 1
                            return true
                        }
                        guard admitted else {
                            connection.channel.close(promise: nil)
                            continue
                        }
                        tasks.addTask {
                            await serve(connection, port: bound, clients: clients)
                            open.count.withLock { $0 -= 1 }
                        }
                    }
                }
            }
        }
        return MCPHTTPListener(port: bound, group: group, channel: channel, serving: serving)
    }

    /// Stops accepting and closes every connection, open SSE streams included.
    func stop() async {
        try? await channel.channel.close()
        serving.cancel()
        await serving.value
        try? await group.shutdownGracefully()
    }

    private final class OpenConnections: Sendable {
        let count = Mutex(0)
    }

    // MARK: - One connection

    /// Serves one connection's requests in order until it closes. The client
    /// closing the connection cancels the work, which also ends an SSE stream
    /// that would otherwise wait silently for its next message; cancelling the
    /// task closes the connection, which also ends a response being written
    /// to a client that stopped reading.
    private static func serve(_ connection: Connection, port: Int, clients: MCPHTTPClients) async {
        let channel = connection.channel
        let work = Task {
            // A connection reset by its client ends here like one it closed.
            try? await connection.executeThenClose { inbound, outbound in
                // Re-armed after each response: a connection that sends no
                // head in time, first or next, is closed.
                var deadline = closing(channel, after: headDeadline)
                defer { deadline.cancel() }
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                for try await part in inbound {
                    switch part {
                    case .head(let next):
                        deadline.cancel()
                        if let refused = clients.admit(converted(next, body: nil), port: port) {
                            try await write(refused, version: next.version, to: outbound, closing: true)
                            return
                        }
                        head = next
                        body.clear()
                    case .body(var chunk):
                        guard let request = head else { continue }
                        guard body.readableBytes + chunk.readableBytes <= bodyLimit else {
                            // Answered now and closed: the rest is never read.
                            try await write(
                                .error(statusCode: 413, .invalidRequest("request body exceeds \(bodyLimit) bytes")),
                                version: request.version, to: outbound, closing: true)
                            return
                        }
                        body.writeBuffer(&chunk)
                    case .end:
                        guard let current = head else { continue }
                        head = nil
                        let request = converted(current, body: body)
                        let response =
                            request.path == path
                            ? await clients.handle(request)
                            : .error(statusCode: 404, .invalidRequest("Not Found: MCP is at \(path)"))
                        try await write(response, version: current.version, to: outbound)
                        deadline = closing(channel, after: headDeadline)
                    }
                }
            }
        }
        channel.closeFuture.whenComplete { _ in work.cancel() }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    /// A task that closes `channel` after `delay`, unless cancelled first.
    private static func closing(_ channel: any Channel, after delay: Duration) -> Task<Void, any Error> {
        Task {
            try await Task.sleep(for: delay)
            channel.close(promise: nil)
        }
    }

    private static func converted(_ head: HTTPRequestHead, body: ByteBuffer?) -> HTTPRequest {
        // Repeated headers are joined, as RFC 9110 allows for list values;
        // names are compared without case.
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            let name = name.lowercased()
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return HTTPRequest(
            method: head.method.rawValue, headers: headers,
            body: body.flatMap { $0.readableBytes > 0 ? Data($0.readableBytesView) : nil },
            path: head.uri.split(separator: "?", maxSplits: 1).first.map(String.init))
    }

    /// Writes one response. An SSE stream is copied until it ends, or until
    /// the task is cancelled because the client went away; a stream that
    /// didn't end ends without its terminating chunk, so the client can tell
    /// it from one that completed. `closing` says the connection is closed
    /// after it.
    private static func write(
        _ response: HTTPResponse, version: HTTPVersion,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, closing: Bool = false
    ) async throws {
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        if closing { headers.replaceOrAdd(name: "Connection", value: "close") }
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        guard case .stream(let stream, _) = response else {
            let body = response.bodyData ?? Data()
            headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
            try await outbound.write(.head(HTTPResponseHead(version: version, status: status, headers: headers)))
            if !body.isEmpty { try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: body)))) }
            try await outbound.write(.end(nil))
            return
        }
        try await outbound.write(.head(HTTPResponseHead(version: version, status: status, headers: headers)))
        for try await chunk in stream {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: chunk))))
        }
        // A cancelled stream ends its loop without throwing.
        try Task.checkCancellation()
        try await outbound.write(.end(nil))
    }
}
