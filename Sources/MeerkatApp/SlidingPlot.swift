import AppKit
import SwiftUI

/// A chart that scrolls one sample to the left when a new one arrives,
/// animated by Core Animation.
///
/// Animating the chart in SwiftUI made Swift Charts lay out and redraw it on
/// every frame, and SwiftUI rebuild the window's display list with it: about
/// 27% of a core for the Overview's six charts at the Relaxed preset
/// (2026-10-29). Here the chart is drawn once per sample, and the render
/// server moves the drawing. The plot is drawn one slot wider than shown,
/// starting one slot left of the visible edge, so the oldest point sits just
/// out of view: the new drawing, offset one slot right, is exactly the old
/// one, and gliding it back into place scrolls without a gap at either edge.
///
/// A sample that does not shift the window (it is still filling up) and
/// Reduce Motion replace the drawing in place.
struct SlidingPlot<Plot: View>: NSViewRepresentable {
    /// The newest sample's sequence number: a change scrolls.
    let step: Int
    /// Samples drawn, including the one hidden past the leading edge.
    let count: Int
    @ViewBuilder var plot: Plot

    func makeNSView(context: Context) -> SlidingPlotView {
        SlidingPlotView(root: AnyView(plot))
    }

    func updateNSView(_ view: SlidingPlotView, context: Context) {
        view.update(
            root: AnyView(plot), step: step, count: count,
            animated: !context.environment.accessibilityReduceMotion)
    }
}

final class SlidingPlotView: NSView {
    private let slider = NSView()
    private let host: NSHostingView<AnyView>
    private var step: Int?
    private var count = 0

    init(root: AnyView) {
        host = NSHostingView(rootView: root)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        slider.wantsLayer = true
        slider.addSubview(host)
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// One slot's width: the drawn span is `count - 1` slots across the
    /// visible width plus the hidden slot, so a slot is the visible width
    /// over `count - 2`.
    private var slot: CGFloat { count > 2 ? bounds.width / CGFloat(count - 2) : 0 }

    func update(root: AnyView, step: Int, count: Int, animated: Bool) {
        let scrolls = animated && window != nil && self.step.map { $0 + 1 == step } == true && count == self.count
        self.step = step
        if count != self.count {
            self.count = count
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        host.rootView = root
        guard scrolls, slot > 0, let layer = slider.layer else { return }
        let glide = CASpringAnimation(perceptualDuration: 0.5, bounce: 0)
        glide.keyPath = "transform.translation.x"
        glide.fromValue = slot
        glide.toValue = 0
        glide.duration = glide.settlingDuration
        layer.add(glide, forKey: "scroll")
    }

    override func layout() {
        super.layout()
        slider.frame = CGRect(x: -slot, y: 0, width: bounds.width + slot, height: bounds.height)
        host.frame = slider.bounds
    }
}

/// The top of a chart's scale: it grows at once to fit a new peak and, once
/// the peak scrolls out, shrinks 6% a sample, so the line does not jump
/// every time a spike leaves the window.
///
/// It is a function of the series alone. Kept in the view's state and
/// advanced after each sample, it drew every chart twice per sample, and
/// started over whenever the view was made again.
enum StickyTop {
    /// Samples a series keeps after they scroll out. By then a departed
    /// peak counts for under 5% of itself (0.94^50 ≈ 0.045).
    static let memory = 50

    /// The highest `magnitude` in `series`: the drawn samples at full
    /// height, a departed one shrunk once for each sample since it left.
    /// Nil for an empty series.
    static func peak<Value>(of series: RollingSeries<Value>, _ magnitude: (Value) -> Double) -> Double? {
        guard let first = series.points.first?.id,
            let shown = series.points.map({ magnitude($0.value) }).max()
        else { return nil }
        let departed = series.departed.map { magnitude($0.value) * pow(0.94, Double(first - $0.id)) }.max()
        return max(shown, departed ?? shown)
    }
}
