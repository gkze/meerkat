import AppKit
import Charts
import MeerkatKit
import SwiftUI

// MARK: - Palette
//
// Colour marks a resource: one system colour per metric, used on its card's
// icon, its chart, its bars and its sidebar row, so each reads as one family.
// Status uses the system's meaning: green normal, orange warning, red
// critical. Everything else is the system's semantic label, fill and
// separator styles, so light, dark and Increase Contrast come for free.
// Not for status words, though: the system green, orange and red are fill
// colours, and as small text on a light surface they reach only about 2:1
// to 3.5:1 (WCAG AA asks 4.5:1). Status text takes `Theme.text(_:)`.

enum Theme {
    static let cpu = Color.teal
    static let memory = Color.indigo
    static let disk = Color.orange
    static let network = Color.blue
    static let power = Color.green
    static let churn = Color.pink

    static let normal = Color.green
    static let warn = Color.orange
    static let critical = Color.red

    /// `tint` as the colour of text: the status colours swapped for their
    /// text variants (`NSColor.normalText` and its siblings), any other
    /// colour as it is. Fills, chart marks and glyphs beside a word keep
    /// the status colour itself.
    static func text(_ tint: Color) -> Color {
        switch tint {
        case normal: Color(nsColor: .normalText)
        case warn: Color(nsColor: .warnText)
        case critical: Color(nsColor: .criticalText)
        default: tint
        }
    }

    /// macOS group boxes and grouped content use a 10–12 point radius;
    /// cards are content, not windows.
    static let cardRadius: CGFloat = 12
}

extension NSColor {
    /// The status colours for text. In the light appearance each keeps its
    /// hue, darkened to over 5:1 against a card's fill and against a 14%
    /// tint of itself (`StatusBadge`), with Increase Contrast too. In the
    /// dark appearance the system colours already contrast, so they are
    /// used as they are.
    static let normalText = statusText(red: 0x17, green: 0x6B, blue: 0x28, dark: .systemGreen)
    static let warnText = statusText(red: 0x9A, green: 0x4A, blue: 0x00, dark: .systemOrange)
    static let criticalText = statusText(red: 0xB3, green: 0x26, blue: 0x1E, dark: .systemRed)

    private static func statusText(red: Int, green: Int, blue: Int, dark: NSColor) -> NSColor {
        let light = NSColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        return NSColor(name: nil) { appearance in
            let isDark =
                appearance.bestMatch(from: [
                    .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                ]).map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            return isDark ? dark : light
        }
    }
}

// MARK: - Appearance

/// The app's appearance setting: follow the system, or pin light or dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applied app-wide through `NSApp.appearance`, so every window, sheet
    /// and menu follows, the Settings window included; nil hands appearance
    /// back to the system. (`preferredColorScheme` scopes to one window and
    /// does not reliably return to the system's choice once set.)
    @MainActor func apply() {
        NSApp.appearance =
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
    }
}

// MARK: - Card

/// One resource's card: a quiet grouped surface, the way macOS draws group
/// boxes. Liquid Glass is for controls and navigation that float above
/// content, not for content itself, so cards are solid; the window's
/// toolbar and sidebar keep their system glass.
struct ProbeCard<Content: View, Badge: View>: View {
    let resource: Resource
    @ViewBuilder var badge: Badge
    @ViewBuilder var content: Content
    @Environment(\.cardOpensPage) private var opensPage
    @Environment(\.cardHovered) private var hovered
    @Environment(\.feedFailure) private var feedFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ResourceIcon(symbol: resource.symbol, tint: resource.tint)
                Text(resource.title)
                    .font(.headline)
                Spacer(minLength: 6)
                badge
                if opensPage {
                    // Leans toward the page it opens while the card is hovered.
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hovered ? .secondary : .tertiary)
                        .offset(x: hovered ? 2 : 0)
                        .accessibilityHidden(true)
                }
            }

            if let feedFailure { FeedFailureNote(reason: feedFailure) }

            content

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(CardSurface())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(resource.title)
    }
}

extension EnvironmentValues {
    /// Set by the Overview, whose cards open their resource's page: the
    /// card header then shows a chevron.
    @Entry var cardOpensPage = false
    /// The pointer is over the card (`CardButtonStyle`).
    @Entry var cardHovered = false
    /// Why some of the card's feeds stopped (`MetricsModel.feedFailure`).
    @Entry var feedFailure: String? = nil
}

/// The grouped surface cards and panels share: a quiet fill and a hairline,
/// the way macOS draws group boxes.
struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.fill.quinary, in: .rect(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
    }
}

/// A resource's icon, the way System Settings draws its sidebar: a white
/// symbol on a rounded square of the resource's colour. The same icon
/// marks the resource in the sidebar, on its card and on its page.
struct ResourceIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

/// A card that opens its resource's page: the whole card is the button.
/// Under the pointer it lifts a little (a shadow, a brighter edge, about 1%
/// larger) and its chevron leans toward the page; pressed, it settles back.
/// With Reduce Motion it only brightens, without moving.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardButton(configuration: configuration)
    }

    /// A view, so each card holds its own hover state and hovering one card
    /// redraws only that card.
    private struct CardButton: View {
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var scale: CGFloat {
            guard !reduceMotion else { return 1 }
            if configuration.isPressed { return 0.99 }
            return hovered ? 1.012 : 1
        }

        var body: some View {
            configuration.label
                .environment(\.cardHovered, hovered)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(.primary.opacity(hovered ? 0.18 : 0), lineWidth: 1)
                }
                .shadow(color: .black.opacity(hovered ? 0.14 : 0), radius: hovered ? 12 : 0, y: hovered ? 4 : 0)
                .scaleEffect(scale)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(.rect(cornerRadius: Theme.cardRadius))
                .animation(.smooth(duration: 0.2), value: hovered)
                .animation(.smooth(duration: 0.12), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}

extension ProbeCard where Badge == EmptyView {
    init(resource: Resource, @ViewBuilder content: () -> Content) {
        self.init(resource: resource, badge: { EmptyView() }, content: content)
    }
}

// MARK: - Readout

/// The card's headline: what the number is, then the number and its unit.
/// The number's changed digits roll (`RollingNumber`); tabular figures keep
/// its width steady while they do.
struct Readout: View {
    let context: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(context)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                let number = RollingNumber(text: value, style: .largeTitle)
                number
                    .alignmentGuide(.firstTextBaseline) { _ in number.baseline }
                    .accessibilityRepresentation { Text(value) }
                Text(unit)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stats

/// Three-ish labelled values in a row, closed by a separator.
struct StatRow: View {
    struct Item: Identifiable {
        let label: String
        let value: String
        /// Status colour only (swap over threshold); plain values stay primary.
        var tint: Color? = nil
        /// A colour key, when the value names a segment of a bar above.
        var key: Color? = nil
        var id: String { label }
    }

    let items: [Item]
    /// The separator under the row; off where the row ends a card's header.
    var divided = true

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if let key = item.key {
                                Circle().fill(key).frame(width: 6, height: 6).accessibilityHidden(true)
                            }
                            Text(item.label)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.body.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(item.tint.map { AnyShapeStyle(Theme.text($0)) } ?? AnyShapeStyle(.primary))
                    }
                    // One line each: a longer value ("95% · 3 h 32 min") shrinks
                    // a little rather than wrapping and growing the card.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if divided { Divider() }
        }
    }
}

// MARK: - Charts

/// The x-axis: the series' whole window, `capacity` samples ending at the
/// newest. A series still filling grows in from the right edge, so every
/// sample moves the chart by the same one slot and `SlidingPlot` glides it.
/// A domain from the oldest point to the newest squeezed every point left
/// by a fraction of a slot instead, in one frame, for the window's first
/// two minutes. Pinned, too, because sequence numbers keep growing and the
/// automatic domain would reach back toward zero.
func windowDomain<Value>(_ series: RollingSeries<Value>) -> ClosedRange<Int> {
    let last = series.points.last?.id ?? 0
    return (last - max(series.capacity, 2) + 1)...last
}

typealias SparkPoint = RollingSeries<Double>.Point

/// A chart with its scale: the top of its value range and zero on the
/// trailing edge, and the time it spans underneath. Charts cover the last
/// two minutes (see the Sampling settings).
private struct ScaledChart<Plot: View>: View {
    let top: String
    let bottom: String
    /// The left end of the time axis: "2 min ago".
    let span: String
    @ViewBuilder var plot: Plot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                plot
                VStack(alignment: .leading) {
                    Text(top)
                    Spacer(minLength: 0)
                    Text(bottom)
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 50, alignment: .leading)
                .accessibilityHidden(true)
            }
            HStack {
                Text(span)
                Spacer()
                Text("now")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.trailing, 56)
            .accessibilityHidden(true)
        }
    }
}

/// A new sample scrolls the series one slot left (`SlidingPlot`, played by
/// Core Animation, here and in `DualSparkline`), and the scale's top follows
/// the data without jumping (`StickyTop`). Swift Charts itself never
/// animates: a transition made it lay out and redraw the whole chart every
/// frame, about 27% of a core for the Overview's six charts (2026-10-29).
struct Sparkline: View {
    /// What the series measures, for VoiceOver ("CPU use").
    let metric: String
    let series: RollingSeries<Double>
    let tint: Color
    var height: CGFloat = 56
    /// Formats the top of the scale and the value VoiceOver reads.
    var format: (Double) -> String = { Format.number($0) }
    /// When true the y-domain hugs the data instead of starting at zero, so
    /// slow drifts in a large absolute value (compressed memory) stay visible.
    var banded: Bool = false
    /// The time the series covers, for the axis and VoiceOver.
    var span = "\(SamplingRates.chartSpanText) ago"

    private var points: [SparkPoint] { series.points }

    private var values: [Double] { points.map(\.value) }

    private var domain: ClosedRange<Double> {
        if banded, let lo = values.min(), let hi = values.max(), hi > lo {
            let pad = max((hi - lo) * 0.4, 1)
            return max(lo - pad, 0)...(hi + pad)
        }
        return StickyTop.range(of: series, headroom: 1.15) { $0 }
    }

    var body: some View {
        ScaledChart(top: format(domain.upperBound), bottom: format(domain.lowerBound), span: span) {
            SlidingPlot(step: points.last?.id ?? 0, capacity: series.capacity, values: domain) {
                Chart {
                    // A banded chart is zoomed to a narrow value range, so an area
                    // fill would cover the whole plot and hide the drift it exists
                    // to show. Line only in that mode.
                    if !banded {
                        ForEach(points) { point in
                            AreaMark(x: .value("Time", point.id), y: .value(metric, point.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(tint.opacity(0.16))
                        }
                    }
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.id), y: .value(metric, point.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                    if let last = points.last {
                        PointMark(x: .value("Time", last.id), y: .value(metric, last.value))
                            .symbolSize(24)
                            .foregroundStyle(tint)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: windowDomain(series))
                .chartYScale(domain: domain)
            }
            .frame(height: height)
            .overlay(alignment: .bottom) { Baseline() }
            .accessibilityLabel("\(metric), from \(span) to now")
            .accessibilityValue(points.last.map { format($0.value) } ?? "no data yet")
        }
    }
}

/// One rate as an area with a second drawn as a dashed line (disk write
/// and read, network received and sent): one card, two series, without
/// doubling the vertical space.
struct DualSparkline: View {
    let metric: String
    let secondary: String
    let series: RollingSeries<RatePair>
    let tint: Color
    var height: CGFloat = 56
    var format: (Double) -> String = { Format.number($0, digits: 1) }

    private var points: [RatePoint] { series.points }

    private var upper: Double {
        max((StickyTop.peak(of: series) { max($0.area, $0.line) } ?? 0.001) * 1.25, 0.001)
    }

    var body: some View {
        ScaledChart(top: format(upper), bottom: "0", span: "\(SamplingRates.chartSpanText) ago") {
            SlidingPlot(step: points.last?.id ?? 0, capacity: series.capacity, values: 0...upper) {
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value("Time", point.id), y: .value(metric, point.value.area))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(tint.opacity(0.16))
                    }
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Time", point.id), y: .value(metric, point.value.area),
                            series: .value("Series", metric)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        LineMark(
                            x: .value("Time", point.id), y: .value(secondary, point.value.line),
                            series: .value("Series", secondary)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(tint.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [3, 2]))
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: windowDomain(series))
                .chartYScale(domain: 0...upper)
            }
            .frame(height: height)
            .overlay(alignment: .bottom) { Baseline() }
            .accessibilityLabel("\(metric) and \(secondary), last \(SamplingRates.chartSpanText)")
            .accessibilityValue(
                points.last.map { "\(metric) \(format($0.value.area)), \(secondary) \(format($0.value.line))" }
                    ?? "no data yet")
        }
    }
}

/// The chart's zero line: one device pixel of separator. Not `Divider`,
/// which takes its direction from the nearest stack and, overlaid on a plot
/// inside the chart's HStack, drew a vertical line down the middle.
private struct Baseline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

// MARK: - Lists

/// A list's caption: "Busiest apps · % of one core".
struct ListTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A ranked list with a fixed number of lanes. The block is always as tall
/// as its full list, so the card keeps one height whether a sample brings
/// three rows, one, or none (then `empty` sits in the first lane). A card
/// that grew would also grow every card in its grid row.
struct RankedList<Item, ID: Hashable, Row: View>: View {
    let title: String
    let items: [Item]
    let id: KeyPath<Item, ID>
    let lanes: Int
    let empty: String
    @ViewBuilder var row: (Item) -> Row

    private static var laneHeight: CGFloat { BarRow.height }
    private static var spacing: CGFloat { 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ListTitle(title)
            VStack(alignment: .leading, spacing: Self.spacing) {
                if items.isEmpty {
                    QuietLine(empty)
                } else {
                    ForEach(items.prefix(lanes), id: id) { item in row(item) }
                }
            }
            .frame(
                height: CGFloat(lanes) * Self.laneHeight + CGFloat(lanes - 1) * Self.spacing, alignment: .top)
        }
    }
}

/// One ranked row: icon, name, a bar against the list's peak, the value.
/// Fixed-width lanes, so names, bars and values align down the list.
struct BarRow: View {
    let label: String
    let value: String
    let fraction: Double
    let tint: Color
    /// When set, the row leads with that process's app icon.
    var pid: pid_t? = nil
    /// For identifiers (interfaces, paths) rather than names.
    var monospaced = false

    /// One lane of a `RankedList`.
    static let height: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            if let pid {
                ProcessIcon(pid: pid, name: label)
            }
            Text(label)
                .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: pid == nil ? 138 : 112, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            Text(value)
                .font(.body.weight(.medium))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)
    }
}

/// What a list says while it has nothing: one quiet line in the row's
/// place, not a box, so an empty list does not look like a control.
struct QuietLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: BarRow.height, alignment: .leading)
    }
}

// MARK: - Bars

/// A track filled by segments, each a share of its width, from the leading
/// edge; what they leave is bare track.
struct SegmentTrack: View {
    struct Segment {
        let id: String
        let share: Double
        let color: Color
    }

    let segments: [Segment]
    let height: CGFloat
    var minimumWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments, id: \.id) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(
                            width: max(
                                minimumWidth, (geo.size.width - 2 * Double(segments.count - 1)) * segment.share))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary)
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: height / 2))
    }
}

/// RAM as a bar of its in-use parts against physical memory, with its scale.
struct MemoryCompositionBar: View {
    /// (label, megabytes, colour) in stacking order.
    let segments: [(label: String, mb: Double, color: Color)]
    /// Capacity the segments are proportions of: physical RAM, in the
    /// segments' unit. Pages the breakdown does not name show as bare track.
    let totalMB: Double
    /// The same capacity in bytes, for its label.
    let totalBytes: Int64

    /// Never smaller than the segment sum, so rounding cannot overflow the bar.
    private var total: Double { max(segments.reduce(0) { $0 + $1.mb }, totalMB, 1) }

    var body: some View {
        VStack(spacing: 3) {
            SegmentTrack(
                segments: segments.map { .init(id: $0.label, share: $0.mb / total, color: $0.color) }, height: 8,
                minimumWidth: 2)
            HStack {
                Text("0")
                Spacer()
                Text(MemorySize.text(bytes: totalBytes))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory in use")
        .accessibilityValue(
            segments.map { "\($0.label) \(MemorySize.text(megabytes: $0.mb))" }.joined(separator: ", "))
    }
}

// MARK: - Process icon

/// App icon for a pid, or a symbol for daemons and helpers that LaunchServices
/// does not know. Cached because the row re-renders every second and the
/// lookup walks the running-application list. The key includes the name: a
/// pid alone is reused by later processes and survives `exec`.
struct ProcessIcon: View {
    let pid: pid_t
    let name: String

    private struct Key: Hashable {
        let pid: pid_t
        let name: String
    }

    @MainActor private static var cache: [Key: NSImage?] = [:]

    @MainActor private static func icon(for key: Key) -> NSImage? {
        if let hit = cache[key] { return hit }
        if cache.count > 256 { cache.removeAll(keepingCapacity: true) }
        let found = NSRunningApplication(processIdentifier: key.pid)?.icon
        cache[key] = found
        return found
    }

    var body: some View {
        Group {
            if let image = Self.icon(for: Key(pid: pid, name: name)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 4))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
