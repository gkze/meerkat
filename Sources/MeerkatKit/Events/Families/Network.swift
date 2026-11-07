import Dispatch
import Foundation
import Network
import Synchronization
import SystemConfiguration

// MARK: - network.path

public struct NetworkPathPayload: EventPayload, Equatable {
    public enum Status: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        /// Usable for traffic.
        case satisfied
        /// Not usable, for example offline or with no route.
        case unsatisfied
        /// Not usable now, but connecting (for example dial-on-demand or a
        /// VPN on demand) could make it usable.
        case requiresConnection
    }

    public enum InterfaceType: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case wifi, wiredEthernet, cellular, loopback
        /// Anything else, including VPN tunnels and types this version does
        /// not name.
        case other
    }

    public struct Interface: Codable, Sendable, Equatable, SchemaDescribed {
        public let name: String
        public let type: InterfaceType

        public static var schema: TypeSchema {
            .named(
                "NetworkPathInterface",
                ObjectSchema([
                    .field("name", String.self, doc: "BSD interface name, such as en0 or utun4."),
                    .field("type", InterfaceType.self),
                ]))
        }
    }

    public let status: Status
    /// In the system's order of preference.
    public let interfaces: [Interface]
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let supportsDNS: Bool

    public static var schema: TypeSchema {
        .named(
            "NetworkPath",
            ObjectSchema([
                .field("status", Status.self),
                .field(
                    "interfaces", [Interface].self, doc: "Interfaces the default path can use, most preferred first."),
                .field("isExpensive", Bool.self, doc: "Cellular or a personal hotspot."),
                .field("isConstrained", Bool.self, doc: "Low Data Mode is on for the path."),
                .field("supportsIPv4", Bool.self),
                .field("supportsIPv6", Bool.self),
                .field("supportsDNS", Bool.self),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                status: .satisfied,
                interfaces: [Interface(name: "en0", type: .wifi), Interface(name: "utun4", type: .other)],
                isExpensive: false, isConstrained: false, supportsIPv4: true, supportsIPv6: false, supportsDNS: true),
            Self(
                status: .unsatisfied, interfaces: [], isExpensive: false, isConstrained: false,
                supportsIPv4: false, supportsIPv6: false, supportsDNS: false),
        ]
    }
}

extension NetworkPathPayload {
    /// Nil for a status this version does not know, which has no honest
    /// mapping onto the three above.
    init?(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = .satisfied
        case .unsatisfied: status = .unsatisfied
        case .requiresConnection: status = .requiresConnection
        @unknown default: return nil
        }
        var interfaces: [Interface] = []
        for interface in path.availableInterfaces {
            let type: InterfaceType
            switch interface.type {
            case .wifi: type = .wifi
            case .wiredEthernet: type = .wiredEthernet
            case .cellular: type = .cellular
            case .loopback: type = .loopback
            case .other: type = .other
            @unknown default: type = .other
            }
            // The path lists an interface once per address family; the
            // payload carries only name and type, so repeats say nothing.
            let entry = Interface(name: interface.name, type: type)
            if !interfaces.contains(entry) { interfaces.append(entry) }
        }
        self.interfaces = interfaces
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
    }
}

public enum NetworkPathEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "network.path",
        "Whether the default network path is usable, and over which interfaces, changed. The current path is delivered first. Wi-Fi network names and addresses are not reported (see network.configuration).",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source: "NWPathMonitor"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<NetworkPathPayload>
    ) throws -> any EventSource {
        PathMonitorSource(emit: emit)
    }
}

/// `NWPathMonitor` delivers the current path right after `start` and then
/// every update, on a private serial queue. `stop` cancels on that queue, so
/// nothing is emitted after it returns.
final class PathMonitorSource: EventSource {
    private let queue = DispatchQueue(label: "com.gkze.meerkat.network-path", qos: .utility)
    private let reporter: StateReporter<NetworkPathPayload>
    private let monitor = Mutex<NWPathMonitor?>(nil)

    init(emit: Emitter<NetworkPathPayload>) {
        reporter = StateReporter(emit)
    }

    func start() throws {
        // A monitor cannot be restarted after `cancel`, so each start makes one.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        self.monitor.withLock { $0 = monitor }
        monitor.start(queue: queue)
    }

    func stop() {
        queue.sync { monitor.withLock { $0.take() }?.cancel() }
    }

    /// Runs on `queue`.
    private func update(_ path: NWPath) {
        // Stopped: an update queued before `cancel` must not be emitted.
        guard monitor.withLock({ $0 != nil }) else { return }
        reporter.report { NetworkPathPayload(path) }
    }
}

/// The interface a dynamic store key names, for keys of the form
/// State:/Network/Interface/<name>/<entity> (SCSchemaDefinitions.h).
private func interfaceName(inKey key: String, entitySuffix suffix: String) -> String? {
    let prefix = "State:/Network/Interface/"
    guard key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
    return String(key.dropFirst(prefix.count).dropLast(suffix.count))
}

// MARK: - network.configuration

public struct NetworkConfigurationPayload: EventPayload, Equatable {
    public struct Address: Codable, Sendable, Equatable, SchemaDescribed {
        public let interface: String
        public let address: String

        public static var schema: TypeSchema {
            .named(
                "NetworkInterfaceAddress",
                ObjectSchema([
                    .field("interface", String.self, doc: "BSD interface name, such as en0."),
                    .field("address", String.self),
                ]))
        }
    }

    public struct Proxy: Codable, Sendable, Equatable, SchemaDescribed {
        public let host: String
        public let port: Int?

        public static var schema: TypeSchema {
            .named(
                "NetworkProxy",
                ObjectSchema([
                    .field("host", String.self),
                    .optional("port", Int.self),
                ]))
        }
    }

    public struct Proxies: Codable, Sendable, Equatable, SchemaDescribed {
        public let http: Proxy?
        public let https: Proxy?
        public let socks: Proxy?
        public let autoConfigURL: String?
        public let exceptions: [String]

        public static let none = Proxies(http: nil, https: nil, socks: nil, autoConfigURL: nil, exceptions: [])

        public static var schema: TypeSchema {
            .named(
                "NetworkProxies",
                ObjectSchema([
                    .optional("http", Proxy.self, doc: "Enabled HTTP proxy."),
                    .optional("https", Proxy.self, doc: "Enabled HTTPS proxy."),
                    .optional("socks", Proxy.self, doc: "Enabled SOCKS proxy."),
                    .optional("autoConfigURL", String.self, doc: "Enabled proxy auto-configuration (PAC) URL."),
                    .field("exceptions", [String].self, doc: "Hosts and domains that bypass the proxies."),
                ]))
        }
    }

    public let primaryInterface: String?
    public let primaryService: String?
    public let router: String?
    /// Ordered by interface name, then as the interface lists them.
    public let ipv4Addresses: [Address]
    public let ipv6Addresses: [Address]
    public let dnsServers: [String]
    public let searchDomains: [String]
    public let proxies: Proxies

    public static var schema: TypeSchema {
        .named(
            "NetworkConfiguration",
            ObjectSchema([
                .optional(
                    "primaryInterface", String.self,
                    doc:
                        "Interface of the primary IPv4 service, or of the primary IPv6 service when there is no IPv4 one; absent when offline."
                ),
                .optional("primaryService", String.self, doc: "Network service id of that primary service."),
                .optional("router", String.self, doc: "That primary service's router address."),
                .field(
                    "ipv4Addresses", [Address].self,
                    doc: "Every IPv4 address on every interface, including loopback and tunnels."),
                .field(
                    "ipv6Addresses", [Address].self,
                    doc: "Every IPv6 address on every interface, including link-local (fe80::) and temporary addresses."
                ),
                .field("dnsServers", [String].self, doc: "Default resolver addresses, in resolver order."),
                .field("searchDomains", [String].self, doc: "Default resolver search domains, in order."),
                .field("proxies", Proxies.self, doc: "The system proxy settings in effect."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                primaryInterface: "en0", primaryService: "D198631A-6C7B-4A19-95AC-DF7219E4DD30", router: "192.168.1.1",
                ipv4Addresses: [
                    Address(interface: "en0", address: "192.168.1.20"), Address(interface: "lo0", address: "127.0.0.1"),
                ],
                ipv6Addresses: [Address(interface: "en0", address: "fe80::1c2b:3d4e:5f60:7182")],
                dnsServers: ["192.168.1.1"], searchDomains: ["example.net"],
                proxies: Proxies(
                    http: Proxy(host: "proxy.example.net", port: 3128), https: nil, socks: nil,
                    autoConfigURL: nil, exceptions: ["*.local", "169.254/16"])),
            Self(
                primaryInterface: nil, primaryService: nil, router: nil,
                ipv4Addresses: [Address(interface: "lo0", address: "127.0.0.1")], ipv6Addresses: [],
                dnsServers: [], searchDomains: [], proxies: .none),
        ]
    }
}

extension NetworkConfigurationPayload.Proxies {
    /// Only enabled entries: a disabled proxy's host is often left set.
    init(_ entity: [String: Any]) {
        func proxy(_ enable: CFString, _ host: CFString, _ port: CFString) -> NetworkConfigurationPayload.Proxy? {
            guard (entity[enable as String] as? NSNumber)?.boolValue == true,
                let name = entity[host as String] as? String, !name.isEmpty
            else { return nil }
            return NetworkConfigurationPayload.Proxy(host: name, port: (entity[port as String] as? NSNumber)?.intValue)
        }
        http = proxy(kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort)
        https = proxy(kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort)
        socks = proxy(kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort)
        autoConfigURL =
            (entity[kSCPropNetProxiesProxyAutoConfigEnable as String] as? NSNumber)?.boolValue == true
            ? entity[kSCPropNetProxiesProxyAutoConfigURLString as String] as? String : nil
        exceptions = entity[kSCPropNetProxiesExceptionsList as String] as? [String] ?? []
    }
}

public enum NetworkConfigurationEvent: EventKind {
    static let ipv4Key =
        SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4) as String
    static let ipv6Key =
        SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6) as String
    static let dnsKey =
        SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetDNS) as String
    static let proxiesKey =
        SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetProxies) as String
    /// `State:/Network/Interface/[^/]+/IPv4` and `/IPv6`.
    static let interfaceIPv4Pattern =
        SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4)
        as String
    static let interfaceIPv6Pattern =
        SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv6)
        as String

    static let keys = [ipv4Key, ipv6Key, dnsKey, proxiesKey]
    static let patterns = [interfaceIPv4Pattern, interfaceIPv6Pattern]

    public static let descriptor = EventDescriptor(
        "network.configuration",
        "The primary interface, router, IPv4 or IPv6 addresses, default DNS configuration, or proxy settings changed. The current configuration is delivered first. Per-domain (scoped) resolvers and Wi-Fi network names are not reported (see network.wifi).",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source: "SCDynamicStore State:/Network/Global/{IPv4,IPv6,DNS,Proxies}, State:/Network/Interface/*/{IPv4,IPv6}"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<NetworkConfigurationPayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        return DynamicStoreKeySource(keys: keys, patterns: patterns) { store in
            reporter.report { read(store) }
        }
    }

    /// One `SCDynamicStoreCopyMultiple`, so the fields come from one
    /// consistent snapshot of the store. Nil when configd cannot be reached.
    static func read(_ store: SCDynamicStore) -> NetworkConfigurationPayload? {
        guard let values = SCDynamicStoreCopyMultiple(store, keys as CFArray, patterns as CFArray) as? [String: Any]
        else {
            return nil
        }
        return payload(from: values)
    }

    /// Pure translation from the store's values.
    static func payload(from values: [String: Any]) -> NetworkConfigurationPayload {
        func entity(_ key: String) -> [String: Any] { values[key] as? [String: Any] ?? [:] }
        let ipv4 = entity(ipv4Key)
        let ipv6 = entity(ipv6Key)
        let usesIPv4 = ipv4[kSCDynamicStorePropNetPrimaryInterface as String] != nil
        let primary = usesIPv4 ? ipv4 : ipv6
        let router = primary[(usesIPv4 ? kSCPropNetIPv4Router : kSCPropNetIPv6Router) as String] as? String
        let dns = entity(dnsKey)

        func addresses(_ suffix: String, _ property: CFString) -> [NetworkConfigurationPayload.Address] {
            var found: [NetworkConfigurationPayload.Address] = []
            for (key, value) in values {
                guard let name = interfaceName(inKey: key, entitySuffix: suffix) else { continue }
                let entity = value as? [String: Any] ?? [:]
                for address in entity[property as String] as? [String] ?? [] {
                    found.append(.init(interface: name, address: address))
                }
            }
            // Stable order; within an interface the store's order is kept.
            return found.enumerated()
                .sorted { ($0.element.interface, $0.offset) < ($1.element.interface, $1.offset) }
                .map(\.element)
        }

        return NetworkConfigurationPayload(
            primaryInterface: primary[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
            primaryService: primary[kSCDynamicStorePropNetPrimaryService as String] as? String,
            router: router,
            ipv4Addresses: addresses("/IPv4", kSCPropNetIPv4Addresses),
            ipv6Addresses: addresses("/IPv6", kSCPropNetIPv6Addresses),
            dnsServers: dns[kSCPropNetDNSServerAddresses as String] as? [String] ?? [],
            searchDomains: dns[kSCPropNetDNSSearchDomains as String] as? [String] ?? [],
            proxies: .init(entity(proxiesKey))
        )
    }
}

// MARK: - network.link

public struct NetworkLinkPayload: EventPayload, Equatable {
    public struct Link: Codable, Sendable, Equatable, SchemaDescribed {
        public let interface: String
        public let active: Bool

        public static var schema: TypeSchema {
            .named(
                "NetworkLink",
                ObjectSchema([
                    .field("interface", String.self, doc: "BSD interface name, such as en0."),
                    .field("active", Bool.self, doc: "Link up: a cable is connected, or Wi-Fi is associated."),
                ]))
        }
    }

    /// Ordered by interface name.
    public let links: [Link]

    public static var schema: TypeSchema {
        .named(
            "NetworkLinks",
            ObjectSchema([
                .field("links", [Link].self, doc: "Every interface that reports a link state, ordered by name.")
            ]))
    }

    public static var examples: [Self] {
        [Self(links: [Link(interface: "en0", active: true), Link(interface: "en5", active: false)]), Self(links: [])]
    }
}

public enum NetworkLinkEvent: EventKind {
    /// `State:/Network/Interface/[^/]+/Link`
    static let pattern =
        SCDynamicStoreKeyCreateNetworkInterfaceEntity(nil, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetLink)
        as String

    public static let descriptor = EventDescriptor(
        "network.link",
        "A network interface's link went up or down (a cable plugged in or pulled, Wi-Fi associating or dropping), or an interface with a link state appeared or went away. The current links are delivered first.",
        mechanism: .push, semantics: .state, loss: .coalesced,
        observation: .open,
        source: "SCDynamicStore State:/Network/Interface/*/Link"
    )

    public static func makeSource(
        _ parameters: NoParameters, environment: SourceEnvironment,
        emit: Emitter<NetworkLinkPayload>
    ) throws -> any EventSource {
        let reporter = StateReporter(emit)
        return DynamicStoreKeySource(keys: [], patterns: [pattern]) { store in
            reporter.report {
                guard let values = SCDynamicStoreCopyMultiple(store, nil, [pattern] as CFArray) as? [String: Any]
                else { return nil }
                return payload(from: values)
            }
        }
    }

    static func payload(from values: [String: Any]) -> NetworkLinkPayload {
        let links = values.compactMap { key, value -> NetworkLinkPayload.Link? in
            guard let name = interfaceName(inKey: key, entitySuffix: "/Link"),
                let active = ((value as? [String: Any])?[kSCPropNetLinkActive as String] as? NSNumber)?.boolValue
            else { return nil }
            return .init(interface: name, active: active)
        }
        return NetworkLinkPayload(
            links: links.sorted { $0.interface.localizedStandardCompare($1.interface) == .orderedAscending })
    }
}
