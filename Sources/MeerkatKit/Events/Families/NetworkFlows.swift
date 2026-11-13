import Foundation
import MeerkatNetworkFilter
import Synchronization

// MARK: - network.flows

/// One process's traffic to one remote endpoint over a window.
public struct NetworkFlow: Codable, Sendable, Equatable, SchemaDescribed {
    public enum Transport: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case tcp, udp, other
    }

    public let pid: Int32
    public let uid: UInt32
    /// The process's name and path when it was still running at the window's
    /// end; absent once it exited.
    public let name: String?
    public let path: String?
    /// The name the process connected to where macOS knows it, otherwise the
    /// remote address.
    public let host: String
    public let port: Int
    public let transport: Transport
    public let receivedMB: Double
    public let sentMB: Double

    public static var schema: TypeSchema {
        .named(
            "NetworkFlow",
            ObjectSchema([
                .field("pid", Int32.self),
                .field("uid", UInt32.self),
                .optional("name", String.self, doc: "Absent once the process exited."),
                .optional("path", String.self),
                .field(
                    "host", String.self,
                    doc: "The name the process connected to where macOS knows it, otherwise the remote address."),
                .field("port", Int.self),
                .field("transport", Transport.self),
                .field("receivedMB", Double.self),
                .field("sentMB", Double.self),
            ]))
    }

    static let example = NetworkFlow(
        pid: 4_211, uid: 501, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari",
        host: "example.com", port: 443, transport: .tcp, receivedMB: 12.5, sentMB: 0.3)
}

public struct NetworkFlowsPayload: RuleViewedPayload, Equatable {
    /// At most this many flows per window, the largest first.
    public static let maximumFlows = 200

    public let windowSeconds: Double
    public let flows: [NetworkFlow]
    /// Flows left out beyond `maximumFlows`, or by the endpoint table's
    /// eviction under load: the window had more traffic than listed.
    public let omitted: Int

    /// Only the processes the rule may see; nothing when none of them moved
    /// data.
    public func viewed(by view: RuleView) -> Self? {
        guard let user = view.user else { return self }
        let visible = flows.filter { $0.uid == user }
        guard !visible.isEmpty else { return nil }
        return NetworkFlowsPayload(windowSeconds: windowSeconds, flows: visible, omitted: omitted)
    }

    public static var schema: TypeSchema {
        .named(
            "NetworkFlows",
            ObjectSchema([
                .field("windowSeconds", Double.self),
                .field("flows", [NetworkFlow].self, doc: "Largest first, at most 200."),
                .field("omitted", Int.self, doc: "Flows the window had beyond those listed."),
            ]))
    }

    public static var examples: [Self] { [Self(windowSeconds: 5, flows: [.example], omitted: 0)] }

    /// The flows in a delta, named from `names` (pid to name and path),
    /// largest first and capped.
    static func make(
        from delta: UsageDelta, windowSeconds: Double, names: [Int32: (name: String, path: String?)]
    ) -> NetworkFlowsPayload {
        let flows = delta.hosts.map { key, moved in
            NetworkFlow(
                pid: key.process.pid, uid: key.process.uid, name: names[key.process.pid]?.name,
                path: names[key.process.pid]?.path, host: key.remote.host, port: Int(key.remote.port),
                transport: NetworkFlow.Transport(rawValue: key.remote.transport.rawValue) ?? .other,
                receivedMB: Double(moved.bytesIn) / 1_000_000, sentMB: Double(moved.bytesOut) / 1_000_000)
        }
        .sorted {
            ($0.receivedMB + $0.sentMB, $1.host, $1.pid) > ($1.receivedMB + $1.sentMB, $0.host, $0.pid)
        }
        return NetworkFlowsPayload(
            windowSeconds: windowSeconds, flows: Array(flows.prefix(maximumFlows)),
            omitted: max(0, flows.count - maximumFlows) + delta.restarted)
    }
}

extension IntervalParameters: NetworkFilterParameters where Defaults == NetworkFlowsEvent {
    public var needsNetworkFilter: Bool { true }
}

public enum NetworkFlowsEvent: EventKind, IntervalParameterDefaults {
    public static let defaultInterval = 5.0
    public static let intervalRange = 5.0...3600.0

    public static let descriptor = EventDescriptor(
        "network.flows",
        "Each process's bytes received and sent per remote host over the last interval, largest first, every user's processes included. Needs the network filter (Meerkat › Settings › Network); without it a subscription is refused. The first window after subscribing, or after the filter restarts, is not reported. No contents are read.",
        mechanism: .poll, semantics: .occurrence, loss: .lossy,
        observation: .named,
        source: "the network filter (NetworkExtension content filter statistics)"
    )

    public static func makeSource(
        _ parameters: IntervalParameters<NetworkFlowsEvent>, environment: SourceEnvironment,
        emit: Emitter<NetworkFlowsPayload>
    ) throws -> any EventSource {
        let reader = environment.networkFilter
        let state = Mutex<(differ: UsageDiffer, last: ContinuousClock.Instant?)>((UsageDiffer(), nil))
        do {
            let first = try reader.totals(wantsHosts: true)
            state.withLock { state in
                _ = state.differ.next(first)
                state.last = .now
            }
        } catch {
            throw EventError.sourceUnavailable("network.flows: \(error)")
        }
        return PollingSource(
            label: "network-flows", interval: parameters.interval, fireImmediately: false, failingThrough: emit
        ) {
            let snapshot = try reader.totals(wantsHosts: true)
            let now = ContinuousClock.now
            let (delta, window) = state.withLock { state -> (UsageDelta, Duration?) in
                defer { state.last = now }
                return (state.differ.next(snapshot), state.last.map { now - $0 })
            }
            guard !delta.baseline, let window, !delta.hosts.isEmpty else { return }
            // Names from the shared process snapshot; a process that exited
            // before it is listed by pid alone.
            var names: [Int32: (name: String, path: String?)] = [:]
            if let processes = try? environment.processSnapshots.current(maxAge: parameters.interval / 2) {
                for counters in processes.counters.values { names[counters.pid] = (counters.name, counters.path) }
            }
            let seconds = Double(window.components.seconds) + Double(window.components.attoseconds) / 1e18
            emit(NetworkFlowsPayload.make(from: delta, windowSeconds: seconds, names: names))
        }
    }
}
