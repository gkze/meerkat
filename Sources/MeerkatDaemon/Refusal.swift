/// A request the daemon turns down in words its caller can act on: bad
/// arguments, a policy refusal, a busy session, a runner that can't serve
/// now. The dry runner throws it to every caller, which the XPC server
/// answers with as a failure (the CLI and the app) and MCP reports to the
/// model as a tool error rather than a protocol error.
struct Refusal: Error, CustomStringConvertible, Sendable, Equatable {
    let description: String

    init(_ description: String) { self.description = description }
}
