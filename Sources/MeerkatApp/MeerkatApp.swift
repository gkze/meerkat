import SwiftUI

@main
struct MeerkatApp: App {
    /// Created once for the app's lifetime; the window and the commands
    /// share it.
    @State private var app = AppState()
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    @AppStorage(RuleEditorTheme.defaultsKey) private var editorTheme: RuleEditorTheme = .system

    var body: some Scene {
        // One window, not a `WindowGroup`: every page model, and the rule
        // editor's one buffer, belongs to the app, so a second window would
        // show and edit the same state twice. Closing it quits the app.
        Window("Meerkat", id: "main") {
            RootView(app: app)
                // App-wide, so the Settings window and menus follow too.
                .onChange(of: appearance, initial: true) { appearance.apply() }
        }
        // A titled window, so the split view's sidebar toggle, the search
        // field and the inspector toggle have a toolbar to live in.
        // Wide enough for sidebar, a table and an inspector side by side, so
        // opening a page with an inspector doesn't grow the window.
        .defaultSize(width: 1360, height: 880)
        .windowResizability(.contentMinSize)
        .commands {
            // A single-window instrument: the New command has nothing to open.
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Picker("Editor Theme", selection: $editorTheme) {
                    ForEach(RuleEditorTheme.allCases) { Text($0.title).tag($0) }
                }
            }
            DetailsPanelCommands()
            CommandMenu("Rules") {
                Button("Reload Rules") { Task { await app.rules.reload() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open Rules Folder") {
                    Finder.open(URL(fileURLWithPath: app.rules.rulesDirectory))
                }
            }
            CommandGroup(before: .sidebar) {
                Button("Overview") { app.destination = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Event Explorer") { app.destination = .explorer }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Rules") { app.destination = .rules }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Daemon Health") { app.destination = .health }
                    .keyboardShortcut("4", modifiers: .command)
                Divider()
            }
        }

        // The standard Settings window: SwiftUI adds Meerkat › Settings…
        // and ⌘, for it.
        Settings {
            SettingsView(agent: app.agent)
        }
    }
}

extension FocusedValues {
    /// Whether the showing page's details panel is open; nil when the page
    /// has none it can show now. Pages keep the state, so it survives
    /// switching kinds or files the way their toolbar toggles do.
    @Entry var detailsPanel: Binding<Bool>?
}

/// View › Show/Hide Inspector for the page's details panel (`trailingPanel`),
/// which SwiftUI's `InspectorCommands` can't reach: it acts on
/// `.inspector`, which no page uses.
struct DetailsPanelCommands: Commands {
    @FocusedBinding(\.detailsPanel) private var isShown

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(isShown == true ? "Hide Inspector" : "Show Inspector") { isShown?.toggle() }
                .keyboardShortcut("i", modifiers: [.control, .command])
                .disabled(isShown == nil)
        }
    }
}
