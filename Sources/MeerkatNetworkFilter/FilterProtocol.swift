import Foundation

/// The names the extension and the daemon know each other by. Each side
/// accepts only the other's signing identifier from the same team
/// (`XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier:)`): the
/// team alone would let the CLI, or any other binary the team signs, read
/// every user's traffic.
public enum FilterService {
    /// The system extension's bundle and signing identifier.
    public static let extensionIdentifier = "com.gkze.meerkat.network-filter"
    /// meerkatd's signing identifier (`DaemonService.label`, which
    /// MeerkatIPCTests checks this against).
    public static let daemonIdentifier = "com.gkze.meerkat.daemon"

    /// The app group the Mach service is named under. A sandboxed system
    /// extension may only listen on a name its app group prefixes, and on
    /// macOS a group is the team identifier and a name.
    public static func appGroup(team: String) -> String { "\(team).com.gkze.meerkat" }

    /// The extension's Mach service (`NEMachServiceName` in its Info.plist):
    /// in the system domain, so a per-user daemon can reach it, where a root
    /// extension could not reliably reach the daemon's.
    public static func machServiceName(team: String) -> String { "\(appGroup(team: team)).network-filter" }
}

/// The daemon's one request: the extension's totals now. `wantsHosts` says
/// whether a rule observes `network.flows`; the extension keeps a host table
/// only while some daemon has said so recently.
public struct FilterRequest: Codable, Sendable, Equatable {
    public let build: String
    public let wantsHosts: Bool

    public init(build: String, wantsHosts: Bool) {
        self.build = build
        self.wantsHosts = wantsHosts
    }
}

/// The extension's totals since it started, under an `instance` identifier
/// that changes when it restarts, so a reader never subtracts across two
/// lifetimes.
public struct FilterSnapshot: Codable, Sendable, Equatable {
    public struct Process: Codable, Sendable, Equatable {
        public let process: ProcessKey
        public let totals: ByteTotals
    }

    public struct Host: Codable, Sendable, Equatable {
        public let key: HostKey
        public let totals: ByteTotals
    }

    public let instance: UUID
    public let build: String
    public let processes: [Process]
    public let hosts: [Host]
    public let counters: LedgerCounters
    public let openFlows: Int

    public init(instance: UUID, build: String, snapshot: FlowLedger.Snapshot, openFlows: Int) {
        self.instance = instance
        self.build = build
        // Sorted, so equal states encode equally.
        processes = snapshot.processes.map { Process(process: $0.key, totals: $0.value) }
            .sorted { ($0.process.pid, $0.process.version) < ($1.process.pid, $1.process.version) }
        hosts = snapshot.hosts.map { Host(key: $0.key, totals: $0.value) }
            .sorted {
                ($0.key.process.pid, $0.key.remote.host, $0.key.remote.port)
                    < ($1.key.process.pid, $1.key.remote.host, $1.key.remote.port)
            }
        counters = snapshot.counters
        self.openFlows = openFlows
    }

    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case tooManyProcesses(Int)
        case tooManyHosts(Int)
        case duplicateProcess
        case duplicateHost
        case openFlows(Int)
        case otherBuild(extension: String, daemon: String)

        public var description: String {
            switch self {
            case .tooManyProcesses(let count): "the network filter reported \(count) processes, more than it can hold"
            case .tooManyHosts(let count): "the network filter reported \(count) endpoints, more than it can hold"
            case .duplicateProcess: "the network filter reported a process twice"
            case .duplicateHost: "the network filter reported an endpoint twice"
            case .openFlows(let count): "the network filter reported \(count) open flows, more than it can hold"
            case .otherBuild(let filter, let daemon):
                "the network filter is build \(filter) and meerkatd build \(daemon); turn the filter off and on again in Meerkat › Settings"
            }
        }
    }

    /// The checks the decoded value needs beyond each key's own: sizes within
    /// what the extension can hold, no key twice, and the daemon's build.
    /// The daemon calls this once, where the reply enters.
    public func validated(limits: FlowLedger.Limits = .standard, build daemonBuild: String) throws(Invalid) -> Self {
        guard build == daemonBuild else { throw .otherBuild(extension: build, daemon: daemonBuild) }
        guard processes.count <= limits.processes else { throw .tooManyProcesses(processes.count) }
        guard hosts.count <= limits.hosts else { throw .tooManyHosts(hosts.count) }
        guard (0...limits.flows).contains(openFlows) else { throw .openFlows(openFlows) }
        guard Set(processes.map(\.process)).count == processes.count else { throw .duplicateProcess }
        guard Set(hosts.map(\.key)).count == hosts.count else { throw .duplicateHost }
        return self
    }
}
