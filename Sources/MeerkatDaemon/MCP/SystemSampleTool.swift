import Foundation
import MeerkatIPC
import MeerkatKit

/// `system_sample`: one measurement window, as `meerkat sample` takes it
/// (docs/design/mcp.md, "Built-in surface"). It is what `meerkat-diagnose`
/// measures with, so a client with only MCP can follow the skill.
///
/// It reads what `process.top`, `cpu.sample` and `memory.sample` carry
/// (process names and paths among them) without subscribing to them, so it
/// is offered only while the policy allows all three: a client can't get
/// round a denied kind by asking for a sample. What none of them carries is
/// left out: path churn, which would read file paths under any folder the
/// client named (`fs.churn` through `events_sample` is where the policy
/// decides that), and the host name (`reply`).
struct SystemSampleTool: Sendable {
    let policy: MCPPolicy
    let catalog: EventCatalog

    static let name = "system_sample"
    /// The kinds whose data a sample carries.
    static let kinds = ["process.top", "cpu.sample", "memory.sample"]
    static let defaultWindow = 10.0
    static let defaultTop = 10
    static let maxTop = 50

    var defaultWindow: Double { min(Self.defaultWindow, policy.limits.sampleSeconds) }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The kinds the policy denies, in `kinds` order; empty when a sample
    /// may run.
    var deniedKinds: [String] {
        Self.kinds.filter { name in catalog.kind(named: name).map { !policy.allows($0) } ?? true }
    }

    func inputSchema() -> TypeSchema {
        let ceiling = EventSampler.format(policy.limits.sampleSeconds)
        return .object(
            ObjectSchema([
                .init(
                    "window", .number, optional: true,
                    doc:
                        "Seconds to measure CPU and disk over: more than 0, at most \(ceiling), default \(EventSampler.format(defaultWindow))."
                ),
                .init(
                    "top", .number, optional: true,
                    doc: "Processes to report, busiest first: 1 to \(Self.maxTop), default \(Self.defaultTop)."),
                .init(
                    "systemOnly", .boolean, optional: true,
                    doc: "Only processes whose executable ships with macOS."),
            ]))
    }

    /// Checks a call's arguments against the schema, the ranges and the
    /// policy, before anything is measured.
    func request(_ arguments: JSONValue) throws(Failure) -> SystemSampler.Options {
        let denied = deniedKinds
        guard denied.isEmpty else {
            throw Failure(
                description:
                    "system_sample reads what \(Self.kinds.joined(separator: ", ")) carry, and meerkat.json's mcp policy denies \(denied.joined(separator: ", "))"
            )
        }
        let problems = SchemaValidator.violations(of: arguments, against: inputSchema(), at: "arguments")
        guard problems.isEmpty else { throw Failure(description: problems.joined(separator: "; ")) }
        let window = arguments["window"]?.numberValue ?? defaultWindow
        guard window > 0, window <= policy.limits.sampleSeconds else {
            throw Failure(
                description:
                    "window must be more than 0 and at most \(EventSampler.format(policy.limits.sampleSeconds))")
        }
        let top = arguments["top"]?.numberValue ?? Double(Self.defaultTop)
        guard top >= 1, top <= Double(Self.maxTop), top.rounded() == top else {
            throw Failure(description: "top must be a whole number from 1 to \(Self.maxTop)")
        }
        return SystemSampler.Options(
            window: window, top: Int(top), systemOnly: arguments["systemOnly"]?.boolValue ?? false)
    }

    /// What a client gets: the sample without its host name. That is the
    /// network's (DNS) name, which `network.hostname` leaves out by design
    /// and none of `kinds` carries, so a policy that denies it would not
    /// keep it from a client otherwise. `meerkat sample` and the store,
    /// which the user reads, keep it.
    static func reply(_ sample: SystemSample) throws -> JSONValue {
        guard case .object(var fields) = try JSONValue(encoding: sample) else { return .object([:]) }
        fields["host"] = nil
        return .object(fields)
    }

    /// Takes the sample. The sampler sleeps through its window, so it runs
    /// on a dispatch thread rather than one of the few the daemon's actors
    /// share. It can't be interrupted: a cancelled call waits out the
    /// window, which the policy bounds, and holds its slot until then.
    static func run(_ options: SystemSampler.Options) async throws -> SystemSample {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SystemSample, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try SystemSampler.sample(options) })
            }
        }
    }
}
