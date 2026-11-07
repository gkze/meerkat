import AppKit
import MeerkatAgent
import MeerkatIPC
import MeerkatKit
import SwiftUI

/// A failed request to meerkatd, classified once where it was caught: the
/// typed `DaemonClient.ClientError` decides the class, the text is for
/// display only.
struct DaemonFault: Equatable, CustomStringConvertible {
    /// The daemon answered, but is a different build from this app.
    let isDifferentBuild: Bool
    let description: String

    init(_ error: any Error) {
        isDifferentBuild = if case .differentBuild? = error as? DaemonClient.ClientError { true } else { false }
        description = "\(error)"
    }
}

/// A page's first request to meerkatd.
enum LoadState: Equatable {
    case loading
    case loaded
    case failed(DaemonFault)
}

/// Why meerkatd does not answer, in the words every page uses: the full-page
/// `DaemonUnavailableView` and the Overview's banner.
struct DaemonProblem {
    let fault: DaemonFault
    let agent: AgentRegistration.Status

    var title: String {
        if fault.isDifferentBuild { return "meerkatd is a different build" }
        switch agent {
        case .notRegistered: return "meerkatd isn't installed"
        case .requiresApproval: return "meerkatd is off in Login Items"
        case .enabled: return "meerkatd isn't answering"
        case .notInBundle: return "Run Meerkat from Meerkat.app"
        }
    }

    var explanation: String {
        if fault.isDifferentBuild {
            return
                "The running agent was built separately from this app, for example it has not restarted since an update. Restart it so they match (`meerkat agent restart`); if that does not help, reinstall it from this copy of Meerkat."
        }
        switch agent {
        case .notRegistered:
            return
                "The app reads everything from the background agent. Installing it also runs the rules in the rules folder."
        case .requiresApproval: return "Turn on Meerkat in System Settings > General > Login Items & Extensions."
        case .enabled:
            return
                "The agent is registered but didn't reply. Reinstalling registers it again from this copy of Meerkat."
        case .notInBundle: return "The agent can only be managed from the installed app."
        }
    }

    var symbol: String { fault.isDifferentBuild ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle" }
}

/// The one action most likely to fix a `DaemonProblem`, run through
/// `AgentControl` so Settings and the Daemon health page show the same
/// progress and the same failure. Restart and Reinstall are asked about
/// first, as everywhere (`AgentControl.Action.confirmation`): the daemon may
/// be running rules.
struct AgentFixButton: View {
    let problem: DaemonProblem
    let agent: AgentControl
    /// Called once the action succeeds, to subscribe again at once rather
    /// than at the next retry.
    let fixed: () async -> Void
    @State private var pending: AgentControl.Action?

    var body: some View {
        button
            .confirmingAgentAction($pending, agent: agent) { error in
                if error == nil { await fixed() }
            }
    }

    @ViewBuilder private var button: some View {
        switch agent.status {
        case .notRegistered:
            Button(agent.action == .installing ? "Installing…" : "Install Agent") {
                Task {
                    await agent.install()
                    if agent.error == nil { await fixed() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(agent.action != nil)
        case .requiresApproval:
            Button("Open Login Items…") { agent.openLoginItems() }
                .buttonStyle(.borderedProminent)
        case .enabled where problem.fault.isDifferentBuild:
            Button(agent.action == .restarting ? "Restarting…" : "Restart Agent") { pending = .restarting }
                .buttonStyle(.borderedProminent)
                .disabled(!agent.canRestart)
        case .enabled:
            // Registered but silent: launchd may be refusing this build's
            // binary (a launch constraint from an earlier signature), which
            // registering again from the running app fixes, and a restart
            // would not.
            Button(agent.action == .reinstalling ? "Reinstalling…" : "Reinstall Agent") { pending = .reinstalling }
                .buttonStyle(.borderedProminent)
                .disabled(!agent.canReinstall)
        case .notInBundle:
            EmptyView()
        }
    }
}

extension View {
    /// Asks before `pending`'s action runs, in its `confirmation`'s words,
    /// then runs it and calls `completed` with its failure, if any: the one
    /// confirmation for every place that offers an agent action.
    func confirmingAgentAction(
        _ pending: Binding<AgentControl.Action?>, agent: AgentControl,
        completed: @escaping @MainActor (_ error: String?) async -> Void = { _ in }
    ) -> some View {
        let confirmation = pending.wrappedValue?.confirmation
        return confirmationDialog(
            confirmation?.title ?? "",
            isPresented: Binding(
                get: { pending.wrappedValue?.confirmation != nil },
                set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { action in
            Button(action.confirmation?.button ?? "") {
                Task {
                    await agent.run(action)
                    await completed(agent.error)
                }
            }
        } message: { action in
            Text(action.confirmation?.message ?? "")
        }
    }
}

/// A page's whole content when meerkatd does not answer: why, and the one
/// action most likely to fix it.
struct DaemonUnavailableView: View {
    let fault: DaemonFault
    let agent: AgentControl
    let retry: () async -> Void

    var body: some View {
        let problem = DaemonProblem(fault: fault, agent: agent.status)
        let reason = fault.description
        ContentUnavailableView {
            Label(problem.title, systemImage: problem.symbol)
        } description: {
            VStack(spacing: 8) {
                Text(problem.explanation)
                Text(agent.error ?? reason)
                    .font(.caption)
                    .foregroundStyle(agent.error == nil ? .tertiary : .secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(agent.error ?? reason)
            }
        } actions: {
            HStack {
                AgentFixButton(problem: problem, agent: agent, fixed: retry)
                Button("Try Again") { Task { await retry() } }
            }
        }
        // Registration has no change notifications; read it when shown.
        .task { agent.refresh() }
    }
}

/// What a page shows until it has something to show: progress, or why not.
struct DaemonLoadGate: View {
    let state: LoadState
    let agent: AgentControl
    let retry: () async -> Void

    var body: some View {
        if case .failed(let fault) = state {
            DaemonUnavailableView(fault: fault, agent: agent, retry: retry)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The last poll failed; what is on screen is the last good `subject`.
struct StaleBanner: View {
    let subject: String
    let reason: String

    var body: some View {
        Label(
            "Lost contact with meerkatd. Showing the last \(subject). \(reason)", systemImage: "bolt.horizontal.circle"
        )
        .font(.callout)
        .foregroundStyle(Theme.text(Theme.warn))
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

/// One feed the daemon refused or ended, where its numbers show: they hold
/// their last values until the feed subscribes again on its own
/// (`MetricsModel.feedFailures`). The daemon still answers, so this is not
/// the connection banner, and offers no agent action.
struct FeedFailureNote: View {
    let reason: String

    var body: some View {
        Label {
            Text("Not updating: \(reason). Trying again.")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
        }
        .font(.caption)
        .lineLimit(2)
        .help(reason)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small coloured capsule for a state word.
struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.text(tint))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .capsule)
            .fixedSize()
    }
}

extension RuleSummary.State {
    var label: String {
        switch self {
        case .loaded: return "Running"
        case .failed: return "Failed"
        case .disabled: return "Off"
        }
    }

    var tint: Color {
        switch self {
        case .loaded: return .green
        case .failed: return .red
        case .disabled: return .secondary
        }
    }
}

extension HandlerHostStatus.State {
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .running: return "Running"
        case .backingOff: return "Restarting"
        case .unavailable: return "Unavailable"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .starting, .backingOff: return .orange
        case .running: return .green
        case .unavailable: return .red
        }
    }
}

extension LogLevel {
    var symbol: String {
        switch self {
        case .debug: return "ant"
        case .info: return "info.circle"
        case .warn: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}

enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens `url` with its default application without waiting for it.
    /// `NSWorkspace.open(_:)` waits on Launch Services, on the main thread,
    /// until the handling app has launched; a slow or stuck handler (a code
    /// editor for a rule file) froze the whole app, Quit included.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

/// A row of a two-column details grid: a quiet trailing label, then its value.
struct LabeledGridRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value
        }
    }
}

/// A link-styled button whose title stays on one line. `.buttonStyle(.link)`
/// ignores a line limit set on the button, so a long event name in a narrow
/// table column would otherwise wrap mid-word.
struct LinkButton: View {
    let title: String
    var monospaced = true
    let action: () -> Void

    init(_ title: String, monospaced: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.monospaced = monospaced
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.link)
    }
}

// MARK: - Trailing panel

extension View {
    /// A details panel on the trailing edge, below the toolbar. The system
    /// `.inspector` column draws its divider through the toolbar as well,
    /// where it cut across the search field; this one is page content, so it
    /// starts under the toolbar the way Pages' and Keynote's inspectors do.
    /// Drag its edge to resize it within `width`.
    func trailingPanel<Panel: View>(
        isPresented: Bool, width: ClosedRange<CGFloat>, ideal: CGFloat, @ViewBuilder panel: () -> Panel
    ) -> some View {
        modifier(TrailingPanel(isPresented: isPresented, range: width, ideal: ideal, panel: panel()))
    }
}

private struct TrailingPanel<Panel: View>: ViewModifier {
    let isPresented: Bool
    let range: ClosedRange<CGFloat>
    let ideal: CGFloat
    let panel: Panel
    @State private var width: CGFloat?
    @State private var dragStart: CGFloat?

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                Divider()
                    .overlay {
                        Color.clear
                            .frame(width: 8)
                            .contentShape(.rect)
                            .pointerStyle(.frameResize(position: .leading))
                            .gesture(resize)
                            .accessibilityHidden(true)
                    }
                panel
                    .frame(width: width ?? ideal)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var resize: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? width ?? ideal
                dragStart = start
                width = min(max(start - drag.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in dragStart = nil }
    }
}

extension View {
    /// The process card for whichever process `card` names, pointing at this
    /// view: the list the process was picked from. Not at the row, which
    /// re-ranking can move or remove (a popover closes with the view it
    /// points at), so the card stays open while it follows the process.
    func processCard(_ card: Binding<ProcessTarget?>, metrics: MetricsModel, app: AppState) -> some View {
        popover(item: card, arrowEdge: .leading) { target in
            // Identified by its process: picking another while the card is
            // open must make a new card, whose model is seeded once.
            ProcessCard(target: target, metrics: metrics, app: app)
                .id(target)
        }
    }
}
