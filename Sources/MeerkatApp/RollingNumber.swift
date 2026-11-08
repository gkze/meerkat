import AppKit
import SwiftUI

/// A live number whose changed digits roll, animated by Core Animation.
///
/// SwiftUI's `.numericText()` transition re-renders the whole window's
/// display list on every frame while it plays; with six headlines rolling
/// once a second that kept the Overview at about a third of a core at the
/// Relaxed preset (2026-10-29). Here each character is its own text layer,
/// and a change commits once: the render server plays the roll, so the app
/// does no per-frame work. Digits that change roll up when the value rises
/// and down when it falls. Any other change, of length or of a character
/// that is not a digit, lays the text out again without a roll.
/// With Reduce Motion on, nothing rolls.
struct RollingNumber: NSViewRepresentable {
    let text: String
    let style: NSFont.TextStyle
    var weight: NSFont.Weight = .semibold

    private var font: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
    }

    func makeNSView(context: Context) -> RollingNumberView {
        RollingNumberView(font: font)
    }

    func updateNSView(_ view: RollingNumberView, context: Context) {
        view.font = font
        view.set(text, rolls: !context.environment.accessibilityReduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingNumberView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    /// Distance from the top to the text baseline, for baseline alignment
    /// with the unit beside it.
    var baseline: CGFloat { font.ascender }
}

final class RollingNumberView: NSView {
    var font: NSFont {
        didSet { if font != oldValue { rebuild() } }
    }
    private var text = ""
    /// One clipping slot per character, so a digit rolling through its slot
    /// never overlaps its neighbours, each showing its current glyph.
    private var slots: [CALayer] = []
    private var glyphs: [CATextLayer] = []

    /// SwiftUI's `.smooth`: a critically damped spring, here about 0.4 s,
    /// which starts quickly and settles without overshoot. A value that
    /// arrives mid-roll (the Live preset's 4 Hz CPU) finishes the roll in
    /// flight first.
    private static func spring(_ keyPath: String, from: CGFloat, to: CGFloat) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: 0.4, bounce: 0)
        spring.keyPath = keyPath
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    init(font: NSFont) {
        self.font = font
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(glyphWidths(text).reduce(0, +)), height: lineHeight)
    }

    func set(_ new: String, rolls: Bool) {
        guard new != text else { return }
        let old = text
        text = new
        // Only digits share one width (the font's tabular figures), so only
        // digit-for-digit changes can roll in the slots already laid out:
        // 589 KB/s becoming 1.3 MB/s puts a point where a digit was, and a
        // point in a digit's slot leaves a gap, a digit in a point's is cut.
        let digitsOnly = zip(old, new).allSatisfy { was, now in was == now || (was.isNumber && now.isNumber) }
        guard rolls, window != nil, old.count == new.count, glyphs.count == new.count, digitsOnly else {
            rebuild()
            return
        }
        // The direction follows the value, not each digit: 19 → 21 rolls
        // both digits up. Layers here are y-up, so "up" enters from below.
        let rising = (Self.number(new) ?? 0) >= (Self.number(old) ?? 0)
        let travel = rising ? -lineHeight : lineHeight
        var leaving: [CALayer] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, (was, now)) in zip(old, new).enumerated() where was != now {
            let slot = slots[index]
            let outgoing = glyphs[index]
            // Finish a roll still in flight in this slot.
            for layer in slot.sublayers ?? [] where layer !== outgoing { layer.removeFromSuperlayer() }
            outgoing.removeAllAnimations()
            let rest = CGPoint(x: slot.bounds.midX, y: slot.bounds.midY)
            outgoing.position = rest
            outgoing.opacity = 1
            let incoming = glyph(String(now), in: slot)
            glyphs[index] = incoming
            incoming.add(Self.spring("position.y", from: rest.y + travel, to: rest.y), forKey: "roll")
            incoming.add(Self.spring("opacity", from: 0, to: 1), forKey: "fade")
            outgoing.position.y = rest.y - travel
            outgoing.opacity = 0
            outgoing.add(Self.spring("position.y", from: rest.y, to: rest.y - travel), forKey: "roll")
            outgoing.add(Self.spring("opacity", from: 1, to: 0), forKey: "fade")
            leaving.append(outgoing)
        }
        // One block for every digit: each call would replace the last.
        CATransaction.setCompletionBlock { for layer in leaving { layer.removeFromSuperlayer() } }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let color = resolvedColor
        for glyph in glyphs { glyph.foregroundColor = color }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for glyph in glyphs { glyph.contentsScale = scale }
    }

    override func layout() {
        super.layout()
        place()
    }

    private var lineHeight: CGFloat { ceil(font.ascender - font.descender) }

    /// One slot and glyph per character, laid out left to right at the
    /// text's widths.
    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for slot in slots { slot.removeFromSuperlayer() }
        slots = text.map { _ in
            let slot = CALayer()
            slot.masksToBounds = true
            layer?.addSublayer(slot)
            return slot
        }
        place()
        glyphs = zip(text, slots).map { character, slot in glyph(String(character), in: slot) }
        CATransaction.commit()
        invalidateIntrinsicContentSize()
    }

    private func glyph(_ string: String, in slot: CALayer) -> CATextLayer {
        let glyph = CATextLayer()
        glyph.string = string
        glyph.font = font
        glyph.fontSize = font.pointSize
        glyph.foregroundColor = resolvedColor
        glyph.contentsScale = window?.backingScaleFactor ?? 2
        glyph.frame = slot.bounds
        slot.addSublayer(glyph)
        return glyph
    }

    private func place() {
        var x: CGFloat = 0
        for (slot, width) in zip(slots, glyphWidths(text)) {
            slot.frame = CGRect(x: x, y: 0, width: ceil(width), height: lineHeight)
            for glyph in slot.sublayers ?? [] { glyph.bounds = slot.bounds }
            x += width
        }
    }

    private func glyphWidths(_ text: String) -> [CGFloat] {
        text.map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
    }

    private var resolvedColor: CGColor {
        var color = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        return color
    }

    /// "24.1", "1,284" → a number, for the roll's direction.
    private static func number(_ text: String) -> Double? {
        Double(text.filter { $0.isNumber || $0 == "." || $0 == "-" })
    }
}
