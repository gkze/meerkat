import Foundation
import MeerkatIPC
import MeerkatKit
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
    /// On, but not answering meerkatd after Meerkat restarted its session
    /// once (`ListenerRepair`).
    case notAnswering
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
        case .notAnswering: "On, but not answering"
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
        case .notAnswering:
            "The filter is on, but meerkatd cannot read it. This can happen when macOS replaces it with a newer build. Meerkat restarted it once, and it still does not answer. Turn it off and on again here; if that does not help, restart the Mac."
        case .failed(let reason): reason
        }
    }
}

/// The system-extension request `turnOn` or `turnOff` waits on. The
/// launch-time upgrade shares the delegate, so each callback is matched to
/// its request: an upgrade's result must not end Turn Off, and Turn Off's
/// must not be dropped.
struct ExtensionRequestWait {
    private var awaited: (request: ObjectIdentifier, continuation: CheckedContinuation<Void, any Error>)?

    mutating func begin(_ request: ObjectIdentifier, _ continuation: CheckedContinuation<Void, any Error>) {
        awaited = (request, continuation)
    }

    /// Resumes the wait when `request` is the one awaited; a result for any
    /// other is left to macOS's log. Returns whether it resumed.
    @discardableResult
    mutating func finish(_ request: ObjectIdentifier, _ result: Result<Void, any Error>) -> Bool {
        guard let awaited, awaited.request == request else { return false }
        self.awaited = nil
        awaited.continuation.resume(with: result)
        return true
    }
}

/// What to do about a filter that is on and does not answer meerkatd,
/// decided from successive checks (docs/design/network-filter.md,
/// "Failure"). When macOS replaces the extension in place, the new launchd
/// job can come up without the Mach service the Info.plist names (seen on
/// macOS 27: 18→21, 30→17), and the extension's listener then never
/// activates. Ending and restarting the content filter's session once may
/// bring the job back with its service; if it does not, the user is told
/// what does (Turn Off and On, or a restart).
///
/// `grace` covers a healthy swap: the extension retries its listener for up
/// to 30 s, and meerkatd waits 30 s after a failed read before asking again.
struct ListenerRepair {
    enum Step: Equatable {
        /// Nothing to watch: the filter answers, is off, or meerkatd can
        /// never reach it.
        case done
        case wait
        /// Restart the content filter's session.
        case restart
        /// Restarted once, still silent: tell the user.
        case giveUp
    }

    static let grace: Duration = .seconds(90)

    private var silentSince: ContinuousClock.Instant?
    /// At most once per launch: a restart ends the connections attached to
    /// the filter's session, so it is not repeated on a filter it did not
    /// fix.
    private(set) var restarted = false
    private(set) var gaveUp = false

    /// `health` is meerkatd's view, nil when meerkatd did not answer.
    mutating func next(filterOn: Bool, health: NetworkFilterHealth?, at now: ContinuousClock.Instant) -> Step {
        guard filterOn else { return settled() }
        guard let health else { return .wait }
        switch health.cause {
        case nil, .unreachable:
            return settled()
        case .refused:
            // Another build's extension, which the launch-time upgrade
            // replaces: answering, so not this failure.
            silentSince = nil
            return .wait
        case .notAnswering:
            guard let since = silentSince else {
                silentSince = now
                return .wait
            }
            guard now - since >= Self.grace else { return .wait }
            if restarted {
                gaveUp = true
                return .giveUp
            }
            restarted = true
            silentSince = now
            return .restart
        }
    }

    /// Something replaced what was judged: the user turned the filter off or
    /// on, or macOS finished installing the bundled extension. Judge it
    /// afresh, but without a second restart this launch: Turn Off and On has
    /// just done more than a restart would, and a new extension gets the
    /// restart only if the old one did not use it.
    mutating func judgeAfresh() {
        silentSince = nil
        gaveUp = false
    }

    private mutating func settled() -> Step {
        silentSince = nil
        gaveUp = false
        return .done
    }
}

/// Installs and configures the network filter, the two steps only the app
/// can take: activating the system extension, and saving and enabling the
/// content filter that names it. Turning it off reverses both.
@MainActor @Observable
final class NetworkFilterSetup: NSObject {
    private(set) var status: NetworkFilterStatus
    private(set) var busy = false

    private var awaited = ExtensionRequestWait()
    private var upgradeRequested = false
    /// The launch-time upgrade until macOS says it is done. Until then the
    /// filter that answers may be the old extension, so its completion
    /// starts a fresh watch of the new one.
    private var pendingUpgrade: OSSystemExtensionRequest?
    private var repair = ListenerRepair()
    private var watching: Task<Void, Never>?
    /// meerkatd's view of the filter; nil when meerkatd does not answer.
    private let health: @Sendable () async -> NetworkFilterHealth?

    static let checkInterval: Duration = .seconds(15)
    /// Past a restart's two graces with room to spare. A watch still going
    /// then is waiting on something else (meerkatd down, an upgrade macOS
    /// has not applied), which a session restart would not fix.
    static let watchLimit: Duration = .seconds(600)

    /// The launch-time upgrade: an activation request no caller awaits. Its
    /// completion starts a fresh watch (`finish`); a failure is logged by
    /// macOS and leaves the running extension.
    private static func upgrade(delegate: any OSSystemExtensionRequestDelegate) -> OSSystemExtensionRequest {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FilterService.extensionIdentifier, queue: .main)
        request.delegate = delegate
        return request
    }

    init(health: @escaping @Sendable () async -> NetworkFilterHealth?) {
        self.health = health
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
        if status == .on, repair.gaveUp { status = .notAnswering }
        // A newer Meerkat carries a newer extension, which macOS installs only
        // when the app asks again: with the filter on, ask once per launch.
        // The same version is a no-op; a newer one replaces the old without a
        // prompt (`actionForReplacingExtension`).
        if status == .on, !upgradeRequested {
            upgradeRequested = true
            let request = Self.upgrade(delegate: self)
            pendingUpgrade = request
            OSSystemExtensionManager.shared.submitRequest(request)
        }
        startWatching()
    }

    /// Watches while the filter is on, or reported silent: a check that
    /// then finds it answering clears the report (`ListenerRepair` keeps the
    /// one restart per launch either way).
    private func startWatching() {
        guard status == .on || status == .notAnswering, watching == nil else { return }
        watching = Task { [weak self] in await self?.watch() }
    }

    /// Checks until the filter answers meerkatd, restarting its session once
    /// if it stays silent (`ListenerRepair`). Started by `refresh` whenever
    /// the filter is on or reported silent (at launch, after Turn On, on
    /// opening Settings) and again when the launch-time upgrade completes,
    /// which is when macOS swaps the extension.
    private func watch() async {
        defer { watching = nil }
        let deadline = ContinuousClock.now + Self.watchLimit
        while !Task.isCancelled, ContinuousClock.now < deadline {
            let manager = NEFilterManager.shared()
            let loaded = (try? await manager.loadFromPreferences()) != nil
            let on = loaded && manager.providerConfiguration != nil && manager.isEnabled
            let step = repair.next(filterOn: on, health: await health(), at: .now)
            switch step {
            case .done:
                if status == .notAnswering { status = on ? .on : .off }
                return
            case .wait:
                break
            case .restart:
                do {
                    try await restartSession()
                } catch {
                    status = .failed("Could not restart the network filter: \(error.localizedDescription)")
                    return
                }
            case .giveUp:
                status = .notAnswering
                return
            }
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    /// Ends the content filter's session and starts a new one, without
    /// removing the extension or its configuration, so no approval is asked.
    /// Connections attached to the old session stall and fail, as at Turn
    /// Off.
    private func restartSession() async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        guard manager.providerConfiguration != nil else { return }
        manager.isEnabled = false
        try await manager.saveToPreferences()
        manager.isEnabled = true
        try await manager.saveToPreferences()
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
        repair.judgeAfresh()
        do {
            try await work()
            await refresh()
        } catch {
            status = .failed("\(error.localizedDescription)")
        }
    }

    private func submit(_ request: OSSystemExtensionRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            awaited.begin(ObjectIdentifier(request), continuation)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ request: ObjectIdentifier, _ result: Result<Void, any Error>) {
        if awaited.finish(request, result) { return }
        guard let upgrade = pendingUpgrade, ObjectIdentifier(upgrade) == request else { return }
        pendingUpgrade = nil
        // A failed upgrade leaves the running extension, which the watch
        // already judges; a completed one is a new extension to judge.
        guard case .success = result else { return }
        repair.judgeAfresh()
        startWatching()
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
        let id = ObjectIdentifier(request)
        Task { @MainActor in self.finish(id, .success(())) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let id = ObjectIdentifier(request)
        Task { @MainActor in self.finish(id, .failure(error)) }
    }
}
