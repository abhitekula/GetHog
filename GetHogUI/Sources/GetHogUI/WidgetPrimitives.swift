import Foundation
import GetHogKit

/// Number formatting that keeps a widget-sized headline readable without
/// separating a unit from the value it qualifies.
public enum WidgetNumber {

    public static func compact(_ value: Double, unit: String? = nil) -> String {
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

    public static func full(_ value: Double, unit: String? = nil) -> String {
        decorate(value.formatted(.number.precision(.fractionLength(0...2))), unit: unit)
    }

    public static func percentChange(_ fraction: Double) -> String {
        let magnitude = abs(fraction)
        let precision: Int = magnitude < 0.1 ? 1 : 0
        return (magnitude * 100).formatted(.number.precision(.fractionLength(precision))) + "%"
    }

    /// The change as compact surfaces show it: percentage when there is a
    /// usable baseline, otherwise a raw difference, otherwise no claim.
    public static func changeLabel(for metric: SharedSnapshot.Metric) -> String? {
        if let fraction = metric.deltaFraction { return percentChange(fraction) }
        if let delta = metric.delta { return compact(abs(delta), unit: metric.unit) }
        return nil
    }

    private static func decorate(_ number: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return number }
        if unit == "%" { return number + "%" }
        if unit.count == 1, unit.rangeOfCharacter(from: .letters) == nil { return unit + number }
        return "\(number) \(unit)"
    }
}

/// How old rendered snapshot data is, in concise and spoken forms every
/// widget-shaped surface can state consistently.
public struct WidgetFreshness: Equatable, Sendable {

    /// `nil` before the app has ever synced.
    public let capturedAt: Date?
    public let now: Date

    public init(capturedAt: Date?, now: Date) {
        self.capturedAt = capturedAt
        self.now = now
    }

    public var age: TimeInterval? {
        guard let capturedAt else { return nil }
        return max(0, now.timeIntervalSince(capturedAt))
    }

    public var isStale: Bool {
        guard let age else { return true }
        return age > SharedSnapshot.defaultStaleTolerance
    }

    /// Compact enough for a widget footer: "now", "20m", "3h", "2d".
    public var shortLabel: String {
        guard let age else { return "never" }
        switch age {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(age / 60))m"
        case ..<86_400: return "\(Int(age / 3_600))h"
        default: return "\(Int(age / 86_400))d"
        }
    }

    /// Spelled out for VoiceOver, which should not have to read "3h" aloud.
    public var spokenLabel: String {
        guard let age else { return "not synced yet" }
        switch age {
        case ..<60: return "updated just now"
        case ..<3_600: return "updated \(Int(age / 60)) minutes ago"
        case ..<86_400: return "updated \(Int(age / 3_600)) hours ago"
        default: return "updated \(Int(age / 86_400)) days ago"
        }
    }

    /// A complete visual sentence for a widget footer.
    public var caption: String {
        guard let age else { return "never synced" }
        return Self.caption(forAge: age)
    }

    /// The relative-time clause for copy that supplies its own prefix, such as
    /// a carried-forward section labelled "as of 20m ago".
    public var relativeCaption: String? {
        guard let age else { return nil }
        return Self.relativeCaption(forAge: age)
    }

    /// One-line title form for surfaces such as Top Shelf and the menu bar.
    public static func caption(forAge age: TimeInterval) -> String {
        "Updated \(relativeCaption(forAge: age))"
    }

    /// A prefix-free age that remains grammatical at the under-a-minute
    /// boundary instead of producing "now ago".
    public static func relativeCaption(forAge age: TimeInterval) -> String {
        switch max(0, age) {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(age / 60))m ago"
        case ..<86_400: return "\(Int(age / 3_600))h ago"
        default: return "\(Int(age / 86_400))d ago"
        }
    }
}
