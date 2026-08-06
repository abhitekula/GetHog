import GetHogUI
import SwiftUI

/// The tvOS entry point — a placeholder scene only. The real shell
/// arrives in a later task; this file exists so the target builds and the
/// project's plumbing (packages, entitlements, demo data, the widget embed)
/// can be verified end to end before any feature lands on it.
///
/// `Theme` is used deliberately: it proves GetHogUI links for this platform,
/// not merely that it compiled.
@main
struct GetHogTVApp: App {
    var body: some Scene {
        WindowGroup {
            Text("GetHog")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.accent)
        }
    }
}
