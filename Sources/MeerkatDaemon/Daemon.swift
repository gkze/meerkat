import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatRules
import MeerkatStore
import os

extension DaemonPaths {
    /// What no rule's code may touch through Deno's APIs, whatever its
    /// grants. Rules reach the daemon's state only through effects, which
    /// keep each rule's state its own; and a rule that could write rules, or
    /// the app it runs from, could widen its own grants.
    ///
    /// `meerkat.json` is listed beside the rules folder because it may be a
    /// symlink out of it (a dotfiles setup), and what a protected path leads
    /// to is protected too.
    ///
    /// Each path is listed as named and, where symlinks lead elsewhere, as
    /// resolved: Deno compares the paths a call names with its lists as text.
    /// The runtime holds both lists to real paths on every call besides
    /// (meerkat-runtime, protected.rs), every symlink on each path's way
    /// included, which also covers links made later.
    func protected(executable: URL) -> RuleEngine.ProtectedPaths {
        let state = ruleDatabase.deletingLastPathComponent().standardizedFileURL.path
        let samples = sampleDatabase.standardizedFileURL.path
        let rules = rulesDirectory.standardizedFileURL
        var write = [
            rules.path, DaemonPaths.configurationFile(in: rules).path,
            cacheDirectory.standardizedFileURL.path, state, samples, samples + "-wal", samples + "-shm",
            DaemonPaths.preferencesFile.path,
        ]
        // Contents/MacOS/meerkatd inside Meerkat.app.
        let bundle = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        if bundle.pathExtension == "app" { write.append(bundle.path) }
        let withResolved = { (paths: [String]) in
            paths.flatMap { path in
                let resolved = CapabilityGrants.resolved(path)
                return resolved == path ? [path] : [path, resolved]
            }
        }
        return RuleEngine.ProtectedPaths(read: withResolved([state]), write: withResolved(write))
    }
}

extension EventHub {
    /// Why `subscription`'s stream ended without being cancelled, as every
    /// part of the daemon that sees it end says so: the source's own reason
    /// when it failed.
    func stopReason(of subscription: EventSubscription) -> String {
        endReason(of: subscription).map { "its event source failed: \($0)" } ?? "its event source stopped"
    }
}

/// The assembled daemon: hub, rule engine, and the XPC server with its MCP
/// service.
public final class Daemon: Sendable {
    public let hub: EventHub
    let engine: RuleEngine
    let dryRunner: RuleDryRunner
    private let server: DaemonServer
    private let responder: NotificationResponder
    private let paths: DaemonPaths
    private let startedAt = Date()
    private let logger = Logger(subsystem: DaemonService.label, category: "daemon")

    /// - Parameters:
    ///   - runtime: what rules are compiled against and run in; nil runs no
    ///     rules (meerkatd passes the embedded Deno runtime).
    ///   - lintToolchain: what lints the rules directory on each reload; nil
    ///     lints nothing.
    public init(
        paths: DaemonPaths = .standard(), runtime: HandlerRuntime?,
        toolchain: TypeScriptToolchain? = TypeScriptToolchain.locate(),
        lintToolchain: LintToolchain? = LintToolchain.locate()
    ) throws {
        self.paths = paths
        try FileManager.default.createDirectory(
            at: paths.ruleDatabase.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let hub = EventHub()
        let store = try RuleStore(path: paths.ruleDatabase.path)
        let settings = DaemonSettings(rulesDirectory: paths.rulesDirectory, catalog: hub.catalog)
        // fs.churn without a root measures meerkat.json's `files`, read per window.
        hub.environment.provideFileScope { settings.current.files.scope }
        let protected = paths.protected(executable: .currentExecutable)
        // One authorizer for what runs and what a dry run simulates, so a
        // draft is refused exactly as the saved rule will be.
        let authorizer = EffectAuthorizer(permissionStatus: { $0.status }, protectedPaths: protected.write)
        let executor = EffectExecutor(
            store: store, ownProcesses: hub.environment.ownProcesses,
            notifier: UserNotifier(), sampleDatabasePath: paths.sampleDatabase.path, authorizer: authorizer,
            sampleLimits: { settings.sampleLimits })
        let engine = RuleEngine(
            configuration: .init(
                rulesDirectory: paths.rulesDirectory, cacheDirectory: paths.cacheDirectory,
                toolchain: toolchain, runtime: runtime, linter: lintToolchain.map(RuleLinter.init),
                protected: protected, settings: settings),
            hub: hub, store: store, executor: executor
        )
        // The engine's loader and authorizer, never its executor: see
        // `RuleDryRunner`.
        let dryRunner = RuleDryRunner(engine: engine, hub: hub, store: store)
        self.dryRunner = dryRunner
        self.hub = hub
        self.engine = engine
        let logger = self.logger
        responder = NotificationResponder(
            deliver: { [internalEvents = hub.environment.internalEvents] in internalEvents.send(.notification($0)) },
            dropped: { logger.warning("\($0, privacy: .public)") })
        // Before the first post, so responses to notifications from before a
        // restart reach the rules.
        responder.install()
        let startedAt = self.startedAt
        let rulesDirectory = paths.rulesDirectory.path
        let status: @Sendable () async -> DaemonStatus = {
            let report = await engine.report()
            return DaemonStatus(
                version: Daemon.version,
                pid: getpid(),
                startedAt: startedAt.timeIntervalSince1970 * 1000,
                executablePath: URL.currentExecutable.path,
                rulesDirectory: rulesDirectory,
                handlerHost: await engine.hostStatus(),
                sources: hub.statistics(),
                rules: report.rules,
                configuration: settings.status
            )
        }
        server = DaemonServer(
            hub: hub, engine: engine, dryRunner: dryRunner,
            mcp: MCPService(
                hub: hub, engine: engine, dryRunner: dryRunner, sampleDatabase: paths.sampleDatabase,
                policy: { settings.policy },
                configuration: { settings.status }, status: status,
                permissionStatus: authorizer.permissionStatus),
            startedAt: startedAt.timeIntervalSince1970 * 1000, status: status)
    }

    /// Starts the rule engine and, when `listen` is set, the XPC listener.
    public func start(listen: Bool = true) async throws {
        logger.info(
            "meerkatd \(Daemon.version, privacy: .public) starting; rules in \(self.paths.rulesDirectory.path, privacy: .public)"
        )
        if listen { try server.start() }
        await engine.start()
    }

    public func stop() async {
        await server.stop()
        await engine.shutdown()
    }

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
