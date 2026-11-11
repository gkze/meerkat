import Foundation
import MeerkatNetworkFilter
import NetworkExtension
import Observation
import SystemExtensions

/// Where the network filter stands, from what the app can see: whether this
/// bundle carries it, whether macOS will install it from where the app is,
/// and the content filter's configuration (docs/design/network-filter.md).
enum NetworkFilterStatus: Equatable {
    /// Built without the provisioning profiles: no extension to install.
    case notInThisBuild
    /// macOS installs system extensions only from an app in /Applications.
    case needsApplications(current: String)
    case off
    /// Waiting for the user to allow the extension in System Settings.
    case awaitingApproval
    case on
    case failed(String)

    /// Decides from the app's own facts; `filterEnabled` is the saved
    /// content-filter configuration's state, nil when none is saved.
    static func of(bundled: Bool, appPath: String, filterEnabled: Bool?) -> NetworkFilterStatus {
        guard bundled else { return .notInThisBuild }
        guard appPath.hasPrefix("/Applications/") else { return .needsApplications(current: appPath) }
        return filterEnabled == true ? .on : .off
    }

    var summary: String {
        switch self {
        case .notInThisBuild: "Not part of this build"
        case .needsApplications: "Needs Meerkat in /Applications"
        case .off: "Off"
        case .awaitingApproval: "Waiting for your approval"
        case .on: "On"
        case .failed: "Could not change"
        }
    }

    var explanation: String {
        switch self {
        case .notInThisBuild:
            "This copy of Meerkat was built without the network filter's provisioning profiles."
        case .needsApplications(let current):
            "macOS installs Meerkat's network filter only from /Applications. Move Meerkat there from \(current), open it again, and turn the filter on."
        case .off:
            "Turn on to see which processes use the network, and how much, in rules (process.hot's network metrics, network.flows). The filter allows all traffic and reads none of it."
        case .awaitingApproval:
            "Allow Meerkat's extension in System Settings › General › Login Items & Extensions › Network Extensions, then allow the content filter when macOS asks."
        case .on:
            "Meerkat counts each process's network bytes, and each process's hosts while a rule observes network.flows."
        case .failed(let reason): reason
        }
    }
}

/// Installs and configures the network filter, the two steps only the app
/// can take: activating the system extension, and saving and enabling the
/// content filter that names it. Turning it off reverses both.
@MainActor @Observable
final class NetworkFilterSetup: NSObject {
    private(set) var status: NetworkFilterStatus
    private(set) var busy = false

    private var activationContinuation: CheckedContinuation<Void, any Error>?

    override init() {
        status = Self.bundled ? .off : .notInThisBuild
        super.init()
    }

    /// Whether this bundle carries the extension.
    static var bundled: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/SystemExtensions/\(FilterService.extensionIdentifier).systemextension"
            ).path)
    }

    func refresh() async {
        let manager = NEFilterManager.shared()
        let enabled: Bool? =
            (try? await manager.loadFromPreferences()).map {
                manager.providerConfiguration == nil ? nil : manager.isEnabled
            } ?? nil
        status = NetworkFilterStatus.of(bundled: Self.bundled, appPath: Bundle.main.bundlePath, filterEnabled: enabled)
    }

    func turnOn() async {
        await change {
            self.status = .awaitingApproval
            try await self.submit(
                .activationRequest(forExtensionWithIdentifier: FilterService.extensionIdentifier, queue: .main))
            let manager = NEFilterManager.shared()
            try await manager.loadFromPreferences()
            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterPackets = false
            configuration.filterDataProviderBundleIdentifier = FilterService.extensionIdentifier
            manager.providerConfiguration = configuration
            manager.localizedDescription = "Meerkat"
            manager.isEnabled = true
            try await manager.saveToPreferences()
        }
    }

    func turnOff() async {
        await change {
            let manager = NEFilterManager.shared()
            try await manager.loadFromPreferences()
            if manager.providerConfiguration != nil { try await manager.removeFromPreferences() }
            try await self.submit(
                .deactivationRequest(forExtensionWithIdentifier: FilterService.extensionIdentifier, queue: .main))
        }
    }

    private func change(_ work: @escaping @MainActor () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            await refresh()
        } catch {
            status = .failed("\(error.localizedDescription)")
        }
    }

    private func submit(_ request: OSSystemExtensionRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            activationContinuation = continuation
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        activationContinuation?.resume(with: result)
        activationContinuation = nil
    }
}

extension NetworkFilterSetup: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // A new build of Meerkat replaces its own earlier extension.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = .awaitingApproval }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in self.finish(.success(())) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
