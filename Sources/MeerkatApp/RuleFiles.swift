import CryptoKit
import Foundation

/// What the app writes into new rule files, whichever way it makes one.
nonisolated enum RuleFileSource {
    /// Why a name can't be a rule file's.
    enum FileNameProblem: Error, Equatable, CustomStringConvertible {
        case empty
        case notAFileName
        case declarationFile
        case exists(String)

        var description: String {
            switch self {
            case .empty: "Enter a name."
            case .notAFileName: "Use letters, digits, spaces, “-”, “_” or “.”, not starting with “.”."
            case .declarationFile: "A .d.ts file only declares types; it can't hold rules."
            case .exists(let file): "\(file) already exists."
            }
        }
    }

    /// `input` as a rule file name (".ts" added when missing), or why it
    /// can't be one. `existing` is compared without regard to case, as
    /// APFS compares names.
    static func fileName(_ input: String, existing: [String]) -> Result<String, FileNameProblem> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let name = trimmed.hasSuffix(".ts") ? trimmed : trimmed + ".ts"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        guard name.count > 3, !name.hasPrefix("."), name.unicodeScalars.allSatisfy(allowed.contains) else {
            return .failure(.notAFileName)
        }
        guard !name.hasSuffix(".d.ts") else { return .failure(.declarationFile) }
        if let clash = existing.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return .failure(.exists(clash))
        }
        return .success(name)
    }

    /// A new rule file, valid as written: a timer rule that logs, for the
    /// user to change.
    static func template(for file: String) -> String {
        let words = RuleFileSource.words(String(file.dropLast(3))).map { $0.lowercased() }
        let name = words.isEmpty ? "rule" : words.joined(separator: "-")
        return """
            // \(file): what this rule watches for, and what it does.
            import { rule } from "meerkat";

            export const \(RuleFileSource.identifier(words)) = rule({
              name: "\(name)",
              on: "timer",
              params: { every: 300 },
              handle(_event, ctx) {
                ctx.info("\(name) ran");
              },
            });

            """
    }

    /// The words of a file name: "xcode-hot" → ["xcode", "hot"]. A word is
    /// made of identifier characters (Unicode XID_Continue, which
    /// JavaScript's ID_Continue matches here), so it can go into an export
    /// name as it is. Anything else, "²" or "½" included, separates words,
    /// and so does "_", for "xcode_hot".
    static func words(_ name: String) -> [String] {
        name.split { $0 == "_" || !$0.unicodeScalars.allSatisfy(\.properties.isXIDContinue) }.map(String.init)
    }

    /// `words` in camelCase, as a valid identifier for a rule's export;
    /// `empty` when there are none.
    static func identifier(_ words: [String], empty: String = "rule") -> String {
        guard let first = words.first else { return empty }
        func capitalized(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }
        let camel = first.lowercased() + words.dropFirst().map(capitalized).joined()
        let starts = camel.unicodeScalars.first?.properties.isXIDStart == true
        return starts && !reservedWords.contains(camel) ? camel : "rule" + capitalized(camel)
    }

    /// Writes a new file, failing rather than replacing one already there.
    /// The daemon makes the rules folder when it starts, so it may not exist
    /// yet.
    static func create(_ url: URL, text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    private static let reservedWords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "implements", "import",
        "in", "instanceof", "interface", "let", "new", "null", "package", "private", "protected", "public",
        "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while",
        "with", "yield",
    ]
}

/// Unsaved edits to rule files, one JSON file per rule file in the app's
/// support folder, so they outlive the editor and the app.
struct RuleDrafts: Sendable {
    struct Draft: Codable, Equatable {
        /// The file's text when editing started.
        let base: String
        let text: String
    }

    let directory: URL

    static var standard: RuleDrafts {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RuleDrafts(
            directory: support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.gkze.meerkat")
                .appendingPathComponent("Rule Drafts"))
    }

    /// Nil when `file` has no draft; throws when it has one that can't be
    /// read, which isn't the same.
    func load(for file: URL) throws -> Draft? {
        let location = location(file)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        return try JSONDecoder().decode(Draft.self, from: Data(contentsOf: location))
    }

    func exists(for file: URL) -> Bool { FileManager.default.fileExists(atPath: location(file).path) }

    /// Moves an unreadable draft out of the way, under a name no file maps
    /// to, and returns where.
    func setAside(for file: URL) throws -> URL {
        let location = location(file)
        let aside = location.deletingPathExtension().appendingPathExtension("unreadable-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: location, to: aside)
        return aside
    }

    func save(_ draft: Draft, for file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: location(file), options: .atomic)
    }

    func remove(for file: URL) {
        try? FileManager.default.removeItem(at: location(file))
    }

    /// Named by a hash of the file's path: rule files may sit in
    /// subfolders, and the name must not depend on what's legal in one.
    private func location(_ file: URL) -> URL {
        let digest = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".json")
    }
}
