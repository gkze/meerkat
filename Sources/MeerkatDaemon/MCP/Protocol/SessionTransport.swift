import Foundation
import Logging
import MCP
import MeerkatIPC

/// One XPC session's MCP byte stream, as the SDK's `Transport`.
///
/// Input arrives as `DaemonRequest.mcp` messages, which the XPC handler
/// passes to `deliver` in the order the session received them; output goes
/// back as `DaemonPush.mcp` through `push`.
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

    func receive() -> AsyncThrowingStream<Data, any Error> { inbound }
}
