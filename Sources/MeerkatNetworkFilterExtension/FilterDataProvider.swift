import Foundation
import MeerkatNetworkFilter
import Network
import NetworkExtension
import os

/// The content filter: allows every flow and counts it. Everything that
/// decides anything is MeerkatNetworkFilter's (`FlowPolicy`, `FlowLedger`);
/// this class only translates between NetworkExtension and it.
///
/// The Objective-C name is fixed, because the extension's Info.plist names
/// the class (`NEProviderClasses`) and must not depend on the module name.
@objc(MeerkatFilterDataProvider)
final class FilterDataProvider: NEFilterDataProvider {
    private let logger = Logger(subsystem: FilterService.extensionIdentifier, category: "provider")

    override func startFilter(completionHandler: @escaping ((any Error)?) -> Void) {
        // No rules and a default of filterData: every socket flow comes to
        // handleNewFlow, which allows it at once.
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(settings) { [logger] error in
            if let error { logger.error("applying the filter settings failed: \(error, privacy: .public)") }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stopping: \(reason.rawValue, privacy: .public)")
        completionHandler()
    }

    /// Called for every new flow, in the flow's path: no I/O, no lock, no
    /// throw. The verdict cannot be anything but allow (`NewFlowVerdict`).
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        Self.verdict(FlowPolicy.verdict(for: Self.kind(of: flow)))
    }

    override func handle(_ report: NEFilterReport) {
        guard let translated = Self.translate(report) else { return }
        FilterState.shared.record(translated)
    }

    static func verdict(_ verdict: NewFlowVerdict) -> NEFilterNewFlowVerdict {
        let allow = NEFilterNewFlowVerdict.allow()
        allow.shouldReport = true
        allow.statisticsReportFrequency =
            switch verdict.statistics {
            case .low: .low
            case .medium: .medium
            case .high: .high
            }
        return allow
    }

    static func kind(of flow: NEFilterFlow) -> FlowKind {
        switch (flow as? NEFilterSocketFlow)?.socketProtocol {
        case IPPROTO_TCP: .tcp
        case IPPROTO_UDP: .udp
        default: .other
        }
    }

    /// The report as the ledger reads it, or nil for an event it does not
    /// count (a data decision, which this filter never asks for) or a report
    /// with no flow.
    static func translate(_ report: NEFilterReport) -> FlowReport? {
        guard let flow = report.flow else { return nil }
        let event: FlowReport.Event
        switch report.event {
        case .newFlow: event = .opened
        case .statistics: event = .statistics
        case .flowClosed: event = .closed
        default: return nil
        }
        let socket = flow as? NEFilterSocketFlow
        return FlowReport(
            flow: flow.identifier, event: event,
            process: flow.sourceAppAuditToken.flatMap(ProcessKey.init(auditToken:)),
            remote: socket.flatMap(remote(of:)),
            bytesIn: UInt64(clamping: report.bytesInboundCount),
            bytesOut: UInt64(clamping: report.bytesOutboundCount))
    }

    /// The name the app connected to where macOS knows it, else the address.
    private static func remote(of flow: NEFilterSocketFlow) -> RemoteEndpoint? {
        guard let endpoint = flow.remoteFlowEndpoint else { return nil }
        let transport: RemoteEndpoint.Transport =
            switch flow.socketProtocol {
            case IPPROTO_TCP: .tcp
            case IPPROTO_UDP: .udp
            default: .other
            }
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        if let name = flow.remoteHostname, !name.isEmpty {
            return RemoteEndpoint(host: name, port: port.rawValue, transport: transport)
        }
        let address: String
        switch host {
        case .name(let name, _): address = name
        case .ipv4(let ipv4): address = "\(ipv4)"
        case .ipv6(let ipv6): address = "\(ipv6)"
        @unknown default: return nil
        }
        return RemoteEndpoint(host: address, port: port.rawValue, transport: transport)
    }
}
