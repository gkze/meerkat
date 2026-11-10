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

    private let backend: AgentBackend
    private let back: DaemonReturn

    init(backend: AgentBackend, back: DaemonReturn = DaemonReturn()) {
        self.backend = backend
        self.back = back
        status = backend.status()
    }

    /// Registered, whether or not Login Items allows it to run.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    /// launchd runs the agent only when it is enabled.
    var canRestart: Bool { status == .enabled && action == nil }
    var canReinstall: Bool { status != .notInBundle && action == nil }

    /// An agent turned on outside the app (Login Items, `meerkat agent
    /// install`) is meerkatd coming back, as one turned on here is.
    func refresh() {
        let current = backend.status()
        guard current != status else { return }
        status = current
        if current == .enabled { back.fire() }
    }

    func dismissError() { error = nil }

    /// Runs `action`; `error` says whether it failed.
    func run(_ action: Action) async {
        switch action {
        case .installing: await install()
        case .uninstalling: await setRunsInBackground(false)
        case .restarting, .reinstalling: await perform(action)
        }
    }

    func setRunsInBackground(_ on: Bool) async {
        guard on != isRegistered else { return }
        await perform(on ? .installing : .uninstalling)
    }

    /// Registers the agent, then opens Login Items when macOS wants the
    /// user's approval before launchd may run it. The same route as
    /// `meerkat agent install` (`AgentRegistration.installAndAwait`).
    func install() async {
        await setRunsInBackground(true)
        if error == nil, status == .requiresApproval { openLoginItems() }
    }

    func openLoginItems() { AgentRegistration.openLoginItemsSettings() }

    private func perform(_ action: Action) async {
        guard self.action == nil else { return }
        self.action = action
        error = nil
        defer {
            self.action = nil
            refresh()
        }
        do {
            try await backend.run(action)
            if action != .uninstalling { back.fire() }
        } catch {
            self.error = "\(error)"
        }
    }
}

/// What `AgentControl` acts on, chosen once by `AppState`: the system's
/// registration of the agent, or sample data's stand-in, which changes
/// nothing installed.
struct AgentBackend: Sendable {
    /// The registration now; `SMAppService` sends no change notifications.
    let status: @MainActor @Sendable () -> AgentRegistration.Status
    /// Runs an action, off the main actor, throwing its failure in words
    /// for the person.
    let run: @Sendable (AgentControl.Action) async throws -> Void

    /// The LaunchAgent in this copy of Meerkat.app. Every action that
    /// registers decides it as `meerkat agent install` does, and fails in
    /// its words (`AgentRegistration.RegistrationError`): done once a daemon
    /// from this build answers, or once Login Items holds it for approval.
    /// Restart waits for a new daemon the same way. Nothing is rebuilt:
    /// Reinstall registers again, so launchd rereads the bundle's plist and
    /// restarts meerkatd from the bundle's binary.
    static func system(_ client: DaemonClient) -> AgentBackend {
        AgentBackend(
            status: { AgentRegistration.status },
            run: { action in
                switch action {
                case .installing, .reinstalling:
                    _ = try await AgentRegistration.installAndAwait(client: client)
                case .uninstalling:
                    try AgentRegistration.uninstall()
                case .restarting:
                    _ = try await AgentRegistration.restartAndAwait(client: client)
                }
            })
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
