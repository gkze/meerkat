import Foundation
import MeerkatIPC
import MeerkatKit
import Observation

extension RuleSummary: Identifiable {
    /// The rule's name within its file, or nil for a row that stands for a
    /// whole file that failed to load (its id is the file name). Taken past
    /// `file` rather than at a `#`, which a refused file's name may hold.
    var name: String? {
        id == file ? nil : String(id.dropFirst(file.count + 1))
    }

    var isFileFailure: Bool { name == nil }
    var isEnabled: Bool { state != .disabled }

    var lastInvokedDate: Date? {
        lastInvokedAt.map(Date.init(epochMilliseconds:))
    }
}

/// A compiler diagnostic with an identity for lists: its text, plus how
/// many identical diagnostics precede it in the same report.
struct ListedDiagnostic: Identifiable {
    let id: String
    let diagnostic: RuleDiagnostic
}

/// A log line with an identity for lists: its content, plus how many
/// identical lines precede it, so a row keeps its identity across polls.
struct ListedLogEntry: Identifiable {
    let id: String
    let entry: RuleLogEntry
    var date: Date { Date(epochMilliseconds: entry.time) }
}

/// The daemon's rules, as the Rules page, the sidebar and the explorer see
/// them.
///
/// Rule state changes arrive as `meerkat.rule` events for as long as the
/// window is open, so the sidebar badge and the explorer's "used by" list
/// stay current. Invocation counts have no event, so the Rules page also
/// polls while it is on screen.
@MainActor
@Observable
final class RulesModel {
    static let pollInterval: Duration = .seconds(5)
    static let logLimit = 200

    private(set) var report: RulesReport?
    private(set) var loadState: LoadState = .loading
    /// Resolved as the daemon resolves it (`MEERKAT_RULES_DIR`, then the
    /// `RulesDirectory` default) until its status says otherwise, so the
    /// folder opens even when status is unreadable. Taken from every
    /// refresh's status, not the first: a moved `RulesDirectory` applies at
    /// the daemon's next start, which the app doesn't otherwise see.
    private(set) var rulesDirectory: String = DaemonPaths.standard().rulesDirectory.path
    private(set) var reloading = false
    /// The last failed action (reload, enable, disable), shown until the
    /// next one succeeds.
    private(set) var actionError: String?
    private(set) var diagnostics: [ListedDiagnostic] = []
    /// Lint and format findings: advice about style and likely mistakes,
    /// never a reason a rule failed to load.
    private(set) var lintFindings: [ListedDiagnostic] = []

    var lintedAt: Date? {
        report?.lint.map { Date(epochMilliseconds: $0.lintedAt) }
    }

    func lintFindings(in file: String) -> [ListedDiagnostic] {
        lintFindings.filter { $0.diagnostic.file == file }
    }

    var selection: RuleSummary.ID?
    /// Logs for `logsRule`, newest first: the rule's own lines and its
    /// file's.
    private(set) var logs: [ListedLogEntry] = []
    private(set) var logsRule: RuleSummary.ID?
    /// Why `logsRule`'s logs could not be read; nil when `logs` is current.
    private(set) var logsError: String?

    private let client: any DaemonConnection
    private var pendingRefresh: Task<Void, Never>?

    init(client: any DaemonConnection) {
        self.client = client
    }

    var rules: [RuleSummary] { report?.rules ?? [] }
    var failingCount: Int { rules.filter { $0.state == .failed }.count }

    var selectedRule: RuleSummary? {
        guard let selection else { return nil }
        return rules.first { $0.id == selection }
    }

    func rules(handling kind: String) -> [RuleSummary] {
        rules.filter { $0.event == kind && !$0.isFileFailure }
    }

    func fileURL(_ file: String) -> URL {
        URL(fileURLWithPath: rulesDirectory).appendingPathComponent(file)
    }

    /// What kept `file` from loading: its compile and load errors.
    func loadFailures(in file: String) -> [ListedDiagnostic] {
        diagnostics.filter { $0.diagnostic.file == file && $0.diagnostic.tool.isLoadGate }
    }

    // MARK: - Requests

    func refresh() async {
        do {
            apply(try await client.rules())
            if let reported = try? await client.status().rulesDirectory, reported != rulesDirectory {
                rulesDirectory = reported
            }
        } catch {
            // Keep the last report on screen; say why it may be stale.
            loadState = .failed(DaemonFault(error))
        }
    }

    func reload() async {
        reloading = true
        defer { reloading = false }
        await perform { try await $0.reloadRules() }
    }

    func setEnabled(_ id: RuleSummary.ID, _ enabled: Bool) async {
        await perform { try await $0.setRule(id, enabled: enabled) }
    }

    func loadLogs(for rule: RuleSummary) async {
        // A reply for a rule that is no longer selected must not replace the
        // logs of the one that is.
        defer { if selection == rule.id, logsRule != rule.id { logsRule = rule.id } }
        do {
            var entries = try await fetchLogs(rule.id)
            if rule.id != rule.file {
                entries += try await fetchLogs(rule.file)
            }
            entries.sort { $0.time > $1.time }
            var ids = OccurrenceIDs()
            let listed = entries.map { entry in
                ListedLogEntry(id: ids.next("\(entry.time)|\(entry.rule ?? "")|\(entry.message)"), entry: entry)
            }
            guard selection == rule.id else { return }
            if listed.map(\.id) != logs.map(\.id) { logs = listed }
            if logsError != nil { logsError = nil }
        } catch {
            guard selection == rule.id else { return }
            logs = []
            logsError = "\(error)"
        }
    }

    // MARK: - Watching

    /// Follows `meerkat.rule` for the window's lifetime, refreshing the
    /// report when a rule loads, fails, is disabled or unloads. Retries while
    /// the daemon is unreachable.
    func followStateChanges() async {
        await refresh()
        while !Task.isCancelled {
            do {
                for try await _ in try await client.subscribe("meerkat.rule") {
                    scheduleRefresh()
                }
            } catch {
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: Self.pollInterval)
            await refresh()
        }
    }

    /// Polls counts and the selected rule's logs while the Rules page is on
    /// screen; cancelled with the page's task.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            if let rule = selectedRule { await loadLogs(for: rule) }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    // MARK: - Private

    /// A reload changes many rules at once; one refresh covers the burst.
    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.pendingRefresh = nil
            await self.refresh()
        }
    }

    private func perform(_ action: (any DaemonConnection) async throws -> RulesReport) async {
        do {
            apply(try await action(client))
            actionError = nil
        } catch {
            actionError = "\(error)"
        }
    }

    private func apply(_ report: RulesReport) {
        if report != self.report {
            self.report = report
            diagnostics = Self.listed(report.diagnostics)
            lintFindings = Self.listed(report.lint?.diagnostics ?? [])
        }
        if loadState != .loaded { loadState = .loaded }
    }

    private static func listed(_ diagnostics: [RuleDiagnostic]) -> [ListedDiagnostic] {
        var ids = OccurrenceIDs()
        return diagnostics.map { ListedDiagnostic(id: ids.next($0.description), diagnostic: $0) }
    }

    private func fetchLogs(_ rule: String) async throws -> [RuleLogEntry] {
        try await client.logs(rule: rule, limit: Self.logLimit)
    }
}

/// List identities for rows that may repeat: a row's content, plus how many
/// identical rows came before it.
private struct OccurrenceIDs {
    private var seen: [String: Int] = [:]

    mutating func next(_ content: String) -> String {
        let occurrence = seen[content, default: 0]
        seen[content] = occurrence + 1
        return "\(content)#\(occurrence)"
    }
}
