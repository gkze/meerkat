import Foundation
import LanguageServerProtocol

/// LSP positions are 0-based lines and UTF-16 characters (the protocol's
/// default encoding, and NSString's), so they convert to text offsets here,
/// for the language server's diagnostics, completions, hovers and fixes.
extension NSString {
    /// The LSP position (0-based line, UTF-16 character) of a text offset.
    nonisolated func lspPosition(of offset: Int) -> Position {
        var line = 0
        var lineStart = 0
        for index in 0..<min(offset, length) where character(at: index) == 0x0A {
            line += 1
            lineStart = index + 1
        }
        return Position(line: line, character: offset - lineStart)
    }

    /// The text offset of an LSP position, or nil past the end.
    nonisolated func offset(ofLSP position: Position) -> Int? {
        var line = 0
        var index = 0
        while line < position.line {
            guard index < length else { return nil }
            if character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        let offset = index + position.character
        return offset <= length ? offset : nil
    }
}
