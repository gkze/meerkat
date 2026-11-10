import Foundation
import MeerkatKit

/// What Meerkat writes into a rules directory so an editor, and the
/// linter's type-aware rules, check what the daemon checks: the `meerkat`
/// module's declarations, the runtime's, the daemon's compiler options,
/// the lint and format policy (`RuleLinter.writeConfiguration`) and
/// `meerkat.json`'s schema. The daemon writes it on every reload and the CLI
/// before it lints or formats, both through `write`, so neither leaves out
/// a part the other writes.
///
/// `.meerkat/` is rewritten as needed; `tsconfig.json` is written only when
/// absent: it is the author's file once it exists.
public struct EditorSupport: Sendable {
    /// The `meerkat` module's (`TypeScriptDeclarations`).
    public var declarations: String
    /// The runtime's globals; nil leaves any copy already there.
    public var runtimeDeclarations: String?
    /// `meerkat.json`'s JSON Schema, and where it goes relative to the rules
    /// directory; nil writes none.
    public var configurationSchema: (path: String, text: String)?
    /// Writes the lint and format policy; nil writes none.
    public var linter: RuleLinter?

    public static let declarationsFile = "meerkat.d.ts"

    public init(
        declarations: String, runtimeDeclarations: String?, configurationSchema: (path: String, text: String)?,
        linter: RuleLinter?
    ) {
        self.declarations = declarations
        self.runtimeDeclarations = runtimeDeclarations
        self.configurationSchema = configurationSchema
        self.linter = linter
    }

    /// Some parts could not be written; the others were.
    public struct Failed: Error, CustomStringConvertible {
        public let problems: [String]

        public var description: String { problems.joined(separator: "; ") }
    }

    /// Writes every part, then throws `Failed` naming each that could not be
    /// written: one part's failure does not keep the others from an editor.
    public func write(in rulesDirectory: URL) async throws {
        var problems: [String] = []
        do {
            try writeCompilerSupport(in: rulesDirectory)
        } catch {
            problems.append("could not write the editor configuration: \(error)")
        }
        if let schema = configurationSchema {
            let url = rulesDirectory.appendingPathComponent(schema.path)
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.writeIfChanged(schema.text, to: url)
            } catch {
                problems.append("could not write \(url.path): \(error)")
            }
        }
        do {
            try await linter?.writeConfiguration(in: rulesDirectory)
        } catch {
            problems.append("could not write the lint configuration: \(error)")
        }
        if !problems.isEmpty { throw Failed(problems: problems) }
    }

    private func writeCompilerSupport(in rulesDirectory: URL) throws {
        let support = rulesDirectory.appendingPathComponent(RulesDirectoryLayout.supportDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let runtimeFile = TypeScriptToolchain.runtimeDeclarationsFile
        let base: JSONValue = .object([
            "compilerOptions": .object(RuleCompiler.compilerOptions.merging(["noEmit": true]) { $1 }),
            "include": .array([
                .string("../**/*.ts"), .string("./\(Self.declarationsFile)"), .string("./\(runtimeFile)"),
            ]),
            "exclude": .array([.string("../**/node_modules")]),
        ])
        try Self.writeIfChanged(declarations, to: support.appendingPathComponent(Self.declarationsFile))
        if let runtimeDeclarations {
            try Self.writeIfChanged(runtimeDeclarations, to: support.appendingPathComponent(runtimeFile))
        }
        try Self.writeIfChanged(
            String(decoding: try JSONEncoder.meerkat(pretty: true).encode(base), as: UTF8.self) + "\n",
            to: support.appendingPathComponent("tsconfig.base.json"))
        let tsconfig = rulesDirectory.appendingPathComponent("tsconfig.json")
        if !FileManager.default.fileExists(atPath: tsconfig.path) {
            try Self.writeIfChanged(
                "{\n  \"extends\": \"./\(RulesDirectoryLayout.supportDirectory)/tsconfig.base.json\"\n}\n",
                to: tsconfig)
        }
    }

    /// Writes only when the contents differ, so the rules directory's
    /// watcher does not see a change that is not one.
    static func writeIfChanged(_ text: String, to url: URL) throws {
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
