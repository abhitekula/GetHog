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
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: .rect(cornerRadius: 14))
    }
}

/// Signed delta with an arrow, so change is never conveyed by colour alone.
struct DeltaBadge: View {
    let current: Double
    let previous: Double

    private var change: Double? {
        guard previous != 0 else { return nil }
        return (current - previous) / abs(previous)
    }

    var body: some View {
        if let change {
            let rising = change >= 0
            Label {
                Text(change, format: .percent.precision(.fractionLength(0...1)))
            } icon: {
                Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(rising ? Theme.Status.good : Theme.Status.critical)
            .accessibilityLabel(
                "\(rising ? "Up" : "Down") \(abs(change).formatted(.percent.precision(.fractionLength(0...1))))"
            )
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
