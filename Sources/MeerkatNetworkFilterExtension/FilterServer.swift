import Foundation
import MeerkatNetworkFilter
import Synchronization
import XPC
import os

extension FilterState {
    /// One per extension process: the provider instance NetworkExtension makes
    /// and the XPC listener both reach it.
    static let shared = FilterState(build: FilterService.build(info: Bundle.main.infoDictionary))
}

/// Answers meerkatd's requests on the Mach service the Info.plist names,
/// accepting only meerkatd itself: the team's binary signed as
/// `FilterService.daemonIdentifier`. A session never pushes; each request
/// gets its one reply.
enum FilterServer {
    private static let listener = Mutex<XPCListener?>(nil)
    private static let logger = Logger(subsystem: FilterService.extensionIdentifier, category: "server")

    static func start() throws {
        // The bundler writes the name (`NetworkExtension.NEMachServiceName`)
        // from the signing team; a bundle without it cannot be reached.
        guard
            let networkExtension = Bundle.main.infoDictionary?["NetworkExtension"] as? [String: Any],
            let service = networkExtension["NEMachServiceName"] as? String
        else {
            throw Missing()
        }
        let requirement = XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier: FilterService.daemonIdentifier)
        let listener = try XPCListener(service: service, requirement: requirement) { request in
            request.accept { _ in Session() }
        }
        Self.listener.withLock { $0 = listener }
        logger.info("listening on \(service, privacy: .public)")
    }

    struct Missing: Error, CustomStringConvertible {
        var description: String { "the extension's Info.plist names no NEMachServiceName" }
    }

    private struct Session: XPCPeerHandler {
        func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
            do {
                return FilterState.shared.reply(to: try message.decode(as: FilterRequest.self))
            } catch {
                return FilterReply.refused("the request did not decode: \(error)")
            }
        }

        func handleCancellation(error _: XPCRichError) {}
    }
}
