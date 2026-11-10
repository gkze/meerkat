import Foundation
import MeerkatKit
import MeerkatRules
import MeerkatStore
import Testing

@testable import MeerkatDaemon

/// The repository root.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// `MEERKAT_TSRS` (which `buck2 test` sets to //buck2/third_party/js's tsrs),
/// else the repository's Sources/meerkat-rules/node_modules.
func typeScriptToolchain() throws -> TypeScriptToolchain {
    try #require(
        TypeScriptToolchain.locate(executable: repositoryRoot.appendingPathComponent(".build/x")),
        "run `bun install` in Sources/meerkat-rules/, or set MEERKAT_TSRS")
}

/// A name no other test uses, for a notification or a Darwin channel.
func uniqueName() -> String {
    "com.gkze.meerkat.test.\(UUID().uuidString)"
}

/// A path under the temporary directory no other test uses; nothing is
/// created there.
func temporaryURL(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

extension RuleDefinition {
    /// For tests about something other than observation: nothing is
    /// protected, so the rule's grants alone decide what it may observe.
    init(file: String, raw: JSONValue, catalog: EventCatalog) throws {
        try self.init(file: file, raw: raw, catalog: catalog, observation: ObservationScope(protectedRead: []))
    }
}

/// A notifier that posts nothing.
struct SilentNotifier: Notifier {
    func post(_ plan: NotificationPlan) async throws {}
    func withdraw(identifier: String) async throws {}
}

/// An engine and its dry runner over `hub` and `store`, wired as `Daemon`
/// wires them: one executor, whose authorizer the engine hands the runner.
func ruleEngine(
    _ configuration: RuleEngine.Configuration, hub: EventHub, store: RuleStore, notifier: any Notifier,
    sampleDatabase: URL, permissionStatus: @escaping EventDescriptor.Permission.StatusReader = { $0.status }
) -> (engine: RuleEngine, runner: RuleDryRunner) {
    let executor = EffectExecutor(
        store: store, ownProcesses: hub.environment.ownProcesses, notifier: notifier,
        sampleDatabasePath: sampleDatabase.path,
        authorizer: EffectAuthorizer(permissionStatus: permissionStatus, protectedPaths: configuration.protected.write))
    let engine = RuleEngine(configuration: configuration, hub: hub, store: store, executor: executor)
    return (engine, RuleDryRunner(engine: engine, hub: hub, store: store))
}
