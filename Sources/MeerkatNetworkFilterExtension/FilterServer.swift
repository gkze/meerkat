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

    /// Starts the listener, trying again until it can. While macOS replaces
    /// the extension, the new process starts before the old one has let go
    /// of the service, and activating the listener then fails (EPERM, seen
    /// on macOS 27): without another try meerkatd could not read the totals
    /// until the extension next restarted. A bundle without the name never
    /// will, so that stops at once.
    static func serve() {
        serve(after: .seconds(0), backoff: .seconds(1))
    }

    private static func serve(after delay: DispatchTimeInterval, backoff: Duration) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            do {
                try start()
            } catch let error as Missing {
                logger.error("not serving totals: \(error, privacy: .public)")
            } catch {
                logger.error(
                    "not serving totals yet, trying again in \(backoff, privacy: .public): \(error, privacy: .public)")
                let seconds = Int(backoff.components.seconds)
                serve(after: .seconds(seconds), backoff: min(backoff * 2, retryLimit))
            }
        }
    }

    /// The longest wait between tries.
    static let retryLimit: Duration = .seconds(30)

    private static let heartbeat = Mutex<(any DispatchSourceTimer)?>(nil)

    /// One line a minute with what the provider received and what the ledger
    /// made of it, so a filter that counts nothing says why.
    static func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
            logger.info("\(ReportTally.shared.line, privacy: .public); \(FilterState.shared.summary, privacy: .public)")
        }
        timer.resume()
        heartbeat.withLock { $0 = timer }
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
