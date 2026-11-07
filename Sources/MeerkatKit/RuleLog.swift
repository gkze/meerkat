/// How a rule's log line is marked.
public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case debug, info, warn, error
}

public struct RuleLogEntry: Codable, Sendable, Equatable {
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
