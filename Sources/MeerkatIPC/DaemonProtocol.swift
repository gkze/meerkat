import Foundation
import MeerkatKit

/// Names shared by the daemon, its launchd plist and its clients.
public enum DaemonService {
    /// launchd label of the agent and the plist's file name without `.plist`.
    public static let label = "com.gkze.meerkat.daemon"
    public static let plistName = label + ".plist"
    /// The XPC Mach service the daemon listens on.
    public static let machService = label
    /// Bundle identifier of Meerkat.app, which contains every executable.
    public static let bundleIdentifier = "com.gkze.meerkat"
    /// The executables in Meerkat.app's `AppBundle.executables`, as the
    /// bundler places them and the agent's plist and its clients name them.
    public static let appExecutable = "MeerkatApp"
    public static let daemonExecutable = "meerkatd"
    public static let cliExecutable = "meerkat"
    /// The daemon's bundle identifier, also the launchd label and the Mach
    /// service: one name for the agent and the bundle people see.
    public static let daemonBundleIdentifier = label
    /// The daemon as the agent's plist names it (`BundleProgram`), relative
    /// to the bundle.
    public static let daemonProgram = AppBundle.daemonBundle + "/" + AppBundle.executables + "/" + daemonExecutable
    /// The CLI, relative to the bundle: what an MCP client starts and a
    /// `meerkat` on PATH links to.
    public static let cliPath = AppBundle.executables + "/" + cliExecutable
    /// The agent's plist, relative to the bundle, where `SMAppService`
    /// looks for it.
    public static let agentPlist = AppBundle.launchAgents + "/" + plistName
    /// Where the bundler's `--install` puts Meerkat.app, relative to the
    /// home folder, and so where the help and the errors point people.
    public static let installedApp = "Applications/Meerkat.app"
    /// `meerkat agent install`'s exit status when the agent registered but
    /// no daemon from this build answered (sysexits' `EX_TEMPFAIL`): the one
    /// outcome worth trying again, which the Bundler does.
    public static let registeredButSilentExit: Int32 = 75
    /// The CLI's exit status when the daemon is not available (sysexits'
    /// `EX_UNAVAILABLE`), which the agent skills tell agents to look for.
    public static let unavailableExit: Int32 = 69
}

// MARK: - Requests

/// One request from a client (CLI or app) to the daemon over XPC.
public enum DaemonRequest: Codable, Sendable, Equatable {
    /// Cheap liveness check; clients use the answer to notice a restarted
    /// daemon, whose subscriptions are gone.
    case ping
    case status
    case catalog
    /// Start streaming `kind` to this session. Events arrive as
    /// `DaemonPush.event` carrying `subscription`, which the client chooses
    /// and must keep unique within its session.
    case subscribe(subscription: UInt64, kind: String, parameters: JSONValue)
    case unsubscribe(subscription: UInt64)
    case rules
    /// Re-read and recompile the rules directory now.
    case reloadRules
    case setRuleEnabled(rule: String, enabled: Bool)
    case ruleLogs(rule: String?, limit: Int)
    /// One JSON-RPC message from an MCP client, as `meerkat mcp` read it
    /// from stdin, without its line ending (docs/design/mcp.md). The daemon
    /// replies `done` once the message is queued for this session's MCP
    /// server; answers and notifications come back as `DaemonPush.mcp`.
    /// Messages on one session are handled in the order they are sent.
    case mcp(message: Data)
    /// Compile unsaved rule text and run one rule on events with effects
    /// captured, not performed. Answers `dryRun`, or `failure` for a request
    /// that can't run (one dry run at a time). The answer can take as long as
    /// the sample and the handlers do.
    case dryRun(DryRunRequest)

    /// The largest `mcp` message, in bytes: larger than any request the MCP
    /// server understands needs to be. The daemon refuses larger ones, and
    /// `meerkat mcp` refuses them before sending, which bounds its own
    /// memory.
    public static let mcpMessageLimit = 4 << 20
}

/// One run of the daemon. launchd replacing it changes both fields, and a
/// new daemon has none of its predecessor's subscriptions.
public struct DaemonIdentity: Codable, Sendable, Hashable {
    public let pid: Int32
    /// Unix epoch milliseconds.
    public let startedAt: Double

    public init(pid: Int32, startedAt: Double) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// The daemon's answer to one request.
public enum DaemonReply: Codable, Sendable, Equatable {
    case pong(pid: Int32, startedAt: Double)
    case status(DaemonStatus)
    case catalog([CatalogEntry])
    /// `daemon` is the run that holds the subscription, so a client can
    /// tell which of its subscriptions a restart took away.
    case subscribed(parameters: JSONValue, daemon: DaemonIdentity)
    case rules(RulesReport)
    case logs([RuleLogEntry])
    case dryRun(DryRunReport)
    case done
    case failure(String)
    /// The daemon could not decode the request: the client is a different
    /// build (for example, the daemon has not restarted since an upgrade).
    case undecodableRequest(String)
}

/// Unsolicited messages from the daemon to one session.
public enum DaemonPush: Codable, Sendable, Equatable {
    case event(subscription: UInt64, envelope: EventEnvelope)
    /// The daemon ended a subscription (its source failed); the client should
    /// not expect more events for it.
    case ended(subscription: UInt64, reason: String)
    /// One JSON-RPC message from this session's MCP server to its client.
    case mcp(message: Data)
}

// MARK: - Payloads

public struct DaemonStatus: Codable, Sendable, Equatable {
    public let version: String
    public let pid: Int32
    /// Unix epoch milliseconds.
    public let startedAt: Double
    public let executablePath: String
    public let rulesDirectory: String
    public let handlerHost: HandlerHostStatus
    public let sources: [SourceStatistics]
    public let rules: [RuleSummary]
    /// `meerkat.json` as the daemon applies it.
    public let configuration: ConfigurationStatus

    public init(
        version: String, pid: Int32, startedAt: Double, executablePath: String,
        rulesDirectory: String, handlerHost: HandlerHostStatus,
        sources: [SourceStatistics], rules: [RuleSummary], configuration: ConfigurationStatus
    ) {
        self.configuration = configuration
        self.version = version
        self.pid = pid
        self.startedAt = startedAt
        self.executablePath = executablePath
        self.rulesDirectory = rulesDirectory
        self.handlerHost = handlerHost
        self.sources = sources
        self.rules = rules
    }
}

/// The rule runtime: Deno, embedded in the daemon, with a worker per loaded
/// rule file.
public struct HandlerHostStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// No rules are loaded, so no runtime runs.
        case idle
        case starting, running
        /// Waiting before a restart after a crash or a stalled handler.
        case backingOff
        /// The runtime or the TypeScript compiler is missing.
        case unavailable
    }

    public let state: State
    /// Rule files loaded into the running host, each in its own worker.
    public let workers: Int
    public let restarts: Int
    public let lastExit: String?

    public init(state: State, workers: Int, restarts: Int, lastExit: String?) {
        self.state = state
        self.workers = workers
        self.restarts = restarts
        self.lastExit = lastExit
    }
}

public struct RuleSummary: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case loaded, failed, disabled
    }

    /// `<file>#<name>`.
    public let id: String
    public let file: String
    public let event: String?
    public let state: State
    public let reason: String?
    public let invocations: Int
    public let failures: Int
    /// Unix epoch milliseconds.
    public let lastInvokedAt: Double?
    public let lastError: String?

    public init(
        id: String, file: String, event: String?, state: State, reason: String?,
        invocations: Int, failures: Int, lastInvokedAt: Double?, lastError: String?
    ) {
        self.id = id
        self.file = file
        self.event = event
        self.state = state
        self.reason = reason
        self.invocations = invocations
        self.failures = failures
        self.lastInvokedAt = lastInvokedAt
        self.lastError = lastError
    }
}

public struct RulesReport: Codable, Sendable, Equatable {
    /// Where the daemon reads rules, as it resolved the path when it started.
    public let rulesDirectory: String
    public let rules: [RuleSummary]
    /// Compile and load problems; each one kept its file's rules from
    /// loading.
    public let diagnostics: [RuleDiagnostic]
    /// Unix epoch milliseconds of the last compile.
    public let compiledAt: Double?
    /// The last lint of the rules directory. Nil before the first one
    /// finishes, and when the daemon has no lint toolchain.
    public let lint: LintReport?

    public init(
        rulesDirectory: String, rules: [RuleSummary], diagnostics: [RuleDiagnostic], compiledAt: Double?,
        lint: LintReport? = nil
    ) {
        self.rulesDirectory = rulesDirectory
        self.rules = rules
        self.diagnostics = diagnostics
        self.compiledAt = compiledAt
        self.lint = lint
    }
}

public struct CatalogEntry: Codable, Sendable, Equatable {
    public let descriptor: EventDescriptor
    /// TypeScript type of the payload.
    public let payloadType: String
    /// TypeScript type of `params`.
    public let parametersType: String

    public init(descriptor: EventDescriptor, payloadType: String, parametersType: String) {
        self.descriptor = descriptor
        self.payloadType = payloadType
        self.parametersType = parametersType
    }

    public static func entries(_ catalog: EventCatalog = .standard) -> [CatalogEntry] {
        catalog.kinds.map {
            CatalogEntry(
                descriptor: $0.descriptor,
                payloadType: TypeScriptDeclarations.inlineType($0.payloadSchema),
                parametersType: TypeScriptDeclarations.inlineType(.object($0.parametersSchema)))
        }
    }
}
