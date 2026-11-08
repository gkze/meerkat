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
/// The glide is linear and lasts as long as the last gap between samples,
/// so the series moves at a steady pace instead of stepping a slot and
/// waiting. The newest sample is in full view only once its glide ends, a
/// sample's time after it arrived; the reading beside the chart shows it at
/// once. A sample that lands before the glide ends starts the next glide
/// from where the drawing is, so it never snaps.
///
/// A new value range (`values`: a new peak, or the scale's top shrinking
/// after one leaves) eases in the same way: the new drawing starts stretched
/// to look like the old one and relaxes over the same glide. A range more
/// than twice or under half the size of the one shown snaps instead, since
/// the stretch would also thicken the line that much.
///
/// The plot spans the series' whole window (`windowDomain`), filled or not,
/// so every new sample shifts it by exactly one slot. The first sample after
/// the chart appears, one that skips a number, a new window size and Reduce
/// Motion replace the drawing in place.
struct SlidingPlot<Plot: View>: NSViewRepresentable {
    /// The newest sample's sequence number: a change scrolls.
    let step: Int
    /// The window's samples, including the one hidden past the leading edge.
    let capacity: Int
    /// The plot's y-domain, bottom to top.
    let values: ClosedRange<Double>
    @ViewBuilder var plot: Plot

    func makeNSView(context: Context) -> SlidingPlotView {
        SlidingPlotView(root: AnyView(plot))
    }

    func updateNSView(_ view: SlidingPlotView, context: Context) {
        view.update(
            root: AnyView(plot), step: step, capacity: capacity, values: values,
            animated: !context.environment.accessibilityReduceMotion)
    }
}

final class SlidingPlotView: NSView {
    /// Carries the vertical rescale, so it composes with the slider's
    /// scroll without the two animating parts of one transform.
    private let scaler = NSView()
    private let slider = NSView()
    private let host: NSHostingView<AnyView>
    private var step: Int?
    private var capacity = 0
    private var values: ClosedRange<Double>?
    /// When the last new sample arrived: the next glide lasts until then.
    private var stepped: CFTimeInterval?

    init(root: AnyView) {
        host = NSHostingView(rootView: root)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        scaler.wantsLayer = true
        slider.wantsLayer = true
        slider.addSubview(host)
        scaler.addSubview(slider)
        addSubview(scaler)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// One slot's width: the drawn span is `capacity - 1` slots across the
    /// visible width plus the hidden slot, so a slot is the visible width
    /// over `capacity - 2`.
    private var slot: CGFloat { capacity > 2 ? bounds.width / CGFloat(capacity - 2) : 0 }

    func update(root: AnyView, step: Int, capacity: Int, values: ClosedRange<Double>, animated: Bool) {
        let scrolls =
            animated && window != nil && self.step.map { $0 + 1 == step } == true && capacity == self.capacity
        let now = CACurrentMediaTime()
        let gap = stepped.map { now - $0 }
        if step != self.step { stepped = now }
        self.step = step
        if capacity != self.capacity {
            self.capacity = capacity
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        let shown = self.values
        self.values = values
        host.rootView = root
        guard scrolls, slot > 0, let gap, let layer = slider.layer else {
            scaler.layer?.removeAnimation(forKey: "rescale")
            return
        }
        let duration = Self.glideDuration(gap: gap)
        if let shown, shown != values { rescale(from: shown, to: values, duration: duration) }
        // Still mid-glide, the drawing sits `inFlight` right of its place; the
        // new one is a slot further left, so it starts a slot further right.
        let inFlight = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
        let glide = CABasicAnimation(keyPath: "transform.translation.x")
        glide.fromValue = slot + inFlight
        glide.toValue = 0
        glide.duration = duration
        glide.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(glide, forKey: "scroll")
    }

    /// Starts the new drawing where the old one is on screen, mid-rescale
    /// included, and eases it to its own scale.
    private func rescale(from shown: ClosedRange<Double>, to values: ClosedRange<Double>, duration: CFTimeInterval) {
        guard let layer = scaler.layer, bounds.height > 0 else { return }
        let height = bounds.height
        // Transforms act about the anchor; the mapping is from the bottom edge.
        let anchor = layer.anchorPoint.y * height
        let current = layer.presentation()?.transform ?? CATransform3DIdentity
        let onScreen = VerticalMap(
            scale: current.m22, offset: (current.m42 + anchor * (1 - current.m22)) / height)
        guard let change = VerticalMap(from: shown, to: values), (0.5...2).contains(onScreen.after(change).scale)
        else {
            layer.removeAnimation(forKey: "rescale")
            return
        }
        let start = onScreen.after(change)
        var from = CATransform3DMakeScale(1, start.scale, 1)
        from.m42 = start.offset * height - anchor * (1 - start.scale)
        let ease = CABasicAnimation(keyPath: "transform")
        ease.fromValue = NSValue(caTransform3D: from)
        ease.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        ease.duration = duration
        ease.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(ease, forKey: "rescale")
    }

    /// The gap since the previous sample, bounded: a burst of samples still
    /// glides visibly, and one after a long stall (the Mac slept) does not
    /// glide for longer than the chart spans.
    static func glideDuration(gap: CFTimeInterval) -> CFTimeInterval {
        min(max(gap, 0.1), SamplingRates.chartSpan)
    }

    override func layout() {
        super.layout()
        scaler.frame = bounds
        slider.frame = CGRect(x: -slot, y: 0, width: bounds.width + slot, height: bounds.height)
        host.frame = slider.bounds
    }
}

/// How a drawing's heights map onto the plot, from the bottom edge: `y` in
/// the drawing shows at `scale * y + offset * height`.
struct VerticalMap: Equatable {
    var scale: CGFloat
    var offset: CGFloat

    /// What makes a drawing over `values` look like one over `shown`: a
    /// value at fraction `f` of `values` sits at fraction
    /// `(lo - shownLo + f * span) / shownSpan` of `shown`. Nil when either
    /// range is empty.
    init?(from shown: ClosedRange<Double>, to values: ClosedRange<Double>) {
        let shownSpan = shown.upperBound - shown.lowerBound
        let span = values.upperBound - values.lowerBound
        guard shownSpan > 0, span > 0 else { return nil }
        scale = CGFloat(span / shownSpan)
        offset = CGFloat((values.lowerBound - shown.lowerBound) / shownSpan)
    }

    init(scale: CGFloat, offset: CGFloat) {
        self.scale = scale
        self.offset = offset
    }

    /// This map applied after `inner`.
    func after(_ inner: VerticalMap) -> VerticalMap {
        VerticalMap(scale: scale * inner.scale, offset: scale * inner.offset + offset)
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

    /// A chart's value range: zero to the peak with `headroom` above it, so
    /// the newest point never touches the top. An automatic scale would
    /// round to a new "nice" top on most samples.
    static func range<Value>(
        of series: RollingSeries<Value>, headroom: Double, _ magnitude: (Value) -> Double
    ) -> ClosedRange<Double> {
        0...max((peak(of: series, magnitude) ?? 1) * headroom, 0.0001)
    }
}
