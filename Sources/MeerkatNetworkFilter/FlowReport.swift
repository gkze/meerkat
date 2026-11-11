import Foundation

/// One running process, as an audit token names it: the pid and the pid's
/// version, which the kernel bumps on every exec and reuse, so a recycled pid
/// is a different key. `uid` is the effective user, for the daemon's
/// per-rule observation scope.
public struct ProcessKey: Hashable, Sendable, Codable {
    public let pid: Int32
    public let version: Int32
    public let uid: UInt32

    public init(pid: Int32, version: Int32, uid: UInt32) {
        self.pid = pid
        self.version = version
        self.uid = uid
    }

    /// The key in an `audit_token_t`, as NetworkExtension hands it over: eight
    /// 32-bit words, euid at 1, pid at 5, pid version at 7. Anything but 32
    /// bytes, or a pid that is not positive, is no process.
    public init?(auditToken data: Data) {
        guard data.count == MemoryLayout<UInt32>.size * 8 else { return nil }
        let words = data.withUnsafeBytes { raw in
            (0..<8).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        let pid = Int32(bitPattern: words[5])
        guard pid > 0 else { return nil }
        self.init(pid: pid, version: Int32(bitPattern: words[7]), uid: words[1])
    }
}

/// Where a flow goes: the name the app connected to when macOS knows it
/// (`remoteHostname`), otherwise the remote address, with the port and the
/// transport.
public struct RemoteEndpoint: Hashable, Sendable, Codable {
    public enum Transport: String, Hashable, Sendable, Codable, CaseIterable {
        case tcp, udp, other
    }

    /// A DNS name is at most 253 characters, an IPv6 address with a zone well
    /// under that; longer is not a host.
    public static let maximumHostLength = 253

    public let host: String
    public let port: UInt16
    public let transport: Transport

    /// Nil for an empty or over-long host: the ledger keeps no entry it could
    /// not later hand on intact.
    public init?(host: String, port: UInt16, transport: Transport) {
        guard !host.isEmpty, host.utf8.count <= Self.maximumHostLength else { return nil }
        self.host = host
        self.port = port
        self.transport = transport
    }
}

/// What NetworkExtension reports about one flow: its statistics so far or its
/// close. `bytesIn` and `bytesOut` are the flow's running totals, not deltas.
public struct FlowReport: Sendable {
    /// `opened` comes with the verdict, before any statistics; the ledger
    /// counts only flows it saw open.
    public enum Event: Sendable, Equatable {
        case opened, statistics, closed
    }

    public let flow: UUID
    public let event: Event
    /// The process charged: the app behind the flow, which for traffic macOS
    /// sends on an app's behalf (a background download) is that app, not the
    /// system process that made the connection. Nil when macOS gave none.
    public let process: ProcessKey?
    public let remote: RemoteEndpoint?
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(
        flow: UUID, event: Event, process: ProcessKey?, remote: RemoteEndpoint?, bytesIn: UInt64, bytesOut: UInt64
    ) {
        self.flow = flow
        self.event = event
        self.process = process
        self.remote = remote
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

// Decoding goes through the same checks as the initializers, so a key that
// could not be made in the extension cannot be decoded in the daemon either.

extension ProcessKey {
    private enum CodingKeys: String, CodingKey { case pid, version, uid }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pid = try container.decode(Int32.self, forKey: .pid)
        guard pid > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .pid, in: container, debugDescription: "pid \(pid) is no process")
        }
        self.init(
            pid: pid, version: try container.decode(Int32.self, forKey: .version),
            uid: try container.decode(UInt32.self, forKey: .uid))
    }
}

extension RemoteEndpoint {
    private enum CodingKeys: String, CodingKey { case host, port, transport }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decode(String.self, forKey: .host)
        guard
            let endpoint = RemoteEndpoint(
                host: host, port: try container.decode(UInt16.self, forKey: .port),
                transport: try container.decode(Transport.self, forKey: .transport))
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .host, in: container, debugDescription: "a host of \(host.utf8.count) bytes is no host")
        }
        self = endpoint
    }
}
