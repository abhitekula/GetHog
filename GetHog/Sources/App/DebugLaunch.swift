#if DEBUG
import Foundation

/// Launch-time deep links for verification runs.
///
/// Screens that sit two or three taps in — a dashboard's inspector, a tile
/// detail — otherwise can't be screenshotted without driving the UI, which needs
/// a granted device. These let a launch land directly on the screen under test:
///
///     xcrun simctl launch <udid> app.gethog.GetHog \
///       GETHOG_API_KEY=phx_… GETHOG_OPEN_DASHBOARD=first GETHOG_OPEN_TILE=0
///
/// DEBUG-only, read once at launch, and inert unless the variable is set, so
/// nothing here can affect a normal run.
enum DebugLaunch {
    private static let environment = ProcessInfo.processInfo.environment

    /// `first`, or an explicit dashboard id.
    enum DashboardSelection {
        case first
        case id(Int)
    }

    static var dashboard: DashboardSelection? {
        guard let raw = environment["GETHOG_OPEN_DASHBOARD"], !raw.isEmpty else { return nil }
        if let id = Int(raw) { return .id(id) }
        return raw.lowercased() == "first" ? .first : nil
    }

    /// Index of the tile to open in the inspector once a dashboard has loaded.
    static var tileIndex: Int? {
        environment["GETHOG_OPEN_TILE"].flatMap(Int.init)
    }

    /// Opens straight onto a given tab, by `AppTab` raw value.
    ///
    /// Sections beyond the four loose tabs sit behind "More" on iPhone and a
    /// sidebar disclosure on iPad, so reaching them for a screenshot otherwise
    /// takes taps.
    static var initialTab: String? {
        environment["GETHOG_TAB"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Shows a single detached screen as the whole app, bypassing the tab bar
    /// and split view — the way to tell whether a layout is misbehaving on its
    /// own or only because of what contains it.
    static var soloWindowTarget: WindowTarget? {
        guard let raw = environment["GETHOG_SOLO_DASHBOARD"], let id = Int(raw) else { return nil }
        return .dashboard(id: id)
    }
}
#endif
