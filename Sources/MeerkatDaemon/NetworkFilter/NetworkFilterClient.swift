import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatNetworkFilter
import Security
import Synchronization
import XPC
import os

/// meerkatd's side of the network filter: asks the system extension for its
/// totals over its Mach service, accepting only the team's binary signed as
/// the extension (docs/design/network-filter.md).
///
/// Every read is bounded: a reply that takes longer than `timeout` fails the
/// read, and a failure keeps the client from trying again for `backoff`, so
/// an absent or wedged extension costs the samplers a second at most, then
/// nothing.
final class NetworkFilterClient: NetworkFilterReading {
    private let service: String?
    private let build: String
    private let timeout: Duration
    private let backoff: Duration
    private let state = Mutex<(session: XPCSession?, retryAfter: ContinuousClock.Instant?)>((nil, nil))
    private let logger = Logger(subsystem: DaemonService.label, category: "network-filter")

    /// `team` is the team that signed this process; without one (an
    /// unsigned build) the extension, which accepts only the team's daemon,
    /// cannot be reached.
    init(
        team: String? = NetworkFilterClient.signingTeam(),
        build: String = FilterService.build(info: Bundle.main.infoDictionary),
        timeout: Duration = .seconds(1), backoff: Duration = .seconds(30)
    ) {
        service = team.map(FilterService.machServiceName(team:))
        self.build = build
        self.timeout = timeout
        self.backoff = backoff
    }

    func totals(wantsHosts: Bool) throws(NetworkFilterUnavailable) -> FilterSnapshot {
        guard let service else {
            throw NetworkFilterUnavailable("meerkatd is not signed by a team, so it cannot reach the network filter")
        }
        let session: XPCSession
        do {
            session = try connect(service)
        } catch {
            throw .off
        }
        let reply: FilterReply
        do {
            reply = try exchange(FilterRequest(build: build, wantsHosts: wantsHosts), on: session)
        } catch {
            fail(session, because: error)
            throw .off
        }
        switch reply {
        case .refused(let reason):
            throw NetworkFilterUnavailable(reason)
        case .snapshot(let snapshot):
            do {
                return try snapshot.validated(build: build)
            } catch {
                throw NetworkFilterUnavailable(error.description)
            }
        }
    }

    private func connect(_ service: String) throws -> XPCSession {
        try state.withLock { state in
            if let retryAfter = state.retryAfter, ContinuousClock.now < retryAfter { throw Backoff() }
            if let session = state.session { return session }
            let session = try XPCSession(
                machService: service,
                requirement: .isFromSameTeam(andMatchesSigningIdentifier: FilterService.extensionIdentifier))
            state.session = session
            return session
        }
    }

    /// One request and its reply, waited for at most `timeout`.
    private func exchange(_ request: FilterRequest, on session: XPCSession) throws -> FilterReply {
        let outcome = Mutex<Result<FilterReply, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        try session.send(request) { (result: Result<XPCReceivedMessage, XPCRichError>) in
            outcome.withLock { outcome in
                outcome = Result {
                    // Decoded here, so a transport failure and a reply this
                    // build cannot read stay distinct in the log.
                    try result.get().decode(as: FilterReply.self)
                }
            }
            done.signal()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        guard done.wait(timeout: .now() + seconds) == .success, let result = outcome.withLock({ $0 }) else {
            throw TimedOut()
        }
        return try result.get()
    }

    private func fail(_ session: XPCSession, because error: any Error) {
        logger.info("network filter unavailable: \(String(describing: error), privacy: .public)")
        session.cancel(reason: "the network filter did not answer")
        state.withLock { state in
            state.session = nil
            state.retryAfter = ContinuousClock.now + backoff
        }
    }

    private struct Backoff: Error {}
    private struct TimedOut: Error {}

    /// The team identifier in this process's code signature, or nil for
    /// ad-hoc and unsigned code.
    static func signingTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
