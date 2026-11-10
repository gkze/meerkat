import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import LanguageServerProtocol
import SwiftUI

/// Completions from tsrs through CodeEditSourceEditor's
/// suggestion window.
///
/// tsrs answers with bare labels: no edit ranges, details or documentation.
/// So the word before the cursor is what an item replaces, the list is
/// filtered here as typing continues (CodeEditSourceEditor asks for that
/// synchronously), and items are resolved for their signature and
/// documentation a few at a time.
@MainActor
final class RuleCompletions: CodeSuggestionDelegate {
    /// One completion item, resolved in place.
    final class Entry: CodeSuggestionEntry {
        var item: CompletionItem
        var resolved = false

        init(_ item: CompletionItem) { self.item = item }

        var label: String { item.label }
        var detail: String? { item.labelDetails?.description }
        var documentation: String? {
            switch item.documentation {
            case .optionA(let text)?: text
            case .optionB(let markup)?: markup.value
            case nil: nil
            }
        }
        var pathComponents: [String]? { nil }
        var targetPosition: CursorPosition? { nil }
        /// The signature, highlighted as TypeScript in the window's preview.
        var sourcePreview: String? { item.detail }
        var image: Image { Image(systemName: RuleCompletions.symbol(item.kind)) }
        var imageColor: SwiftUI.Color { RuleCompletions.color(item.kind) }
        var deprecated: Bool { item.deprecated ?? false }
    }

    /// Items resolved before the window shows, about as many as it shows.
    static let resolvedAhead = 10

    weak var model: RuleEditorModel?
    /// The last request's items, sorted as the server ranks them.
    private var entries: [Entry] = []
    /// Where the text an item replaces starts.
    private var wordStart = 0
    /// Inside a string literal, where items are literal values that may
    /// hold dots ("process.hot"), anything up to the quote is the word.
    private var inString = false

    func completionTriggerCharacters() -> Set<String> { RuleEditorModel.completionTriggers }

    func completionSuggestionsRequested(
        textView: TextViewController, cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        guard let model else { return nil }
        let string = textView.textView.textStorage.string as NSString
        let offset = cursorPosition.range.location
        guard offset != NSNotFound, offset <= string.length else { return nil }
        let start = Self.wordStart(before: offset, in: string)
        let before = start > 0 ? string.substring(with: NSRange(location: start - 1, length: 1)) : ""
        let trigger = start == offset && RuleEditorModel.completionTriggers.contains(before) ? before : nil
        let position = string.lspPosition(of: offset)
        let items = await model.completions(line: position.line, character: position.character, trigger: trigger)
        guard !Task.isCancelled, !items.isEmpty else { return nil }

        wordStart = start
        inString = ["\"", "'", "`"].contains(before)
        entries = items.sorted { ($0.sortText ?? $0.label, $0.label) < ($1.sortText ?? $1.label, $1.label) }
            .map(Entry.init)
        let typed = string.substring(with: NSRange(location: start, length: offset - start))
        let shown = Self.filter(entries, typed: typed)
        guard !shown.isEmpty else { return nil }
        await resolve(shown.prefix(Self.resolvedAhead))
        return (CursorPosition(range: NSRange(location: start, length: 0)), shown as [any CodeSuggestionEntry])
    }

    func completionOnCursorMove(
        textView: TextViewController, cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]? {
        let string = textView.textView.textStorage.string as NSString
        let offset = cursorPosition.range.location
        guard cursorPosition.range.length == 0, offset >= wordStart, offset <= string.length else { return nil }
        let typed = string.substring(with: NSRange(location: wordStart, length: offset - wordStart))
        guard typed.unicodeScalars.allSatisfy({ inString ? !Self.isStringEnd($0) : Self.isWordCharacter($0) }) else {
            return nil
        }
        let shown: [any CodeSuggestionEntry] = Self.filter(entries, typed: typed)
        return shown.isEmpty ? nil : shown
    }

    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry, textView: TextViewController, cursorPosition: CursorPosition?
    ) {
        guard let entry = item as? Entry, let cursor = cursorPosition ?? textView.cursorPositions.first else { return }
        let string = textView.textView.textStorage.string as NSString
        var start = wordStart
        var insertion = entry.item.insertText ?? entry.item.label
        if case .optionA(let edit)? = entry.item.textEdit,
            let editStart = string.offset(ofLSP: edit.range.start)
        {
            start = editStart
            insertion = edit.newText
        }
        let end = cursor.range.location
        guard start <= end, end <= string.length else { return }
        textView.textView.replaceCharacters(in: NSRange(location: start, length: end - start), with: insertion)
        let caret = start + (insertion as NSString).length
        textView.setCursorPositions([CursorPosition(range: NSRange(location: caret, length: 0))])
    }

    /// Resolves the selected item and the next few, so moving through the
    /// list finds them resolved. (The window reads an item's documentation
    /// when it is selected and can't be told it changed.)
    func completionWindowDidSelect(item: any CodeSuggestionEntry) {
        guard let entry = item as? Entry, let index = entries.firstIndex(where: { $0 === entry }) else { return }
        let ahead = entries[index...].prefix(Self.resolvedAhead)
        Task { await resolve(ahead) }
    }

    private func resolve(_ batch: ArraySlice<Entry>) async {
        for entry in batch where !entry.resolved {
            entry.resolved = true
            if let resolved = await model?.resolve(entry.item) { entry.item = resolved }
        }
    }

    // MARK: - Text

    /// Items whose filter text starts with what was typed, ignoring case;
    /// failing that, those that contain it.
    nonisolated static func filter(_ entries: [Entry], typed: String) -> [Entry] {
        guard !typed.isEmpty else { return entries }
        func key(_ entry: Entry) -> String { entry.item.filterText ?? entry.item.label }
        let prefixed = entries.filter { key($0).range(of: typed, options: [.caseInsensitive, .anchored]) != nil }
        return prefixed.isEmpty ? entries.filter { key($0).localizedCaseInsensitiveContains(typed) } : prefixed
    }

    /// The start of the identifier that ends at `offset`.
    nonisolated static func wordStart(before offset: Int, in string: NSString) -> Int {
        var start = offset
        while start > 0, let scalar = UnicodeScalar(string.character(at: start - 1)), isWordCharacter(scalar) {
            start -= 1
        }
        return start
    }

    nonisolated static func isWordCharacter(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }

    private nonisolated static func isStringEnd(_ scalar: UnicodeScalar) -> Bool {
        scalar == "\"" || scalar == "'" || scalar == "`" || CharacterSet.newlines.contains(scalar)
    }

    // MARK: - Kinds

    fileprivate nonisolated static func symbol(_ kind: CompletionItemKind?) -> String {
        switch kind {
        case .method, .function, .constructor: "f.square"
        case .field, .property: "p.square"
        case .variable, .constant, .value: "v.square"
        case .class, .interface, .struct, .typeParameter: "t.square"
        case .enum, .enumMember: "e.square"
        case .keyword: "k.square"
        case .module, .file, .folder: "m.square"
        case .snippet: "s.square"
        default: "circle.square"
        }
    }

    fileprivate nonisolated static func color(_ kind: CompletionItemKind?) -> SwiftUI.Color {
        switch kind {
        case .method, .function, .constructor: .purple
        case .field, .property: .blue
        case .variable, .constant, .value: .green
        case .class, .interface, .struct, .typeParameter: .orange
        case .enum, .enumMember: .teal
        case .keyword: .pink
        default: .secondary
        }
    }
}

/// tsrs's hover for the word under the pointer, after the pointer rests
/// on it, in a popover at the word (CodeEditSourceEditor has no hover API;
/// the word's rectangle comes from `TextLayoutManager.rectForOffset`).
@MainActor
final class RuleHovers: NSResponder, @preconcurrency TextViewCoordinator {
    /// How long the pointer rests before the server is asked.
    static let delay: Duration = .milliseconds(600)

    weak var model: RuleEditorModel?
    private weak var controller: TextViewController?
    private var trackingArea: NSTrackingArea?
    private var pending: Task<Void, Never>?
    private var popover: NSPopover?
    /// The text the shown popover describes.
    private var shownRange: NSRange?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        controller.textView.addTrackingArea(area)
        trackingArea = area
    }

    func textViewDidChangeText(controller: TextViewController) { dismiss() }

    func destroy() {
        dismiss()
        if let trackingArea { controller?.textView.removeTrackingArea(trackingArea) }
        trackingArea = nil
        controller = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard let textView = controller?.textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let offset = textView.layoutManager.textOffsetAtPoint(point)
        if let shownRange, let offset, NSLocationInRange(offset, shownRange) { return }
        dismiss()
        guard let offset else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            await self?.show(at: offset)
        }
    }

    override func mouseExited(with event: NSEvent) { dismiss() }

    private func dismiss() {
        pending?.cancel()
        pending = nil
        popover?.close()
        popover = nil
        shownRange = nil
    }

    private func show(at offset: Int) async {
        guard let model, let textView = controller?.textView else { return }
        let string = textView.textStorage.string as NSString
        // The nearest offset comes back for blank space and past a line's
        // end too; only a word has a hover.
        guard offset < string.length, let scalar = UnicodeScalar(string.character(at: offset)),
            RuleCompletions.isWordCharacter(scalar)
        else { return }
        let position = string.lspPosition(of: offset)
        guard let hover = await model.hover(line: position.line, character: position.character), !Task.isCancelled
        else { return }
        let content = HoverContent(hover)
        guard !content.isEmpty else { return }

        var range = NSRange(location: RuleCompletions.wordStart(before: offset, in: string), length: 1)
        if let lspRange = hover.range, let start = string.offset(ofLSP: lspRange.start),
            let end = string.offset(ofLSP: lspRange.end), end > start
        {
            range = NSRange(location: start, length: end - start)
        }
        guard let first = textView.layoutManager.rectForOffset(range.location) else { return }
        let last = textView.layoutManager.rectForOffset(range.upperBound - 1) ?? first
        let anchor = first.minY == last.minY ? first.union(last) : first

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: HoverCard(content: content))
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        self.popover = popover
        shownRange = range
    }
}

/// A hover's signatures (code blocks) and documentation.
struct HoverContent: Equatable {
    var code: [String] = []
    var prose: [String] = []

    var isEmpty: Bool { code.isEmpty && prose.isEmpty }

    init(_ hover: Hover) {
        switch hover.contents {
        case .optionA(let marked): add(marked)
        case .optionB(let list):
            for marked in list { add(marked) }
        case .optionC(let markup):
            if markup.kind == .markdown { add(markdown: markup.value) } else { add(prose: markup.value) }
        }
    }

    /// Fenced blocks are code; the rest is Markdown prose.
    init(markdown: String) { add(markdown: markdown) }

    private mutating func add(_ marked: MarkedString) {
        switch marked {
        case .optionA(let markdown): add(markdown: markdown)
        case .optionB(let pair): add(code: pair.value)
        }
    }

    private mutating func add(markdown: String) {
        var block: [Substring]?
        var paragraph: [Substring] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if let lines = block {
                    add(code: lines.joined(separator: "\n"))
                    block = nil
                } else {
                    add(prose: paragraph.joined(separator: "\n"))
                    paragraph = []
                    block = []
                }
            } else if block != nil {
                block?.append(line)
            } else {
                paragraph.append(line)
            }
        }
        if let block { add(code: block.joined(separator: "\n")) }
        add(prose: paragraph.joined(separator: "\n"))
    }

    private mutating func add(code text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { code.append(trimmed) }
    }

    private mutating func add(prose text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { prose.append(trimmed) }
    }
}

private struct HoverCard: View {
    let content: HoverContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(content.code.enumerated()), id: \.offset) { _, code in
                Text(code)
                    .font(.system(.body, design: .monospaced))
            }
            if !content.code.isEmpty && !content.prose.isEmpty { Divider() }
            ForEach(Array(content.prose.enumerated()), id: \.offset) { _, prose in
                Text(Self.attributed(prose))
                    .font(.callout)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520, alignment: .leading)
        .padding(12)
    }

    private static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

// MARK: - Inline problems

/// Underlines each problem and writes the first problem on a line after the
/// line's end, as the editor has no diagnostics view of its own: underlines
/// through `TextView`'s emphasis layer, messages as labels in the text view.
@MainActor
final class ProblemAnnotations: @preconcurrency TextViewCoordinator {
    private static let emphasisGroup = "meerkat.problems"
    private weak var controller: TextViewController?
    private var labels: [NSTextField] = []

    var problems: [RuleEditorModel.Problem] = [] {
        didSet { if problems != oldValue { apply() } }
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        apply()
    }

    func controllerDidAppear(controller: TextViewController) { apply() }

    /// Positions shift as text is inserted; place everything again after
    /// layout. The ranges themselves are the last check's until the next
    /// one arrives.
    func textViewDidChangeText(controller: TextViewController) {
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    func destroy() {
        for label in labels { label.removeFromSuperview() }
        labels = []
        controller = nil
    }

    /// Replaces the editor's text, from the top. `SourceEditor` reads its
    /// binding only when it is created, so opening another file has to reach
    /// the text view here.
    func show(_ text: String) {
        guard let controller else { return }
        controller.setText(text)
        moveCursor(to: CursorPosition(line: 1, column: 1))
        apply()
    }

    /// Makes `fix`'s edits as one undo step, through the text view so the
    /// model hears of them like any other edit.
    func apply(_ fix: RuleFix) {
        guard let textView = controller?.textView,
            let replacements = fix.replacements(in: textView.string as NSString)
        else { return }
        textView.undoManager?.beginUndoGrouping()
        for replacement in replacements {
            textView.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        textView.undoManager?.endUndoGrouping()
    }

    /// `SourceEditorState.cursorPositions` only reports the cursor: setting
    /// it doesn't move the text view's.
    func moveCursor(to position: CursorPosition) {
        controller?.setCursorPositions([position], scrollToVisible: true)
    }

    private func apply() {
        for label in labels { label.removeFromSuperview() }
        labels = []
        guard let textView = controller?.textView, let layout = textView.layoutManager else { return }
        // Positions below are nil or stale until the text is laid out.
        textView.layoutSubtreeIfNeeded()
        let emphases = problems.compactMap { problem -> Emphasis? in
            guard let start = offset(problem.line, problem.character, in: layout),
                let end = offset(problem.endLine, problem.endCharacter, in: layout)
            else { return nil }
            // A zero-width range (a missing token) still gets a mark.
            let length = max(end - start, 1)
            let range = NSRange(location: start, length: min(length, max(textView.textStorage.length - start, 0)))
            return Emphasis(range: range, style: .underline(color: problem.severity.status.nsColor))
        }
        textView.emphasisManager?.replaceEmphases(emphases, for: Self.emphasisGroup)

        var annotated = Set<Int>()
        for problem in problems where annotated.insert(problem.line).inserted {
            guard let line = layout.textLineForIndex(problem.line) else { continue }
            let end = lineEnd(line.range, in: textView)
            let x = (end > line.range.location ? layout.rectForOffset(end - 1)?.maxX : nil) ?? textView.edgeInsets.left
            let label = NSTextField(labelWithString: "  \(problem.message)  ")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            // The text variant: the underline's system colour is too light
            // for small text on a light theme. It resolves for the theme's
            // background, not the app's appearance: a dark-only theme
            // (`RuleEditorTheme.isDarkOnly`) is dark in both.
            label.appearance = labelAppearance
            label.textColor = problem.severity.status.nsText
            label.drawsBackground = true
            label.backgroundColor = problem.severity.status.nsColor.withAlphaComponent(0.12)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = problem.message
            label.sizeToFit()
            label.frame.origin = CGPoint(
                x: x + 16, y: line.yPos + max((line.height - label.frame.height) / 2, 0))
            textView.addSubview(label)
            labels.append(label)
        }
    }

    /// The text offset of an LSP position, clamped to its line.
    private func offset(_ line: Int, _ character: Int, in layout: TextLayoutManager) -> Int? {
        guard let position = layout.textLineForIndex(line) else { return nil }
        return position.range.location + min(character, position.range.length)
    }

    private func lineEnd(_ range: NSRange, in textView: TextView) -> Int {
        var end = range.upperBound
        let string = textView.textStorage.string as NSString
        while end > range.location, let scalar = UnicodeScalar(string.character(at: end - 1)),
            CharacterSet.newlines.contains(scalar)
        {
            end -= 1
        }
        return end
    }

    /// Dark or light, as the editor theme's background is.
    private var labelAppearance: NSAppearance? {
        guard let background = controller?.theme.background.usingColorSpace(.sRGB) else { return nil }
        let isDark = background.brightnessComponent < 0.5
        return NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}
