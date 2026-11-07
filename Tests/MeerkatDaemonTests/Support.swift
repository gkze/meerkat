import Foundation
import MeerkatKit
import MeerkatRules
import Testing

@testable import MeerkatDaemon

/// The repository root.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// `MEERKAT_TSRS` (which `buck2 test` sets to //buck2/third_party/js's tsrs),
/// else the repository's Sources/meerkat-rules/node_modules.
func typeScriptToolchain() throws -> TypeScriptToolchain {
    try #require(
        TypeScriptToolchain.locate(executable: repositoryRoot.appendingPathComponent(".build/x")),
        "run `bun install` in Sources/meerkat-rules/, or set MEERKAT_TSRS")
}

/// A name no other test uses, for a notification or a Darwin channel.
func uniqueName() -> String {
    "com.gkze.meerkat.test.\(UUID().uuidString)"
}

/// A path under the temporary directory no other test uses; nothing is
/// created there.
func temporaryURL(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

extension RuleDefinition {
    /// For tests about something other than observation: nothing is
    /// protected, so the rule's grants alone decide what it may observe.
    init(file: String, raw: JSONValue, catalog: EventCatalog) throws {
        try self.init(file: file, raw: raw, catalog: catalog, observation: ObservationScope(protectedRead: []))
    }
}
