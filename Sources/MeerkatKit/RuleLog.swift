/// How a rule's log line is marked.
public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case debug, info, warn, error
}

public struct RuleLogEntry: Codable, Sendable, Equatable {
    /// How many entries one read of a rule's log may ask for; every reader
    /// (the CLI, XPC, MCP) holds a request to it.
    public static let readLimits = 1...10_000

    /// `limit` within `readLimits`.
    public static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, readLimits.lowerBound), readLimits.upperBound)
    }

    public let rule: String?
    /// Unix epoch milliseconds.
    public let time: Double
    public let level: LogLevel
    public let message: String

    public init(rule: String?, time: Double, level: LogLevel, message: String) {
        self.rule = rule
        self.time = time
        self.level = level
        self.message = message
    }
}

/// A TypeScript compiler diagnostic, a load error, a lint finding, or a tool
/// that did not run. Which tool produced it decides what it means: compiler
/// and loader diagnostics keep a file's rules from loading, and the rest are
/// advice, whatever their severity.
public struct RuleDiagnostic: Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Tool: String, Codable, Sendable, CaseIterable {
        /// tsrs's compile, which decides what loads.
        case compiler
        /// The host's evaluation of a compiled file and the daemon's decoding
        /// of the rules it returns.
        case loader
        case oxlint
        case meerkatLint = "meerkat-lint"
        case oxfmt

        /// The compiler and the loader decide what loads; the rest advise.
        public var isLoadGate: Bool { self == .compiler || self == .loader }
    }

    /// As the tool reported it. Oxlint reports most findings as errors, and
    /// they are still advice: use `blocksLoading` for whether one matters.
    public enum Severity: String, Codable, Sendable {
        case error, warning
    }

    public enum Kind: String, Codable, Sendable {
        /// About the rules: a type error, a load error, a lint finding, an
        /// unformatted file.
        case finding
        /// The tool did not run, or exited without reporting why.
        case toolFailure
    }

    public let tool: Tool
    public let kind: Kind
    public let severity: Severity
    /// Relative to the rules directory, or absolute outside it (the generated
    /// declarations). Nil when the diagnostic is about no file: a compiler
    /// error without a location, or a tool that did not run.
    public let file: String?
    public let line: Int?
    public let column: Int?
    /// The tool's own identifier: `TS2322`, `eslint(no-console)`,
    /// `meerkat(rule-exported)`. Nil when the tool gives none.
    public let code: String?
    public let message: String
    /// Whether the tool's fix mode fixes it. Nil when the tool does not say
    /// (Oxlint and meerkat-lint report findings without it).
    public let fixable: Bool?

    public init(
        tool: Tool, kind: Kind = .finding, severity: Severity = .error, file: String?, line: Int? = nil,
        column: Int? = nil, code: String? = nil, message: String, fixable: Bool? = nil
    ) {
        self.tool = tool
        self.kind = kind
        self.severity = severity
        self.file = file
        self.line = line
        self.column = column
        self.code = code
        self.message = message
        self.fixable = fixable
    }

    /// A tool that did not run, or exited without saying why. Nothing a fix
    /// mode could fix.
    public static func toolFailure(_ tool: Tool, file: String? = nil, message: String) -> RuleDiagnostic {
        RuleDiagnostic(tool: tool, kind: .toolFailure, file: file, message: message, fixable: false)
    }

    public var blocksLoading: Bool { tool.isLoadGate }

    /// `file:line:column`, or the tool in parentheses when there is no file.
    public var location: String {
        guard let file else { return "(\(tool.rawValue))" }
        let position = [line, column].compactMap { $0.map(String.init) }.joined(separator: ":")
        return position.isEmpty ? file : "\(file):\(position)"
    }

    public var description: String {
        code.map { "\(location): \($0): \(message)" } ?? "\(location): \(message)"
    }
}

/// Oxlint, meerkat-lint and Oxfmt findings for the rules directory, and
/// tsrs's when run from the CLI. Advice only: a finding never stops a rule
/// from loading; the compile decides that.
public struct LintReport: Codable, Sendable, Equatable {
    public let diagnostics: [RuleDiagnostic]
    /// Unix epoch milliseconds the lint started.
    public let lintedAt: Double

    public init(diagnostics: [RuleDiagnostic], lintedAt: Double) {
        self.diagnostics = diagnostics
        self.lintedAt = lintedAt
    }
}

/// What Meerkat keeps inside a rules directory, which the compile, the
/// linters, the watcher and `meerkat.json`'s schema path all name.
public enum RulesDirectoryLayout {
    /// Editor support the daemon rewrites (declarations, compiler options,
    /// the lint policy, `meerkat.json`'s schema): never a rule source, and
    /// no edit to it is a reason to reload.
    public static let supportDirectory = ".meerkat"
}

extension String {
    /// The longest prefix of at most `limit` UTF-8 bytes that ends on a
    /// character boundary: how a rule's log line is cut to the runtime's
    /// limit, which counts bytes, without splitting a character.
    public func prefix(utf8Bytes limit: Int) -> String {
        guard utf8.count > limit else { return self }
        var end = startIndex
        var bytes = 0
        for index in indices {
            let next = self.index(after: index)
            bytes += self[index..<next].utf8.count
            guard bytes <= limit else { break }
            end = next
        }
        return String(self[..<end])
    }
}
