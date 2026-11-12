import AppKit
import MeerkatAgent
import MeerkatKit
import SwiftUI

/// The Settings window (Meerkat › Settings…, ⌘,). One tab per pane. Lasting
/// choices only: one-off daemon actions (restart, reinstall) live on the
/// Daemon health page, beside the status they act on.
struct SettingsView: View {
    let agent: AgentControl
    let networkFilter: NetworkFilterSetup

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(agent: agent, networkFilter: networkFilter)
            }
            Tab("Sampling", systemImage: "waveform.path.ecg") {
                SamplingSettings()
            }
            Tab("Editor", systemImage: "curlybraces") {
                EditorSettings()
            }
        }
        .frame(width: 500)
    }
}

private struct EditorSettings: View {
    @AppStorage(RuleEditorTheme.defaultsKey) private var theme: RuleEditorTheme = .system

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(RuleEditorTheme.allCases) { Text($0.title).tag($0) }
                }
                RuleEditorThemePreview(theme: theme)
            } footer: {
                Text("Themes follow the app's appearance. \(Self.darkOnly) are always dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Dracula and Nord".
    private static let darkOnly = RuleEditorTheme.allCases.filter(\.isDarkOnly).map(\.title)
        .formatted(.list(type: .and))
}

private struct GeneralSettings: View {
    let agent: AgentControl
    let networkFilter: NetworkFilterSetup
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    /// Turn Off, while it is being confirmed.
    @State private var pending: AgentControl.Action?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows the appearance set in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Turning it on registers the LaunchAgent, off unregisters
                // it: the same switch as Meerkat in System Settings > Login
                // Items, so the two always agree.
                Toggle(
                    "Run meerkatd in the background",
                    isOn: Binding(
                        get: { agent.isRegistered },
                        set: { on in
                            // Turning it off stops every rule; ask first, as
                            // Restart and Reinstall do.
                            if on { Task { await agent.setRunsInBackground(true) } } else { pending = .uninstalling }
                        }
                    )
                )
                .disabled(agent.status == .notInBundle || agent.action != nil)
                .confirmingAgentAction($pending, agent: agent)

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if let action = agent.action {
                            ProgressView().controlSize(.small)
                            Text(action.label)
                        } else {
                            Text(agent.status.settingsLabel)
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                if agent.status == .requiresApproval {
                    Button("Open Login Items…") { agent.openLoginItems() }
                }

                if let error = agent.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Status.critical.text)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Background agent")
            } footer: {
                Text(
                    "meerkatd collects events for this app, the meerkat command and your rules. "
                        + "While it is off, rules do not run."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            AutomationSection()
            NetworkFilterSection(setup: networkFilter)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        // Login Items can change the registration while Meerkat is in the
        // background, and SMAppService does not report it.
        .task { agent.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            agent.refresh()
        }
    }
}

/// Turns the network filter on and off (docs/design/network-filter.md):
/// installing a system extension and configuring a content filter are the
/// app's to do, each confirmed by the user in System Settings.
private struct NetworkFilterSection: View {
    let setup: NetworkFilterSetup

    var body: some View {
        Section {
            LabeledContent("Network filter") {
                HStack(spacing: 6) {
                    if setup.busy { ProgressView().controlSize(.small) }
                    Text(setup.status.summary)
                }
                .foregroundStyle(.secondary)
            }
            Text(setup.status.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            switch setup.status {
            case .off, .failed:
                Button("Turn On…") { Task { await setup.turnOn() } }.disabled(setup.busy)
            case .on, .awaitingApproval:
                Button("Turn Off") { Task { await setup.turnOff() } }.disabled(setup.busy)
            case .notInThisBuild, .needsApplications:
                EmptyView()
            }
        } header: {
            Text("Network")
        }
        .task { await setup.refresh() }
    }
}

/// Asks for the Automation permission that rules' Apple Events effects
/// need, one app at a time, for every app the effect catalog sends them to
/// (`EffectDescriptor.automation`). macOS shows that prompt only to an app
/// in the foreground, never to meerkatd, and its answer covers both, so the
/// app asks here. Nothing is checked until the button is clicked: checking
/// starts the target app.
private struct AutomationSection: View {
    private struct Target: Identifiable {
        let target: AutomationTarget
        var effects: [String]
        var id: String { target.bundleId }
    }

    /// Each target once, with the effects that need it, in catalog order.
    private static let targets: [Target] = EffectCatalog.standard.effects.reduce(into: []) { targets, effect in
        guard let target = effect.automation else { return }
        if let index = targets.firstIndex(where: { $0.target == target }) {
            targets[index].effects.append(effect.kind)
        } else {
            targets.append(Target(target: target, effects: [effect.kind]))
        }
    }

    var body: some View {
        Section {
            ForEach(Self.targets) { entry in
                AutomationRow(target: entry.target, effects: entry.effects)
            }
        } header: {
            Text("Automation")
        } footer: {
            Text(
                "Rules' effects that control another app send it Apple Events. macOS asks only an app in the "
                    + "foreground, so Meerkat asks here on meerkatd's behalf."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct AutomationRow: View {
    let target: AutomationTarget
    /// The effects that send `target` Apple Events, for the explanation.
    let effects: [String]
    @State private var status: AutomationPermission.Status?
    @State private var asking = false

    var body: some View {
        LabeledContent(target.name) {
            HStack(spacing: 6) {
                if asking { ProgressView().controlSize(.small) }
                Text(label)
            }
            .foregroundStyle(.secondary)
        }
        Text(explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        if status != .granted {
            Button("Allow Meerkat to Control \(target.name)…") {
                Task {
                    asking = true
                    status = await AutomationPermission.request(target.bundleId)
                    asking = false
                }
            }
            .disabled(asking)
        }
        if status == .denied,
            let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
        {
            Button("Open Automation Settings…") { Finder.open(url) }
        }
    }

    private var label: String {
        switch status {
        case nil: "Not checked"
        case .granted?: "Allowed"
        case .denied?: "Not allowed"
        case .notDetermined?: "Not asked yet"
        case .unavailable(let code)?: "Could not check (OSStatus \(code))"
        }
    }

    private var explanation: String {
        let used = "Used by \(effects.joined(separator: ", "))."
        guard status == .denied else { return used }
        return used + " Turn on \(target.name) under Meerkat in Privacy & Security › Automation. "
            + "If it is already on, macOS kept an earlier answer: run "
            + "tccutil reset AppleEvents \(Bundle.main.bundleIdentifier ?? "com.gkze.meerkat") in Terminal, "
            + "then click Allow again."
    }
}

private struct SamplingSettings: View {
    @AppStorage(SamplingPreset.defaultsKey) private var preset: SamplingPreset = .normal
    @AppStorage(SamplingRates.customKey) private var customRates = ""

    private var custom: SamplingRates { SamplingRates(json: customRates) ?? .normal }

    var body: some View {
        Form {
            Section {
                Picker("Sampling rate", selection: $preset) {
                    ForEach(SamplingPreset.allCases) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(option.rates(custom: custom).cadenceSummary)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(
                    "Charts always cover the last two minutes. "
                        + "The daemon shares a sampler only between subscribers that ask for the same rate, "
                        + "so rules on other rates keep their own."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if preset == .custom {
                Section("Custom rates") {
                    ForEach(SamplingField.allCases) { field in
                        Picker(selection: rate(field)) {
                            ForEach(field.options(in: custom), id: \.self) { step in
                                Text(SamplingStep.every(step)).tag(step)
                            }
                        } label: {
                            Text(field.title)
                            Text(field.help)
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        // Custom starts from the rates just in use rather than from Normal.
        .onChange(of: preset) { previous, current in
            if current == .custom, SamplingRates(json: customRates) == nil {
                customRates = previous.rates(custom: nil).json
            }
        }
    }

    private func rate(_ field: SamplingField) -> Binding<Double> {
        Binding(
            get: { custom[keyPath: field.keyPath] },
            set: { customRates = field.setting($0, in: custom).json }
        )
    }
}
