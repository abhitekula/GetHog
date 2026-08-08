import Foundation
import SwiftUI

/// The PostHog project's day boundary for charts.
///
/// A missing or malformed project setting falls back to UTC, matching PostHog's
/// own default rather than silently adopting the device's unrelated time zone.
public enum ProjectChartTimeZone {
    public static let fallback = TimeZone(secondsFromGMT: 0)!

    public static func resolve(_ identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? fallback
    }
}

private struct ProjectChartTimeZoneKey: EnvironmentKey {
    static let defaultValue = ProjectChartTimeZone.fallback
}

public extension EnvironmentValues {
    var projectChartTimeZone: TimeZone {
        get { self[ProjectChartTimeZoneKey.self] }
        set { self[ProjectChartTimeZoneKey.self] = newValue }
    }
}
