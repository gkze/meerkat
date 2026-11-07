import ArgumentParser
import Foundation

/// Exit statuses with a meaning of their own, from sysexits(3). Everything
/// else that fails is 1; ArgumentParser makes a usage error 64.
enum ExitStatus {
    /// A file or folder named on the command line does not exist.
    static let noInput: Int32 = 66
    /// What the command needs is not there: the daemon, or the tools the
    /// app ships.
    static let unavailable: Int32 = 69
}

/// Why a command failed and the status it exits with. Commands throw this
/// rather than printing and exiting, so `Meerkat.main` is the one place a
/// failure is written: as a line of text, or under `--json` as one JSON
/// object, both on stderr.
///
/// A failed check is not one of these: its findings are its output, on
/// stdout, and it exits 1 with nothing more to say (`ExitCode.failure`).
struct CommandFailure: Error, CustomStringConvertible {
    let message: String
    let status: Int32

    init(_ message: String, status: Int32 = EXIT_FAILURE) {
        self.message = message
        self.status = status
    }

    var description: String { message }
}

/// A command whose output `--json` makes JSON. Its failures are then JSON
/// too. `CLITests` holds every command to having this or a stated reason
/// not to, so the contract can't lapse for a new one.
protocol JSONOutput {
    var json: Bool { get }
}

/// A command whose output is JSON without `--json`. A usage error, found
/// before there is a command to ask, is JSON for these by their type.
protocol AlwaysJSONOutput: JSONOutput {}

extension AlwaysJSONOutput {
    var json: Bool { true }
}

/// What a failure under `--json` writes to stderr, as one line.
struct FailureReport: Encodable, Equatable {
    struct Detail: Encodable, Equatable {
        let status: Int32
        let message: String
    }

    let error: Detail
}

extension Meerkat {
    /// Parses and runs the command, then reports what it threw.
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command: any ParsableCommand
        do {
            command = try parseAsRoot(arguments)
        } catch {
            // A usage error, before any command exists to ask for JSON. As
            // text it keeps ArgumentParser's form, with the usage; help and
            // --version go to stdout that way too.
            guard wantsJSON(arguments), exitCode(for: error).rawValue != EXIT_SUCCESS else { exit(withError: error) }
            fail(error, json: true)
        }
        do {
            if var command = command as? any AsyncParsableCommand {
                try await command.run()
            } else {
                var command = command
                try command.run()
            }
        } catch {
            fail(error, json: (command as? any JSONOutput)?.json == true)
        }
    }

    /// Writes what `error` says, if anything, and exits with its status.
    /// Help is not a failure: a command that names no operation (a bare
    /// `meerkat`, `meerkat config`) shows it on stdout and exits 0, as
    /// ArgumentParser does.
    static func fail(_ error: any Error, json: Bool) -> Never {
        let (status, message) = outcome(of: error)
        if status == EXIT_SUCCESS { exit(withError: error) }
        if let message { writeFailure(message, status: status, json: json) }
        Foundation.exit(status)
    }

    /// Whether a failure to parse `arguments` is written as JSON: they ask
    /// for it, before any `--`, or name a command that always prints it.
    static func wantsJSON(_ arguments: [String]) -> Bool {
        arguments.prefix { $0 != "--" }.contains("--json") || commandType(named: arguments) is any AlwaysJSONOutput.Type
    }

    /// The deepest command `arguments` name, as far as they name one.
    static func commandType(named arguments: [String]) -> any ParsableCommand.Type {
        var command: any ParsableCommand.Type = Meerkat.self
        for argument in arguments {
            guard let next = command.configuration.subcommands.first(where: { $0._commandName == argument }) else {
                break
            }
            command = next
        }
        return command
    }

    /// The status `error` exits with, and what to say, if anything: a bare
    /// `ExitCode` comes from a command that has already said what failed.
    static func outcome(of error: any Error) -> (status: Int32, message: String?) {
        switch error {
        case let failure as CommandFailure: (failure.status, failure.message)
        case let exit as ExitCode: (exit.rawValue, nil)
        default: (exitCode(for: error).rawValue, message(for: error))
        }
    }

    static func writeFailure(_ message: String, status: Int32, json: Bool) {
        guard json else { return stderrLine(message) }
        stderrLine(failureLine(message, status: status))
    }

    /// `FailureReport` as the one line `--json` writes.
    static func failureLine(_ message: String, status: Int32) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let report = FailureReport(error: .init(status: status, message: message))
        return (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? message
    }
}
