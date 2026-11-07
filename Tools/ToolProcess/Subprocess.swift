import Foundation

// How the repository's tools (the bundler, the release plan, the remote build
// and the conformance checker) run other programs: one place that reads a
// child's output before waiting for it, as a child blocked on a full pipe
// would never exit, and that names a failed command and its status.

/// A program that exited with a status other than 0.
public struct SubprocessFailure: Error, CustomStringConvertible {
    public let command: [String]
    public let status: Int32

    public var description: String { "\(command.joined(separator: " ")) failed (\(status))" }
}

/// `executable` with `arguments`, run in `directory` (default: this
/// process's), with this process's environment and standard error.
public struct Subprocess: Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: URL?

    public init(_ executable: String, _ arguments: [String], in directory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
    }

    /// Runs it with this process's standard output; fails unless it exits 0.
    public func run() throws {
        let status = try launch(output: nil)
        guard status == 0 else { throw failure(status) }
    }

    /// Its standard output; fails unless it exits 0.
    public func output() throws -> String {
        let (status, output) = try outcome()
        guard status == 0 else { throw failure(status) }
        return output
    }

    /// Its exit status and standard output, whatever the status.
    public func outcome() throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        var data = Data()
        let status = try launch(output: pipe) { data = pipe.fileHandleForReading.readDataToEndOfFile() }
        return (status, String(decoding: data, as: UTF8.self))
    }

    private func launch(output: Pipe?, reading: () -> Void = {}) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if let output { process.standardOutput = output }
        try process.run()
        reading()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func failure(_ status: Int32) -> SubprocessFailure {
        SubprocessFailure(command: [executable] + arguments, status: status)
    }
}
