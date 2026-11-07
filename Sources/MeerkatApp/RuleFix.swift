import Foundation
import LanguageServerProtocol

/// A change tsrs offers for the open file (a code action): a quick fix for
/// some of its problems, or a whole-file action such as Organize Imports.
///
/// Only what the editor can apply whole is offered: edits to the open file
/// alone, with no command to run afterwards, that change its text.
struct RuleFix: Identifiable, Equatable {
    /// tsrs's reply types, named here so tests can decode captured replies
    /// without importing the protocol.
    typealias Action = CodeAction
    typealias Finding = Diagnostic

    let id: Int
    let title: String
    /// The ids of the problems this fixes; empty for a whole-file action.
    let problems: Set<Int>
    private let edits: [TextEdit]

    /// What tsrs offered for `text`, in its order. `shown` are the ids
    /// (indices into `findings`) of the problems the editor lists; an action
    /// for hints alone has no row to sit on and counts as whole-file.
    static func offered(
        _ actions: [Action], for findings: [Finding], shown: Set<Int>, in document: DocumentUri, text: String
    ) -> [RuleFix] {
        var fixes: [RuleFix] = []
        for action in actions where action.disabled == nil && action.command == nil {
            guard let changes = action.edit?.changes, changes.count == 1, let edits = changes[document] else {
                continue
            }
            let fixed = (action.diagnostics ?? []).compactMap { findings.firstIndex(of: $0) }.filter(shown.contains)
            let fix = RuleFix(id: fixes.count, title: action.title, problems: Set(fixed), edits: edits)
            if let applied = fix.applied(to: text), applied != text { fixes.append(fix) }
        }
        return fixes
    }

    /// The edits as ranges of `text`, last first: applied in that order, none
    /// moves a range still to come, and inserts at one position end up in
    /// the order tsrs gave them. Nil if tsrs's edits don't fit `text`.
    func replacements(in text: NSString) -> [(range: NSRange, text: String)]? {
        var ranges: [(range: NSRange, text: String)] = []
        for edit in edits {
            guard let start = text.offset(ofLSP: edit.range.start), let end = text.offset(ofLSP: edit.range.end),
                start <= end
            else { return nil }
            ranges.append((NSRange(location: start, length: end - start), edit.newText))
        }
        let ordered = ranges.indices.sorted {
            (ranges[$0].range.location, $0) < (ranges[$1].range.location, $1)
        }.map { ranges[$0] }
        for (edit, next) in zip(ordered, ordered.dropFirst()) where NSMaxRange(edit.range) > next.range.location {
            return nil
        }
        return ordered.reversed()
    }

    /// `text` with the edits made.
    func applied(to text: String) -> String? {
        let result = NSMutableString(string: text)
        guard let replacements = replacements(in: result) else { return nil }
        for replacement in replacements {
            result.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return result as String
    }
}
