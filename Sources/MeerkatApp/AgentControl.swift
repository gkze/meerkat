import AppKit
import Foundation
import MeerkatAgent
import MeerkatIPC
import Observation

/// The meerkatd LaunchAgent's registration and lifecycle actions, shared by
/// the Settings window's General pane and the Daemon health page so both show
/// the same state and the same action in progress.
///
/// Registration state belongs to the system (`SMAppService`), which sends no
/// change notifications, so `status` is a cached read refreshed on demand.
@MainActor
@Observable
final class AgentControl {
    enum Action: Equatable {
        case installing
        case uninstalling
        case restarting
        case reinstalling

        var label: String {
            switch self {
            case .installing: return "Turning on…"
            case .uninstalling: return "Turning off…"
            case .restarting: return "Restarting…"
            case .reinstalling: return "Reinstalling…"
            }
        }

        /// What to ask before an action that stops a daemon which may be
        /// running rules: each drops every subscription, and rules miss
        /// events meanwhile (Turn Off until it is turned on again). The one
        /// policy for every place that offers them (the Daemon health
        /// toolbar, the agent banners, Settings), through
        /// `confirmingAgentAction`. Installing starts a daemon that isn't
        /// running, so it is not asked about.
        struct Confirmation {
            let title: String
            let button: String
            let message: String
        }

        var confirmation: Confirmation? {
            switch self {
            case .installing:
                return nil
            case .uninstalling:
                return Confirmation(
                    title: "Turn off meerkatd?", button: "Turn Off",
                    message:
                        "launchd stops meerkatd and won't start it at login. Rules stop running and the dashboard stops updating until you turn it on again."
                )
            case .restarting:
                return Confirmation(
                    title: "Restart meerkatd?", button: "Restart",
                    message:
                        "launchd stops meerkatd and starts it again, which can take up to 10 seconds. Rules miss events meanwhile; they and the dashboard reconnect on their own."
                )
            case .reinstalling:
                return Confirmation(
                    title: "Reinstall the meerkatd agent?", button: "Reinstall",
                    message:
                        "Registers the agent in this copy of Meerkat.app again, so launchd rereads its plist and restarts meerkatd from this app. Rules miss events while it restarts. It does not rebuild Meerkat or update the app."
                )
            }
        }
    }

    private(set) var status: AgentRegistration.Status
    private(set) var action: Action?
    /// The last action's failure, until `dismissError()`.
    private(set) var error: String?

    private let client: DaemonClient
    #if DEBUG
        /// Sample data stands in for the system's registration, so every
        /// action can be checked without touching the installed agent.
        private var sampleStatus: AgentRegistration.Status = .enabled
    #endif

    init(client: DaemonClient) {
        self.client = client
        status = .notRegistered
        status = currentStatus()
    }

    /// Registered, whether or not Login Items allows it to run.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    /// launchd runs the agent only when it is enabled.
    var canRestart: Bool { status == .enabled && action == nil }
    var canReinstall: Bool { status != .notInBundle && action == nil }

    func refresh() {
        let current = currentStatus()
        if current != status { status = current }
    }

    func dismissError() { error = nil }

    /// Runs `action`; `error` says whether it failed.
    func run(_ action: Action) async {
        switch action {
        case .installing: await install()
        case .uninstalling: await setRunsInBackground(false)
        case .restarting: await restart()
        case .reinstalling: await reinstall()
        }
    }

    func setRunsInBackground(_ on: Bool) async {
        guard on != isRegistered else { return }
        if on {
            await perform(.installing, sample: .enabled) { try await Self.installAndAwait($0) }
        } else {
            await perform(.uninstalling, sample: .notRegistered) { _ in try AgentRegistration.uninstall() }
        }
    }

    /// Registers the agent, then opens Login Items when macOS wants the
    /// user's approval before launchd may run it. The same route as
    /// `meerkat agent install` (`AgentRegistration.installAndAwait`).
    func install() async {
        await setRunsInBackground(true)
        if error == nil, status == .requiresApproval { openLoginItems() }
    }

    func openLoginItems() { AgentRegistration.openLoginItemsSettings() }

    /// Restarts meerkatd through launchd and waits for a new process to answer.
    func restart() async {
        await perform(.restarting, sample: .enabled) { client in
            guard try await AgentRegistration.restartAndAwait(client: client) != nil else {
                throw AgentRegistration.RegistrationError.failed(
                    "meerkatd did not answer within \(AgentRegistration.startLimit.formatted()).")
            }
        }
    }

    /// Registers the agent from this copy of Meerkat.app again: launchd
    /// rereads the bundle's plist and restarts meerkatd from the bundle's
    /// binary. Nothing is rebuilt.
    func reinstall() async {
        await perform(.reinstalling, sample: .enabled) { try await Self.installAndAwait($0) }
    }

    /// Registering, as every action that registers decides it: done once a
    /// daemon from this build answers, or once Login Items holds it for
    /// approval; registered but silent is a failure that says so.
    private nonisolated static func installAndAwait(_ client: DaemonClient) async throws {
        switch try await AgentRegistration.installAndAwait(client: client) {
        case .answering, .requiresApproval:
            return
        case .silent:
            throw AgentRegistration.RegistrationError.failed(
                "meerkatd registered but did not start within \(AgentRegistration.startLimit.formatted()). "
                    + "If Meerkat.app was just replaced, quit and reopen it, then Reinstall.")
        }
    }

    private func perform(
        _ action: Action, sample: AgentRegistration.Status,
        _ work: @escaping @Sendable (DaemonClient) async throws -> Void
    ) async {
        guard self.action == nil else { return }
        self.action = action
        error = nil
        defer {
            self.action = nil
            refresh()
        }
        #if DEBUG
            if SampleData.isEnabled {
                try? await Task.sleep(for: .seconds(2))
                sampleStatus = sample
                return
            }
        #endif
        do {
            try await work(client)
        } catch {
            self.error = "\(error)"
        }
    }

    private func currentStatus() -> AgentRegistration.Status {
        #if DEBUG
            if SampleData.isEnabled { return sampleStatus }
        #endif
        return AgentRegistration.status
    }
}

extension AgentRegistration.Status {
    /// Registration state in Settings' words.
    var settingsLabel: String {
        switch self {
        case .enabled: return "On"
        case .requiresApproval: return "Waiting for approval in Login Items"
        case .notRegistered: return "Off"
        case .notInBundle: return "Unavailable: run Meerkat from Meerkat.app"
        }
    }
}
