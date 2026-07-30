import AppIntents
import GetHogKit
import SwiftUI
import WidgetKit

// MARK: - Palette

/// The app's palette, narrowed to the four roles a widget has room for.
///
/// This used to be four *system* colours under a comment claiming the app's
/// `Theme` could not be reached from an extension target. It could: `Theme.swift`
/// imports only SwiftUI and UIKit, and `project.yml` now compiles it here. The
/// claim had a real cost — `accent` was `Color.orange`, which is the one hue the
/// app rules out by name, for trademark distance from PostHog's own brand. A
/// widget sits on the Home Screen with no app around it to give it context, so
/// it is the *last* surface that can afford to be a different colour from the
/// app it belongs to.
///
/// The text-weight `Ink` partners rather than the marks, because every use here
/// is a glyph or a number rather than a fill.
///
/// Every colour below is still decoration. Direction, state and value are always
/// also carried by a glyph and by text, because on the Lock Screen the rendering
/// mode is `.vibrant` or `.accented` and hue is simply discarded.
enum WidgetPalette {
    static let accent = Theme.Status.accentInk
    static let positive = Theme.Status.goodInk
    static let neutral = Color.secondary

    /// Direction is deliberately *not* painted green-good / red-bad.
    ///
    /// The snapshot says how a number moved, not whether moving that way is
    /// desirable — a rise in errors, bounce rate or churn is a fall in health,
    /// and there is no field that distinguishes them. Colouring every rise green
    /// would be wrong about half the metrics an analytics tool tracks. So the
    /// arrow carries direction, the text carries magnitude, and colour only
    /// separates "something changed" from "nothing to compare against".
    static func tint(for direction: SharedSnapshot.Metric.Direction) -> Color {
        switch direction {
        case .up, .down: accent
        case .flat, .unknown: neutral
        }
    }

    static func symbol(for direction: SharedSnapshot.Metric.Direction) -> String {
        switch direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        case .unknown: "minus"
        }
    }

    /// Health, unlike direction, has a defined polarity.
    ///
    /// The rule above — never green-good / red-bad — holds for a *metric*,
    /// because the snapshot says how a number moved and not whether moving that
    /// way is desirable. A health verdict is the opposite case: `critical` means
    /// PostHog is refusing or rejecting data right now, and there is no reading of
    /// that which is good news. So red is accurate here and only here.
    ///
    /// It is still never the only encoding. Every surface that uses this also
    /// draws `HealthVerdict.symbolName` and prints `healthHeadline`, because the
    /// Lock Screen renders `.vibrant` or `.accented` and discards hue outright.
    static func tint(for verdict: SharedSnapshot.HealthVerdict) -> Color {
        switch verdict {
        case .critical: critical
        case .attention: accent
        case .clear: positive
        case .unchecked: neutral
        }
    }

    static let critical = Theme.Status.criticalInk
}

// MARK: - Formatting

enum WidgetNumber {

    /// Widgets have no room for "1,204,533". Compact notation keeps the headline
    /// legible at every Dynamic Type size; the full number goes to VoiceOver.
    static func compact(_ value: Double, unit: String? = nil) -> String {
        let magnitude = abs(value)
        let number: String
        if magnitude >= 1_000 {
            number = value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        } else if value == value.rounded() {
            number = value.formatted(.number.precision(.fractionLength(0)))
        } else {
            number = value.formatted(.number.precision(.fractionLength(0...1)))
        }
        return decorate(number, unit: unit)
    }

    static func full(_ value: Double, unit: String? = nil) -> String {
        decorate(value.formatted(.number.precision(.fractionLength(0...2))), unit: unit)
    }

    private static func decorate(_ number: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return number }
        // "%" and currency symbols hug the number; word units get a space.
        if unit == "%" { return number + "%" }
        if unit.count == 1, unit.rangeOfCharacter(from: .letters) == nil { return unit + number }
        return "\(number) \(unit)"
    }

    static func percentChange(_ fraction: Double) -> String {
        let magnitude = abs(fraction)
        // Below a tenth of a percent, one decimal reads as "0.0%".
        let precision: Int = magnitude < 0.1 ? 1 : 0
        return (magnitude * 100).formatted(.number.precision(.fractionLength(precision))) + "%"
    }

    /// The change as the widget shows it: percentage when there is a usable
    /// baseline, otherwise the raw difference, otherwise nothing at all.
    static func changeLabel(for metric: SharedSnapshot.Metric) -> String? {
        if let fraction = metric.deltaFraction { return percentChange(fraction) }
        if let delta = metric.delta { return compact(abs(delta), unit: metric.unit) }
        return nil
    }
}

// MARK: - Accessibility

enum WidgetAccessibility {

    /// Value *and* direction in one phrase. A widget that reads out only
    /// "1.2 thousand" has hidden the half of the information the colour was
    /// carrying.
    static func label(for metric: SharedSnapshot.Metric) -> String {
        var parts = [metric.title, WidgetNumber.full(metric.value, unit: metric.unit)]
        let change = WidgetNumber.changeLabel(for: metric)
        switch metric.direction {
        case .up: parts.append("up \(change ?? "")")
        case .down: parts.append("down \(change ?? "")")
        case .flat: parts.append("unchanged")
        case .unknown: parts.append("no comparison available")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func label(for flag: SharedSnapshot.Flag) -> String {
        "Feature flag \(flag.key), \(flag.active ? "enabled" : "disabled")"
    }
}

// MARK: - Building blocks

/// Value and direction. The arrow is the primary signal; the colour repeats it.
struct DeltaBadge: View {
    let metric: SharedSnapshot.Metric
    var compact = false

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: WidgetPalette.symbol(for: metric.direction))
                .imageScale(.small)
                .font(.caption2.weight(.bold))
            if let change = WidgetNumber.changeLabel(for: metric) {
                Text(change)
                    .font(compact ? .caption2 : .caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if !compact {
                Text("no baseline")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        // In `.accented` and `.vibrant` the system flattens colour anyway;
        // asking for a hue there just produces an unpredictable grey.
        .foregroundStyle(renderingMode == .fullColor ? AnyShapeStyle(WidgetPalette.tint(for: metric.direction)) : AnyShapeStyle(.secondary))
        .accessibilityHidden(true)
    }
}

/// A trend line drawn by hand rather than with Swift Charts: a widget gets a
/// hard memory ceiling and this is four points and a `Path`.
struct Sparkline: View {
    let points: [Double]
    var filled = true

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        GeometryReader { geo in
            let coordinates = coordinates(in: geo.size)
            if coordinates.count >= 2 {
                ZStack {
                    if filled {
                        area(through: coordinates, in: geo.size).fill(shade.opacity(0.18))
                    }
                    line(through: coordinates)
                        .stroke(shade, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static let lineWidth: CGFloat = 2

    private func coordinates(in size: CGSize) -> [CGPoint] {
        guard points.count >= 2, let low = points.min(), let high = points.max() else { return [] }
        let span = high - low
        let step = size.width / CGFloat(points.count - 1)
        // Inset by half the stroke so the peak and trough aren't shaved off by
        // the frame — on a 16pt-tall sparkline that clipping is very visible.
        let inset = Self.lineWidth / 2
        let usable = max(0, size.height - Self.lineWidth)
        return points.enumerated().map { index, value in
            // A flat series would divide by zero; draw it down the middle.
            let fraction = span > 0 ? (value - low) / span : 0.5
            return CGPoint(x: CGFloat(index) * step, y: inset + usable * (1 - fraction))
        }
    }

    private func line(through coordinates: [CGPoint]) -> Path {
        Path { path in
            path.addLines(coordinates)
        }
    }

    private func area(through coordinates: [CGPoint], in size: CGSize) -> Path {
        Path { path in
            path.addLines(coordinates)
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }

    private var shade: Color {
        renderingMode == .fullColor ? WidgetPalette.accent : .primary
    }
}

/// Title, value, delta — the unit every family is built from.
struct MetricTile: View {
    let metric: SharedSnapshot.Metric
    var valueFont: Font = .title2
    var showsSparkline = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // Falls back to dropping the sparkline before it lets the number
            // shrink or clip at accessibility sizes.
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    valueRow
                    if showsSparkline, metric.sparkline.count >= 2 {
                        Sparkline(points: metric.sparkline).frame(height: 16)
                    }
                }
                valueRow
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetAccessibility.label(for: metric))
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(WidgetNumber.compact(metric.value, unit: metric.unit))
                .font(valueFont)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            DeltaBadge(metric: metric, compact: true)
        }
    }
}

/// "Updated 20m ago", plus the only refresh a widget can honestly offer.
struct FreshnessFooter: View {
    let freshness: WidgetFreshness
    var showsRefresh = true

    @Environment(\.widgetFamily) private var family

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: freshness.isStale ? "clock.badge.exclamationmark" : "clock")
                .imageScale(.small)
            Text(freshness.capturedAt == nil ? "never synced" : "Updated \(freshness.shortLabel) ago")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if showsRefresh, supportsInteraction {
                Spacer(minLength: 2)
                Button(intent: RefreshInAppIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open GetHog to sync")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(freshness.spokenLabel)
    }

    /// Buttons only exist on the families that can host them; a Lock Screen
    /// accessory would render a dead control.
    private var supportsInteraction: Bool {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge: true
        default: false
        }
    }
}

/// Shown when the App Group holds nothing yet. A blank widget is a bug: it
/// looks identical to a broken one, and the user has no idea what to do.
struct NoDataView: View {
    var message: String = "Open GetHog to sync"

    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.dotted")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No data yet. \(message).")
    }
}

/// The accessory families are text-only in practice: images beyond a symbol are
/// stripped and there is no room for a second line.
struct InlineMetricView: View {
    let metric: SharedSnapshot.Metric?

    var body: some View {
        if let metric {
            let change = WidgetNumber.changeLabel(for: metric)
            Label {
                Text("\(metric.title) \(WidgetNumber.compact(metric.value, unit: metric.unit))\(change.map { " \($0)" } ?? "")")
            } icon: {
                Image(systemName: WidgetPalette.symbol(for: metric.direction))
            }
            .accessibilityLabel(WidgetAccessibility.label(for: metric))
        } else {
            Text("GetHog: no data")
        }
    }
}
