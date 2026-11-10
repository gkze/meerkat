import Foundation
import MeerkatIPC
import MeerkatKit
import Observation

enum Destination: Hashable {
    case overview
    /// One resource's page.
    case resource(Resource)
    case explorer
    case rules
    case health
}

/// What the whole window shares: the one connection to meerkatd, each
/// page's model, and which page is showing.
///
/// Page models live here rather than in their pages, so a page keeps its
/// state across a visit to another one. Each page still starts and stops its
/// own subscriptions and polling with its visibility. Links between pages go
/// through `showEvent` and `showRule`.
@MainActor
@Observable
final class AppState {
    /// Never empty: the sidebar binds it through `Sidebar.selection`, which
    /// ignores a deselection, so the sidebar and the page always agree.
    var destination: Destination = .overview
    /// The process a new rule is being made for: the window presents the
    /// sheet, so it sits on the window rather than on a process card.
    var newRuleFor: ProcessTarget?

    /// The daemon every page and process card asks: one XPC session and one
    /// heartbeat, or sample data's stand-in (`Stand`).
    let daemon: any DaemonConnection
    /// Fired when meerkatd may be back, by the client and by `agent`: every
    /// subscription the app follows retries, or refreshes, at once.
    let back: DaemonReturn
    let metrics: MetricsModel
    let explorer: ExplorerModel
    let rules: RulesModel
    let dryRun: RuleDryRunModel
    let health: HealthModel
    /// The LaunchAgent's registration, for Settings and the Daemon health page.
    let agent: AgentControl
    /// The Rules page's editor: its file, unsaved edits, place and Try It.
    let ruleEditor = RuleEditorSession()

    init() {
        let back = DaemonReturn()
        self.back = back
        let stand = Stand.chosen(DaemonClient(reconnected: { back.fire() }))
        daemon = stand.daemon
        metrics = MetricsModel(client: stand.daemon, hostName: stand.hostName, back: back)
        explorer = ExplorerModel(client: stand.daemon)
        rules = RulesModel(client: stand.daemon, rulesDirectory: stand.rulesDirectory, back: back)
        dryRun = RuleDryRunModel(client: stand.daemon)
        health = HealthModel(client: stand.daemon, back: back)
        agent = AgentControl(backend: stand.agent, back: back)
    }

    /// What the models read from outside the app: the daemon, the Mac's
    /// name, the agent's registration and the rules folder. The one place
    /// sample data (`MEERKAT_SAMPLE_DATA=1`, debug builds) takes their place,
    /// so that it shows made-up figures, the Mac's name included, and
    /// nothing it does reaches the installed daemon, its registration or its
    /// rules: the editor writes to a scratch folder.
    private struct Stand {
        let daemon: any DaemonConnection
        let hostName: @Sendable () -> String
        let agent: AgentBackend
        /// Where the rules folder is until the daemon says.
        let rulesDirectory: URL

        @MainActor
        static func chosen(_ client: DaemonClient) -> Stand {
            #if DEBUG
                if SampleData.isEnabled {
                    return Stand(
                        daemon: SampleDaemon(), hostName: { SampleData.host }, agent: SampleData.agent(),
                        rulesDirectory: SampleData.rulesDirectory)
                }
            #endif
            return Stand(
                daemon: client, hostName: { ProcessInfo.processInfo.hostName }, agent: .system(client),
                rulesDirectory: DaemonPaths.standard().rulesDirectory)
        }
    }

    /// Opens `kind` in the event explorer, with `parameters` ready to
    /// subscribe with when given.
    func showEvent(_ kind: String, parameters: JSONValue? = nil) {
        explorer.open(kind, parameters: parameters)
        destination = .explorer
    }

    /// Opens the Rules page with `id` selected.
    func showRule(_ id: String) {
        rules.selection = id
        destination = .rules
    }
}
