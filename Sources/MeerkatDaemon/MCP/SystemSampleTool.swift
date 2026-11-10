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
    static let maxTop = 50

    /// The sampler's own default, within what the policy allows.
    var defaultWindow: Double { min(SystemSampler.Options().window, policy.limits.sampleSeconds) }

    /// The kinds the policy denies, in `kinds` order; empty when a sample
    /// may run.
    var deniedKinds: [String] {
        Self.kinds.filter { name in catalog.kind(named: name).map { !policy.allows($0) } ?? true }
    }

    /// Why the policy hides the tool now, or nil.
    var denial: String? {
        let denied = deniedKinds
        guard !denied.isEmpty else { return nil }
        return
            "system_sample reads what \(Self.kinds.joined(separator: ", ")) carry, and meerkat.json's mcp policy denies \(denied.joined(separator: ", "))"
    }

    func inputSchema() -> ObjectSchema {
        ObjectSchema([
            .init(
                "window", .bounded(.positive(atMost: policy.limits.sampleSeconds)),
                default: .number(defaultWindow), doc: "Seconds to measure CPU and disk over."),
            .init(
                "top", .bounded(.integer(1...Self.maxTop)), default: .number(Double(SystemSampler.Options().top)),
                doc: "Processes to report, busiest first."),
            .init(
                "systemOnly", .boolean, default: .bool(SystemSampler.Options().systemOnly),
                doc: SystemSampler.Options.systemOnlyDoc),
        ])
    }

    /// Checks a call's arguments against the schema, whose bounds are the
    /// policy's, before anything is measured. Whether the policy allows a
    /// sample at all is the dispatch's (`denial`).
    func request(_ arguments: JSONValue) throws(Refusal) -> SystemSampler.Options {
        let input: Input = try MCPService.decoded(arguments, inputSchema())
        return SystemSampler.Options(window: input.window, top: input.top, systemOnly: input.systemOnly)
    }

    private struct Input: Decodable {
        let window: Double
        let top: Int
        let systemOnly: Bool
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
}
