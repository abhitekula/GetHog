import GetHogKit
import SwiftUI

/// Honest freshness stamp.
///
/// The app is cache-first because rate limits are organisation-wide, so every
/// data surface states when its data was actually computed. Silent stale data is
/// the worst failure mode an analytics app can have.
struct FreshnessLabel: View {
    let date: Date?
    var isCached: Bool = true

    var body: some View {
        Group {
            if let date {
                Text("Updated \(date, format: .relative(presentation: .named))")
            } else {
                Text("Not yet loaded")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .accessibilityLabel(
            date.map { "Data updated \($0.formatted(.relative(presentation: .named)))" }
                ?? "Data not yet loaded"
        )
    }
}

/// Shown when an insight type isn't drawn on mobile yet.
///
/// A deliberate, tappable card beats a broken chart, and it makes the roadmap
/// self-evident inside the app.
struct UnsupportedInsightCard: View {
    let kind: String
    var webURL: URL?

    private var friendlyName: String {
        kind.replacingOccurrences(of: "Query", with: "")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("\(friendlyName) insights aren't drawn on mobile yet")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let webURL {
                Link(destination: webURL) {
                    Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                        .font(.footnote.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// Shown in place of a feature the current API key can't reach.
struct LockedCapabilityView: View {
    let capability: Capability
    let scope: String?
    var onRecheck: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("\(capability.title) is locked", systemImage: "lock")
        } description: {
            VStack(spacing: 8) {
                Text("Your PostHog API key is missing a scope.")
                if let scope {
                    Text(scope)
                        .font(.footnote.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                }
                Text("Add it to your key in PostHog, then re-check.")
                    .font(.footnote)
            }
        } actions: {
            if let onRecheck {
                Button("Re-check permissions", action: onRecheck)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A rounded card that hosts a dashboard tile or detail block.
///
/// Three things stack to make it read as a surface rather than a rectangle: a
/// fill, a hairline, and two shallow shadows. The hairline is load-bearing —
/// the grouped card colour is pure white in light mode, so on any screen not
/// using the grouped background the fill alone makes the card vanish — but on
/// its own it left everything looking like a wireframe. The shadows give the
/// edge somewhere to sit.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    var elevation: Theme.Elevation = .card
    /// Draws a coloured spine down the leading edge.
    ///
    /// Lifted from PostHog's insight cards, and it earns its place: a wall of
    /// identical white rectangles gives the eye nothing to navigate by, and the
    /// stripe lets a tile be recognised by colour and position before a single
    /// word is read. It is chrome keyed to the *kind* of insight, never to a
    /// series — borrowing the data palette here would imply a relationship to
    /// the values that does not exist.
    var accent: Color?
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: shape)
            .overlay(alignment: .leading) {
                if let accent {
                    accent
                        .frame(width: 4)
                        .clipShape(
                            .rect(
                                topLeadingRadius: Theme.Radius.medium,
                                bottomLeadingRadius: Theme.Radius.medium,
                                style: .continuous
                            )
                        )
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                shape.strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .compositingGroup()
            .shadow(
                color: elevation.ambient.color,
                radius: elevation.ambient.radius,
                y: elevation.ambient.y
            )
            .shadow(
                color: elevation.key.color,
                radius: elevation.key.radius,
                y: elevation.key.y
            )
    }
}

/// Muted small-caps run-in header, the way PostHog labels its column groups.
///
/// Gives a screen structure without spending a full-weight heading on it, which
/// is what makes a dense list feel organised rather than merely long.
struct SectionLabel: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(text.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(text)
    }
}

/// Title row for a card, with the insight's own symbol.
///
/// The dashboard was a wall of identically-weighted rectangles; a symbol and a
/// firmer title give each tile a recognisable silhouette, so the eye can find
/// the funnel without reading every heading. The symbol is tinted from the
/// accent rather than the series palette — the palette belongs to the data, and
/// borrowing it for chrome would imply a relationship that isn't there.
struct CardHeader: View {
    let title: String
    var systemImage: String?
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A selectable option row used in onboarding and pickers.
struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                content
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Color(.tertiaryLabel))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(14)
            .background(Theme.cardBackground, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Theme.accent.opacity(0.6) : Theme.hairline,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Signed delta with an arrow, so change is never conveyed by colour alone.
struct DeltaBadge: View {
    let current: Double
    let previous: Double
    /// True for metrics where a rise is bad news — bounce rate, error rate, load
    /// time. Without it the badge tints purely by direction and paints a rising
    /// bounce rate green, which is the opposite of what happened.
    var isIncreaseBad: Bool = false

    private var change: Double? {
        guard previous != 0 else { return nil }
        return (current - previous) / abs(previous)
    }

    var body: some View {
        if let change {
            let rising = change >= 0
            let isGood = rising != isIncreaseBad
            Label {
                Text(change, format: .percent.precision(.fractionLength(0...1)))
            } icon: {
                // The arrow always follows the number, never the verdict: a fall
                // in a bad-when-rising metric is good news but it is still a
                // fall, and flipping the arrow would misstate the direction.
                Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isGood ? Theme.Status.good : Theme.Status.critical)
            .accessibilityLabel(
                "\(rising ? "Up" : "Down") "
                    + abs(change).formatted(.percent.precision(.fractionLength(0...1)))
                    + ", \(isGood ? "an improvement" : "worse")"
            )
        }
    }
}

/// A delta that states its own absence rather than rendering nothing.
///
/// `DeltaBadge` returns an empty view when there is no previous value, which is
/// right inline but wrong in a column: eight rows of nothing reads as a broken
/// field rather than as a fact about the data. This says the fact.
struct DeltaOrAbsence: View {
    let current: Double
    let previous: Double?
    /// True for metrics where going up is bad news — bounce rate, error rate,
    /// load time. Without it this tints purely by direction and paints a rising
    /// bounce rate green, contradicting the metric beside it.
    var isIncreaseBad: Bool = false
    /// Explains *why* it is missing, when the caller knows.
    var absenceReason: String = "No prior period"

    var body: some View {
        if let previous, previous != 0 {
            DeltaBadge(current: current, previous: previous, isIncreaseBad: isIncreaseBad)
        } else {
            Label(absenceReason, systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("No comparable previous period")
        }
    }
}

/// Compact status pill that always carries text, never colour alone.
struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: .capsule)
            .foregroundStyle(tint)
    }
}

extension View {
    /// Applies a redacted skeleton while loading, so layout never jumps.
    @ViewBuilder
    func skeleton(_ isLoading: Bool) -> some View {
        redacted(reason: isLoading ? .placeholder : [])
            .animation(.default, value: isLoading)
    }
}

/// Formats large counts compactly (12.4K) for tiles and rows.
extension Double {
    var compactFormatted: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
