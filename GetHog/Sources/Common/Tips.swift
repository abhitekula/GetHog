import GetHogKit
import GetHogUI
import SwiftUI
import TipKit

/// Point-of-use tips.
///
/// The tips are *defined* here but *displayed* next to the control each one
/// describes. Nothing is front-loaded into a launch tutorial: a carousel shown
/// before the user has a reason to care is read once and remembered by nobody,
/// whereas a tip attached to the chart teaches the gesture at the moment the
/// chart is on screen.
///
/// Dismissal state belongs to TipKit rather than to `@AppStorage`. Hand-rolled
/// flags would have to reimplement what TipKit already owns — permanent
/// invalidation on close, display cadence, and rule re-evaluation — and would
/// get the "never show this again" contract subtly wrong.
enum AppTips {

    /// Called once at launch. Kept here so the app entry point carries a single
    /// line and none of the policy.
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }

    /// Pushes the current key's capabilities into the tips' rules.
    ///
    /// A tip for a feature the user's API key cannot reach is pure noise, so
    /// availability is a rule rather than a check at the call site — TipKit then
    /// suppresses the tip without the view having to know it exists.
    @MainActor
    static func refresh(from model: AppModel) {
        ChartScrubTip.isAvailable = model.isAvailable(.dashboards)
        FlagWidgetTip.isAvailable = model.isAvailable(.flags)
        // Not a capability: switching is meaningless with one project, and the
        // key's scopes have nothing to do with it.
        ProjectSwitchTip.hasMultipleProjects = model.projects.count > 1
    }
}

/// Attach to a project-switching control.
struct ProjectSwitchTip: Tip {
    @Parameter static var hasMultipleProjects: Bool = false

    var title: Text { Text("Switch project") }

    var message: Text? {
        Text("Every screen shows one project at a time. Change it here and the whole app follows.")
    }

    var image: Image? { Image(systemName: "rectangle.2.swap") }

    var rules: [Rule] {
        #Rule(Self.$hasMultipleProjects) { $0 == true }
    }
}

/// Attach to the feature flag list.
struct FlagWidgetTip: Tip {
    @Parameter static var isAvailable: Bool = false

    var title: Text { Text("Keep a flag to hand") }

    var message: Text? {
        Text("Add a GetHog widget to your Home Screen, or a control to Control Center, to watch and toggle a flag without opening the app.")
    }

    var image: Image? { Image(systemName: "square.grid.2x2") }

    var rules: [Rule] {
        #Rule(Self.$isAvailable) { $0 == true }
    }
}
