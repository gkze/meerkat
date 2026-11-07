import AppKit
import MeerkatAgent
import MeerkatKit
import SwiftUI

/// The Settings window (Meerkat › Settings…, ⌘,). One tab per pane. Lasting
/// choices only: one-off daemon actions (restart, reinstall) live on the
/// Daemon health page, beside the status they act on.
struct SettingsView: View {
    let agent: AgentControl

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(agent: agent)
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
                Text("Themes follow the app's appearance. Dracula and Nord are always dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    let agent: AgentControl
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
                        .foregroundStyle(Theme.text(Theme.critical))
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

/// Asks for the Automation permission that rules' Apple Events effects
/// need (`appearance.setDark` controls System Events). macOS shows that
/// prompt only to an app in the foreground, never to meerkatd, and its
/// answer covers both, so the app asks here. Nothing is checked until the
/// button is clicked: checking starts System Events.
private struct AutomationSection: View {
    private static let systemEvents = "com.apple.systemevents"
    @State private var status: AutomationPermission.Status?
    @State private var asking = false

    var body: some View {
        Section {
            LabeledContent("System Events") {
                HStack(spacing: 6) {
                    if asking { ProgressView().controlSize(.small) }
                    Text(label)
                }
                .foregroundStyle(.secondary)
            }
            if status != .granted {
                Button("Allow Meerkat to Control System Events…") {
                    Task {
                        asking = true
                        status = await AutomationPermission.request(Self.systemEvents)
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
        } header: {
            Text("Automation")
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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

    private var footer: String {
        if status == .denied {
            return "Turn on System Events under Meerkat in Privacy & Security › Automation. "
                + "If it is already on, macOS kept an earlier answer: run "
                + "tccutil reset AppleEvents com.gkze.meerkat in Terminal, then click Allow again."
        }
        return "Rules that switch dark mode (appearance.setDark) send Apple Events to System Events. "
            + "macOS asks only an app in the foreground, so Meerkat asks here on meerkatd's behalf."
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
