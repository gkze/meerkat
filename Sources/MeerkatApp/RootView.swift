import SwiftUI

/// The window: a sidebar of pages beside the selected one.
struct RootView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar(app: app)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch app.destination {
            case .overview:
                Dashboard(model: app.metrics, app: app) { app.destination = .resource($0) }
                    .navigationTitle("Overview")
            case .resource(let resource):
                ResourcePage(model: app.metrics, app: app, resource: resource)
                    .navigationTitle(resource.title)
            case .explorer:
                EventExplorer(model: app.explorer, app: app)
                    .navigationTitle("Event Explorer")
            case .rules:
                RulesPage(model: app.rules, app: app)
                    .navigationTitle("Rules")
            case .health:
                HealthPage(model: app.health, app: app)
                    .navigationTitle("Daemon Health")
            }
        }
        // Rule state is window-wide: it feeds the sidebar badge and the
        // explorer's "used by" list, not only the Rules page.
        .task { await app.rules.followStateChanges() }
        .sheet(item: $app.newRuleFor) { target in
            ProcessRuleSheet(target: target, rules: app.rules) { app.destination = .rules }
        }
    }
}

/// A resource and its live value, the way Mail shows a count: secondary,
/// trailing, in tabular figures. Its own view, so each CPU reading
/// redraws this row and not the sidebar or the page beside it.
private struct ResourceRow: View {
    let model: MetricsModel
    let resource: Resource

    var body: some View {
        Label {
            Text(resource.title)
        } icon: {
            ResourceIcon(symbol: resource.symbol, tint: resource.tint, size: 20)
        }
        .badge(Text(model.headline(resource) ?? "").monospacedDigit())
    }
}

/// Its own view, so a rule state change redraws the sidebar's badge and not
/// the page beside it.
private struct Sidebar: View {
    let app: AppState

    var body: some View {
        List(selection: selection) {
            Section("Live") {
                SidebarLabel("Overview", symbol: "square.grid.2x2.fill")
                    .tag(Destination.overview)
                ForEach(Resource.allCases) { resource in
                    ResourceRow(model: app.metrics, resource: resource)
                        .tag(Destination.resource(resource))
                }
            }
            Section("Automate") {
                SidebarLabel("Rules", symbol: "wand.and.rays")
                    .badge(app.rules.failingCount)
                    .badgeProminence(.increased)
                    .tag(Destination.rules)
            }
            Section("Daemon") {
                SidebarLabel("Event Explorer", symbol: "list.bullet.rectangle.portrait.fill")
                    .tag(Destination.explorer)
                SidebarLabel("Health", symbol: "stethoscope")
                    .tag(Destination.health)
            }
        }
    }

    /// `List` selects through an optional, and Command-clicking the
    /// selected row sets it to nil; that is dropped, so the row stays
    /// selected with its page showing.
    private var selection: Binding<Destination?> {
        Binding(get: { app.destination }, set: { if let new = $0 { app.destination = new } })
    }
}

/// A page that is not a resource: the same icon shape in neutral grey, as
/// System Settings draws its non-category rows, so the sidebar reads as one
/// set.
private struct SidebarLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            ResourceIcon(symbol: symbol, tint: .gray, size: 20)
        }
    }
}
