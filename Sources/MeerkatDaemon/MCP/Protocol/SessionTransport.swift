import Foundation
import Logging
import MCP
import MeerkatIPC

/// One XPC session's MCP byte stream, as the SDK's `Transport`.
///
/// Input arrives as `DaemonRequest.mcp` messages, which the XPC handler
/// passes to `deliver` in the order the session received them; output goes
/// back as `DaemonPush.mcp` through `push`. The transport also does two
/// things the SDK leaves to the server (docs/design/mcp.md, "Inside the
/// daemon"):
///
/// - It holds input back until `open()`, because `Server.start` installs the
///   SDK's own `subscriptions/listen` handler, and the protocol layer's must
///   replace it before the first message is handled.
/// - It records the version `initialize` negotiated, which the SDK keeps
///   private, so handlers can tell a legacy session from a modern one.
actor SessionTransport: Transport {
    /// Bounds what one session can queue ahead of its server. Messages are
    /// handled as they arrive, so a full queue means a client that floods
    /// the session; the message is refused rather than dropped silently.
    static let queueLimit = 1024
    static let messageLimit = DaemonRequest.mcpMessageLimit

    nonisolated let logger = Logger(label: "meerkatd.mcp")
    private nonisolated let input: AsyncThrowingStream<Data, any Error>.Continuation
    private let inbound: AsyncThrowingStream<Data, any Error>
    private let push: @Sendable (Data) throws -> Void
    private(set) var initializedVersion: String?
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(push: @escaping @Sendable (Data) throws -> Void) {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.queueLimit))
        inbound = stream
        input = continuation
        self.push = push
    }

    enum DeliveryError: Error, CustomStringConvertible {
        case tooLarge(Int)
        case backlogged
        case closed

        var description: String {
            switch self {
            case .tooLarge(let size): "MCP message of \(size) bytes exceeds \(SessionTransport.messageLimit)"
            case .backlogged: "MCP session has \(SessionTransport.queueLimit) messages waiting"
            case .closed: "MCP session is closed"
            }
        }
    }

    /// Queues one message from the client. Called from the XPC handler, which
    /// runs one message at a time per session, so order is the client's.
    nonisolated func deliver(_ message: Data) throws(DeliveryError) {
        guard message.count <= Self.messageLimit else { throw .tooLarge(message.count) }
        switch input.yield(message) {
        case .enqueued: return
        case .dropped: throw .backlogged
        case .terminated: throw .closed
        @unknown default: throw .closed
        }
    }

    /// Ends input: the server's receive loop finishes and the server stops.
    nonisolated func finish() { input.finish() }

    func connect() async throws {}
    func disconnect() async { input.finish() }
    func send(_ data: Data) async throws { try push(data) }

    /// Lets queued input through. Call once handlers are registered.
    func open() {
        opened = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    private func untilOpen() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        let upstream = inbound
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.untilOpen()
                do {
                    for try await data in upstream {
                        self.observe(data)
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A JSON-RPC request as far as `initialize` is read.
    private struct Envelope: Decodable {
        let method: String
        let params: Value?
    }

    private func observe(_ data: Data) {
        guard let request = try? JSONDecoder().decode(Envelope.self, from: data),
            request.method == Initialize.name
        else { return }
        // The SDK's rule (its `Version.negotiate` is internal): a legacy version
        // it serves is accepted, anything else gets the latest legacy version.
        let requested = request.params?.objectValue?["protocolVersion"]?.stringValue ?? ""
        initializedVersion = Version.legacy.contains(requested) ? requested : Version.latestLegacy
    }
}
