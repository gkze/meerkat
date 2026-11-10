import Foundation
import Synchronization

// MARK: - log.entry

public struct LogEntryPayload: EventPayload, Equatable {
    public enum Level: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case `default`, info, debug, error, fault
    }

    public let timestamp: Double
    public let process: String
    public let pid: Int32
    public let sender: String?
    public let subsystem: String?
    public let category: String?
    public let level: Level?
    public let message: String

    public static var schema: TypeSchema {
        .named(
            "LogEntry",
            ObjectSchema([
                .field("timestamp", Double.self, doc: "When the entry was logged, Unix epoch milliseconds."),
                .field("process", String.self, doc: "Name of the logging process's executable."),
                .field("pid", Int32.self),
                .optional(
                    "sender", String.self,
                    doc: "Name of the library or executable that called os_log, when not the process itself."),
                .optional(
                    "subsystem", String.self, doc: "os_log subsystem, e.g. \"com.apple.bluetooth\"; absent when empty."),
                .optional("category", String.self, doc: "os_log category; absent when empty."),
                .optional("level", Level.self),
                .field(
                    "message", String.self,
                    doc: "The formatted message. Values the logger marked private appear as \"<private>\"."),
            ]))
    }

    public static var examples: [Self] {
        [
            Self(
                timestamp: 1_792_901_240_302, process: "bluetoothd", pid: 412, sender: "CoreBluetooth",
                subsystem: "com.apple.bluetooth", category: "Server", level: .error, message: "Connection timed out"),
            Self(
                timestamp: 1_792_901_240_310, process: "logger", pid: 71_824, sender: nil, subsystem: nil,
                category: nil,
                level: .default, message: "hello"),
        ]
    }

    /// The fields of one `log stream --style ndjson` line an entry is made
    /// of, decoded once. `log` writes the line; whoever logged controls
    /// its text.
    private struct Line: Decodable {
        let eventType: String?
        let eventMessage: String?
        let processImagePath: String?
        let senderImagePath: String?
        let processID: Int32?
        let subsystem: String?
        let category: String?
        let messageType: String?
        let timestamp: String?
    }

    /// A `logEvent` line without what every entry states: skipped and
    /// counted, never filled with an invented value.
    struct MalformedLine: Error, CustomStringConvertible {
        let description: String
    }

    /// One `log stream --style ndjson` line. Nil for lines that are not a
    /// log event (activity or signpost records); throws `MalformedLine` for
    /// one that is not JSON of that shape, or a log event without its
    /// message, process, pid or a readable timestamp.
    static func parse(_ line: Data, decoder: JSONDecoder, timestamps: DateFormatter) throws -> Self? {
        let fields: Line
        do {
            fields = try decoder.decode(Line.self, from: line)
        } catch {
            throw MalformedLine(description: "not a log record: \(error)")
        }
        guard fields.eventType == "logEvent" else { return nil }
        guard let message = fields.eventMessage, let path = fields.processImagePath, let pid = fields.processID
        else { throw MalformedLine(description: "a log event without its message, process or pid") }
        guard let date = fields.timestamp.flatMap(timestamps.date(from:)) else {
            throw MalformedLine(description: "a log event with an unreadable timestamp \(fields.timestamp ?? "(none)")")
        }
        func name(_ path: String?) -> String? {
            path.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func text(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let process = name(path) ?? ""
        let sender = name(fields.senderImagePath)
        return Self(
            timestamp: date.timeIntervalSince1970 * 1000,
            process: process,
            pid: pid,
            sender: sender == process ? nil : sender,
            subsystem: text(fields.subsystem),
            category: text(fields.category),
            level: fields.messageType.flatMap { Level(rawValue: $0.lowercased()) },
            message: message
        )
    }

    /// `2026-10-24 21:17:20.302696-0700`.
    static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }
}

public struct LogStreamParameters: EventParameters {
    public enum Level: String, Codable, Sendable, CaseIterable, SchemaDescribed {
        case `default`, info, debug
    }

    /// 4096 characters of any script, as the limit once counted.
    public static let maximumPredicateBytes = 16_384

    public var predicate: String
    public var level: Level

    public init(predicate: String, level: Level = .default) {
        self.predicate = predicate
        self.level = level
    }

    public static var objectSchema: ObjectSchema {
        ObjectSchema([
            ObjectSchema.Field(
                "predicate", .text(TextBounds(1...maximumPredicateBytes, pattern: .notBlank)),
                doc:
                    "`log stream --predicate` filter, e.g. `subsystem == \"com.apple.bluetooth\" AND messageType == error`. Required: the full log is thousands of entries a second."
            ),
            ObjectSchema.Field(
                "level", Level.schema, default: .string(Level.default.rawValue),
                doc: "Lowest level streamed: \"default\" (also error and fault), \"info\", or \"debug\"."),
        ])
    }

    public static var examples: [Self] {
        [
            Self(predicate: #"subsystem == "com.apple.bluetooth""#),
            Self(predicate: #"process == "logger""#, level: .info),
        ]
    }
}

public enum LogEntryEvent: EventKind {
    public static let descriptor = EventDescriptor(
        "log.entry",
        "A unified log message matching `predicate` was logged. Runs one `log stream` process per distinct predicate and level for as long as a rule subscribes. Activity and signpost records are not reported. A predicate `log` rejects, or a lone word `log` would read as a message search, fails the subscription with the reason. Under heavy logging, logd discards entries for a `log stream` that falls behind and says nothing, so entries can be missed, as can entries logged just after subscribing, before the stream is live.",
        mechanism: .push, semantics: .occurrence, loss: .lossy,
        observation: .named,
        source: "/usr/bin/log stream --style ndjson --type log"
    )

    public static func makeSource(
        _ parameters: LogStreamParameters, environment: SourceEnvironment,
        emit: Emitter<LogEntryPayload>
    ) throws -> any EventSource {
        var arguments = ["stream", "--style", "ndjson", "--type", "log", "--predicate", parameters.predicate]
        if parameters.level != .default { arguments += ["--level", parameters.level.rawValue] }
        return LogStreamSource(
            arguments: arguments, predicate: parameters.predicate, ownProcesses: environment.ownProcesses, emit: emit)
    }
}

/// Splits a byte stream into lines across reads. A line longer than
/// `maximumLineBytes` is discarded whole instead of buffered without bound.
struct LineBuffer {
    let maximumLineBytes: Int
    private var pending = Data()
    private var discarding = false

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// The lines `data` completes, without their newlines. The remainder is
    /// copied once per call, not once per line.
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            if discarding {
                discarding = false
            } else {
                lines.append(Data(pending[start..<newline]))
            }
            start = newline + 1
        }
        pending = Data(pending[start...])
        if pending.count > maximumLineBytes {
            pending.removeAll()
            discarding = true
        }
        return lines
    }
}

/// One `log stream` child process.
///
/// A dedicated thread drains its output pipe and hands raw chunks to a
/// private serial queue, which splits and parses them. Draining is kept off
/// that queue because logd discards entries for a client whose pipe stays
/// full, without telling it (hence `loss: lossy`), and parsing a burst is
/// slower than reading it. That narrows the loss; it cannot close it.
///
/// `start` returns once `log` has accepted the predicate (it prints a
/// "Filtering the log data using …" header first) or throws with its message
/// when it exits instead. It also throws when `log` read the predicate as a
/// lone word to search messages for.
///
/// Acceptance is not attachment: `log` prints that header before its stream
/// is live, and offers no later signal. An entry logged in that gap reaches
/// `log show` but never this source (docs/design/meerkatd.md).
///
/// The child is the daemon's own process (`origin: meerkat` in process
/// events). If the daemon is killed without `stop`, the child exits the
/// next time it writes to the closed pipe.
final class LogStreamSource: EventSource {
    static let executable = URL(fileURLWithPath: "/usr/bin/log")
    /// Longest line kept while waiting for its newline; a longer one is dropped.
    static let maximumLineBytes = 1 << 20
    /// A pipe holds at most 64 KiB, so one read never returns more.
    static let readSize = 1 << 16
    static let startTimeout: DispatchTimeInterval = .seconds(5)
    static let header = "Filtering the log data"

    private let arguments: [String]
    private let predicate: String
    private let ownProcesses: OwnProcesses
    private let emit: Emitter<LogEntryPayload>
    private let queue = DispatchQueue(label: "com.gkze.meerkat.log-stream", qos: .utility)
    /// Used only on `queue`.
    private let timestamps = LogEntryPayload.timestampFormatter()
    private let decoder = JSONDecoder()
    private let state = Mutex<State>(State())
    private let accepted = DispatchSemaphore(value: 0)
    /// Signalled at end of output, once every chunk has been queued.
    private let drained = DispatchSemaphore(value: 0)

    private struct State {
        var process: ProcessBox?
        var identity: ProcessIdentity?
        /// Set by `stop`. Output that arrives before `start` has recorded
        /// the process is still consumed: `log`'s header can come first.
        var stopped = false
        var lines = LineBuffer(maximumLineBytes: LogStreamSource.maximumLineBytes)
        var accepted = false
        /// The predicate `log` applies, from its header.
        var appliedPredicate: String?
        /// Non-JSON output before acceptance: `log`'s error message.
        var diagnostics = ""
        /// Lines skipped as malformed, and the last one's reason.
        var malformed = 0
        var lastMalformed: String?
    }

    /// Foundation's `Process` is not Sendable; this source only calls
    /// `run`, `terminate` and `isRunning`, which are safe from any thread.
    private struct ProcessBox: @unchecked Sendable {
        let value: Process
    }

    init(arguments: [String], predicate: String, ownProcesses: OwnProcesses, emit: Emitter<LogEntryPayload>) {
        self.arguments = arguments
        self.predicate = predicate
        self.ownProcesses = ownProcesses
        self.emit = emit
    }

    var detail: String? {
        state.withLock { state in
            let applied = state.appliedPredicate.map { "log applies: \($0)" }
            let skipped = state.lastMalformed.map { "skipped \(state.malformed) malformed line(s); last: \($0)" }
            let parts = [applied, skipped].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }

    /// The running `log` child, while there is one.
    var processIdentifier: pid_t? {
        state.withLock { $0.process?.value.processIdentifier }
    }

    func start() throws {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.accepted.signal() }
        try process.run()
        startReader(output.fileHandleForReading)
        let identity = ProcessTable.record(pid: process.processIdentifier)?.identity
        if let identity { ownProcesses.insert(identity) }
        state.withLock {
            $0.process = ProcessBox(value: process)
            $0.identity = identity
        }

        // Only the header counts as success. End of output or exit also wake
        // this wait, and at end of output `isRunning` can still be true.
        let woke = accepted.wait(timeout: .now() + Self.startTimeout) == .success
        // Lines already read are consumed in order before this runs.
        let (isAccepted, applied) = queue.sync { state.withLock { ($0.accepted, $0.appliedPredicate) } }
        if isAccepted {
            guard let applied, let word = Self.searchedWord(in: predicate, applied: applied) else { return }
            stop()
            throw EventError.invalidParameters(
                "\"predicate\" \(predicate) is not a predicate: log reads a lone word as a message search and would apply \(applied). Write eventMessage CONTAINS[cd] \"\(word)\" to search messages, or eventType == logEvent to match every entry."
            )
        }
        guard woke else {
            stop()
            throw EventError.sourceUnavailable("log stream printed nothing within \(Self.startTimeout)")
        }
        // Exit can be seen before the output is read: wait for all of it, so
        // the error carries log's own message.
        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + .seconds(1))
        let diagnostics = queue.sync { state.withLock(\.diagnostics) }
        stop()
        let message = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        throw EventError.sourceUnavailable(
            "log stream exited: \(message.isEmpty ? "status \(process.terminationStatus)" : message)")
    }

    func stop() {
        let (process, identity) = state.withLock { state in
            defer {
                state.process = nil
                state.identity = nil
                state.stopped = true
            }
            return (state.process, state.identity)
        }
        guard let process else { return }
        // The reader thread sees end of output once `log` exits.
        if process.value.isRunning { process.value.terminate() }
        if let identity { ownProcesses.remove(identity) }
        // Lines already queued must not be emitted after `stop` returns.
        queue.sync {}
    }

    /// Reads until end of output: `log` exiting, or `stop` terminating it.
    /// The thread holds `handle`, so the descriptor stays open (and cannot
    /// be reused for another file) until the thread is done with it.
    private func startReader(_ handle: FileHandle) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: Self.readSize)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0, let self else { break }
                let chunk = Data(buffer[..<count])
                self.queue.async { self.consume(chunk) }
            }
            self?.drained.signal()
            self?.accepted.signal()
            self?.queue.async { [weak self] in self?.outputEnded() }
        }
        thread.name = "com.gkze.meerkat.log-stream.reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs on `queue`.
    private func consume(_ data: Data) {
        let (entries, acceptedNow) = state.withLock { state -> ([Data], Bool) in
            guard !state.stopped else { return ([], false) }
            let wasAccepted = state.accepted
            var entries: [Data] = []
            for line in state.lines.append(data) {
                if line.first == UInt8(ascii: "{") {
                    entries.append(line)
                } else if !state.accepted, line.starts(with: Data(Self.header.utf8)) {
                    state.accepted = true
                    state.appliedPredicate = Self.appliedPredicate(inHeader: String(decoding: line, as: UTF8.self))
                } else if !state.accepted, state.diagnostics.utf8.count < 4096 {
                    state.diagnostics += String(decoding: line, as: UTF8.self) + "\n"
                }
            }
            return (entries, !wasAccepted && state.accepted)
        }
        if acceptedNow { accepted.signal() }
        for line in entries {
            do {
                if let entry = try LogEntryPayload.parse(line, decoder: decoder, timestamps: timestamps) {
                    emit(entry)
                }
            } catch {
                state.withLock { state in
                    state.malformed += 1
                    state.lastMalformed = "\(error)"
                }
            }
        }
    }

    /// Runs on `queue`, after every chunk. `log` exiting before acceptance
    /// is `start`'s error and after `stop` is expected; in between, the
    /// stream is gone and the subscribers must learn it.
    private func outputEnded() {
        guard state.withLock({ $0.accepted && !$0.stopped }) else { return }
        emit.fail("log stream exited while the source was running")
    }

    /// The predicate in `log`'s header, `Filtering the log data using
    /// "<predicate>"`. `log` does not escape quotes inside it, so only the
    /// outer pair is removed.
    static func appliedPredicate(inHeader header: String) -> String? {
        let header = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = Self.header + " using \""
        guard header.hasPrefix(prefix), header.hasSuffix("\""), header.count > prefix.count else { return nil }
        return String(header.dropFirst(prefix.count).dropLast())
    }

    /// The word `log` searches message text for when it read `predicate` as a
    /// lone word or quoted string (`TRUE`, `error`, even `TRUEPREDICATE`):
    /// it then applies `composedMessage CONTAINS[cd] "<word>"`. Nil when
    /// `log` used the predicate as written. Compared with what was written,
    /// because `eventMessage CONTAINS[cd] "TRUE"` is applied as the same
    /// string and is a deliberate search.
    static func searchedWord(in predicate: String, applied: String) -> String? {
        var word = predicate.trimmingCharacters(in: .whitespacesAndNewlines)
        if word.count >= 2, word.hasPrefix("\""), word.hasSuffix("\"") { word = String(word.dropFirst().dropLast()) }
        return applied.hasPrefix("composedMessage CONTAINS[cd] \"\(word)\"") ? word : nil
    }
}
