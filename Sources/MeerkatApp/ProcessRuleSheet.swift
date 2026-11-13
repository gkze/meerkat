import Foundation
import MeerkatKit
import SwiftUI

/// A `process.hot` rule for one process, written as a TypeScript file in
/// the rules folder: the daemon compiles and loads it like any rule, and
/// the file is the user's to edit afterwards.
struct ProcessRuleDraft: Equatable {
    enum Action: String, CaseIterable, Identifiable {
        case notify, background
        var id: Self { self }

        var title: String {
            switch self {
            case .notify: "Notify me"
            case .background: "Move it to the background and notify me"
            }
        }
    }

    var process: String
    var metric: ProcessHotParameters.Metric = .cpuPercent
    var threshold: Double = ProcessHotParameters.Metric.cpuPercent.defaultThreshold
    var minutes: Double = 5
    var action: Action = .notify
    var fileName: String
    /// Whether the process belongs to another user: the rule then needs to
    /// observe every user's processes, not only the user's own.
    var otherUser: Bool

    init(process: String, otherUser: Bool = false) {
        self.process = process
        self.otherUser = otherUser
        fileName = Self.slug(process) + "-hot.ts"
    }

    var ruleName: String { (fileName as NSString).deletingPathExtension }

    /// The file's text. Every value from outside (the process name) goes in
    /// as a JSON string literal, which TypeScript reads as the same string,
    /// and never into a comment, which a line break would end.
    var source: String {
        let name = Self.literal(process)
        // At least 5 minutes between notifications, at most `rate`'s limit.
        let longest = Self.whole(RuleLimits.rateSeconds.maximum ?? .infinity)
        let throttle = min(max(Self.whole(minutes * 60 * 3), 300), longest)
        let observe = otherUser ? "\"all\"" : "\"own\""
        let capabilities =
            action == .background
            ? "{ process: { observe: \(observe), priority: true }, notify: true }"
            : "{ process: { observe: \(observe) }, notify: true }"
        let move =
            action == .background
            ? """
                const { pid, startedAt } = event.process;
                await ctx.process.setPriority({ pid, startedAt }, "background");

            """ : ""
        return """
            // Made in Meerkat from a process card. Edit freely.
            import { rule } from "meerkat";

            const SECONDS_PER_MINUTE = 60;

            export const \(RuleFileSource.identifier(RuleFileSource.words(ruleName), empty: "processRule")) = rule({
              name: \(Self.literal(ruleName)),
              on: "process.hot",
              params: { metric: "\(metric.rawValue)", above: \(Self.number(threshold)), sustainSeconds: \(sustainSeconds) },
              match: { phase: "started", process: { name: \(name) } },
              rate: { throttleSeconds: \(throttle) },
              capabilities: \(capabilities),
              async handle(event, ctx) {
            \(move)    await ctx.notify({
                  title: \(Self.literal("\(process) \(metric.what)")),
                  body: `${event.value.toFixed(0)} \(metric.unit) for ${Math.round(event.aboveForSeconds / SECONDS_PER_MINUTE)} min`,
                });
              },
            });

            """
    }

    private var sustainSeconds: Int { Self.whole(minutes * 60) }

    var problem: String? {
        if threshold <= 0 { return "The threshold must be above 0." }
        if sustainSeconds <= 0 { return "The duration must be above 0." }
        let parameters = ProcessHotParameters(metric: metric, above: threshold, sustainSeconds: Double(sustainSeconds))
        do {
            try parameters.validate()
        } catch {
            return "\(error)"
        }
        if case .failure(let problem) = file { return problem.description }
        return nil
    }

    /// The file to write in the rules folder, by the editor's rules for a
    /// new file's name; whether one is already there is checked on create.
    var file: Result<String, RuleFileSource.FileNameProblem> { RuleFileSource.fileName(fileName, existing: []) }

    static func slug(_ text: String) -> String {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? "process" : joined
    }

    /// `text` as a string literal on one line. JSON leaves U+0085, U+2028
    /// and U+2029 raw, which editors show as line breaks, so they're escaped
    /// too: the file breaks lines only where the template does.
    static func literal(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{85}", with: "\\u0085")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// The nearest whole number. The preview builds on every keystroke, so
    /// this takes any number a field accepts; `problem` refuses the large.
    static func whole(_ value: Double) -> Int { Int(exactly: value.rounded()) ?? .max }

    static func number(_ value: Double) -> String {
        Int(exactly: value).map { String($0) } ?? String(value)
    }
}

/// How the sheet offers each `process.hot` metric: every one the event
/// knows, in its words.
extension ProcessHotParameters.Metric {
    var title: String {
        switch self {
        case .cpuPercent: "CPU"
        case .footprintMB: "Memory"
        case .energyWatts: "Energy"
        case .diskWriteMBps: "Disk writes"
        case .diskReadMBps: "Disk reads"
        case .networkInMBps: "Network received"
        case .networkOutMBps: "Network sent"
        case .networkMBps: "Network"
        }
    }

    var unit: String {
        switch self {
        case .cpuPercent: "% of a core"
        case .footprintMB: "MB"
        case .energyWatts: "W"
        case .diskWriteMBps, .diskReadMBps, .networkInMBps, .networkOutMBps, .networkMBps: "MB/s"
        }
    }

    var defaultThreshold: Double {
        switch self {
        case .cpuPercent: 80
        case .footprintMB: 4000
        case .energyWatts: 5
        case .diskWriteMBps, .diskReadMBps: 50
        case .networkInMBps, .networkOutMBps, .networkMBps: 10
        }
    }

    /// The notification's headline: "is running hot", "is using a lot of
    /// memory".
    var what: String {
        switch self {
        case .cpuPercent: "is running hot"
        case .footprintMB: "is using a lot of memory"
        case .energyWatts: "is using a lot of energy"
        case .diskWriteMBps: "is writing a lot"
        case .diskReadMBps: "is reading a lot"
        case .networkInMBps: "is downloading a lot"
        case .networkOutMBps: "is uploading a lot"
        case .networkMBps: "is using a lot of network"
        }
    }
}

struct ProcessRuleSheet: View {
    let rules: RulesModel
    let created: () -> Void
    @State private var draft: ProcessRuleDraft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(target: ProcessTarget, rules: RulesModel, created: @escaping () -> Void) {
        self.rules = rules
        self.created = created
        // One-time seed from the process the card shows.
        _draft = State(initialValue: ProcessRuleDraft(process: target.name, otherUser: target.uid != getuid()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Rule for \(draft.process)").font(.headline)
                Text("Saved to your rules folder as a TypeScript file you can edit later.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Form {
                LabeledContent("When") {
                    HStack {
                        Picker("Metric", selection: $draft.metric) {
                            ForEach(ProcessHotParameters.Metric.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("is above")
                        TextField("Threshold", value: $draft.threshold, format: .number)
                            .labelsHidden()
                            .frame(width: 64)
                        Text(draft.metric.unit)
                        Text("for")
                        TextField("Minutes", value: $draft.minutes, format: .number)
                            .labelsHidden()
                            .frame(width: 44)
                        Text("min")
                    }
                }
                LabeledContent("Process") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(draft.process)
                        Text("matched by name").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Picker("Then", selection: $draft.action) {
                    ForEach(ProcessRuleDraft.Action.allCases) { Text($0.title).tag($0) }
                }
                TextField("File", text: $draft.fileName)
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.columns)
            .onChange(of: draft.metric) { _, metric in draft.threshold = metric.defaultThreshold }
            // A failed Create is about the draft it tried; any change is a
            // new one.
            .onChange(of: draft) { error = nil }
            ScrollView {
                Text(draft.source)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 220)
            .background(.fill.quaternary, in: .rect(cornerRadius: 8))
            HStack {
                Text(error ?? draft.problem ?? "The rule loads when the file is saved.")
                    .font(.caption)
                    .foregroundStyle(error != nil || draft.problem != nil ? Status.critical.text : .secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Rule") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    /// Writes the file without replacing one already there, then shows the
    /// Rules page, where the rule appears once the daemon has compiled it.
    private func create() {
        guard case .success(let file) = draft.file else { return }
        let url = URL(fileURLWithPath: rules.rulesDirectory).appendingPathComponent(file)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            error = "A file named \(file) is already in the rules folder."
            return
        }
        do {
            try RuleFileSource.create(url, text: draft.source)
        } catch {
            self.error = "Could not save \(file): \(error.localizedDescription)"
            return
        }
        dismiss()
        created()
    }
}
