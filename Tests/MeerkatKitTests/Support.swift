import Foundation
import MeerkatKit

/// A name no other test uses, for a notification or a Darwin channel.
func uniqueName() -> String {
    "com.gkze.meerkat.test.\(UUID().uuidString)"
}

/// A path under the temporary directory no other test uses; nothing is
/// created there.
func temporaryURL(_ prefix: String, suffix: String = "") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)\(suffix)")
}

/// The next event matching `predicate`, or nil after `timeout`. A timeout
/// cancels the iteration, which ends the subscription.
func nextEvent(
    _ subscription: EventSubscription, timeout: Duration = .seconds(10),
    where predicate: @escaping @Sendable (EventEnvelope) -> Bool = { _ in true }
) async -> EventEnvelope? {
    await withTaskGroup(of: EventEnvelope?.self) { group in
        group.addTask {
            for await envelope in subscription.events where predicate(envelope) { return envelope }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Whether `condition` holds by `timeout`, checked every 10 ms. For a
/// positive assertion about something that happens asynchronously, in place
/// of a fixed sleep that is either too short on a busy machine or wasted.
func eventually(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
}

/// Runs a tool and returns its standard output; throws on a non-zero exit.
func runTool(_ tool: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolError(description: "\(tool) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
    }
    return data
}
