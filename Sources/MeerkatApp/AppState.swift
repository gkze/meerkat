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

    /// One XPC session and one heartbeat for every page. The Event Explorer,
    /// process cards and the agent controls always use it; the other models
    /// take `daemon`, which sample data replaces.
    let client: DaemonClient
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
        let client = DaemonClient()
        self.client = client
        let daemon = Self.daemon(client)
        metrics = MetricsModel(client: daemon)
        explorer = ExplorerModel(client: client)
        rules = RulesModel(client: daemon)
        dryRun = RuleDryRunModel(client: daemon)
        health = HealthModel(client: daemon)
        agent = AgentControl(client: client)
    }

    private static func daemon(_ client: DaemonClient) -> any DaemonConnection {
        #if DEBUG
            if SampleData.isEnabled { return SampleDaemon() }
        #endif
        return client
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
