import Foundation
import MeerkatIPC
import Security
import Synchronization

/// The bearer token every MCP HTTP request must carry (docs/design/mcp.md,
/// "Transport: Streamable HTTP").
///
/// XPC needs no secret: the listener checks the peer's code signature. A TCP
/// port has no such check, and any process can connect to the loopback
/// address, sandboxed apps included, so this token is what stands in for it.
/// It lives in the login Keychain, made the first time it is needed; the
/// daemon keeps a copy in memory, so a request never reaches the Keychain.
/// `meerkat mcp http` gets it over XPC, from a peer the daemon already trusts.
final class MCPHTTPToken: Sendable {
    /// Where the token is kept. A protocol so tests need no Keychain.
    protocol Store: Sendable {
        func read() throws -> String?
        func write(_ token: String) throws
    }

    private let store: any Store
    private let cached = Mutex<String?>(nil)

    init(store: any Store = KeychainStore()) {
        self.store = store
    }

    /// The token, read from the store, or made and stored when there is none.
    /// Under the lock, so the cache and the store never hold different tokens.
    func current() throws -> String {
        try cached.withLock { cached in
            if let cached { return cached }
            let token: String
            if let stored = try store.read() {
                token = stored
            } else {
                token = try Self.make()
                try store.write(token)
            }
            cached = token
            return token
        }
    }

    /// Replaces the token. Clients holding the old one are refused from the
    /// next request.
    func rotate() throws -> String {
        try cached.withLock { cached in
            let token = try Self.make()
            try store.write(token)
            cached = token
            return token
        }
    }

    /// Whether `header` is `Bearer <token>` for the token in force (the scheme
    /// in any case), compared in time that does not depend on where the
    /// tokens differ. Before `current()` has loaded a token, nothing matches.
    func authorizes(_ header: String?) -> Bool {
        guard let header, let token = cached.withLock({ $0 }) else { return false }
        let scheme = Array("bearer ".utf8)
        let presented = Array(header.utf8)
        let expected = Array(token.utf8)
        guard presented.count == scheme.count + expected.count,
            String(decoding: presented.prefix(scheme.count), as: UTF8.self).lowercased().utf8.elementsEqual(scheme)
        else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(presented.dropFirst(scheme.count), expected) { difference |= a ^ b }
        return difference == 0
    }

    struct RandomFailure: Error, CustomStringConvertible {
        let status: Int32
        var description: String { "cannot make an MCP HTTP token: SecRandomCopyBytes failed (\(status))" }
    }

    /// 32 random bytes, base64url without padding: 43 characters a header
    /// carries as they are.
    static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw RandomFailure(status: status) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// One generic password in the login Keychain, which only meerkatd
    /// reads without asking: its access list names the daemon that made it.
    struct KeychainStore: Store {
        static let service = DaemonService.label + ".mcp-http"
        static let account = "bearer"

        struct Failure: Error, CustomStringConvertible {
            let operation: String
            let status: OSStatus
            var description: String {
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "cannot \(operation) the MCP HTTP token in the Keychain: \(message)"
            }
        }

        private var query: [CFString: Any] {
            [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: Self.account]
        }

        func read() throws -> String? {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(
                (query.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 }) as CFDictionary,
                &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
                else { return nil }
                return token
            case errSecItemNotFound: return nil
            default: throw Failure(operation: "read", status: status)
            }
        }

        func write(_ token: String) throws {
            let data = Data(token.utf8)
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            switch updated {
            case errSecSuccess: return
            case errSecItemNotFound:
                let attributes = query.merging([
                    kSecValueData: data, kSecAttrLabel: "Meerkat MCP HTTP token",
                ]) { $1 }
                let added = SecItemAdd(attributes as CFDictionary, nil)
                guard added == errSecSuccess else { throw Failure(operation: "store", status: added) }
            default: throw Failure(operation: "update", status: updated)
            }
        }
    }
}
