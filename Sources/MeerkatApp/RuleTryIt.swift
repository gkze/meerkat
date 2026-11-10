import MeerkatIPC
import MeerkatKit
import SwiftUI

/// The rule editor's "Try it" inspector: runs the unsaved text
/// on live, recorded or example events and shows what each did.
struct RuleTryIt: View {
    @Bindable var model: RuleDryRunModel
    let editor: RuleEditorModel
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                sourcePicker
                if ruleNames.count > 1 { rulePicker }
                Text(Self.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            Divider()
            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let finished, finished.report.outcome == .ran {
                Divider()
                footer(finished)
            }
        }
    }

    private static let note =
        "Dry run: nothing is sent, changed or run. Effects are simulated and handlers get an empty placeholder, "
        + "so a branch on an exec or http result takes the empty path. state.get reads the rule's real state."

    // MARK: - Controls

    private var header: some View {
        HStack {
            Text("Try It").font(.headline)
            Spacer()
            if source == .live {
                Picker("Sample Length", selection: $model.sampleSeconds) {
                    ForEach(RuleDryRunModel.sampleChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min").tag(seconds)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(model.isRunning)
                .help("How long to collect events")
            }
            Button("Run") { run() }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
                .help("Run the unsaved text")
        }
        .controlSize(.small)
    }

    private var sourcePicker: some View {
        Picker("Events", selection: $model.source) {
            ForEach(RuleDryRunModel.Source.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .disabled(model.isRunning)
    }

    private var rulePicker: some View {
        Picker("Rule", selection: ruleBinding) {
            ForEach(ruleNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .controlSize(.small)
        .disabled(model.isRunning)
    }

    private var source: RuleDryRunModel.Source { model.source }

    private var ruleBinding: Binding<String> {
        Binding(get: { selectedRule ?? "" }, set: { model.rule = $0 })
    }

    private var canRun: Bool {
        editor.file != nil && !model.isRunning && (source != .recorded || !recorded.isEmpty)
    }

    private func run() {
        guard let file = editor.file else { return }
        let text = editor.text
        let rule = selectedRule
        let recorded = recorded
        Task { await model.run(file: file, text: text, rule: rule, recorded: recorded) }
    }

    // MARK: - What the file holds

    /// The last report's, which knows the unsaved text, else the saved file's.
    private var ruleNames: [String] {
        if let finished, !finished.report.rules.isEmpty { return finished.report.rules }
        return app.rules.rules.filter { $0.file == editor.file }.compactMap(\.name)
    }

    private var selectedRule: String? {
        if let rule = model.rule, ruleNames.contains(rule) { return rule }
        return ruleNames.count > 1 ? ruleNames.first : nil
    }

    /// The run of the open file, if that's what the last run was.
    private var state: RuleDryRunModel.State { model.state(for: editor.file) }

    private var finished: RuleDryRunModel.Finished? {
        if case .finished(let finished) = state { finished } else { nil }
    }

    /// The event kind the run's rule listens to, as far as is known.
    private var kind: String? {
        if let event = finished?.report.event { return event }
        let fileRules = app.rules.rules.filter { $0.file == editor.file }
        return (fileRules.first { $0.name == selectedRule } ?? fileRules.first)?.event
    }

    private var recorded: [DryRunEvent] {
        RuleDryRunModel.recorded(app.explorer.events, of: app.explorer.streamingKind, for: kind)
    }

    // MARK: - Results

    @ViewBuilder
    private var result: some View {
        switch state {
        case .idle:
            if let other = model.state.file, model.isRunning {
                message(
                    "Another file is running", "Try It runs one file at a time; “\(other)” is running now.",
                    symbol: "hourglass", status: .neutral)
            } else if source == .recorded && recorded.isEmpty {
                nothingRecorded
            } else {
                idlePrompt
            }
        case .running(let running):
            progress(running)
        case .failed(_, let fault):
            message(
                fault.title(.dryRun), fault.explanation(.dryRun), symbol: "exclamationmark.triangle",
                status: .warning)
        case .finished(let finished):
            report(finished)
        }
    }

    private var idlePrompt: some View {
        message("Run the rule", prompt, symbol: "play.circle", status: .neutral)
    }

    private var prompt: String {
        switch source {
        case .live: "Collects events from the rule's source, then runs them. Rows appear when the sample ends."
        case .recorded: "Runs the events the Event Explorer holds."
        case .example: "Runs the event kind's documented examples."
        }
    }

    private var nothingRecorded: some View {
        VStack(alignment: .leading, spacing: 8) {
            message(
                "No recorded events",
                "Recorded means events the Event Explorer holds. Capture some\(kind.map { " of \($0)" } ?? "") there.",
                symbol: "tray", status: .neutral)
            if let kind {
                Button("Open Event Explorer") { app.showEvent(kind) }
                    .controlSize(.small)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func progress(_ running: RuleDryRunModel.Running) -> some View {
        TimelineView(.periodic(from: running.started, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(RuleDryRunModel.progress(of: running, kind: kind, at: context.date))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    /// `detail` is plain text, never Markdown: meerkatd's refusals quote
    /// rule text (an `on:` kind, a source's stop reason), which must not
    /// become links or formatting.
    private func message(_ title: String, _ detail: String, symbol: String, status: Status) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(status.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(verbatim: detail).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(12)
    }

    private func report(_ finished: RuleDryRunModel.Finished) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if finished.text != editor.text {
                    banner("The text has changed since this run.")
                }
                switch finished.report.outcome {
                case .ran: ranRows(finished.report)
                case .rejected: rejected(finished.report)
                case .chooseRule: banner("This file has several rules, or not that one. Choose one above and run.")
                }
                ForEach(Array(finished.report.fileLogs.enumerated()), id: \.offset) { _, log in
                    LogLine(log: log).padding(.horizontal, 12).padding(.vertical, 2)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func ranRows(_ report: DryRunReport) -> some View {
        if report.outOfTime { banner("The run's time budget ended before every event ran.") }
        if report.runs.isEmpty {
            message(
                "No events", "None arrived during the sample. Try Example, or a longer sample.", symbol: "tray",
                status: .neutral)
        }
        ForEach(Array(report.runs.enumerated()), id: \.offset) { index, run in
            if index > 0 { Divider() }
            InvocationRow(run: run)
        }
    }

    private func rejected(_ report: DryRunReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The file doesn't compile or load").fontWeight(.semibold)
            ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(Self.location(of: diagnostic) + diagnostic.message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(12)
    }

    private static func location(of diagnostic: RuleDiagnostic) -> String {
        let place = [diagnostic.file, diagnostic.line.map(String.init), diagnostic.column.map(String.init)]
            .compactMap(\.self).joined(separator: ":")
        return place.isEmpty ? "" : "\(place): "
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Status.warning.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func footer(_ finished: RuleDryRunModel.Finished) -> some View {
        let report = finished.report
        let handlers = report.runs.reduce(0) { $0 + $1.milliseconds }
        return VStack(alignment: .leading, spacing: 2) {
            Text(report.summary)
            Text(
                "Compile \(Self.time(report.compileMilliseconds)) · load \(Self.time(report.loadMilliseconds))"
                    + " · handlers \(Self.time(handlers))"
            )
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .padding(12)
    }

    static func time(_ milliseconds: Double) -> String {
        Format.milliseconds(milliseconds)
    }
}

/// One event's way through the rule.
private struct InvocationRow: View {
    let run: DryRunInvocation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(
                    Date(epochMilliseconds: run.event.time),
                    format: .dateTime.hour().minute().second()
                )
                .monospacedDigit()
                Text(run.event.kind)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if run.milliseconds > 0 {
                    Text(RuleTryIt.time(run.milliseconds)).monospacedDigit().foregroundStyle(.secondary)
                }
                StatusBadge(text: run.result.label, status: run.result.status)
            }
            .font(.caption)
            Text(run.event.payload.canonicalString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(run.event.payload.canonicalString)
            if let detail = run.result.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(run.result.isFailure ? Status.critical.text : Status.neutral.text)
                    .textSelection(.enabled)
            }
            ForEach(Array(run.effects.enumerated()), id: \.offset) { _, effect in
                EffectRow(effect: effect)
            }
            if case .completed = run.result, run.effects.isEmpty {
                Text("No effects").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(run.logs.enumerated()), id: \.offset) { _, log in
                LogLine(log: log)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

/// An effect the handler asked for, none of which happened.
private struct EffectRow: View {
    let effect: DryRunEffect

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(effect.kind).font(.system(.callout, design: .monospaced))
                Text(effect.requestText)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(effect.requestText)
                if let detail = effect.outcomeDetail {
                    Text(detail).foregroundStyle(effect.status.text).lineLimit(3).help(detail)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(text: effect.outcomeLabel, status: effect.status)
        }
        .font(.callout)
    }
}

private struct LogLine: View {
    let log: DryRunLog

    var body: some View {
        Text("\(log.level.rawValue): \(log.message)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(log.level.status.text)
            .textSelection(.enabled)
    }
}
